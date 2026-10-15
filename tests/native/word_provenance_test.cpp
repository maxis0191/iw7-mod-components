#include "../../src/native/paris_word_provenance.hpp"
#include <cassert>
#include <iostream>
#include <initializer_list>
#include <stdexcept>

// Pure production predicates/ownership objects. No Windows APIs, process, lease or memory reader.
int main() {
    using namespace paris_word_provenance;
    static_assert(max_tids == 1 && max_records == 64 && checkpoint_ms == 200 && duration_ms == 10000);
    static_assert(max_snapshots == 4 && window_bytes == 64 && target_word == 0x141238362);
    static_assert((word_dr7 & 15) == 1 && ((word_dr7 >> 16) & 3) == 1 && ((word_dr7 >> 18) & 3) == 1);
    launch_flags flags{true, true, true, true, true, true, false, false};
    assert(permitted(flags));
    flags.restart = true; assert(!permitted(flags)); flags.restart = false;
    flags.capacity_watch = true; assert(!permitted(flags)); flags.capacity_watch = false;
    flags.reviewed = false; assert(!permitted(flags)); flags.reviewed = true;
    flags.dedicated = false; assert(!permitted(flags)); flags.dedicated = true;
    flags.lab = false; assert(!permitted(flags)); flags.lab = true;
    flags.server_test = false; assert(!permitted(flags)); flags.server_test = true;
    flags.debugger = false; assert(!permitted(flags)); flags.debugger = true;
    flags.startup = false; assert(!permitted(flags));
    assert(valid_nonce("fixed_nonce_123456"));
    assert(!valid_nonce("short")); assert(!valid_nonce("fixed_nonce_12345/"));
    assert(!valid_nonce("fixed_nonce_12345\n"));
    assert(valid_hash("0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF"));
    assert(!valid_hash("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"));
    assert(!valid_hash("ABC"));
    debug_registers saved{};
    assert(clear_debug_state(saved)); saved.dr7 = 0x400; assert(clear_debug_state(saved));
    auto actual = saved; actual.dr0 = 0x1234; assert(!clear_debug_state(actual));
    actual = saved; actual.flags = 0x100; assert(!clear_debug_state(actual));
    for (const unsigned cause : {13u, 14u, 15u}) {
        actual = saved; actual.dr6 = 1ull << cause; assert(!clear_debug_state(actual));
    }
    actual = saved; actual.dr0 = 0x1234; actual.dr7 |= canary_dr7;
    assert(owned(actual, saved, state::canary, 0x1234));
    actual.dr0 = target_word; actual.dr7 = saved.dr7 | word_dr7;
    assert(owned(actual, saved, state::word, 0x1234));
    actual.dr7 |= 4; assert(!owned(actual, saved, state::word, 0x1234));
    actual.dr7 = saved.dr7 | word_dr7; actual.dr2 = target_word;
    assert(!owned(actual, saved, state::word, 0x1234));
    actual = saved; assert(exact_baseline(actual, saved)); actual.dr6 = 1;
    assert(!exact_baseline(actual, saved));
    actual = saved; actual.flags = 0x100; assert(!exact_baseline(actual, saved));
    assert(same_bootstrap(7123, 7123)); assert(!same_bootstrap(0, 7123));
    assert(!same_bootstrap(7123, 8181));
    assert(unexpected_baseline(state::word)); assert(unexpected_baseline(state::canary));
    assert(!unexpected_baseline(state::disarming)); assert(!unexpected_baseline(state::closed));
    region r{0x141238000, 0x140000000, 4096, 0x1000, 0x1000000, 0x20, 0x20};
    assert(valid_window(r));
    auto changed = r; changed.allocation = 0x160000000; assert(!valid_window(changed));
    changed = r; changed.type = 0x20000; assert(!valid_window(changed));
    changed = r; changed.protection |= 0x100; assert(!valid_window(changed));
    changed = r; changed.protection = 4; assert(!valid_window(changed));
    changed = r; changed.size = window_start - changed.base + window_bytes - 1;
    assert(!valid_window(changed));
    changed = r; changed.protection = 0x40; assert(valid_window(changed)); assert(!same_region(changed, r));
    assert(same_region(r, r));
    assert(!elapsed(99, 100, 10)); assert(!elapsed(109, 100, 10)); assert(elapsed(110, 100, 10));
    assert(may_cancel(1, 200, 200)); assert(!may_cancel(1, 199, 200));
    assert(!may_cancel(2, 900, 200)); assert(!may_cancel(3, 900, 200));
    assert(operation(state::empty, false, false) == 1);
    assert(operation(state::word, true, false) == 2);
    // Actual helper-stop/closed path cannot publish another ticket.
    assert(operation(state::closed, true, false) == 0);
    assert(operation(state::failed, true, true) == 0);
    fixed_ring<int, 2> ring;
    unsigned index{}; assert(ring.reserve(index) && index == 0);
    assert(ring.append(22)); int result{};
    assert(!ring.read(0, result)); assert(ring.read(1, result) && result == 22);
    ring.publish(index, 11); assert(ring.read(0, result) && result == 11);
    assert(!ring.append(33)); assert(ring.reserved() == 2);
    std::atomic<unsigned> ticket{2}; std::atomic<bool> inflight{true};
    publish_completion(ticket, inflight, [&] {
        assert(ticket.load() == 3 && inflight.load());
        ticket.store(0); assert(inflight.load()); // Target ACK cannot prematurely hide publisher.
    });
    assert(ticket.load() == 0 && !inflight.load());
    closure_proof p{true, true, false, true, true, false, true, false, true, true, true, true, true, true};
    assert(debug_closed(p));
    auto q = p; q.restore_readback = false; assert(!debug_closed(q));
    q = p; q.resume_confirmed = false; assert(!debug_closed(q));
    q = p; q.own_suspend_outstanding = true; assert(!debug_closed(q));
    q = p; q.ticket_zero = false; assert(!debug_closed(q));
    q = p; q.helper_inflight = true; assert(!debug_closed(q));
    q = p; q.helper_exited = false; assert(!debug_closed(q));
    q = p; q.handler_removed = false; assert(!debug_closed(q));
    q = p; q.target_closed = false; assert(!debug_closed(q));
    q = p; q.event_closed = false; assert(!debug_closed(q));
    q = p; q.signal_closed = false; assert(!debug_closed(q));
    q = p; q.helper_closed = false; assert(!debug_closed(q));
    q = p; q.restore_readback = false; q.resume_confirmed = false; q.thread_exited = true;
    assert(debug_closed(q)); assert(!q.restore_readback && !q.resume_confirmed); // Exit stays separately labelled.
    retained_object<unsigned> original;
    unsigned calls = 0;
    assert(original.close_with([&](unsigned) { ++calls; return false; })); assert(calls == 0);
    assert(handle_closed(original.acquired, original.status));
    assert(original.capture(7123)); assert(!original.capture(9999)); assert(original.value == 7123);
    auto first_two_refuse = [&](unsigned handle) { assert(handle == 7123); return ++calls >= 3; };
    assert(!original.close_with(first_two_refuse)); assert(original.value == 7123 && original.status == disposition::refused);
    assert(!original.close_with(first_two_refuse)); assert(!handle_closed(original.acquired, original.status));
    assert(original.close_with(first_two_refuse)); assert(calls == 3 && original.value == 0);
    assert(handle_closed(original.acquired, original.status));
    assert(original.close_with(first_two_refuse)); assert(calls == 3);
    retained_object<unsigned> throwing;
    assert(throwing.capture(8181));
    assert(!throwing.close_with([&](unsigned h) -> bool {
        assert(h == 8181); throwing.status = disposition::closed;
        throw std::runtime_error("injected throw despite closed property");
    }));
    assert(throwing.value == 8181 && throwing.status == disposition::unknown);
    assert(!handle_closed(throwing.acquired, throwing.status));
    assert(throwing.close_with([](unsigned h) { assert(h == 8181); return true; }));
    assert(handle_closed(throwing.acquired, throwing.status));
    assert(!handle_closed(false, disposition::closed));
    std::cout << "PASS pure STARTUP ownership, DR encoding, publication, bounds and same-original closure checks; no kernel claim\n";
}
