#pragma once
#include <cstdint>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <string_view>

namespace paris_model_diagnostics
{
    enum class profile { none, model_probe, original_rig };
    inline profile select_profile(std::string_view fs_game, bool rig_opt_in)
    {
        if (fs_game == "mods/paris_model_probe") return profile::model_probe;
        if (rig_opt_in && fs_game == "mods/sdk_original_rig_probe") return profile::original_rig;
        return profile::none;
    }
    enum class default_status : int { unknown = -1, nondefault = 0, default_asset = 1 };
    inline default_status observed_default(bool returned, bool value)
    {
        return !returned ? default_status::unknown : value ? default_status::default_asset : default_status::nondefault;
    }
    inline bool lod0_span(unsigned lods, unsigned model_surfs, unsigned lod_surfs, unsigned first)
    {
        return lods > 0 && lods <= 6 && model_surfs > 0 && model_surfs <= 256 &&
            lod_surfs > 0 && first < model_surfs && lod_surfs <= model_surfs - first;
    }
    inline bool span_within(std::uintptr_t address, std::size_t bytes, std::uintptr_t base, std::size_t region_size)
    {
        return address && bytes && bytes <= 4096 && address <= std::numeric_limits<std::uintptr_t>::max() - bytes &&
            address >= base && region_size >= bytes && address - base <= region_size - bytes;
    }
    struct scene_permit
    {
        std::uint64_t request{}, arm{}, deadline{}, validated_until{};
        unsigned pid{};
        bool cancelled{};
    };
    inline bool scene_admitted(const scene_permit& p, std::uint64_t request, std::uint64_t arm, unsigned pid, std::uint64_t now)
    {
        return request && p.request == request && arm && p.arm == arm && pid && p.pid == pid && !p.cancelled &&
            now < p.deadline && now <= p.validated_until;
    }
    inline bool scene_binding_matches(std::string_view nonce, std::string_view generation, std::string_view challenge,
        std::string_view current_nonce, std::string_view current_generation, std::string_view current_challenge)
    {
        return !nonce.empty() && !generation.empty() && !challenge.empty() &&
            nonce == current_nonce && generation == current_generation && challenge == current_challenge;
    }
    inline bool scene_count_bounded(int count) { return count >= 0 && count <= 1024; }
    inline int fixed_scene_model(std::uintptr_t pointer, std::uintptr_t first, std::uintptr_t second, std::uintptr_t stock = 0)
    {
        if (!pointer || !first || !second || first == second || (stock && (stock == first || stock == second))) return -1;
        return pointer == first ? 0 : pointer == second ? 1 : stock && pointer == stock ? 2 : -1;
    }
    // Main thread only. Caller supplies the existing exact-connection safety
    // result; this observer cannot manufacture protection or a model index.
    void observe_client(bool protected_now, std::uint64_t probe_tick,
        std::string_view client_nonce, std::string_view server_generation,
        std::string_view connection_challenge, bool capture_requested = true, std::uint64_t scene_arm = 0);
}
