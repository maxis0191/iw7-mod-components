#include "../../src/native/debugger_stats.hpp"
#include <cassert>
#include <thread>
#include <vector>
#include <iostream>
int main()
{
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
    assert(stats.take()[0].calls == 0);
    std::vector<std::thread> threads;
    for (int t = 0; t < 4; ++t) threads.emplace_back([&] { for (int i = 0; i < 10000; ++i) { stats.begin(3); stats.end(3, 1, 101); } });
    for (auto& thread : threads) thread.join();
    result = stats.take(); assert(result[3].started == 40000 && result[3].calls == 40000 && result[3].total_ns == 4000000);
    stats.begin(0); stats.end(0, 0, UINT64_MAX); stats.begin(0); stats.end(0, 0, 20);
    assert(stats.take()[0].total_ns == UINT64_MAX);
    std::cout << "Debugger counter bounds, interruption, rollover and contention passed\n";
}
