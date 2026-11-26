#pragma once
// Lazy commit of the engine allocator's segments: the portable part (no Windows headers), unit-tested in tests/native/lazy_commit_test.cpp.
// docs/LAZY-COMMIT.md has the design, the engine addresses and the reasoning.
#include <array>
#include <cstddef>
#include <cstdint>

namespace iw7::lazy_commit {
constexpr std::size_t page = 4096;
constexpr std::size_t kb = 1024, mb = 1024 * 1024;
constexpr std::size_t pad = 64 * kb;          // reserved after the block and never committed: no other block starts where the allocator thinks this one ends (no segment merge)
constexpr std::size_t head_commit = 64 * kb;  // committed at once: the mstate (0x3c0 bytes), the first chunks and the top chunk's header
constexpr std::size_t tail_commit = 16 * kb;  // committed at once: the fence posts and the segment record the allocator writes at the end of a segment
constexpr std::size_t grow_step = 256 * kb;   // a fault commits up to the next multiple of this (from the block base)
constexpr std::size_t min_lazy = 2 * mb;      // smaller blocks are committed whole
constexpr std::size_t max_blocks = 4096;

struct shape {
    bool lazy{};
    std::size_t reserve{}, head{}, tail{};
};

// What to reserve and commit for a block of `size` bytes (the size the allocator asked for: a multiple of the allocation granularity).
constexpr shape plan(std::size_t size) {
    if (size < min_lazy || size % page || size < head_commit + tail_commit + grow_step) return {false, size, size, 0};
    return {true, size + pad, head_commit, tail_commit};
}

struct block {
    std::uintptr_t base{};
    std::size_t size{};
    std::uintptr_t committed{};   // [base, committed) is committed (the head grown by faults)
    std::uintptr_t tail_start{};  // [tail_start, base + size) is committed from the start
    bool used{};
};

constexpr std::uintptr_t align_up(std::uintptr_t value, std::size_t unit) { return (value + unit - 1) / unit * unit; }

enum class fault_result { not_ours, handled, failed };

// The block table. No locking here: the caller serialises. `commit(address, bytes)` commits pages and says whether it worked.
class table {
public:
    block* add(std::uintptr_t base, std::size_t size, const shape& s) {
        if (!s.lazy) return nullptr;
        for (auto& b : blocks_)
            if (!b.used) {
                b = {base, size, base + s.head, base + size - s.tail, true};
                ++count_;
                return &b;
            }
        return nullptr;
    }
    block* find(std::uintptr_t address) {
        for (auto& b : blocks_)
            if (b.used && address >= b.base && address < b.base + b.size) return &b;
        return nullptr;
    }
    block* find_base(std::uintptr_t base) {
        for (auto& b : blocks_)
            if (b.used && b.base == base) return &b;
        return nullptr;
    }
    bool full() const { return count_ >= blocks_.size(); }
    std::size_t count() const { return count_; }
    void remove(block* b) { if (b && b->used) { *b = {}; --count_; } }

    // Commit [committed, end) of a block, end clipped to the tail. Used by the fault handler and by the retirement of a segment's top.
    template <class Commit> bool grow_to(block& b, std::uintptr_t end, Commit&& commit) {
        if (end > b.tail_start) end = b.tail_start;
        if (end <= b.committed) return true;
        if (!commit(b.committed, static_cast<std::size_t>(end - b.committed))) return false;
        b.committed = end;
        return true;
    }
    // A fault at `address`: the allocator (or the code of a caller) touched a page of a block that is still only reserved.
    template <class Commit> fault_result fault(std::uintptr_t address, Commit&& commit) {
        auto* b = find(address);
        if (!b || address >= b->tail_start) return fault_result::not_ours;
        if (address < b->committed) return fault_result::handled;   // another thread committed it first
        const auto end = b->base + align_up(address - b->base + 1, grow_step);
        return grow_to(*b, end, commit) ? fault_result::handled : fault_result::failed;
    }
    // Bytes committed now (committed heads and tails) and reserved in the lazy blocks.
    std::size_t committed_bytes() const {
        std::size_t total = 0;
        for (const auto& b : blocks_) if (b.used) total += (b.committed - b.base) + (b.base + b.size - b.tail_start);
        return total;
    }
    std::size_t block_bytes() const {
        std::size_t total = 0;
        for (const auto& b : blocks_) if (b.used) total += b.size;
        return total;
    }

private:
    std::array<block, max_blocks> blocks_{};
    std::size_t count_{};
};
}
