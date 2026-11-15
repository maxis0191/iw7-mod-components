#include <std_include.hpp>
#include "agent_capacity.hpp"
#include "loader/component_loader.hpp"
#include "game/game.hpp"
#include "scheduler.hpp"
#include "console/console.hpp"
#include "command.hpp"
#include <utils/flags.hpp>
#include <utils/hook.hpp>
#include <shellapi.h>
#include <intrin.h>
#include <malloc.h>
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
buffer agent_pool, sentient_pool, table8, table20, parts_pool, entity_queue;
buffer state_a, state_c, state_client, state_x;   // replicated scriptable state (section 4b)
buffer pool_server[stream_pool_classes], pool_client[stream_pool_classes];   // scriptable stream buffer pools (section 4d)
std::size_t queue_references{};

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
// One unsigned byte: a byte of a block or of a cave window, written exactly as given.
void add1(std::uintptr_t address, std::uint32_t before, std::uint32_t after) { add(address, before, after, 1); }
// One byte the CPU sign-extends (a disp8, or the imm8 of an `83 /r`, `6B`, `48 83` form): 0x90 there is -112. `intended` is the
// value the instruction must read, negative for a negative displacement; one that a signed byte cannot hold is refused at plan time.
void add1s(std::uintptr_t address, std::uint32_t before, std::int32_t intended) {
    if (!fits_signed_byte(intended)) {
        char text[160];
        sprintf_s(text, "agent capacity: %d does not fit a signed 8-bit field (the CPU sign-extends the byte at %llX)", intended,
            static_cast<unsigned long long>(address));
        throw std::runtime_error(text);
    }
    add(address, before, static_cast<std::uint8_t>(intended), 1);
}
std::uint8_t unsigned_imm8(std::uint32_t value) { // the low byte of a `mov eax, imm32` whose other three bytes are zero
    if (value > 0xFF) throw std::runtime_error("agent capacity: value does not fit one byte");
    return static_cast<std::uint8_t>(value);
}
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

// `cmp ax, imm8` (66 83 f8 ib, 4 bytes) -> `cmp ax, imm16` (66 3d iw, 4 bytes): the same length, in place.
void wide16(std::uintptr_t address, std::uint32_t value) {
    if (value > 0xFFFF) throw std::runtime_error("agent capacity: value does not fit a 16-bit immediate");
    block(address, std::array<std::uint8_t, 4>{0x66, 0x83, 0xf8, 0x2a},
          std::array<std::uint8_t, 4>{0x66, 0x3d, static_cast<std::uint8_t>(value), static_cast<std::uint8_t>(value >> 8)});
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
          std::array<std::uint8_t, 5>{0xb8, unsigned_imm8(l.agents), 0, 0, 0});
    add(0x1405AFFF6, stock_characters, l.characters);        // entity layout: characters
    add(0x1405B0000, 58, l.map_start);                       // first map entity
    add(0x14B54FA72, 58, l.map_start); add(0x14B54FA7C, 58, l.map_start); // G_InitGame's own reservation
    add(0x140B6686F, 58 * 0x3F8, l.map_start * 0x3F8);
    // The corpse allocators and bounds (ClonePlayer 0x140B67400, CloneAgent 0x140C1BB20, the entity - first corpse subtractions) and the
    // character bounds ("Received entnum %d: must index MAX_CHARACTERS_MP", lookup, interpolation, teardown) were one-byte fields: they
    // hold 32-bit values in caves now (wide_site, plan_caves) and, for the two 16-bit compares, in place (wide16).
    wide16(0x14077EDEB, l.characters);                        // cmp ax, characters (FUN_14077ecd0)
    wide16(0x1407801DB, l.characters);                        // cmp ax, characters (FUN_14077ff50)
    // agent-state delta: explicit character index 6 -> 7 bits (8 above 127 characters; writer and the live/demo readers)
    for (auto f : {0x140BBFAB5ull, 0x140BBFB08ull, 0x1409B7542ull, 0x140C655D8ull, 0x140C65C51ull}) add(f, 6, l.net_id_bits());
    // entity-state clientNum (offset 0x9C) in the 21 CP field lists: 6 -> 7 bits (8 above 127 characters)
    for (auto f : {0x141BB3F50ull, 0x141BB45FCull, 0x141BB4790ull, 0x141BB4A80ull, 0x141BB4D64ull, 0x141BB50C0ull,
                   0x141BB5410ull, 0x141BB576Cull, 0x141BB59F0ull, 0x141BB5C08ull, 0x141BB5FB8ull, 0x141BB61E8ull,
                   0x141BB6634ull, 0x141BB6858ull, 0x141BB6B24ull, 0x141BB6E50ull, 0x141BB71E8ull, 0x141BB7460ull,
                   0x141BB775Cull, 0x141BB7D98ull, 0x141BB9EF0ull}) {
        readable(f - 4, 12);
        std::uint32_t d[3]{};
        std::memcpy(d, reinterpret_cast<void*>(f - 4), sizeof(d));
        if (d[0] != 0x9C) throw std::runtime_error("agent capacity: clientNum net field differs");
        add(f, 6, l.net_id_bits(), 4, false);
    }
    // three more 6-bit clientNum fields (live .data; map engine-zombie-limits.md 9b): the event-entity list (eType >= 30),
    // list group2[0] and the agentState list (+0x9C)
    for (auto f : {0x141BB41E0ull, 0x141BB9AF4ull, 0x141BB7F44ull}) {
        readable(f - 4, 12);
        std::uint32_t d[3]{};
        std::memcpy(d, reinterpret_cast<void*>(f - 4), sizeof(d));
        if (d[0] != 0x9C) throw std::runtime_error("agent capacity: clientNum net field differs");
        add(f, 6, l.net_id_bits(), 4, false);
    }
    // server AI loops over characters by entity byte offset (cmp reg, 42 x 0x3F8): agents past entity 41 were skipped.
    // 0x1400A9865 is left: its collector fills a 6-int stack array in sub_140B69E20 with no bound (not done).
    for (auto f : {0x140C22AE3ull, 0x140C29144ull, 0x140C390F8ull, 0x140C3A939ull, 0x140C3CB5Cull, 0x140C3D17Bull, 0x140C481FEull})
        add(f, stock_characters * 0x3F8, l.characters * 0x3F8);
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
    // FUN_140415bf0+34 `mov [rdi+rbx*8+0x40],rax` (the rewind pointer array) is a disp8 that rewind_pointers() outgrows (0x80 from 84 agents, read as
    // negative): re-encoded with a 32-bit displacement in a cave, see rewind_cave_table in plan_caves().
    add(0x140445F0C, 42, l.characters);
    add(0x1400A8585, 42, l.characters);
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
    // CL_GetSnapshot copied min(numAgents, 24) agent states: zombies 25+ had entities but no model (invisible).
    for (auto a : {0x1408646D1ull, 0x1408646EAull, 0x140864726ull, 0x1408648BDull}) add(a, 2 * 0x3DC78, 2 * l.snap_size());
    for (auto a : {0x14086470Dull, 0x14086471Full, 0x1408648E9ull, 0x1408648FBull, 0x14086C728ull}) add(a, 0x3DC78, l.snap_size());
    for (auto a : {0x1408706ABull, 0x140873602ull, 0x1408738B3ull, 0x1409934BFull}) add(a, 0x38D48, 0x3DC78);
    add(0x1409934A4, stock_agents, l.agents);
    // SV snapshot buffers (sub_140C68A00): the two agent-state rings hold 24 states a snapshot frame
    // (count = frames x 24 as lea [r+r*2] / shl 3; the allocator sub_140C68B00 sizes them from that count x 0xC0).
    // With more agents a frame the rings wrap before the oldest frame a client may delta from: frames x agents.
    // The first (frames x agents, at 0x140C68A82) is in caves (wide_site 37: its lea and its shl are 11 bytes apart); the second is lea + shl
    // side by side, replaced in place by `imul eax, r11d, imm32` (7 bytes).
    block(0x140C68A96, std::array<std::uint8_t, 7>{0x43, 0x8d, 0x04, 0x5b, 0xc1, 0xe0, 0x03},
                       std::array<std::uint8_t, 7>{0x41, 0x69, 0xc3, static_cast<std::uint8_t>(l.agents), static_cast<std::uint8_t>(l.agents >> 8), 0, 0});
    // CL snapshot buffers (sub_14034F1D0, called from sub_1409B2620): the client's agent-state ring is frames x agents a
    // frame. A listen host passes the server's own max agents (byte +0x546, set from the patched selector); a client
    // joining a remote server passes 24 as `mov ebp, 18; lea r14d, [rbp + 6]`: the 6 becomes agents - 18.
    // CG_SetNextSnap: the character change mask (one bit a character) lives in the room its frame grow opens (frame_fields_d,
    // agent_capacity_caves_mask.inc): [rsp+0x170, +0x190), 8 words, enough for 256 characters. No one-byte stack offset is left here (a34).
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

