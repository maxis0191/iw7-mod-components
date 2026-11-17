#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <set>
#include <vector>

#include "../../src/native/script_parent_pools.hpp"
#include "../../src/native/script_variables.hpp"

// The free parent ids (a56, a67): the id lists of two pools over 4, 8 or 16 segments, the allocation order, the segment choice, the reuse, the exhaustion.
using namespace script_variables;
static int failures;
#define CHECK(c) do { if (!(c)) { std::printf("FAIL line %d (segments %u): %s\n", __LINE__, S, #c); ++failures; } } while (0)

static std::vector<parent_entry> table;
static volatile std::uint32_t counters[16];

static parent_pools fresh(unsigned S, bool low_first) {
    parent_pools p;
    table.assign(parent_ids_for(S), parent_entry{});
    p.attach(table.data(), counters, S, parent_ids_for(S), parent_low_locals_for(S), low_first);
    for (auto& c : counters) c = 0;
    p.format();
    return p;
}

static void one(unsigned S) {
    const std::uint32_t ids = parent_ids_for(S), low_locals = parent_low_locals_for(S), low_ids = 0x10000u;
    CHECK(ids == S * 0x10000u && low_locals == 0x10000u / S);
    // format: every entry free, the heads are not ids, the last entry of each pool ends the list
    {
        auto p = fresh(S, false);
        const auto shift = segment_shift(S);
        for (unsigned segment = 0; segment < S; ++segment) {
            CHECK(table[segment].type == 0x18);
            CHECK(table[((low_locals - 1) << shift) | segment].link == 0);        // end of the low pool
            CHECK(table[(0xFFFFu << shift) | segment].link == 0);                 // end of the high pool
            CHECK(table[(1u << shift) | segment].link == 2);
            CHECK(table[(low_locals << shift) | segment].link == low_locals + 1);
        }
    }
    // general allocations take the high pool first and spread over the segments by the children counters (equal counters: lowest segment first)
    {
        auto p = fresh(S, false);
        std::vector<std::uint32_t> first(S);
        for (auto& id : first) { id = p.take(false); CHECK(id >= low_ids); }
        CHECK((first[0] & (S - 1)) == 0);
        for (unsigned s = 0; s < S; ++s) counters[s] = 50 + s;
        counters[S - 1] = 1; counters[0] = 7; counters[1] = 3;
        CHECK((p.take(false) & (S - 1)) == S - 1);
        counters[S - 1] = 99;
        CHECK((p.take(false) & (S - 1)) == 1);
    }
    // low-only allocations stay below 0x10000; local 0 and the ids 0..S-1 are never handed out
    {
        auto p = fresh(S, false);
        std::set<std::uint32_t> seen;
        std::size_t n = 0;
        for (;;) {
            for (unsigned s = 0; s < S; ++s) counters[s] = 0;
            const auto id = p.take(true);
            if (!id) break;
            CHECK(id >= S && id < low_ids);
            CHECK(seen.insert(id).second);
            ++n;
        }
        CHECK(n == static_cast<std::size_t>(S) * parent_low_usable(S));
        CHECK(n == low_ids - S);                                    // 65,532 / 65,528 / 65,520 ids below 0x10000
        CHECK(p.high_taken() == 0);
    }
    // everything can be taken exactly once, the high pool first, then the low pool; the total is S x 65,535
    {
        auto p = fresh(S, false);
        std::vector<char> taken(ids);
        std::size_t n = 0, high = 0;
        for (;;) {
            const auto id = p.take(false);
            if (!id) break;
            CHECK(id >= S && id < ids && !taken[id]);
            taken[id] = 1;
            ++n;
            if (id >= low_ids) ++high;
            if (n == static_cast<std::size_t>(S) * (0xFFFFu - low_locals + 1)) CHECK(high == n);        // the high pool is spent before any low id
        }
        CHECK(n == static_cast<std::size_t>(S) * parent_usable());
        CHECK(p.take(false) == 0 && p.take(true) == 0);
        // give back: the id returns to the pool of its number, LIFO, and is taken again
        const std::uint32_t low_id = 0x1001u, high_id = ids - S + 1u;
        CHECK(low_id < low_ids && high_id >= low_ids && (low_id & (S - 1)) == 1 && (high_id & (S - 1)) == 1);
        p.give(low_id);
        p.give(high_id);
        CHECK(p.take(true) == low_id);
        CHECK(p.take(false) == high_id);
        CHECK(p.take(false) == 0);
    }
    // low first (the a46 order): ascending ids, the high pool only when the low pool is spent
    {
        auto p = fresh(S, true);
        const auto a = p.take(false), b = p.take(false);
        CHECK(a < 0x100 && b < 0x100 && a != b);
        for (std::size_t i = 0; i < static_cast<std::size_t>(S) * parent_low_usable(S) - 2; ++i) CHECK(p.take(false) < low_ids);
        CHECK(p.take(false) >= low_ids);
    }
    // burned low pool (the detection test of a55, a79): the low pool keeps `keep` locals a segment, a general allocation never falls back to it
    {
        parent_pools p;
        table.assign(parent_ids_for(S), parent_entry{});
        for (auto& c : counters) c = 0;
        p.attach(table.data(), counters, S, parent_ids_for(S), parent_low_locals_for(S), false, 24);
        p.format();
        CHECK(p.burned());
        std::size_t low = 0;
        for (;;) {
            for (unsigned s = 0; s < S; ++s) counters[s] = 0;
            const auto id = p.take(true);
            if (!id) break;
            CHECK(id >= S && id < low_ids);
            ++low;
        }
        CHECK(low == static_cast<std::size_t>(S) * 23);              // locals 1..23 of every segment
        std::size_t high = 0;
        for (;;) {
            const auto id = p.take(false);
            if (!id) break;
            CHECK(id >= low_ids);                                   // never a low id, even when the high pool ends
            ++high;
        }
        CHECK(high == static_cast<std::size_t>(S) * (0x10000u - low_locals - 1u) + S);        // locals low_locals..0xFFFF of every segment
    }
    // the id <-> local conversion of the key (`id >> shift`) and of the read back (`local << shift | segment`) is the identity for every id
    for (std::uint32_t id : {S, S + 1u, 0x1234u, 0xFFFFu, 0x10000u, ids - 1}) {
        const auto local = id >> segment_shift(S), segment = id & (S - 1);
        CHECK(((local << segment_shift(S)) | segment) == id && local <= 0xFFFFu);
    }
    // the object key names (0x40000 + id) stay between the strings (below 0x40000) and the integers (0x800000 and up)
    CHECK(name_bound_for(S) == 0x40000u + ids && name_bound_for(S) <= 0x800000u);
    CHECK(0x800000u - name_bound_for(S) > 0x40000u);
}

