#pragma once
#include <cstdint>
#include <string>
#include <string_view>

namespace paris_test_fixture
{
    struct kick_context
    {
        bool dedicated{}, fixture{}, zombies{}, private_access{}, loopback{};
        bool bound_identity{}, connected{}, godmode{}, cheats_disabled{}, native_inactivity_disabled{};
    };
    inline bool allow_inactivity_exception(const kick_context& c, std::string_view reason)
    {
        return reason == "EXE_PLAYERKICKED_INACTIVE" && c.dedicated && c.fixture && c.zombies &&
            c.private_access && c.loopback && c.bound_identity && c.connected && c.godmode &&
            c.cheats_disabled && c.native_inactivity_disabled;
    }
    bool suppress_inactivity_kick(int client_num, const char* reason);
    bool is_protected_player(int client_num);

    struct client_test_protection
    {
        bool protected_now{}, current_loopback{};
        unsigned pid{}, port{}, expected_port{};
        std::uint64_t query_tick{}, observed_tick{};
        std::string nonce, generation, challenge, map;
    };
    // Value-snapshot validity only: neither a world lifetime nor a physics epoch.
    inline bool client_protection_current(const client_test_protection& s, std::uint64_t now)
    {
        const auto token = [](std::string_view v) {
            return v.size() == 32 && v.find_first_not_of("0123456789abcdef") == std::string_view::npos;
        };
        const bool known_map = s.map == "cp_zmb" || s.map == "cp_rave" || s.map == "cp_disco" || s.map == "cp_town" || s.map == "cp_final";
        return s.protected_now && s.current_loopback && s.pid && s.expected_port >= 27100 && s.expected_port <= 27999 &&
            s.port == s.expected_port && s.query_tick && s.observed_tick >= s.query_tick && now >= s.observed_tick &&
            now - s.query_tick <= 500 && token(s.nonce) && token(s.generation) && !s.challenge.empty() && known_map;
    }
    // Scheduler main only; invalid/foreign/stale state returns an empty value.
    // Reuses the existing server-confirmed protection handshake, without input
    // authority or a client-world reset promise.
    client_test_protection client_protection(const char** refusal_reason = nullptr);
}
