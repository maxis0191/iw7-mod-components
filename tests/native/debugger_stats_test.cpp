#include "../../src/native/debugger_stats.hpp"
#include <cassert>
#include <thread>
#include <vector>
#include <iostream>

#include "../../src/native/paris_debugger.hpp"
#include <string>

using namespace iw7::debugger;
static_assert(sizeof(counter) == 6 * sizeof(std::uint64_t), "Generic counters must not grow");
static_assert(sizeof(paris_debugger::scope) == sizeof(std::size_t) + sizeof(std::uint64_t), "GSC scope must not grow");

thread_cpu_sample sample(std::uint32_t tid = 7, std::uint64_t creation = (1ULL << 60) + 7,
    std::uint64_t kernel = 100, std::uint64_t user = 200, std::uint64_t before = 100, std::uint64_t after = 110)
{
    thread_cpu_sample s;
    s.tid = tid; s.creation_100ns = creation; s.kernel_100ns = kernel; s.user_100ns = user;
    s.before_ns = before; s.after_ns = after; s.ok = true;
    return s;
}
bool pair(thread_cpu_counters& c, const thread_cpu_sample& start, const thread_cpu_sample& end)
{
    thread_cpu_ticket t;
    assert(c.begin(t));
    c.attach_start(t, start);
    return c.end(t, end);
}

