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
// The replicated scriptable state (a39): the server keeps one dword (four one-byte part states) a unit of a 1,016 unit budget; an instance of a
// zombie's scriptable takes 8 (31 replicated parts), the 557 fixed parts of cp_zmb 140. The budget grows by 8 units for each agent beyond 24
// (measured: runs d2, d2b; docs/AGENT-CAPACITY-ENGINE.md "Replicated state budget").
constexpr std::uint32_t stock_state_dwords = 0x3F8, state_dwords_per_agent = 8;

// The entities one client snapshot can carry (a49). The server's snapshot writer ends the entity list with the number 0x7FF in 11 bits (FUN_140C67230),
// so an entity number is 0..0x7FE and a snapshot never holds more than 2,047 records: the cap of 2,048 (the 11 bit number space) cannot drop an entity.
// Stock: 768 (sv_maxSnapshotEntities, DAT_146B3985C; the client copy DAT_1421EDA6C), 1,024 for each of the two lists (DAT_146B39858 / 146B39860 on the
// server, DAT_1421EDA68 on the client), the server's entity-state ring frames x 0xA40 + clients x 1,024 records of 0x110 bytes, the client's parsed-entity
// ring frames x 0x258 records. See docs/AGENT-CAPACITY-ENGINE.md "Snapshot entities".
constexpr std::uint32_t stock_snapshot_entities = 0x300, stock_snapshot_list = 0x400, entity_record_bytes = 0x110;
constexpr std::uint32_t snapshot_entities = 2048, snapshot_entities_shift = 11;
static_assert((1u << snapshot_entities_shift) == snapshot_entities && snapshot_entities <= 0x7FF + 1);
// The server ring holds, for every frame, 0xA40 records (3.4 stock snapshots) plus 1,024 for each client: grown by three more snapshots a frame and
// by the new per client room, so the ring still holds 16 frames of four full snapshots (16 x 4 x 2,048 = 131,072 of the 136,192 records at 16 clients).
constexpr std::uint32_t stock_ring_frame_term = 0xA40;
constexpr std::uint32_t ring_frame_term = stock_ring_frame_term + 3 * (snapshot_entities - stock_snapshot_entities);
// The client's parsed-entity ring holds frames x this many records (stock 0x258 = 600, below what a 746 entity snapshot needs): a full snapshot a frame.
constexpr std::uint32_t stock_client_ring_per_frame = 0x258, client_ring_per_frame = snapshot_entities;

// What a 32-bit field of the wide caves holds (agent_capacity.cpp `wide_sites`): the value the shipped one-byte instruction had, as a function of the count.
enum class wide_field { characters, characters_less_one, player_corpses, agent_corpses, minus_agent_corpses, agents, agents_less_players };

