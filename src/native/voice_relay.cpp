#include <std_include.hpp>
#include "loader/component_loader.hpp"
#include "game/game.hpp"
#include "network.hpp"
#include "party.hpp"
#include "scheduler.hpp"
#include "scripting.hpp"
#include "command.hpp"
#include "console/console.hpp"
#include <utils/cryptography.hpp>
#include <utils/flags.hpp>
#include <utils/hook.hpp>
#include <charconv>
#include "voice_relay.hpp"
#include "voice_transport.hpp"
#include "voice_inbox.hpp"

namespace voice_relay
{
    namespace
    {
        namespace wire = voice::wire;
        namespace transport = voice::transport;
        constexpr const char* command_name = "iw7voice";
        // Supported retail binary; keep ABI/layout checks alongside the calls.
        namespace engine
        {
            constexpr std::uintptr_t queue = 0x14037D960;
            constexpr std::uintptr_t selected_session = 0x140D32740;
            constexpr std::uintptr_t controller = 0x140347690;
            constexpr std::uintptr_t local_slot = 0x140D32920;
            constexpr std::uintptr_t incoming = 0x140D59620;
            constexpr std::uintptr_t is_muted = 0x14037BBA0;
            constexpr std::uintptr_t unregister = 0x140C73970;
            constexpr std::uintptr_t register_voice = 0x140D59D10;
            constexpr std::uintptr_t mute = 0x140D59AC0;
            constexpr std::uintptr_t accepted_join_call = 0x140C4F87E;
            constexpr std::uintptr_t send_game_state = 0x140C6B8A0;
            game::SessionData* session()
            {
                return utils::hook::invoke<game::SessionData*>(selected_session);
            }
            int controller_index()
            {
                return utils::hook::invoke<int>(controller);
            }
            int own_slot(int index, game::SessionData* data)
            {
                return utils::hook::invoke<int>(local_slot, index, data);
            }
            bool muted(game::SessionData* data, unsigned slot)
            {
                return utils::hook::invoke<bool>(is_muted, data, static_cast<int>(slot));
            }
            void unregister_user(game::SessionData* data, unsigned slot)
            {
                utils::hook::invoke<void>(unregister, data, static_cast<int>(slot));
            }
            void playback(game::SessionData* data, unsigned slot, const std::string& frame)
            {
                utils::hook::invoke<void>(incoming, data, static_cast<int>(slot), frame.data(),
                                          static_cast<int>(frame.size()), 0);
            }
            bool supported()
            {
                struct entry
                {
                    std::uintptr_t address;
                    const char* bytes;
                    unsigned size;
                };
                const entry entries[] = {
                    {queue, "\x40\x53\x48\x83\xec\x20\x48\x63\xd9\x85\xc9", 11},
                    {selected_session, "\x48\x83\xec\x28\x48\x8d\x0d\x55\x26\x52\x04", 11},
                    {controller, "\x8b\x05\xce\xcd\xeb\x01\xc3", 7},
                    {local_slot, "\x48\x63\xc1\x4c\x8b\xc2", 6},
                    {incoming, "\x40\x55\x57\x41\x54\x41\x56\x41\x57\xb8\x40\x20\x00\x00", 14},
                    {is_muted, "\x48\x89\x74\x24\x10\x57\x48\x83\xec\x20", 10},
                    {unregister, "\x48\x89\x5c\x24\x18\x55\x48\x83\xec\x20\x80\x79\x10\x00", 14},
                    {register_voice, "\x48\x89\x6c\x24\x10\x48\x89\x74\x24\x18\x57\x48\x83\xec\x20",
                     15},
                    {mute, "\x48\x63\xc2\x48\x6b\xd0\x38\xc6\x84\x0a\x90\x00\x00\x00\x01\xc3", 16},
                    {0x140D59FE0,
                     "\x48\x63\xc2\x48\x6b\xd0\x38\xc6\x84\x0a\x90\x00\x00\x00\x00\xc3", 16},
                    {accepted_join_call, "\xe8\x1d\xc0\x01\x00", 5},
                    {send_game_state, "\x48\x89\x5c\x24\x08\x48\x89\x6c\x24\x10", 10},
                    {0x140C733E0, "\x4c\x89\x44\x24\x18\x53\x56\x41\x54\x41\x55\x48\x83\xec\x58",
                     15},
                };
                for (const auto& entry : entries)
                    if (std::memcmp(reinterpret_cast<const void*>(entry.address), entry.bytes,
                                    entry.size))
                        return false;
                return true;
            }
        }
        transport::id random_id()
        {
            transport::id result;
            do
            {
                utils::cryptography::random::get_data(&result, sizeof(result));
            } while (result.empty());
            return result;
        }
        std::uint64_t now()
        {
            return GetTickCount64();
        }
        bool zombies()
        {
            return game::Com_GameMode_GetActiveGameMode() == game::GAME_MODE_CP;
        }
        bool voice_enabled()
        {
            const auto* setting = game::Dvar_FindVar("cl_voice");
            return setting && setting->type == game::DVAR_TYPE_BOOL && setting->current.enabled;
        }
        std::atomic<bool> installed{};
        utils::hook::detour queue_hook;
        std::recursive_mutex state_mutex;
        voice::inbox incoming;
        std::unique_ptr<transport::server> server;
        bool server_running{};
        std::unique_ptr<transport::client> client;
        std::array<transport::id, voice::state::max_speakers> incarnations{};
        std::array<game::netadr_s, voice::state::max_speakers> addresses{};
        game::netadr_s host{};
        std::string game_challenge;
        game::SessionData* session{};
        std::array<std::uint64_t, voice::state::max_speakers> owned_users{};
        int local_slot{-1};
        std::uint64_t local_user{};
        std::uint64_t last_registration_check{};
        std::atomic<std::uint64_t> encoded{}, sent{}, relayed{}, played{}, rejected{}, muted{},
            joins{}, registrations{};
        std::atomic<std::uint64_t> registration_attempts{}, registration_failures{};

