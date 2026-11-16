#pragma once
#include <cstdint>

// GSC variable pools (a46, a56): the child table (4 segments) grown from the shipped 0xA000 entries a segment to 0x10000, and the parent id
// space grown from 0xDC00 ids (u16) to 0x40000 (18 bits: 4 x 65,535 usable). An id is 4 x local + segment; the u16 fields that held a whole id
// hold the local index. Layout and every edited instruction: docs/SCRIPT-VARIABLES.md, ops/engine/variable_sites.py (find, parents),
// script_variables_sites.inc, script_variables_caves.inc. Off unless the process starts with -agent-capacity (and not -script-variables-stock).
namespace script_variables {

constexpr std::uint32_t stock_child_entries = 0xA000, stock_parent_ids = 0xDC00;
// entries a segment: local index 0 (the free list head) and 1..0xFFFF (u16 links; 0xFFFF is not a sentinel anywhere in the code)
constexpr std::uint32_t child_entries = 0x10000;
// The number of child segments (a67): 4 (stock, a46/a56), 8 or 16, `-script-variables-segments <n>` (or IW7_SCRIPT_VARIABLES_SEGMENTS), default 8. A parent's children live in the
// segment (id & (segments - 1)). Ids are `segments x local + segment`, local 1..0xFFFF (u16 in the child entry, in the key and in the free list links): ids 0..segments-1 are the
// heads of the id lists, 0x10000 x segments - 1 is the last id (0x3FFFF at 4 segments, 0x7FFFF at 8, 0xFFFFF at 16). The ids below 0x10000 (locals below 0x10000 / segments, the
// low pool) are kept for the objects whose id the engine holds in 16 bits (threads and their `self`, entity objects, the class arrays, the server client arrays); every other
// object takes a high id first.
constexpr std::uint32_t stock_segments = 4, min_segments = 4, max_segments = 16, default_segments = 8, child_bytes_each = 0x18;
constexpr bool valid_segments(std::uint32_t s) noexcept { return s == 4 || s == 8 || s == 16; }
constexpr std::uint32_t segment_shift(std::uint32_t s) noexcept { return s == 4 ? 2u : s == 8 ? 3u : 4u; }          // id >> shift = the local index
constexpr std::uint32_t parent_ids_for(std::uint32_t s) noexcept { return s * 0x10000u; }
constexpr std::uint32_t parent_low_locals_for(std::uint32_t s) noexcept { return 0x10000u / s; }
// object key names are 0x40000 + parent id (below: strings, from 0x800000: integers): ids up to 0xFFFFF give names up to 0x13FFFF
constexpr std::uint32_t name_bound_for(std::uint32_t s) noexcept { return 0x40000u + parent_ids_for(s); }
static_assert(name_bound_for(max_segments) <= 0x800000);
// the largest set (the native tests and the static sizes)
constexpr std::uint32_t parent_ids = parent_ids_for(stock_segments), parent_low_locals = parent_low_locals_for(stock_segments), segments = stock_segments;
constexpr std::uint32_t name_bound = name_bound_for(stock_segments);

constexpr std::uint64_t stock_a = 0x14665A180ull, stock_b = 0x146675980ull, stock_p8 = 0x146691180ull, stock_p4 = 0x1466FF180ull, stock_ch = 0x146756180ull, stock_hash = 0x146736180ull;
constexpr std::uint64_t stock_a_bytes = stock_parent_ids * 2ull, stock_p8_bytes = stock_parent_ids * 8ull, stock_p4_bytes = stock_parent_ids * 4ull,
                        stock_ch_bytes = stock_segments * stock_child_entries * child_bytes_each;
static_assert(stock_a_bytes == 0x1B800 && stock_p8_bytes == 0x6E000 && stock_p4_bytes == 0x37000 && stock_ch_bytes == 0x3C0000);

constexpr std::uint64_t a_bytes(std::uint32_t s) { return parent_ids_for(s) * 2ull; }
constexpr std::uint64_t p8_bytes(std::uint32_t s) { return parent_ids_for(s) * 8ull; }
constexpr std::uint64_t p4_bytes(std::uint32_t s) { return parent_ids_for(s) * 4ull; }
constexpr std::uint64_t ch_bytes(std::uint32_t s) { return static_cast<std::uint64_t>(s) * child_entries * child_bytes_each; }
// usable entries a segment / usable parent ids a segment (ids interleave over the segments: id & (segments - 1))
constexpr std::uint32_t child_usable() { return child_entries - 1; }
constexpr std::uint32_t parent_usable() { return 0x10000u - 1; }
constexpr std::uint32_t parent_low_usable(std::uint32_t s) { return parent_low_locals_for(s) - 1; }

// The child hash table (a62): `segments` x 2^bits u16 bucket heads. bucket = ((parent * 0x65 + name) & (2^bits - 1)) + (parent & (segments - 1)) * 2^bits. Stock 14 (16,384 a
// segment, 0x20000 bytes); `-script-variables-buckets <bits>` (or IW7_SCRIPT_VARIABLES_BUCKETS) takes 14 to 17; the default is the one the measurements chose.
constexpr std::uint32_t stock_hash_bits = 14, default_hash_bits = 16, min_hash_bits = 14, max_hash_bits = 17;
constexpr std::uint64_t stock_hash_bytes = 0x20000;
constexpr std::uint64_t hash_bytes(std::uint32_t s, std::uint32_t bits) { return static_cast<std::uint64_t>(s) * 2ull << bits; }
static_assert(hash_bytes(stock_segments, stock_hash_bits) == stock_hash_bytes);

bool installed() noexcept;
// the bits in use (stock_hash_bits until the component has started)
std::uint32_t hash_bits() noexcept;
// the segments in use (stock_segments until the component has started)
std::uint32_t segments_in_use() noexcept;
}
