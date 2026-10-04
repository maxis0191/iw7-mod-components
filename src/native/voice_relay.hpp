#pragma once
#include <cstdint>

namespace voice_relay
{
    // Read-only counters for the private harness; the component itself has no
    // dependency on test protection, fixtures or server-specific configuration.
    std::uint64_t encoded_frames();
}