// One layout, computed from the agent count. Every limit below follows from the shipped code (addresses in the .cpp).
struct layout {
    std::uint32_t agents{}, characters{}, map_start{}, player_corpses{}, agent_corpses{};
    std::uint32_t parts{};
    constexpr std::int64_t wide_value(wide_field what) const {
        switch (what) {
        case wide_field::characters: return characters;
        case wide_field::characters_less_one: return static_cast<std::int64_t>(characters) - 1;
        case wide_field::player_corpses: return player_corpses;
        case wide_field::agent_corpses: return agent_corpses;
        case wide_field::minus_agent_corpses: return -static_cast<std::int64_t>(agent_corpses);
        case wide_field::agents: return agents;
        case wide_field::agents_less_players: return static_cast<std::int64_t>(agents) - players;
        }
        return 0;
    }
    // Bits of an explicit character number in the agent-state delta and of the clientNum net field: 6 stock; 7 holds numbers below 128; 8 up to 256
    // characters (numbers 0..255); 9 above (a57: numbers up to 511).
    constexpr std::uint32_t net_id_bits() const { return characters <= 127 ? 7 : (characters <= 256 ? 8 : 9); }
    // Above 256 characters the 6..8 bit integer fields of the entity and agent state lists that no one proved free of character numbers are widened too (a57).
    constexpr bool wide_net_fields() const { return characters > 256; }
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
    // The server's per-entity queue (FUN_1405ee9e0 family): one 0x208-byte row per entity number (16 slots of 0x20 bytes, ring head
    // and count), indexed by clients 0..17 and by agents from 18 (up to 17 + the agent count): one row per character.
    constexpr std::uint32_t queue_rows() const { return characters; }
    constexpr std::uint32_t queue_bytes() const { return queue_rows() * 0x208; }
    // client snapshot: the 24-row agent-state array stays; a full array is appended after the old end
    // The replicated scriptable state block: u16 fixed count, S dwords, u16 instance count, two tables of 512 u16, pad = 4 S + 0x808 bytes
    // (0x17E8 at the stock S = 1,016). S - 1,016 is a multiple of 32 at every accepted count, so the 0x80 byte copy loops of the engine (47 of
    // them and a 0x68 byte tail, `mov ecx, 0x2f`) stay exact: 47 + (S - 1016) / 32 loops.
    constexpr std::uint32_t state_dwords() const { return stock_state_dwords + state_dwords_per_agent * (agents - stock_agents); }
    constexpr std::uint32_t state_extra() const { return state_dwords() - stock_state_dwords; }
    constexpr std::uint32_t state_bytes() const { return 4 * state_dwords() + 0x808; }
    constexpr std::uint32_t state_list_bytes() const { return 24 * state_dwords() + 14; }   // six-byte list entries a state byte, heads, list index
    constexpr std::uint32_t state_copies() const { return 47 + state_extra() / 32; }
    // The server hunk size adds the one block that SV_AllocSnapshotBuffers allocates besides its two rings as a constant (0x17E8 rounded to 0x80 = 0x1800).
    constexpr std::uint32_t state_hunk_growth() const { return ((state_bytes() + 0x7F) & ~0x7Fu) - 0x1800; }
    // The client snapshot: the block member moves behind the appended agent states (its stock slot at 0x3AF38 stays, unused); the entity array
    // (stock: 768 records of 0x110 bytes at +0x4AB8) moves behind the block with snapshot_entities records (a49).
    constexpr std::uint32_t snap_state_offset() const { return 0x3DC78 + agents * 0xC0; }
    constexpr std::uint32_t snap_entity_offset() const { return snap_state_offset() + state_bytes(); }
    constexpr std::uint32_t snap_size() const { return snap_entity_offset() + snapshot_entities * entity_record_bytes; }
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
    // Frame grow of FUN_1403E61B0 (docs/CAVE-REWRITER.md): its 71-entry stack array of 32-byte entries sits under the stack cookie
    // and two unbounded loops fill it (sentients: at most one entry per slot; a second list). The frame grows at the array's top
    // by room for one entry per sentient slot from each loop beyond the stock 71, rounded to 16 (movaps alignment).
    constexpr std::uint32_t frame_extra() const { return ((2 * sentient_slots() - 71) * 32 + 15) & ~15u; }
    // Frame grow of FUN_140ADB8E0 (71 entries of 16 bytes) and FUN_140ADDED0 (71 entries of 32 bytes), both under their cookie and
    // filled by ONE loop over the sentients: room for one entry per sentient slot beyond the stock 71 (0 at 24 agents: no change).
    constexpr std::uint32_t frame_extra_b() const { return (sentient_slots() - 71) * 16; }
    constexpr std::uint32_t frame_extra_c() const { return (sentient_slots() - 71) * 32; }
};

// A bot client keeps its agent record inside client_t, on the 128 x 0x408 byte reliable-command ring (unused by a bot).
constexpr std::uint32_t embedded_record_room = 0x20000;

