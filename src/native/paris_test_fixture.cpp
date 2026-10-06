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
#include <cstring>
#include "command.hpp"
#include "party.hpp"
#include "paris_test_safety.hpp"
#include "agent_scenario.hpp"

namespace paris_test_fixture
{
    namespace
    {
        struct protected_player { std::string identity; game::netadr_s address{}; bool safety_failed{}; };
        std::array<protected_player, 4> protected_players{};
        std::mutex safety_mutex;
        std::uint64_t script_inactivity_suppressed{};
        bool private_fixture()
        {
            const auto* password = game::Dvar_FindVar("g_password");
            return game::environment::is_dedi() && utils::flags::has_flag("paris-server-test") &&
                game::Com_GameMode_GetActiveGameMode() == game::GAME_MODE_CP &&
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
            if (!bound_player(ent.entnum)) protected_players[ent.entnum] = {identity, client.remoteAddress, false};
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
        std::string agent_connection_challenge;
        std::uint64_t agent_last_probe{}, agent_last_ack{};
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
        void agent_input_snapshot(iw7::agent::button key, const char* phase, const std::string& binding_name)
        {
            if (!agent_runtime.client || !utils::flags::has_flag("paris-isolated-lab") ||
                !utils::flags::has_flag("paris-server-client-test")) return;
            const auto& ui = game::clientUIActives[0];
            iw7::agent::movement_key_snapshot state{}, strafe{};
            iw7::agent::key_probe probe{};
            const bool key_valid = iw7::agent::key_probe_for(key, probe) && agent_read_key(probe, state);
            const bool strafe_valid = agent_read_key(iw7::agent::strafe_probe, strafe);
            console::info("[Paris agent input] phase=%s seq=%llu step=%llu binding=%s tick_ms=%llu frontend=%u cgame_initialized=%u catchers=%d connection=%d kbutton_valid=%d key0=%d key1=%d active=%u was_pressed=%u downtime=%d msec=%d strafe_valid=%d strafe_active=%u usercmd=unmeasured\n",
                phase, agent_runtime.client->sequence(), agent_runtime.client->step(), binding_name.c_str(), GetTickCount64(),
                static_cast<unsigned>(ui.frontEndSceneState[0]), static_cast<unsigned>(ui.cgameInitialized), ui.keyCatchers,
                static_cast<int>(ui.connectionState), static_cast<int>(key_valid), state.down[0], state.down[1],
                static_cast<unsigned>(state.active), static_cast<unsigned>(state.was_pressed), state.downtime, state.msec, static_cast<int>(strafe_valid), static_cast<unsigned>(strafe.active));
        }
        void agent_binding(iw7::agent::button key, bool down)
        {
            const auto index = static_cast<unsigned>(key);
            if (index >= iw7::agent::bindings.size()) return;
            if (down && iw7::agent::aiming(key))
            {
                iw7::agent::movement_key_snapshot strafe{};
                if (!agent_read_key(iw7::agent::strafe_probe, strafe) || strafe.active || strafe.down[0] || strafe.down[1])
                {
                    agent_binding_failed = true;
                    console::error("[Paris agent input] aim refused: strafe unreadable or active.\n");
                    return;
                }
            }
            const auto* name = iw7::agent::bindings[index];
            const std::string binding_name = down ? name : "-" + std::string(name + 1);
            for (int binding = 0; binding < 118; ++binding)
            {
                if (!game::command_whitelist[binding] || binding_name != game::command_whitelist[binding]) continue;
                agent_input_snapshot(key, "before", binding_name);
                utils::hook::invoke<void>(0x14032A3B0, 0, binding, 210 + static_cast<int>(index), game::Sys_Milliseconds());
                agent_input_snapshot(key, "after", binding_name);
                console::info("[Paris agent binding] step=%llu binding=%s down=%d tick_ms=%llu\n",
                    agent_runtime.client->step(), binding_name.c_str(), static_cast<int>(down), GetTickCount64());
                return;
            }
            agent_binding_failed = true;
            console::error("[Paris agent binding] Missing retail whitelist binding %s; tick_ms=%llu\n", binding_name.c_str(), GetTickCount64());
        }
        bool agent_bindings_available()
        {
            for (const auto* name : iw7::agent::bindings)
                for (const bool down : {false, true})
                {
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
                    for (unsigned slot = 0; clients && slot < protected_players.size() && slot < *game::svs_numclients; ++slot)
                        if (clients[slot].header.state == game::CS_ACTIVE &&
                            network::are_addresses_equal(query.address, clients[slot].remoteAddress) && refresh_protection(slot)) safe = true;
                }
                network::send(query.address, "parisAgentSafe", std::format("{} {} {} {} {}", query.nonce, query.probe,
                    agent_runtime.server_generation, static_cast<int>(safe), map_name));
            }
        }
        void agent_client_tick()
        {
            if (!agent_runtime.client || !utils::flags::has_flag("paris-isolated-lab")) return;
            const auto now = GetTickCount64();
            const auto* connection = party::get_server_connection_state();
            const auto* port = game::Dvar_FindVar("paris_lab_server_port");
            const int expected_port = port && port->type == game::DVAR_TYPE_STRING && port->current.string ? std::atoi(port->current.string) :
                port && port->type == game::DVAR_TYPE_INT ? port->current.integer : 0;
            agent_safety.connected = connection && connection->hostDefined && loopback(connection->host) &&
                expected_port >= 27100 && expected_port <= 27999 && ntohs(connection->host.port) == expected_port &&
                !game::Com_IsAnyLocalServerRunning() && game::Com_GameMode_GetActiveGameMode() == game::GAME_MODE_CP &&
                game::CL_IsGameClientActive(0) && game::clientUIActives[0].connectionState == game::CA_ACTIVE;
            agent_packet reply;
            { std::lock_guard lock(agent_packet_mutex); reply = std::move(agent_reply); agent_reply = {}; }
            if (agent_safety.connected)
            {
                if (agent_connection_challenge != connection->challenge)
                {
                    if (agent_runtime.client->active()) { agent_runtime.client->stop(agent_binding); agent_result("connection_changed"); }
                    agent_connection_challenge = connection->challenge; agent_last_ack = agent_last_probe;
                    agent_safety.protected_now = false; agent_safety.received = 0;
                }
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
                agent_last_probe = now;
                network::send(connection->host, "parisAgentQuery", std::format("{} {}", agent_runtime.client_nonce, now));
            }
            if (const auto* failure = agent_runtime.client->tick(now, agent_safety, agent_binding)) agent_result(failure);
            utils::io::write_file("iw7-mod/paris-agent.safety", std::format("{} {} {} {} {}\n", GetCurrentProcessId(), agent_runtime.client_nonce,
                static_cast<int>(iw7::agent::scenario::safe(agent_safety, now)), now, agent_safety.map.empty() ? "none" : agent_safety.map));
            static std::string previous;
            const auto wire = utils::io::read_file("iw7-mod/paris-agent.request");
            if (wire.empty() || wire == previous) return;
            previous = wire; iw7::agent::request request;
            if (!iw7::agent::parse(wire, request)) { agent_result("parse_rejected"); return; }
            if (vote_witness_running && request.operation != iw7::agent::action::abort && request.operation != iw7::agent::action::release_all)
            { agent_result("vote_busy", &request); return; }
            if (request.operation == iw7::agent::action::arm && !agent_bindings_available())
            { agent_result("binding_rejected", &request); return; }
            agent_binding_failed = false;
            const auto* status = agent_runtime.client->accept(request, now, agent_safety, agent_binding);
            if (std::strcmp(status, "armed") == 0)
            {
                // A prior legacy voteholdnext uses different synthetic keys.
                // Clear those keys before the scenario owns Fire/ADS.
                vote_binding("+attack", false); vote_binding("+speed_throw", false);
            }
            if (agent_binding_failed)
            {
                agent_runtime.client->release_all(agent_binding);
                agent_safety.protected_now = false;
                agent_runtime.client->tick(now, agent_safety, agent_binding); status = "binding_rejected";
            }
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
            if (!clients || *game::svs_numclients > 4) return;
            std::lock_guard lock(safety_mutex);
            for (unsigned slot = 0; slot < *game::svs_numclients; ++slot)
                if (clients[slot].header.state >= game::CS_CONNECTED &&
                    (clients[slot].header.state != game::CS_ACTIVE || !refresh_protection(slot))) return;
            command::execute("map " + map, false);
            utils::io::write_file("iw7-mod/paris-server-client.response", request);
            console::info("[Paris voice base test] Owned protected map request queued: %s.\n", map.c_str());
        }
        int lab_port()
        {
            const auto* port = game::Dvar_FindVar("paris_lab_server_port");
            if (!port) return 0;
            int value = 0;
            if (port->type == game::DVAR_TYPE_STRING && port->current.string)
                value = std::atoi(port->current.string);
            else if (port->type == game::DVAR_TYPE_INT) value = port->current.integer;
            if (value == 27016 && utils::flags::has_flag("paris-voice-base-test")) return value;
            return value >= 27100 && value <= 27999 ? value : 0;
        }
        void client_request()
        {
            if (connect_pending && (utils::flags::has_flag("paris-isolated-lab") || utils::flags::has_flag("paris-voice-base-test")) &&
                game::Com_GameMode_GetActiveGameMode() != game::GAME_MODE_CP)
            {
                game::Com_GameMode_SetDesiredGameMode(game::GAME_MODE_CP);
                return;
            }
            if (connect_pending && (utils::flags::has_flag("paris-isolated-lab") || utils::flags::has_flag("paris-voice-base-test")) &&
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
            const bool voice_control = action == "voicemute" || action == "voiceunmute" || action == "voicedisable" || action == "voiceenable" || action == "voicerestore" || action == "voicecodecprobe" || action == "voiceconcurrentprobe" || action == "voicesoakprobe";
            const bool vote_input = action == "votenext" || action == "voteprevious" || action == "voteboth" || action == "voteholdnext" || action == "voterelease" || action == "votewitness";
            if (vote_input && !utils::flags::has_flag("paris-isolated-lab")) return;
            if (vote_input && vote_witness_running) return;
            if (vote_input && agent_runtime.client && agent_runtime.client->active()) return;
            if (voice_control && (!utils::flags::has_flag("iw7-voice-relay") || !utils::flags::has_flag("paris-voice-base-test"))) return;
            if (action != "capture" && action != "stop" && action != "help" && action != "mods" && action != "close" && action != "connect" && action != "voiceprobe" && action != "voicereleasedprobe" && action != "witnessroster" && action != "registerwitness" && !voice_control && !vote_input) return;
            if ((action == "witnessroster" || action == "registerwitness") && (!utils::flags::has_flag("paris-voice-registration-witness") ||
                !utils::flags::has_flag("paris-voice-base-test"))) return;
            if ((action == "voiceprobe" || action == "voicereleasedprobe" || action == "voicecodecprobe" || action == "voiceconcurrentprobe" || action == "voicesoakprobe") && (!utils::flags::has_flag("paris-voice-native-trace") ||
                !((utils::flags::has_flag("paris-isolated-lab") && utils::flags::has_flag("paris-voice-audio-lab")) ||
                  utils::flags::has_flag("paris-voice-base-test")))) return;
            if (action == "connect")
            {
                if (!utils::flags::has_flag("paris-isolated-lab") && !utils::flags::has_flag("paris-voice-base-test")) return;
                if (!lab_port()) return;
                connect_pending = true;
            }
            if (action == "capture")
            {
                const auto graphics_value = [](const char* name)
                {
                    const auto* dvar = game::Dvar_FindVar(name);
                    return dvar && dvar->type == game::DVAR_TYPE_INT ? dvar->current.integer : -1;
                };
                console::info("[Paris lab graphics] picmip=%d; bump=%d; spec=%d; tick_ms=%llu\n",
                    graphics_value("r_picmip"), graphics_value("r_picmip_bump"), graphics_value("r_picmip_spec"), GetTickCount64());
                command::execute("capture_frame server-modules-fixture", true);
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
            else if (action == "help") command::execute("cmd say ..help", true);
            else if (action == "mods") command::execute("cmd say ..mods", true);
            else if (action == "close") command::execute("cmd say ..close", true);
            else if (action == "voiceprobe") command::execute("paris_voice_native_probe", true);
            else if (action == "voicereleasedprobe") command::execute("paris_voice_native_released_probe", true);
            else if (action == "voicecodecprobe") command::execute("paris_voice_native_codec_probe", true);
            else if (action == "voiceconcurrentprobe") command::execute("paris_voice_native_concurrent_probe", true);
            else if (action == "voicesoakprobe") command::execute("paris_voice_native_soak_probe", true);
            else if (action == "voicemute") command::execute("paris_voice_test_mute", true);
            else if (action == "voiceunmute") command::execute("paris_voice_test_unmute", true);
            else if (action == "voicedisable") command::execute("paris_voice_test_disable", true);
            else if (action == "voiceenable") command::execute("paris_voice_test_enable", true);
            else if (action == "voicerestore") command::execute("paris_voice_test_restore", true);
            else if (action == "witnessroster") command::execute("paris_voice_registration_roster", true);
            else if (action == "registerwitness") command::execute("paris_voice_register_witness", true);
            else if (action == "stop")
            {
                if (agent_runtime.client) agent_runtime.client->stop(agent_binding);
                command::execute("paris_voice_test_restore", true);
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
            if (!game::environment::is_dedi() && utils::flags::has_flag("paris-server-client-test"))
            {
                scheduler::loop(client_request, scheduler::main, 100ms);
                if (utils::flags::has_flag("paris-isolated-lab"))
                {
                    agent_runtime.activate(GetCurrentProcessId(), true, false, agent_nonce);
                    utils::io::write_file("iw7-mod/paris-agent.session", std::format("{} {}\n", GetCurrentProcessId(), agent_runtime.client_nonce));
                    network::on("parisAgentSafe", agent_receive_reply);
                    scheduler::loop(agent_client_tick, scheduler::main, 50ms);
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
            gsc::method::add("paris_rhino_test_protect", [](game::scr_entref_t ent, const gsc::function_args&) -> scripting::script_value
            {
                if (!utils::flags::has_flag("paris-rhino-probe") && !utils::flags::has_flag("paris-isolated-lab")) return false;
                return protect_player(ent);
            });
            gsc::method::add("paris_test_safety_snapshot", [](game::scr_entref_t ent, const gsc::function_args&) -> scripting::script_value
            {
                return protection_snapshot(ent);
            });
        }
    };
}
REGISTER_COMPONENT(paris_test_fixture::component)
