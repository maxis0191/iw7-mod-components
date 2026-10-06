#pragma once
#include <array>
#include <cstdint>
#include <limits>
#include <mutex>

namespace iw7::debugger
{
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
