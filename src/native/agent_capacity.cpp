#include <std_include.hpp>
#include "agent_capacity.hpp"
#include "loader/component_loader.hpp"
#include "game/game.hpp"
#include "scheduler.hpp"
#include "console/console.hpp"
#include <utils/flags.hpp>
#include <shellapi.h>
#include <algorithm>
#include <atomic>
#include <cstring>
#include <cwchar>
#include <string>
#include <vector>
#pragma comment(lib, "shell32.lib")

// Engine agent capacity: see agent_capacity.hpp. Off unless the process starts with -agent-capacity <n>.
// Server and client must run the same count (the wire layout of characters changes); the server announces it as
// the "agentcap" info key and refuses a client that does not match (party.cpp hook in the build overlay).
namespace agent_capacity {
namespace {
constexpr std::uintptr_t image_base = 0x140000000ull, image_end = 0x14C301400ull;

layout L{};
std::atomic_bool active{};
std::string contract = "24";

struct buffer { std::uintptr_t data{}; std::size_t bytes{}; };
buffer agent_pool, sentient_pool, table8, table20, parts_pool;

struct patch { std::uintptr_t address{}; unsigned width{}; std::uint32_t before{}, after{}; bool code{true}; };
std::vector<patch> plan;

// Storage the shipped code addresses with 32-bit displacements (image-base relative or rip relative) must stay
// within 2 GB of the image: reserve it just above the image, guard bytes on both sides.
buffer reserve(std::size_t bytes) {
    const auto committed = (bytes + 32 + 4095) & ~std::size_t(4095);
    for (unsigned attempt = 0; attempt < 4096; ++attempt) {
        const auto wanted = 0x150000000ull + static_cast<std::uintptr_t>(attempt) * 0x10000;
        auto memory = VirtualAlloc(reinterpret_cast<void*>(wanted), committed, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
        if (!memory) continue;
        const auto data = reinterpret_cast<std::uintptr_t>(memory) + 16;
        std::memset(memory, 0xA7, 16);
        std::memset(reinterpret_cast<void*>(data + bytes), 0xA7, 16);
        return {data, bytes};
    }
    throw std::runtime_error("agent capacity: no storage within 2 GB of the image");
}

void readable(std::uintptr_t address, unsigned width) {
    MEMORY_BASIC_INFORMATION info{};
    if (address < image_base || address + width > image_end ||
        VirtualQuery(reinterpret_cast<void*>(address), &info, sizeof(info)) != sizeof(info) ||
        info.State != MEM_COMMIT || (info.Protect & PAGE_GUARD) ||
        address + width > reinterpret_cast<std::uintptr_t>(info.BaseAddress) + info.RegionSize)
        throw std::runtime_error("agent capacity: address not readable " + std::to_string(address));
}

void add(std::uintptr_t address, std::uint32_t before, std::uint32_t after, unsigned width = 4, bool code = true) {
    readable(address, width);
    std::uint32_t actual{};
    std::memcpy(&actual, reinterpret_cast<void*>(address), width);
    if (actual != before) {
        char text[160];
        sprintf_s(text, "agent capacity: the shipped code differs at %llX (%X, expected %X)",
            static_cast<unsigned long long>(address), actual, before);
        throw std::runtime_error(text);
    }
    if (width < 4 && after >> (8 * width)) throw std::runtime_error("agent capacity: value does not fit its field");
    plan.push_back({address, width, before, after, code});
}
void add1(std::uintptr_t address, std::uint32_t before, std::uint32_t after) { add(address, before, after, 1); }
void rip(std::uintptr_t field, std::uintptr_t before, std::uintptr_t after, unsigned tail = 0) {
    std::int32_t o{}, n{};
    if (!relative32(before, field + 4 + tail, o) || !relative32(after, field + 4 + tail, n))
        throw std::runtime_error("agent capacity: rip displacement overflow");
    add(field, static_cast<std::uint32_t>(o), static_cast<std::uint32_t>(n));
}
void rva(std::uintptr_t field, std::uint32_t before, std::uintptr_t after) {
    if (after < image_base || after - image_base > 0x7fffffff) throw std::runtime_error("agent capacity: rva overflow");
    add(field, before, static_cast<std::uint32_t>(after - image_base));
}
template <std::size_t N> void block(std::uintptr_t address, const std::array<std::uint8_t, N>& before,
                                    const std::array<std::uint8_t, N>& after) {
    readable(address, static_cast<unsigned>(N));
    if (std::memcmp(reinterpret_cast<void*>(address), before.data(), N))
        throw std::runtime_error("agent capacity: instruction block differs at " + std::to_string(address));
    for (std::size_t i = 0; i < N; ++i) add1(address + i, before[i], after[i]);
}

bool write(const patch& item, bool rollback) noexcept {
    DWORD previous{};
    auto address = reinterpret_cast<void*>(item.address);
    if (!VirtualProtect(address, item.width, item.code ? PAGE_EXECUTE_READWRITE : PAGE_READWRITE, &previous)) return false;
    const auto value = rollback ? item.before : item.after;
    std::memcpy(address, &value, item.width);
    const bool flushed = !item.code || FlushInstructionCache(GetCurrentProcess(), address, item.width) != FALSE;
    DWORD ignored{};
    return VirtualProtect(address, item.width, previous, &ignored) && flushed && !std::memcmp(address, &value, item.width);
}

// ---- 1. agent records, sentients, characters, entity layout (server; the dedicated and a listen host) ----------
void plan_agents() {
    const auto& l = L;
    add(0x140C18D77, stock_agents, l.agents);               // G_GetMaxAgents (sub_140C18D00): min(atoi(scr_*_maxagents), 24)
    // The stock game writes "24" into scr_zombie_maxagents and scr_default_maxagents itself (run h1, 11 Nov 2026: both
    // read 24 with the clamp raised, 24 agents). With the capacity on, the count is the server's: `call atoi` -> `mov eax, n`.
    block(0x140C18D6E, std::array<std::uint8_t, 5>{0xe8, 0x35, 0xed, 0x6a, 0x00},
          std::array<std::uint8_t, 5>{0xb8, static_cast<std::uint8_t>(l.agents), 0, 0, 0});
    add(0x1405AFFF6, stock_characters, l.characters);        // entity layout: characters
    add(0x1405B0000, 58, l.map_start);                       // first map entity
    add(0x14B54FA72, 58, l.map_start); add(0x14B54FA7C, 58, l.map_start); // G_InitGame's own reservation
    add(0x140B6686F, 58 * 0x3F8, l.map_start * 0x3F8);
    add1(0x140B67402, 42, l.player_corpses);                 // ClonePlayer corpse allocator
    add1(0x140C1BB22, 50, l.agent_corpses);                  // CloneAgent corpse allocator
    for (auto f : {0x1407AE403ull, 0x140823B61ull, 0x140826385ull, 0x14086D122ull, 0x140872E65ull}) add1(f, 42, l.player_corpses);
    for (auto f : {0x1407AF52Full, 0x140823B80ull, 0x140865EB9ull, 0x14086F509ull, 0x140872EECull}) add1(f, 50, l.agent_corpses);
    add1(0x1408213F4, 0x100 - 50, 0x100 - l.agent_corpses);   // lea ebx, [entity - first agent corpse]
    add1(0x140B2F536, 42, l.player_corpses);
    // character decode ("Received entnum %d: must index MAX_CHARACTERS_MP", sub_14084A530), lookup, interpolation, teardown
    for (auto f : {0x14084A551ull, 0x140842A20ull, 0x140842B0Bull, 0x14077EDEEull, 0x1407801DEull, 0x140780549ull,
                   0x140805D4Eull, 0x140282ED8ull, 0x1402854DEull, 0x1405C2578ull, 0x140B202DCull}) add1(f, 42, l.characters);
    // agent-state delta: explicit character index 6 -> 7 bits (writer and the live/demo readers)
    for (auto f : {0x140BBFAB5ull, 0x140BBFB08ull, 0x1409B7542ull, 0x140C655D8ull, 0x140C65C51ull}) add(f, 6, 7);
    // entity-state clientNum (offset 0x9C) in the 21 CP field lists: 6 -> 7 bits
    for (auto f : {0x141BB3F50ull, 0x141BB45FCull, 0x141BB4790ull, 0x141BB4A80ull, 0x141BB4D64ull, 0x141BB50C0ull,
                   0x141BB5410ull, 0x141BB576Cull, 0x141BB59F0ull, 0x141BB5C08ull, 0x141BB5FB8ull, 0x141BB61E8ull,
                   0x141BB6634ull, 0x141BB6858ull, 0x141BB6B24ull, 0x141BB6E50ull, 0x141BB71E8ull, 0x141BB7460ull,
                   0x141BB775Cull, 0x141BB7D98ull, 0x141BB9EF0ull}) {
        readable(f - 4, 12);
        std::uint32_t d[3]{};
        std::memcpy(d, reinterpret_cast<void*>(f - 4), sizeof(d));
        if (d[0] != 0x9C) throw std::runtime_error("agent capacity: clientNum net field differs");
        add(f, 6, 7, 4, false);
    }
    // three more 6-bit clientNum fields (live .data; map engine-zombie-limits.md 9b): the event-entity list (eType >= 30),
    // list group2[0] and the agentState list (+0x9C)
    for (auto f : {0x141BB41E0ull, 0x141BB9AF4ull, 0x141BB7F44ull}) {
        readable(f - 4, 12);
        std::uint32_t d[3]{};
        std::memcpy(d, reinterpret_cast<void*>(f - 4), sizeof(d));
        if (d[0] != 0x9C) throw std::runtime_error("agent capacity: clientNum net field differs");
        add(f, 6, 7, 4, false);
    }
    // server AI loops over characters by entity byte offset (cmp reg, 42 x 0x3F8): agents past entity 41 were skipped.
    // 0x1400A9865 is left: its collector fills a 6-int stack array in sub_140B69E20 with no bound (not done).
    for (auto f : {0x140C22AE3ull, 0x140C29144ull, 0x140C390F8ull, 0x140C3A939ull, 0x140C3CB5Cull, 0x140C3D17Bull, 0x140C481FEull})
        add(f, stock_characters * 0x3F8, l.characters * 0x3F8);
    add1(0x140C217CD, 42, l.characters);                     // per-frame round-robin over characters (sub_140C21740)
    add1(0x140C3F3AA, 42, l.characters);                     // gametype table setup loop (sub_140C3F1E0)
    // server hunk budget for the snapshot agent rings (sub_140C68880): frames x 24 x 0xC0 as lea [r+r*8] / shl 9
    block(0x140C68901, std::array<std::uint8_t, 6>{0x8d, 0x04, 0xf6, 0xc1, 0xe0, 0x09},
          std::array<std::uint8_t, 6>{0x69, 0xc6, static_cast<std::uint8_t>(l.agents * 0xC0), static_cast<std::uint8_t>((l.agents * 0xC0) >> 8), 0, 0});
    block(0x140C68977, std::array<std::uint8_t, 7>{0x43, 0x8d, 0x04, 0xff, 0xc1, 0xe0, 0x09},
          std::array<std::uint8_t, 7>{0x41, 0x69, 0xc7, static_cast<std::uint8_t>(l.agents * 0xC0), static_cast<std::uint8_t>((l.agents * 0xC0) >> 8), 0, 0});
    add(0x140007781, stock_agents, l.agents);                // character-reference reset
    for (auto a : {0x140406F77ull, 0x141238588ull, 0x140C14B28ull, 0x140C14BF3ull, 0x140C14C96ull}) add(a, 0x78180, l.agent_bytes());
    rip(0x14C1ED662, 0x145C9E590, agent_pool.data);
    rip(0x140007788, 0x145CA32A0, agent_pool.data + 0x4D10);
    add(0x14B3C5D02, stock_agents, l.agents);                // sentient init: agents (+ the 47 others the next LEA adds)
    add(0x140AF6331, 0x2C60, l.sentient_bytes());
    rip(0x140AF6324, 0x145C6F5A0, sentient_pool.data);
    rip(0x140AF6F2A, 0x145C6F5A0, sentient_pool.data);
    add1(0x1404494FD, stock_agents, l.agents); add1(0x140449696, stock_agents, l.agents); // G_WriteStruct agent bounds
    // server character information and the per-player data after it: one object, grown together
    add(0x140B1F4FE, 0x7A0D8, l.server_size()); add(0x140449EE9, 0x7A0D8, l.server_size());
    add(0x140449EAB, 0x7A0D0, l.server_size() - 8);
    add(0x14044A0CA, 0x798F8, 0x798F8 + l.character_growth());
    add(0x140B205B4, 0x2B7130, 0x2B7130 + l.character_growth() + (l.characters - stock_characters) * 0x40 + l.archive_growth());
    for (auto a : {0x140B1F5ADull, 0x140B1F5C3ull, 0x140486F35ull, 0x140486F4Bull, 0x140486F63ull}) add(a, 0xA88, l.reference_bytes());
    for (auto a : {0x140434FD4ull, 0x14044928Eull, 0x14044936Cull, 0x14048C1EEull, 0x14048C2CCull}) add(a, stock_characters, l.characters);
    // fixed character work tables (8 and 5 x 20 bytes a character)
    for (auto f : {0x14049084Aull, 0x140491BFBull, 0x140AC6795ull, 0x140AC683Aull, 0x140AC6A76ull, 0x140AC6AB4ull,
                   0x140AC6C06ull, 0x140AC6E74ull, 0x140AC6EB1ull, 0x140AC6F3Aull}) rip(f, 0x145C51580, table8.data);
    rip(0x140AC6AD4, 0x145C51582, table8.data + 2);
    rip(0x140AC6ADE, 0x145C516D2, table8.data + l.table8_bytes() + 2);
    for (auto f : {0x140490882ull, 0x140491C34ull, 0x140AC6905ull, 0x140AC6B03ull}) rip(f, 0x145C516D0, table20.data);
    rip(0x140AC6B1A, 0x145C52738, table20.data + l.table20_bytes());
    rva(0x140AC6B71, 0x5C51580, table8.data); rva(0x140AC6B7B, 0x5C51584, table8.data + 4);
    rva(0x140AC6C7E, 0x5C516D4, table20.data + 4); rva(0x140AC6C99, 0x5C516D2, table20.data + 2);
    rva(0x140AC6CCE, 0x5C516E0, table20.data + 16); rva(0x140AC6CEB, 0x5C516D0, table20.data);
    add1(0x140AC67C1, 42, l.characters); add1(0x140AC686E, 42, l.characters);
    add(0x140AC6933, 210, l.characters * 5); add(0x140AC6AC2, 336, l.table8_bytes()); add(0x140AC6B0E, 4200, l.table20_bytes());
}

// ---- 2. lag-compensation archive (CP server): 40 history frames of per-character controllers and saved trees -----
void plan_archive() {
    const auto& l = L;
    const auto d = l.controller_records(); // controller records start after 2 bytes of flags per character
    add(0x140B1F55A, 0x2077F0, l.archive_size());
    add(0x14B431B51, 0x2077F0, l.archive_size());
    add(0x140445927, 0xC7A8, l.frame_size()); add(0x14044592D, 0xC7A8, l.frame_size()); add(0x140445A67, 0xC7A8, l.frame_size());
    add(0x140445A73, 0x1F5648, l.restore());
    add(0x14044608F, 0x3C58, l.frame_size() - 0x8B50);
    add(0x140445C33, 0x9774, l.xanim_base());
    add(0x140445D2A, 0, (d - 0x54) / 8);
    add(0x140445DAB, 0x150, l.xanim_counter());
    add(0x140445DBE, 0x55, l.xanim_data() / 4);
    add(0x140445DDA, 0xA8, l.xanim_counts());
    add(0x140445DE0, 0x150, l.xanim_counter());
    for (auto a : {0x140445AB8ull, 0x140445B5Full, 0x140445B96ull, 0x140445ED2ull}) add(a, 0x2077E8, l.rewind_base() + l.rewind_active());
    add(0x140445ACE, 0x207698, l.rewind_base() + l.rewind_pointers());
    add(0x140445ADF, 0x20766C, l.rewind_base() + 0x14);
    add(0x140445B7B, 0x207668, l.rewind_base() + 0x10);
    for (auto a : {0x140445B82ull, 0x140445EDCull}) add(a, 0x207658, l.rewind_base());
    add(0x140445B90, 0x207660, l.rewind_base() + 8);
    add1(0x140445B45, 42, l.characters);
    add(0x140445F0C, 42, l.characters);
    add(0x1400A8585, 42, l.characters);
    add1(0x140415C28, 0x40, l.rewind_pointers());
    for (auto a : {0x140414E42ull, 0x140414E78ull, 0x1404151BCull, 0x1404151E7ull, 0x140415264ull, 0x1404152EAull})
        add(a, 0xCCC, l.controller_size() + l.xanim_counts());
    for (auto a : {0x1404151A7ull, 0x1404151DAull, 0x140415254ull, 0x1404152DAull}) add(a, 0xC24, l.controller_size());
    for (auto a : {0x1404151C3ull, 0x1404151EEull, 0x14041526Bull, 0x1404152F1ull})
        add(a, 0x1AF, (l.controller_size() + l.xanim_data()) / 8);
    // Three straight-line copies used a disp8 of 0x54 (= 2 x 42); re-encode them with a disp32 of 2 x characters.
    const std::uint8_t b0 = d & 0xff, b1 = (d >> 8) & 0xff;
    const std::array<std::uint8_t, 33> blend_before = {0x48,0x8d,0x57,0x54,0x4c,0x8b,0x4c,0x24,0x70,0xf3,0x0f,0x10,0x55,0x10,
        0x48,0x8d,0x0c,0xc0,0x48,0x8d,0x14,0xca,0x48,0x8d,0x0c,0xcd,0x54,0,0,0,0x48,0x03,0xcb};
    const std::array<std::uint8_t, 33> blend_after = {0x48,0x8d,0x0c,0xc0,0x48,0x8d,0x94,0xcf,b0,b1,0,0,
        0x48,0x8d,0x8c,0xcb,b0,b1,0,0,0x4c,0x8b,0x4c,0x24,0x70,0xf3,0x0f,0x10,0x55,0x10,0x90,0x90,0x90};
    const std::array<std::uint8_t, 64> next_before = {0x49,0x63,0x06,0x48,0x8d,0x0c,0xc0,0x48,0x8b,0x44,0x24,0x70,
        0x0f,0x10,0x44,0xcf,0x54,0x0f,0x11,0x00,0x0f,0x10,0x4c,0xcf,0x64,0x0f,0x11,0x48,0x10,0x0f,0x10,0x44,0xcf,0x74,
        0x0f,0x11,0x40,0x20,0x0f,0x10,0x8c,0xcf,0x84,0,0,0,0x0f,0x11,0x48,0x30,0xf2,0x0f,0x10,0x84,0xcf,0x94,0,0,0,
        0xe9,0x81,0,0,0};
    const std::array<std::uint8_t, 59> previous_before = {0x49,0x63,0x06,0x48,0x8d,0x0c,0xc0,0x48,0x8b,0x44,0x24,0x70,
        0x0f,0x10,0x44,0xcb,0x54,0x0f,0x11,0x00,0x0f,0x10,0x4c,0xcb,0x64,0x0f,0x11,0x48,0x10,0x0f,0x10,0x44,0xcb,0x74,
        0x0f,0x11,0x40,0x20,0x0f,0x10,0x8c,0xcb,0x84,0,0,0,0x0f,0x11,0x48,0x30,0xf2,0x0f,0x10,0x84,0xcb,0x94,0,0,0};
    auto copy_after = [&](auto& code, bool next) {
        for (auto& byte : code) byte = 0x90;
        const std::uint8_t body[] = {0x49,0x63,0x06,0x48,0x6b,0xc8,0x48,0x48,0x8d,0x8c,0x0b,b0,b1,0,0,
            0x48,0x8b,0x44,0x24,0x70,0x0f,0x10,0x01,0x0f,0x11,0x00,0x0f,0x10,0x49,0x10,0x0f,0x11,0x48,0x10,
            0x0f,0x10,0x41,0x20,0x0f,0x11,0x40,0x20,0x0f,0x10,0x49,0x30,0x0f,0x11,0x48,0x30,0xf2,0x0f,0x10,0x41,0x40};
        std::copy(std::begin(body), std::end(body), code.begin());
        const auto n = code.size();
        if (next) { code[10] = 0x0f; code[n - 5] = 0xe9; code[n - 4] = 0x81; code[n - 3] = code[n - 2] = code[n - 1] = 0; }
    };
    std::array<std::uint8_t, 64> next_after{}; copy_after(next_after, true);
    std::array<std::uint8_t, 59> previous_after{}; copy_after(previous_after, false);
    block(0x140415205, blend_before, blend_after);
    block(0x14041527F, next_before, next_after);
    block(0x140415305, previous_before, previous_after);
    // Three snapshot-history callers keep the query's 42 positions (12 bytes) and validity bytes on their stacks:
    // grow those frames, their saved-argument slots and their unwind data together.
    const auto s = l.query_stack_growth(), p = l.query_position_growth();
    struct q { std::uintptr_t a; std::uint32_t before; bool stack; };
    for (const auto& i : {q{0x140C6236E,0x2A0,1},q{0x140C62380,0x280,1},q{0x140C62401,0x250,0},q{0x140C6241B,0x2F8,1},
             q{0x140C62433,0x290,1},q{0x140C6246E,0x250,0},q{0x140C6257F,0x290,1},q{0x140C62587,0x2F8,1},q{0x140C6258F,0x280,1},
             q{0x140C6259E,0x2A0,1},q{0x140C62DAE,0x2A0,1},q{0x140C62DC0,0x280,1},q{0x140C62E25,0x250,0},q{0x140C62E58,0x2F8,1},
             q{0x140C62E65,0x290,1},q{0x140C62E88,0x250,0},q{0x140C62F92,0x290,1},q{0x140C62F9A,0x2F8,1},q{0x140C62FA2,0x280,1},
             q{0x140C62FB1,0x2A0,1},q{0x140C63BEB,0x270,1},q{0x140C63BFD,0x260,1},q{0x140C63F8F,0x230,0},q{0x140C63F97,0x230,0},
             q{0x140C63F9F,0x238,0},q{0x140C63FAC,0x240,0},q{0x140C63FB7,0x248,0},q{0x140C63FBF,0x250,0},q{0x140C63FC7,0x258,0},
             q{0x140C64037,0x230,0},q{0x140C640A2,0x231,0},q{0x140C6410E,0x232,0},q{0x140C6417A,0x233,0},q{0x140C64218,0x230,0},
             q{0x140C642D8,0x260,1},q{0x140C642E8,0x270,1}})
        add(i.a, i.before, i.before + (i.stack ? s : p));
    struct u { std::uintptr_t a; std::uint32_t before; unsigned width, scale; };
    for (const auto& i : {u{0x1416CCF5A,0x54,2,8},u{0x1416CCF70,0x280,4,1},u{0x1416CCF7A,0x5F,2,8},u{0x1416CCF8E,0x29,2,16},
             u{0x1416CCF12,0x54,2,8},u{0x1416CCF28,0x280,4,1},u{0x1416CCF32,0x29,2,16},u{0x1416CCF36,0x5F,2,8},
             u{0x1416E29A2,0x57,2,8},u{0x1416E29A6,0x56,2,8},u{0x1416E29AA,0x55,2,8},u{0x1416E29AE,0x4E,2,8},
             u{0x1416E29C0,0x260,4,1}})
        add(i.a, i.before, i.before + s / i.scale, i.width, false);
}

// ---- 3. client: character arrays of the cg object, snapshots carry every agent state -------------------------------
void plan_client() {
    const auto& l = L;
    for (auto a : {0x1402409DAull, 0x140240A17ull, 0x140240A83ull, 0x140241AD9ull, 0x140241AF3ull, 0x140241BCCull,
                   0x140241BDAull, 0x140242BF6ull}) add(a, 0xFDEA8, l.client_size());
    for (auto a : {0x140240AA0ull, 0x140241B15ull, 0x140242C13ull}) add(a, 0xFD7F8, l.client_tail());
    for (auto a : {0x140180172ull, 0x1401833EBull, 0x14018340Bull, 0x140183435ull, 0x140D2BE4Aull}) add(a, 0x86B17, l.client_flags());
    add1(0x140242E22, 41, l.characters - 1); add1(0x140242E3C, 41, l.characters - 1);
    // CL_GetSnapshot copied min(numAgents, 24) agent states: zombies 25+ had entities but no model (invisible).
    for (auto a : {0x1408646D1ull, 0x1408646EAull, 0x140864726ull, 0x1408648BDull}) add(a, 2 * 0x3DC78, 2 * l.snap_size());
    for (auto a : {0x14086470Dull, 0x14086471Full, 0x1408648E9ull, 0x1408648FBull, 0x14086C728ull}) add(a, 0x3DC78, l.snap_size());
    for (auto a : {0x1408706ABull, 0x140873602ull, 0x1408738B3ull, 0x1409934BFull}) add(a, 0x38D48, 0x3DC78);
    add(0x1409934A4, stock_agents, l.agents);
    // SV snapshot buffers (sub_140C68A00): the two agent-state rings hold 24 states a snapshot frame
    // (count = frames x 24 as lea [r+r*2] / shl 3; the allocator sub_140C68B00 sizes them from that count x 0xC0).
    // With more agents a frame the rings wrap before the oldest frame a client may delta from: frames x agents.
    block(0x140C68A82, std::array<std::uint8_t, 4>{0x43, 0x8d, 0x04, 0x52},
                       std::array<std::uint8_t, 4>{0x41, 0x6b, 0xc2, static_cast<std::uint8_t>(l.agents)}); // imul eax, r10d, agents
    block(0x140C68A8D, std::array<std::uint8_t, 3>{0xc1, 0xe0, 0x03}, std::array<std::uint8_t, 3>{0x0f, 0x1f, 0x00});
    block(0x140C68A96, std::array<std::uint8_t, 4>{0x43, 0x8d, 0x04, 0x5b},
                       std::array<std::uint8_t, 4>{0x41, 0x6b, 0xc3, static_cast<std::uint8_t>(l.agents)}); // imul eax, r11d, agents
    block(0x140C68A9A, std::array<std::uint8_t, 3>{0xc1, 0xe0, 0x03}, std::array<std::uint8_t, 3>{0x0f, 0x1f, 0x00});
    // CL snapshot buffers (sub_14034F1D0, called from sub_1409B2620): the client's agent-state ring is frames x agents a
    // frame. A listen host passes the server's own max agents (byte +0x546, set from the patched selector); a client
    // joining a remote server passes 24 as `mov ebp, 18; lea r14d, [rbp + 6]`: the 6 becomes agents - 18.
    add1(0x1409B26FC, 6, l.agents - players);
    // CG_SetNextSnap: the character change mask (one bit a character) grows into a free stack slot
    add1(0x14086FBE0, 0x70, 0x68); add(0x14086FBE3, 0x100, 0x108);
    add1(0x14086FDAF, 0x60, 0x58); add1(0x140870705, 0x60, 0x58);
    for (auto a : {0x14086FE70ull, 0x14086FE78ull, 0x14086FE87ull, 0x140870670ull, 0x1408706D0ull}) add1(a, 0x40, 0x60);
}

// ---- 3b. two per-sentient pools of 71 static objects (built by static constructors sub_140004650, sub_1400046A0) ----
// Run h2 (12 Nov 2026): with 100 agents the 72nd sentient got a null object from the allocator sub_1403EE550 (it scans
// the 71 for a free one, in-use flag +0x8B) and SV_AddAgent crashed writing +0x9C. The second pool (0x180 bytes, allocator
// sub_1403F2820) has the same shape and the same 71. Both move to sentient-slot size; the new objects are built with the
// shipped constructors; the old 71 stay built (their exit destructors still run on them) and unused.
// The references were listed by iw7_xref32.py over each pool and 0x200 past it, then read one by one: a `lea` of the
// first object (+field) starts a scan, a `lea` of the end (+field) bounds it; `mov` from just past the end are other
// globals and stay.
struct object_pool {
    std::uintptr_t base; std::uint32_t stride; std::uintptr_t ctor; std::array<std::uint8_t, 8> ctor_head;
    buffer storage;
};
object_pool ai_pools[] = {
    {0x143C34440, 0x4D0, 0x1403EAC70, {0x48, 0x89, 0x5c, 0x24, 0x08, 0x48, 0x89, 0x6c}, {}},
    {0x143C4BA00, 0x180, 0x1403F0D40, {0x48, 0x89, 0x5c, 0x24, 0x08, 0x48, 0x89, 0x74}, {}},
};
constexpr std::uint32_t ai_stock = 71;
void build_ai_objects() {
    for (auto& pool : ai_pools) {
        pool.storage = reserve(L.sentient_slots() * pool.stride);
        readable(pool.ctor, 8);
        if (std::memcmp(reinterpret_cast<void*>(pool.ctor), pool.ctor_head.data(), 8))
            throw std::runtime_error("agent capacity: a sentient object constructor differs");
        const auto construct = reinterpret_cast<void* (*)(void*)>(pool.ctor);
        for (std::uint32_t i = 0; i < L.sentient_slots(); ++i) construct(reinterpret_cast<void*>(pool.storage.data + i * pool.stride));
    }
}
void plan_ai_pool() {
    struct r { int pool; std::uintptr_t field; std::uint32_t off; bool at_end; };
    for (const auto& i : {
             r{0, 0x1403EB90D, 0xA0, false}, r{0, 0x1403EB917, 0xA0, true},       // sub_1403EB8F0
             r{0, 0x1403EBAA5, 0, false}, r{0, 0x1403EBAAC, 0, true},             // sub_1403EBA90
             r{0, 0x1403EBB4A, 0, false}, r{0, 0x1403EBB51, 0, true},             // sub_1403EBB20
             r{0, 0x1403F0259, 0, false}, r{0, 0x1403F0260, 0, true},             // sub_1403F0230
             r{0, 0x1403EE55A, 0x8B, false}, r{0, 0x1403EE567, 0x8B, true},       // allocator sub_1403EE550
             r{0, 0x1403EE59F, 0, false},
             r{0, 0x1403EE629, 0x30, false}, r{0, 0x1403EE630, 0x30, true},       // sub_1403EE600
             r{0, 0x1403EE9A4, 0x8B, false}, r{0, 0x1403EE9AB, 0x8B, true},       // restore sub_1403EE780
             r{0, 0x1403EF012, 0, false},
             r{1, 0x1403F126D, 0x8B, false}, r{1, 0x1403F127A, 0xC8, false},      // sub_1403F1250 (count below)
             r{1, 0x1403F1346, 0, false}, r{1, 0x1403F1352, 0, true},             // sub_1403F1330
             r{1, 0x1403F282A, 0x8B, false}, r{1, 0x1403F2831, 0x8B, true},       // allocator sub_1403F2820
             r{1, 0x1403F2862, 0, false},
             r{1, 0x1403F29B2, 0x8B, false}, r{1, 0x1403F29B9, 0x8B, true},       // restore sub_1403F28A0
             r{1, 0x1403F29E4, 0, false},
             r{1, 0x1403F3510, 0, false}, r{1, 0x1403F3517, 0, true}}) {         // sub_1403F34F0
        const auto& pool = ai_pools[i.pool];
        const auto old_end = pool.base + ai_stock * pool.stride;
        const auto new_end = pool.storage.data + L.sentient_slots() * pool.stride;
        rip(i.field, (i.at_end ? old_end : pool.base) + i.off, (i.at_end ? new_end : pool.storage.data) + i.off);
    }
    add(0x1403F1273, ai_stock, L.sentient_slots());                          // sub_1403F1250 walks the pool by count
}

// ---- 3c. two static free-list pools of 64 (a per-entity map: 64 tree nodes of 0x30 and 64 blocks of 0x810) ---------
// Run h3 (14 Nov 2026): with more than 24 agents active, sub_1403DCC50 (called from sub_1403E1E30 under a script
// builtin) popped a block from the free list at 0x143C1A580 when it was empty (the empty list points at its own head)
// and the red-black tree at 0x143BFA140 was corrupted (crash writing [0] in sub_140093B10). Both lists are chained once
// by static initialisers (sub_140004440: 64 x 0x810 below 0x143C1A580; sub_140004490: 64 x 0x30 below 0x143BFA140) and
// nothing else addresses the pool memory: more capacity = more blocks appended to the free lists, no code patched.
void extend_free_list(std::uintptr_t head, std::uint32_t stride, std::uint32_t count) {
    readable(head, 8);
    const auto storage = reserve(static_cast<std::size_t>(stride) * count);
    // walk to the last free element (its next is the head itself: the empty-list sentinel)
    auto prev = head;
    for (unsigned guard = 0; guard < 100000; ++guard) {
        const auto next = *reinterpret_cast<std::uintptr_t*>(prev);
        if (next == head) break;
        prev = next;
    }
    for (std::uint32_t i = 0; i < count; ++i) {
        const auto block = storage.data + static_cast<std::uintptr_t>(i) * stride;
        *reinterpret_cast<std::uintptr_t*>(prev) = block;
        prev = block;
    }
    *reinterpret_cast<std::uintptr_t*>(prev) = head;
    console::info("[agent capacity] free list %llX: +%u blocks of 0x%X\n", static_cast<unsigned long long>(head), count, stride);
}

// ---- 4. reserved scriptable parts (server): one free list of 2,048 u16 links -----------------------------------------
// ScriptableSv_LinkReservedScriptable (sub_140BF96A0) takes one slot a part; an agent's model takes 31, so 24 agents
// hold 744 and 78 would need 2,418 ("Too many reserved scriptable parts", ERR_DROP). Free (sub_140BF9A70), init
// (sub_140BF7770), lookup (sub_140BFA3D0) and the save/restore of the pool (sub_140BF6F20) are the only readers
// (iw7_xref32.py over the unpacked code: rip, image-base relative and absolute forms).
void plan_parts() {
    const auto& l = L;
    rip(0x140BF77BC, 0x1460B22F2, parts_pool.data + 2);
    add(0x140BF77C4, stock_parts, l.parts);
    add(0x140BF97FB, stock_parts, l.parts);
    rva(0x140BF981C, 0x60B22F2, parts_pool.data + 2);
    rva(0x140BF982C, 0x60B22F0, parts_pool.data);
    rva(0x140BF9839, 0x60B22F2, parts_pool.data + 2);
    rva(0x140BF9D6C, 0x60B22F0, parts_pool.data);
    rip(0x140BFA40F, 0x1460B22F0, parts_pool.data);
    rip(0x140BF6FF8, 0x1460B22F0, parts_pool.data); add(0x140BF6FFD, stock_parts * 4, l.parts * 4);
    rip(0x140BF731C, 0x1460B22F0, parts_pool.data); add(0x140BF7321, stock_parts * 4, l.parts * 4);
}

std::uint32_t parse_count(const wchar_t* flag, std::uint32_t fallback) {
    int count{};
    auto args = CommandLineToArgvW(GetCommandLineW(), &count);
    if (!args) return 0;
    std::uint32_t result{};
    for (int i = 0; i < count; ++i) {
        if (std::wcscmp(args[i], flag)) continue;
        result = fallback;
        if (i + 1 < count) {
            wchar_t* end{};
            const auto v = std::wcstoul(args[i + 1], &end, 10);
            if (end && !*end && v) result = static_cast<std::uint32_t>(v);
        }
    }
    LocalFree(args);
    return result;
}

// ---- 5. code caves: an instruction that must grow is moved, with its neighbours, into a cave --------------------------
// Planned offline by ops/engine/cave_plan.py (docs/CAVE-REWRITER.md): `agent_capacity_caves.inc` holds, per cave, the
// stock bytes of a window of whole instructions (5 bytes or more), the cave bytes (the same instructions, one of them
// re-encoded, rip-relative fields still holding their stock displacement) and the fixups {offset of the 32-bit field,
// offset of the instruction end, absolute target}. At start: check the stock window, copy the cave bytes into executable
// memory within 2 GB, re-base each fixup (new = target - (cave address + end)), append `jmp rel32` back, and queue the
// window as `jmp rel32 cave` + int3 fill in the same all-or-nothing transaction as every other patch.
// A cave has no counter (a counter would change flags). `-agent-capacity-cave-fault [mask]` replaces the cave bytes of
// the caves in the mask (bit k = cave k of the table; no value = all) by `ud2`: proof that a cave runs, by a crash
// inside it (a test switch; the environment variable IW7_AGENT_CAPACITY_CAVE_FAULT=<mask> does the same; without either
// nothing here is written differently).
struct cave_fixup { std::uint32_t offset, end; std::uintptr_t target; };
// An incoming reference to an interior instruction of the window, rewritten to point into the cave: kind 0 = the rel32 of a
// jmp/jcc (new = cave + cave_offset - (field + 4)), kind 1 = a 4-byte image-relative jump-table entry (new = cave + offset - image base).
struct cave_retarget { std::uintptr_t field; std::uint32_t kind, old_value, cave_offset; };
struct cave_spec {
    std::uintptr_t window_start;
    std::vector<std::uint8_t> old_bytes, cave_bytes;
    std::vector<cave_fixup> fixups;
    std::vector<cave_retarget> retargets;
};
const std::vector<cave_spec> cave_table = {
#include "agent_capacity_caves.inc"
};
buffer code_region;
std::size_t code_used{};
std::size_t caves_planned{};

buffer reserve_code(std::size_t bytes) {
    const auto committed = (bytes + 4095) & ~std::size_t(4095);
    for (unsigned attempt = 0; attempt < 4096; ++attempt) {
        const auto wanted = 0x150000000ull + static_cast<std::uintptr_t>(attempt) * 0x10000;
        auto memory = VirtualAlloc(reinterpret_cast<void*>(wanted), committed, MEM_RESERVE | MEM_COMMIT, PAGE_EXECUTE_READWRITE);
        if (!memory) continue;
        std::memset(memory, 0xCC, committed);
        return {reinterpret_cast<std::uintptr_t>(memory), committed};
    }
    throw std::runtime_error("agent capacity: no code memory within 2 GB of the image");
}

void cave(std::uintptr_t window_start, const std::vector<std::uint8_t>& old_bytes, const std::vector<std::uint8_t>& cave_bytes,
          const std::vector<cave_fixup>& fixups, const std::vector<cave_retarget>& retargets) {
    const auto length = old_bytes.size();
    if (length < 5 || length > 64 || cave_bytes.empty()) throw std::runtime_error("agent capacity: bad cave window");
    readable(window_start, static_cast<unsigned>(length));
    if (std::memcmp(reinterpret_cast<void*>(window_start), old_bytes.data(), length)) {
        char text[96];
        sprintf_s(text, "agent capacity: the shipped code differs in the cave window at %llX", static_cast<unsigned long long>(window_start));
        throw std::runtime_error(text);
    }
    const auto size = (cave_bytes.size() + 5 + 15) & ~std::size_t(15);
    if (code_used + size > code_region.bytes) throw std::runtime_error("agent capacity: code cave memory exhausted");
    const auto at = code_region.data + code_used;
    code_used += size;
    auto* out = reinterpret_cast<std::uint8_t*>(at);
    std::memcpy(out, cave_bytes.data(), cave_bytes.size());
    for (const auto& f : fixups) {
        std::int32_t rel{};
        if (f.offset + 4 > cave_bytes.size() || f.end > cave_bytes.size() || f.end < f.offset + 4 ||
            !relative32(f.target, at + f.end, rel))
            throw std::runtime_error("agent capacity: cave fixup out of range");
        std::memcpy(out + f.offset, &rel, 4);
    }
    std::int32_t back{}, forth{};
    if (!relative32(window_start + length, at + cave_bytes.size() + 5, back) || !relative32(at, window_start + 5, forth))
        throw std::runtime_error("agent capacity: cave is not within 2 GB of its window");
    out[cave_bytes.size()] = 0xE9;
    std::memcpy(out + cave_bytes.size() + 1, &back, 4);
    // the window: jmp rel32 to the cave, the rest int3 (checked against the stock bytes by add1)
    std::uint8_t window[64];
    window[0] = 0xE9;
    std::memcpy(window + 1, &forth, 4);
    std::memset(window + 5, 0xCC, length - 5);
    for (std::size_t i = 0; i < length; ++i) add1(window_start + i, old_bytes[i], window[i]);
    for (const auto& t : retargets) {
        if (t.cave_offset >= cave_bytes.size()) throw std::runtime_error("agent capacity: cave retarget outside its cave");
        const auto target = at + t.cave_offset;
        if (t.kind == 0) {
            std::int32_t rel{};
            if (!relative32(target, t.field + 4, rel)) throw std::runtime_error("agent capacity: retargeted branch cannot reach its cave");
            add(t.field, t.old_value, static_cast<std::uint32_t>(rel), 4, true);
        } else {
            // a jump-table entry is image base + a 32-bit value: the cave must lie above the image base, within 2 GB of it
            if (target <= image_base || target - image_base > 0x7FFFFFFFull)
                throw std::runtime_error("agent capacity: a jump-table entry cannot point into the cave (cave not above the image base within 2 GB)");
            add(t.field, t.old_value, static_cast<std::uint32_t>(target - image_base), 4, false);
        }
    }
    // one line a cave (short tables only): a fault at an address in cave memory maps back to its window by this range
    if (cave_table.size() <= 32)
        console::info("[agent capacity] cave %zu: window %llX+%zu -> cave %llX..%llX (retargets %zu)\n", caves_planned,
            static_cast<unsigned long long>(window_start), length, static_cast<unsigned long long>(at),
            static_cast<unsigned long long>(at + cave_bytes.size() + 5 - 1), retargets.size());
    ++caves_planned;
}

void plan_caves() {
    if (cave_table.empty()) return;
    std::size_t total = 0;
    for (const auto& c : cave_table) total += (c.cave_bytes.size() + 5 + 15) & ~std::size_t(15);
    code_region = reserve_code(total);
    auto fault = parse_count(L"-agent-capacity-cave-fault", 0xFFFFFFFFu);
    wchar_t from_env[16]{};  // the game-lab plans pass only whitelisted flags: the same switch as an environment variable
    if (!fault && GetEnvironmentVariableW(L"IW7_AGENT_CAPACITY_CAVE_FAULT", from_env, 16) && from_env[0])
        fault = static_cast<std::uint32_t>(std::wcstoul(from_env, nullptr, 10));
    std::size_t k = 0;
    for (const auto& c : cave_table) {
        if (k < 32 && (fault >> k) & 1u) {
            std::vector<std::uint8_t> trap(c.cave_bytes.size(), 0xCC);  // ud2 at the start of a cave of the same size
            trap[0] = 0x0F; trap[1] = 0x0B;
            cave(c.window_start, c.old_bytes, trap, {}, c.retargets);
        } else cave(c.window_start, c.old_bytes, c.cave_bytes, c.fixups, c.retargets);
        ++k;
    }
    if (fault) console::info("[agent capacity] cave fault switch: mask %X (ud2 instead of the instruction)\n", fault);
}

void check_guards() {
    for (const auto& pool : {agent_pool, sentient_pool, table8, table20, parts_pool, ai_pools[0].storage, ai_pools[1].storage})
        for (unsigned i = 0; i < 16; ++i)
            if (*reinterpret_cast<const unsigned char*>(pool.data - 16 + i) != 0xA7 ||
                *reinterpret_cast<const unsigned char*>(pool.data + pool.bytes + i) != 0xA7) {
                game::Com_Error(game::ERR_FATAL, "agent capacity: a relocated table was written out of bounds");
                return;
            }
}

class component final : public component_interface {
public:
    void post_unpack() override {
        const auto agents = parse_count(L"-agent-capacity", 100);
        if (!agents) return;
        const auto parts = std::max<std::uint32_t>(parse_count(L"-scriptable-parts", 0), 8192);
        if (const auto why = refuse(agents); *why) throw std::runtime_error(std::string("agent capacity refused: ") + why);
        if (parts > 0xFFFF) throw std::runtime_error("agent capacity: parts are u16 links (at most 65535)");
        L = make(agents, parts);
        agent_pool = reserve(L.agent_bytes());
        sentient_pool = reserve(L.sentient_bytes());
        table8 = reserve(L.table8_bytes());
        table20 = reserve(L.table20_bytes());
        parts_pool = reserve(L.parts * 4);
        build_ai_objects();
        plan_agents();
        plan_archive();
        plan_client();
        plan_parts();
        plan_ai_pool();
        plan_caves();
        std::sort(plan.begin(), plan.end(), [](const patch& a, const patch& b) { return a.address < b.address; });
        for (std::size_t i = 1; i < plan.size(); ++i)
            if (plan[i - 1].address + plan[i - 1].width > plan[i].address)
                throw std::runtime_error("agent capacity: overlapping patches");
        std::size_t applied{};
        for (; applied < plan.size(); ++applied)
            if (!write(plan[applied], false)) {
                bool restored = write(plan[applied], true);
                while (applied) restored = write(plan[--applied], true) && restored;
                if (!restored) std::terminate();
                throw std::runtime_error("agent capacity: a code write failed; everything restored");
            }
        active = true;
        contract = "agents-" + std::to_string(L.agents);
        scheduler::once([] {
            // after the static initialisers chained the stock 64: add room for every sentient slot twice over
            extend_free_list(0x143C1A580, 0x810, 2 * L.sentient_slots());
            extend_free_list(0x143BFA140, 0x30, 2 * L.sentient_slots());
            // G_GetMaxAgents reads scr_<gametype>_maxagents, else scr_default_maxagents: make the default the new count.
            const auto value = std::to_string(L.agents);
            game::Dvar_RegisterString("scr_default_maxagents", value.data(), game::DVAR_FLAG_NONE, "Agents this server can hold");
            game::Dvar_RegisterInt("agent_capacity", L.agents, L.agents, L.agents, game::DVAR_FLAG_NONE, "Engine agent records");
            game::Dvar_RegisterInt("agent_capacity_parts", L.parts, L.parts, L.parts, game::DVAR_FLAG_NONE, "Reserved scriptable parts");
            console::info("[agent capacity] agents=%u characters=%u map_start=%u parts=%u patches=%zu caves=%zu\n",
                L.agents, L.characters, L.map_start, L.parts, plan.size(), caves_planned);
        }, scheduler::main);
        scheduler::loop(check_guards, scheduler::main, 500ms);
    }
};
}

bool installed() noexcept { return active; }
std::uint32_t agents() noexcept { return active ? L.agents : stock_agents; }
const char* wire_contract() noexcept { return contract.c_str(); }
}

REGISTER_COMPONENT(agent_capacity::component)