// CG_SetNextSnap (0x14086FBA0): its frame grows by this many bytes (a constant) for the character change mask: 12 words (48 bytes, a57) = 384 characters.
constexpr std::uint32_t snap_mask_room = 48;
// The probe caves of the three grown frames (agent_capacity_frame_cave*.inc, `max_extra`), planned for 320 agents (a57): X of
// FUN_1403E61B0 = (2 x 367 - 71) x 32 = 21,216 (frame 0xD58 + X = 24,632 bytes), FUN_140ADDED0 = (367 - 71) x 32 = 9,472
// (0x9E0 + X), FUN_140ADB8E0 = (367 - 71) x 16 = 4,736 (0x4F0 + X). (a34 planned them for 232: 15,584 / 3,328 / 6,656.)
constexpr std::uint32_t frame_cave_max_extra_a = 0x52E0, frame_cave_max_extra_b = 0x1280, frame_cave_max_extra_c = 0x2500;
// The largest count this component has been analysed for (a29: 232; a55/a57: 320. The agent's entity number needs 9 wire bits above 256 characters;
// GameStateInfo and G_GetMaxAgents carry min(n, 255) in their byte, the three readers of the value take n as an immediate above 255).
constexpr std::uint32_t max_analysed_agents = 320;

// Why a count is refused (empty: accepted). The bounds are the encodings of the shipped code, not choices:
//  - characters - 42 must be a multiple of 4: the archive's controller base moves by a disp32 of (2c - 84) / 8 and its
//    copy loops by (82c + 4) / 8 quadwords (both whole only then);
//  - the corpse and character bounds are 32-bit fields in caves since a33 (they were signed 8-bit immediates: 100 agents at most);
//  - the snapshot's character change mask (32 per word) lives in the room of CG_SetNextSnap's frame grow (a34, 12 words since a57);
//  - the page-probe caves of the three grown frames are planned for 320 agents (a57).
constexpr const char* refuse(std::uint32_t agents) {
    const auto c = players + agents;
    if (agents < stock_agents) return "fewer than the stock 24 agents";
    if ((c - stock_characters) % 4) return "players + agents - 42 must be a multiple of 4 (24, 28, ..., 320)";
    if (agents > max_analysed_agents) return "more than 320 agents: not analysed (a57)";
    if (((c + 31) / 32) * 4 > snap_mask_room) return "character change mask does not fit the room of CG_SetNextSnap's frame grow";
    const auto slots = 71 + agents - stock_agents;
    if ((((2 * slots - 71) * 32 + 15) & ~15u) > frame_cave_max_extra_a) return "FUN_1403E61B0: the page-probe cave of its grown frame was planned for 320 agents";
    if ((slots - 71) * 32 > frame_cave_max_extra_c) return "FUN_140ADDED0: the page-probe cave of its grown frame was planned for 320 agents";
    if ((slots - 71) * 16 > frame_cave_max_extra_b) return "FUN_140ADB8E0: the page-probe cave of its grown frame was planned for 320 agents";
    if (((0x3F08 + slots * 0x40 + slots * 0x3C + 15) & ~15u) > embedded_record_room)
        return "the agent record with its per-sentient tables would not fit the room of a bot client's embedded record (0x20000 bytes)";
    return "";
}

// The state budget at every accepted count: the dword start/count tables and the byte list indices are u16 (4 S <= 65,535), the copy loops stay exact.
constexpr bool state_budget_holds() {
    for (std::uint32_t n = 24; n <= 320; n += 4) {
        const std::uint32_t s = stock_state_dwords + state_dwords_per_agent * (n - stock_agents);
        if ((s - stock_state_dwords) % 32 || 4 * s > 0xFFFF) return false;
    }
    return true;
}
static_assert(state_budget_holds());

