#pragma once
#include <cstdint>

// The script canonical name table (a82): SL_GetCanonicalString (0x140BFD340) hands out one id for every identifier a script uses that the shipped token table does not
// hold (field names, function names, notify names of the production and custom scripts). The shipped table has 4095 slots (a 4096 entry u32 hash, slot 0 unused, then a 114,688
// byte name buffer, one block of 0x20000 bytes that FUN_140C03280 takes from a hunk of exactly that size at the start of every script load) and MAX_CANONICAL_STRING
// ends the load when it is full: Beast (cp_final) has 66 names to spare with the production scripts. An id is 0x13FCC + slot; the variable system holds a name in 24 bits
// and keeps 0x40000 and above for object keys, so a name may go up to 0x3FFFF (docs/SCRIPT-CANONICAL.md has every holder).
// `-script-canon-names <n>` (or IW7_SCRIPT_CANON_NAMES; a client process also IW7_SCRIPT_CANON_NAMES_CLIENT, first) sets the number of slots: 4095 is the shipped table untouched, up to max_names; the default is default_names.
namespace script_canonical {

constexpr std::uint32_t stock_names = 4095, default_names = 16383, max_names = 65535;
constexpr std::uint32_t first_id = 0x13FCC;                                   // id = first_id + slot (slot 1..names)
constexpr std::uint32_t stock_hash_bytes = 0x4000, stock_name_bytes = 0x1C000;
// the shipped sizes are (4095 + 1) x 4 and (4095 + 1) x 28 bytes: the same ratios for any number of slots
constexpr std::uint32_t hash_bytes_for(std::uint32_t names) noexcept { return (names + 1u) * 4u; }
constexpr std::uint32_t name_bytes_for(std::uint32_t names) noexcept { return (names + 1u) * 28u; }
constexpr std::uint32_t block_bytes_for(std::uint32_t names) noexcept { return hash_bytes_for(names) + name_bytes_for(names); }
static_assert(hash_bytes_for(stock_names) == stock_hash_bytes && name_bytes_for(stock_names) == stock_name_bytes);
static_assert(first_id + max_names < 0x40000, "a canonical id must stay below the object key names");

bool installed() noexcept;
// the slots in use: stock_names until the component has patched the code
std::uint32_t names_in_use() noexcept;
}