int main() {
    static_assert(parent_ids == 0x40000 && parent_low_locals == 0x4000 && segments == 4);
    static_assert(parent_ids_for(8) == 0x80000 && parent_ids_for(16) == 0x100000);
    static_assert(parent_low_locals_for(8) == 0x2000 && parent_low_locals_for(16) == 0x1000);
    static_assert(parent_usable() == 65535 && parent_low_usable(4) == 0x3FFF && parent_low_usable(8) == 0x1FFF && parent_low_usable(16) == 0xFFF);
    static_assert(name_bound == 0x80000 && name_bound_for(8) == 0xC0000 && name_bound_for(16) == 0x140000);
    static_assert(0x800000u - name_bound_for(4) == 0x780000u && 0x800000u - name_bound_for(8) == 0x740000u && 0x800000u - name_bound_for(16) == 0x6C0000u);
    static_assert(valid_segments(4) && valid_segments(8) && valid_segments(16) && !valid_segments(0) && !valid_segments(2) && !valid_segments(12) && !valid_segments(32));
    static_assert(ch_bytes(8) == 8ull * 0x10000 * 0x18 && p8_bytes(16) == 0x100000ull * 8 && hash_bytes(16, 17) == 16ull * 2 << 17);
    for (unsigned S : {4u, 8u, 16u}) one(S);
    if (failures) { std::printf("%d failures\n", failures); return 1; }
    std::printf("script parent pools: ok\n");
    return 0;
}