// Reserved scriptable RECORDS (a41, a42): the map's MapEnts block (S + 0x240: total, reserved, server end; array at +0x250, 0x1D0 bytes a
// record) holds 200 reserved records on cp_zmb, 24 stock instances plus one for every agent alive. A zombie's scriptable needs one, so
// the block is rebuilt at load with R(n) = max(200, n + 56) reserved records: the 24 stock instances, n agents and 32 spare.
constexpr std::uint32_t stock_reserved_records = 200, reserved_record_margin = 32, record_bytes = 0x1D0;
constexpr std::uint32_t reserved_records(std::uint32_t agents) {
    const auto need = stock_agents + agents + reserved_record_margin;
    return need > stock_reserved_records ? need : stock_reserved_records;
}
// The block after the move: [0, reserved) the old reserved records, `added` copies of reserved record 0, then the old records from
// `reserved` on. `old_index` is the index of the old record that new record `index` is (record 0 stands for each added one), for a
// block of `total` old records; the indexes of the fixed records shift by `added`.
constexpr std::uint32_t moved_record_source(std::uint32_t index, std::uint32_t reserved, std::uint32_t added) {
    return index < reserved ? index : (index < reserved + added ? 0 : index - added);
}
// Record indexes stored in the zone's data (a44): the part tables of the MapEnts (two groups, S + 0x178 / S + 0x180, `count` entries of 0x70
// bytes, entry +0 the type, entry +0x4C a u16 record index for the types 3 and 4) name a scriptable record by its authored index, and a value
// at or above the old total is "no record" (FUN_140BD8B40 queues that event: the frontend zone stores 60 = its total). After the move the old
// record `i` >= `reserved` sits at `i + added` and the total grows by `added`: every stored value >= `reserved` shifts by `added`, the ones
// below `total` stay the same record, the ones at or above it stay "no record" (>= the new total). A value below `reserved` is a reserved
// record and stays; one that cannot take `added` inside a u16 (0xFFFF-like) stays, it is far above any total.
constexpr std::uint32_t part_entry_bytes = 0x70, part_entry_type_offset = 0, part_entry_record_offset = 0x4C, part_type_record_link = 3, part_type_record_event = 4;
constexpr std::uint32_t remapped_record_index(std::uint32_t index, std::uint32_t reserved, std::uint32_t added) {
    return index >= reserved && index + added <= 0xFFFF ? index + added : index;
}
// Reserved scriptable part links (u16 links, at most 65,535): about 31 for each agent's scriptable (a41; measured 4,137 at 132 alive) on top
// of the stock 2,048 and a margin of 1,024, rounded up to 1,024, never below the 8,192 of a39.
constexpr std::uint32_t scriptable_parts(std::uint32_t agents) {
    const auto need = stock_parts + 32 * agents + 1024;
    const auto rounded = (need + 1023) / 1024 * 1024;
    return rounded > 8192 ? rounded : 8192;
}
static_assert(reserved_records(24) == 200 && reserved_records(100) == 200 && reserved_records(144) == 200 && reserved_records(148) == 204 &&
              reserved_records(232) == 288 && reserved_records(320) == 376);
static_assert(scriptable_parts(24) == 8192 && scriptable_parts(100) == 8192 && scriptable_parts(164) == 9216 && scriptable_parts(232) == 11264 &&
              scriptable_parts(320) == 13312 && scriptable_parts(320) <= 0xFFFF);

// Scriptable stream buffer pools (a43): every reserved scriptable instance takes one stream buffer of [def + 0x40] bytes (148 for a zombie) from
// five static pools, 16, 64, 256, 512 and 3072 byte blocks, stock 128, 128, 64, 32, 32 blocks (FUN_140BE1770 alloc: the smallest class that holds the
// request, then the larger ones while that list is empty; "Could not allocate Stream Buffer of %i bytes" when all are). The server has one pool a
// class, the client two slots a class. An instance holds at most one buffer and there is one reserved record for each instance, so a class that holds
// as many blocks as there are records can never run out: 512 blocks a class (the part state tables hold at most 512 instances too), 1.97 MB a pool set,
// never fewer than the reserved records of the map (R(n)).
constexpr std::uint32_t stream_pool_classes = 5, stream_pool_slots = 2, stream_pool_min_blocks = 512;
constexpr std::uint32_t stream_pool_class_bytes[stream_pool_classes] = {16, 64, 256, 512, 3072};
constexpr std::uint32_t stock_stream_pool_blocks[stream_pool_classes] = {128, 128, 64, 32, 32};
constexpr std::uint32_t stream_pool_blocks(std::uint32_t agents) {
    const auto records = reserved_records(agents);
    return records > stream_pool_min_blocks ? records : stream_pool_min_blocks;
}
constexpr std::uint32_t stream_pool_array_bytes(std::uint32_t agents, unsigned cls) { return stream_pool_blocks(agents) * stream_pool_class_bytes[cls]; }
constexpr std::uint32_t stream_pool_stride(std::uint32_t agents, unsigned cls) { return stream_pool_array_bytes(agents, cls) + 8; }   // array, then the 8 byte list head
static_assert(stream_pool_blocks(24) == 512 && stream_pool_blocks(232) == 512 && stream_pool_blocks(320) == 512 && stream_pool_array_bytes(232, 4) == 512 * 3072 &&
              stream_pool_stride(232, 0) == 512 * 16 + 8);