void test_thread_cpu()
{
    const auto start = sample(), end = sample(7, (1ULL << 60) + 7, 101, 202, 210, 230);
    thread_cpu_counters c;
    thread_cpu_ticket spanning;
    assert(c.begin(spanning)); assert(c.attach_start(spanning, start));
    auto v = c.take();
    assert(v.started == 1 && v.active == 1 && v.paired == 0 && v.cohorts[0].active == 1);
    assert(c.take().active == 1); // Snapshot/reset must retain outstanding scopes.
    // Finalization is driven by the captured ticket, not a later enabled flag.
    assert(c.end(spanning, end)); assert(!spanning.pending()); assert(!c.end(spanning, end));
    v = c.take();
    const auto& first = v.cohorts[0];
    assert(v.completed == 1 && v.paired == 1 && v.active == 0 && v.invalid_tokens == 1);
    assert(first.paired == 1 && first.kernel_100ns == 1 && first.user_100ns == 2 && first.cpu_100ns == 3);
    assert(first.wall_lower_ns == 100 && first.wall_upper_ns == 130 && first.acquisition_ns == 30);
    assert(first.last_start.before_ns == 100 && first.last_end.after_ns == 230);
    assert(first.wall_lower_histogram[0] == 1 && first.cpu_histogram[0] == 1);
    assert(std::to_string(first.creation_100ns) == "1152921504606846983"); // Beyond IEEE754 exact integer range.
    assert(!c.begin(spanning)); // A consumed token cannot be enrolled again.

    // A failed CPU read cannot turn into a valid zero sample; valid zero deltas can.
    thread_cpu_counters errors;
    auto bad = start; bad.ok = false; bad.error = 5;
    assert(!pair(errors, bad, end));
    bad = end; bad.ok = false; bad.error = 6;
    assert(!pair(errors, start, bad));
    v = errors.take(); assert(v.api_failures == 2 && v.paired == 0 && v.active == 0 && v.last_api_error == 6);
    assert(pair(errors, start, sample(7, start.creation_100ns, 100, 200, 210, 230)));
    v = errors.take(); assert(v.paired == 1 && v.cohorts[0].cpu_100ns == 0 && !v.api_failures);

    bad = end; bad.tid = 8; assert(!pair(errors, start, bad));
    bad = end; ++bad.creation_100ns; assert(!pair(errors, start, bad));
    bad = start; bad.creation_100ns = 0; assert(!pair(errors, bad, end));
    v = errors.take(); assert(v.identity_failures == 3 && v.paired == 0 && v.active == 0);
    bad = end; bad.before_ns = 109; assert(!pair(errors, start, bad));
    bad = start; bad.after_ns = 99; assert(!pair(errors, bad, end));
    bad = end; bad.after_ns = 209; assert(!pair(errors, start, bad));
    v = errors.take(); assert(v.clock_failures == 3 && v.paired == 0 && v.active == 0);
    bad = end; bad.kernel_100ns = 99; assert(!pair(errors, start, bad));
    bad = end; bad.user_100ns = 199; assert(!pair(errors, start, bad));
    v = errors.take(); assert(v.cpu_rollbacks == 2 && v.paired == 0 && v.active == 0);

    // Four exact identities are retained; a reused TID with another creation is distinct.
    thread_cpu_counters bounded;
    for (std::uint64_t i = 0; i < 4; ++i)
        assert(pair(bounded, sample(7, 1000 + i), sample(7, 1000 + i, 101, 202, 210, 230)));
    assert(!pair(bounded, sample(7, 2000), sample(7, 2000, 101, 202, 210, 230)));
    v = bounded.take(); assert(v.paired == 4 && v.capacity_drops == 1 && v.active == 0);
    for (std::size_t i = 0; i < 4; ++i) assert(v.cohorts[i].creation_100ns == 1000 + i);
    assert(!pair(bounded, sample(7, 2000), sample(7, 2000, 101, 202, 210, 230))); // No eviction after reset.
    assert(bounded.take().capacity_drops == 1);

    // Overflow bucket, exact edge, zero lower interval, sticky saturation and CPU sum overflow.
    thread_cpu_counters large;
    auto a = sample(9, 3000, 0, 0, 0, 0), b = sample(9, 3000, 0, 0, UINT64_MAX, UINT64_MAX);
    assert(pair(large, a, b)); assert(pair(large, a, b));
    v = large.take(); assert(v.cohorts[0].saturated && v.cohorts[0].wall_lower_ns == UINT64_MAX);
    assert(v.cohorts[0].wall_lower_histogram.back() == 2 && large.take().cohorts[0].saturated);
    thread_cpu_counters edges;
    b = sample(9, 3000, 0, 0, 250000, 250000);
    assert(pair(edges, a, b)); ++b.before_ns; ++b.after_ns; assert(pair(edges, a, b));
    b.before_ns = b.after_ns = 0; assert(pair(edges, a, b));
    v = edges.take(); assert(v.cohorts[0].wall_lower_histogram[0] == 2 && v.cohorts[0].wall_lower_histogram[1] == 1);
    b = sample(9, 3000, UINT64_MAX, 1, 200, 210); assert(!pair(edges, a, b));
    v = edges.take(); assert(v.cpu_overflows == 1 && v.paired == 0 && !v.active);

    thread_cpu_counters other;
    thread_cpu_ticket owned;
    assert(c.begin(owned)); c.attach_start(owned, start);
    assert(!other.end(owned, end) && owned.pending());
    assert(c.end(owned, end)); assert(other.take().invalid_tokens == 1);

    // Concurrent begins/ends and snapshots use the real collector, with four cohorts.
    thread_cpu_counters concurrent;
    std::vector<std::thread> workers;
    for (std::uint32_t i = 1; i <= 4; ++i) workers.emplace_back([&, i]
    {
        for (int n = 0; n < 1000; ++n)
            assert(pair(concurrent, sample(i, i), sample(i, i, 101, 202, 210, 230)));
    });
    std::uint64_t completions = 0;
    for (int i = 0; i < 100; ++i) completions += concurrent.take().paired;
    for (auto& worker : workers) worker.join();
    v = concurrent.take(); completions += v.paired;
    assert(completions == 4000 && v.active == 0 && !v.capacity_drops && !v.identity_failures);

#ifdef _WIN32
    // Future Windows qualification exercises the component's exact acquisition helper
    // on this test's current thread only. No claim about CPU clock resolution/progress.
    const auto real_start = capture_current_thread_cpu(), real_end = capture_current_thread_cpu();
    assert(real_start.ok && real_end.ok && real_start.tid && real_start.creation_100ns);
    assert(real_start.tid == real_end.tid && real_start.creation_100ns == real_end.creation_100ns);
    thread_cpu_counters real;
    assert(pair(real, real_start, real_end));
    assert(real.take().paired == 1);
#endif
    std::cout << "Dedicated scope2 CPU/wall pairing, identity, quality, bounds and snapshot cases passed\n";
}
int main()
{
    test_thread_cpu();
    iw7::debugger::counters<4> stats;
    assert(!stats.begin(4)); assert(!stats.end(4, 1, 2));
    stats.begin(0); stats.end(0, 100, 200);
    stats.begin(0); stats.end(0, 1, 301);
    stats.begin(1); stats.end(1, 8, 7);
    stats.begin(2); // Simulated VM interruption: counted start, no completion.
    auto result = stats.take();
    assert(result[0].started == 2 && result[0].calls == 2 && result[0].total_ns == 400 && result[0].max_ns == 300);
    assert(result[1].failed_clock == 1 && result[1].calls == 0);
    assert(result[2].started == 1 && result[2].calls == 0);
    assert(stats.take()[2].active == 1); // Retain a spanning/incomplete scope.
    assert(stats.end(2, 1, 100)); assert(stats.take()[2].active == 0);
    assert(stats.take()[0].calls == 0);
    std::vector<std::thread> threads;
    for (int t = 0; t < 4; ++t) threads.emplace_back([&] { for (int i = 0; i < 10000; ++i) { stats.begin(3); stats.end(3, 1, 101); } });
    for (auto& thread : threads) thread.join();
    result = stats.take(); assert(result[3].started == 40000 && result[3].calls == 40000 && result[3].total_ns == 4000000);
    stats.begin(0); stats.end(0, 0, UINT64_MAX); stats.begin(0); stats.end(0, 0, 20);
    assert(stats.take()[0].total_ns == UINT64_MAX);
    iw7::debugger::frames<2> frames;
    assert(!frames.record(0, 100)); assert(frames.record(1, 100));
    assert(frames.record(1, 300)); assert(frames.record(2, 500));
    assert(!frames.record(3, 500));
    auto rendering = frames.take();
    assert(rendering[0].intervals == 1 && rendering[0].total_ns == 200 && rendering[1].intervals == 0);
    assert(frames.record(1, 800)); rendering = frames.take();
    assert(rendering[0].intervals == 1 && rendering[0].max_ns == 500);
    std::cout << "Debugger counter bounds, interruption, rollover and contention passed\n";
}
