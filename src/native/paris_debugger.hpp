#pragma once
#include <cstdint>
#include <cstddef>
#include "debugger_thread_cpu.hpp"
struct IDXGISwapChain;
namespace paris_debugger
{
    void render_frame(IDXGISwapChain* swap_chain) noexcept;
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
    struct scope2_state
    {
        std::uint64_t wall_start{};
        bool wall_open{};
        iw7::debugger::thread_cpu_ticket cpu;
    };
    void begin_scope2(scope2_state& state) noexcept;
    void end_scope2(scope2_state& state) noexcept;
    // Only the main engine call uses this larger token; GSC scope is unchanged.
    class scope2
    {
        scope2_state state_;
    public:
        scope2() noexcept { begin_scope2(state_); }
        ~scope2() { end_scope2(state_); }
        scope2(const scope2&) = delete;
        scope2& operator=(const scope2&) = delete;
    };
}
