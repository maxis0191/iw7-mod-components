#pragma once
#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <string_view>

namespace paris_capacity_watch {
constexpr std::uint64_t field_b8 = 0x143C986B8ull, field_c0 = 0x143C986C0ull;
constexpr std::uint64_t canary_dr7 = 0x90001, data_dr7 = 0x990005;
constexpr unsigned max_events = 64;
constexpr std::uint64_t duration_ms = 10000;
enum class phase : unsigned { empty, canary, data, failed, disarming, closed };
inline unsigned checkpoint_operation(phase current, bool stopping) noexcept {
    if (current == phase::closed) return 0;
    return stopping ? 2u : (current == phase::empty ? 1u : 0u);
}
// A terminated original target cannot acknowledge a published ticket. Never
// clear a claimed ticket or one whose helper still owns its notification.
inline void acknowledge_exited_target_ticket(std::atomic<unsigned>& ticket, const std::atomic<bool>& helper_inflight) noexcept {
    auto expected=ticket.load(std::memory_order_acquire);
    // Acquire the published ticket before observing inflight, so ticket=3's
    // publication also orders the helper's preceding inflight=true store.
    if (helper_inflight.load(std::memory_order_acquire)) return;
    if (expected==1 || expected==3) ticket.compare_exchange_strong(expected,0,std::memory_order_acq_rel);
}
enum class kind : unsigned { canary_pass, write, failure, disarmed, baseline };
struct observation {
    std::uint32_t tid{}, roles{}, slot_bits{};
    kind type{};
    std::uint64_t tick_ms{}, qpc{}, rip{}, b8{}, c0{}, previous_b8{}, previous_c0{};
    unsigned zero_seen{}, first_nonzero{};
};
inline bool valid_nonce(std::string_view s) noexcept {
    if (s.size() < 16 || s.size() > 64) return false;
    for (const auto c : s) if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
        (c >= '0' && c <= '9') || c == '_')) return false;
    return true;
}
inline bool elapsed(std::uint64_t now, std::uint64_t start, std::uint64_t limit) noexcept {
    return now >= start && now - start >= limit;
}
inline bool clear_debug_state(std::uint64_t dr0, std::uint64_t dr1, std::uint64_t dr2,
    std::uint64_t dr3, std::uint64_t dr6, std::uint64_t dr7, std::uint64_t flags) noexcept {
    return !dr0 && !dr1 && !dr2 && !dr3 && !(dr6 & 15) && !(dr7 & ~0x400ull) && !(flags & 0x100);
}
// Only the hardware-fixed DR7 bit10 is normalized; all ownership bits stay exact.
inline bool same_dr7(std::uint64_t actual,std::uint64_t expected) noexcept {return (actual&~0x400ull)==(expected&~0x400ull);}
inline bool matching_canary(unsigned bits, std::uint64_t dr0, std::uint64_t dr7,
    std::uint64_t address, std::uint64_t original_dr7) noexcept {
    return bits == 1 && dr0 == address && same_dr7(dr7,original_dr7 | canary_dr7);
}
struct write_history {
    std::uint64_t b8{}, c0{};
    unsigned zero_seen{}, first_nonzero{};
    void observe(unsigned bits, std::uint64_t a, std::uint64_t b) noexcept {
        if (bits & 1) { if (!a) zero_seen |= 1; else if (zero_seen & 1) first_nonzero |= 1; }
        if (bits & 2) { if (!b) zero_seen |= 2; else if (zero_seen & 2) first_nonzero |= 2; }
        b8 = a; c0 = b;
    }
};
// One helper publishes completion. The target may acknowledge ticket=0 before
// notification returns; closure must still see the helper as inflight then.
template<class Notify> inline void publish_checkpoint_completion(
    std::atomic<unsigned>& ticket,std::atomic<bool>& inflight,Notify&& notify) noexcept {
    ticket.store(3,std::memory_order_release);
    notify();
    inflight.store(false,std::memory_order_release);
}
// Each slot is published once, never overwritten. The VEH producer does no IO,
// allocation, waiting, mutex acquisition or stack walking.
template<class T> class fixed_ring {
    std::array<T, max_events> events_{};
    std::array<std::atomic<bool>, max_events> ready_{};
    std::atomic<unsigned> reserved_{0};
public:
    bool append(const T& e) noexcept {
        auto n = reserved_.load(std::memory_order_relaxed);
        do { if (n >= max_events) return false; }
        while (!reserved_.compare_exchange_weak(n, n + 1, std::memory_order_relaxed));
        events_[n] = e; ready_[n].store(true, std::memory_order_release); return true;
    }
    unsigned reserved() const noexcept { return reserved_.load(std::memory_order_acquire); }
    const T* get(unsigned n) const noexcept {
        return n < max_events && ready_[n].load(std::memory_order_acquire) ? &events_[n] : nullptr;
    }
};
// Runner must observe this before file restoration / resource lease release.
// Default true only because an unrequested component owns no handler/registers.
void checkpoint(unsigned role) noexcept;
bool cleanup_confirmed() noexcept;
void request_stop() noexcept;
}