// The client's character proxy list (a47; the "140 entry character sound list"): one entry for every client entity (centity) of eType 1 (player), 18
// (agent), 20 (actor) or 6 with the flag word 1, active in the snapshot (FUN_1405532D0 and FUN_140552DF0 drop the others), each with two physics
// character proxies. FUN_1405527E0 appends with no bound; its four callers (FUN_1402E7230, FUN_14086CD50) ask FUN_140552DB0 first, so an entry is a
// DISTINCT centity, and a client has entity numbers 0..0x7FE (0x7FF is "none": the entity masks of CG_SetNextSnap are 2,048 bits, FUN_14086FBA0). The
// 16 corpse entities between the characters and the map entities (8 player corpses eType 2, 8 agent corpses eType 19: layout::make) are not in the
// filter, so the list never holds more than 0x7FF - 16 = 2,031 entries whatever the agent count (the count only decides which entity numbers are
// characters; 232 agents + 18 players are 250 of them). Of those, the players and agents fit the characters, the actors the 38 entry pool of
// FUN_14044ED70, and the eType 6 entities are bounded by the entity numbers only: no tighter hard maximum exists, so the size is the entity space.
// The lookup FUN_140552D20 steps five entries at a time (the stock 140 is a multiple of 5): entries are rounded up to a multiple of 5.
constexpr std::uint32_t stock_proxy_entries = 140, proxy_entity_numbers = 0x7FF, proxy_corpse_entities = 16, proxy_actor_pool = 38;
constexpr std::uint32_t proxy_list_most = proxy_entity_numbers - proxy_corpse_entities;
constexpr std::uint32_t proxy_list_entries = (proxy_list_most + 4) / 5 * 5;
// Bytes an entry takes across the eight tables: centity pointer 8, two 0x18 transforms 0x30, two physics objects twice 16, four tables of two u32.
constexpr std::uint32_t proxy_entry_bytes = 8 + 0x30 + 16 + 16 + 4 * 8;
// FUN_1405532D0 keeps u32 selected[140] (0xC0..0x2F0) and a 140 * 16 byte array (0x2F0..0xBB0) under its cookie: the frame grows at the cookie by the
// bytes the second array gains, and the second array moves up by the bytes the first one gains (three `lea` of its base).
constexpr std::uint32_t proxy_selected_bytes = (4 * proxy_list_entries + 15) & ~15u;
constexpr std::uint32_t proxy_frame_shift = proxy_selected_bytes - 4 * stock_proxy_entries;
constexpr std::uint32_t proxy_frame_extra = proxy_frame_shift + 16 * (proxy_list_entries - stock_proxy_entries);
static_assert(proxy_list_entries == 2035 && proxy_list_entries % 5 == 0 && proxy_list_entries >= proxy_list_most && proxy_frame_shift % 16 == 0 &&
              proxy_frame_extra % 16 == 0 && proxy_frame_shift == 7584 && proxy_frame_extra == 37904 && 4 * stock_proxy_entries == 0x230 &&
              proxy_entry_bytes == 120);

