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

namespace paris_test_fixture
{
    namespace
    {
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
            if (action != "capture" && action != "stop" && action != "help" && action != "mods" && action != "close" && action != "connect" && action != "voiceprobe") return;
            if (action == "voiceprobe" && (!utils::flags::has_flag("paris-voice-native-trace") ||
                !((utils::flags::has_flag("paris-isolated-lab") && utils::flags::has_flag("paris-voice-audio-lab")) ||
                  utils::flags::has_flag("paris-voice-base-test")))) return;
            if (action == "connect")
            {
                if (!utils::flags::has_flag("paris-isolated-lab") && !utils::flags::has_flag("paris-voice-base-test")) return;
                if (!lab_port()) return;
                connect_pending = true;
            }
            utils::io::write_file("iw7-mod/paris-server-client.response", request);
            console::info("[Paris module client] Request %s acknowledged.\n", action.c_str());
            if (action == "capture") command::execute("capture_frame server-modules-fixture", true);
            else if (action == "help") command::execute("cmd say ..help", true);
            else if (action == "mods") command::execute("cmd say ..mods", true);
            else if (action == "close") command::execute("cmd say ..close", true);
            else if (action == "voiceprobe") command::execute("paris_voice_native_probe", true);
            else if (action == "stop") { command::execute("disconnect", true); scheduler::once([] { command::execute("quit", true); }, scheduler::main, 1s); }
        }
    }
    class component final : public component_interface
    {
    public:
        void post_unpack() override
        {
            if (!game::environment::is_dedi() && utils::flags::has_flag("paris-server-client-test"))
                scheduler::loop(client_request, scheduler::main, 100ms);
        gsc::method::add("paris_test_protect", [](game::scr_entref_t ent, const gsc::function_args&) -> scripting::script_value
        {
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
            // Same engine flag as upstream's god command, set rather than toggled.
            entity.flags |= 1;
            game::Dvar_SetFromStringByName("g_inactivity", "0", game::DVAR_SOURCE_INTERNAL);
            const auto* inactivity = game::Dvar_FindVar("g_inactivity");
            return (entity.flags & 1) != 0 && inactivity && inactivity->current.integer == 0;
        });
        }
    };
}
REGISTER_COMPONENT(paris_test_fixture::component)
