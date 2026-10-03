#include <std_include.hpp>
#include <cstdlib>
#include "loader/component_loader.hpp"
#include "game/game.hpp"
#include "network.hpp"
#include "party.hpp"
#include "scheduler.hpp"
#include "command.hpp"
#include "console/console.hpp"
#include <utils/hook.hpp>
#include <utils/cryptography.hpp>
#include <utils/flags.hpp>
#include <cmath>
#include "paris_voice_protocol.hpp"

namespace paris_voice
{
    namespace
    {
        // Config "set" may create a string dvar. Read only the union member
        // matching its type, so string "0" cannot be mistaken for its pointer.
        bool read_module_enabled(const game::dvar_t* setting)
        {
            if (!setting) return true;
            switch (setting->type)
            {
            case game::DVAR_TYPE_BOOL: return setting->current.enabled;
            case game::DVAR_TYPE_INT: return setting->current.integer != 0;
            case game::DVAR_TYPE_STRING:
            {
                const auto* text = setting->current.string;
                if (!text) return false;
                char* end = nullptr;
                const auto value = std::strtol(text, &end, 10);
                return end != text && *end == '\0' && value != 0;
            }
            default: return false;
            }
        }

        bool module_enabled()
        {
            const auto* setting = game::Dvar_FindVar("paris_mod_voice");
            const bool enabled = read_module_enabled(setting);
            static int previous = -1;
            if (previous != static_cast<int>(enabled))
            {
                previous = static_cast<int>(enabled);
                console::info("[paris-voice] Module enabled=%d; dvar_type=%u.\n",
                    previous, setting ? static_cast<unsigned>(setting->type) : 255u);
            }
            return enabled;
        }

        namespace wire = protocol;

        constexpr const char* transport = "parisvoice";
        constexpr std::uint64_t timeout_ms = 15000;
        constexpr std::size_t inbox_limit = 128;
        utils::hook::detour queue_voice_hook;
        utils::hook::detour decode_voice_hook;
        utils::hook::detour enqueue_voice_hook;
        utils::hook::detour capture_voice_hook;
        std::mutex inbox_mutex, state_mutex;
        struct incoming { game::netadr_s from; wire::packet data; std::uint64_t time; unsigned bytes; };
        std::vector<incoming> inbox;
        struct counters
        {
            std::atomic<std::uint64_t> captured{}, sent{}, relayed{}, decoded{}, pcm_bytes{}, rejected{}, muted{};
            std::atomic<std::uint64_t> queued_bytes{}, queue_errors{};
            std::atomic<std::uint64_t> capture_blocks{};
        } stats;
        struct server_peer
        {
            game::netadr_s address{};
            std::string identity;
            std::uint64_t token{}, challenge{}, seen{}, hello_time{};
            wire::replay_window replay;
            wire::rate_limit rate;
        };
        std::array<server_peer, wire::slots> peers{};
        struct client_state
        {
            game::netadr_s host{};
            bool connected{};
            std::uint64_t token{}, challenge{}, last_hello{}, last_ready{};
            std::uint32_t sequence{};
            unsigned char own_slot{};
            std::array<wire::replay_window, wire::slots> replay{};
            std::array<wire::rate_limit, wire::slots> rate{};
        } client;
        bool local_test_probed{};
        bool local_test_connected{};
        bool local_test_gates{};
        int relay_test_frame{};
        std::uint64_t relay_test_begin{};

