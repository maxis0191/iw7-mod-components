#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <set>
#include <vector>

#include "../../src/native/script_parent_pools.hpp"
#include "../../src/native/script_variables.hpp"

// The free parent ids (a56): the four ids lists of two pools, the allocation order, the segment choice, the reuse, the exhaustion.
using namespace script_variables;
static int failures;
#define CHECK(c) do { if (!(c)) { std::printf("FAIL line %d: %s\n", __LINE__, #c); ++failures; } } while (0)

static std::vector<parent_entry> table(parent_ids);
static volatile std::uint32_t counters[4];

static parent_pools fresh(bool low_first) {
    parent_pools p;
    p.attach(table.data(), counters, parent_ids, parent_low_locals, low_first);
    for (auto& c : counters) c = 0;
    p.format();
    return p;
}

int main() {
    static_assert(parent_ids == 0x40000 && parent_low_locals == 0x4000);
    // format: every entry free, the heads are not ids, the last entry of each pool ends the list
    {
        auto p = fresh(false);
        for (unsigned segment = 0; segment < 4; ++segment) {
            CHECK(table[segment].type == 0x18);
            CHECK(table[(0x3FFFu << 2) | segment].link == 0);        // end of the low pool
            CHECK(table[(0xFFFFu << 2) | segment].link == 0);        // end of the high pool
            CHECK(table[(1u << 2) | segment].link == 2);
            CHECK(table[(0x4000u << 2) | segment].link == 0x4001);
        }
    }
    // general allocations take the high pool first and spread over the segments by the children counters (equal counters: lowest segment first)
    {
        auto p = fresh(false);
        std::uint32_t first[4];
        for (auto& id : first) { id = p.take(false); CHECK(id >= 0x10000u); }
        CHECK((first[0] & 3) == 0);
        counters[0] = 5; counters[1] = 1; counters[2] = 3; counters[3] = 2;
        CHECK((p.take(false) & 3) == 1);
        counters[1] = 9;
        CHECK((p.take(false) & 3) == 3);
    }
    // low-only allocations stay below 0x10000; local 0 and the ids 0..3 are never handed out
    {
        auto p = fresh(false);
        std::set<std::uint32_t> seen;
        std::size_t n = 0;
        for (;;) {
            counters[0] = counters[1] = counters[2] = counters[3] = 0;
            const auto id = p.take(true);
            if (!id) break;
            CHECK(id >= 4 && id < 0x10000u);
            CHECK(seen.insert(id).second);
            ++n;
        }
        CHECK(n == 4u * parent_low_usable());
        CHECK(p.high_taken() == 0);
    }
    // everything can be taken exactly once: 262,140 ids, the high pool first, then the low pool; the total is 4 x 65,535
    {
        auto p = fresh(false);
        std::vector<char> taken(parent_ids);
        std::size_t n = 0, high = 0;
        for (;;) {
            const auto id = p.take(false);
            if (!id) break;
            CHECK(id >= 4 && id < parent_ids && !taken[id]);
            taken[id] = 1;
            ++n;
            if (id >= 0x10000u) ++high;
            if (n == 4u * (0xFFFFu - parent_low_locals + 1)) CHECK(high == n);        // the high pool is spent before any low id
        }
        CHECK(n == 4u * parent_usable());
        CHECK(p.take(false) == 0 && p.take(true) == 0);
        // give back: the id returns to the pool of its number, LIFO, and is taken again
        const std::uint32_t low_id = 0x1004, high_id = 0x20004;
        p.give(low_id);
        p.give(high_id);
        CHECK(p.take(true) == low_id);
        CHECK(p.take(false) == high_id);
        CHECK(p.take(false) == 0);
    }
    // low first (the a46 order): ascending ids, the high pool only when the low pool is spent
    {
        auto p = fresh(true);
        const auto a = p.take(false), b = p.take(false);
        CHECK(a < 0x100 && b < 0x100 && a != b);
        for (std::size_t i = 0; i < 4u * parent_low_usable() - 2; ++i) CHECK(p.take(false) < 0x10000u);
        CHECK(p.take(false) >= 0x10000u);
    }
    // the layout facts the code relies on
    static_assert(script_variables::parent_usable() == 65535 && script_variables::parent_low_usable() == 0x3FFF);
    static_assert(script_variables::name_bound == 0x80000);
    if (failures) { std::printf("%d failures\n", failures); return 1; }
    std::printf("script parent pools: ok\n");
    return 0;
}
