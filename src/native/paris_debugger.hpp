#pragma once
#include <cstdint>
#include <cstddef>
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
}
