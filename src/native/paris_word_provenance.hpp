#pragma once
#include <array>
#include <atomic>
#include <cstdint>
#include <string_view>

// STARTUP only. This component does not extend the existing capacity watcher.
namespace paris_word_provenance {
constexpr std::uint64_t target_word = 0x141238362ull;
constexpr std::uint64_t window_start = 0x141238342ull;
constexpr unsigned window_bytes = 64, max_records = 64, max_diagnostics = 16;
constexpr std::uint64_t duration_ms = 10000, checkpoint_ms = 200;
constexpr unsigned max_tids = 1, max_snapshots = 4;
constexpr std::uint64_t canary_dr7 = 0x90001, word_dr7 = 0x50001;
constexpr std::uint64_t dr6_debug_causes = 15 | (1ull << 13) | (1ull << 14) | (1ull << 15);
static_assert((target_word & 1) == 0 && target_word >= window_start &&
    target_word + 2 <= window_start + window_bytes);

enum class boundary : unsigned { loaded, after_post_load, before_post_unpack, after_post_unpack };
enum class state : unsigned { empty, canary, word, failed, disarming, closed };
enum class record_kind : unsigned { snapshot, baseline, canary, write, restore, failure };
enum class disposition : unsigned { not_acquired, open, closed, refused, unknown };
enum class fault : unsigned {
    activation, phase_order, wrong_tid, snapshot_query, snapshot_read, snapshot_changed,
    identity, thread_times, thread_exit, suspend, preexisting_suspend, resume,
    get_context, context_flags, foreign_dr, set_context, readback, canary,
    ticket_expired, deadline, event_limit, foreign_step, unattributed_change,
    handler_remove, handle_close, output, registration, count
};

struct launch_flags {
    bool dedicated{}, lab{}, server_test{}, debugger{}, startup{}, reviewed{};
    bool capacity_watch{}, restart{};
};
constexpr bool permitted(const launch_flags& f) noexcept {
    return f.dedicated && f.lab && f.server_test && f.debugger && f.startup &&
        f.reviewed && !f.capacity_watch && !f.restart;
}
inline bool valid_nonce(std::string_view s) noexcept {
    if (s.size() < 16 || s.size() > 64) return false;
    for (const auto c : s) if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
        (c >= '0' && c <= '9') || c == '_')) return false;
    return true;
}
inline bool valid_hash(std::string_view s) noexcept {
    if (s.size() != 64) return false;
    for (const auto c : s) if (!((c >= '0' && c <= '9') || (c >= 'A' && c <= 'F'))) return false;
    return true;
}
constexpr bool elapsed(std::uint64_t now, std::uint64_t start, std::uint64_t limit) noexcept {
    return now >= start && now - start >= limit;
}
constexpr bool same_dr7(std::uint64_t a, std::uint64_t b) noexcept {
    return (a & ~0x400ull) == (b & ~0x400ull);
}
struct debug_registers { std::uint64_t dr0{}, dr1{}, dr2{}, dr3{}, dr6{}, dr7{}, flags{}; };
constexpr bool clear_debug_state(const debug_registers& c) noexcept {
    return !c.dr0 && !c.dr1 && !c.dr2 && !c.dr3 && !(c.dr6 & dr6_debug_causes) &&
        !(c.dr7 & ~0x400ull) && !(c.flags & 0x100);
}
constexpr bool owned(const debug_registers& c, const debug_registers& saved,
    state phase, std::uint64_t canary_address) noexcept {
    if (c.dr1 != saved.dr1 || c.dr2 != saved.dr2 || c.dr3 != saved.dr3) return false;
    return phase == state::canary ? c.dr0 == canary_address && same_dr7(c.dr7, saved.dr7 | canary_dr7) :
        phase == state::word && c.dr0 == target_word && same_dr7(c.dr7, saved.dr7 | word_dr7);
}
constexpr bool exact_baseline(const debug_registers& c, const debug_registers& saved) noexcept {
    return c.dr0 == saved.dr0 && c.dr1 == saved.dr1 && c.dr2 == saved.dr2 &&
        c.dr3 == saved.dr3 && c.dr6 == saved.dr6 && c.dr7 == saved.dr7 && !(c.flags & 0x100);
}
constexpr bool same_bootstrap(unsigned loaded_tid, unsigned current_tid) noexcept {
    return loaded_tid != 0 && loaded_tid == current_tid;
}
constexpr bool unexpected_baseline(state phase) noexcept {
    return phase == state::canary || phase == state::word;
}
struct region {
    std::uint64_t base{}, allocation{}, size{};
    unsigned state{}, type{}, protection{}, allocation_protection{};
};
constexpr bool valid_window(const region& r) noexcept {
    const auto access = r.protection & 0xff;
    return r.base <= window_start && r.size >= window_bytes &&
        window_start - r.base <= r.size - window_bytes && r.allocation == 0x140000000ull &&
        r.state == 0x1000 && r.type == 0x1000000 && !(r.protection & 0x100) &&
        (access == 0x20 || access == 0x40 || access == 0x80);
}
constexpr bool same_region(const region& a, const region& b) noexcept {
    return a.base == b.base && a.allocation == b.allocation && a.size == b.size &&
        a.state == b.state && a.type == b.type && a.protection == b.protection &&
        a.allocation_protection == b.allocation_protection;
}
constexpr unsigned operation(state phase, bool stopping, bool helper_stopping) noexcept {
    if (helper_stopping || phase == state::closed) return 0;
    return stopping ? 2u : (phase == state::empty ? 1u : 0u);
}
struct closure_proof {
    bool dr_attempted{}, restore_readback{}, own_suspend_outstanding{}, resume_confirmed{};
    bool ever_suspended{}, thread_exited{}, ticket_zero{}, helper_inflight{}, helper_exited{};
    bool handler_removed{}, target_closed{}, event_closed{}, signal_closed{}, helper_closed{};
};
constexpr bool debug_closed(const closure_proof& p) noexcept {
    return (!p.dr_attempted || p.restore_readback || p.thread_exited) &&
        !p.own_suspend_outstanding && (!p.ever_suspended || p.resume_confirmed || p.thread_exited) &&
        p.ticket_zero && !p.helper_inflight && p.helper_exited && p.handler_removed &&
        p.target_closed && p.event_closed && p.signal_closed && p.helper_closed;
}
constexpr bool handle_closed(bool acquired, disposition d) noexcept {
    return acquired ? d == disposition::closed : d == disposition::not_acquired;
}
template<class Handle> struct retained_object {
    Handle value{}; bool acquired{}; disposition status{disposition::not_acquired};
    bool capture(Handle h) noexcept {
        if (acquired || !h) return false;
        value = h; acquired = true; status = disposition::open; return true;
    }
    template<class Close> bool close_with(Close&& close) noexcept {
        if (!acquired) return status == disposition::not_acquired;
        if (!value) return status == disposition::closed;
        try {
            if (!close(value)) { status = disposition::refused; return false; }
        } catch (...) { status = disposition::unknown; return false; }
        value = {}; status = disposition::closed; return true;
    }
};
// 0 cancels an unclaimed ticket; 2/3 must keep the original target waiting.
constexpr bool may_cancel(unsigned ticket, std::uint64_t now, std::uint64_t expires) noexcept {
    return ticket == 1 && now >= expires;
}
template<class Notify> inline void publish_completion(std::atomic<unsigned>& ticket,
    std::atomic<bool>& inflight, Notify&& notify) noexcept {
    ticket.store(3, std::memory_order_release);
    notify();
    inflight.store(false, std::memory_order_release);
}
template<class T, unsigned Capacity = max_records> class fixed_ring {
    std::array<T, Capacity> values_{};
    std::array<std::atomic<bool>, Capacity> ready_{};
    std::atomic<unsigned> reserved_{0};
public:
    bool reserve(unsigned& index) noexcept {
        auto n = reserved_.load(std::memory_order_relaxed);
        while (n < Capacity) if (reserved_.compare_exchange_weak(n, n + 1)) { index = n; return true; }
        return false;
    }
    void publish(unsigned index, const T& value) noexcept {
        values_[index] = value; ready_[index].store(true, std::memory_order_release);
    }
    bool append(const T& value) noexcept {
        unsigned index{}; if (!reserve(index)) return false; publish(index, value); return true;
    }
    unsigned reserved() const noexcept { return reserved_.load(std::memory_order_acquire); }
    bool read(unsigned index, T& value) const noexcept {
        if (index >= Capacity || !ready_[index].load(std::memory_order_acquire)) return false;
        value = values_[index]; return true;
    }
};

// Called only by the exact lifecycle overlay. No restart API exists.
void loaded_boundary() noexcept;
void after_all_post_load() noexcept;
void before_first_post_unpack() noexcept;
void after_first_post_unpack() noexcept;
bool cleanup_confirmed() noexcept;
}
