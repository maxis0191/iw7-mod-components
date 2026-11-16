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
// ids 0..3 are the heads of the four id lists, 4..0x3FFFF usable: id = 4 x local + segment, local 1..0xFFFF (u16 in the child entry, in the key
// and in the free list links). The ids below 0x10000 (locals below 0x4000, the low pool) are kept for the objects whose id the engine holds in
// 16 bits (threads and their `self`, entity objects, the class arrays, the server client arrays); every other object takes a high id first.
constexpr std::uint32_t parent_ids = 0x40000;
constexpr std::uint32_t parent_low_locals = 0x4000;
constexpr std::uint32_t segments = 4, child_bytes_each = 0x18;
// object key names are 0x40000 + parent id (below: strings, from 0x800000: integers): ids up to 0x3FFFF give names up to 0x7FFFF
constexpr std::uint32_t name_bound = 0x40000 + parent_ids;
static_assert(name_bound <= 0x800000);

constexpr std::uint64_t stock_a = 0x14665A180ull, stock_b = 0x146675980ull, stock_p8 = 0x146691180ull, stock_p4 = 0x1466FF180ull, stock_ch = 0x146756180ull, stock_hash = 0x146736180ull;
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
constexpr std::uint32_t parent_low_usable() { return parent_low_locals - 1; }

// The child hash table (a62): 4 segments x 2^bits u16 bucket heads. bucket = ((parent * 0x65 + name) & (2^bits - 1)) + (parent & 3) * 2^bits. Stock 14 (16,384 a
// segment, 0x20000 bytes); `-script-variables-buckets <bits>` (or IW7_SCRIPT_VARIABLES_BUCKETS) takes 14 to 17; the default is the one the measurements chose.
constexpr std::uint32_t stock_hash_bits = 14, default_hash_bits = 16, min_hash_bits = 14, max_hash_bits = 17;
constexpr std::uint64_t stock_hash_bytes = 0x20000;
constexpr std::uint64_t hash_bytes(std::uint32_t bits) { return static_cast<std::uint64_t>(segments) * 2ull << bits; }
static_assert(hash_bytes(stock_hash_bits) == stock_hash_bytes);

bool installed() noexcept;
// the bits in use (stock_hash_bits until the component has started)
std::uint32_t hash_bits() noexcept;
}
