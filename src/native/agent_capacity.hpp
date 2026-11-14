#pragma once
#include <array>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <string_view>

// Engine agent capacity (zombies mode): the game's fixed 24 agent records, the 42 character slots that follow the
// 18 players, the entity layout after them and the server's 2,048 reserved scriptable parts, all moved to sizes
// chosen at start (-agent-capacity <n>). Every changed byte is checked against the shipped executable first; one
// mismatch and nothing is written. Layout derived from the shipped code, see docs/AGENT-CAPACITY-ENGINE.md.
namespace agent_capacity {

constexpr std::uint32_t stock_agents = 24, players = 18, stock_characters = players + stock_agents;
constexpr std::uint32_t stock_parts = 0x800;

// One layout, computed from the agent count. Every limit below follows from the shipped code (addresses in the .cpp).
struct layout {
    std::uint32_t agents{}, characters{}, map_start{}, player_corpses{}, agent_corpses{};
    std::uint32_t parts{};
    constexpr std::uint32_t agent_bytes() const { return agents * 0x5010; }
    constexpr std::uint32_t sentient_slots() const { return 71 + agents - stock_agents; }
    constexpr std::uint32_t sentient_bytes() const { return sentient_slots() * 0xA0; }
    constexpr std::uint32_t character_growth() const { return (characters - stock_characters) * 0x2CA0; }
    constexpr std::uint32_t server_size() const { return 0x7A0D8 + character_growth(); }
    constexpr std::uint32_t client_tail() const { return 0xFD7F8 + character_growth(); }
    constexpr std::uint32_t client_flags() const { return 0xFDEA8 + character_growth(); }
    constexpr std::uint32_t client_size() const { return (client_flags() + characters + 15) & ~15u; }
    constexpr std::uint32_t reference_bytes() const { return 8 + characters * 0x40; }
    constexpr std::uint32_t table8_bytes() const { return characters * 8; }
    constexpr std::uint32_t table20_bytes() const { return characters * 5 * 20; }
    // client snapshot: the 24-row agent-state array stays; a full array is appended after the old end
    constexpr std::uint32_t snap_size() const { return 0x3DC78 + agents * 0xC0; }
    // lag-compensation archive (CP): per-character controllers and saved animation trees inside each history frame
    constexpr std::uint32_t controller_records() const { return characters * 2; }
    constexpr std::uint32_t controller_size() const { return characters * (2 + 0x48); }
    constexpr std::uint32_t xanim_base() const { return 0x8B50 + controller_size(); }
    constexpr std::uint32_t xanim_counts() const { return characters * 4; }
    constexpr std::uint32_t xanim_counter() const { return characters * 8; }
    constexpr std::uint32_t xanim_data() const { return xanim_counter() + 4; }
    constexpr std::uint32_t frame_size() const { return xanim_base() + xanim_data() + 1000 * 12; }
    constexpr std::uint32_t restore() const { return 0x2408 + 40 * frame_size(); }
    constexpr std::uint32_t rewind_base() const { return restore() + 0x12010; }
    constexpr std::uint32_t rewind_pointers() const { return (0x14 + characters + 7) & ~7u; }
    constexpr std::uint32_t rewind_active() const { return rewind_pointers() + characters * 8; }
    constexpr std::uint32_t archive_size() const { return rewind_base() + ((rewind_active() + 1 + 7) & ~7u); }
    constexpr std::int32_t archive_growth() const { return static_cast<std::int32_t>(archive_size()) - 0x2077F0; }
    constexpr std::uint32_t query_position_growth() const { return (characters - stock_characters) * 12; }
    constexpr std::uint32_t query_stack_growth() const { return ((characters - stock_characters) * 13 + 15) & ~15u; }
    constexpr std::uint32_t change_words() const { return (characters + 31) / 32; }
    // The two per-sentient tables of an SV agent record (64-byte rows, 60-byte rows), indexed by the sentient slot, move to
    // the end of a grown record: one entry per sentient slot the engine can index. See docs/AGENT-CAPACITY-ENGINE.md.
    constexpr std::uint32_t table_slots() const { return sentient_slots(); }
    constexpr std::uint32_t table1_offset() const { return 0x3F08; }
    constexpr std::uint32_t table2_offset() const { return 0x3F08 + table_slots() * 0x40; }
    constexpr std::uint32_t record_bytes() const { return (table2_offset() + table_slots() * 0x3C + 15) & ~15u; }
};

// A bot client keeps its agent record inside client_t, on the 128 x 0x408 byte reliable-command ring (unused by a bot).
constexpr std::uint32_t embedded_record_room = 0x20000;

// Why a count is refused (empty: accepted). The bounds are the encodings of the shipped code, not choices:
//  - characters - 42 must be a multiple of 4: the archive's controller base moves by a disp32 of (2c - 84) / 8 and its
//    copy loops by (82c + 4) / 8 quadwords (both whole only then);
//  - characters + 8 (first agent corpse) <= 127: eight corpse bounds are signed 8-bit immediates;
//  - the snapshot's character change mask (32 per word) must end before 0x70 on CG_SetNextSnap's stack.
constexpr const char* refuse(std::uint32_t agents) {
    const auto c = players + agents;
    if (agents < stock_agents) return "fewer than the stock 24 agents";
    if ((c - stock_characters) % 4) return "players + agents - 42 must be a multiple of 4 (24, 28, ..., 100)";
    if (c + 8 > 127) return "more than 100 agents needs 8-bit corpse and character bounds rewritten (not done)";
    if (0x60 + ((c + 31) / 32) * 4 > 0x70) return "character change mask does not fit";
    const auto slots = 71 + agents - stock_agents;
    if (((0x3F08 + slots * 0x40 + slots * 0x3C + 15) & ~15u) > embedded_record_room)
        return "the agent record with its per-sentient tables would not fit the room of a bot client's embedded record (0x20000 bytes)";
    return "";
}

constexpr layout make(std::uint32_t agents, std::uint32_t parts) {
    layout l{};
    l.agents = agents; l.characters = players + agents;
    l.player_corpses = l.characters; l.agent_corpses = l.characters + 8; l.map_start = l.characters + 16;
    l.parts = parts;
    return l;
}

// The shipped layout gives back the shipped numbers (the patch plan is the identity at 24).
static_assert(make(64, 0x800).client_size() == ((0xFDEA8 + 40 * 0x2CA0 + 82 + 15) & ~15u));
static_assert(make(64, 0x800).archive_size() == 0x2279D8);
static_assert(make(64, 0x800).query_stack_growth() == 0x210 && make(64, 0x800).query_position_growth() == 0x1E0);
static_assert(make(24, 0x800).archive_size() == 0x2077F0 && make(24, 0x800).frame_size() == 0xC7A8);
static_assert(make(24, 0x800).xanim_base() == 0x9774);
static_assert(make(24, 0x800).record_bytes() == ((0x3F08 + 71 * 0x7C + 15) & ~15u) && make(24, 0x800).table1_offset() == 0x3F08);
static_assert(make(100, 0x800).table2_offset() == 0x3F08 + 147 * 0x40 && make(100, 0x800).record_bytes() < embedded_record_room);
static_assert(refuse(100)[0] == 0 && refuse(78)[0] != 0 && refuse(104)[0] != 0 && refuse(96)[0] == 0);

bool installed() noexcept;
std::uint32_t agents() noexcept;      // 24 when not installed
const char* wire_contract() noexcept; // "24" or "agents-<n>": what a peer must match
// A peer that sends no "agentcap" key is today's official client: the stock layout ("24").
inline bool compatible_peer(std::string_view peer) noexcept {
    return (peer.empty() ? std::string_view("24") : peer) == std::string_view(wire_contract());
}

inline bool relative32(std::uintptr_t target, std::uintptr_t next, std::int32_t& result) noexcept {
    const auto delta = static_cast<long long>(target) - static_cast<long long>(next);
    if (delta > std::numeric_limits<std::int32_t>::max() || delta < std::numeric_limits<std::int32_t>::min()) return false;
    result = static_cast<std::int32_t>(delta);
    return true;
}
}
