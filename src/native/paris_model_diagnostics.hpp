#pragma once
#include <cstdint>
#include <cstddef>
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
    // Main thread only. Caller supplies the existing exact-connection safety
    // result; this observer cannot manufacture protection or a model index.
    void observe_client(bool protected_now, std::uint64_t probe_tick,
        std::string_view client_nonce, std::string_view server_generation,
        std::string_view connection_challenge);
}