// ---- 4b. replicated scriptable state: the 1,016 dword budget (a39) ------------------------------------------------------------
// ScriptableSv_LinkReservedScriptable (sub_140BF96A0) fills one block of 1,016 dwords (four one-byte part states each) with the state of the
// fixed parts from the bottom and of every reserved instance from the top; an instance of a zombie's scriptable takes 8 dwords, so 100 zombies
// and the stock instances end the match with "Too many replicated parts" (ERR_DROP), after which the shutdown walk reads the null state buffer of
// the half linked instance (sub_140BF5730+0xD2, guarded by a cave below). The block (0x17E8 bytes: u16 count, dwords, u16 instance count, two
// tables of 512 u16) moves to `state_a` with S dwords and its tables behind them; the byte list table (6 bytes an entry, sentinel 0xFE0, heads at
// +0x5F40) moves to `state_c`; the client's two static blocks and the empty block to `state_client` / `state_x`; every stride, size, copy loop
// count, top-of-budget constant, sentinel and field offset is a 4 byte field listed in agent_capacity_state.inc (generated by
// ops/engine/state_sites.py from the shipped code), the client snapshot's block member moves behind its appended agent states. Two fields of one
// instruction (disp32 and imm32) are two rows. Not patched: the save-game serializer sub_140C70A50 (a fixed slot of DAT_146B4DF48; it copies the
// stock size).
enum class state_op : std::uint8_t {
    shift, state_bytes, state_bytes_less6, budget, budget4, budget4x2, c_bytes, c_heads, copies, snap_member, hunk_fixed, ref_A, ref_C, ref_A1, ref_A2, ref_X
};
struct state_site { std::uintptr_t field; unsigned form; std::uint64_t stock; unsigned tail; state_op op; };
const state_site state_sites[] = {
#include "agent_capacity_state.inc"
};
constexpr std::uint64_t state_stock_a = 0x1460A8BE0ull, state_stock_c = 0x1460AC3A0ull, state_stock_a1 = 0x146030250ull,
                        state_stock_a2 = 0x146031A40ull, state_stock_x = 0x1421EDA70ull;
// The stock offset of a reference into a block -> the offset in the grown block: the tables behind the dwords (and the trailer of a client block)
// move by 4 bytes a dword added; in the list table the heads and the index byte (stock +0x5F40) move by 24 bytes a dword.
std::uint64_t state_block_offset(std::uint64_t stock, std::uint64_t extra) { return stock < 0xFE4 ? stock : stock + 4 * extra; }
std::size_t state_rows{};
void plan_state() {
    const auto& l = L;
    const std::uint64_t extra = l.state_extra();
    for (const auto& s : state_sites) {
        ++state_rows;
        const auto field = s.field;
        const auto stock = s.stock;
        const auto before = static_cast<std::uint32_t>(stock);
        switch (s.op) {
        case state_op::shift: add(field, before, before + static_cast<std::uint32_t>(4 * extra)); break;
        case state_op::state_bytes: add(field, before, l.state_bytes()); break;
        case state_op::state_bytes_less6: add(field, before, l.state_bytes() - 6); break;
        case state_op::budget: add(field, before, l.state_dwords()); break;
        case state_op::budget4: add(field, before, 4 * l.state_dwords()); break;
        case state_op::budget4x2: add(field, before, (4 * l.state_dwords() << 16) | (4 * l.state_dwords())); break;
        case state_op::c_bytes: add(field, before, l.state_list_bytes()); break;
        case state_op::c_heads: add(field, before, before + static_cast<std::uint32_t>(24 * extra)); break;
        case state_op::copies: add(field, before, l.state_copies()); break;
        case state_op::snap_member: add(field, before, l.snap_state_offset()); break;
        // the server hunk (FUN_140C68880) adds the fixed allocations of SV_AllocSnapshotBuffers as constants: 0x2CD300 and the single block
        // aligned to 0x80 (0x1800) folded to 0x2CEB00 (0x6CEB00 in the other mode); the single block is now state_bytes() long
        case state_op::hunk_fixed: add(field, before, before + l.state_hunk_growth()); break;
        case state_op::ref_A: case state_op::ref_C: case state_op::ref_A1: case state_op::ref_A2: case state_op::ref_X: {
            const std::uint64_t target = s.form == 1 ? stock : image_base + stock;
            std::uint64_t base{}, offset{};
            switch (s.op) {
            case state_op::ref_A: base = state_a.data; offset = state_block_offset(target - state_stock_a, extra); break;
            case state_op::ref_X: base = state_x.data; offset = state_block_offset(target - state_stock_x, extra); break;
            case state_op::ref_C: {
                base = state_c.data;
                const auto stock_offset = target - state_stock_c;
                offset = stock_offset < 0x5F40 ? stock_offset : stock_offset + 24 * extra;
                break;
            }
            default: {   // the two static client blocks, 0x17F0 apart in the shipped image: block, then an 8 byte trailer of four u16
                const bool first = s.op == state_op::ref_A1;
                base = state_client.data + (first ? 0 : l.state_bytes() + 8);
                const auto stock_offset = target - (first ? state_stock_a1 : state_stock_a2);
                offset = stock_offset < 0x17E8 ? state_block_offset(stock_offset, extra) : stock_offset - 0x17E8 + l.state_bytes();
                break;
            }
            }
            if (s.form == 1) rip(field, static_cast<std::uintptr_t>(target), static_cast<std::uintptr_t>(base + offset), s.tail);
            else rva(field, before, static_cast<std::uintptr_t>(base + offset));
            break;
        }
        }
    }
}

// ---- 4d. scriptable stream buffer pools (a43) ----------------------------------------------------------------------------------------
// Every reserved scriptable instance takes one stream buffer from five static pools (16, 64, 256, 512, 3072 byte blocks; 128, 128, 64, 32, 32
// blocks): ScriptableSv_LinkReservedScriptable at 0x140BF99CC calls FUN_140BE1770, and with 200 zombies a run died with "Could not allocate Stream Buffer of
// 148 bytes" (a42, run h2). Each pool is an array of blocks followed by an 8 byte free-list head (an empty list holds the head's address); the client
// has two slots of each class, stride array + 8. The pools move to `pool_server` / `pool_client` with stream_pool_blocks(n) blocks a class; the code
// that names an array base, a head, a stride or an array size (the allocator, free, the class lookups and the static initialisers: 132 fields,
// agent_capacity_pools.inc, generated by ops/engine/pool_sites.py) is edited in place. The static initialisers have already run (their code is
// edited too, but only for the meter and a re-run): the new arrays are chained by chain_pool. The in-use counters (0x146043318, 0x1460A8BB8) stay where they are.
enum class pool_op : std::uint8_t { ref_server_base, ref_server_head, ref_client_base, ref_client_head, pool_stride, pool_array };
struct pool_site { std::uintptr_t field; unsigned form; std::uint64_t stock; unsigned tail; pool_op op; unsigned cls; };
const pool_site pool_sites[] = {
#include "agent_capacity_pools.inc"
};
std::size_t pool_rows{};
// What the static initialiser of a class does to an array: block i points at block i + 1, the last at the head, the head at block 0
// (a list that holds its own head's address is empty). The initialisers have already run when post_unpack patches them (run a43-p1: the new
// heads were still null and the first allocation read address 0), so the new arrays are chained here.
void chain_pool(std::uintptr_t array, std::uint32_t blocks, std::uint32_t size) {
    const auto head = array + static_cast<std::uintptr_t>(blocks) * size;
    auto next = head;
    for (std::uint32_t i = blocks; i-- > 0;) {
        const auto block = array + static_cast<std::uintptr_t>(i) * size;
        *reinterpret_cast<std::uintptr_t*>(block) = next;
        next = block;
    }
    *reinterpret_cast<std::uintptr_t*>(head) = next;
}
void plan_pools() {
    const auto agents = L.agents;
    for (unsigned c = 0; c < stream_pool_classes; ++c) {
        pool_server[c] = reserve(stream_pool_array_bytes(agents, c) + 8);
        pool_client[c] = reserve(static_cast<std::size_t>(stream_pool_slots) * stream_pool_stride(agents, c));
        chain_pool(pool_server[c].data, stream_pool_blocks(agents), stream_pool_class_bytes[c]);
        for (unsigned slot = 0; slot < stream_pool_slots; ++slot)
            chain_pool(pool_client[c].data + static_cast<std::uintptr_t>(slot) * stream_pool_stride(agents, c), stream_pool_blocks(agents), stream_pool_class_bytes[c]);
    }
    for (const auto& s : pool_sites) {
        ++pool_rows;
        const auto before = static_cast<std::uint32_t>(s.stock);
        const auto array = stream_pool_array_bytes(agents, s.cls);
        switch (s.op) {
        case pool_op::ref_server_base: rip(s.field, static_cast<std::uintptr_t>(s.stock), pool_server[s.cls].data, s.tail); break;
        case pool_op::ref_server_head: rip(s.field, static_cast<std::uintptr_t>(s.stock), pool_server[s.cls].data + array, s.tail); break;
        case pool_op::ref_client_base: rip(s.field, static_cast<std::uintptr_t>(s.stock), pool_client[s.cls].data, s.tail); break;
        case pool_op::ref_client_head: rip(s.field, static_cast<std::uintptr_t>(s.stock), pool_client[s.cls].data + array, s.tail); break;
        case pool_op::pool_stride: add(s.field, before, stream_pool_stride(agents, s.cls)); break;
        case pool_op::pool_array: add(s.field, before, (before & 0x80000000u) ? 0u - array : array); break;   // `lea rcx,[rdx - array]` holds the negative
        }
    }
}