// The saved animation cache (a57): a hash map of 193 buckets (0x147994898) from a DObj index (the key, FUN_140bb16d0: the index of a 0x110 byte DObj record, 2,048 of
// them) to a saved animation state; its nodes of 0x360 bytes come from ONE static pool of 84 chained by a static initialiser (0x14001AE20, free list head 0x147994890, an
// empty list ends at the head's own address). The insert (FUN_140d815a0, 0x140D818xx: pop the head, no emptiness check) took the head variable itself as a node when the
// 85th key was saved and wrote the key and the state over the first buckets: the walk of the chain (FUN_140d80d60) then read a garbage pointer (runs a57-m264 and m232: the
// 84th ghost). One node a key at most, so 2,048 nodes cover every key; the extra nodes are appended to the free list at start like the two pools of plan_3c.
constexpr std::uintptr_t anim_cache_head = 0x147994890ull;
constexpr std::uint32_t anim_cache_node_bytes = 0x360, anim_cache_stock_nodes = 84, dobj_records = 2048;
constexpr std::uint32_t anim_cache_extra_nodes = dobj_records - anim_cache_stock_nodes;
static_assert(anim_cache_extra_nodes == 1964 && anim_cache_node_bytes * dobj_records == 0x1B0000);

// The XAnim anim-info heap (a57): every animated entity's animation state is chained from 16 byte "anim info" units of ONE static heap (0x147995420, 0x3FFC0 usable bytes
// of 0x40000 = 16,384 units, initialised by FUN_140D83DF0; the units are addressed by u16 indexes from the base 0x1479953E0 = heap - 0x40). A client that animates about 250
// agents runs out: FUN_140D72DB0 asks FUN_140D846B0 for a unit, gets 0 and calls the fatal "exceeded maximum number of anim info" (a message box that blocks the client's
// main thread for good; run a57-hB: 250 alive agents, 220 in run a57-hA were fine). The heap becomes the largest the u16 index allows, 0x100000 bytes (65,536 units, 4x), in a new
// block: the init's seven fields (heap start, usable bytes, base, total bytes and the four zeroed units) are retargeted. The heap object keeps its own bookkeeping inside the heap.
constexpr std::uintptr_t anim_info_stock_heap = 0x147995420ull, anim_info_stock_base = 0x1479953E0ull;
constexpr std::uint32_t anim_info_stock_bytes = 0x40000, anim_info_heap_bytes = 0x100000, anim_info_header = 0x40;
static_assert(anim_info_stock_heap - anim_info_stock_base == anim_info_header && anim_info_heap_bytes / 16 <= 0x10000 && anim_info_heap_bytes % 16 == 0 &&
              anim_info_stock_bytes - anim_info_header == 0x3FFC0);

// The per-frame animated bone buffers (a57): every animated skeleton of a frame (a client animates every character of its snapshot; the server animates what it traces) takes its bones
// from ONE bump buffer chosen by the frame's parity: two static halves of 0x100000 bytes at 0x141FE5F20 (FUN_140342790 picks `parity << 20 + base`), the allocators
// FUN_140346520 (client) and FUN_1403464D0 (server side) hand out 16 byte multiples and refuse past 0xFFFF0 with the fatal message box "TOO MANY ANIMATED BONES"
// (a joined client at 238 agents and more, about 4.4 KB a skeleton: runs a57-hB, hB2, n320, n320b, the message read from the frozen client's stack). Each half becomes 4 MB (shift 22,
// cap 0x3FFFF0) in a new block of 8 MB; the skeleton pointers are 64-bit, nothing else addresses the buffer (only the allocators and a null test of the base variable).
constexpr std::uint32_t bone_stock_shift = 20, bone_shift = 22, bone_stock_cap = 0xFFFF0, bone_cap = (1u << bone_shift) - 0x10;
constexpr std::uintptr_t bone_stock_base = 0x141FE5F23ull;
static_assert(bone_cap == 0x3FFFF0 && (1u << bone_stock_shift) - 0x10 == bone_stock_cap);

constexpr layout make(std::uint32_t agents, std::uint32_t parts) {
    layout l{};
    l.agents = agents; l.characters = players + agents;
    l.player_corpses = l.characters; l.agent_corpses = l.characters + 8; l.map_start = l.characters + 16;
    l.parts = parts;
    return l;
}

