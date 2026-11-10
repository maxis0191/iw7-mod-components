#include <std_include.hpp>
#include "loader/component_loader.hpp"
#include "game/game.hpp"
#include "network.hpp"
#include "scheduler.hpp"
#include "console/console.hpp"
#include "gsc/script_extension.hpp"
#include <utils/flags.hpp>
#include <utils/io.hpp>
#include <utils/hook.hpp>
#include <utils/cryptography.hpp>
#include <format>
#include <atomic>
#include <cstring>
#include "command.hpp"
#include "party.hpp"
#include "paris_test_safety.hpp"
#include "agent_scenario.hpp"
#include "paris_model_diagnostics.hpp"

namespace paris_test_fixture
{
    namespace
    {
        struct protected_player { std::string identity; game::netadr_s address{}; bool safety_failed{}; std::string agent_nonce; std::uint64_t agent_probe{}; };
        std::array<protected_player, 18> protected_players{};
        std::mutex safety_mutex;
        std::uint64_t script_inactivity_suppressed{};
        bool private_fixture()
        {
            const auto* password = game::Dvar_FindVar("g_password");
            const auto* lan = game::Dvar_FindVar("sv_lanOnly");
            return game::environment::is_dedi() && utils::flags::has_flag("paris-server-test") &&
                game::Com_GameMode_GetActiveGameMode() == game::GAME_MODE_CP &&
                lan && lan->type == game::DVAR_TYPE_BOOL && lan->current.enabled &&
                password && password->type == game::DVAR_TYPE_STRING && password->current.string && *password->current.string;
        }
        bool loopback(const game::netadr_s& address)
        {
            return address.type == game::NA_LOOPBACK ||
                (address.type == game::NA_IP && address.ip[0] == 127 && address.ip[1] == 0 && address.ip[2] == 0 && address.ip[3] == 1);
        }
        game::dvar_t* engine_inactivity() { return *reinterpret_cast<game::dvar_t**>(0x145C9E558); }
        bool bound_player(unsigned slot)
        {
            if (!private_fixture() || slot >= protected_players.size() || protected_players[slot].identity.empty()) return false;
            const auto* clients = *game::svs_clients;
            if (!clients || slot >= *game::svs_numclients || clients[slot].header.state < game::CS_CONNECTED) return false;
            const auto& c = clients[slot];
            return loopback(c.remoteAddress) && network::are_addresses_equal(c.remoteAddress, protected_players[slot].address) &&
                protected_players[slot].identity == std::string(c.playerGuid, strnlen(c.playerGuid, sizeof(c.playerGuid))) &&
                game::g_entities[slot].client;
        }
        bool refresh_protection(unsigned slot)
        {
            const auto* cheats = game::Dvar_FindVar("sv_cheats");
            auto* inactivity = engine_inactivity();
            if (!bound_player(slot) || protected_players[slot].safety_failed) return false;
            if (!cheats || cheats->type != game::DVAR_TYPE_BOOL || cheats->current.enabled ||
                !inactivity || inactivity->type != game::DVAR_TYPE_INT)
            {
                protected_players[slot].safety_failed = true;
                console::error("[Paris test protection failure] slot=%u; tick_ms=%llu; reason=invalid_safety_dvars\n", slot, GetTickCount64());
                return false;
            }
            game::g_entities[slot].flags |= 1;
            game::Dvar_SetInt(inactivity, 0);
            const bool safe = (game::g_entities[slot].flags & 1) != 0 && inactivity->current.integer == 0;
            if (!safe) protected_players[slot].safety_failed = true;
            return safe;
        }
        bool protect_player(game::scr_entref_t ent)
        {
            std::lock_guard lock(safety_mutex);
            if (!private_fixture() || ent.classnum || ent.entnum >= protected_players.size()) return false;
            const auto* clients = *game::svs_clients;
            if (!clients || ent.entnum >= *game::svs_numclients || clients[ent.entnum].header.state < game::CS_CONNECTED) return false;
            const auto& client = clients[ent.entnum];
            if (!loopback(client.remoteAddress) || !game::g_entities[ent.entnum].client) return false;
            const std::string identity(client.playerGuid, strnlen(client.playerGuid, sizeof(client.playerGuid)));
            if (identity.empty()) return false;
            // Repeated calls cannot clear a failure observed by the 100 ms
            // watcher. Only a newly bound connection starts a new safety record.
            if (!bound_player(ent.entnum)) protected_players[ent.entnum] = {identity, client.remoteAddress, false, {}, 0};
            return refresh_protection(ent.entnum);
        }
        std::string protection_snapshot(game::scr_entref_t ent)
        {
            std::lock_guard lock(safety_mutex);
            const bool valid_slot = !ent.classnum && ent.entnum < protected_players.size();
            const bool bound = valid_slot && bound_player(ent.entnum);
            const bool godmode = bound && (game::g_entities[ent.entnum].flags & 1) != 0;
            const auto* inactivity_dvar = game::environment::is_dedi() ? engine_inactivity() : nullptr;
            const auto inactivity = inactivity_dvar && inactivity_dvar->type == game::DVAR_TYPE_INT ? inactivity_dvar->current.integer : -1;
            const auto* cheats_dvar = game::Dvar_FindVar("sv_cheats");
            const auto cheats = cheats_dvar && cheats_dvar->type == game::DVAR_TYPE_BOOL ? static_cast<int>(cheats_dvar->current.enabled) : -1;
            const bool failed = valid_slot && protected_players[ent.entnum].safety_failed;
            const bool protected_now = bound && godmode && inactivity == 0 && cheats == 0 && !failed;
            return std::format("slot={}; tick_ms={}; protected={}; bound={}; godmode={}; inactivity={}; cheats={}; failed={}",
                ent.entnum, GetTickCount64(), static_cast<int>(protected_now), static_cast<int>(bound),
                static_cast<int>(godmode), inactivity, cheats, static_cast<int>(failed));
        }
        void maintain_protection()
        {
            std::lock_guard lock(safety_mutex);
            for (unsigned slot = 0; slot < protected_players.size(); ++slot)
            {
                if (!bound_player(slot)) { protected_players[slot] = {}; continue; }
                refresh_protection(slot);
            }
        }
        void safety_status()
        {
            std::lock_guard lock(safety_mutex);
            unsigned count{};
            for (unsigned slot = 0; slot < protected_players.size(); ++slot)
                if (bound_player(slot) && !protected_players[slot].safety_failed && (game::g_entities[slot].flags & 1)) ++count;
            const auto* inactivity = engine_inactivity();
            console::info("[Paris test safety] protected=%u native_inactivity=%d script_inactivity_suppressed=%llu tick_ms=%llu\n",
                count, inactivity && inactivity->type == game::DVAR_TYPE_INT ? inactivity->current.integer : -1,
                script_inactivity_suppressed, GetTickCount64());
            const auto* lan = game::Dvar_FindVar("sv_lanOnly");
            console::info("[Paris test privacy] private=%d lan_only=%d heartbeat_suppressed=1\n",
                static_cast<int>(private_fixture()),
                lan && lan->type == game::DVAR_TYPE_BOOL ? static_cast<int>(lan->current.enabled) : -1);
        }
        bool connect_pending = false;
        bool vote_witness_running = false;
        void vote_binding(const char* name, bool down);
        std::string agent_nonce()
        {
            std::array<unsigned char, 16> bytes{};
            utils::cryptography::random::get_data(bytes.data(), bytes.size());
            constexpr char digits[] = "0123456789abcdef";
            std::string result;
            for (const auto b : bytes) { result += digits[b >> 4]; result += digits[b & 15]; }
            return result;
        }
        // Never call the upstream PRNG from a global initializer: its state is
        // constructed in another translation unit and CRT order is unspecified.
        iw7::agent::lab_session agent_runtime;
        struct agent_packet { game::netadr_s address{}; std::string nonce, generation, map; std::uint64_t probe{}; bool safe{}; };
        std::mutex agent_packet_mutex;
        std::array<agent_packet, 4> agent_queries{};
        agent_packet agent_reply{};
        iw7::agent::safety agent_safety{};
        std::string agent_generation;
        std::atomic<DWORD> client_protection_main_tid{0};
        std::string agent_connection_challenge;
        std::uint64_t agent_last_probe{}, agent_last_ack{};
        std::uint64_t rig_scene_arm{}; // Accepted ARM identity; no new command or scenario API.
        bool agent_binding_failed{};
        bool agent_read_key(const iw7::agent::key_probe& probe, iw7::agent::movement_key_snapshot& state)
        {
            std::array<unsigned char, 10> prefix{0x48, 0x69, 0xCF, 0x60, 0x04, 0x00, 0x00, 0x48, 0x8D, 0x05};
            if (probe.lea_rdi) prefix.back() = 0x3D;
            if (std::memcmp(reinterpret_cast<const void*>(probe.code), prefix.data(), prefix.size())) return false;
            std::int32_t displacement{};
            std::memcpy(&displacement, reinterpret_cast<const void*>(probe.code + prefix.size()), sizeof(displacement));
            if (displacement != probe.displacement || probe.code + 14 + displacement != probe.address) return false;
            MEMORY_BASIC_INFORMATION region{};
            if (VirtualQuery(reinterpret_cast<const void*>(probe.address), &region, sizeof(region)) != sizeof(region) ||
                region.State != MEM_COMMIT || (region.Protect & (PAGE_GUARD | PAGE_NOACCESS)) ||
                !(region.Protect & (PAGE_READONLY | PAGE_READWRITE | PAGE_WRITECOPY | PAGE_EXECUTE_READ |
                    PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY)) ||
                probe.address < reinterpret_cast<std::uintptr_t>(region.BaseAddress) ||
                probe.address + sizeof(state) > reinterpret_cast<std::uintptr_t>(region.BaseAddress) + region.RegionSize) return false;
            std::memcpy(&state, reinterpret_cast<const void*>(probe.address), sizeof(state));
            return true;
        }
        struct agent_input_sample
        {
            game::clientUIActive_t ui{};
            iw7::agent::movement_key_snapshot key{}, strafe{};
            bool key_valid{}, strafe_valid{};
            std::uint64_t tick{};
        };
        struct agent_dispatch_event
        {
            iw7::agent::button key{}; bool down{};
            std::uint64_t sequence{}, step{}, start{}, end{}, due{};
            agent_input_sample before{}, after{};
        };
        std::array<agent_dispatch_event, 32> agent_dispatch_events{};
        unsigned agent_dispatch_event_count{};
        bool agent_dispatch_overflow{};
        agent_input_sample agent_input_snapshot(iw7::agent::button key)
        {
            agent_input_sample sample; sample.ui = game::clientUIActives[0]; sample.tick = GetTickCount64();
            iw7::agent::key_probe probe{};
            sample.key_valid = iw7::agent::key_probe_for(key, probe) && agent_read_key(probe, sample.key);
            sample.strafe_valid = agent_read_key(iw7::agent::strafe_probe, sample.strafe);
            return sample;
        }
        void agent_flush_dispatch()
        {
            for (unsigned i = 0; i < agent_dispatch_event_count; ++i)
            {
                const auto& event = agent_dispatch_events[i];
                const auto* name = iw7::agent::bindings[static_cast<unsigned>(event.key)];
                const std::string binding_name = event.down ? name : "-" + std::string(name + 1);
                for (const bool after : {false, true})
                {
                    const auto& sample = after ? event.after : event.before; const auto& ui = sample.ui;
                    const auto& state = sample.key; const auto& strafe = sample.strafe;
                    console::info("[Paris agent input] phase=%s seq=%llu step=%llu binding=%s tick_ms=%llu frontend=%u cgame_initialized=%u catchers=%d connection=%d kbutton_valid=%d key0=%d key1=%d active=%u was_pressed=%u downtime=%d msec=%d strafe_valid=%d strafe_active=%u usercmd=unmeasured\n",
                        after ? "after" : "before", event.sequence, event.step, binding_name.c_str(), sample.tick,
                        static_cast<unsigned>(ui.frontEndSceneState[0]), static_cast<unsigned>(ui.cgameInitialized), ui.keyCatchers,
                        static_cast<int>(ui.connectionState), static_cast<int>(sample.key_valid), state.down[0], state.down[1],
                        static_cast<unsigned>(state.active), static_cast<unsigned>(state.was_pressed), state.downtime, state.msec,
                        static_cast<int>(sample.strafe_valid), static_cast<unsigned>(strafe.active));
                }
                console::info("[Paris agent binding] seq=%llu step=%llu binding=%s down=%d tick_ms=%llu dispatch_start_ms=%llu dispatch_end_ms=%llu due_ms=%llu deadline_late_ms=%llu\n",
                    event.sequence, event.step, binding_name.c_str(), static_cast<int>(event.down), event.end, event.start, event.end, event.due,
                    !event.down && event.due && event.start > event.due ? event.start - event.due : 0);
            }
            agent_dispatch_event_count = 0;
            if (agent_dispatch_overflow) { console::error("[Paris agent binding] telemetry_overflow; no complete timing witness.\n"); agent_dispatch_overflow = false; }
            if (agent_binding_failed) console::error("[Paris agent binding] rejected retail/strafe binding; tick_ms=%llu\n", GetTickCount64());
            agent_binding_failed = false;
        }
        std::uint64_t agent_binding(iw7::agent::button key, bool down)
        {
            const auto index = static_cast<unsigned>(key);
            if (index >= iw7::agent::bindings.size()) { agent_binding_failed = true; return GetTickCount64(); }
            if (down && iw7::agent::aiming(key))
            {
                iw7::agent::movement_key_snapshot strafe{};
                if (!agent_read_key(iw7::agent::strafe_probe, strafe) || strafe.active || strafe.down[0] || strafe.down[1])
                { agent_binding_failed = true; return GetTickCount64(); }
            }
            const auto* name = iw7::agent::bindings[index];
            const std::string binding_name = down ? name : "-" + std::string(name + 1);
            for (int binding = 0; binding < 118; ++binding)
            {
                if (!game::command_whitelist[binding] || binding_name != game::command_whitelist[binding]) continue;
                agent_dispatch_event event; event.key = key; event.down = down;
                event.sequence = agent_runtime.client->sequence(); event.step = agent_runtime.client->step();
                event.due = agent_runtime.client->due(key); event.before = agent_input_snapshot(key);
                const auto engine_time = game::Sys_Milliseconds(); event.start = GetTickCount64();
                utils::hook::invoke<void>(0x14032A3B0, 0, binding, 210 + static_cast<int>(index), engine_time);
                event.end = GetTickCount64(); event.after = agent_input_snapshot(key);
                // Fixed, main-thread-only queue: no logging/file/network IO may
                // delay the next release in this frame's release-all batch.
                if (agent_dispatch_event_count < agent_dispatch_events.size()) agent_dispatch_events[agent_dispatch_event_count++] = event;
                else agent_dispatch_overflow = true;
                return event.end;
            }
            agent_binding_failed = true;
            return GetTickCount64();
        }
        bool agent_bindings_available()
        {
            for (const auto* name : iw7::agent::bindings)
                for (const bool down : {false, true})
                {
                    // This fixture never dispatches +talk (agent requests for it are rejected).
                    if (std::strcmp(name, "+talk") == 0) continue;
                    const std::string desired = down ? name : "-" + std::string(name + 1);
                    bool found{};
                    for (int binding = 0; binding < 118; ++binding)
                        if (game::command_whitelist[binding] && desired == game::command_whitelist[binding]) { found = true; break; }
                    if (!found) { console::error("[Paris agent binding] Preflight missing %s\n", desired.c_str()); return false; }
                }
            return true;
        }
        void agent_result(const char* status, const iw7::agent::request* request = nullptr)
        {
            const auto result = std::format("{} {} {} {} {} {}\n", GetCurrentProcessId(), agent_runtime.client_nonce,
                request ? request->sequence : agent_runtime.client->sequence(), request ? request->step : agent_runtime.client->step(), status, GetTickCount64());
            utils::io::write_file("iw7-mod/paris-agent.response", result);
            console::info("[Paris agent dispatch] %s", result.c_str());
        }
        // Network callbacks only parse and replace a bounded mailbox. Engine
        // entities/dvars and binding dispatch are read on their scheduler thread.
        void agent_receive_query(const game::netadr_s& from, std::string_view wire)
        {
            if (!loopback(from) || wire.size() > 64) return;
            agent_packet packet; std::string probe, extra;
            std::istringstream input{std::string(wire)};
            if (!(input >> packet.nonce >> probe) || (input >> extra) || !iw7::agent::nonce_valid(packet.nonce) ||
                !iw7::agent::number(probe, packet.probe) || !packet.probe) return;
            packet.address = from;
            std::lock_guard lock(agent_packet_mutex);
            for (auto& pending : agent_queries)
                if (pending.nonce.empty() || network::are_addresses_equal(pending.address, from)) { pending = packet; return; }
        }
        void agent_receive_reply(const game::netadr_s& from, std::string_view wire)
        {
            if (!loopback(from) || wire.size() > 160) return;
            agent_packet packet; std::string probe, safe, extra;
            std::istringstream input{std::string(wire)};
            if (!(input >> packet.nonce >> probe >> packet.generation >> safe >> packet.map) || (input >> extra) ||
                packet.nonce != agent_runtime.client_nonce || !iw7::agent::nonce_valid(packet.generation) ||
                !iw7::agent::number(probe, packet.probe) || (safe != "0" && safe != "1")) return;
            packet.safe = safe == "1"; packet.address = from;
            std::lock_guard lock(agent_packet_mutex); agent_reply = packet;
        }
        void agent_server_tick()
        {
            if (agent_runtime.server_generation.empty() || !private_fixture() || !utils::flags::has_flag("paris-isolated-lab") || !game::SV_Loaded()) return;
            std::array<agent_packet, 4> queries;
            { std::lock_guard lock(agent_packet_mutex); queries = std::move(agent_queries); agent_queries = {}; }
            const auto* map = game::Dvar_FindVar("mapname");
            const std::string map_name = map && map->type == game::DVAR_TYPE_STRING && map->current.string ? map->current.string : "none";
            const auto* clients = *game::svs_clients;
            for (const auto& query : queries)
            {
                if (query.nonce.empty()) continue;
                bool safe{};
                { std::lock_guard lock(safety_mutex);
                    std::array<bool, 4> matches{};
                    for (unsigned slot = 0; clients && slot < matches.size() && slot < *game::svs_numclients; ++slot)
                        if (clients[slot].header.state == game::CS_ACTIVE &&
                            network::are_addresses_equal(query.address, clients[slot].remoteAddress) && bound_player(slot) &&
                            !protected_players[slot].safety_failed) matches[slot] = true;
                    const auto selected = iw7::agent::unique_slot(matches);
                    if (selected >= 0 && refresh_protection(static_cast<unsigned>(selected)))
                        {
                            const auto now = GetTickCount64(); auto& player = protected_players[static_cast<unsigned>(selected)];
                            if (now >= query.probe && now - query.probe <= 500 && query.probe > player.agent_probe &&
                                (player.agent_nonce.empty() || player.agent_nonce == query.nonce))
                            { player.agent_nonce = query.nonce; player.agent_probe = query.probe; safe = true; }
                        }
                }
                network::send(query.address,"parisAgentSafe",std::format("{} {} {} {} {}",query.nonce,query.probe,
                    agent_runtime.server_generation,static_cast<int>(safe),map_name));
            }
        }
        std::string agent_observation_stamp(game::scr_entref_t ent)
        {
            if (!private_fixture() || !utils::flags::has_flag("paris-isolated-lab") || !game::SV_Loaded() ||
                ent.classnum || ent.entnum >= protected_players.size() || agent_runtime.server_generation.empty()) return "unavailable";
            const auto* revive = game::Dvar_FindVar("paris_agent_revive_probe");
            const bool revive_probe = revive && revive->type == game::DVAR_TYPE_STRING && revive->current.string &&
                iw7::agent::revive_role_enabled(revive->current.string);
            const auto* port = game::Dvar_FindVar("net_port");
            if (!port || port->type != game::DVAR_TYPE_INT || port->current.integer < 27100 || port->current.integer > 27999) return "unavailable";
            std::lock_guard lock(safety_mutex);
            const auto now = GetTickCount64(); const auto& player = protected_players[ent.entnum];
            const auto* cheats = game::Dvar_FindVar("sv_cheats"); const auto* inactivity = engine_inactivity();
            const auto* clients = *game::svs_clients;
            if (!bound_player(ent.entnum) || player.safety_failed || !clients || clients[ent.entnum].header.state != game::CS_ACTIVE ||
                !iw7::agent::observation_valid(player.agent_nonce, agent_runtime.server_generation, ent.entnum, player.agent_probe, now, true, true, revive_probe) ||
                !(game::g_entities[ent.entnum].flags & 1) || !inactivity || inactivity->type != game::DVAR_TYPE_INT || inactivity->current.integer != 0 ||
                !cheats || cheats->type != game::DVAR_TYPE_BOOL || cheats->current.enabled) return "unavailable";
            return std::format("server_pid={}; client_nonce={}; server_generation={}; slot={}; native_tick_ms={}; protected=1",
                GetCurrentProcessId(), player.agent_nonce, agent_runtime.server_generation, ent.entnum, now);
        }
        // PREVIEW ONLY: insert in the existing anonymous namespace, immediately
        // before agent_client_tick. Release diagnostic; no hook/command/GSC API.
        void observe_original_sound_on_arm(const iw7::agent::request& request)
        {
            static_assert(sizeof(game::SndBank) == 0x160);
            static_assert(offsetof(game::SndBank, aliasCount) == 32);
            static_assert(offsetof(game::SndBank, alias) == 40);
            static_assert(offsetof(game::SndBank, aliasIndex) == 48);
            static_assert(sizeof(game::SndAliasList) == 32);
            static_assert(offsetof(game::SndAliasList, head) == 16);
            static_assert(offsetof(game::SndAliasList, count) == 24);
            static_assert(sizeof(game::SndAlias) == 200);
            static_assert(offsetof(game::SndAlias, assetFileName) == 32);
            static_assert(offsetof(game::SndAlias, id) == 40);
            static_assert(offsetof(game::SndAlias, assetId) == 52);
            static_assert(offsetof(game::SndAlias, flags) == 108);
            static_assert(sizeof(game::SndIndexEntry) == 4);
            constexpr auto bank_name = "community_original_sound_v1.all";
            constexpr auto alias_name = "community_original_chime_v1";
            constexpr auto asset_name = "community/original_chime_v1";
            constexpr std::uintptr_t length_address = 0x140C9BCE0;
            const auto readable = [](const void* pointer, std::size_t bytes)
            {
                const auto address = reinterpret_cast<std::uintptr_t>(pointer);
                if (!address || !bytes || bytes > 4096 || address > UINTPTR_MAX - bytes) return false;
                MEMORY_BASIC_INFORMATION region{};
                if (VirtualQuery(pointer, &region, sizeof(region)) != sizeof(region) || region.State != MEM_COMMIT ||
                    (region.Protect & (PAGE_GUARD | PAGE_NOACCESS)) ||
                    !(region.Protect & (PAGE_READONLY | PAGE_READWRITE | PAGE_WRITECOPY | PAGE_EXECUTE_READ |
                        PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY))) return false;
                const auto base = reinterpret_cast<std::uintptr_t>(region.BaseAddress);
                return address >= base && address - base <= region.RegionSize && bytes <= region.RegionSize - (address - base);
            };
            const auto snapshot = [&](const void* pointer, void* value, std::size_t bytes)
            {
                if (!readable(pointer, bytes)) return false;
                SIZE_T copied{};
                // VirtualQuery is a prefilter, not a lifetime lock. Reject a
                // failed/partial copy before interpreting any destination byte.
                return ReadProcessMemory(GetCurrentProcess(), pointer, value, bytes, &copied) != FALSE && copied == bytes;
            };
            const auto copy = [&](const auto* pointer, auto& value)
            {
                return snapshot(pointer, &value, sizeof(value));
            };
            const auto same = [&](const char* pointer, const char* literal, bool* all_readable = nullptr)
            {
                const auto size = std::strlen(literal) + 1;
                std::array<char, 64> value{};
                if (size > value.size() || !snapshot(pointer, value.data(), size))
                { if (all_readable) *all_readable = false; return false; }
                return std::memcmp(value.data(), literal, size) == 0;
            };
            const auto exact_dvar = [&](const char* key, const char* literal)
            {
                game::dvar_t dvar{};
                return copy(game::Dvar_FindVar(key), dvar) && dvar.type == game::DVAR_TYPE_STRING && same(dvar.current.string, literal);
            };
            if (game::environment::is_dedi() || game::base_address != 0x140000000 ||
                !utils::flags::has_flag("paris-server-client-test") || !utils::flags::has_flag("paris-isolated-lab") ||
                !agent_runtime.client || request.operation != iw7::agent::action::arm ||
                !exact_dvar("fs_game", "mods/sdk_original_sound_v1")) return;
            const auto safe = [&]
            {
                const auto* connection = party::get_server_connection_state();
                game::dvar_t cheats{}, port{};
                game::clientUIActive_t client_ui{};
                if (!copy(game::Dvar_FindVar("sv_cheats"), cheats) || !copy(game::Dvar_FindVar("paris_lab_server_port"), port) ||
                    !copy(static_cast<game::clientUIActive_t*>(game::clientUIActives), client_ui)) return false;
                int expected_port{};
                if (port.type == game::DVAR_TYPE_INT) expected_port = port.current.integer;
                else if (port.type == game::DVAR_TYPE_STRING)
                {
                    std::array<char, 6> text{};
                    if (!snapshot(port.current.string, text.data(), text.size()) || text[5] != '\0') return false;
                    const auto parsed = std::from_chars(text.data(), text.data() + 5, expected_port);
                    if (parsed.ec != std::errc{} || parsed.ptr != text.data() + 5) return false;
                }
                return iw7::agent::scenario::safe(agent_safety, GetTickCount64()) && agent_safety.map == "cp_zmb" &&
                    exact_dvar("mapname", "cp_zmb") && exact_dvar("fs_game", "mods/sdk_original_sound_v1") &&
                    game::Com_GameMode_GetActiveGameMode() == game::GAME_MODE_CP && game::CL_IsGameClientActive(0) &&
                    client_ui.cgameInitialized && client_ui.connectionState == game::CA_ACTIVE &&
                    !game::Com_IsAnyLocalServerRunning() && connection && connection->hostDefined && loopback(connection->host) &&
                    connection->challenge == agent_connection_challenge && !agent_connection_challenge.empty() &&
                    expected_port >= 27100 && expected_port <= 27999 && ntohs(connection->host.port) == expected_port &&
                    cheats.type == game::DVAR_TYPE_BOOL && !cheats.current.enabled &&
                    iw7::agent::nonce_valid(agent_runtime.client_nonce) && iw7::agent::nonce_valid(agent_generation) &&
                    request.pid == GetCurrentProcessId() && request.nonce == agent_runtime.client_nonce &&
                    request.sequence == agent_runtime.client->sequence() && request.step == agent_runtime.client->step();
            };
            // Exactly one attempt per already-bound connection, including missing
            // or invalid banks. No delayed retry, timer or secondary input action.
            static std::string observed_nonce, observed_generation, observed_challenge;
            const auto begin = GetTickCount64();
            const char* status = "scope_not_ready";
            const char* alias_state = "unmeasured";
            bool bank_present{}, bank_default{}, bank_identity{}, engine_called{};
            int index_value = -1, index_next = -1, length_raw{};
            try
            {
                if (observed_nonce == agent_runtime.client_nonce && observed_generation == agent_generation &&
                    observed_challenge == agent_connection_challenge) return;
                // Allocate all three snapshots before committing the latch.
                auto nonce = agent_runtime.client_nonce, generation = agent_generation, challenge = agent_connection_challenge;
                observed_nonce.swap(nonce); observed_generation.swap(generation); observed_challenge.swap(challenge);
                do
                {
                    if (!safe()) break;
#ifdef _DEBUG
                    status = "release_required"; break;
#endif
                    const auto header = game::DB_FindXAssetHeader(game::ASSET_TYPE_SOUND_BANK, bank_name, 0);
                    bank_present = header.soundBank != nullptr;
                    // Missing at arm is an unready/failed load observation, never
                    // evidence that this alias is absent from the engine globally.
                    if (!bank_present) { status = "bank_not_observed_load_unproven"; break; }
                    bank_default = game::DB_IsXAssetDefault(game::ASSET_TYPE_SOUND_BANK, bank_name);
                    if (bank_default) { status = "default_bank_load_unproven"; break; }
                    game::SndBank bank{};
                    if (!copy(header.soundBank, bank)) { status = "bank_unreadable"; break; }
                    bool bank_strings_readable = true;
                    bank_identity = same(bank.name, bank_name, &bank_strings_readable) && same(bank.zone, "mod", &bank_strings_readable) &&
                        same(bank.gameLanguage, "all", &bank_strings_readable) && same(bank.soundLanguage, "all", &bank_strings_readable);
                    if (!bank_strings_readable) { status = "bank_unreadable"; break; }
                    if (!bank_identity) { status = "bank_identity_mismatch"; break; }
                    if (bank.aliasCount == 0) { status = "alias_absent_in_observed_bank"; alias_state = "absent_in_bank"; break; }
                    if (bank.aliasCount != 1) { status = "alias_count_mismatch"; break; }
                    game::SndIndexEntry index{};
                    if (!copy(bank.aliasIndex, index)) { status = "index_unreadable"; break; }
                    index_value = index.value; index_next = index.next;
                    if (index.value != 0 || index.next != 65535) { status = "index_mismatch"; break; }
                    game::SndAliasList list{};
                    // This is the one-entry closed bank; never follow next or
                    // dereference a variable index/count from untrusted memory.
                    if (!copy(bank.alias, list)) { status = "alias_unreadable"; break; }
                    bool alias_string_readable = true;
                    const auto alias_matches = same(list.aliasName, alias_name, &alias_string_readable);
                    if (!alias_string_readable) { status = "alias_unreadable"; break; }
                    if (!alias_matches || list.id != 1489483025u || list.count != 1)
                    { status = "alias_identity_mismatch"; break; }
                    game::SndAlias head{};
                    if (!copy(list.head, head)) { status = "head_unreadable"; break; }
                    bool head_strings_readable = true;
                    const auto head_strings_match = same(head.aliasName, alias_name, &head_strings_readable) &&
                        same(head.assetFileName, asset_name, &head_strings_readable);
                    if (!head_strings_readable) { status = "head_unreadable"; break; }
                    if (!head_strings_match ||
                        head.id != 1489483025u || head.assetId != 1496246593u || head.flags.type != game::SAT_LOADED ||
                        head.flags.looping != 0 || !head.flags.precached)
                    { status = "head_contract_mismatch"; break; }
                    alias_state = "resolved_in_bank";
                    MEMORY_BASIC_INFORMATION code{};
                    if (VirtualQuery(reinterpret_cast<const void*>(length_address), &code, sizeof(code)) != sizeof(code) ||
                        code.State != MEM_COMMIT || (code.Protect & (PAGE_GUARD | PAGE_NOACCESS)) ||
                        !(code.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY)))
                    { status = "engine_entry_unavailable"; break; }
                    if (!safe()) { status = "protection_expired_before_call"; break; }
                    engine_called = true;
                    // Source-proven signature in upstream dedicated.cpp, client
                    // Release path only. No dedicated sounddata substitution.
                    length_raw = utils::hook::invoke<int>(length_address, alias_name);
                    status = length_raw == 0 ? "resolved_zero_length" : length_raw < 0 ? "resolved_negative_length" : "resolved_positive_length";
                } while (false);
                const auto end = GetTickCount64();
                const bool fresh_end = safe();
                if (!fresh_end) status = "protection_expired";
                const auto length_text = engine_called ? std::to_string(length_raw) : "unmeasured";
                console::info("[Paris sound lookup] pid=%lu nonce=%s generation=%s sequence=%llu step=%llu probe_tick_ms=%llu begin_tick_ms=%llu end_tick_ms=%llu protected_end=%d status=%s bank_present=%d bank_default=%d bank_identity=%d alias_state=%s index_value=%d index_next=%d engine_length_called=%d engine_length_raw=%s playback_verified=0\n",
                    GetCurrentProcessId(), observed_nonce.c_str(), observed_generation.c_str(), request.sequence, request.step,
                    agent_safety.received, begin, end, static_cast<int>(fresh_end), status, static_cast<int>(bank_present),
                    static_cast<int>(bank_default), static_cast<int>(bank_identity), alias_state, index_value, index_next,
                    static_cast<int>(engine_called), length_text.c_str());
            }
            catch (const std::exception&)
            {
                console::error("[Paris sound lookup] pid=%lu nonce=%s generation=%s sequence=%llu step=%llu status=snapshot_exception evidence_complete=0 playback_verified=0\n",
                    GetCurrentProcessId(), request.nonce.c_str(), agent_generation.c_str(), request.sequence, request.step);
            }
        }