// ---- 3d. the two per-sentient tables of an SV agent record (map A1) ---------------------------------------------------
// Each SV agent record (0x3F08 bytes, one per agent) holds table 1 (64-byte rows at +0x10) and table 2 (60-byte rows at +0x23E4),
// 66 rows each, indexed by the sentient slot; with more than 24 agents a slot passes 65 and the stock code writes past the
// tables. The tables move to the END of a grown record (record_bytes(): table 1 at 0x3F08, table 2 after it, one row per
// sentient slot) and the old areas stay unused. A bot client's embedded record (inside client_t) has the same layout.
//  - record size: every stride and allocation size 0x3F08 (`imul r, r, 0x3F08`, `add r, 0x3F08`, the hunk size function);
//    the 0x3798 memset of SV_InitAgentRecord and the +0x3F00 flag stay;
//  - table 2: 77 instructions carry its start in a 32-bit displacement: edited in place; the pointer add at 140C487F9 adds only
//    the scaled slot (the accesses after it carry the displacement), so it stays;
//  - table 1: 49 instructions (8-bit displacements, `add` forms) move to code caves (agent_capacity_caves.inc, planned
//    offline from ops/engine/caves/a1-table1.*) and the accessor sub_140AE2D10 is rewritten in place (16 bytes);
//  - SV_InitAgentRecord: row count 66 -> slots, table 2 start in place, table 1 start = the 49th cave instruction; the new
//    area is zeroed by a hook (init_record_stub) because the 0x3798 memset no longer reaches the tables;
//  - sub_140C3BDD0 (player death of a bot client: saves both tables, resets the embedded record, restores them) is replaced.
void plan_tables() {
    const auto& l = L;
    // record size (24 immediates, all imm32 in place)
    for (auto a : {
        0x140C16C60ull, 0x140C16DAAull, 0x140C16DC6ull, 0x140C16DEAull, 0x140C182E4ull,
        0x140C1893Full, 0x140C18DEBull, 0x140C190DAull, 0x140C19167ull, 0x140C192B3ull,
        0x140C193B0ull, 0x140C19739ull, 0x140C1974Dull, 0x140C1983Bull, 0x140C199D1ull,
        0x140C19A41ull, 0x140C19BDCull, 0x140C1A1BFull, 0x140C1A232ull, 0x140C1A25Aull,
        0x140C1A2A0ull, 0x140C1A2FFull, 0x140C1A396ull, 0x140C1A3D7ull})
        add(a, 0x3F08, l.record_bytes());
    // table 2: displacement = old - 0x23E4 + new table 2 start
    const std::uint32_t shift = l.table2_offset() - 0x23E4;
    struct t2 { std::uintptr_t field; std::uint32_t before; };
    for (const auto& i : {
        t2{0x140C1F261,0x2400}, t2{0x140C1F4A0,0x2414}, t2{0x140C1F4AA,0x240C}, t2{0x140C1F4C6,0x240C},
        t2{0x140C1F4D2,0x2414}, t2{0x140C1F4EA,0x2414}, t2{0x140C1F4F1,0x2414}, t2{0x140C216D4,0x2408},
        t2{0x140C216DE,0x2408}, t2{0x140C21BB6,0x241C}, t2{0x140C23606,0x23E4}, t2{0x140C2363F,0x23E8},
        t2{0x140C2B796,0x2404}, t2{0x140C2C6A2,0x23F4}, t2{0x140C2C6CA,0x23F4}, t2{0x140C2C6D3,0x23FC},
        t2{0x140C2C6DD,0x23F8}, t2{0x140C2C7F4,0x2404}, t2{0x140C2C814,0x2404}, t2{0x140C2DAB1,0x241C},
        t2{0x140C2FFD8,0x2410}, t2{0x140C2FFE5,0x2410}, t2{0x140C30008,0x2410}, t2{0x140C348F9,0x23E4},
        t2{0x140C34920,0x23E8}, t2{0x140C34931,0x23EC}, t2{0x140C34C36,0x241C}, t2{0x140C34C7D,0x23E8},
        t2{0x140C34C84,0x23EC}, t2{0x140C39A2C,0x2410}, t2{0x140C39B77,0x241C}, t2{0x140C39B85,0x2418},
        t2{0x140C39BA1,0x2418}, t2{0x140C39BB4,0x241C}, t2{0x140C39BC6,0x241C}, t2{0x140C39BCD,0x241C},
        t2{0x140C39D4A,0x241C}, t2{0x140C39D54,0x2418}, t2{0x140C39D70,0x2418}, t2{0x140C39D83,0x241C},
        t2{0x140C39D95,0x241C}, t2{0x140C39D9C,0x241C}, t2{0x140C3A180,0x23E4}, t2{0x140C3A188,0x23EC},
        t2{0x140C3A190,0x23F4}, t2{0x140C3A198,0x23FC}, t2{0x140C3A1A0,0x2404}, t2{0x140C3A1A8,0x240C},
        t2{0x140C3A1B0,0x2414}, t2{0x140C3A1B8,0x241C}, t2{0x140C3B330,0x2400}, t2{0x140C3B462,0x23E8},
        t2{0x140C3B471,0x23E4}, t2{0x140C3B489,0x23EC}, t2{0x140C3B496,0x23E4}, t2{0x140C3E39A,0x2408},
        t2{0x140C3ED27,0x241C}, t2{0x140C3ED38,0x241C}, t2{0x140C3F9DA,0x23F0}, t2{0x140C3FA09,0x23F8},
        t2{0x140C3FA41,0x23FC}, t2{0x140C3FA51,0x23FC}, t2{0x140C3FA5A,0x23F8}, t2{0x140C3FA64,0x23F0},
        t2{0x140C4003B,0x23F8}, t2{0x140C40045,0x23F8}, t2{0x140C40053,0x23F0}, t2{0x140C487E3,0x23E4},
        t2{0x140C487FF,0x23E4}, t2{0x140C48808,0x23F4}, t2{0x140C4880F,0x23F4}, t2{0x140C48818,0x2404},
        t2{0x140C4881F,0x2404}, t2{0x140C48829,0x2414}, t2{0x140C48831,0x2414}, t2{0x140C48839,0x241C},
        t2{0x140C4883F,0x241C}})
        add(i.field, i.before, i.before + shift);
    // SV_InitAgentRecord (sub_140C2A080): table 2 start `lea rax, [rbx + 0x2408]`, row count `mov edx, 0x42`
    add(0x140C2A302, 0x2408, l.table2_offset() + 0x24);
    add(0x140C2A31F, 0x42, l.table_slots());
    // accessor sub_140AE2D10 (the entry of table 1 for a sentient slot): `mov rax,[rcx+8]; add rax,0x10; shl rdx,6; add rax,rdx; ret`
    // -> `shl rdx,6; add rdx,[rcx+8]; lea rax,[rdx+0x3F08]; ret` (the same 16 bytes)
    block(0x140AE2D32, std::array<std::uint8_t, 16>{0x48,0x8b,0x41,0x08,0x48,0x83,0xc0,0x10,0x48,0xc1,0xe2,0x06,0x48,0x03,0xc2,0xc3},
          std::array<std::uint8_t, 16>{0x48,0xc1,0xe2,0x06,0x48,0x03,0x51,0x08,0x48,0x8d,0x82,
              static_cast<std::uint8_t>(l.table1_offset()), static_cast<std::uint8_t>(l.table1_offset() >> 8), 0, 0, 0xc3});
}

