#pragma once
#include <cstdint>

// GSC variable pools (a46): the child table (4 segments) and the parent id space of the engine's script variable system, grown from the
// shipped 0xA000 entries a segment / 0xDC00 parent ids to 0x10000 each. Layout and every edited instruction: docs/SCRIPT-VARIABLES.md,
// ops/engine/variable_sites.py, script_variables_sites.inc. Off unless the process starts with -agent-capacity (and not -script-variables-stock).
namespace script_variables {

constexpr std::uint32_t stock_child_entries = 0xA000, stock_parent_ids = 0xDC00;
// entries a segment: local index 0 (the free list head) and 1..0xFFFF (u16 links; 0xFFFF is not a sentinel anywhere in the code)
constexpr std::uint32_t child_entries = 0x10000;
// ids 0..3 are the heads of the four id lists, 4..0xFFFF usable (u16 id in the child; 0xFFFF is not a sentinel)
constexpr std::uint32_t parent_ids = 0x10000;
constexpr std::uint32_t segments = 4, child_bytes_each = 0x18;
// object key names are 0x40000 + parent id (below: strings, from 0x800000: integers)
constexpr std::uint32_t name_bound = 0x40000 + parent_ids;
static_assert(name_bound <= 0x800000);

constexpr std::uint64_t stock_a = 0x14665A180ull, stock_b = 0x146675980ull, stock_p8 = 0x146691180ull, stock_p4 = 0x1466FF180ull, stock_ch = 0x146756180ull;
constexpr std::uint64_t stock_a_bytes = stock_parent_ids * 2ull, stock_p8_bytes = stock_parent_ids * 8ull, stock_p4_bytes = stock_parent_ids * 4ull,
                        stock_ch_bytes = segments * stock_child_entries * child_bytes_each;
static_assert(stock_a_bytes == 0x1B800 && stock_p8_bytes == 0x6E000 && stock_p4_bytes == 0x37000 && stock_ch_bytes == 0x3C0000);

constexpr std::uint64_t a_bytes() { return parent_ids * 2ull; }
constexpr std::uint64_t p8_bytes() { return parent_ids * 8ull; }
constexpr std::uint64_t p4_bytes() { return parent_ids * 4ull; }
constexpr std::uint64_t ch_bytes() { return static_cast<std::uint64_t>(segments) * child_entries * child_bytes_each; }
// usable entries a segment / usable parent ids a segment (ids interleave over the segments: id & 3)
constexpr std::uint32_t child_usable() { return child_entries - 1; }
constexpr std::uint32_t parent_usable() { return parent_ids / 4 - 1; }

bool installed() noexcept;
}