// The proxy list holds every character and the actor pool for every accepted agent count (the corpse entities are not listed).
constexpr bool proxy_list_holds_the_characters() {
    for (std::uint32_t n = 24; n <= 320; n += 4)
        if (make(n, 0x800).characters + proxy_actor_pool > proxy_list_most || make(n, 0x800).map_start - make(n, 0x800).characters != proxy_corpse_entities) return false;
    return true;
}
static_assert(proxy_list_holds_the_characters());

// A one-byte field the CPU sign-extends (a disp8, an imm8 of `83 /r`, `6B`, `48 83`) holds -128..127; add1s (the .cpp) refuses the rest.
constexpr bool fits_signed_byte(std::int64_t value) { return value >= -128 && value <= 127; }
// The fields that held a count are 32-bit now (wide caves, `wide16` in place, imm32 `imul`). What stays one byte: GameStateInfo's +0x546 and the
// G_GetMaxAgents result (the wire byte of the gamestate message): they carry min(n, 255) (a57); the three readers of the value (SV init, the
// client snapshot ring, GScr_getmaxagents) take n as an imm32 above 255 and are not touched up to 255. CG_SetNextSnap's stack offsets are not
// one-byte patches any more (a34). The rewind pointer array's displacement is a 32-bit field in a cave too (rewind_cave_table).
constexpr std::uint32_t gamestate_agent_byte(std::uint32_t agents) { return agents < 255 ? agents : 255; }
constexpr bool byte_sites_hold(std::uint32_t agents) { return gamestate_agent_byte(agents) <= 255; }
constexpr bool accepted_counts_keep_byte_sites() {
    for (std::uint32_t n = 0; n <= 1024; ++n)
        if (refuse(n)[0] == 0 && !byte_sites_hold(n)) return false;
    return true;
}
static_assert(accepted_counts_keep_byte_sites());
// Every wide field holds its value as a signed 32-bit number for every count up to the analysed maximum.
static_assert(make(max_analysed_agents, 0x800).wide_value(wide_field::agent_corpses) == 18 + 320 + 8 &&
              make(max_analysed_agents, 0x800).wide_value(wide_field::minus_agent_corpses) == -(18 + 320 + 8) &&
              make(100, 0x800).wide_value(wide_field::characters_less_one) == 117 && make(100, 0x800).wide_value(wide_field::agents_less_players) == 82);
static_assert(make(100, 0x800).net_id_bits() == 7 && make(108, 0x800).net_id_bits() == 7 && make(112, 0x800).net_id_bits() == 8 &&
              make(232, 0x800).net_id_bits() == 8 && make(236, 0x800).net_id_bits() == 8 && make(240, 0x800).net_id_bits() == 9 &&
              make(320, 0x800).net_id_bits() == 9 && !make(236, 0x800).wide_net_fields() && make(240, 0x800).wide_net_fields() &&
              gamestate_agent_byte(232) == 232 && gamestate_agent_byte(254) == 254 && gamestate_agent_byte(255) == 255 && gamestate_agent_byte(320) == 255);
static_assert(make(24, 0x800).rewind_pointers() == 0x40 && make(84, 0x800).rewind_pointers() == 0x80 && make(100, 0x800).rewind_pointers() == 0x90);
static_assert(!fits_signed_byte(make(100, 0x800).rewind_pointers()));   // why that store is a cave with a 32-bit displacement

// The state block at the stock count is the shipped one: 1,016 dwords, 0x17E8 bytes, a 0x5F4E byte list table, 47 copy loops.
static_assert(make(24, 0x800).state_dwords() == 1016 && make(24, 0x800).state_bytes() == 0x17E8 && make(24, 0x800).state_list_bytes() == 0x5F4E &&
              make(24, 0x800).state_copies() == 47 && make(24, 0x800).state_extra() == 0 && make(24, 0x800).state_hunk_growth() == 0);
static_assert(make(100, 0x800).state_dwords() == 1624 && make(164, 0x800).state_dwords() == 2136 && make(232, 0x800).state_dwords() == 2680);
static_assert(make(164, 0x800).state_bytes() == 10600 && make(232, 0x800).state_bytes() == 12776 && make(164, 0x800).state_copies() == 82);
static_assert(make(100, 0x800).snap_entity_offset() == 0x3DC78 + 100 * 0xC0 + 8552 &&
              make(100, 0x800).snap_size() == 0x3DC78 + 100 * 0xC0 + 8552 + 2048 * 0x110);
