#pragma once
#include <cstddef>
#include <cstdint>

// Memory watch for isolated lab clients (-paris-watch with -paris-isolated-lab). See docs/MEMORY-WATCH.md.
namespace paris_watch
{
    // Starts one recording of `count` copies of the block [address, address + size), one every `interval_ms`, taken on
    // the main thread. Returns false (and prints a console error) when the component is not active, a recording is
    // still running or being written, or a limit is exceeded. Call it from the main thread only.
    bool start(std::uintptr_t address, std::size_t size, unsigned interval_ms, unsigned count);
}
