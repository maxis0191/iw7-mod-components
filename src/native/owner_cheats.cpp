#include <std_include.hpp>
#include "loader/component_loader.hpp"
#include "owner_cheats.hpp"
#include "owner_cheats_policy.hpp"
#include "owner_cheats_crypto.hpp"
#include "auth.hpp"
#include "network.hpp"
#include "party.hpp"
#include "scheduler.hpp"
#include "console/console.hpp"
#include "command.hpp"
#include "game/scripting/execution.hpp"
#include "gsc/script_extension.hpp"
#include <utils/cryptography.hpp>
#include <utils/io.hpp>
#include <charconv>

namespace owner_cheats
{
    namespace
    {
        constexpr auto wire = "iw7OwnerCheats1";
        constexpr auto directory = "iw7-mod/owner-cheats/";
        std::recursive_mutex state_mutex;
        crypto::key owner_key, server_key, client_key, trusted_server;
        bool configured{};
        struct session
        {
            game::client_t* connection{};
            game::netadr_s endpoint{};
            std::string identity;
            policy::proof proof;
            std::uint64_t last_hello{};
        };
        std::array<session, 4> sessions{};
        struct packet { game::netadr_s endpoint{}; std::string text; };
        std::mutex queue_mutex;
        std::vector<packet> packets;
        std::uint64_t ingress_window{};
        unsigned ingress_count{};
        game::netadr_s client_host{};
        std::string client_connection, client_nonce, server_nonce, client_identity;
        std::uint64_t client_sent{}, client_issued{}, client_granted{};
        struct connection_epoch { game::netadr_s endpoint{}; std::string token; };
        std::vector<connection_epoch> epochs;

        game::client_t* connection(unsigned slot);
        void teleport(int owner, const command::params_sv& args, bool here)
        {
            const auto reply = [owner](const char* text)
            { console::info("[Owner teleport] slot=%d result=%s\n", owner, text); game::SV_GameSendServerCommand(owner, game::SV_CMD_RELIABLE, text); };
            if (!server_allowed(owner)) { reply("f \"Owner authentication required.\""); return; }
            const auto query = args.join(1);
            if (!policy::safe_target(query)) { reply("f \"Usage: tp <name|#ID> or tphere <name|#ID>. IDs: .players\""); return; }
            try
            {
                std::vector<std::pair<int, std::string>> players;
                for (unsigned slot = 0; slot < 4; ++slot)
                    if (connection(slot))
                        players.emplace_back(slot, scripting::entity({static_cast<uint16_t>(slot), 0}).get<std::string>("name"));
                const auto target = policy::target_slot(query, players);
                if (target < 0) { reply("f \"No unique player found. Use .players and #ID.\""); return; }
                if (target == owner) { reply("f \"Choose another player.\""); return; }
                const scripting::entity player({static_cast<uint16_t>(here ? target : owner), 0});
                const scripting::entity destination({static_cast<uint16_t>(here ? owner : target), 0});
                for (const auto& entity : {player, destination})
                {
                    if (!scripting::call<int>("isalive", {entity}) || entity.get<std::string>("sessionstate") != "playing" ||
                        entity.call("islinked").as<int>() ||
                        scripting::call_script_function(entity, "scripts/cp/cp_laststand", "player_in_laststand", {entity}).as<int>())
                    { reply("f \"Both players must be alive, standing and unlinked.\""); return; }
                }
                const auto origin = destination.get<scripting::vector>("origin");
                if (!server_allowed(owner) || !connection(target)) return;
                // Native GSC SetOrigin updates the entity/teleport state as well
                // as playerState; a raw ps.origin write leaves stale prediction.
                player.call("setorigin", {origin});
                reply("f \"Teleport complete.\"");
                console::info("[Owner teleport] actor=%d target=%d here=%d\n", owner, target, here);
            }
            catch (const std::exception& error)
            { console::info("[Owner teleport] state error=%s\n", error.what()); reply("f \"Teleport refused; player state unavailable.\""); }
        }