        std::uint64_t now() { return GetTickCount64(); }
        std::uint64_t random_token()
        {
            std::uint64_t value{};
            do { utils::cryptography::random::get_data(&value, sizeof(value)); } while (!value);
            return value;
        }
        bool zombies() { return game::Com_GameMode_GetActiveGameMode() == game::GAME_MODE_CP; }
        bool enabled()
        {
            const auto* dvar = game::Dvar_FindVar("cl_voice");
            return dvar && dvar->current.enabled;
        }
        bool audio_initialized() { return *reinterpret_cast<const int*>(0x1477A012C) != 0; }
        int decode_voice(const char* data, int length, short* pcm, int samples)
        {
            const int result = decode_voice_hook.invoke<int>(data, length, pcm, samples);
            if (result > 0) { ++stats.decoded; stats.pcm_bytes += result; }
            return result;
        }
        int enqueue_voice(void* buffer, const short* pcm, int bytes)
        {
            const int result = enqueue_voice_hook.invoke<int>(buffer, pcm, bytes);
            if (result > 0) stats.queued_bytes += result;
            else if (result < 0) ++stats.queue_errors;
            return result;
        }
        int capture_voice(void* buffer)
        {
            ++stats.capture_blocks;
            return capture_voice_hook.invoke<int>(buffer);
        }
        void ensure_audio()
        {
            if (!audio_initialized()) utils::hook::invoke<void>(0x140D597C0);
        }
        bool same(const game::netadr_s& a, const game::netadr_s& b)
        {
            return network::are_addresses_equal(a, b);
        }
        void send(const game::netadr_s& to, const wire::packet& p)
        {
            const auto bytes = wire::encode(p);
            if (!bytes.empty()) network::send(to, transport, bytes);
        }
        std::vector<incoming> drain()
        {
            std::lock_guard lock(inbox_mutex);
            std::vector<incoming> result;
            result.swap(inbox); return result;
        }
        void receive(const game::netadr_s& from, const std::string_view& data)
        {
            // Parse before touching engine memory; at most 1200 bytes/10 frames.
            wire::packet p;
            if (from.type != game::NA_IP || !wire::decode(data, p)) { ++stats.rejected; return; }
            std::lock_guard lock(inbox_mutex);
            if (inbox.size() >= inbox_limit) { ++stats.rejected; return; }
            inbox.push_back({from, std::move(p), now(), static_cast<unsigned>(data.size())});
        }
        void server_tick()
        {
            auto messages = drain();
            std::lock_guard lock(state_mutex);
            const bool enabled = module_enabled();
            if (!zombies() || !game::SV_Loaded() || !enabled) { peers = {}; return; }
            const auto* clients = *game::svs_clients;
            const auto count = std::min(*game::svs_numclients, wire::slots);
            const auto time = now();
            for (unsigned i = 0; i < wire::slots; ++i)
            {
                auto& p = peers[i];
                if (!clients || i >= count || clients[i].header.state != game::CS_ACTIVE || clients[i].remoteAddress.type != game::NA_IP)
                { p = {}; continue; }
                const auto& c = clients[i];
                const std::string identity(c.playerGuid, strnlen(c.playerGuid, sizeof(c.playerGuid)));
                if (!p.identity.empty() && (p.identity != identity || !same(p.address, c.remoteAddress))) p = {};
                if (p.token && time - p.seen > timeout_ms) p = {};
                p.address = c.remoteAddress; p.identity = identity;
            }
            for (auto& msg : messages)
            {
                if (time - msg.time > 500) { ++stats.rejected; continue; }
                unsigned slot = count;
                for (unsigned i = 0; clients && i < count; ++i)
                    if (clients[i].header.state == game::CS_ACTIVE && same(clients[i].remoteAddress, msg.from)) { slot = i; break; }
                if (slot >= count) { ++stats.rejected; continue; }
                auto& p = peers[slot];
                if (msg.data.type == wire::kind::hello)
                {
                    if (p.hello_time && time - p.hello_time < 500) { ++stats.rejected; continue; }
                    p.hello_time = time;
                    if (!p.token || p.challenge != msg.data.token)
                    {
                        p.token = random_token(); p.challenge = msg.data.token; p.replay = {}; p.rate = {};
                    }
                    p.seen = time;
                    wire::packet reply; reply.type = wire::kind::ready; reply.token = p.token;
                    reply.challenge = p.challenge; reply.speaker = static_cast<unsigned char>(slot);
                    send(p.address, reply); continue;
                }
                if ((msg.data.type != wire::kind::audio && msg.data.type != wire::kind::probe) || !p.token || msg.data.token != p.token ||
                    msg.data.speaker != slot || !p.replay.accept(msg.data.sequence) ||
                    !p.rate.accept(static_cast<unsigned>(msg.data.frames.size()), msg.bytes, time))
                { ++stats.rejected; continue; }
                p.seen = time;
                // Explicit synthetic calibration returns only to its connected sender.
                // It never relays test audio to other players and cannot amplify a datagram.
                if (msg.data.type == wire::kind::probe) { send(p.address, msg.data); continue; }
                for (unsigned i = 0; i < count; ++i)
                {
                    const auto& recipient = peers[i];
                    if (i == slot || !recipient.token || time - recipient.seen > timeout_ms) continue;
                    msg.data.token = recipient.token;
                    send(recipient.address, msg.data); stats.relayed += msg.data.frames.size();
                }
            }
        }
        bool client_connection(game::netadr_s& host)
        {
            const auto* connection = party::get_server_connection_state();
            if (!zombies() || !connection || !connection->hostDefined || connection->host.type != game::NA_IP ||
                !game::CL_IsGameClientActive(0) || game::clientUIActives[0].connectionState != game::CA_ACTIVE) return false;
            host = connection->host; return true;
        }
        void client_tick()
        {
            auto messages = drain();
            std::lock_guard lock(state_mutex);
            game::netadr_s host{};
            if (!client_connection(host)) { client = {}; return; }
            const auto time = now();
            if (!client.connected || !same(client.host, host))
            {
                client = {}; client.host = host; client.connected = true; client.challenge = random_token();
            }
            if (client.token && time - client.last_ready > timeout_ms)
            {
                client.token = 0; client.challenge = random_token(); client.replay = {}; client.sequence = 0;
            }
            if (time - client.last_hello >= (client.token ? 5000 : 1000))
            {
                wire::packet hello; hello.type = wire::kind::hello; hello.token = client.challenge;
                send(client.host, hello); client.last_hello = time;
            }
            for (const auto& msg : messages)
            {
                if (time - msg.time > 500 || !same(msg.from, client.host)) { ++stats.rejected; continue; }
                const auto& p = msg.data;
                if (p.type == wire::kind::ready && p.challenge == client.challenge)
                {
                    if (p.token != client.token)
                    {
                        client.replay = {}; client.rate = {}; client.sequence = 0;
                        console::info("[paris-voice] Zombies relay ready (protocol 1, slot %u)\n", p.speaker);
                    }
                    client.token = p.token; client.own_slot = p.speaker; client.last_ready = time;
                    ensure_audio(); continue;
                }
                if ((p.type != wire::kind::audio && p.type != wire::kind::probe) || !client.token || p.token != client.token ||
                    (p.type == wire::kind::audio && p.speaker == client.own_slot) || (p.type == wire::kind::probe && p.speaker != client.own_slot) ||
                    !client.replay[p.speaker].accept(p.sequence) ||
                    !client.rate[p.speaker].accept(static_cast<unsigned>(p.frames.size()), msg.bytes, time))
                { ++stats.rejected; continue; }
                if (!enabled()) { ++stats.muted; continue; }
                ensure_audio();
                const auto samples = *reinterpret_cast<const int*>(0x145D5C6DC);
                if (!audio_initialized() || samples <= 0 || samples > 4096) { ++stats.rejected; continue; }
                const auto* lobby = game::Lobby_GetPartyData();
                const auto* session = lobby ? lobby->session : nullptr;
                // Engine scoreboard mute and platform/privacy checks remain in force.
                if (session && utils::hook::invoke<bool>(0x14037BBA0, session, static_cast<int>(p.speaker)))
                { ++stats.muted; continue; }
                for (const auto& frame : p.frames)
                {
                    const int result = utils::hook::invoke<int>(0x140D59620, session, static_cast<int>(p.speaker),
                        frame.data(), static_cast<int>(frame.size()), 0);
                    if (result <= 0) ++stats.rejected;
                }
            }
        }
        void codec_selftest()
        {
            if (game::environment::is_dedi()) { console::warn("[paris-voice] Codec test requires a rendering client; dedicated server has no audio devices.\n"); return; }
            ensure_audio();
            const int samples = utils::hook::invoke<int>(0x140B79440);
            if (!audio_initialized() || samples <= 0 || samples > 4096)
            { console::error("[paris-voice] Codec selftest FAIL: audio initialization/frame size.\n"); return; }
            std::vector<short> input(samples); std::array<char, 256> encoded{}; std::array<short, 8192> decoded{};
            double energy{}; int frames{};
            for (int n = 0; n < 20; ++n)
            {
                for (int i = 0; i < samples; ++i) input[i] = static_cast<short>(10000 * std::sin((n * samples + i) * 0.3455751919));
                const int length = utils::hook::invoke<int>(0x140B794F0, input.data(), encoded.data(), 254);
                if (length <= 0 || length > 254) break;
                const int size = utils::hook::invoke<int>(0x140B79310, encoded.data(), length, decoded.data(), samples);
                if (size != samples * 2) break;
                for (int i = 0; i < samples; ++i) energy += std::abs(static_cast<double>(decoded[i]));
                ++frames;
            }
            console::info("[paris-voice] Codec selftest %s: frames=%d samples=%d pcm_energy=%.0f (synthetic, no microphone/network transmission).\n",
                frames == 20 && energy > 10000 ? "PASS" : "FAIL", frames, samples, energy);
        }
        void network_selftest()
        {
            if (game::environment::is_dedi()) return;
            std::lock_guard lock(state_mutex);
            if (!client.token) { console::warn("[paris-voice] Network selftest requires a ready Zombies relay.\n"); return; }
            ensure_audio();
            const int samples = utils::hook::invoke<int>(0x140B79440);
            if (samples <= 0 || samples > 4096) return;
            std::vector<short> input(samples); std::array<char, 256> buffer{};
            wire::packet p; p.type = wire::kind::probe; p.token = client.token; p.speaker = client.own_slot;
            for (int n = 0; n < 20; ++n)
            {
                for (int i = 0; i < samples; ++i) input[i] = static_cast<short>(7000 * std::sin((n * samples + i) * 6.283185307179586 * 440 / *reinterpret_cast<const int*>(0x141BB2CA0)));
                const int length = utils::hook::invoke<int>(0x140B794F0, input.data(), buffer.data(), 254);
                if (length <= 0 || length > 254) return;
                p.frames.emplace_back(buffer.data(), length);
                if (p.frames.size() == 4)
                {
                    p.sequence = ++client.sequence; send(client.host, p); p.frames.clear();
                }
            }
            console::info("[paris-voice] Network selftest sent 20 synthetic frames; only this client receives the calibration tone.\n");
        }
        void relay_test_tick()
        {
            if (relay_test_frame >= 1000) return;
            {
                std::lock_guard lock(state_mutex);
                if (!client.token || !client.connected || client.host.ip[0] != 127 || !game::CL_IsGameClientActive(0)) return;
            }
            if (!relay_test_begin) relay_test_begin = now() + 60000;
            if (now() < relay_test_begin) return;
            const int samples = utils::hook::invoke<int>(0x140B79440);
            if (samples <= 0 || samples > 4096) return;
            std::vector<short> input(samples); std::array<char, 256> buffer{};
            for (int i = 0; i < samples; ++i) input[i] = static_cast<short>(7000 * std::sin((relay_test_frame * samples + i) * 6.283185307179586 * 440 / *reinterpret_cast<const int*>(0x141BB2CA0)));
            if (utils::flags::has_flag("paris-voice-capture-test"))
            {
                // Development-only post-device PCM injection. Exercise native gain,
                // threshold, encoder and our actual queue hook without recording speech.
                struct capture_buffer { short* pcm; int bytes, samples, sample_bytes; int reserved[3]; int consumed; };
                capture_buffer data{input.data(), samples * 2, samples, 2, {}, 0};
                auto* ptt = *reinterpret_cast<game::dvar_t**>(0x1421EF7A0);
                if (!ptt) return;
                const bool saved = ptt->current.enabled;
                ptt->current.enabled = false;
                capture_voice(&data);
                ptt->current.enabled = saved;
                ++relay_test_frame;
                return;
            }
            const int length = utils::hook::invoke<int>(0x140B794F0, input.data(), buffer.data(), 254);
            if (length <= 0 || length > 254) return;
            std::lock_guard lock(state_mutex);
            wire::packet p; p.type = wire::kind::audio; p.token = client.token; p.speaker = client.own_slot;
            p.sequence = ++client.sequence; p.frames.emplace_back(buffer.data(), length);
            send(client.host, p); ++stats.sent; ++relay_test_frame;
            if (relay_test_frame == 1000) console::info("[paris-voice] Local relay fixture sent 1000 synthetic frames on the normal audio path.\n");
        }
        void gate_selftest()
        {
            if (game::environment::is_dedi() || local_test_gates) return;
            game::netadr_s host{};
            if (!client_connection(host) || host.ip[0] != 127) return;
            unsigned own{};
            { std::lock_guard lock(state_mutex); if (!client.token) return; own = client.own_slot; }
            auto* lobby = game::Lobby_GetPartyData();
            auto* session = lobby ? lobby->session : nullptr;
            if (!session) return;
            int speaker = -1;
            for (unsigned i = 0; i < wire::slots; ++i)
                if (i != own && session->dyn.users[i].registered) { speaker = static_cast<int>(i); break; }
            if (speaker < 0) return; // Wait until the other test client has joined.
            local_test_gates = true;
            auto* voice = const_cast<game::dvar_t*>(game::Dvar_FindVar("cl_voice"));
            auto* ptt = *reinterpret_cast<game::dvar_t**>(0x1421EF7A0);
            const int samples = utils::hook::invoke<int>(0x140B79440);
            if (!voice || !ptt || samples <= 0 || samples > 4096) return;
            std::vector<short> pcm(samples, 10000);
            struct capture_buffer { short* pcm; int bytes, samples, sample_bytes; int reserved[3]; int consumed; };
            const bool saved_voice = voice->current.enabled, saved_ptt = ptt->current.enabled;
            const auto before = stats.sent.load();
            capture_buffer data{pcm.data(), samples * 2, samples, 2, {}, 0};
            voice->current.enabled = false; capture_voice(&data);
            const bool disabled_pass = !enabled() && stats.sent.load() == before;
            voice->current.enabled = true; ptt->current.enabled = true;
            const bool key_released = !utils::hook::invoke<bool>(0x14036FE40, 0);
            data.consumed = 0; capture_voice(&data);
            const bool ptt_pass = key_released && stats.sent.load() == before;
            voice->current.enabled = saved_voice; ptt->current.enabled = saved_ptt;
            const bool saved_mute = session->dyn.users[speaker].muted;
            const bool eligible = utils::hook::invoke<bool>(0x14037B3E0, session, speaker);
            session->dyn.users[speaker].muted = false;
            utils::hook::invoke<void>(0x14037C8A0, session, speaker);
            const bool mute_pass = utils::hook::invoke<bool>(0x14037BBA0, session, speaker);
            utils::hook::invoke<void>(0x14037C8A0, session, speaker);
            const bool unmute_pass = !utils::hook::invoke<bool>(0x14037BBA0, session, speaker);
            session->dyn.users[speaker].muted = saved_mute;
            console::info("[paris-voice] Native gates %s: disabled=%d released_ptt=%d mute_eligible=%d mute=%d unmute=%d (temporary settings restored).\n",
                disabled_pass && ptt_pass && eligible && mute_pass && unmute_pass ? "PASS" : "FAIL",
                disabled_pass, ptt_pass, eligible, mute_pass, unmute_pass);
        }
        int queue_voice(int length, const char* data)
        {
            // Native capture already applies PTT, mic mute, threshold and cl_voice.
            // Send each encoded frame promptly instead of the legacy 200 ms party batch.
            game::netadr_s host{};
            if (!client_connection(host))
            {
                const auto* connection = party::get_server_connection_state();
                // During a connected Zombies map load, discard stale frames rather
                // than filling the legacy online-party queue with unroutable audio.
                if (zombies() && connection && connection->hostDefined && connection->host.type == game::NA_IP) return length;
                return queue_voice_hook.invoke<int>(length, data);
            }
            std::lock_guard lock(state_mutex);
            ++stats.captured;
            if (!client.connected || !same(client.host, host) || !client.token || !enabled()) return length;
            if (!data || length <= 0 || length > static_cast<int>(wire::max_frame_bytes)) { ++stats.rejected; return length; }
            wire::packet p; p.type = wire::kind::audio; p.token = client.token; p.sequence = ++client.sequence;
            p.speaker = client.own_slot; p.frames.emplace_back(data, length);
            send(client.host, p); ++stats.sent; return length;
        }
        void status()
        {
            std::lock_guard lock(state_mutex);
            unsigned ready{}; for (const auto& p : peers) if (p.token) ++ready;
            console::info("[paris-voice] v1 zombies=%d dedicated=%d ready=%u client_ready=%d audio_init=%d capture=%llu sent=%llu relayed=%llu decoded=%llu pcm_bytes=%llu rejected=%llu muted=%llu\n",
                zombies(), game::environment::is_dedi(), ready, client.token != 0,
                audio_initialized(), stats.captured.load(), stats.sent.load(), stats.relayed.load(), stats.decoded.load(), stats.pcm_bytes.load(), stats.rejected.load(), stats.muted.load());
            if (!game::environment::is_dedi()) console::info("[paris-voice] client mode=%d connection=%d game_active=%d mic_running=%d cl_voice=%d\n",
                game::Com_GameMode_GetActiveGameMode(), game::clientUIActives[0].connectionState,
                game::CL_IsGameClientActive(0), *reinterpret_cast<const unsigned char*>(0x1477A0158) != 0, enabled());
            if (!game::environment::is_dedi())
            {
                unsigned playing{};
                const auto buffers = reinterpret_cast<const unsigned char* const*>(0x1477A01C0);
                for (unsigned i = 0; i < wire::slots; ++i)
                    if (buffers[i] && *reinterpret_cast<const int*>(buffers[i] + 0x44)) ++playing;
                console::info("[paris-voice] playback ds_init=%d rate=%d start_bytes=%d playing=%u queued_bytes=%llu queue_errors=%llu\n",
                    *reinterpret_cast<const unsigned char*>(0x145D5C728) != 0,
                    *reinterpret_cast<const int*>(0x141BB2CA0), *reinterpret_cast<const int*>(0x141BB2C90),
                    playing, stats.queued_bytes.load(), stats.queue_errors.load());
                console::info("[paris-voice] native capture callbacks=%llu\n", stats.capture_blocks.load());
                unsigned registered{};
                const auto* lobby = game::Lobby_GetPartyData();
                if (lobby && lobby->session)
                    for (const auto& user : lobby->session->dyn.users) if (user.registered) ++registered;
                console::info("[paris-voice] native session registered_players=%u\n", registered);
            }
        }
    }
    class component final : public component_interface
    {
    public:
        void post_unpack() override
        {
            scheduler::once([] { game::Dvar_RegisterBool("paris_voice_available", true, 0, "Voice transport installed; matching clients required"); }, scheduler::main);
            network::on(transport, receive);
            command::add("paris_voice_status", status);
            command::add("paris_voice_selftest", codec_selftest);
            command::add("paris_voice_network_test", network_selftest);
            command::add("paris_voice_gate_selftest", gate_selftest);
            if (utils::flags::has_flag("paris-voice-diagnostics")) scheduler::loop(status, scheduler::main, 10s);
            if (game::environment::is_dedi()) scheduler::loop(server_tick, scheduler::server, 10ms);
            else
            {
                // The lab uses the connect fixture without opening custom
                // microphone/output sessions or emitting calibration tones.
                if (!utils::flags::has_flag("paris-isolated-lab"))
                {
                    queue_voice_hook.create(0x14037D960, queue_voice);
                    decode_voice_hook.create(0x140B79310, decode_voice);
                    enqueue_voice_hook.create(0x140B79B60, enqueue_voice);
                    capture_voice_hook.create(0x140B79D30, capture_voice);
                    scheduler::loop(client_tick, scheduler::main, 10ms);
                }
                if (utils::flags::has_flag("paris-voice-selftest")) scheduler::once(codec_selftest, scheduler::main, 20s);
                if (utils::flags::has_flag("paris-voice-local-test"))
                {
                    scheduler::loop([]
                    {
                        if (local_test_connected) return;
                        if (!zombies()) { game::Com_GameMode_SetDesiredGameMode(game::GAME_MODE_CP); return; }
                        if (game::Live_SyncOnlineDataFlags(0) != 0) return;
                        game::netadr_s target{};
                        const auto fixture_port = utils::flags::has_flag("paris-isolated-lab") ? 27116 : 27016;
                        target.type = game::NA_IP; target.ip[0] = 127; target.ip[3] = 1; target.port = htons(static_cast<unsigned short>(fixture_port));
                        console::info("[paris-voice] Local development fixture connecting to UDP %d (mode %d).\n", fixture_port, game::Com_GameMode_GetActiveGameMode());
                        local_test_connected = true;
                        party::connect(target);
                    }, scheduler::main, 1s);
                    if (utils::flags::has_flag("paris-voice-relay-test")) scheduler::loop(relay_test_tick, scheduler::main, 20ms);
                    if (utils::flags::has_flag("paris-voice-gate-test")) scheduler::loop(gate_selftest, scheduler::main, 1s);
                    scheduler::loop([]
                    {
                        bool ready{};
                        { std::lock_guard lock(state_mutex); ready = client.token != 0; }
                        if (ready && !local_test_probed) { local_test_probed = true; network_selftest(); }
                    }, scheduler::main, 1s);
                    scheduler::once([] { game::Com_Quit_f(); }, scheduler::main, 300s);
                }
            }
            console::info("[paris-voice] Native Zombies relay v1 installed; every participant needs this client build.\n");
        }
    };
}
REGISTER_COMPONENT(paris_voice::component)
