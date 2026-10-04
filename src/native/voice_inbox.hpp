#pragma once
#include "voice_wire.hpp"
#include <algorithm>
#include <array>
#include <deque>
#include <mutex>

namespace voice
{
    // Network callbacks never inspect engine state or decode untrusted packets.
    // The game thread publishes admitted IPv4:port endpoints. Each has its own
    // bounded queue, so one sender cannot consume another player's allowance.
    class inbox
    {
    public:
        using endpoint = std::uint64_t;
        using sources = std::array<endpoint, state::max_speakers>;
        static constexpr unsigned server_capacity = 32;
        static constexpr unsigned client_capacity = 128;
        static constexpr std::uint64_t max_age_ms = 500;
        struct packet
        {
            endpoint source;
            std::string bytes;
            std::uint64_t time;
        };

        void admit(const sources& current, unsigned capacity)
        {
            std::lock_guard lock(mutex_);
            capacity_ = std::min(capacity, client_capacity);
            for (unsigned slot = 0; slot < queues_.size(); ++slot)
            {
                auto& queue = queues_[slot];
                if (sources_[slot] != current[slot])
                    queue.clear();
                while (queue.size() > capacity_)
                    queue.pop_front();
            }
            sources_ = current;
        }

        bool push(endpoint source, std::string_view bytes, std::uint64_t time)
        {
            if (!source || bytes.empty() || bytes.size() > wire::max_packet_bytes)
                return false;
            std::lock_guard lock(mutex_);
            const auto found = std::find(sources_.begin(), sources_.end(), source);
            if (found == sources_.end())
                return false;
            auto& queue = queues_[static_cast<std::size_t>(found - sources_.begin())];
            if (queue.size() >= capacity_)
                return false;
            queue.push_back({source, std::string(bytes), time});
            return true;
        }

        template <typename Clock>
        std::vector<packet> drain(Clock clock, unsigned& expired)
        {
            std::lock_guard lock(mutex_);
            // Sample after locking: callbacks may enqueue between a caller's
            // earlier tick snapshot and this drain. Those packets are not future
            // input and must not be discarded at a clock tick boundary.
            const auto time = clock();
            std::vector<packet> result;
            expired = 0;
            // Round-robin across sources; preserve each sender's arrival order.
            bool pending;
            do
            {
                pending = false;
                for (auto& queue : queues_)
                {
                    if (queue.empty())
                        continue;
                    pending = true;
                    auto& front = queue.front();
                    if (time < front.time || time - front.time > max_age_ms)
                        ++expired;
                    else
                        result.push_back(std::move(front));
                    queue.pop_front();
                }
            } while (pending);
            return result;
        }

    private:
        std::mutex mutex_;
        sources sources_{};
        unsigned capacity_{};
        std::array<std::deque<packet>, state::max_speakers> queues_;
    };
}
