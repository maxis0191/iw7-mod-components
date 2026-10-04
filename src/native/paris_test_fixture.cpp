#include <std_include.hpp>
#include "loader/component_loader.hpp"
#include "game/game.hpp"
#include "network.hpp"
#include "scheduler.hpp"
#include "console/console.hpp"
#include "gsc/script_extension.hpp"
#include <utils/flags.hpp>
#include <utils/io.hpp>
#include "command.hpp"
#include "party.hpp"
#include "paris_test_safety.hpp"

namespace paris_test_fixture
{
    namespace
    {
        struct protected_player { std::string identity; game::netadr_s address{}; };
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
            if (!bound_player(slot) || !cheats || cheats->current.enabled || !inactivity || inactivity->type != game::DVAR_TYPE_INT) return false;
            game::g_entities[slot].flags |= 1;
            game::Dvar_SetInt(inactivity, 0);
            return (game::g_entities[slot].flags & 1) != 0 && inactivity->current.integer == 0;
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
                if (bound_player(slot) && (game::g_entities[slot].flags & 1)) ++count;
            const auto* inactivity = engine_inactivity();
            console::info("[Paris test safety] protected=%u native_inactivity=%d script_inactivity_suppressed=%llu tick_ms=%llu\n",
                count, inactivity && inactivity->type == game::DVAR_TYPE_INT ? inactivity->current.integer : -1,
                script_inactivity_suppressed, GetTickCount64());
        }
        bool connect_pending = false;
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
            const bool voice_control = action == "voicemute" || action == "voiceunmute" || action == "voicedisable" || action == "voiceenable" || action == "voicerestore";
            if (voice_control && (!utils::flags::has_flag("iw7-voice-relay") || !utils::flags::has_flag("paris-voice-base-test"))) return;
            if (action != "capture" && action != "stop" && action != "help" && action != "mods" && action != "close" && action != "connect" && action != "voiceprobe" && action != "voicereleasedprobe" && action != "witnessroster" && action != "registerwitness" && !voice_control) return;
            if ((action == "witnessroster" || action == "registerwitness") && (!utils::flags::has_flag("paris-voice-registration-witness") ||
                !utils::flags::has_flag("paris-voice-base-test"))) return;
            if ((action == "voiceprobe" || action == "voicereleasedprobe") && (!utils::flags::has_flag("paris-voice-native-trace") ||
                !((utils::flags::has_flag("paris-isolated-lab") && utils::flags::has_flag("paris-voice-audio-lab")) ||
                  utils::flags::has_flag("paris-voice-base-test")))) return;
            if (action == "connect")
            {
                if (!utils::flags::has_flag("paris-isolated-lab") && !utils::flags::has_flag("paris-voice-base-test")) return;
                if (!lab_port()) return;
                connect_pending = true;
            }
            if (action == "capture") command::execute("capture_frame server-modules-fixture", true);
            else if (action == "help") command::execute("cmd say ..help", true);
            else if (action == "mods") command::execute("cmd say ..mods", true);
            else if (action == "close") command::execute("cmd say ..close", true);
            else if (action == "voiceprobe") command::execute("paris_voice_native_probe", true);
            else if (action == "voicereleasedprobe") command::execute("paris_voice_native_released_probe", true);
            else if (action == "voicemute") command::execute("paris_voice_test_mute", true);
            else if (action == "voiceunmute") command::execute("paris_voice_test_unmute", true);
            else if (action == "voicedisable") command::execute("paris_voice_test_disable", true);
            else if (action == "voiceenable") command::execute("paris_voice_test_enable", true);
            else if (action == "voicerestore") command::execute("paris_voice_test_restore", true);
            else if (action == "witnessroster") command::execute("paris_voice_registration_roster", true);
            else if (action == "registerwitness") command::execute("paris_voice_register_witness", true);
            else if (action == "stop") { command::execute("paris_voice_test_restore", true); command::execute("disconnect", true); scheduler::once([] { command::execute("quit", true); }, scheduler::main, 1s); }
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
        const bool bound = bound_player(slot);
        const auto* cheats = game::Dvar_FindVar("sv_cheats");
        const auto* inactivity = engine_inactivity();
        const kick_context context{game::environment::is_dedi(), utils::flags::has_flag("paris-server-test"),
            game::Com_GameMode_GetActiveGameMode() == game::GAME_MODE_CP, private_fixture(), bound, bound, bound,
            bound && (game::g_entities[slot].flags & 1) != 0, cheats && !cheats->current.enabled,
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
                scheduler::loop(client_request, scheduler::main, 100ms);
            if (game::environment::is_dedi() && utils::flags::has_flag("paris-server-test"))
            {
                scheduler::loop(maintain_protection, scheduler::server, 100ms);
                scheduler::loop(safety_status, scheduler::server, 10s);
            }
        gsc::method::add("paris_test_protect", [](game::scr_entref_t ent, const gsc::function_args&) -> scripting::script_value
        {
            std::lock_guard lock(safety_mutex);
            const auto* password = game::Dvar_FindVar("g_password");
            if (!game::environment::is_dedi() || !utils::flags::has_flag("paris-server-test") ||
                !password || !password->current.string || !*password->current.string ||
                ent.classnum || ent.entnum >= 4) return false;
            const auto* clients = *game::svs_clients;
            if (!clients || clients[ent.entnum].header.state < game::CS_CONNECTED) return false;
            const auto& address = clients[ent.entnum].remoteAddress;
            if (address.type != game::NA_LOOPBACK &&
                !(address.type == game::NA_IP && address.ip[0] == 127 && address.ip[1] == 0 && address.ip[2] == 0 && address.ip[3] == 1)) return false;
            auto& entity = game::g_entities[ent.entnum];
            if (!entity.client) return false;
            const std::string identity(clients[ent.entnum].playerGuid, strnlen(clients[ent.entnum].playerGuid, sizeof(clients[ent.entnum].playerGuid)));
            if (identity.empty()) return false;
            protected_players[ent.entnum] = {identity, address};
            return refresh_protection(ent.entnum);
        });
        }
    };
}
REGISTER_COMPONENT(paris_test_fixture::component)
