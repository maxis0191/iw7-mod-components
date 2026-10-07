#pragma once
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
}

#ifdef IW7_PARIS_ISOLATED_VOICE_CAPTURE
#include <cstdint>
#include <string>
namespace paris_test_fixture {
struct client_capture_protection {
    bool protected_now{}, slot_correlated{}, ui_ready{}, talk_valid{};
    int talk_key0{},talk_key1{}; unsigned talk_active{};
    unsigned pid{}, port{}, slot{};
    std::uint64_t query_tick{};
    std::string nonce, generation;
};
// Read on scheduler main only. The integration copies this to its own mutex.
client_capture_protection capture_protection();
}
#endif