// ---- 3g. the server's entity queue table ---------------------------------------------------------------------------------
// Static table at 0x144EB2B70: 42 rows x 0x208 bytes (16 slots x 0x20, ring head +0x200, count +0x204), one row per entity number
// (clients 0..17, agents from 18). FUN_1405ee9e0 (every server frame) walks rows 0..svs_numclients and then rows 18 .. 17 + the
// agent count: 100 agents read and write up to row 117, 76 rows past the table's end 0x144EB8090 (the next module's globals; the
// capacity client died there in its first server frame, 14 Nov). The whole table moves to `characters` zeroed rows. The code is
// FUN_1405ee500 (clear a row), ee530 (clear all: memset 0x5550), ee550, ee590, ee6e0 (enqueue), ee880, ee960, ee9e0; every
// access is [row * 0x208 + base + field] with the base loaded by one of the 10 encoded references below (docs: a16 note).
void plan_entity_queue() {
    for (auto f : {0x1405EE50Full, 0x1405EE535ull, 0x1405EE556ull, 0x1405EE5B2ull, 0x1405EE6FFull, 0x1405EE968ull, 0x1405EE9F4ull})
        rip(f, 0x144EB2B70, entity_queue.data);
    rip(0x1405EEA03, 0x144EB2D70, entity_queue.data + 0x200);                 // loop 1: head of row 0
    rip(0x1405EEA8A, 0x144EB5200, entity_queue.data + 18 * 0x208 + 0x200);    // loop 2: head of row 18 (the first agent)
    rva(0x1405EE8B5, 0x4EB2D74, entity_queue.data + 0x204);                   // ee880: count of row 0, image-base relative
    add(0x1405EE53B, 0x5550, L.queue_bytes());                                // ee530: memset length 42 x 0x208
    queue_references = 10;
}

// ---- 3e. hooks for the grown record: zero the new table area, and the bot client's death reset ------------------------
utils::hook::detour init_record_hook, death_reset_hook;

// SV_InitAgentRecord (sub_140C2A080, rcx = record, rdx = entity): the stock function clears record[0, 0x3798) (both old
// tables) and then writes the first field of every table row. The new tables lie past that memset: clear them first. The
// stock function has no return before its memset (the only branches before it skip the teardown of an old record), so
// every path that later uses a table sees zeroed rows, exactly as in the stock layout.
std::uintptr_t init_record_stub(std::uint8_t* record, void* entity) {
    std::memset(record + L.table1_offset(), 0, L.record_bytes() - L.table1_offset());
    return init_record_hook.invoke<std::uintptr_t>(record, entity);
}

// sub_140C3BDD0 (player-death handler of a bot client, rcx = client_t): the agent record is embedded in client_t at +0x4C4.
// It saves table 2 and table 1 to a 0x2020-byte stack frame, resets the record (FUN_140C28510, SV_InitAgentRecord,
// FUN_140C29FC0, FUN_140AF09D0) and restores both tables. The frame cannot hold the grown tables: this replacement keeps the
// same calls in the same order, with the saved blocks on the heap. Original (Ghidra decompile, address 0x140C3BDD0):
//
//   void FUN_140c3bdd0(longlong param_1) {
//     puVar16 = (undefined8 *)(param_1 + 0x4c4);                                      // [1] record
//     FUN_140ac61b0(*(undefined8 *)(*(longlong *)(param_1 + 0x88) + 0x180),7);       // [2] first call
//     <do { 16 qwords per pass } while (--30)  copy 0xF00 bytes from param_1+0x28a8 (= record+0x23E4, table 2) to local_2008>
//     <tail: 0x78 bytes more>                                                         // [3] save table 2 (0xF78 bytes)
//     <do { 16 qwords per pass } while (--33)  copy 0x1080 bytes from param_1+0x4d4 (= record+0x10, table 1) to local_1088>
//                                                                                    // [4] save table 1 (0x1080 bytes)
//     FUN_140c28510(puVar16);                                                         // [5]
//     FUN_140c2a080(puVar16,*puVar16);                                                // [6] SV_InitAgentRecord(record, record[0])
//     FUN_140c29fc0(puVar16);                                                         // [7]
//     if ((*(longlong *)(param_1 + 0x4cc) != 0) &&
//        (*(longlong *)(*(longlong *)(param_1 + 0x4cc) + 0x70) != 0)) {              // [8] record[1] and record[1]->+0x70
//       FUN_140af09d0();                                                              //     (rcx = record[1] is live: sentient)
//     }
//     <restore table 2 (30 passes + 0x78 tail), then table 1 (33 passes)>             // [9]
//   }
//
// Here: [1] record, [2] the same call, [3] and [4] one copy each of E rows (E x 0x3C and E x 0x40 bytes at their new places)
// into one heap block, [5] to [8] the same calls with the same arguments (the disassembly passes record[1] to FUN_140AF09D0 in
// rcx, which the decompile omits; it tail-jumps to FUN_140AF0900(rcx, 0)), [9] the two copies back.
void death_reset_stub(std::uint8_t* client) {
    auto* record = client + 0x4C4;
    const auto fn_sentient_flag = reinterpret_cast<void (*)(void*, int)>(0x140AC61B0);
    const auto fn_clear = reinterpret_cast<void (*)(void*)>(0x140C28510);
    const auto fn_init = reinterpret_cast<std::uintptr_t (*)(void*, void*)>(0x140C2A080);
    const auto fn_finish = reinterpret_cast<void (*)(void*)>(0x140C29FC0);
    const auto fn_notify = reinterpret_cast<void (*)(void*)>(0x140AF09D0);
    const auto entity = *reinterpret_cast<std::uint8_t**>(client + 0x88);
    fn_sentient_flag(*reinterpret_cast<void**>(entity + 0x180), 7);                       // [2]
    const std::size_t bytes2 = static_cast<std::size_t>(L.table_slots()) * 0x3C, bytes1 = static_cast<std::size_t>(L.table_slots()) * 0x40;
    std::vector<std::uint8_t> saved(bytes2 + bytes1);
    std::memcpy(saved.data(), record + L.table2_offset(), bytes2);                        // [3]
    std::memcpy(saved.data() + bytes2, record + L.table1_offset(), bytes1);               // [4]
    fn_clear(record);                                                                     // [5]
    fn_init(record, *reinterpret_cast<void**>(record));                                   // [6]
    fn_finish(record);                                                                    // [7]
    const auto sentient = *reinterpret_cast<std::uint8_t**>(record + 8);                  // [8]
    if (sentient && *reinterpret_cast<std::uintptr_t*>(sentient + 0x70)) fn_notify(sentient);
    std::memcpy(record + L.table2_offset(), saved.data(), bytes2);                        // [9]
    std::memcpy(record + L.table1_offset(), saved.data() + bytes2, bytes1);
}