static_assert(ring_frame_term == 6464 && 16 * ring_frame_term + 16 * snapshot_entities == 136192 && 16 * 4 * snapshot_entities <= 136192);

// The shipped layout gives back the shipped numbers (the patch plan is the identity at 24).
static_assert(make(64, 0x800).client_size() == ((0xFDEA8 + 40 * 0x2CA0 + 82 + 15) & ~15u));
static_assert(make(64, 0x800).archive_size() == 0x2279D8);
static_assert(make(64, 0x800).query_stack_growth() == 0x210 && make(64, 0x800).query_position_growth() == 0x1E0);
static_assert(make(24, 0x800).archive_size() == 0x2077F0 && make(24, 0x800).frame_size() == 0xC7A8);
static_assert(make(24, 0x800).xanim_base() == 0x9774);
static_assert(make(24, 0x800).record_bytes() == ((0x3F08 + 71 * 0x7C + 15) & ~15u) && make(24, 0x800).table1_offset() == 0x3F08);
static_assert(make(100, 0x800).table2_offset() == 0x3F08 + 147 * 0x40 && make(100, 0x800).record_bytes() < embedded_record_room);
static_assert(make(24, 0x800).frame_extra() == 2272 && make(100, 0x800).frame_extra() == 7136 && make(100, 0x800).frame_extra() % 16 == 0);
static_assert(make(24, 0x800).frame_extra_b() == 0 && make(100, 0x800).frame_extra_b() == 1216 && make(24, 0x800).frame_extra_c() == 0 &&
              make(100, 0x800).frame_extra_c() == 2432);
// a34: the three frames at the largest count are the planned maxima (a29 had 15,456 / 3,296 / 6,592 at 230 agents; 232 adds 2 slots).
static_assert(make(232, 0x800).sentient_slots() == 279 && make(232, 0x800).frame_extra() == 15584 && make(232, 0x800).frame_extra_b() == 3328 &&
              make(232, 0x800).frame_extra_c() == 6656);
// a57: at 320 they are the planned maxima (E = 367 sentient slots).
static_assert(make(320, 0x800).sentient_slots() == 367 && make(320, 0x800).frame_extra() == frame_cave_max_extra_a && make(320, 0x800).frame_extra() == 21216 &&
              make(320, 0x800).frame_extra_b() == frame_cave_max_extra_b && make(320, 0x800).frame_extra_b() == 4736 &&
              make(320, 0x800).frame_extra_c() == frame_cave_max_extra_c && make(320, 0x800).frame_extra_c() == 9472);
static_assert(make(24, 0x800).queue_bytes() == 0x5550 && make(100, 0x800).queue_rows() == 118 && 18 + 100 == make(100, 0x800).queue_rows());
// refuse() accepts exactly the counts 24, 28, ..., 320 (a57: every frame, cave and mask is sized for 320; nothing between 104 and 320 refuses).
constexpr bool accepts_exactly_the_valid_counts() {
    for (std::uint32_t n = 0; n <= 1024; ++n)
        if ((refuse(n)[0] == 0) != (n >= 24 && n <= 320 && (n - 24) % 4 == 0)) return false;
    return true;
}
static_assert(accepts_exactly_the_valid_counts());
static_assert(refuse(100)[0] == 0 && refuse(232)[0] == 0 && refuse(236)[0] == 0 && refuse(320)[0] == 0 && refuse(78)[0] != 0 && refuse(324)[0] != 0 && refuse(321)[0] != 0 &&
              refuse(233)[0] != 0);

bool installed() noexcept;
// How many times the renderer's full-list warning came for a list (a52): 0x9A the model parameter list, 5 the lights, 1 the draw records, 2 the other pass's draw records.
std::uint32_t render_skipped(unsigned id) noexcept;
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
