#pragma once
// Marks a debugger that has the present listener below. paris_see.cpp builds to nothing without it, so a kept build
// tree that still holds that file can serve a build from an older checkout.
#define PARIS_DEBUGGER_PRESENT_LISTENER 1
#include <cstdint>
#include <cstddef>
struct IDXGISwapChain;
namespace paris_debugger
{
    void render_frame(IDXGISwapChain* swap_chain) noexcept;
    // One function called on the renderer thread at every present, under the render mutex, after the frame capture.
    void set_present_listener(void (*listener)(IDXGISwapChain*)) noexcept;
    std::uint64_t begin(std::size_t id) noexcept;
    void end(std::size_t id, std::uint64_t start) noexcept;
    class scope
    {
        std::size_t id_;
        std::uint64_t start_;
    public:
        explicit scope(std::size_t id) noexcept : id_(id), start_(begin(id)) {}
        ~scope() { end(id_, start_); }
        scope(const scope&) = delete;
        scope& operator=(const scope&) = delete;
    };
}
