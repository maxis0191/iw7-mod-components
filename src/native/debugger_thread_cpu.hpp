#pragma once
#include <array>
#include <chrono>
#include <cstdint>
#include <limits>
#include <mutex>
#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <Windows.h>
#endif

namespace iw7::debugger
{
    struct thread_cpu_sample
    {
        std::uint32_t tid{}, error{};
        std::uint64_t creation_100ns{}, kernel_100ns{}, user_100ns{};
        std::uint64_t before_ns{}, after_ns{};
        bool ok{};
    };

    inline std::uint64_t thread_cpu_wall_ns() noexcept
    {
        return static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count());
    }

#ifdef _WIN32
    // The component and the standalone Windows fixture call this same helper.
    // GetCurrentThread is a synchronous pseudo-handle: no foreign/opened handle.
    inline thread_cpu_sample capture_current_thread_cpu() noexcept
    {
        thread_cpu_sample s;
        FILETIME creation{}, exit{}, kernel{}, user{};
        s.before_ns = thread_cpu_wall_ns();
        s.tid = GetCurrentThreadId();
        s.ok = GetThreadTimes(GetCurrentThread(), &creation, &exit, &kernel, &user) != FALSE;
        if (!s.ok) s.error = GetLastError();
        s.after_ns = thread_cpu_wall_ns();
        const auto ticks = [](const FILETIME& v) { return (std::uint64_t(v.dwHighDateTime) << 32) | v.dwLowDateTime; };
        if (s.ok)
        {
            s.creation_100ns = ticks(creation);
            s.kernel_100ns = ticks(kernel);
            s.user_100ns = ticks(user);
        }
        return s;
    }
