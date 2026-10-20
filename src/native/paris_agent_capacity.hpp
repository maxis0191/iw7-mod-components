#pragma once
#include <cstddef>
#include <cstdint>
#include <limits>
#include <string_view>
#include <array>

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
// CP keeps forty history frames, then an unchanged generic restoration
// context, followed by character-indexed rewind flags and saved XAnim trees.
// These are independent of the live character-info/agent allocations.
namespace animation_archive {
constexpr std::uint32_t align8(std::uint32_t n) { return (n+7)&~7u; }
constexpr std::uint32_t controller_base=0x8B50, frames=40, frame_base=0x2408;
constexpr std::uint32_t controller_records=characters*2;
constexpr std::uint32_t controller_size=characters*(2+0x48);
constexpr std::uint32_t xanim_base=controller_base+controller_size;
constexpr std::uint32_t xanim_counts=characters*4, xanim_counter=characters*8;
constexpr std::uint32_t xanim_data=xanim_counter+4;
constexpr std::uint32_t frame_size=xanim_base+xanim_data+1000*12;
constexpr std::uint32_t restore=frame_base+frames*frame_size;
constexpr std::uint32_t rewind=restore+0x12010, flags=0x14;
constexpr std::uint32_t pointers=align8(flags+characters);
constexpr std::uint32_t active=pointers+characters*8;
constexpr std::uint32_t object_size=rewind+align8(active+1);
constexpr std::uint32_t growth=object_size-0x2077F0;
static_assert(controller_records==0xA4 && controller_size==0x17B4);
static_assert(xanim_base==0xA304 && xanim_data==0x294 && frame_size==0xD478);
static_assert(restore==0x2156C8 && rewind==0x2276D8);
static_assert(pointers==0x68 && active==0x2F8 && object_size==0x2279D8);
// Complete straight-line blocks; widening a disp8 from54 toA4 would address
// negative memory. Re-encode the same copies with a computed positive base.
constexpr std::array<std::uint8_t,33> blend_before={
    0x48,0x8d,0x57,0x54,0x4c,0x8b,0x4c,0x24,0x70,0xf3,0x0f,0x10,0x55,0x10,
    0x48,0x8d,0x0c,0xc0,0x48,0x8d,0x14,0xca,0x48,0x8d,0x0c,0xcd,0x54,0,0,0,0x48,0x03,0xcb};
constexpr std::array<std::uint8_t,33> blend_after={
    0x48,0x8d,0x0c,0xc0,0x48,0x8d,0x94,0xcf,0xA4,0,0,0,
    0x48,0x8d,0x8c,0xcb,0xA4,0,0,0,0x4c,0x8b,0x4c,0x24,0x70,
    0xf3,0x0f,0x10,0x55,0x10,0x90,0x90,0x90};
constexpr std::array<std::uint8_t,64> next_before={
    0x49,0x63,0x06,0x48,0x8d,0x0c,0xc0,0x48,0x8b,0x44,0x24,0x70,
    0x0f,0x10,0x44,0xcf,0x54,0x0f,0x11,0x00,0x0f,0x10,0x4c,0xcf,0x64,
    0x0f,0x11,0x48,0x10,0x0f,0x10,0x44,0xcf,0x74,0x0f,0x11,0x40,0x20,
    0x0f,0x10,0x8c,0xcf,0x84,0,0,0,0x0f,0x11,0x48,0x30,
    0xf2,0x0f,0x10,0x84,0xcf,0x94,0,0,0,0xe9,0x81,0,0,0};
constexpr std::array<std::uint8_t,59> previous_before={
    0x49,0x63,0x06,0x48,0x8d,0x0c,0xc0,0x48,0x8b,0x44,0x24,0x70,
    0x0f,0x10,0x44,0xcb,0x54,0x0f,0x11,0x00,0x0f,0x10,0x4c,0xcb,0x64,
    0x0f,0x11,0x48,0x10,0x0f,0x10,0x44,0xcb,0x74,0x0f,0x11,0x40,0x20,
    0x0f,0x10,0x8c,0xcb,0x84,0,0,0,0x0f,0x11,0x48,0x30,
    0xf2,0x0f,0x10,0x84,0xcb,0x94,0,0,0};
template<std::size_t N> constexpr std::array<std::uint8_t,N> copy_after(bool next) {
    std::array<std::uint8_t,N> code{};
    for(auto& byte:code)byte=0x90;
    const std::uint8_t body[]={
        0x49,0x63,0x06,0x48,0x6b,0xc8,0x48,0x48,0x8d,0x8c,0x0b,0xA4,0,0,0,
        0x48,0x8b,0x44,0x24,0x70,0x0f,0x10,0x01,0x0f,0x11,0x00,
        0x0f,0x10,0x49,0x10,0x0f,0x11,0x48,0x10,0x0f,0x10,0x41,0x20,0x0f,0x11,0x40,0x20,
        0x0f,0x10,0x49,0x30,0x0f,0x11,0x48,0x30,0xf2,0x0f,0x10,0x41,0x40};
    static_assert(N>=sizeof(body));
    for(std::size_t i=0;i<sizeof(body);++i)code[i]=body[i];
    if(next) {code[10]=0x0f;code[N-5]=0xe9;code[N-4]=0x81;code[N-3]=code[N-2]=code[N-1]=0;}
    return code;
}
constexpr auto next_after=copy_after<64>(true);
constexpr auto previous_after=copy_after<59>(false);
}
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
inline const char* wire_contract(bool expanded) noexcept { return expanded ? "64-v2" : "24"; }
inline bool compatible_wire(bool expanded,std::string_view peer) noexcept {
    return expanded ? peer=="64-v2" : peer.empty() || peer=="24";
}
inline bool compatible_peer(std::string_view peer) noexcept { return compatible_wire(installed(),peer); }
}
