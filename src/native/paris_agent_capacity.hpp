#pragma once
#include <cstddef>
#include <cstdint>
#include <limits>

namespace paris_agent_capacity {
constexpr std::uint32_t ordinary = 48, special_reserve = 16, agents = ordinary + special_reserve;
constexpr std::uint32_t players = 18, characters = players + agents, map_start = characters + 16;
constexpr std::uint32_t character_bits = 7;
constexpr std::uint32_t player_corpse_start = characters, agent_corpse_start = characters + 8;
constexpr std::uint32_t agent_stride = 0x5010, agent_bytes = agents * agent_stride;
constexpr std::uint32_t sentient_slots = 71 + agents - 24, sentient_bytes = sentient_slots * 0xA0;
constexpr std::uint32_t character_growth = (characters - 42) * 0x2CA0;
constexpr std::uint32_t server_size = 0x7A0D8 + character_growth;
constexpr std::uint32_t client_tail = 0xFD7F8 + character_growth;
constexpr std::uint32_t client_flags = 0xFDEA8 + character_growth;
constexpr std::uint32_t client_size = (client_flags + characters + 15) & ~15u;
constexpr std::uint32_t reference_bytes = 8 + characters * 0x40;
constexpr std::uint32_t table8_bytes = characters * 8, table20_bytes = characters * 5 * 20;
static_assert(agents == 64 && characters == 82 && map_start == 98);
static_assert(characters > (1u << 6) && characters <= (1u << character_bits));
static_assert(player_corpse_start == 82 && agent_corpse_start == 90 && agent_corpse_start + 8 == map_start);
static_assert(client_tail + (0xFDEA8 - 0xFD7F8) == client_flags);
static_assert(client_flags + characters <= client_size);
inline bool relative32(std::uintptr_t target, std::uintptr_t next, std::int32_t& result) noexcept {
    if (target >= next) {
        const auto delta = target - next;
        if (delta > static_cast<std::uintptr_t>(std::numeric_limits<std::int32_t>::max())) return false;
        result = static_cast<std::int32_t>(delta); return true;
    }
    const auto delta = next - target;
    if (delta > 0x80000000ull) return false;
    result = delta == 0x80000000ull ? std::numeric_limits<std::int32_t>::min() : -static_cast<std::int32_t>(delta);
    return true;
}
bool installed() noexcept;
}