        void agent_client_tick()
        {
            if (!agent_runtime.client || !utils::flags::has_flag("paris-isolated-lab")) return;
            const auto now = GetTickCount64();
            client_protection_main_tid.store(GetCurrentThreadId(), std::memory_order_relaxed);
            const auto* connection = party::get_server_connection_state();
            const auto* port = game::Dvar_FindVar("paris_lab_server_port");
            const int expected_port = port && port->type == game::DVAR_TYPE_STRING && port->current.string ? std::atoi(port->current.string) :
                port && port->type == game::DVAR_TYPE_INT ? port->current.integer : 0;
            agent_safety.connected = connection && connection->hostDefined && loopback(connection->host) &&
                expected_port >= 27100 && expected_port <= 27999 && ntohs(connection->host.port) == expected_port &&
                !game::Com_IsAnyLocalServerRunning() && game::Com_GameMode_GetActiveGameMode() == game::GAME_MODE_CP &&
                game::CL_IsGameClientActive(0) && game::clientUIActives[0].connectionState == game::CA_ACTIVE;
            const char* frame_status{};
            if (agent_safety.connected && agent_connection_challenge != connection->challenge)
            {
                if (agent_runtime.client->active()) { agent_runtime.client->stop(agent_binding); frame_status = "connection_changed"; }
                agent_connection_challenge = connection->challenge; agent_last_ack = agent_last_probe;
                agent_safety.protected_now = false; agent_safety.received = 0;
            }
            if (const auto* failure = agent_runtime.client->tick(now, agent_safety, agent_binding)) frame_status = failure;
            if (agent_binding_failed) { agent_runtime.client->stop(agent_binding); agent_safety.protected_now = false; frame_status = "binding_rejected"; }
            agent_flush_dispatch();
            if (frame_status) agent_result(frame_status);
            paris_model_diagnostics::observe_client(iw7::agent::scenario::safe(agent_safety, GetTickCount64()), agent_safety.received,
                agent_runtime.client_nonce, agent_generation, agent_connection_challenge, false,
                agent_runtime.client->active() ? rig_scene_arm : 0);
            static std::uint64_t last_poll{};
            if (now >= last_poll && now - last_poll < 50) return;
            last_poll = now;
            agent_packet reply;
            { std::lock_guard lock(agent_packet_mutex); reply = std::move(agent_reply); agent_reply = {}; }
            if (agent_safety.connected)
            {
                if (iw7::agent::heartbeat_valid(reply.nonce, agent_runtime.client_nonce, reply.generation,
                    network::are_addresses_equal(reply.address, connection->host), reply.probe, agent_last_ack, agent_last_probe, now))
                {
                    if (agent_runtime.client->active() && agent_generation != reply.generation)
                    {
                        agent_runtime.client->stop(agent_binding); agent_result("server_changed");
                    }
                    agent_generation = reply.generation; agent_last_ack = reply.probe;
                    // Age from the local query time: network latency must not
                    // extend how long an old server safety sample can authorize input.
                    agent_safety.protected_now = reply.safe; agent_safety.map = reply.map; agent_safety.received = reply.probe;
                }
            }
            if (const auto* failure = agent_runtime.client->tick(GetTickCount64(), agent_safety, agent_binding)) agent_result(failure);
            agent_flush_dispatch();
            if (agent_safety.connected)
            {
                agent_last_probe = GetTickCount64();
                network::send(connection->host,"parisAgentQuery",std::format("{} {}",agent_runtime.client_nonce,agent_last_probe));
            }
            const auto safety_now = GetTickCount64();
            if (const auto* failure = agent_runtime.client->tick(safety_now, agent_safety, agent_binding)) agent_result(failure);
            agent_flush_dispatch();
            utils::io::write_file("iw7-mod/paris-agent.safety", std::format("{} {} {} {} {}\n", GetCurrentProcessId(), agent_runtime.client_nonce,
                static_cast<int>(iw7::agent::scenario::safe(agent_safety, safety_now)), safety_now, agent_safety.map.empty() ? "none" : agent_safety.map));
            static std::string previous;
            const auto wire = utils::io::read_file("iw7-mod/paris-agent.request");
            if (wire.empty() || wire == previous) return;
            previous = wire; iw7::agent::request request;
            if (!iw7::agent::parse(wire, request)) { agent_result("parse_rejected"); return; }
            // This fixture never dispatches +talk.
            if (request.key == iw7::agent::button::talk) { agent_result("parse_rejected"); return; }
            if (vote_witness_running && request.operation != iw7::agent::action::abort && request.operation != iw7::agent::action::release_all)
            { agent_result("vote_busy", &request); return; }
            if (request.operation == iw7::agent::action::arm && !agent_bindings_available())
            { agent_result("binding_rejected", &request); return; }
            agent_binding_failed = false;
            const auto* status = agent_runtime.client->accept(request, GetTickCount64(), agent_safety, agent_binding);
            if (std::strcmp(status, "armed") == 0)
            {
                rig_scene_arm = request.sequence;
                observe_original_sound_on_arm(request);
                // Model READY and the pre-action frame precede runner arm.
                // Sample after the scene has been referenced, not on its first
                // protection heartbeat (GPU upload may otherwise be lazy).
                paris_model_diagnostics::observe_client(iw7::agent::scenario::safe(agent_safety, GetTickCount64()), agent_safety.received,
                    agent_runtime.client_nonce, agent_generation, agent_connection_challenge);
                for (const auto* name : {"cl_yawspeed", "cl_pitchspeed"})
                {
                    const auto* rate = game::Dvar_FindVar(name);
                    if (!rate) console::info("[Paris agent turn rate] name=%s present=0\n", name);
                    else if (rate->type == game::DVAR_TYPE_FLOAT)
                        console::info("[Paris agent turn rate] name=%s type=%d flags=%u value=%g tick_ms=%llu\n",
                            name, static_cast<int>(rate->type), rate->flags, static_cast<double>(rate->current.value), GetTickCount64());
                    else console::info("[Paris agent turn rate] name=%s type=%d flags=%u value=unmeasured tick_ms=%llu\n",
                        name, static_cast<int>(rate->type), rate->flags, GetTickCount64());
                }
                // A prior legacy voteholdnext uses different synthetic keys.
                // Clear those keys before the scenario owns Fire/ADS.
                vote_binding("+attack", false); vote_binding("+speed_throw", false);
            }
            if (agent_binding_failed)
            {
                agent_runtime.client->release_all(agent_binding);
                agent_safety.protected_now = false;
                agent_runtime.client->tick(GetTickCount64(), agent_safety, agent_binding); status = "binding_rejected";
            }
            agent_flush_dispatch();
            agent_result(status, &request);
        }
        void vote_binding(const char* name, bool down)
        {
            // Pinned IW7 input.cpp routes the 118 retail bindings through this
            // client dispatcher. Release uses the separate '-' binding, as the
            // key-event path does. Its third argument identifies the held key.
            const std::string binding_name = down ? name : "-" + std::string(name + 1);
            const int key = std::strcmp(name, "+attack") == 0 ? 200 : 201;
            for (int binding = 0; binding < 118; ++binding)
            {
                if (!game::command_whitelist[binding] || binding_name != game::command_whitelist[binding]) continue;
                utils::hook::invoke<void>(0x14032A3B0, 0, binding, key, game::Sys_Milliseconds());
                console::info("[Paris vote input] binding=%s key=%d catchers=%d\n", binding_name.c_str(), key, *game::keyCatchers);
                return;
            }
            console::error("[Paris vote input] Missing pinned retail binding %s.\n", binding_name.c_str());
        }
        // Generic lab key request: "keydown:<name>" / "keyup:<name>" for any retail
        // "+name" binding (forward, reload, gostand, speed_throw, ...). The retail
        // binding table decides what exists; nothing outside it can be dispatched.
        bool key_binding(const std::string& base, bool down)
        {
            if (base.size() < 2 || base.size() > 24 || base.find_first_not_of("abcdefghijklmnopqrstuvwxyz0123456789_") != std::string::npos) return false;
            const std::string binding_name = (down ? "+" : "-") + base;
            for (int binding = 0; binding < 118; ++binding)
            {
                if (!game::command_whitelist[binding] || binding_name != game::command_whitelist[binding]) continue;
                // One fixed key id: it only identifies the holder inside that binding's own button state.
                utils::hook::invoke<void>(0x14032A3B0, 0, binding, 222, game::Sys_Milliseconds());
                console::info("[Paris key input] binding=%s catchers=%d tick_ms=%llu\n", binding_name.c_str(), *game::keyCatchers, GetTickCount64());
                return true;
            }
            console::error("[Paris key input] no retail binding %s\n", binding_name.c_str());
            return false;
        }
        void vote_buttons(bool attack, bool ads, bool hold = false)
        {
            vote_binding("+attack", false);
            vote_binding("+speed_throw", false);
            if (attack) vote_binding("+attack", true);
            if (ads) vote_binding("+speed_throw", true);
            if (!hold) scheduler::once([]
            {
                vote_binding("+attack", false);
                vote_binding("+speed_throw", false);
            }, scheduler::main, 200ms);
        }
        void server_request()
        {
            // -paris-voice-base-test is a historical name; it now only enables
            // these protected server map requests (agent-capacity Watch-Server and
            // the server repository's Test-GameplayDrop pass it to the dedicated).
            if (!private_fixture() || !utils::flags::has_flag("paris-voice-base-test") || !game::SV_Loaded()) return;
            static std::string previous;
            const auto request = utils::io::read_file("iw7-mod/paris-server-client.request");
            if (request.empty() || request.size() > 128 || request == previous) return;
            previous = request;
            unsigned long pid{};
            std::string nonce, action, extra;
            std::istringstream input(request);
            if (!(input >> pid >> nonce >> action) || (input >> extra) || pid != GetCurrentProcessId() ||
                nonce.size() != 32 || nonce.find_first_not_of("0123456789abcdef") != std::string::npos) return;
            const std::array<std::string, 5> maps{"cp_zmb", "cp_rave", "cp_disco", "cp_town", "cp_final"};
            if (action.rfind("map_", 0) != 0) return;
            const auto map = action.substr(4);
            if (std::find(maps.begin(), maps.end(), map) == maps.end()) return;
            // Only the owned, protected loopback party can change the test map.
            // This fixture is absent from ordinary server operation.
            const auto* clients = *game::svs_clients;
            // Retail CP allocates16 client records despite a four-player game.
            // Inspect every allocated record; any unprotected occupant refuses.
            if (!clients || *game::svs_numclients > 16) return;
            // This callback runs on main. refresh_protection writes a dvar and
            // can wait for the server thread; holding safety_mutex here would
            // deadlock a simultaneous server damage/protection query. Read the
            // current safety state, releasing its lock before command dispatch.
            for (unsigned slot = 0; slot < *game::svs_numclients; ++slot)
                if (clients[slot].header.state >= game::CS_CONNECTED &&
                    (clients[slot].header.state != game::CS_ACTIVE || !is_protected_player(static_cast<int>(slot)))) return;
            command::execute("map " + map, false);
            utils::io::write_file("iw7-mod/paris-server-client.response", request);
            console::info("[Paris server test] Owned protected map request queued: %s.\n", map.c_str());
        }
        int lab_port()
        {
            const auto* port = game::Dvar_FindVar("paris_lab_server_port");
            if (!port) return 0;
            int value = 0;
            if (port->type == game::DVAR_TYPE_STRING && port->current.string)
                value = std::atoi(port->current.string);
            else if (port->type == game::DVAR_TYPE_INT) value = port->current.integer;
            return value >= 27100 && value <= 27999 ? value : 0;
        }
        // Moved from the retired paris_voice.cpp. The server repository's
        // ops/Isolated-Lab.ps1 Baseline and Slasher profiles start clients with
        // -paris-voice-local-test and without the server-client fixture, and its
        // paris_rhino.cpp checks the same flag. Join the isolated lab dedicated
        // on loopback UDP 27116 once Zombies is ready: one attempt, no reconnect.
        // The flag name is historical. Only the isolated-lab path remains.
        bool local_lab_join_done{};
        void local_lab_join()
        {
            if (local_lab_join_done) return;
            if (game::Com_GameMode_GetActiveGameMode() != game::GAME_MODE_CP)
            {
                game::Com_GameMode_SetDesiredGameMode(game::GAME_MODE_CP);
                return;
            }
            if (game::Live_SyncOnlineDataFlags(0) != 0) return;
            game::netadr_s target{};
            target.type = game::NA_IP; target.ip[0] = 127; target.ip[3] = 1;
            target.port = htons(27116);
            local_lab_join_done = true;
            console::info("[Paris lab client] Loopback join to UDP 27116.\n");
            party::connect(target);
        }
        void client_request()
        {
            if (connect_pending && utils::flags::has_flag("paris-isolated-lab") &&
                game::Com_GameMode_GetActiveGameMode() != game::GAME_MODE_CP)
            {
                game::Com_GameMode_SetDesiredGameMode(game::GAME_MODE_CP);
                return;
            }
            if (connect_pending && utils::flags::has_flag("paris-isolated-lab") &&
                game::Live_SyncOnlineDataFlags(0) == 0 && lab_port())
            {
                game::netadr_s target{};
                target.type = game::NA_IP; target.ip[0] = 127; target.ip[3] = 1;
                target.port = htons(static_cast<unsigned short>(lab_port()));
                connect_pending = false;
                party::connect(target);
                console::info("[Paris module client] Ready loopback join to UDP %d.\n", lab_port());
            }
            static std::string previous;
            const auto request = utils::io::read_file("iw7-mod/paris-server-client.request");
            if (request.empty() || request.size() > 128 || request == previous) return;
            previous = request;
            unsigned long pid{}; std::string nonce, action, extra;
            std::istringstream input(request);
            if (!(input >> pid >> nonce >> action) || (input >> extra) || pid != GetCurrentProcessId() ||
                nonce.size() != 32 || nonce.find_first_not_of("0123456789abcdef") != std::string::npos) return;
            const bool vote_input = action == "votenext" || action == "voteprevious" || action == "voteboth" || action == "voteholdnext" || action == "voterelease" || action == "votewitness";
            const bool key_input = action.rfind("keydown:", 0) == 0 || action.rfind("keyup:", 0) == 0;
            const bool afk_input = action == "afk";
            const bool teleport_input = action == "owner_tphere" || action == "owner_tp";
            const bool cutscene_input = action == "cutscene_space" || action == "cutscene_enter" || action == "cutscene_mouse" || action == "cutscene_release";
            if (teleport_input || cutscene_input)
            {
                const auto* connection = party::get_server_connection_state();
                if (!utils::flags::has_flag("paris-isolated-lab") || !lab_port() || lab_port() == 27016 ||
                    !iw7::agent::scenario::safe(agent_safety, GetTickCount64()) ||
                    !connection || !connection->hostDefined || !loopback(connection->host) ||
                    ntohs(connection->host.port) != lab_port() || !game::CL_IsGameClientActive(0)) return;
            }
            if (afk_input && !utils::flags::has_flag("paris-isolated-lab")) return;
            if (vote_input && !utils::flags::has_flag("paris-isolated-lab")) return;
            if (key_input && (!utils::flags::has_flag("paris-isolated-lab") || vote_witness_running)) return;
            if (key_input && agent_runtime.client && agent_runtime.client->active()) return;
            if (vote_input && vote_witness_running) return;
            if (vote_input && agent_runtime.client && agent_runtime.client->active()) return;
            if (action != "capture" && action != "stop" && action != "help" && action != "mods" && action != "close" && action != "connect" && action != "rejoin" && action != "rejoin_immediate" && !vote_input && !key_input && !afk_input && !teleport_input && !cutscene_input) return;
            if (action == "rejoin" || action == "rejoin_immediate")
            {
                const auto* connection = party::get_server_connection_state();
                if (!utils::flags::has_flag("paris-isolated-lab") || !lab_port() || lab_port() == 27016 ||
                    !connection || !connection->hostDefined || !loopback(connection->host) ||
                    ntohs(connection->host.port) != lab_port() || !game::CL_IsGameClientActive(0)) return;
                if (agent_runtime.client) agent_runtime.client->stop(agent_binding);
                if (action == "rejoin_immediate") command::execute("reconnect", false);
                else
                {
                    command::execute("disconnect", false);
                    scheduler::once([] { connect_pending = true; }, scheduler::main, 3s);
                }
            }
            else if (action == "connect")
            {
                if (!utils::flags::has_flag("paris-isolated-lab")) return;
                if (!lab_port()) return;
                connect_pending = true;
            }
            if (action == "capture")
            {
                if (utils::flags::has_flag("paris-rig-assets-probe") || utils::flags::has_flag("paris-rig-scene-probe"))
                    paris_model_diagnostics::observe_scene_capture(agent_runtime.client && agent_runtime.client->active(), rig_scene_arm,
                        iw7::agent::scenario::safe(agent_safety, GetTickCount64()), agent_safety.received,
                        agent_runtime.client_nonce, agent_generation, agent_connection_challenge);
                const auto graphics_value = [](const char* name)
                {
                    const auto* dvar = game::Dvar_FindVar(name);
                    return dvar && dvar->type == game::DVAR_TYPE_INT ? dvar->current.integer : -1;
                };
                console::info("[Paris lab graphics] picmip=%d; bump=%d; spec=%d; tick_ms=%llu\n",
                    graphics_value("r_picmip"), graphics_value("r_picmip_bump"), graphics_value("r_picmip_spec"), GetTickCount64());
                command::execute("capture_frame server-modules-fixture", true);
            }
            else if (cutscene_input)
                command::execute("paris_cutscene_test_key " + action.substr(9),true);
            else if (key_input)
            {
                const bool down = action[3] == 'd';
                if (!key_binding(action.substr(down ? 8 : 6), down)) return; // no response: the requester sees the refusal as a timeout
            }
            else if (vote_input)
            {
                // Fixed client usercmd buttons only, scoped to the independent lab.
                // The operation helper requires fresh server protection first.
                if (action == "votewitness")
                {
                    vote_witness_running = true;
                    vote_buttons(false, true); // 0 -> Beast, reverse wrap.
                    scheduler::once([] { vote_buttons(false, true); }, scheduler::main, 2s); // Attack.
                    scheduler::once([] { vote_buttons(true, false); }, scheduler::main, 4s); // Beast.
                    scheduler::once([] { vote_buttons(true, false, true); }, scheduler::main, 5s); // Held Fire -> 0 once.
                    scheduler::once([] { vote_buttons(false, false); }, scheduler::main, 7s);
                    scheduler::once([] { vote_buttons(false, true); }, scheduler::main, 8s); // Beast.
                    scheduler::once([] { vote_buttons(true, true); }, scheduler::main, 9s); // Both ignored.
                    scheduler::once([] { vote_buttons(false, false); vote_witness_running = false; }, scheduler::main, 10s);
                }
                else vote_buttons(action == "votenext" || action == "voteboth" || action == "voteholdnext",
                    action == "voteprevious" || action == "voteboth", action == "voteholdnext");
            }
            else if (teleport_input) command::execute(action == "owner_tphere" ? "tphere #2" : "tp #2", true);
            else if (action == "help") command::execute("cmd say ..help", true);
            // Retail chat consumes its leading control byte before GSC say.
            else if (afk_input) command::execute("cmd say ..afk", true);
            else if (action == "mods") command::execute("cmd say ..mods", true);
            else if (action == "close") command::execute("cmd say ..close", true);
            else if (action == "stop")
            {
                if (agent_runtime.client) agent_runtime.client->stop(agent_binding);
                // Process lifecycle commands in the native command buffer.
                // A synchronous quit unwinds the engine stack through the
                // scheduler's noexcept scope-exit callback and calls terminate.
                command::execute("disconnect", false);
                scheduler::once([] { command::execute("quit", false); }, scheduler::main, 1s);
            }
            utils::io::write_file("iw7-mod/paris-server-client.response", request);
            console::info("[Paris module client] Request %s dispatched and returned.\n", action.c_str());
        }
    }
    client_test_protection client_protection(const char** refusal_reason)
    {
        client_test_protection result{};
        if (refusal_reason) *refusal_reason = nullptr;
        const auto refuse = [&](const char* reason) {
            if (refusal_reason) *refusal_reason = reason;
            return client_test_protection{};
        };
        const auto main_tid = client_protection_main_tid.load(std::memory_order_relaxed);
        if (!main_tid || GetCurrentThreadId() != main_tid) return refuse("protection_main_thread");
        if (!agent_runtime.client ||
            game::environment::is_dedi() || !utils::flags::has_flag("paris-isolated-lab") ||
            !utils::flags::has_flag("paris-server-client-test")) return refuse("protection_scope");
        const auto now = GetTickCount64();
        if (!iw7::agent::scenario::safe(agent_safety, now)) return refuse("protection_safety");
        const auto* connection = party::get_server_connection_state();
        if (!connection) return refuse("protection_connection_missing");
        if (!connection->hostDefined) return refuse("protection_host_undefined");
        if (!loopback(connection->host)) return refuse("protection_not_loopback");
        if (connection->challenge != agent_connection_challenge) return refuse("protection_challenge");
        if (game::Com_IsAnyLocalServerRunning()) return refuse("protection_local_server");
        if (game::Com_GameMode_GetActiveGameMode() != game::GAME_MODE_CP) return refuse("protection_game_mode");
        if (!game::CL_IsGameClientActive(0)) return refuse("protection_client_inactive");
        if (game::clientUIActives[0].connectionState != game::CA_ACTIVE) return refuse("protection_connection_state");
        const auto* port = game::Dvar_FindVar("paris_lab_server_port");
        const int expected_port = port && port->type == game::DVAR_TYPE_STRING && port->current.string ? std::atoi(port->current.string) :
            port && port->type == game::DVAR_TYPE_INT ? port->current.integer : 0;
        if (expected_port < 27100 || expected_port > 27999 || ntohs(connection->host.port) != expected_port) return refuse("protection_endpoint");
        result.protected_now = true; result.current_loopback = true;
        result.pid = GetCurrentProcessId(); result.port = ntohs(connection->host.port); result.expected_port = static_cast<unsigned>(expected_port);
        result.query_tick = agent_safety.received; result.observed_tick = now;
        result.nonce = agent_runtime.client_nonce; result.generation = agent_generation;
        result.challenge = connection->challenge; result.map = agent_safety.map;
        return client_protection_current(result, GetTickCount64()) ? result : refuse("protection_snapshot_invalid");
    }
    bool is_protected_player(int client_num)
    {
        if (!private_fixture() ||
            client_num < 0 || client_num >= static_cast<int>(protected_players.size())) return false;
        std::lock_guard lock(safety_mutex);
        const unsigned slot = static_cast<unsigned>(client_num);
        const bool bound = bound_player(slot) && !protected_players[slot].safety_failed;
        const auto* cheats = game::Dvar_FindVar("sv_cheats");
        const auto* inactivity = engine_inactivity();
        const kick_context context{game::environment::is_dedi(), utils::flags::has_flag("paris-server-test"),
            game::Com_GameMode_GetActiveGameMode() == game::GAME_MODE_CP, private_fixture(), bound, bound, bound,
            bound && (game::g_entities[slot].flags & 1) != 0, cheats && cheats->type == game::DVAR_TYPE_BOOL && !cheats->current.enabled,
            inactivity && inactivity->type == game::DVAR_TYPE_INT && inactivity->current.integer == 0};
        return allow_inactivity_exception(context, "EXE_PLAYERKICKED_INACTIVE");
    }
    bool suppress_inactivity_kick(int client_num, const char* reason)
    {
        if (!reason || std::strcmp(reason, "EXE_PLAYERKICKED_INACTIVE") || !is_protected_player(client_num)) return false;
        ++script_inactivity_suppressed;
        return true;
    }
    class component final : public component_interface
    {
    public:
        void post_unpack() override
        {
            if (!game::environment::is_dedi() && utils::flags::has_flag("paris-voice-local-test") && utils::flags::has_flag("paris-isolated-lab"))
                scheduler::loop(local_lab_join, scheduler::main, 1s);
            if (!game::environment::is_dedi() && utils::flags::has_flag("paris-server-client-test"))
            {
                scheduler::loop(client_request, scheduler::main, 100ms);
                if (utils::flags::has_flag("paris-isolated-lab"))
                {
                    agent_runtime.activate(GetCurrentProcessId(), true, false, agent_nonce);
                    utils::io::write_file("iw7-mod/paris-agent.session", std::format("{} {}\n", GetCurrentProcessId(), agent_runtime.client_nonce));
                    network::on("parisAgentSafe", agent_receive_reply);
                    scheduler::loop(agent_client_tick, scheduler::main, 0ms);
                }
            }
            if (game::environment::is_dedi() && utils::flags::has_flag("paris-server-test"))
            {
                scheduler::loop(server_request, scheduler::main, 100ms);
                scheduler::loop(maintain_protection, scheduler::server, 100ms);
                scheduler::loop(safety_status, scheduler::server, 10s);
                if (utils::flags::has_flag("paris-isolated-lab"))
                {
                    agent_runtime.activate(GetCurrentProcessId(), false, true, agent_nonce);
                    network::on("parisAgentQuery", agent_receive_query);
                    scheduler::loop(agent_server_tick, scheduler::server, 50ms);
                }
            }
            gsc::method::add("paris_test_protect", [](game::scr_entref_t ent, const gsc::function_args&) -> scripting::script_value
            {
                return protect_player(ent);
            });
            // Engine bots have no loopback connection identity. This private
            // gameplay witness protects/removes bots only; it exposes no player
            // command, identity override, authentication or persistent state.
            gsc::method::add("paris_test_bot", [](game::scr_entref_t ent, const gsc::function_args& args) -> scripting::script_value
            {
                if (!private_fixture() || !utils::flags::has_flag("paris-isolated-lab") ||
                    ent.classnum || ent.entnum >= protected_players.size() || !is_protected_player(0)) return false;
                auto* clients = *game::svs_clients;
                if (!clients) return false;
                const int operation = args[0].as<int>();
                if (operation == 1 && ent.entnum == 0)
                {
                    for (unsigned slot = 1; slot < protected_players.size() && slot < *game::svs_numclients; ++slot)
                        if (clients[slot].header.state >= game::CS_CONNECTED && game::SV_BotIsBot(static_cast<int>(slot)))
                            game::SV_DropClient(&clients[slot], "Isolated gameplay cleanup", true);
                    return true;
                }
                const auto slot = ent.entnum;
                if (operation != 0 || slot == 0 || slot >= *game::svs_numclients ||
                    clients[slot].header.state < game::CS_CONNECTED || !game::SV_BotIsBot(slot) ||
                    !game::g_entities[slot].client) return false;
                game::g_entities[slot].flags |= 1;
                return (game::g_entities[slot].flags & 1) != 0;
            });
            gsc::method::add("paris_rhino_test_protect", [](game::scr_entref_t ent, const gsc::function_args&) -> scripting::script_value
            {
                if (!utils::flags::has_flag("paris-rhino-probe") && !utils::flags::has_flag("paris-isolated-lab")) return false;
                return protect_player(ent);
            });
            gsc::method::add("paris_agent_observationstamp", [](game::scr_entref_t ent, const gsc::function_args&) -> scripting::script_value
            {
                return agent_observation_stamp(ent);
            });
            gsc::method::add("paris_test_safety_snapshot", [](game::scr_entref_t ent, const gsc::function_args&) -> scripting::script_value
            {
                return protection_snapshot(ent);
            });
        }
        void pre_destroy() override
        {
            paris_model_diagnostics::observe_client(false, 0, {}, {}, {}, false);
        }
    };
}
REGISTER_COMPONENT(paris_test_fixture::component)