#endif

    // Inclusive upper edges in ns; the final bucket is explicit overflow.
    inline constexpr std::array<std::uint64_t, 15> thread_cpu_histogram_ns{
        250000, 500000, 1000000, 2000000, 4000000, 8000000, 16000000, 32000000,
        64000000, 128000000, 256000000, 512000000, 1000000000, 2000000000, 4000000000
    };
    using thread_cpu_histogram = std::array<std::uint64_t, thread_cpu_histogram_ns.size() + 1>;

    inline void thread_cpu_add(std::uint64_t& value, std::uint64_t delta, bool& saturated) noexcept
    {
        const auto max = (std::numeric_limits<std::uint64_t>::max)();
        if (delta > max - value) { value = max; saturated = true; }
        else value += delta;
    }

    struct thread_cpu_cohort
    {
        std::uint32_t tid{};
        std::uint64_t creation_100ns{}, started{}, completed{}, paired{}, active{};
        std::uint64_t kernel_100ns{}, user_100ns{}, cpu_100ns{};
        std::uint64_t wall_lower_ns{}, wall_upper_ns{}, max_wall_lower_ns{}, max_wall_upper_ns{};
        std::uint64_t acquisition_ns{}, max_acquisition_ns{};
        thread_cpu_histogram wall_lower_histogram{}, cpu_histogram{};
        thread_cpu_sample last_start{}, last_end{};
        bool saturated{};
    };
    struct thread_cpu_snapshot
    {
        static constexpr std::size_t capacity = 4;
        std::array<thread_cpu_cohort, capacity> cohorts{};
        std::uint64_t started{}, completed{}, paired{}, active{};
        std::uint64_t api_failures{}, identity_failures{}, clock_failures{}, cpu_rollbacks{};
        std::uint64_t capacity_drops{}, invalid_tokens{}, cpu_overflows{};
        std::uint32_t last_api_error{};
        bool saturated{};
    };

    class thread_cpu_counters;
    class thread_cpu_ticket
    {
        friend class thread_cpu_counters;
        const thread_cpu_counters* owner_{};
        thread_cpu_sample start_{};
        std::size_t slot_{thread_cpu_snapshot::capacity};
        bool open_{}, attached_{}, used_{};
    public:
        thread_cpu_ticket() = default;
        thread_cpu_ticket(const thread_cpu_ticket&) = delete;
        thread_cpu_ticket& operator=(const thread_cpu_ticket&) = delete;
        bool pending() const noexcept { return open_; }
    };

    // Dedicated four-identity storage; does not enlarge the generic/GSC counters.
    // Identities are never evicted/rebound during a run, including TID reuse.
    class thread_cpu_counters
    {
        thread_cpu_snapshot value_{};
        std::mutex mutex_;
        void add(std::uint64_t& v, std::uint64_t n = 1) { thread_cpu_add(v, n, value_.saturated); }
        static void histogram(thread_cpu_histogram& h, std::uint64_t v, bool cpu, bool& saturated)
        {
            std::size_t i = 0;
            while (i < thread_cpu_histogram_ns.size() && v > thread_cpu_histogram_ns[i] / (cpu ? 100 : 1)) ++i;
            thread_cpu_add(h[i], 1, saturated);
        }
    public:
        bool begin(thread_cpu_ticket& t)
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (t.used_ || value_.active == (std::numeric_limits<std::uint64_t>::max)())
            { add(value_.invalid_tokens); value_.saturated |= !t.used_; return false; }
            t.owner_ = this; t.used_ = t.open_ = true;
            add(value_.started); add(value_.active);
            return true;
        }
        bool attach_start(thread_cpu_ticket& t, const thread_cpu_sample& s)
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (t.owner_ != this || !t.open_ || t.attached_) { add(value_.invalid_tokens); return false; }
            t.start_ = s; t.attached_ = true;
            if (!s.ok || !s.tid || !s.creation_100ns) return false;
            for (std::size_t i = 0; i < value_.cohorts.size(); ++i)
            {
                auto& c = value_.cohorts[i];
                if (c.tid && (c.tid != s.tid || c.creation_100ns != s.creation_100ns)) continue;
                c.tid = s.tid; c.creation_100ns = s.creation_100ns;
                t.slot_ = i;
                thread_cpu_add(c.started, 1, c.saturated); thread_cpu_add(c.active, 1, c.saturated);
                return true;
            }
            add(value_.capacity_drops);
            return false;
        }
        bool end(thread_cpu_ticket& t, const thread_cpu_sample& e)
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (t.owner_ != this || !t.open_) { add(value_.invalid_tokens); return false; }
            t.open_ = false; // Consume once, independently of profiler enable toggles.
            --value_.active; add(value_.completed);
            thread_cpu_cohort* c = t.slot_ < value_.cohorts.size() ? &value_.cohorts[t.slot_] : nullptr;
            if (c) { --c->active; thread_cpu_add(c->completed, 1, c->saturated); }
            const auto& s = t.start_;
            if (!t.attached_ || !s.ok || !e.ok)
            { add(value_.api_failures); value_.last_api_error = !s.ok ? s.error : e.error; return false; }
            if (!s.tid || !s.creation_100ns || s.tid != e.tid || s.creation_100ns != e.creation_100ns)
            { add(value_.identity_failures); return false; }
            if (s.after_ns < s.before_ns || e.before_ns < s.after_ns || e.after_ns < e.before_ns)
            { add(value_.clock_failures); return false; }
            if (e.kernel_100ns < s.kernel_100ns || e.user_100ns < s.user_100ns)
            { add(value_.cpu_rollbacks); return false; }
            if (!c) return false; // Capacity refusal is already visible; never mix identities.
            const auto kernel = e.kernel_100ns - s.kernel_100ns, user = e.user_100ns - s.user_100ns;
            if (kernel > (std::numeric_limits<std::uint64_t>::max)() - user)
            { add(value_.cpu_overflows); return false; }
            const auto cpu = kernel + user, lower = e.before_ns - s.after_ns, upper = e.after_ns - s.before_ns;
            const auto acquisition = upper - lower;
            add(value_.paired);
            thread_cpu_add(c->paired, 1, c->saturated);
            thread_cpu_add(c->kernel_100ns, kernel, c->saturated); thread_cpu_add(c->user_100ns, user, c->saturated);
            thread_cpu_add(c->cpu_100ns, cpu, c->saturated);
            thread_cpu_add(c->wall_lower_ns, lower, c->saturated); thread_cpu_add(c->wall_upper_ns, upper, c->saturated);
            thread_cpu_add(c->acquisition_ns, acquisition, c->saturated);
            if (lower > c->max_wall_lower_ns) c->max_wall_lower_ns = lower;
            if (upper > c->max_wall_upper_ns) c->max_wall_upper_ns = upper;
            if (acquisition > c->max_acquisition_ns) c->max_acquisition_ns = acquisition;
            histogram(c->wall_lower_histogram, lower, false, c->saturated);
            histogram(c->cpu_histogram, cpu, true, c->saturated);
            c->last_start = s; c->last_end = e;
            return true;
        }
        thread_cpu_snapshot take()
        {
            std::lock_guard<std::mutex> lock(mutex_);
            const auto copy = value_;
            value_ = {};
            value_.active = copy.active; value_.saturated = copy.saturated;
            for (std::size_t i = 0; i < copy.cohorts.size(); ++i)
            {
                value_.cohorts[i].tid = copy.cohorts[i].tid;
                value_.cohorts[i].creation_100ns = copy.cohorts[i].creation_100ns;
                value_.cohorts[i].active = copy.cohorts[i].active;
                value_.cohorts[i].saturated = copy.cohorts[i].saturated;
            }
            return copy;
        }
    };
}
