#pragma once
#include <cstddef>
#include <cstdint>

// The free parent ids of the engine's GSC variable system (a56). An id is 4 x local + segment; the free ids of a segment are two stacks, linked
// through the u16 `link` of the free entries with LOCAL indices: pool 0 holds the ids below 0x10000 (locals 1 .. low_locals - 1), pool 1 the rest.
// Objects whose id the engine keeps in 16 bits take pool 0 only; every other object takes pool 1 first (pool 0 first with `low_first`). The
// segment is the one with the fewest children among those that have a free id in the pool, ties to the lowest: the shipped choice.
// Pure logic over a table of 8 byte entries, so a native test can run it (tests/native/script_parent_pools_test.cpp).
namespace script_variables {

struct parent_entry { std::uint16_t refs, link; std::uint32_t type; };   // P8 +0, +2, +4 (type 0x18: free)
static_assert(sizeof(parent_entry) == 8);

class parent_pools {
public:
    // table: `ids` entries (ids = 4 x locals, locals <= 0x10000); counters: the children in use of each segment (the shipped int[4]).
    void attach(parent_entry* table, const volatile std::uint32_t* counters, std::uint32_t ids, std::uint32_t low_locals, bool low_first) noexcept {
        table_ = table;
        counters_ = counters;
        locals_ = ids / 4;
        low_locals_ = low_locals;
        low_first_ = low_first;
    }
    // every id is free; the four list heads (ids 0..3) are not allocatable
    void format() noexcept {
        for (unsigned segment = 0; segment < 4; ++segment) {
            table_[segment] = {0, 0, 0x18};
            for (std::uint32_t local = 1; local < locals_; ++local) {
                const auto next = (local + 1 == low_locals_ || local + 1 == locals_) ? 0u : local + 1;
                table_[(local << 2) | segment] = {0, static_cast<std::uint16_t>(next), 0x18};
            }
            head_[segment][0] = 1;
            head_[segment][1] = static_cast<std::uint16_t>(low_locals_);
        }
        low_taken_ = high_taken_ = 0;
    }
    // a free id, or 0 when there is none (the pools asked for are empty)
    std::uint32_t take(bool low_only) noexcept {
        for (unsigned pass = 0; pass < 2; ++pass) {
            const unsigned pool = low_only ? 0u : (low_first_ ? pass : 1u - pass);
            unsigned segment = 4;
            std::uint32_t fewest = 0xFFFFFFFFu;
            for (unsigned s = 0; s < 4; ++s)
                if (head_[s][pool] && counters_[s] < fewest) { fewest = counters_[s]; segment = s; }
            if (segment < 4) {
                const auto id = (static_cast<std::uint32_t>(head_[segment][pool]) << 2) | segment;
                head_[segment][pool] = table_[id].link;
                (pool ? high_taken_ : low_taken_)++;
                return id;
            }
            if (low_only) break;
        }
        return 0;
    }
    // an id goes back to the pool its number belongs to
    void give(std::uint32_t id) noexcept {
        auto& entry = table_[id];
        const auto segment = id & 3, local = id >> 2, pool = local >= low_locals_ ? 1u : 0u;
        entry.refs = 0;
        entry.link = head_[segment][pool];
        head_[segment][pool] = static_cast<std::uint16_t>(local);
    }
    std::size_t low_taken() const noexcept { return low_taken_; }
    std::size_t high_taken() const noexcept { return high_taken_; }
    bool low_first() const noexcept { return low_first_; }

private:
    parent_entry* table_{};
    const volatile std::uint32_t* counters_{};
    std::uint32_t locals_{}, low_locals_{};
    bool low_first_{};
    std::uint16_t head_[4][2]{};
    std::size_t low_taken_{}, high_taken_{};
};

}
