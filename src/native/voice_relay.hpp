#pragma once
#include <cstdint>
#include <string_view>
#include <string>
#include <vector>

namespace voice_relay
{
    // The named player binary supports a plain double-click. Explicit command
    // lines and ordinary/laboratory IW7-Mod binaries retain their own profiles.
    inline void apply_player_defaults(std::string_view executable, int argument_count,
                                      std::vector<std::string>& flags)
    {
        const auto separator = executable.find_last_of("/\\");
        if (separator != std::string_view::npos) executable.remove_prefix(separator + 1);
        std::string name(executable);
        for (auto& c : name) if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
        if (argument_count != 1 || name != "iw7-paris-voice.exe") return;
        flags.insert(flags.end(), {"noupdate", "nosteam", "cpMode", "iw7-voice-relay"});
    }

    // Read-only counters for the private harness; the component itself has no
    // dependency on test protection, fixtures or server-specific configuration.
#ifdef IW7_PARIS_ISOLATED_VOICE_CAPTURE
    struct test_readiness_snapshot
    {
        bool ready{}, loopback{}, both_roles_ready{};
        unsigned slot{}, server_port{};
        std::uint64_t user{}, speaker_generation_low{}, speaker_generation_high{}, observed_tick{};
        std::string game_challenge;
    };
    // Copies transport state under its mutex. No COM call, game mutation, or
    // protection claim. Call from main only; other threads use cached evidence.
    test_readiness_snapshot test_readiness();
#endif

    std::uint64_t encoded_frames();
}
