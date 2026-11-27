#undef NDEBUG
#include "../../src/native/lazy_commit_policy.hpp"
#include <cassert>
#include <iostream>
#include <vector>
using namespace iw7::lazy_commit;

// A fake commit: records the ranges, can be made to fail.
struct recorder {
    std::vector<std::pair<std::uintptr_t, std::size_t>> ranges;
    bool fail{};
    bool operator()(std::uintptr_t address, std::size_t bytes) { if (fail) return false; ranges.push_back({address, bytes}); return true; }
};

int main() {
    // plan: small blocks whole, big ones lazy with a pad
    assert(!plan(1 * mb).lazy && plan(1 * mb).reserve == 1 * mb && plan(1 * mb).head == 1 * mb);
    assert(!plan(2 * mb + 1).lazy);   // not page aligned: whole
    const auto big = plan(16 * mb);
    assert(big.lazy && big.reserve == 16 * mb + pad && big.head == head_commit && big.tail == tail_commit);
    assert(big.reserve > 16 * mb);    // the reserve is larger than the size the allocator sees: blocks placed back to back are never adjacent for it

    table t;
    const std::uintptr_t base = 0x200000000ull;
    auto* b = t.add(base, 16 * mb, big);
    assert(b && t.count() == 1);
    assert(t.add(base + 64 * mb, 1 * mb, plan(1 * mb)) == nullptr);   // a whole block is not registered
    assert(b->committed == base + head_commit && b->tail_start == base + 16 * mb - tail_commit);
    assert(t.committed_bytes() == head_commit + tail_commit);

    recorder c;
    // inside the head, the tail, the pad, below the block: nothing to do or not ours
    assert(t.fault(base + 100, c) == fault_result::handled && c.ranges.empty());   // below the committed mark: another thread committed it
    assert(t.fault(base + 16 * mb - 8, c) == fault_result::not_ours);              // in the tail (committed from the start)
    assert(t.fault(base + 16 * mb + 8, c) == fault_result::not_ours);              // in the pad
    assert(t.fault(base - 8, c) == fault_result::not_ours);

    // a header write just past the head: committed up to the next step, from the old mark
    assert(t.fault(base + head_commit + 8, c) == fault_result::handled);
    assert(c.ranges.size() == 1 && c.ranges[0].first == base + head_commit);
    assert(b->committed == base + 256 * kb);                    // the next multiple of 256 KB above 64 KB + 9
    // a far write: everything between the mark and it is committed (nothing handed out stays reserved)
    c.ranges.clear();
    assert(t.fault(base + 5 * mb + 40, c) == fault_result::handled);
    assert(c.ranges.size() == 1 && c.ranges[0].first == base + 256 * kb);
    assert(b->committed == base + 5 * mb + 256 * kb);
    assert(c.ranges[0].first + c.ranges[0].second == b->committed);
    // the same address again: already committed
    c.ranges.clear();
    assert(t.fault(base + 5 * mb + 40, c) == fault_result::handled && c.ranges.empty());
    // a write near the end is clipped at the tail (never past the block)
    assert(t.fault(base + 16 * mb - tail_commit - 8, c) == fault_result::handled);
    assert(b->committed == b->tail_start);
    assert(t.committed_bytes() == 16 * mb);

    // a commit that fails reports it and leaves the mark where it was
    table u;
    auto* d = u.add(base, 16 * mb, big);
    recorder bad; bad.fail = true;
    assert(u.fault(base + 1 * mb, bad) == fault_result::failed && d->committed == base + head_commit);

    // retirement of a top: grow_to up to the foot of the top chunk
    recorder r;
    assert(u.grow_to(*d, base + 3 * mb + 0x48, r));
    assert(d->committed == base + 3 * mb + 0x48 && r.ranges.size() == 1);
    assert(u.grow_to(*d, base + 1 * mb, r) && r.ranges.size() == 1);   // lower: nothing to do
    assert(u.grow_to(*d, base + 17 * mb, r) && d->committed == d->tail_start);   // beyond: clipped

    // release removes the entry; the slot is reused
    u.remove(d);
    assert(u.count() == 0 && u.find(base + 100) == nullptr && u.find_base(base) == nullptr);
    assert(u.add(base + 64 * mb, 32 * mb, plan(32 * mb)) != nullptr);

    // the table has a bounded size and says when it is full
    table full;
    for (std::size_t i = 0; i < max_blocks; ++i) assert(full.add(0x300000000ull + i * 64 * mb, 16 * mb, big));
    assert(full.full() && full.add(0x7000000000ull, 16 * mb, big) == nullptr);

    // two blocks: a fault lands in the right one
    table two;
    auto* first = two.add(0x400000000ull, 16 * mb, big);
    auto* second = two.add(0x400000000ull + 32 * mb, 32 * mb, plan(32 * mb));
    recorder both;
    assert(two.fault(0x400000000ull + 32 * mb + 2 * mb, both) == fault_result::handled);
    assert(first->committed == 0x400000000ull + head_commit && second->committed > 0x400000000ull + 32 * mb + 2 * mb);

    std::cout << "lazy commit policy checks passed\n";
    return 0;
}
