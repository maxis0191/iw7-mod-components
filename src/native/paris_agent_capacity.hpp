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
// CG's two current/next snapshots separately clamp agent metadata to24.
// Keep their original fields and tail offsets intact; append a64-row agent
// array and move every producer/consumer of the old inline array together.
namespace client_snapshot {
constexpr std::uint32_t legacy_size=0x3DC78, legacy_agents=0x38D48;
constexpr std::uint32_t agent_stride=0xC0, agent_base=legacy_size;
constexpr std::uint32_t size=agent_base+agents*agent_stride, pair_bytes=2*size;
// CG_SetNextSnap's former two-word character-change mask at rsp+40 ran
// into its saved cg pointer at48. Its60 local can move to an unused58
// slot; the new three-word mask then fits60..6B, before entity bits at70.
constexpr std::uint32_t change_mask=0x60, saved_state=0x58;
constexpr std::uint32_t change_words=(characters+31)/32;
static_assert(saved_state+8==change_mask && change_mask+change_words*4<=0x70);
static_assert(legacy_agents+24*agent_stride==0x39F48);
static_assert(size==0x40C78 && pair_bytes==0x818F0);
}
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
constexpr std::uint32_t rewind_base=restore+0x12010, flags=0x14;
constexpr std::uint32_t pointers=align8(flags+characters);
constexpr std::uint32_t rewind_active=pointers+characters*8;
constexpr std::uint32_t object_size=rewind_base+align8(rewind_active+1);
constexpr std::uint32_t growth=object_size-0x2077F0;
static_assert(controller_records==0xA4 && controller_size==0x17B4);
static_assert(xanim_base==0xA304 && xanim_data==0x294 && frame_size==0xD478);
static_assert(restore==0x2156C8 && rewind_base==0x2276D8);
static_assert(pointers==0x68 && rewind_active==0x2F8 && object_size==0x2279D8);
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
// Three snapshot-history callers own the query's position/validity outputs
// on their stacks. Grow their frames, saved arguments and Windows unwind/GS
// metadata together. The original count42 ABI cannot accept82 output rows.
constexpr std::uint32_t query_position_growth=(characters-42)*12;
constexpr std::uint32_t query_stack_growth=((characters-42)*13+15)&~15u;
static_assert(query_position_growth==0x1E0 && query_stack_growth==0x210);
struct query_patch {std::uintptr_t address;std::uint32_t before,after;unsigned width{4};};
constexpr query_patch query_code[]={
    {0x140C6236Eull,0x2A0,0x4B0},{0x140C62380ull,0x280,0x490},
    {0x140C62401ull,0x250,0x430},{0x140C6241Bull,0x2F8,0x508},
    {0x140C62433ull,0x290,0x4A0},{0x140C6246Eull,0x250,0x430},
    {0x140C6257Full,0x290,0x4A0},{0x140C62587ull,0x2F8,0x508},
    {0x140C6258Full,0x280,0x490},{0x140C6259Eull,0x2A0,0x4B0},
    {0x140C62DAEull,0x2A0,0x4B0},{0x140C62DC0ull,0x280,0x490},
    {0x140C62E25ull,0x250,0x430},{0x140C62E58ull,0x2F8,0x508},
    {0x140C62E65ull,0x290,0x4A0},{0x140C62E88ull,0x250,0x430},
    {0x140C62F92ull,0x290,0x4A0},{0x140C62F9Aull,0x2F8,0x508},
    {0x140C62FA2ull,0x280,0x490},{0x140C62FB1ull,0x2A0,0x4B0},
    {0x140C63BEBull,0x270,0x480},{0x140C63BFDull,0x260,0x470},
    {0x140C63F8Full,0x230,0x410},{0x140C63F97ull,0x230,0x410},
    {0x140C63F9Full,0x238,0x418},{0x140C63FACull,0x240,0x420},
    {0x140C63FB7ull,0x248,0x428},{0x140C63FBFull,0x250,0x430},
    {0x140C63FC7ull,0x258,0x438},{0x140C64037ull,0x230,0x410},
    {0x140C640A2ull,0x231,0x411},{0x140C6410Eull,0x232,0x412},
    {0x140C6417Aull,0x233,0x413},{0x140C64218ull,0x230,0x410},
    {0x140C642D8ull,0x260,0x470},{0x140C642E8ull,0x270,0x480}
};
constexpr query_patch query_unwind[]={
    {0x1416CCF5Aull,0x54,0x96,2},{0x1416CCF70ull,0x280,0x490},
    {0x1416CCF7Aull,0x5F,0xA1,2},{0x1416CCF8Eull,0x29,0x4A,2},
    {0x1416CCF12ull,0x54,0x96,2},{0x1416CCF28ull,0x280,0x490},
    {0x1416CCF32ull,0x29,0x4A,2},{0x1416CCF36ull,0x5F,0xA1,2},
    {0x1416E29A2ull,0x57,0x99,2},{0x1416E29A6ull,0x56,0x98,2},
    {0x1416E29AAull,0x55,0x97,2},{0x1416E29AEull,0x4E,0x90,2},
    {0x1416E29C0ull,0x260,0x470}
};
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
inline const char* wire_contract(bool expanded) noexcept { return expanded ? "64-v3" : "24"; }
inline bool compatible_wire(bool expanded,std::string_view peer) noexcept {
    return expanded ? peer=="64-v3" : peer.empty() || peer=="24";
}
inline bool compatible_peer(std::string_view peer) noexcept { return compatible_wire(installed(),peer); }
}
