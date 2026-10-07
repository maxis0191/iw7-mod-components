#pragma once
#include <cstdint>
#include <cstddef>
#include <limits>
#include <string_view>

namespace paris_model_diagnostics
{
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
