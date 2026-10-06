#pragma once
#include <array>
#include <cstdint>
#include <limits>
#include <mutex>

namespace iw7::debugger
{
    struct frame_window
    {
        std::uintptr_t key{};
        std::uint64_t last_ns{}, intervals{}, total_ns{}, max_ns{};
    };
    // The first callback establishes a baseline; fixed anonymous channels
    // retain their clock across flushes, without mixing swapchains.
    template <std::size_t N> class frames
    {
        std::array<frame_window, N> values_{};
        std::mutex mutex_;
    public:
        bool record(std::uintptr_t key, std::uint64_t now)
        {
            if (!key || !now) return false;
            std::lock_guard<std::mutex> lock(mutex_);
            for (auto& v : values_)
            {
                if (v.key && v.key != key) continue;
                v.key = key;
                if (v.last_ns && now > v.last_ns)
                {
                    const auto ns = now - v.last_ns;
                    ++v.intervals; v.total_ns += ns;
                    if (ns > v.max_ns) v.max_ns = ns;
                }
                v.last_ns = now;
                return true;
            }
            return false;
        }
        std::array<frame_window, N> take()
        {
            std::lock_guard<std::mutex> lock(mutex_);
            const auto copy = values_;
            for (auto& v : values_) { v.intervals = 0; v.total_ns = 0; v.max_ns = 0; }
            return copy;
        }
    };
    struct counter
    {
        std::uint64_t started{}, calls{}, total_ns{}, max_ns{}, failed_clock{};
    };
    // Fixed storage, consistent snapshots and no lock held across an engine call.
    template <std::size_t N> class counters
    {
        std::array<counter, N> values_{};
        std::mutex mutex_;
    public:
        bool begin(std::size_t id)
        {
            if (id >= N) return false;
            std::lock_guard<std::mutex> lock(mutex_);
            ++values_[id].started;
            return true;
        }
        bool end(std::size_t id, std::uint64_t begin, std::uint64_t end)
        {
            if (id >= N) return false;
            std::lock_guard<std::mutex> lock(mutex_);
            auto& v = values_[id];
            if (end < begin) { ++v.failed_clock; return false; }
            const auto ns = end - begin;
            ++v.calls;
            v.total_ns = ns > std::numeric_limits<std::uint64_t>::max() - v.total_ns ?
                std::numeric_limits<std::uint64_t>::max() : v.total_ns + ns;
            if (ns > v.max_ns) v.max_ns = ns;
            return true;
        }
        std::array<counter, N> take()
        {
            std::lock_guard<std::mutex> lock(mutex_);
            auto copy = values_;
            values_ = {};
            return copy;
        }
    };
}