// ---- 3f. fast-fail exits leave a dump (lab builds only) --------------------------------------------------------------------
// Exit code 0xC0000409 is `int 0x29` (CD 29): the compiler's stack-cookie failure (__report_gsfailure, reached by jmp from
// __security_check_cookie) and the CRT's abort / watson paths. A fast-fail bypasses the exception handler, so no minidump
// (run h5, 14 Nov 2026). In a lab build (-paris-debugger and -paris-isolated-lab) each of the CRT's five `int 0x29` becomes
// `ud2` (0F 0B), same length: an illegal instruction goes through the normal crash handler with the stack intact, and the frame
// above __report_gsfailure is the function whose cookie check failed. Found by a raw scan for CD 29 in the unpacked code and
// the instruction index (`engine.py imm 0x29 --mnemonic int`): all are preceded by `mov ecx, N`. Not patched: 140BABD61 and
// 1412505D9 (random data bytes, not instructions) and 26 hits in the protector span 0x14B.. / 0x14C.. (obfuscated bytes, the
// instruction boundary is not known).
//   1412BA464 __report_gsfailure   1412BA54C __report_securityfailure   1412BB073 __scrt_fastfail
//   1412D7624 abort                1412E291F _invoke_watson
std::size_t fastfail_sites{};
void plan_fastfail() {
    if (!utils::flags::has_flag("paris-debugger") || !utils::flags::has_flag("paris-isolated-lab")) return;
    for (auto a : {0x1412BA464ull, 0x1412BA54Cull, 0x1412BB073ull, 0x1412D7624ull, 0x1412E291Full}) { add(a, 0x29CD, 0x0B0F, 2); ++fastfail_sites; }
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
// The lag-compensation rewind store of FUN_140415bf0 (`mov [rdi+rbx*8+0x40],rax`, 48 89 44 df 40) in a cave with a 32-bit displacement
// (ops/engine/caves/rewind-pointer.*): the plan holds a placeholder at cave bytes 4..7, plan_caves() writes layout::rewind_pointers()
// there. The cave is installed at every agent count (24 gives the stock 0x40), like the other caves.
const std::vector<cave_spec> rewind_cave_table = {
#include "agent_capacity_caves_rewind.inc"
};
// The one-byte fields that held a character, corpse or agent count (a29 section 2.1, 34 instructions: `cmp`/`sub r32, imm8`, `lea r32, [r+disp8]`,
// the frames x agents `imul`), as 32-bit fields in caves (ops/engine/caves/wide-sites.*, planned by cave_plan.py from wide-sites.requests.json). The
// plan holds a placeholder 0x5A5A0000 | row in each field; plan_caves() writes layout::wide_value(what) there (exactly one placeholder a row, or it throws).
// Installed at every agent count, like the other caves; at 24..100 each cave computes what the shipped instruction computed.
const std::vector<cave_spec> wide_cave_table = {
#include "agent_capacity_caves_wide.inc"
};
// CG_SetNextSnap's character change mask at [rsp+0x170..0x190) (ops/engine/caves/setnextsnap-mask.*): five instructions of the shipped
// function used [rsp+0x40] (2 words) and are cave instructions with a 32-bit displacement and the mask cleared in all 8 words. Constant bytes,
// installed at every agent count (the frame grow of 0x14086FBA0 below makes the room at every count).
const std::vector<cave_spec> mask_cave_table = {
#include "agent_capacity_caves_mask.inc"
};
// The shutdown walk of sub_140BF5730 (+0xD2, `cmp byte [rdx+rcx],bpl`) reads the state byte buffer of every scriptable instance; the instance whose
// replicated-parts check raised ERR_DROP has none (null): a cave treats a null buffer as state 0 (ops/engine/caves/shutdown-guard.*). Constant bytes.
const std::vector<cave_spec> guard_cave_table = {
#include "agent_capacity_caves_guard.inc"
};
// The snapshot interpolation limit of FUN_1407AE190 (0x1407AE222, `cmp dword [rbp+0x700], 0x2A`): in a cave, the limit is the character count for
// agents (eType 18) and stays 42 for every other entity (ops/engine/caves/interp-agents.*). The plan holds the placeholder 0x5A5AC0DE as the
// imm32 of the one `cmp ecx, imm32` in it; plan_caves() writes layout::characters there and throws unless there is exactly one.
const std::vector<cave_spec> interp_cave_table = {
#include "agent_capacity_caves_interp.inc"
};
constexpr std::uint32_t interp_placeholder = 0x5A5AC0DE;
struct wide_site { std::uint32_t row; wide_field what; };
constexpr wide_site wide_sites[] = {
    {1, wide_field::player_corpses}, {2, wide_field::agent_corpses}, {3, wide_field::player_corpses}, {4, wide_field::player_corpses},
    {5, wide_field::player_corpses}, {6, wide_field::player_corpses}, {7, wide_field::player_corpses}, {8, wide_field::player_corpses},
    {9, wide_field::agent_corpses}, {10, wide_field::agent_corpses}, {11, wide_field::agent_corpses}, {12, wide_field::agent_corpses},
    {13, wide_field::agent_corpses}, {14, wide_field::minus_agent_corpses},
    {15, wide_field::characters}, {16, wide_field::characters}, {17, wide_field::characters}, {20, wide_field::characters},
    {21, wide_field::characters}, {22, wide_field::characters}, {23, wide_field::characters}, {24, wide_field::characters},
    {25, wide_field::characters}, {26, wide_field::characters}, {27, wide_field::characters}, {28, wide_field::characters},
    {29, wide_field::characters}, {30, wide_field::characters},
    {31, wide_field::characters_less_one}, {32, wide_field::characters_less_one},
    {33, wide_field::agents}, {34, wide_field::agents}, {35, wide_field::agents_less_players}, {37, wide_field::agents},
};
constexpr std::uint32_t wide_placeholder_base = 0x5A5A0000;
buffer code_region;
std::size_t code_used{};
std::size_t caves_planned{}, wide_caves{};

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

// ---- 5b. frame grow of FUN_1403E61B0 (ops/engine/cave_plan.py frame-grow, docs/CAVE-REWRITER.md) -------------------------------
// The function's 71-entry stack array sits directly under its stack cookie and two loops fill it without a bound. The frame grows
// at the array's top by X = layout::frame_extra() bytes: the planner's field table gives every instruction field and every unwind
// field that must move (stock value, unit in bytes, sign: new = stock + sign * X / unit), all written in the same transaction
// as every other patch. The `sub rsp` goes through a cave that first reads one byte in every 0x1000 step below the stack pointer
// (the new frame is larger than a page), planned for the largest X; only its immediate is set here.
struct frame_field { std::uintptr_t address; unsigned width; std::uint32_t stock; unsigned unit; int sign; bool code; };
struct frame_cave_spec {
    std::uintptr_t window_start;
    std::vector<std::uint8_t> old_bytes, cave_bytes;
    std::uint32_t imm_offset, stock_frame, max_extra, probes;
};
// Three functions, three tables each (fields, and the page-probe cave when the grown frame reaches a page). FUN_1403E61B0 (a): two
// loops, X = layout::frame_extra(); FUN_140ADB8E0 (b) and FUN_140ADDED0 (c): one loop each, X = (slots - 71) x entry size.
const std::vector<frame_field> frame_fields_a = {
#include "agent_capacity_frame_fields.inc"
};
const std::vector<frame_cave_spec> frame_caves_a = {
#include "agent_capacity_frame_cave.inc"
};
const std::vector<frame_field> frame_fields_b = {
#include "agent_capacity_frame_fields_adb8e0.inc"
};
const std::vector<frame_cave_spec> frame_caves_b = {
#include "agent_capacity_frame_cave_adb8e0.inc"
};
const std::vector<frame_field> frame_fields_c = {
#include "agent_capacity_frame_fields_added0.inc"
};
const std::vector<frame_cave_spec> frame_caves_c = {
#include "agent_capacity_frame_cave_added0.inc"
};
// CG_SetNextSnap (d): the frame grows by snap_mask_room (32) bytes at the top of its locals, below the stack cookie, for the 8-word change
// mask; a constant, so no probe cave (0x180 + 32 is far from a page). Its field table: agent_capacity_frame_fields_86fba0.inc.
const std::vector<frame_field> frame_fields_d = {
#include "agent_capacity_frame_fields_86fba0.inc"
};
const std::vector<frame_cave_spec> frame_caves_d = {};
struct frame_set {
    const char* name;
    const std::vector<frame_field>& fields;
    const std::vector<frame_cave_spec>& caves;
    std::uint32_t extra;
    std::size_t planned_fields{}, planned_caves{};
};
std::vector<frame_set> frame_sets;

void plan_frame_set(frame_set& set) {
    if (!set.extra) return;   // no change at 24 agents for the one-loop functions
    for (const auto& f : set.fields) {
        if (!f.unit || set.extra % f.unit) throw std::runtime_error("agent capacity: frame grow X does not fit the unit of a field");
        const auto wide = static_cast<std::int64_t>(f.stock) + static_cast<std::int64_t>(f.sign) * static_cast<std::int64_t>(set.extra / f.unit);
        const std::int64_t mask = f.width >= 4 ? 0xFFFFFFFFll : ((1ll << (8 * f.width)) - 1);
        if (f.width < 4 && (wide < 0 || wide > mask)) throw std::runtime_error("agent capacity: frame grow value does not fit its field");
        add(f.address, f.stock, static_cast<std::uint32_t>(wide & mask), f.width, f.code);
        ++set.planned_fields;
    }
    for (const auto& c : set.caves) {
        if (set.extra > c.max_extra) throw std::runtime_error("agent capacity: frame grow X is above the largest X its probe cave was planned for");
        auto bytes = c.cave_bytes;
        const std::uint32_t frame = c.stock_frame + set.extra;
        if (c.imm_offset + 4 > bytes.size()) throw std::runtime_error("agent capacity: bad frame cave");
        std::memcpy(bytes.data() + c.imm_offset, &frame, 4);
        cave(c.window_start, c.old_bytes, bytes, {}, {});
        ++set.planned_caves;
    }
}

void plan_frames() {
    frame_sets.clear();
    frame_sets.push_back({"1403E61B0", frame_fields_a, frame_caves_a, L.frame_extra()});
    frame_sets.push_back({"140ADB8E0", frame_fields_b, frame_caves_b, L.frame_extra_b()});
    frame_sets.push_back({"140ADDED0", frame_fields_c, frame_caves_c, L.frame_extra_c()});
    frame_sets.push_back({"14086FBA0", frame_fields_d, frame_caves_d, snap_mask_room});
    for (auto& set : frame_sets) plan_frame_set(set);
}

// ---- 5c. lab-only unwind probe of the grown frame ---------------------------------------------------------------------------------
// The frame-grow change rewrites the function's unwind data, which nothing else exercises. `-agent-capacity-unwind-probe [n]`
// (or IW7_AGENT_CAPACITY_UNWIND_PROBE=n; default 60) arms the probe: the first call, n seconds after it (or the time set by the
// command `agent_capacity_unwind_probe <s>`: now + s seconds), of FUN_1403E5700 or FUN_1403E6B10 raises a script-level error,
// Com_Error(ERR_DROP), from INSIDE that call. Both have one caller, FUN_1403E61B0, so the engine's longjmp unwinds through the
// grown frame: the unwinder reads its UNWIND_INFO (sizes, saved registers) and calls its GS handler (cookie check at the new offset).
// A wrong field ends in a crash or a fast-fail; a right one in the normal error path. FUN_1403E5700 runs only for collected entries;
// FUN_1403E6B10 runs whenever FUN_1403E61B0 gets past its collection loops, so the probe has two chances. Every first call and the
// call counts are logged (the command prints them). Inert unless given.
utils::hook::detour unwind_probe_hook_a, unwind_probe_hook_b;
std::atomic<unsigned long long> unwind_probe_due{};
std::atomic_bool unwind_probe_done{};
std::atomic<unsigned> unwind_probe_calls[2]{};
unsigned unwind_probe_seconds{};
bool unwind_probe_gate(unsigned k, const char* name) {
    if (++unwind_probe_calls[k] == 1) console::info("[agent capacity] unwind probe: first call of %s\n", name);
    if (unwind_probe_done) return false;
    const auto now = GetTickCount64();
    unsigned long long unset = 0;
    unwind_probe_due.compare_exchange_strong(unset, now + unwind_probe_seconds * 1000ull);
    if (now >= unwind_probe_due && !unwind_probe_done.exchange(true)) {
        console::info("[agent capacity] unwind probe: raising ERR_DROP inside %s (called from FUN_1403E61B0)\n", name);
        game::Com_Error(game::ERR_DROP, "agent capacity unwind probe");
        return true;
    }
    return false;
}
void unwind_probe_stub_a(void* a, std::intptr_t b, float* c, float* d) {
    if (unwind_probe_gate(0, "FUN_1403E5700")) return;
    unwind_probe_hook_a.invoke<void>(a, b, c, d);
}
char unwind_probe_stub_b(void* a, std::intptr_t b, void* c, void* d) {
    if (unwind_probe_gate(1, "FUN_1403E6B10")) return 0;
    return unwind_probe_hook_b.invoke<char>(a, b, c, d);
}
void plan_unwind_probe() {
    auto seconds = parse_count(L"-agent-capacity-unwind-probe", 60);
    wchar_t from_env[16]{};
    if (!seconds && GetEnvironmentVariableW(L"IW7_AGENT_CAPACITY_UNWIND_PROBE", from_env, 16) && from_env[0])
        seconds = static_cast<std::uint32_t>(std::wcstoul(from_env, nullptr, 10));
    if (!seconds) return;
    unwind_probe_seconds = seconds;
    unwind_probe_hook_a.create(0x1403E5700, unwind_probe_stub_a);   // queued: main applies every queued hook after post_unpack
    unwind_probe_hook_b.create(0x1403E6B10, unwind_probe_stub_b);
    // the lab plan times the error itself: `agent_capacity_unwind_probe <s>` (a plan `cmd` step) sets the due time to now + s seconds, whatever
    // the first call set; the error is raised by the first call of either function after that (once)
    command::add("agent_capacity_unwind_probe", [](const command::params& params) {
        const auto s = params.size() > 1 ? std::strtoul(params.get(1), nullptr, 10) : 0ul;
        unwind_probe_due = GetTickCount64() + s * 1000ull;
        console::info("[agent capacity] unwind probe due in %lu s; calls so far: FUN_1403E5700 %u, FUN_1403E6B10 %u\n", s,
            unwind_probe_calls[0].load(), unwind_probe_calls[1].load());
    });
    console::info("[agent capacity] unwind probe armed: %u s after the first call of FUN_1403E5700 or FUN_1403E6B10\n", seconds);
}

// ---- 5d. lab-only probe of the rewind store (FUN_140415bf0+34) ----------------------------------------------------------------
// `-agent-capacity-rewind-probe` (or IW7_AGENT_CAPACITY_REWIND_PROBE=1) hooks FUN_140415bf0 (called by FUN_140415120 for each rewound
// character; reached only through the lag-compensated animation of a hit trace) and counts its calls. On the first call it logs the
// base pointer it was given (rdi), the character (rbx), the address the patched store writes (base + rewind_pointers + rbx * 8, the cave's
// 32-bit displacement), the array the layout says that is (archive object at [0x143C98468] + rewind_base + rewind_pointers), and the
// quadword at that address and at the stock address (base + 0x40 + rbx * 8) before and after the call. The count is logged on the first
// call, every power of ten, and every 20 s while it changes. Inert unless given; never part of a release path.
utils::hook::detour rewind_probe_hook;
std::atomic<unsigned long long> rewind_probe_calls{}, rewind_probe_reported{};
void rewind_probe_log_count() {
    const auto calls = rewind_probe_calls.load();
    if (calls == rewind_probe_reported.exchange(calls)) return;
    console::info("[agent capacity] rewind probe: FUN_140415bf0 called %llu times\n", calls);
}
void rewind_probe_stub(void* a, std::int32_t* index, std::uint8_t* base, void* d) {
    const auto call = ++rewind_probe_calls;
    const auto first = call == 1;
    const auto slot = static_cast<std::intptr_t>(*index);
    const auto target = reinterpret_cast<std::uintptr_t>(base) + L.rewind_pointers() + static_cast<std::uintptr_t>(slot) * 8;
    const auto stock = reinterpret_cast<std::uintptr_t>(base) + 0x40 + static_cast<std::uintptr_t>(slot) * 8;
    unsigned long long target_before{}, stock_before{};
    if (first) {
        target_before = *reinterpret_cast<const unsigned long long*>(target);
        stock_before = *reinterpret_cast<const unsigned long long*>(stock);
    }
    rewind_probe_hook.invoke<void>(a, index, base, d);
    if (first) {
        const auto archive = *reinterpret_cast<const std::uintptr_t*>(0x143C98468ull);
        const auto array = archive + L.rewind_base() + L.rewind_pointers();
        console::info("[agent capacity] rewind probe: first call, base (rdi) %llX, character (rbx) %lld, store address %llX = base + %X + 8 x character; "
                      "layout array %llX (archive %llX + rewind_base %X + rewind_pointers %X), inside it: %s, base matches rewind_base: %s\n",
            static_cast<unsigned long long>(reinterpret_cast<std::uintptr_t>(base)), static_cast<long long>(slot),
            static_cast<unsigned long long>(target), L.rewind_pointers(), static_cast<unsigned long long>(array),
            static_cast<unsigned long long>(archive), L.rewind_base(), L.rewind_pointers(),
            (target >= array && target < array + L.characters * 8ull) ? "yes" : "NO",
            reinterpret_cast<std::uintptr_t>(base) == archive + L.rewind_base() ? "yes" : "NO");
        console::info("[agent capacity] rewind probe: quadword at the store address %llX before, %llX after; at the stock address %llX (base + 0x40 + 8 x character) %llX before, %llX after\n",
            target_before, *reinterpret_cast<const unsigned long long*>(target), static_cast<unsigned long long>(stock), stock_before,
            *reinterpret_cast<const unsigned long long*>(stock));
    }
    if (call == 10 || call == 100 || call == 1000 || call == 10000 || call == 100000) rewind_probe_log_count();
}
void plan_rewind_probe() {
    auto on = parse_count(L"-agent-capacity-rewind-probe", 1);
    wchar_t from_env[16]{};
    if (!on && GetEnvironmentVariableW(L"IW7_AGENT_CAPACITY_REWIND_PROBE", from_env, 16) && from_env[0])
        on = static_cast<std::uint32_t>(std::wcstoul(from_env, nullptr, 10));
    if (!on) return;
    rewind_probe_hook.create(0x140415BF0, rewind_probe_stub);   // queued: main applies every queued hook after post_unpack
    command::add("agent_capacity_rewind_probe", [](const command::params&) {
        console::info("[agent capacity] rewind probe: FUN_140415bf0 called %llu times\n", rewind_probe_calls.load());
    });
    scheduler::loop(rewind_probe_log_count, scheduler::main, 20s);
    console::info("[agent capacity] rewind probe armed (FUN_140415bf0)\n");
}

void plan_caves() {
    std::size_t total = 0;
    for (const auto& c : cave_table) total += (c.cave_bytes.size() + 5 + 15) & ~std::size_t(15);
    for (const auto& c : rewind_cave_table) total += (c.cave_bytes.size() + 5 + 15) & ~std::size_t(15);
    for (const auto& c : wide_cave_table) total += (c.cave_bytes.size() + 5 + 15) & ~std::size_t(15);
    for (const auto& c : mask_cave_table) total += (c.cave_bytes.size() + 5 + 15) & ~std::size_t(15);
    for (const auto& c : guard_cave_table) total += (c.cave_bytes.size() + 5 + 15) & ~std::size_t(15);
    for (const auto& c : interp_cave_table) total += (c.cave_bytes.size() + 5 + 15) & ~std::size_t(15);
    for (const auto* caves : {&frame_caves_a, &frame_caves_b, &frame_caves_c, &frame_caves_d})
        for (const auto& c : *caves) total += (c.cave_bytes.size() + 5 + 15) & ~std::size_t(15);
    if (!total) return;
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
    for (const auto& c : rewind_cave_table) {
        auto bytes = c.cave_bytes;
        if (bytes.size() != 8 || bytes[0] != 0x48 || bytes[1] != 0x89 || bytes[2] != 0x84 || bytes[3] != 0xDF)
            throw std::runtime_error("agent capacity: the rewind store cave is not mov [rdi+rbx*8+disp32],rax");
        const std::uint32_t disp = L.rewind_pointers();
        std::memcpy(bytes.data() + 4, &disp, 4);
        cave(c.window_start, c.old_bytes, bytes, c.fixups, c.retargets);
    }
    for (const auto& c : mask_cave_table) cave(c.window_start, c.old_bytes, c.cave_bytes, c.fixups, c.retargets);
    for (const auto& c : guard_cave_table) cave(c.window_start, c.old_bytes, c.cave_bytes, c.fixups, c.retargets);
    for (const auto& c : interp_cave_table) {
        auto bytes = c.cave_bytes;
        unsigned hits = 0;
        for (std::size_t at = 0; at + 4 <= bytes.size(); ++at) {
            std::uint32_t here{};
            std::memcpy(&here, bytes.data() + at, 4);
            if (here != interp_placeholder) continue;
            const std::uint32_t value = L.characters;
            std::memcpy(bytes.data() + at, &value, 4);
            ++hits;
        }
        if (hits != 1) throw std::runtime_error("agent capacity: the interpolation cave has no placeholder (or more than one)");
        cave(c.window_start, c.old_bytes, bytes, c.fixups, c.retargets);
    }
    unsigned found[std::size(wide_sites)]{};
    for (const auto& c : wide_cave_table) {
        auto bytes = c.cave_bytes;
        for (std::size_t wi = 0; wi < std::size(wide_sites); ++wi) {
            const std::uint32_t magic = wide_placeholder_base | wide_sites[wi].row;
            for (std::size_t at = 0; at + 4 <= bytes.size(); ++at) {
                std::uint32_t here{};
                std::memcpy(&here, bytes.data() + at, 4);
                if (here != magic) continue;
                const auto value = static_cast<std::int32_t>(L.wide_value(wide_sites[wi].what));
                std::memcpy(bytes.data() + at, &value, 4);
                ++found[wi];
            }
        }
        cave(c.window_start, c.old_bytes, bytes, c.fixups, c.retargets);
    }
    for (std::size_t wi = 0; wi < std::size(wide_sites); ++wi)
        if (found[wi] != 1) throw std::runtime_error("agent capacity: a wide site has no placeholder in its cave (or more than one)");
    wide_caves = wide_cave_table.size();
    if (fault) console::info("[agent capacity] cave fault switch: mask %X (ud2 instead of the instruction)\n", fault);
    plan_frames();
}

void check_guards() {
    std::vector<buffer> checked{agent_pool, sentient_pool, table8, table20, parts_pool, entity_queue, state_a, state_c, state_client, state_x, ai_pools[0].storage, ai_pools[1].storage};
    checked.insert(checked.end(), std::begin(pool_server), std::end(pool_server));
    checked.insert(checked.end(), std::begin(pool_client), std::end(pool_client));
    for (const auto& pool : checked)
        for (unsigned i = 0; i < 16; ++i)
            if (*reinterpret_cast<const unsigned char*>(pool.data - 16 + i) != 0xA7 ||
                *reinterpret_cast<const unsigned char*>(pool.data + pool.bytes + i) != 0xA7) {
                game::Com_Error(game::ERR_FATAL, "agent capacity: a relocated table was written out of bounds");
                return;
            }
}

// ---- 4c. reserved scriptable records (a41, a42) -------------------------------------------------------------------------------
// The map's MapEnts asset (type 0x1b, the pool header S that the clipmap's mapEnts pointer 0x145D5F9D8 points to) holds the scriptable block at
// S + 0x240: +0 total records (cp_zmb 523), +4 reserved records [0, 200), +8 end of the server records (414), +0x10 the record array (0x1D0
// bytes a record, zone memory). The engine never writes these; every one of the ~130 users reads them through the global fresh. The values
// are data of the compiled zone, so the block is rebuilt right after the zone's link step FUN_1403B8610 (called with a pointer to the
// MapEnts pointer, by FUN_140A35E50 for the asset itself and by FUN_1409FAF00 for the clipmap's field): `added` copies of reserved record 0
// are inserted after the reserved ones, and the three counts and the array pointer change. Client and server both run this (same zone).
// Guards, logged once at the first load: (a) the stock reserved records are byte-identical (so a copy of record 0 is the zone's own blank
// record), (b) the callers of the link step, (c) the width of the entity-state field +0x78 (record index + 1 of a fixed scriptable,
// FUN_140BF85C0; entity type 6) read from the net field list at run time: the new total must fit it. Docs: AGENT-CAPACITY-ENGINE.md.
utils::hook::detour link_mapents_hook;
std::uint8_t* record_block{};
const void* record_block_owner{};
unsigned link_calls{};

// Width in bits of the descriptor with offset 0x78 in the entity-state field list of entity type 6 (list table 0x141BB3B20, 16 bytes a list:
// pointer, 62 descriptors of {offset, bits, flag}); 0 when not found.
unsigned entity_index_bits() {
    const auto list = *reinterpret_cast<const std::uintptr_t*>(0x141BB3B20ull + 16 * 6);
    if (list < image_base || list + 62 * 12 > image_end) return 0;
    const auto* d = reinterpret_cast<const std::int32_t*>(list);
    for (unsigned i = 0; i < 62; ++i)
        if (d[3 * i] == 0x78) return d[3 * i + 1] > 0 ? static_cast<unsigned>(d[3 * i + 1]) : 0;
    return 0;
}

std::uintptr_t link_mapents_stub(void** pointer) {
    const auto caller = reinterpret_cast<std::uintptr_t>(_ReturnAddress());
    const auto result = link_mapents_hook.invoke<std::uintptr_t>(pointer);
    const auto first = link_calls++ < 4;
    if (first) console::info("[agent capacity] map ents link: call %u from %p, map ents %p\n", link_calls, reinterpret_cast<void*>(caller),
        pointer ? *pointer : nullptr);
    if (!pointer || !*pointer || !active) return result;
    auto* s = reinterpret_cast<std::uint8_t*>(*pointer);
    auto& total = *reinterpret_cast<std::uint32_t*>(s + 0x240);
    auto& reserved = *reinterpret_cast<std::uint32_t*>(s + 0x244);
    auto& server_end = *reinterpret_cast<std::uint32_t*>(s + 0x248);
    auto& array = *reinterpret_cast<std::uint8_t**>(s + 0x250);
    if (record_block && array != record_block) { _aligned_free(record_block); record_block = nullptr; record_block_owner = nullptr; }
    if (array == record_block) return result;   // already moved (the clipmap's call after the asset's, or a reload of the same S)
    const auto want = reserved_records(L.agents);
    if (!reserved || reserved > total || server_end < reserved || server_end > total || !array) {
        console::info("[agent capacity] map ents: unexpected scriptable block (total %u reserved %u server end %u array %p): not touched\n", total, reserved,
            server_end, array);
        return result;
    }
    static bool logged{};
    {
        unsigned differing = 0;
        std::string offsets;
        for (unsigned i = 1; i < reserved; ++i) {
            if (!std::memcmp(array, array + i * record_bytes, record_bytes)) continue;
            ++differing;
            for (unsigned b = 0; b < record_bytes && offsets.size() < 120; ++b)
                if (array[b] != array[i * record_bytes + b]) offsets += " " + std::to_string(i) + ":" + std::to_string(b);
        }
        if (!logged) console::info("[agent capacity] map ents guard a: %u of %u reserved records differ from record 0%s\n", differing, reserved, offsets.c_str());
        const auto bits = entity_index_bits();
        const auto top = static_cast<std::uint64_t>(total) + (want > reserved ? want - reserved : 0);
        if (!logged) console::info("[agent capacity] map ents guard c: entity field 0x78 is %u bits, largest index+1 %llu (limit %llu)\n", bits,
            static_cast<unsigned long long>(top), bits ? (1ull << bits) - 1 : 0ull);
        if (!logged) console::info("[agent capacity] map ents: total %u reserved %u server end %u, wanted reserved %u\n", total, reserved, server_end, want);
        logged = true;
        if (differing) { game::Com_Error(game::ERR_FATAL, "agent capacity: stock reserved scriptable records differ (guard a)"); return result; }
        if (want > reserved && (!bits || top > (1ull << bits) - 1)) {
            game::Com_Error(game::ERR_FATAL, "agent capacity: the moved scriptable records do not fit the entity field 0x78 (guard c)");
            return result;
        }
    }
    if (std::max(reserved, want) > stream_pool_blocks(L.agents)) {   // one stream buffer per instance, one instance per record: the pools hold at most this many
        game::Com_Error(game::ERR_FATAL, "agent capacity: %u reserved scriptable records exceed the %u blocks of each stream buffer class", std::max(reserved, want), stream_pool_blocks(L.agents));
        return result;
    }
    if (reserved >= want) { if (first) console::info("[agent capacity] map ents: %u reserved records are enough for %u agents (skipped)\n", reserved, L.agents); return result; }
    const auto added = want - reserved;
    const auto count = total + added;
    auto* block = static_cast<std::uint8_t*>(_aligned_malloc(static_cast<std::size_t>(count) * record_bytes, 64));
    if (!block) { game::Com_Error(game::ERR_FATAL, "agent capacity: no memory for %u scriptable records", count); return result; }
    for (unsigned i = 0; i < count; ++i)
        std::memcpy(block + static_cast<std::size_t>(i) * record_bytes, array + static_cast<std::size_t>(moved_record_source(i, reserved, added)) * record_bytes, record_bytes);
    record_block = block;
    record_block_owner = s;
    array = block;
    reserved += added;
    server_end += added;
    total = count;
    console::info("[agent capacity] map ents: scriptable records %u -> %u reserved (%u added), total %u, server end %u, block %p\n", reserved - added, reserved,
        added, total, server_end, block);
    return result;
}

class component final : public component_interface {
public:
    void post_unpack() override {
        const auto agents = parse_count(L"-agent-capacity", 100);
        if (!agents) return;
        const auto parts = std::max<std::uint32_t>(parse_count(L"-scriptable-parts", 0), scriptable_parts(agents));
        if (const auto why = refuse(agents); *why) throw std::runtime_error(std::string("agent capacity refused: ") + why);
        if (parts > 0xFFFF) throw std::runtime_error("agent capacity: parts are u16 links (at most 65535)");
        L = make(agents, parts);
        agent_pool = reserve(L.agent_bytes());
        sentient_pool = reserve(L.sentient_bytes());
        table8 = reserve(L.table8_bytes());
        table20 = reserve(L.table20_bytes());
        parts_pool = reserve(L.parts * 4);
        entity_queue = reserve(L.queue_bytes());
        state_a = reserve(L.state_bytes());
        state_c = reserve(L.state_list_bytes());
        state_client = reserve(2 * (L.state_bytes() + 8));   // the two static client blocks with their 8 byte trailers (stock stride 0x17F0)
        state_x = reserve(L.state_bytes());
        build_ai_objects();
        plan_agents();
        plan_archive();
        plan_client();
        plan_parts();
        plan_state();
        plan_pools();
        plan_ai_pool();
        plan_tables();
        plan_entity_queue();
        plan_fastfail();
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
        init_record_hook.create(0x140C2A080, init_record_stub);   // queued: main applies every queued hook after post_unpack
        death_reset_hook.create(0x140C3BDD0, death_reset_stub);
        link_mapents_hook.create(0x1403B8610, link_mapents_stub);
        plan_unwind_probe();
        plan_rewind_probe();
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
            console::info("[agent capacity] entity queue: rows %u at %p, %zu references\n", L.queue_rows(),
                reinterpret_cast<void*>(entity_queue.data), queue_references);
            console::info("[agent capacity] wide sites: %zu caves carry %zu 32-bit fields (characters %u, corpses %u / %u, agents %u)\n", wide_caves,
                std::size(wide_sites), L.characters, L.player_corpses, L.agent_corpses, L.agents);
            console::info("[agent capacity] replicated state: %u dwords (%u bytes a block), %zu fields, list table %u bytes\n", L.state_dwords(), L.state_bytes(),
                state_rows, L.state_list_bytes());
            console::info("[agent capacity] stream buffer pools: %u blocks a class (stock 128 128 64 32 32), %zu fields, server %p client %p\n", stream_pool_blocks(L.agents),
                pool_rows, reinterpret_cast<void*>(pool_server[2].data), reinterpret_cast<void*>(pool_client[2].data));
            console::info("[agent capacity] fast-fail sites patched to ud2: %zu\n", fastfail_sites);
            for (const auto& set : frame_sets)
                console::info("[agent capacity] frame grow of %s: extra %u bytes, %zu fields, probe caves %zu\n", set.name, set.extra,
                    set.planned_fields, set.planned_caves);
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