        void send(const game::netadr_s& target, const wire::message& data)
        {
            const auto bytes = wire::encode(data);
            if (!bytes.empty())
                network::send(target, command_name, bytes);
        }
        void send(const std::vector<transport::delivery>& messages)
        {
            for (const auto& item : messages)
            {
                if (item.slot >= addresses.size() || addresses[item.slot].type != game::NA_IP)
                    continue;
                send(addresses[item.slot], item.data);
                if (item.data.type == wire::kind::audio_down)
                    relayed += item.data.frames.size();
            }
        }
        voice::inbox::endpoint endpoint(const game::netadr_s& address)
        {
            if (address.type != game::NA_IP)
                return 0;
            return (static_cast<std::uint64_t>(address.addr) << 16) | address.port;
        }
        std::vector<voice::inbox::packet> drain(std::uint64_t time)
        {
            unsigned expired{};
            auto result = incoming.drain(time, expired);
            rejected += expired;
            return result;
        }
        void receive(const game::netadr_s& source, const std::string_view& bytes)
        {
            if (!installed || !incoming.push(endpoint(source), bytes, now()))
                ++rejected;
        }
        int client_index(const game::client_t* value)
        {
            const auto base = reinterpret_cast<std::uintptr_t>(*game::svs_clients);
            const auto pointer = reinterpret_cast<std::uintptr_t>(value);
            const auto count = std::min(*game::svs_numclients, voice::state::max_speakers);
            if (!base || pointer < base || pointer - base >= count * sizeof(game::client_t) ||
                (pointer - base) % sizeof(game::client_t))
                return -1;
            return static_cast<int>((pointer - base) / sizeof(game::client_t));
        }
        void accepted_join(game::client_t* value, int initial)
        {
            utils::hook::invoke<void>(engine::send_game_state, value, initial);
            std::lock_guard lock(state_mutex);
            const int slot = client_index(value);
            if (zombies() && slot >= 0 && value->header.state >= game::CS_CONNECTED)
            {
                incarnations[slot] = random_id();
                ++joins;
            }
        }
        void server_tick()
        {
            std::lock_guard lock(state_mutex);
            if (!installed || !server)
                return;
            if (!zombies() || !game::SV_Loaded())
            {
                if (server_running)
                    server->reset();
                server_running = false;
                addresses = {};
                incoming.admit({}, voice::inbox::server_capacity);
                if (!zombies())
                    incarnations = {};
                return;
            }
            server_running = true;
            const auto time = now();
            transport::connections current{};
            voice::inbox::sources admitted{};
            const auto* players = *game::svs_clients;
            const auto count = std::min(*game::svs_numclients, voice::state::max_speakers);
            const auto* lobby = game::SV_MainMP_GetServerLobby();
            for (unsigned slot = 0; slot < current.size(); ++slot)
            {
                if (!players || !lobby || slot >= count ||
                    players[slot].header.state < game::CS_CONNECTED)
                {
                    incarnations[slot] = {};
                    addresses[slot] = {};
                    continue;
                }
                if (players[slot].header.state != game::CS_ACTIVE ||
                    players[slot].remoteAddress.type != game::NA_IP || incarnations[slot].empty() ||
                    !lobby->dyn.users[slot].registered)
                    continue;
                const std::string_view guid(
                    players[slot].playerGuid,
                    strnlen(players[slot].playerGuid, sizeof(players[slot].playerGuid)));
                std::uint64_t user{};
                const auto parsed =
                    std::from_chars(guid.data(), guid.data() + guid.size(), user, 16);
                if (guid.empty() || guid.size() > 16 || parsed.ec != std::errc{} ||
                    parsed.ptr != guid.data() + guid.size() || !user ||
                    user != lobby->dyn.users[slot].xuid)
                    continue;
                current[slot] = {user, incarnations[slot], true};
                addresses[slot] = players[slot].remoteAddress;
                admitted[slot] = endpoint(addresses[slot]);
            }
            incoming.admit(admitted, voice::inbox::server_capacity);
            send(server->synchronize(current, time));
            for (const auto& packet : drain(time))
            {
                unsigned source = static_cast<unsigned>(current.size());
                for (unsigned slot = 0; slot < current.size(); ++slot)
                    if (current[slot].active &&
                        endpoint(addresses[slot]) == packet.source)
                    {
                        source = slot;
                        break;
                    }
                std::vector<transport::delivery> output;
                wire::message data;
                if (!wire::decode(packet.bytes, data) ||
                    !server->receive(source, data, static_cast<unsigned>(packet.bytes.size()),
                                     time, output))
                {
                    ++rejected;
                    continue;
                }
                send(output);
            }
        }
        void release_users()
        {
            // Teardown runs before the native session disappears. Only remove
            // registrations created here, still bound to the exact same UID.
            if (session && session->dyn.sessionHandle)
                for (unsigned slot = 0; slot < owned_users.size(); ++slot)
                    if (owned_users[slot] && session->dyn.users[slot].registered &&
                        session->dyn.users[slot].xuid == owned_users[slot])
                        engine::unregister_user(session, slot);
            owned_users = {};
        }
        void reset_client()
        {
            release_users();
            client.reset();
            session = nullptr;
            local_slot = -1;
            local_user = 0;
            game_challenge.clear();
            host = {};
            last_registration_check = 0;
            incoming.admit({}, voice::inbox::client_capacity);
        }
        void mirror_roster(std::uint32_t changed)
        {
            if (!session || !session->dyn.sessionHandle || !client || !client->ready())
                return;
            const int controller = engine::controller_index();
            for (unsigned slot = 0; slot < owned_users.size(); ++slot)
            {
                if (static_cast<int>(slot) == local_slot || !(changed & (1u << slot)))
                    continue;
                const auto& member = client->roster().speakers[slot];
                auto& native = session->dyn.users[slot];
                const bool preserve_mute = member.present && native.registered &&
                                           native.xuid == member.user && native.muted;
                if (owned_users[slot] && native.registered && native.xuid == owned_users[slot])
                    engine::unregister_user(session, slot);
                owned_users[slot] = 0;
                if (!member.present)
                    continue;
                if (native.registered && native.xuid == member.user)
                {
                    if (!native.voiceRegistered)
                        utils::hook::invoke<int>(engine::register_voice, controller, session,
                                                 static_cast<int>(slot));
                    continue;
                }
                // A foreign/local native user in this slot is not ours to replace.
                if (native.registered)
                {
                    ++rejected;
                    continue;
                }
                std::array<char, 128> platform_address{};
                ++registration_attempts;
                game::Session_RegisterRemotePlayer(controller, session, member.user, false,
                                                   static_cast<int>(slot), 1,
                                                   platform_address.data(), &host);
                if (native.registered && native.xuid == member.user)
                {
                    owned_users[slot] = member.user;
                    ++registrations;
                    if (preserve_mute)
                        utils::hook::invoke<void>(engine::mute, session, static_cast<int>(slot));
                }
                else
                    ++registration_failures;
            }
        }
        bool current_connection(game::netadr_s& target)
        {
            const auto* connection = party::get_server_connection_state();
            if (!zombies() || game::Com_IsAnyLocalServerRunning() || !connection ||
                !connection->hostDefined || connection->host.type != game::NA_IP ||
                !game::CL_IsGameClientActive(0) ||
                game::clientUIActives[0].connectionState != game::CA_ACTIVE)
                return false;
            target = connection->host;
            return true;
        }
        void client_tick()
        {
            std::lock_guard lock(state_mutex);
            game::netadr_s target{};
            if (!installed || !current_connection(target))
            {
                reset_client();
                return;
            }
            auto* selected = engine::session();
            const auto* connection = party::get_server_connection_state();
            if (!selected || !selected->dyn.sessionHandle)
            {
                reset_client();
                return;
            }
            const int controller = engine::controller_index();
            const auto user = game::Live_GetXuid(controller);
            const int own = engine::own_slot(controller, selected);
            if (!user || own < 0 || own >= static_cast<int>(voice::state::max_speakers))
            {
                reset_client();
                return;
            }
            if (!client || selected != session || !network::are_addresses_equal(host, target) ||
                game_challenge != connection->challenge || own != local_slot || user != local_user)
            {
                reset_client();
                session = selected;
                host = target;
                local_slot = own;
                local_user = user;
                game_challenge = connection->challenge;
                client = std::make_unique<transport::client>(user, random_id);
            }
            voice::inbox::sources admitted{};
            admitted[0] = endpoint(host);
            incoming.admit(admitted, voice::inbox::client_capacity);
            const auto time = now();
            const bool was_ready = client->ready();
            for (const auto& message : client->tick(time))
                send(host, message);
            if (was_ready && !client->ready())
                release_users();
            for (const auto& packet : drain(time))
            {
                wire::message data;
                if (endpoint(host) != packet.source || !wire::decode(packet.bytes, data))
                {
                    ++rejected;
                    continue;
                }
                const auto result = client->receive(data, static_cast<unsigned>(packet.bytes.size()), time);
                if (!result.accepted)
                {
                    ++rejected;
                    continue;
                }
                if (client->ready() && client->own_slot() != static_cast<unsigned>(local_slot))
                {
                    reset_client();
                    ++rejected;
                    return;
                }
                if (result.changed_slots)
                    mirror_roster(result.changed_slots);
                if (!result.audio)
                    continue;
                const auto& member = client->roster().speakers[data.slot];
                const auto& native = session->dyn.users[data.slot];
                if (!native.registered || !native.voiceRegistered || native.xuid != member.user)
                {
                    ++rejected;
                    continue;
                }
                if (!voice_enabled() || engine::muted(session, data.slot))
                {
                    muted += data.frames.size();
                    continue;
                }
                for (const auto& frame : data.frames)
                {
                    engine::playback(session, data.slot, frame);
                    ++played;
                }
            }
            // Engine initialization may not yet accept the first registration,
            // or may clear it while applying game state. Reconcile only missing
            // current users; a repeated control never resets a healthy stream.
            if (client && client->ready() && time - last_registration_check >= 250)
            {
                last_registration_check = time;
                std::uint32_t missing{};
                for (unsigned slot = 0; slot < owned_users.size(); ++slot)
                {
                    const auto& member = client->roster().speakers[slot];
                    const auto& native = session->dyn.users[slot];
                    if (member.present && static_cast<int>(slot) != local_slot &&
                        (!native.registered || native.xuid != member.user ||
                         !native.voiceRegistered))
                        missing |= 1u << slot;
                }
                if (missing)
                    mirror_roster(missing);
            }
        }
        int queue_encoded(int length, const char* bytes)
        {
            game::netadr_s target{};
            if (!installed)
                return queue_hook.invoke<int>(length, bytes);
            if (!current_connection(target))
            {
                const auto* connection = party::get_server_connection_state();
                if (zombies() && connection && connection->hostDefined &&
                    connection->host.type == game::NA_IP && !game::Com_IsAnyLocalServerRunning())
                    return length;
                return queue_hook.invoke<int>(length, bytes);
            }
            // Replace unroutable native P2P only in a connected external CP game.
            // The existing native capture path has already applied PTT/threshold.
            std::lock_guard lock(state_mutex);
            ++encoded;
            if (!client || !client->ready() || !voice_enabled() ||
                !network::are_addresses_equal(host, target))
                return length;
            if (!bytes || length <= 0 || length > static_cast<int>(wire::max_frame_bytes))
            {
                ++rejected;
                return length;
            }
            send(host, client->audio(std::string_view(bytes, length)));
            ++sent;
            return length;
        }
        void status()
        {
            std::lock_guard lock(state_mutex);
            unsigned roster_mask{}, native_mask{};
            if (client && session)
                for (unsigned slot = 0; slot < owned_users.size(); ++slot)
                {
                    if (client->roster().speakers[slot].present)
                        roster_mask |= 1u << slot;
                    if (session->dyn.users[slot].registered &&
                        session->dyn.users[slot].voiceRegistered)
                        native_mask |= 1u << slot;
                }
            console::info(
                "[voice-relay] version=2 installed=%d dedicated=%d ready=%d slot=%d encoded=%llu "
                "sent=%llu relayed=%llu playback_calls=%llu rejected=%llu muted=%llu "
                "accepted_joins=%llu registrations=%llu registration_attempts=%llu "
                "registration_failures=%llu roster_mask=%u native_mask=%u\n",
                installed.load(), game::environment::is_dedi(), client && client->ready(),
                local_slot, encoded.load(), sent.load(), relayed.load(), played.load(),
                rejected.load(), muted.load(), joins.load(), registrations.load(),
                registration_attempts.load(), registration_failures.load(), roster_mask,
                native_mask);
        }
    }
    std::uint64_t encoded_frames()
    {
        return encoded.load();
    }
    class component final : public component_interface
    {
    public:
        void post_unpack() override
        {
            if (!utils::flags::has_flag("iw7-voice-relay"))
                return;
            if (!engine::supported())
            {
                console::error(
                    "[voice-relay] Unsupported native signatures; component disabled. Use "
                    "the supported retail binary.\n");
                return;
            }
            network::on(command_name, receive);
            scripting::on_shutdown([](bool, bool post) {
                if (post)
                    return;
                std::lock_guard lock(state_mutex);
                reset_client();
                addresses = {};
                server_running = false;
                // Existing accepted game connections can survive map load.
                // Rotate the server epoch, retaining their incarnation until
                // native disconnect or the next accepted join replaces it.
                if (server)
                    server->reset();
            });
            scheduler::once(
                [] {
                    std::lock_guard lock(state_mutex);
                    if (game::environment::is_dedi())
                    {
                        server = std::make_unique<transport::server>(random_id);
                        utils::hook::call(engine::accepted_join_call, accepted_join);
                        scheduler::loop(server_tick, scheduler::server, 10ms);
                    }
                    else
                    {
                        queue_hook.create(engine::queue, queue_encoded);
                        scheduler::loop(client_tick, scheduler::main, 10ms);
                    }
                    installed = true;
                    console::info("[voice-relay] Opt-in generic Zombies transport v2 installed; "
                                  "matching clients/server required.\n");
                },
                scheduler::main);
            command::add("voice_relay_status", status);
            if (utils::flags::has_flag("voice-relay-diagnostics"))
                scheduler::loop(status, scheduler::main, 10s);
        }
    };
}
REGISTER_COMPONENT(voice_relay::component)