        std::string nonce()
        { std::string bytes(32, '\0'); utils::cryptography::random::get_data(bytes.data(), bytes.size()); return policy::hex(bytes); }
        std::string identity(const game::client_t* c)
        {
            if (!c) return {};
            std::string value(c->playerGuid, strnlen(c->playerGuid, sizeof(c->playerGuid)));
            if (value.empty() || value.size() > 16) return {};
            for (char& ch : value) { if (ch >= 'A' && ch <= 'F') ch += 'a' - 'A'; }
            return policy::hex_token(value, value.size()) ? value : std::string{};
        }
        game::client_t* connection(unsigned slot)
        {
            if (!game::environment::is_dedi() || !game::SV_Loaded() ||
                game::Com_GameMode_GetActiveGameMode() != game::GAME_MODE_CP || !*game::svs_clients ||
                slot >= 4 || slot >= *game::svs_numclients) return nullptr;
            auto* c = game::svs_clients.get()[slot];
            return c && c->header.state == game::CS_ACTIVE && c->gentity == &game::g_entities[slot] &&
                c->gentity->client ? c : nullptr;
        }
        bool bound(unsigned slot)
        {
            const auto* c = connection(slot); const auto& s = sessions[slot];
            return c && c == s.connection && !s.identity.empty() && identity(c) == s.identity &&
                network::are_addresses_equal(c->remoteAddress, s.endpoint);
        }
        bool client_connected()
        {
            const auto* state = party::get_server_connection_state();
            return !game::environment::is_dedi() && state && state->hostDefined &&
                state->host.type == game::NA_IP && game::Com_GameMode_GetActiveGameMode() == game::GAME_MODE_CP &&
                !game::Com_IsAnyLocalServerRunning() && game::clientUIActives[0].connectionState == game::CA_ACTIVE &&
                client_connection == state->challenge && network::are_addresses_equal(client_host, state->host);
        }
        std::vector<packet> drain()
        { std::lock_guard lock(queue_mutex); std::vector<packet> out; out.swap(packets); return out; }
        void receive(const game::netadr_s& from, std::string_view bytes)
        {
            if (bytes.empty() || bytes.size() > 512) return;
            std::lock_guard lock(queue_mutex); const auto now = GetTickCount64();
            if (now - ingress_window >= 1000) { ingress_window = now; ingress_count = 0; }
            if (++ingress_count > 32 || packets.size() >= 16) return;
            packets.push_back({from, std::string(bytes)});
        }
        bool load_key(crypto::key& key, const char* name, bool secret)
        {
            try
            {
                const auto path = std::filesystem::path(directory) / name;
                if (!std::filesystem::is_regular_file(path) || std::filesystem::file_size(path) != (secret ? 104u : 72u)) return false;
                std::string bytes;
                const bool result = utils::io::read_file(path.string(), &bytes) && key.load(bytes, secret);
                if (secret && !bytes.empty()) SecureZeroMemory(bytes.data(), bytes.size());
                return result;
            }
            catch (const std::exception&) { return false; }
        }
        void send_signed(const session& s, char role)
        {
            const auto signature = server_key.sign(policy::message(role, s.identity, s.proof.client, s.proof.server));
            if (!signature.empty()) network::send(s.endpoint, wire, std::string(1, role) + " " + s.proof.client + " " + s.proof.server + " " + policy::hex(signature));
        }
        void server_packet(const packet& p)
        {
            const auto args = policy::words(p.text); if (args.empty()) return;
            unsigned slot{};
            while (slot < sessions.size() && (!bound(slot) || !network::are_addresses_equal(sessions[slot].endpoint, p.endpoint))) ++slot;
            if (slot == sessions.size()) return;
            auto& s = sessions[slot]; const auto now = GetTickCount64();
            if (args.size() == 3 && args[0] == "H" && args[1] == s.identity && policy::hex_token(args[2], 64))
            {
                if (now - s.last_hello < 1000) return;
                s.last_hello = now;
                if (s.proof.client != args[2] || (!s.proof.allowed(now) && (s.proof.used || now >= s.proof.expires)))
                    s.proof = {args[2], nonce(), now + 10000, 0, false};
                send_signed(s, s.proof.allowed(now) ? 'A' : 'S');
            }
            else if (args.size() == 4 && args[0] == "P" && s.proof.pending(args[1], args[2], now))
            {
                const auto signature = policy::unhex(args[3], 64);
                const bool valid = owner_key.verify(policy::message('P', s.identity, args[1], args[2]), signature);
                if (!s.proof.consume(args[1], args[2], now, valid)) return;
                send_signed(s, 'A');
                console::info("[Owner cheats] Authenticated console access; slot=%u; sv_cheats unchanged.\n", slot);
            }
        }
        void server_tick()
        {
            std::lock_guard lock(state_mutex);
            for (unsigned slot = 0; slot < sessions.size(); ++slot)
            {
                auto* c = connection(slot);
                if (!c) { sessions[slot] = {}; continue; }
                if (!bound(slot)) sessions[slot] = {c, c->remoteAddress, identity(c), {}, 0};
            }
            for (const auto& p : drain()) server_packet(p);
        }
        void client_tick()
        {
            std::lock_guard lock(state_mutex);
            const auto* state = party::get_server_connection_state();
            if (!state || !state->hostDefined || state->host.type != game::NA_IP ||
                game::Com_GameMode_GetActiveGameMode() != game::GAME_MODE_CP || game::Com_IsAnyLocalServerRunning() ||
                game::clientUIActives[0].connectionState != game::CA_ACTIVE)
            { client_nonce.clear(); client_connection.clear(); client_granted = 0; drain(); return; }
            const auto now = GetTickCount64();
            if (client_nonce.empty() || !client_connected() || now - client_issued >= 20000)
            {
                client_host = state->host; client_connection = state->challenge; client_nonce = nonce(); server_nonce.clear();
                client_issued = now; client_sent = 0; client_granted = 0;
                char id[17]{}; const auto end = std::to_chars(id, id + 16, auth::get_guid(), 16).ptr;
                client_identity.assign(id, end);
            }
            if (!client_granted && now - client_sent >= 2000)
            { network::send(client_host, wire, "H " + client_identity + " " + client_nonce); client_sent = now; }
            for (const auto& p : drain())
            {
                if (!network::are_addresses_equal(p.endpoint, client_host)) continue;
                const auto args = policy::words(p.text);
                if (args.size() != 4 || args[1] != client_nonce || !policy::hex_token(args[2], 64)) continue;
                const auto signature = policy::unhex(args[3], 64);
                if (args[0] == "S" && trusted_server.verify(policy::message('S', client_identity, args[1], args[2]), signature))
                {
                    server_nonce = args[2];
                    const auto proof = client_key.sign(policy::message('P', client_identity, client_nonce, server_nonce));
                    if (!proof.empty()) network::send(client_host, wire, "P " + client_nonce + " " + server_nonce + " " + policy::hex(proof));
                }
                else if (args[0] == "A" && args[2] == server_nonce &&
                    trusted_server.verify(policy::message('A', client_identity, args[1], args[2]), signature))
                    client_granted = client_issued + 40000;
            }
        }
    }
    bool server_allowed(int slot)
    {
        std::lock_guard lock(state_mutex);
        return configured && slot >= 0 && slot < 4 && bound(static_cast<unsigned>(slot)) &&
            sessions[slot].proof.allowed(GetTickCount64());
    }
    bool client_allowed()
    {
        std::lock_guard lock(state_mutex);
        return configured && client_connected() && client_granted && GetTickCount64() < client_granted;
    }
    void invalidate(const game::netadr_s* endpoint)
    {
        if (!endpoint) return;
        std::lock_guard lock(state_mutex);
        for (auto& s : sessions) if (s.connection && network::are_addresses_equal(s.endpoint, *endpoint)) s = {};
        // A direct connection gets a new opaque token; map loads retain it.
        // This is lifetime bookkeeping, independent of owner authentication.
        for (auto it = epochs.begin(); it != epochs.end(); ++it)
            if (network::are_addresses_equal(it->endpoint, *endpoint)) { epochs.erase(it); break; }
        if (epochs.size() >= 16) epochs.erase(epochs.begin());
        epochs.push_back({*endpoint, nonce()});
    }
    class component final : public component_interface
    {
    public:
        void post_unpack() override
        {
            gsc::method::add("paris_get_connection_id", [](game::scr_entref_t ent, const gsc::function_args&) -> scripting::script_value
            {
                std::lock_guard lock(state_mutex);
                if (ent.classnum != 0) return scripting::script_value{};
                const auto* client = connection(ent.entnum);
                if (!client) return scripting::script_value{};
                for (const auto& epoch : epochs)
                    if (network::are_addresses_equal(epoch.endpoint, client->remoteAddress)) return epoch.token;
                return scripting::script_value{};
            });
            scheduler::once([]
            {
                const bool dedicated = game::environment::is_dedi();
                configured = dedicated ? load_key(owner_key, "owner-public.blob", false) && load_key(server_key, "server-private.blob", true)
                    : load_key(client_key, "client-private.blob", true) && load_key(trusted_server, "trusted-server-public.blob", false);
                console::info("[Owner cheats] configured=%d; dedicated=%d; global sv_cheats unchanged.\n", configured, dedicated);
                command::add("owner_cheats_status", []
                {
                    if (game::environment::is_dedi())
                        for (int slot = 0; slot < 4; ++slot) console::info("[Owner cheats] slot=%d allowed=%d\n", slot, server_allowed(slot));
                    else console::info("[Owner cheats] local_allowed=%d\n", client_allowed());
                });
                if (!configured) return;
                if (dedicated)
                {
                    command::add_sv("tp", [](int slot, const command::params_sv& args) { teleport(slot, args, false); });
                    command::add_sv("tphere", [](int slot, const command::params_sv& args) { teleport(slot, args, true); });
                }
                else for (const auto* name : {"tp", "tphere"})
                    command::add(name, [name](const command::params& args)
                    {
                        const auto target = args.join(1);
                        console::info("[Owner teleport] client command=%s allowed=%d\n", name, client_allowed());
                        if (!client_allowed() || !policy::safe_target(target))
                        { console::info("Owner access required. Usage: %s <name|#ID>; IDs: .players\n", name); return; }
                        command::execute(std::string("cmd ") + name + " \"" + target + "\"");
                    });
                network::on(wire, receive);
                if (dedicated) scheduler::loop(server_tick, scheduler::pipeline::server, 100ms);
                else scheduler::loop(client_tick, scheduler::pipeline::main, 100ms);
            }, scheduler::pipeline::main);
        }
    };
}
REGISTER_COMPONENT(owner_cheats::component)
