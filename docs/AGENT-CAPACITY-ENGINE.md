# Engine agent capacity: more than 24 real zombies

`src/native/agent_capacity.cpp` (build switch `AgentCapacity` of `ops/Build-Voice.ps1`) moves the engine's fixed agent
limits to a count chosen when the game starts: `-agent-capacity <n>` on the server and on every client. Without the
flag nothing changes. It replaces the October 2026 "capacity 64" candidate (`paris_agent_capacity.cpp`, kept dormant):
the same sites, re-checked, generalised to a runtime count, with the limits that candidate missed.

Measured results and the history are in the server repository, `docs/ZOMBIE-CAPACITY.md`. The address map the work is
built on: the RE map `engine-zombie-limits.md` (notes folder) and the tools below.

## What it changes (shipped iw7_ship.exe, SHA-256 A883EE28...)

| Limit | Stock | With n agents (C = 18 + n characters) | Where |
|---|---|---|---|
| G_GetMaxAgents | min(atoi(scr_<gametype>_maxagents), 24); the stock game writes "24" into that dvar itself | n (the dvar is not read: `call atoi` becomes `mov eax, n`) | sub_140C18D00, 0x140C18D6E and 0x140C18D77 |
| characters / first corpse / first map entity | 42 / 42, 50 / 58 | C / C, C+8 / C+16 | 0x1405AFFF6, 0x1405B0000, G_InitGame 0x14B54FA72/7C, 0x140B6686F, corpse allocators and 12 index sites |
| G agent records (0x5010) | static 24 | new storage n x 0x5010 | rip 0x14C1ED662, 0x140007788, five 0x78180 sizes |
| sentients (0xA0) | 71 | n + 47 | sub_140AF6310, 0x14B3C5D02 |
| two per-sentient object pools (0x4D0 and 0x180 bytes, built by static constructors) | 71 each | n + 47 each, built with the shipped constructors | allocators sub_1403EE550, sub_1403F2820 and 28 scan/restore sites |
| character tables (refs 64 B, work 8 B and 100 B, server 0x2CA0 records, client 0x2CA0 records, flags) | 42 | C | see plan_agents / plan_client |
| lag-compensation archive (40 frames of per-character controllers and saved trees) | 42 | C | plan_archive (three copy loops re-encoded, three stack frames and their unwind data grown) |
| wire: character index | 6 bits | 7 bits | agent-state delta writer and readers, 24 clientNum net fields |
| client snapshot agent states | min(n, 24) copied | n (array appended after the old snapshot end) | CL_GetSnapshot 0x1409934A4 and the snapshot sizes |
| server snapshot agent rings | frames x 24 | frames x n (and the hunk budget) | sub_140C68A00, sub_140C68880 |
| client snapshot agent ring (remote server) | frames x 24 | frames x n | sub_1409B2620 0x1409B26FC |
| server AI loops over characters (cmp reg, 42 x 0x3F8) | 42 | C (7 of 8; see open) | 0x140C22AE3 ... 0x140C481FE |
| reserved scriptable parts (an agent's model takes 31) | 2,048 | default max(8,192, 2,048 + 32 n + 1,024 rounded up to 1,024): 9,216 at 164, 11,264 at 232 (`-scriptable-parts <m>` raises it, at most 65,535) | sub_140BF7770, sub_140BF96A0, sub_140BF9A70, sub_140BFA3D0, sub_140BF6F20 |
| replicated scriptable state (a zombie's scriptable takes 8 of the budget's units) | 1,016 dwords | 1,016 + 8 (n - 24): 1,624 at 100, 2,136 at 164, 2,680 at 232 | see "Replicated state budget" (205 fields, five relocated blocks) |
| reserved scriptable RECORDS (MapEnts scriptable block, map data) | 200 (cp_zmb) | R(n) = max(200, n + 56): 288 at 232; the block is rebuilt at load, and every record index the zone stores moves with it | see "Reserved scriptable records" (a42) and "Stored record indexes" (a44), detour of FUN_1403B8610 |
| entity handle head table of the sentients (u16 a sentient slot, 0x145C64BA0; `ENT_HANDLE_COUNT` nodes are a separate 4,096 list) | 71 entries, the object at 0x145C64D00 follows | sentient_slots() entries in its own block | a44: FUN_140AE99F0 (clear, size 0x8E), FUN_140AE9A80, FUN_140AE9BE0 (3 `lea`), see "Sentient handle head table" |
| client character proxy list (one entry for every active character entity of the client: a centity pointer, two physics proxies; counts at 0x144B47820) | 140 entries, FUN_1405527E0 appends with no bound (the 141st read the count behind the table: client crash with 150 alive agents, a44-m2) | 2,035 entries (the 2,047 entity numbers less the 16 corpse entities, rounded to the lookup's step of five), whatever n; eight tables of 120 bytes an entry in one block | a47: 92 fields in ten functions (`ops/engine/sound_sites.py`), FUN_1405532D0 frame grown by 37,904 bytes, see "Character proxy list" |
| entities in one client snapshot (server cap, both lists, the entity-state ring and its hunk, the client ring, baselines and the cgame entity array) | 768 (lists 1,024) | 2,048 = the 11 bit entity number space: nothing is dropped for the cap | see "Snapshot entities" (a49; 33 fields, `snapshot_sites.py`) |

Every field is compared with its shipped value before anything is written; one difference and the game stops with the
address (nothing is half-applied). Relocated tables sit within 2 GB of the image (the code reaches them by 32-bit
displacements) with guard bytes checked every 0.5 s.

**Accepted counts:** 24, 28, ..., 320 (`refuse()`, a34; 232 until a57). The barriers, in the order `refuse()` checks them: C - 42 must be a multiple of 4 (the archive
copy loops move by (2C - 84) / 8 and (82C + 4) / 8 quadwords); at most 320 agents (`max_analysed_agents`; see "320 agents (a57)": the agent number is 9 wire
bits above 256 characters, the gamestate byte is min(n, 255)); the snapshot's character change mask (CG_SetNextSnap: a 48-byte room opened by its frame grow,
12 words = 384 characters, 338 at 320 agents); the page-probe caves of the three grown frames, planned for 320 agents
(frame_extra of FUN_1403E61B0 = (2 x 367 - 71) x 32 = 21,216, frame 0xD58 + X = 24,632 bytes, 7 probes; FUN_140ADDED0 = (367 - 71) x 32 = 9,472,
3 probes; FUN_140ADB8E0 = (367 - 71) x 16 = 4,736, frame 0x4F0 + X = 6,000 bytes, 2 probes; 367 = n + 47 sentient
slots; a34 planned 15,584 / 6,656 / 3,328 for 232). None of these functions had a stack probe call of its own (their stock frames are below a page); the planner adds the probe. The
corpse and character bounds are not a barrier any more (a33, below). a29 had 15,456 / 3,296 / 6,592 at 230 agents; 232 adds two slots.

**One-byte fields (15 Nov 2026).** The component patched 43 instructions with ONE byte, and the CPU sign-extends every one of them (12
displacements `disp8`, 31 immediates of `83 /r` and `48 83` forms; `agent_capacity_sites_test.py` decodes each from the shipped bytes). They went
through `add1s(address, before, intended)`, which throws at plan time when the value read as a signed byte differs from the intended one. A 44th, the
lag-compensation rewind store `mov [rdi+rbx*8+0x40],rax` of FUN_140415bf0 (0x140415C24, called from
FUN_140415120 from FUN_140414df0 from FUN_140594eb0, the rewound-entity animation path), was patched as one byte too: `rewind_pointers()`
is 0x80 from 84 agents and 0x90 at 100, read as -128 and -112, so the store landed 0x100 bytes below the pointer array. It is now a
cave with a 32-bit displacement (`ops/engine/caves/rewind-pointer.*`, `agent_capacity_caves_rewind.inc`; the component writes the layout's value into the
cave at start, at every count).

**Wide sites (a33, 15 Nov 2026).** 37 of the 43 one-byte instructions held a count (rows 1-35 and 37-38 of the a29 list: 14 corpse subtractions and
allocators, 18 character bounds, 2 agent-count bounds, the agents - 18 of the client snapshot buffers and the two frames x agents `imul`s of
SV_InitSnapshotBufferSizes). Each is a 32-bit field now: 34 in caves (`ops/engine/caves/wide-sites.requests.json` and `.plan.json`, planned by
`cave_plan.py`, table `agent_capacity_caves_wide.inc`, 35 caves because the first imul and its `shl` are two windows), two `cmp ax, imm16` in place
(`wide16`), and the second imul in place (`lea` + `shl` = 7 bytes = `imul r11d, imm32`). The plan holds a placeholder `0x5A5A0000 | row` in every
field; `plan_caves()` writes `layout::wide_value(wide_site.what)` into it and throws unless every row has exactly one placeholder. Installed at every
count (like the other caves): at 24 agents each cave is the shipped instruction, at 100 it computes what the shipped one did. The explicit character
number of the agent-state delta (5 sites) and the clientNum net field (24 sites) are 7 bits up to 127 characters and 8 bits above
(`layout::net_id_bits()`, 7 at every count up to 108). Left as one byte: the low byte of G_GetMaxAgents' `mov eax, n` (`unsigned_imm8`, at most 255); CG_SetNextSnap's eight stack offsets are gone (a34: the mask is in the room of a frame grow of `FUN_14086FBA0`, see `docs/CAVE-REWRITER.md`). `agent_capacity_sites_test.py` decodes every cave for every count 24..232 and checks the
field value, and that at 24 the field equals the shipped immediate.

**Agent motion above entity 41 (a40).** `cmp dword [rbp+0x700], 0x2a` at 0x1407AE222 in FUN_1407ae190 decides, for position type 3, whether an entity takes the
interpolation between the two snapshots (FUN_1407b6850, numbers below 42) or the generic trajectory path evaluated at the render time (numbers 42 and up: drawn
stepwise at the snapshot rate, measured by run i1 of a37: jerk 0.82 against 0.02, stutter 99.8 percent against 0.5). A cave (`ops/engine/caves/interp-agents.*`,
`agent_capacity_caves_interp.inc`, installed with `-agent-capacity`) feeds the same `jge` the flags of `cmp X, 0x2A` with X = 0 when the entity type
(`[rbp+0x704]`) is 18 (agent) and its number is below the character count, X = the number otherwise: branch-free (`cmove` and `cmovl` on a 32-bit copy), rax, rcx and rdx are
pushed and popped (flags survive the pops), the character count is the imm32 of one `cmp ecx, imm` (placeholder 0x5A5AC0DE, written by `plan_caves()`, exactly one).
At 24 agents (42 characters) it is the shipped compare for every input; the test (`InterpAgents` in `agent_capacity_state_test.py`) emulates the cave for every
allowed count 24..232 over entity numbers and types. The lab switch `-paris-interp-all-agents` of a37 is removed (the cave replaces it); the motion meter and its reader stay.
Measured (a40, client 9CD7C14C03051901 from components f965997d, `patches=1508 caves=94`, netlab soak plan, private loopback): g1 (100 records, 78 alive) PASS 148/148 steps, 41/41 expectations: jerk mean low 0.0198..0.0233, high 0.0195..0.0228 (units per ms), stutter low 0.37..0.64 percent, high 0.39..0.64 percent, client 123.0..130.4 fps (a37 i1 without the cave: high jerk 0.82, stutter 99.8 percent, 116..121 fps). g2 (164 records, 132 alive, 110 distinct agents in the high group) PASS 148/148, 41/41, no ERR_DROP: high jerk 0.0200..0.0229, stutter 0.53..0.74 percent against low 0.0194..0.0232 and 0.38..0.75 percent, client 110.7..123.1 fps (a39 r4: 113..115). Not measured: the highest entity number seen (the meter keeps groups, not numbers: `characters` = 182 bounds it), n above 164, a second joined client, the return-to-24 window z24 (high stutter 1.05 percent there while agents are being killed and respawned; low 0.46 percent).
Per-entity arrays on the path of FUN_1407b6850 (a40 step 3): none is indexed by the entity number. The only table is the per-character record at
`cg + 0x885B8 + [centity+0x79C] x 0x2CA0` (`cg` object vtable +0x60 = FUN_140242b70, reached through FUN_140828a50), already grown with the character count (`character_growth()`), and
the generic path that agents 42 and up took before calls FUN_140828a50 the same way. The callees FUN_1401c6a40, FUN_140068e40/e10/e00, FUN_1401c7c30, FUN_1401502e0 and the
quaternion helpers read only the entity and the two snapshot pointers (`cg+0x4AE0/0x4AE8`). The stock early return skips the tail of FUN_1407ae190 (0x1407AE3B4), which only types 2 and 0x13 use: agents (18) never.

Proof state of the rewind store: the cave is decoded for every allowed count by `agent_capacity_sites_test.py` (same instruction as the shipped one, only the
displacement differs, equal to what the planner re-encodes), and the headless plan `capacity-agents-headless.json` passes 22/22 with 51 caves
installed (50 before). The store itself has NOT been seen executing: `FUN_140415bf0` runs only while a lag-compensated action has the archive's rewind
active (read statically, never seen running: `FUN_140100d80`, a weapon fire of a client with a command time in the past, calls the archive's vtable +0x88 and so on to the animation of the
rewound characters, `FUN_140594df0` -> `FUN_140594eb0` -> `FUN_140414df0` -> `FUN_140415120` -> `FUN_140415bf0`), and neither the headless plan (an engine bot) nor
the network-lab plan (the joined client fires no shot in a plan run) does that. The lab-only probe (`IW7_AGENT_CAPACITY_REWIND_PROBE=1` or `-agent-capacity-rewind-probe`)
logs the first call of `FUN_140415bf0` with the store address against the layout's pointer array, and the call count every 20 s while it changes; both runs
armed it and logged no call.

**Measured with the a34 build (client 11941D80, components 8c307604; 15 Nov 2026).** At 100 agents: `capacity-agents-headless` PASS 22/22 (9/9, peak 78) and
`netlab-rewind-fire` PASS 32/32 (5/5, rewind store seen executing: character 20, store 26D5F4CB8 inside the layout array), line `agents=100 characters=118
map_start=134 parts=8192 patches=1289 caves=92` (a33: 1252 patches, 86 caves; the difference is the mask caves, the new probe cave and the CG_SetNextSnap frame
grow). A plan-time start at 232 agents on a headless server (no zombies, stopped after the plan's 3 seconds): accepted, `agents=232 characters=250 map_start=266
parts=8192 patches=1284 caves=92`, frame grow lines 15,584 / 3,328 / 6,656 / 32 bytes. NOT measured: any run with zombies or a client above 100 agents; whether the
indexed-access and rbp assumptions of the CG_SetNextSnap plan hold when the snapshot code runs with more than 100 characters (it runs at 100 in w4).

## Replicated state budget (a39, 15 Nov 2026)

The wall at about 100 zombies was not an agent index. `ScriptableSv_LinkReservedScriptable` (sub_140BF96A0) keeps the state of every reserved scriptable
instance (one per zombie) in one block of 1,016 dwords, four one-byte part states each (bit 7 = dirty): the fixed (Radiant) parts take `ceil(parts / 4)`
dwords from the bottom (557 parts of cp_zmb = 140), every reserved instance `ceil(replicated parts / 4)` from the top (the 31-part zombie scriptable 8, the
28-part one 7, the 23 stock instances 1 each; measured in runs d2 and d2b). When no room is left it raises ERR_DROP "Too many replicated parts. 557 from
'fixed' ..." at about 136 instances; the shutdown walk then crashed reading the null state buffer of the half-linked instance (below).

With `-agent-capacity n` the budget is S = 1,016 + 8 (n - 24) dwords (S - 1,016 is a multiple of 32 at every accepted count: the engine's unrolled 0x80 byte
block copies keep their 0x68 byte tail, only their loop count `mov ecx, 0x2f` changes to 47 + (S - 1,016) / 32). The block (`u16 fixed count | dwords[S] |
u16 instance count | u16 entnum + 1[512] | u16 start dword[512] | pad` = 4 S + 0x808 bytes, stock 0x17E8) and everything that is a function of it:

| Object | Stock | Now | Rows |
|---|---|---|---|
| server block 0x1460A8BE0 | 0x17E8 | `state_a`, 4 S + 0x808 | 42 rip/rva references |
| byte list table 0x1460AC3A0 (6 bytes an entry a state BYTE, sentinel 0xFE0 = none, heads at +0x5F40) | 0x5F4E | `state_c`, 24 S + 14, sentinel 4 S, heads at 24 S | 21 references, 7 head offsets, 7 sentinel loads, 7 `0xFE00FE0` dword inits, 3 sizes |
| client static blocks 0x146030250 / 0x146031A40 (8 byte trailer each, stride 0x17F0) and the empty block 0x1421EDA70 | 0x17E8 | `state_client` (two T + 8), `state_x` | 22 references |
| server rings (frames x block, DAT_146B39908 / 0x...10 / 0x...18), client ring (cl+0x11C68) | stride 0x17E8 | stride T | 29 `imul`/size immediates, 1 `0x17E2` clear |
| unrolled block copies (CL_ParseSnapshot x2, bd1e10, bd3600, c625b0, c636a0, c63bd0, c647a0) | 47 loops | 47 + (S - 1,016) / 32 | 8 |
| the budget compare / top (`mov r, 0x3F8`) in the link, the writer and the reader on both sides | 0x3F8 | S | 8 |
| table offsets 0xFE4 / 0xFE6 / 0x13E6 in the delta reader, writer, baseline copy and the client apply | | + 4 (S - 1,016) | 45 |
| server hunk size (sub_140C68880 folds the one block of SV_AllocSnapshotBuffers into 0x2CEB00 / 0x6CEB00) | + 0x1800 for the block | + (T rounded to 0x80) - 0x1800 | 2 (found by the first run: with the block grown and the hunk not, the server stopped at "Loading zone") |
| client snapshot member (+0x3AF38, 3 instructions) | slot inside the stock snapshot | behind the appended agent states: 0x3DC78 + 0xC0 n | 3; `snap_size()` grows by the block |

The list is generated, not remembered: `ops/engine/state_sites.py find` decodes every function of the reading ranges of the shipped image (engine database),
`state-sites.json` is the table (one row a 4-byte field: address, instruction bytes, stock value, op), `emit` writes `src/native/agent_capacity_state.inc`
that `plan_state()` applies in the same all-or-nothing transaction (plan-time refusal when any field differs from its stock value),
`tests/ops/agent_capacity_state_test.py` re-encodes every row for every count 24..232 (displacement, immediate or reference target decoded back) and checks no
row overlaps another patch or a cave. Wire: the state delta writes the fixed region's dword index in 9 bits, the instance's dword count in 8 bits and an
instance's dword index in 9 bits RELATIVE to its start, the entity number as u16 (sub_140BF6760 / sub_140BF6230): no width holds the budget, nothing on the wire changes.

Not patched: the save-game serializer sub_140C70A50 (copies the block into a fixed slot of DAT_146B4DF48: it copies the stock size, harmless, a
checkpoint of a grown block would be incomplete; a zombies match never runs it) and the fixed-parts capacity of sub_140BFA3A0 (0xFE0 / 0x7E0), which is
not the instance budget. **A separate limit remains: reserved scriptable RECORDS** (`[[0x145D5F9D8] + 0x244]` = 200 on cp_zmb, 0x1D0 bytes each in
map-loaded memory): 24 stock + one a live agent, so about 176 agents alive at most; 177 or more raise "Could not allocate a reserved scriptable ... limit is 200".

**Measured (components 0c9452c5, client E9DC32601FA39839, 15 Nov 2026; runs in `IW7-Runtime/capacity/runs/r1..r4`):**

| Run | What | Result |
|---|---|---|
| r1 | `capacity-agents-headless`, 100 agents | PASS 22/22, 9/9, peak alive 78; state 771 of 1,624 dwords at the peak (140 fixed + stock + 78 zombies), 103 instances |
| r2 | `netlab-rewind-fire`, 100 agents, one joined client | PASS 32/32, 5/5 |
| r3 | 12-minute headless soak, 164 agents, alive 132 | PASS 168/168, 30/30, no ERR_DROP, no crash: peak alive 132, alive minimum 129 to 132 in the 25 windows, 164 instances at the peak (the old wall was 136), state 1,220 of 2,136 dwords, parts 4,137 of 8,192 |
| r4 | 12-minute network soak, 164 agents, alive 132, one joined client | PASS 148/148, 41/41, six frames answered, no engine error, no script error, no crash; entities in one client's snapshot at most 666 (cap 768, never reached), the client 113 to 115 fps mean (1 % low 43 to 49) against 153 at 24, the server 23 to 26 ms a frame mean with the client joined (p99 30 to 35) against 9 at 24, 9 to 10 kB/s down |

A first r3 (r3a: 29/30) failed only `u132.agents ge 132` (130 alive): the once-only quota raise of `cap_hold` was eaten by 6 deaths of the climb (plan fault, fixed in the
plan library, server PR). The first build of this change stopped the server at "Loading zone" before the map started: **a constant folded from a sum is not an `imul`**.
`sub_140C68880` (the server hunk size) adds the one 0x17E8 block of `SV_AllocSnapshotBuffers` as part of 0x2CEB00 / 0x6CEB00 (0x2CD300 + the block aligned to 0x80, 0x1800);
the scan for 0x17E8 never saw it. Found by reading the size function against the allocation function; when a block is allocated, find the function that sums the
allocations. Not measured: the shutdown guard itself (no run raises the ERR_DROP any more; the cave is decoded offline and was built into every client of r1 to r4 without a
fault), n between 100 and 164 (the sites test covers every count 24..232 offline), anything above 164, a second client.

**Shutdown guard (stock bug).** `sub_140BF5730` (the recursive walker of 0xB0-byte part records called for every instance by the shutdown free) compares
`byte [state buffer + part]` for type 2 records at +0xD2 (`cmp byte [rdx+rcx],bpl`, 0x140BF5802); the buffer is allocated by `FUN_140BE1770` AFTER the
replicated-parts check, so an instance that failed the check has a null buffer and the walk crashed at address 0x78 (runs d2, d2b). A cave
(`ops/engine/caves/shutdown-guard.*`, `agent_capacity_caves_guard.inc`) replaces the compare by a branch-free sequence that leaves ZF = 1 for a null buffer
(the `je` that follows is the stock branch for a zero state) and does not read memory then; `rcx`, `rdx` are dead after it, `r9`, `r10` volatile.

## Reserved scriptable records (a42, 15 Nov 2026)

The map's MapEnts asset (type 0x1b; the pool header S, 0x143686918 on cp_zmb, that the clipmap field `[0x145D5F9D8]` points to) keeps the scriptable records in a
block at S + 0x240: +0 total records (cp_zmb 523), +4 reserved records, indices [0, 200), +8 end of the server records (414), +0x10 the array (0x1D0 bytes a record, zone
memory). The values are zone data; no engine code writes them, and the ~130 users read them through the global fresh. A zombie's scriptable takes one reserved record,
so the stock block holds 24 + alive <= 200 (176 alive) and the engine raises "Could not allocate a reserved scriptable ... limit is 200" beyond it.
`link_mapents_stub` (agent_capacity.cpp 4c, detour of FUN_1403B8610, the zone's link step of the MapEnts reference) rebuilds the block right after the original returns,
when -agent-capacity n is given and `reserved < R(n) = max(200, n + 56)` (24 stock instances, n agents, 32 spare): `d = R - 200` copies of reserved record 0 are inserted after
the stock reserved ones into a new 64-aligned block, the old records from index 200 follow (the fixed records shift by d on the server and on the client alike), then +0x244 =
R, +0x248 += d, +0x240 += d and the array pointer change. The old block (zone memory) is left alone; our block is freed when the header no longer points at it (the next zone
load rewrote it). Client and server run the same code (both load the zone). Skipped (logged) when the block is already large enough (R(100) = 200). Guards, logged at the
first link: a) the stock reserved records are byte-identical (200 of 200 equal to record 0 on cp_zmb; else a fatal error before anything moves), b) the caller of
the link step (the clipmap's `FUN_1409FAF00` at 0x1409FAFB3, return 0x1409FAFB8, was the only call of a headless server load; the asset's own caller FUN_140A35E50
@0x140A35F00 did not run), c) the width of the entity-state field 0x78 (record index + 1 of a fixed scriptable, FUN_140BF85C0; entity type 6, net field list
0x141BB6480, descriptor {0x78, 10 bits}, read at run time from the list table 0x141BB3B20): 10 bits hold 1,023, the largest value is 523 + d = 611 at 232; refused when it
does not fit. Part links follow the count: `scriptable_parts(n)` = max(8,192, 2,048 + 32 n + 1,024 rounded up to 1,024). Test: tests/ops/agent_capacity_records_test.py.

Run a42-h2 (headless soak, n = 232, alive 200): the move happened at the first load (`200 -> 288 reserved (88 added), total 611, server end 502`, meter instances_cap 288,
parts_slots 11,264) and the soak climbed to 186 instances (24 stock + about 162 zombies, parts 4,873, state 1,406 of 2,680) before the next limit stopped the
server at 195 s; so the record wall (176 alive) was not yet reached and the move is not stressed past 200 records.

### Stored record indexes (a44, 15 Nov 2026): the move remaps what the zone data names by index

**The cause of the a42 move's client crash, proven.** The p3a client dump (access violation, read 0x18, 0x140BD8BDB = FUN_140BD8B40 + 0x9B, `[record + slot * 0x98 + 0x80]` NULL) holds the record pointer in
r14 = 0x12ADB79500; the client log of the load that crashed (the frontend, "scriptable records 58 -> 288 reserved (230 added), total 290 ... block 12ADB72840") names the block:
(0x12ADB79500 - 0x12ADB72840) / 0x1D0 = **60**, the frontend's old total (58 reserved + 2 fixed records). The stack of the crashing thread holds `maps/cp/cp_frontend.d3dbsp`:
the crash is the frontend zone load (the client's return to the frontend after the game), not the game map. The index is the u16 at +0x4C of a 0x70 byte part entry of the MapEnts
(FUN_140A87F00 type 4 -> FUN_140BD8B40(slot, part, u16 +0x4C, u16 +0x4E)); the engine reads a value at or above the total as "no record" and queues the event (FUN_140BD8B40, first
branch). The frontend stores 60 in all its 64 part entries (cp_zmb: 523 in its 64 events and the fixed record indexes 200 and up in its 108 links). The a42 move raised the frontend's total
from 60 to 290, so the stored 60 became record 60, an inserted blank whose client state block is NULL. The p3b (d = 162) crash zip of 21:12:29 was the same crash at the frontend
reload after the plan had ended; nobody had opened it.

**Field table** (the zone loaders FUN_1409FA490 / FUN_1409ED900 / FUN_140A41800 and every caller of the record accessors were read; the record index reaches an accessor from the entity
(`entity + 0x78` / `cent + 0x778` = index + 1, set at init: both sides shift alike), a loop counter, or this one stored field):

| struct | offset | width | meaning | after the move |
|---|---|---|---|---|
| MapEnts S | +0x170 / +0x172 | u16 | entry count of part group 0 / 1 | read |
| MapEnts S | +0x178 / +0x180 | ptr | arrays of 0x70 byte part entries (group = bit 0 of the part handle) | read |
| part entry | +0x00 | u32 | type: 3 = link to a record, 4 = event on a record (others: sound, fx) | read |
| part entry, type 3 and 4 | **+0x4C** | **u16** | **record index as authored**; a value at or above the total is "no record" | **>= old reserved: + d** (values above the old total too: they stay "no record"); below it stays; a value that cannot take + d inside a u16 stays |
| part entry, type 4 | +0x4E | u16 | event index (not a record index) | unchanged |

Read and not record indexes: S+0x188..0x1A0 (0x48 byte entries: positions), S+0x1A8..0x1C0 (0x38 byte runtime state), S+0x1D8 / 0x1E0 (built at run time), S+0x1F0..0x218, S+0x228,
S+0x238, S+0x310.., S+0x338; inside a record (0x1D0): the definition pointer, the entity copy at +0x20..0x38, the sub-blocks +0x80 / +0x118 / +0x1B0 / +0x1C0 / +0x1C8 (part lists, names).
Tables indexed by record index are filled by the init loops after the move (server B table 0x1460AA3D2, client 0x14602E282, 4,064 entries).

**The remap** (agent_capacity.cpp 4c, `remap_part_records`, same load step as the move): every type 3 and 4 entry of both groups with a value >= the old reserved count takes + d (the hpp
function `remapped_record_index`). One log line a zone (`map ents remap: map <name>, d, entries, shifted, kept, ...`) says what was found: frontend (d = 230 at n = 232): 64 events, all
60, shifted beyond the records 64, "left as authored these would have named an inserted blank 64 times and turned from no record into a record 64 times"; cp_zmb (d = 88): 108 links shifted to
fixed records, 64 events (523) shifted beyond the records; (d = 20 at 164: same entries). Self checks in the same line: `entries naming a fixed record without a client state block`
(the exact condition of the crash; 0 on every load) and `stale pointers into the old array` (a scan of the zone block that holds the old array, at most 1 GB, the new block and S: one
value was found at +0x10 of a copy of the block header, the zone stream's own copy that the loader read S + 0x240 from; it is rewritten like S, so none points at the old array).
`-agent-capacity-no-record-remap` (or the variable `IW7_AGENT_CAPACITY_NO_RECORD_REMAP=1`) leaves the data as authored: it reproduces the a43 fault on purpose.
Tests: tests/ops/agent_capacity_records_test.py (the remap against the move for every n 24..232, on cp_zmb's and the frontend's numbers; the dump arithmetic).

### Sentient handle head table (a44)

The m1 run at n = 232 (and p3a before it) crashed the SERVER at the map restart that follows "GAMEENDED" (the lab joins, the match ends, `Restarting map`, the client joins again): read of 0xFFFF...
at 0x140AE9ACD in FUN_140AE9A80 (the free of a sentient: it walks the handle list `head = u16 [0x145C64BA0 + 2 * slot]` and clears every node). The stock table holds 71 entries (the clear
FUN_140AE99F0 writes 0x8E bytes); the next object, at 0x145C64D00, sits right behind it, so from slot 176 on the table reads and writes that object. The dump's sentient pointer was slot 178
((0x150496F50 - 0x150490010) / 0xA0), the head it read 0x13FF = the neighbour's field at 0x145C64D04 (and the same registers in both dumps). With 164 agents slots up to 205 existed but the
neighbour held zero at that moment, which is why p3b passed. The component moves the table to its own block of `sentient_slots()` u16 entries (four sites: 3 `lea`, the clear size), tests/ops/agent_capacity_sites_test.py checks them against the shipped bytes.
The node list behind it (`ENT_HANDLE_COUNT exceeded - increase size`, FUN_140AE9860, 4,096 nodes at 0x145C53B90) was not measured at 232 agents.

## Character proxy list (a47, 15 Nov 2026)

**What it is.** The client keeps, for each local client, a list of the characters whose physics it mirrors: an entry is one DISTINCT client entity (a `centity`) of eType 1 (player), 18 (agent), 20 (actor) or 6 with the
word 1 at `centity + 0x7D8`, active in the snapshot (`centity + 0x810 & 1`), with two physics "character proxies" (FUN_140552A60 creates them with `FUN_140550280(world, body, material, "character proxy")`, material
"PM_Flesh", worlds 3 * client + 2 and + 4). It is not a sound list (the a44 name was a reading of the callers). Append FUN_1405527E0 (four callers, in FUN_1402E7230 and FUN_14086CD50 for every entity of a new snapshot;
each asks FUN_140552DB0, a linear search of the list for the pointer, first: one entry a centity), lookup FUN_140552D20 (unrolled five at a time), per frame removal and compaction FUN_1405532D0 and FUN_140552DF0
(drop the entities that are inactive or of another type), free FUN_1405531A0, clear FUN_140552950.

**Why it crashed.** The stock tables hold 140 (0x8C) entries and are consecutive in the data section: the pointer table T0 (0x144B473C0, 0x460 bytes) ends at the counts (0x144B47820, four u32; only client 0 is reachable, the
tables hold no second client), then T1 0x144B47830 (two 0x18 byte transforms an entry), A 0x144B49270 and B 0x144B49B30 (two physics objects each, 16 bytes an entry), T3 0x144B4A3F0, T4 0x144B4A850, T5 0x144B4ACB0,
T6 0x144B4B110 (two u32 each), end 0x144B4B570 where another subsystem starts. The 141st append wrote T0[140], which is the count word itself; FUN_1405532D0 then read it as a pointer (`test byte [rcx + 0x810], 1`,
0x140553367, read 0x810) with 150 alive agents (run a44-m2).

**The maximum, from the code.** Distinct centities only. Players and agents are entity numbers below `characters` (250 at n = 232), actors come from a pool of 0x26 = 38 (FUN_14044ED70), the corpse entities (eType 2 and 19: 8 + 8
from `characters`) are not in the filter, and the eType 6 entities are script driven: there is no tighter hard bound than the entity space. CG_SetNextSnap's entity masks are `uint[64]` = 2,048 bits and 0x7FF is "no entity"
(FUN_14086FBA0, FUN_14086CD50), so at most 0x7FF - 16 = 2,031 entries whatever n is. The lookup steps five entries at a time, so the size is rounded up to a multiple of five: **2,035 entries**, 120 bytes an entry across
the eight tables (244,200 bytes). A function of n would be a guess for the eType 6 entities; the entity space is the count of the table the entries come from.

**The change.** `plan_proxy_list` (agent_capacity.cpp 4e) moves the eight tables into one block (the first 140 entries copied; the counts stay) and edits 92 four byte fields in place, from `agent_capacity_sound.inc`
(`ops/engine/sound_sites.py find | check | emit` over the analysed image, `sound-sites.json`): 67 table references (11 rip, 56 image-base disp32, 4 of them the `table - 4 + index` form of the compaction loops), 19 immediates
`0x8C` (16 `imul`, 2 `cmp`, 1 `add`), 1 `0x118` (2 x 140, the client stride of A and B), 2 `0x460` (8 x 140, the client stride of T0), 3 `+-0x8C0` (16 x 140, A to B). Completeness: the instruction index of the whole image holds
no other field naming 0x144B473C0..0x144B4B570 in live code (the only hit outside the ten functions is data decoded as code at 0x14C16AE5C), the multiples of 140 were looked for in the ten functions only (the callers pass
indexes, never a table or a stride), and the three coincidences (`[rsp + 0x118]`, `test [rcx + 0x690], 0x401` twice = 12 x 140) are excluded by name. FUN_1405532D0 has two stack arrays under its cookie, `u32 selected[140]`
(rsp + 0xC0) and `140 x 16` bytes (rsp + 0x2F0, the quaternions of the transforms): its frame grows at the cookie by 37,904 bytes (the cookie, the rbx home slot, `add rsp`, the page probe cave of `sub rsp` with 10 probes, ALLOC_LARGE,
SAVE_NONVOL and the GS cookie offset: 7 fields and the cave, `cave_plan.py frame-grow --function 0x1405532D0 --array-top 0xBB0 --extra 37904 --bounded-index 0xC0:0x2F0 --rbp-general`), and the second array moves up by the 7,584 bytes
the first one gains (the displacement of the three `lea` of its base; the test proves that no other rsp access lies between 0x2F0 and 0xBB0). Frame grow needed one tool change: with `--rbp-general`, `lea rbp, [rsp + d]` is an ordinary
pointer production (the function uses rbp as a general register and also takes cursors into the array). Tests: `tests/ops/agent_capacity_sound_test.py` (10: formulas, size against every count 24..232, rows against the shipped bytes,
every re-encoded value, the frame layout and the overlap with every other patch). The component logs the list length when it passes 140 and at every further 10 (`character proxy list: N entries`).

## Scriptable stream buffer pools (a43, 15 Nov 2026)

Run a42-h2 (n = 232, 200 alive) stopped at 195 s with ERR_DROP "ScriptableSv_LinkReservedScriptable: Could not allocate Stream Buffer of 148 bytes". Every reserved
instance copies `def+0x40` bytes of state into one block taken by FUN_140BE1770 (alloc; ScriptableSv_LinkReservedScriptable calls it at 0x140BF99CC with the size in r8d) from five
static pools: block sizes 16, 64, 256, 512, 3,072, stock counts 128, 128, 64, 32, 32. A pool is an array of blocks and, right behind it, an 8 byte free-list head (an empty list holds
the head's own address; allocation pops the head). FUN_140BE1970 picks the smallest class whose limit (u32[5] at 0x14150B900) holds the request and whose list is not empty, so a
148 byte state takes the 256 class and then the 512 and 3,072 classes: 64 + 32 + 32 = 128 blocks. FUN_140BE1E50 frees (the class is found by FUN_140BE1B20, address range tests; the
alignment tests are relative to the array base). Static initialisers (CRT) chain every array: 0x14001A3D0 + 0x40 * class (server), 0x14001A240.. (client); they have already run when the component patches (run a43-p1: the relocated heads were still null and the first allocation read address 0 at 0x140BE1917), so the component chains the new arrays itself (`chain_pool`: block i points at block i + 1, the last at the head, the head at block 0) and edits the initialisers' fields only so that the meter and any re-run see the new arrays.

Table (the server's arrays are BSS between 0x146041310 and 0x1460A8BE0, in-use counters int at 0x146043318 + 4 * class and, for the client, 0x1460A8BB8 + 4 * (slot + 2 * class) stay in place):

| class | block | stock | server array, head | client slot 0 array, head | client stride |
|---|---|---|---|---|---|
| 0 | 16 | 128 | 0x1460A83B0, 0x1460A8BB0 | 0x14604F350, 0x14604FB50 | 0x808 |
| 1 | 64 | 128 | 0x146041310, 0x146043310 | 0x146088380, 0x14608A380 | 0x2008 |
| 2 | 256 | 64 | 0x146043330, 0x146047330 | 0x146047340, 0x14604B340 | 0x4008 |
| 3 | 512 | 32 | 0x14608C390, 0x146090390 | 0x146080370, 0x146084370 | 0x4008 |
| 4 | 3,072 | 32 | 0x1460903A0, 0x1460A83A0 | 0x146050360, 0x146068360 | 0x18008 |

**The client runs the same allocator** (flag 0, slot index 0 or 1: its two static state blocks A1 and A2 each own a set of pools; callers FUN_140BD1450, FUN_140BD91A0, free
FUN_140BD93D0), so the component relocates both. No pool index leaves the pool: nothing is a bitmap, a u8 or u16 index or a network field; a pool is qword links and address range
tests, counters are int. So no width limits the count. Instruction fields: `ops/engine/pool_sites.py` decodes the two code ranges that hold them (the initialisers at 0x14001A240..0x14001A510,
which belong to no function, and the four allocator functions 0x140BE1770..0x140BE1FF8) into 132 rows (`pool-sites.json`, `agent_capacity_pools.inc`): 62 server head, 10 server
base, 20 client head and 5 client base rip references, 25 strides (`imul` / `add` imm32) and 10 array sizes (`lea` disp32, some negative). The instruction index of the whole image has no
other field that names the region in live code (32-bit constants that look like addresses, e.g. `mov r9d, 0x60588F0` in 150 functions, and data decoded as code, are not references), and no
aligned qword of any section points into it.

The component (agent_capacity.cpp 4d, `plan_pools`) allocates every pool with `reserve()` (within 2 GB of the image) and edits the 132 fields in place: a base to the new base, a head to
new base + array, a stride to array + 8, an array size to the new array bytes. Size: `stream_pool_blocks(n) = max(512, R(n))` blocks in EVERY class (512 x (16 + 64 + 256 + 512 +
3,072) = 1.97 MB a set; the server one set, the client two slots). Reasoning, not a margin: an instance holds at most one buffer and there is one reserved record for each instance
(R(n) = 288 at 232), so no class can run out; the part state tables hold at most 512 instances as well. The map's reserved record count is checked at load (a fatal error when
it exceeds the blocks). Guard bytes around every pool are checked every 500 ms with the other relocated tables. Tests: tests/ops/agent_capacity_pools_test.py (every n 24..232, every
row against the shipped bytes, every new value re-decoded, the heads one array behind the bases, no overlap with another patch).
The budget meter reads `pool_caps` (from the initialisers' code fields) and `pool_used` (the engine's counters) and writes `pool_peak` in the summary.

### Runs (15 Nov 2026, headless `capacity-agents-headless` / `capacity-agents-soak-headless`, n = 100 / 232, meter `pool_used` per class)

| run | what | result |
|---|---|---|
| m1 | old client acc703af (stock pools), n = 164, alive 132, 28 min | PASS 168/168, 30/30; at 164 instances 134 blocks in use at the busiest sample (class 0: 23, class 2: 64 = full, class 3: 32 = full, class 4: 15), per-class peaks 41 / 0 / 64 / 32 / 22: a zombie's 148 byte state takes one block of the 256 class, then the 512 and 3,072 classes; the 28 part type a 16 byte block |
| p1, p2 (first build 9913b2ea) | n = 100 / 232 | server crash 27 s after the start, access violation (read 0) at 0x140BE1917 (alloc popping the head of the relocated class 0): the CRT initialisers had already run, the new heads were null. Fix: `chain_pool` (commit 350d5d9c) |
| p1b | n = 100, 78 alive | PASS 22/22, 9/9, peak alive 78; 103 instances, 79 blocks (class 0: 18, class 2: 61) |
| p2e | n = 232, alive 150, soak | PASS 168/168, 30/30; 182 instances, class 2 holds 130 blocks (stock 64), state 1,360 of 2,680, parts 4,686 of 11,264 |
| p2b, p2c, p2d, p2f, p2g | n = 232, alive 200 (p2b, p2c, p2d) and 190 (p2f, p2g) | all five stop at 196 to 198 instances (the stock pools stopped the same plan at 186): the server thread blocks forever in a message box, game time stops, the main thread keeps looping; next limit below |

| p3b (network lab, joined client) | n = 164, alive 132, soak 1,084 s, `netlab-capacity-soak` | PASS 148/148, 41/41 (join 58 s): 164 instances, 151 blocks (class 0: 36, class 1: 1, class 2: 115); client 108 to 110 fps mean (1 % low 41 to 47), server 26 to 29 ms mean (p99 34 to 39), snapshot entities max 665 of 768; a record move of 20 happened (200 -> 220) |
| p3a (network lab) | n = 232, alive 150 | PLAN_CRASH: two crashes in one run: the SERVER at the map restart after "GAMEENDED" (FUN_140AE9A80, the sentient handle head table, fixed in a44) and then the client in the frontend zone (FUN_140BD8B40, record 60 = the frontend's old total: a stored "no record" turned into a blank record, fixed in a44); the first reading of this row ("the CLIENT crashed 18 s into the game") was wrong: the client had left the server 350 ms after the first join, the lab's own restart followed. See "Stored record indexes" |
| p3c (network lab, `netlab-rewind-fire`, -AgentCapacity 232) | frontend zone | the client crashed while loading `common_cp`: the move also ran on the frontend's MapEnts ("scriptable records 58 -> 288 reserved (230 added), total 290") |

**A fault of the record move (a42), found by the network run of a43 and fixed in a44:** the cause and the field table are in "Stored record indexes". What a43 wrote here (a stored index below the shift names an inserted copy; "remap the part event tables ... not done in this change") was right in kind and incomplete: the proven crash is the stored value 60 that means "no record" and became a record when the total grew.

**Next limit: the script variable pool of the GSC VM, "Exceeded maximum number of script variables (children)".** A frozen server (p2f, 196 instances) had its server thread in
`MessageBoxW` (FUN_140D57730 called by the fatal-error function FUN_140D34180(format) at 0x140D3420E, the text sits in that frame; string 0x14150DD98 is used by the allocators FUN_140C045B0 and
FUN_140C05760): the child variable pool `DAT_146756180` (entries of 0x18 bytes, u16 prev/next at +0/+2, type byte at +0xA; the free list head of a segment is entry 0's +2) is
**4 segments of 0xA000 entries** (init FUN_140C09280, loop `iVar6 < 4`; u16 indices inside a segment; per segment in-use counters int[4] at 0x14665A134) and segment 1 was empty (free head 0,
40,959 of 40,960 used; the others 40.2k to 40.3k). A healthy server at 150 alive stood at 37.7k to 38.0k a segment (92 %), so the pool is nearly full with 150 zombies and full a few dozen later; the script variable ids partition
the id space (`< 0x40000`, `< 0x4DC00`, `>= 0x800000` in FUN_140C05760): growing it is a job on the variable id layout (more segments or larger ones, every `* 0xA000` / `/ 0xA000` site,
the 0x20000 byte clear at 0x146736180 and the user functions FUN_140C04990, FUN_140C053A0, FUN_140C09280, FUN_140C08C30 ...). Not designed yet.
The headless runner hid it for 35 minutes (the message box blocks the server thread on a hidden desktop; no engine error text, no dump): a lab server now starts with `+unattended` (FUN_140D57730
reads it from the command line and skips the box), so a fatal error ends the process at once (p2g: exit -1 after 207 s, verdict `GAME_EXITED` at the step instead of a 2,130 s wait).


### Runs of a44 (15 Nov 2026, private loopback; lab clients built from components 618e4d38 = the remap, cc20b5c4 = + the sentient table, edc8976c = the final head)

| run | shape | result |
|---|---|---|
| m1 (618e4d38) | `netlab-rewind-fire`, n = 232, joined client | the SERVER crashed at the map restart (FUN_140AE9A80, sentient slot 178, same registers as a43-p3a); the client went through the frontend zone twice with the remap and did not crash. The plan's expectation "engine_agents eq 100" was a plan fault at 232 (now a plan parameter `capacity`) |
| m1b (cc20b5c4) | same, `-PlanSet capacity=232` | PASS 32/32, 5/5 (join 57.9 s, 296 s in all); no crash zip; frontend, cp_zmb and frontend loads each remapped |
| m1c (edc8976c, final head) | same | PASS 32/32, 5/5 (join 71.8 s, 317 s); the stale scan reads 0 in the zone block and 1 rewritten copy of the block header |
| m2 (cc20b5c4) | `netlab-capacity-soak`, n = 232, alive 150 | CLIENT crash 0x140553367 in FUN_1405532D0, read 0x810 (a record pointer 0): the per-client list of the character sound code holds 140 entries (0x144B473C0, count 0x144B47820), `FUN_1405527E0` appends without a bound, the loop was at entry 141 (rsi = rdi = r12 = 0x8D) with 150 alive agents. Not this change: see "Next limits" |
| m2c (edc8976c) | same, alive 130 (`capacity=232,alive=130,amin=126,until_s=300,session_s=1800`) | PASS 148/148, 41/41 (join 70.5 s, 1,075 s in all); peak alive 130, 162 instances, 110 blocks of class 2, parts 4,133 of 11,264, state 1,216 of 2,680; entities in one client snapshot at most 673 of 768 (never capped), 541 at 24; server 26.9 to 31.9 ms mean (p99 41 to 46) with 130 alive, 8.5 ms at 24; client 98 to 105 fps mean in the first two windows, 55 to 66 in the middle ones, 127 at the end: other sessions (this work's m3 runs, another agent's client) ran on the machine, so these frame rates are not a clean measure; motion: the stock-speed 24 stay at jerk 0.020 to 0.051, the 108 agents of the high group 0.021 to 0.051, stutter 0.5 to 3.5 % |
| m3 (618e4d38), m3b (cc20b5c4) | `capacity-agents-soak-headless`, n = 164, alive 132 | PASS 168/168, 30/30 both (d = 20: the move and the remap on cp_zmb) |
| m3c (edc8976c) | same | PASS 168/168, 30/30 (peak alive 132, 164 instances, 117 blocks of class 2, parts 4,119, state 1,215 of 2,136) |
| ab2 (cc20b5c4, `IW7_AGENT_CAPACITY_NO_RECORD_REMAP=1`) | `netlab-rewind-fire`, n = 232 | the switch worked (log: "NOT remapped (switch)"), the run PASSED 32/32 and the client did not crash: the A/B did NOT reproduce the a43 crash in this one run. The part events apply when the frontend's emitters are in range, which depends on the scene the client is in; a43-p3a, p3b and p3c all crashed there with the record 60 of the frontend block (p3b: (0x12B2326400 - 0x12B231F740) / 0x1D0 = 60, p3c: r14 0x135634D00 minus 27,840 = a 64 aligned block) |

**Next limits found by these runs (not changed):**

1. (closed by a47, see "Character proxy list" and "Runs of a47") The per-client list of character proxies, formerly called the looping character sound list: 140 entries (`0x144B473C0`, count `0x144B47820`, `FUN_1405527E0` adds without a check; parallel tables of 140 x 2 entries `0x144B49270`, `0x144B4A3F0`, `0x144B4A850`, `0x144B4ACB0`, `0x144B4B110`; update loop FUN_1405532D0 has stack arrays of 140 (`local_b38[140]`, `local_908[2240]`), stop function FUN_1405531A0). Alive agents above about 140 crash the client (m2: 150 alive). The change needed: relocate the tables to `characters` entries and grow the frame of FUN_1405532D0, or bound the append.
2. `ENT_HANDLE_COUNT` (4,096 nodes at `0x145C53B90`, FUN_140AE9860), not measured at 232 agents.
3. The GSC child variable pool (a43), unchanged.



### Runs of a47 (15 Nov 2026, private loopback; lab client built from components 69859d35 with the switches ServerModules, IsolatedLab, Debugger, Perf, AgentCapacity)

| run | shape | result |
|---|---|---|
| k1c | `netlab-capacity-soak`, n = 232, alive 150 (`capacity=232,alive=150,amin=146,until_s=300,session_s=1800`), joined client | **no client crash**: 148/148 steps, 0 findings, 37/41 expectations, 1,081 s in game. The client log shows the list passing the stock 140 (`character proxy list: 141 entries`) and reaching 150 to 159 entries (a line every 10) with 150 alive agents, exactly where a44-m2 died. The four failed expectations are the alive floor of soak windows 2 to 5 (124, 29, 60, 120 alive against 146): the GSC child variable pool, the next limit (below). Snapshot entities per client at most 694 of 768 (never capped); client 101 to 110 fps mean in the soak windows, server 25 to 33 ms mean; 150 alive reached (peak alive 150), 182 instances |
| k2c | `capacity-agents-headless`, n = 100 | PASS 22/22, 9/9 (peak alive 78) |

**The next limit, captured (k1c, `budgets.jsonl`):** the script child variable pool. The fullest of the four segments held 38,500 to 39,333 children of 40,959 for the 12 minutes of the soak (96 %); the instances stayed at 181 to 182 while the alive count fell to 29 (window 3) and 55 (end), the `Exceeded maximum number of script variables (children)` wall of a43/a45 (FUN_140D34180, pool at 0x146756180); parents 12,847 of 14,079. Not changed here: a46 (variable pools, `script_variables.cpp`) owns it. The entity list's own peak is 150 to 159 entries (2,035 capacity).

**A fault of the shared native tree found on the way (fixed in Build-Voice):** a first client was built into the tree `C:/w/a33-native` that another branch (a46) had used: its `script_variables.cpp`, left in `src/client/component` by its Compile-Check and its build, was compiled into the client although the checked-out branch does not have it (the client log printed `[script variables] ... 414 fields` with the switch AgentCapacity off, so the run measured two changes). Build-Voice now removes the capacity family (`agent_capacity*`, `script_variables*`) that its own checkout does not own from a kept tree before generating the project (`tests/ops/build_voice_foreign_sources_test.ps1`). Also: `Invoke-EngineLab -BuildOnly` without `-BuildSwitch` builds `ServerModules,IsolatedLab,Debugger` only, a client WITHOUT the component: capacity runs need `-BuildSwitch 'ServerModules,IsolatedLab,Debugger,Perf,AgentCapacity'`.

## Snapshot entities (a49, 16 Nov 2026)

One client snapshot carried at most 768 entity records (`sv_maxSnapshotEntities`, the server's DAT_146B3985C); the 200-alive run a48-j1b reached 746 of them (3 % margin), so
specials, bosses and a bigger map would have ended the match: `sv_errorOnMaxSnapshotEntities` is registered with default 1 (FUN_140C55310, "end the game when reaching MAX_SNAPSHOT_ENTITIES"; an older note here said 0), so the 769th record is a `Com_Error` drop for everyone (run a49-c3g-old, the previous build, 400 flooded models: ShutdownGame at once; the same plan with the cap raised runs, below). With `-agent-capacity`
the cap is 2,048 on both sides and every buffer that depends on it is sized from it. `ops/engine/snapshot_sites.py` (`find`, `check`, `emit`; table `snapshot-sites.json`;
`src/native/agent_capacity_snapshot.inc`; planner `plan_snapshot`, test `tests/ops/agent_capacity_snapshot_test.py`) lists every field: 33 rows.

**Why 2,048 is "no cap".** The server's entity list ends with the number 0x7FF written in 11 bits (FUN_140C67230 at 0x140C6764B; the client reads it in FUN_1409B7C30), and a record is
an entity number 0..0x7FE, so no snapshot holds more than 2,047 records. No network field changes width: the count is never sent, the numbers stay 11 bits.

| Limit | Stock | With `-agent-capacity` | Where (field) |
|---|---|---|---|
| per client snapshot cap (`sv_maxSnapshotEntities`) | 768 | 2,048 | SV_InitSnapshotBufferSizes 0x140C68A00: `mov [146B3985C], 0x300` (imm at 0x140C68A3A); read only by the check at 0x140C67478 and the save-game writer |
| list A cap (the common entities, DAT_146B39858) and list B cap (the baselines, DAT_146B39860) | 1,024 each | 2,048 each | imm at 0x140C68A2E and 0x140C68A69 (read by FUN_140C64310, FUN_140C647A0, the allocation `DAT_146B39860 * 0x110`) |
| server entity-state ring (DAT_146B39810, records of 0x110 bytes; the baseline of a delta is a ring position, `FUN_140C6A0E0` drops a delta whose first entity left the ring) | frames x 0xA40 + clients x 1,024 (58,368 at 16 and 16) | frames x 6,464 + clients x 2,048 (136,192): the ring still holds 16 frames of four full snapshots | `imul r8d, ecx, 0xA40` (imm at 0x140C68A55) and `shl eax, 0xA` (the byte at 0x140C68A51 becomes 11) |
| server hunk size (FUN_140C68880) | `clients x 0x44000 + frames x 0xAE400` for that ring, `+ 0x45000` for list B and the 0xFF8 block | `clients x 0x88000 + frames x 0x1AD400`, `+ 0x89000` | imm at 0x140C688BD, 0x140C688C3 (one `imul` each) and 0x140C689E6 (an `add`); not folded constants this time (a39 had two) |
| client copy of the parsed records into the cgame snapshot (DAT_1421EDA6C) and the client baseline array (DAT_1421EDA68, 0x44000 bytes allocated at DAT_1421EDA60) | 768 / 1,024 / 0x44000 | 2,048 / 2,048 / 0x88000 | FUN_14034F3E0 end: imm at 0x1403504CC, 0x1403504DC, 0x1403504C2 |
| client parsed-entity ring (`cl + 0x11C08`, records of 0x110) | frames x 600 (`imul eax, r8d, 0x258`) | frames x 2,048 | imm at 0x14034F21F. Not a per snapshot cap (the client parsed 613 and 746 records into it already); it is how many snapshots stay readable as the delta source (`FUN_140992000` refuses an old snapshot whose first record is `0x11C08` records behind) |
| the cgame snapshot (the 0x3DC78 byte object, two of them, FUN_140864680): entity array of 768 x 0x110 at +0x4AB8 | in the middle of the object | behind the state block: `snap_entity_offset()` = `0x3DC78 + 0xC0 n + state_bytes()`, 2,048 x 0x110 bytes more in `snap_size()` | 21 instructions (`lea r, [r + 0x4AB8]` x 18, `add r, 0x4AB8` x 3), each a user of the array by its loop over the count at +0x18: CG_SetNextSnap (4), CL_ParseSnapshot (2 copies), 14 functions of the cgame; the completeness gate is the instruction index (every 0x4AB8 field of the image is a listed user or a listed field of another struct: 18) |

Not touched on purpose: the save-game serializer (FUN_140C692F0 / FUN_140C68F40 read and write the cap and the ring sizes of a save; not run in a match), the agent state rings (`n` agents a frame), the 0x17E8 state block (a39).
The server message buffer is 0x20000 bytes (FUN_140C67BB0): a delta snapshot of 2,000 entities is a few KB; a full one is bounded by the same buffer as before (measured with 1,100 new entities in one snapshot in a52, see Renderer lists).

**What the first live runs found (not part of the snapshot change):**
- The client crashes when about 800 `tag_origin` script models are in its snapshot: FUN_140E2D9D0 (a renderer draw command: `if (count + DAT_149FF3E18 < 0x401)` takes records from a 1,024 record buffer at 0x149FF3E1C, else reports error 0x9A and goes on with a null buffer) hands FUN_140E366C0 a null pointer (write at 0x140E36746, run a49-c3b and c3c). So the renderer, not the snapshot, is the next wall for DRAWN entities (a model behind the view is not culled before this list). An entity that is not drawn must be sent to test above that (a script_origin and a `hide()`n model are not sent: run a49-c3d, c3e).

### Runs of a49 (16 Nov 2026, private loopback; lab client built from components 4bbacee81e (main c758a9c + the snapshot change), switches ServerModules, IsolatedLab, Debugger, Perf, AgentCapacity, tree C:/w/a34-native: the tree of the usual builds was locked, see the ledger entry on `iw7-mod.pdb`)

| Run | What | Result |
|---|---|---|
| a49-c1 | `capacity-agents-headless`, n = 100 | PASS 23/23 steps, 11/11 expectations; the log line `[agent capacity] snapshot entities: cap 2048 (stock 768), lists 2048, server ring 6464 records a frame + 2048 a client, client ring 2048 a frame, 33 fields, cgame entity array at +0x448E0`; server up with the grown ring and hunk |
| a49-c2b | `netlab-capacity-soak`, 232 records, 200 alive (`capacity=232,alive=200,margin=2,amin=196,until_s=300,session_s=2400,refill_s=120`, the a48-j1b shape), one joined client, cap 2,048 | PASS 149/149 steps, 43/43 expectations (join 56 s, no stall); one client's snapshot at most 744 records (p04; 731 to 736 in the other 200-alive phases; the server and the client agree: 742 parsed), `capped` 0, the meter reads cap 2,048 |
| a49-c2old | the same plan with the previous client (components a3f2b0b1af, cap 768), run right after c2b on the same machine | PASS 149/149, 43/43; snapshot at most 748 of 768 |
| a49-c3g | `netlab-capacity-snapshot` (new: 400, then 60 script models behind the joined player), n = 100 | PASS 45/45 steps, 5/5 expectations: one client's snapshot holds 523 records (stock), 923 (+400), 983 (+460), 523 again after the flood is removed; the server and the client count the same, `capped` 0 at the cap 2,048; the client keeps 174 to 186 fps; 30 packets a second, 2.3 to 2.5 kB/s down |
| a49-c3g-old | the same plan with the previous client (cap 768) | the match ENDS at the flood step (ShutdownGame; `sv_errorOnMaxSnapshotEntities` is 1): the stock behaviour at 769 records |
| a49-c3b, c3c, c3f | the flood with more models (900, 800, 650 in all) | CLIENT CRASH in the renderer when the third stage (650 to 900 models, 1,170 to 1,420 records) was spawned (FUN_140E2D9D0 -> FUN_140E366C0, null write at 0x140E36746), see the renderer wall above |
| a49-c3d, c3e | the same with `hide()`n models and `script_origin` entities | PASS, but the snapshot stays at 923: neither is sent |

**What the larger buffers cost, same plan, same machine, one after the other (c2old against c2b, means of the six 200-alive phases):** client 95.7 -> 92.2 fps mean (1 % low 38.5 -> 37.7), server frame 39.7 -> 41.0 ms: inside the spread between two runs of one build (a48-j1b 102.7 fps / 34.2 ms, c2old 95.7 / 39.7 on the same plan; the other agents' sessions were on the machine), no cost measured. Memory (the recorder windows' `memory`): server private 1,287 -> 1,312 MB (+25 MB; the ring 58,368 -> 136,192 records of 0x110 bytes is +21.2 MB, list B +0.3 MB, hunk rounding) and working set 1,180 -> 1,204 MB; client private 15.98 GB (c2old) against 15.93 GB (c2b), working set 5.55 GB against 5.50 GB: nothing measurable (the analytic cost is 7.7 MB: parsed ring +6.3 MB, baselines +0.3 MB, two cgame snapshots +1.1 MB). In the first c2 (a49-c2) the client showed +155 MB and 35 to 82 fps: another three sessions of this work ran beside it; discarded.

**Not proven:** more than 983 records in one snapshot (the renderer ends the client at about 1,170, so the upper range up to 2,047 has no live proof; the server side has no limit left that was found below it, the snapshot message buffer is 0x20000 bytes; the delta snapshots of 923 and 983 records were 75 to 80 bytes a packet on average, the largest packet of the run 1,256 bytes); several clients at once (the ring is sized for 16 frames of four full snapshots); the save-game serializer; a listen server.

## Renderer lists (a52, 16 Nov 2026)

The a49 client crash above (null write at 0x140E36746) is a full 1,024 record list in the renderer; this section is what the list is, what else is limited beside it, and what the change is.

**What a record is.** FUN_140E2D9D0 and FUN_140E2FF80 are the draw commands of ONE dynamic model (a DObj: script_model, character, weapon world model; called from FUN_140E2D870 and FUN_140E2E720 for the entities of the scene, 3 callers: FUN_140145570 the entities, FUN_14007EB30 the scene model list, FUN_140D63D80 the view model with no record). `param_5` is a 0x3C byte blob built by FUN_140148910: byte 0 is the number of material parameter sets of the model (1, or 2 when the model has a second set: at most 2), each 0x14 bytes. FUN_140E366C0 copies them as records of 32 bytes (colour flags + five floats) into the list at 0x149FF3E1C (1,024 records, 0x8000 bytes, ends exactly at the next counter 0x149FFBE1C); the reservation is `lock xadd` on the count 0x149FF3E18 (reset to 1 each frame by FUN_140E311A0: record 0 is the "none" slot, so 1,023 usable), FUN_140E328E0 copies count x 32 bytes into the frame data (hook_renderer_148F73088 + 0x587184) and FUN_1400C13B0 into the mapped GPU buffer. So one drawn model = 1 record (2 with a second set): the a49 numbers agree (about 1,170 records at 650 flooded models + the stock 520 entities).

**The same draw command takes from three more fixed lists** (all in 0x149FFxxxx..0x14A0Bxxxx, per frame): the light records 1,024 x 0x1C (DAT_149FFBE1C, only for a model with a light/shadow flag), the draw records 1,024 x 0x90 (DAT_14A0B6640, allocator FUN_140E30C60) or, for the other pass, 512 x 0x590 (DAT_14A002E20). Those three are full-list safe in the stock code (`return` after the warning, the count clamped), the first list was not. The sort key of a draw record holds the light index in 10 bits (`& 0x3ff`) and the entity number in 12 bits (`(n & 0xfff) << 10`): the lights and the draw slots cannot be grown without re-cutting that key (and everything that reads it, FUN_140DDE800, FUN_140DDEFA0, FUN_140DDF3E0, FUN_140DE1940, FUN_1405F99C0 and the sort).

**Derived maximum.** One record or two for every drawn dynamic model; the models drawn a frame are bounded by the draw record lists above: 1,024 + 512 slots (and the lights 1,024), not by the 2,047 entity numbers. Growing only the parameter list to 4,096 records (2 x 2,047) would change nothing visible (the next list returns at 1,024 slots) and would need the GPU buffer, the frame data field and its copy re-sized (field +0x587184 of a frame data struct whose size is read by the static model lists of the client, `renderer.cpp`: `frame_data_records`). So the list is NOT grown: it is a limit of the renderer's draw record format.

**Change (in place, 31 + 30 bytes, test `tests/ops/agent_capacity_render_test.py`, `plan_render_list`).** The two stock overflow branches (`ja` after the reservation, 0x140E2DAA0 and 0x140E30046) are rewritten: the reservation is given back (`lock sub [0x149FF3E18], ecx`: the count never passes 0x400, so the frame copy stays inside its 0x8000 bytes), the warning 0x9A is still raised, and the function leaves by a short `jmp` to the `jmp` of its own lights overflow, which ends at the epilogue (the second function first stores r12 in the slot its epilogue reloads). A model that does not fit is not drawn; the client lives.

**Runs** (private loopback, lab client from components 27c455a6, switches ServerModules, IsolatedLab, Debugger, Perf, AgentCapacity, `-agent-capacity 100`): a52-e1 (plan flood 700 + 600 asked): the engine refused spawns at 1,703 entities (119 of the second stage: the map's entity numbers), the third snapshot held 1,703 records, no crash; a52-e1b (700 + 450): PASS 45/45, 5/5: 523 -> 1,223 -> 1,673 -> 523 records in one snapshot on the server, the client parsed 573 / 1,372 / 1,673 / 523 (parsed max above the server's in the window of a stage change, as in a49), capped 0, client 149 / 141 fps, frames answered. Before the change the same plan with 650 flooded models (1,170 records) crashed the client (a49-c3b, c3c, c3f).

**The meter (a52).** With `-paris-perf` the client wraps FUN_140E328E0 (once a scene, after every draw command) and reads the four counters; the capacity component counts the full-list warning by list id (a stub every one of its seven call sites calls; `agent_capacity::render_skipped(id)`). The perf window of every netlab phase carries `render_lists`: `lists.{params,lights,draws,draws_other}.{peak,mean,cap,skipped}`, `skipped.{total,max_scene}`; the phase rows of the result and the runner's printout show them, and a plan can demand `render_lists.skipped.total eq 0` (`net_expect`; the soak plan does, in every phase). Runs: a52-e1c (flood, same plan as e1b): stock 523 entities: params 588 of 1,024, draws 538 of 1,024, no skip; 1,223 entities: params full, 107,856 skipped models over the phase; 1,673: 783,850 skipped. a52-e5 (232 agents, 200 alive, joined soak, 8 phases, PASS 149/149, 43/43): params peak 581-584 of 1,024, lights 207-208 of 1,024, draws 337-339 of 1,024, other pass 243-244 of 512, skipped 0 in every phase. So 200 zombies in view use 57 % of the parameter list, 33 % of the draw records and 48 % of the other pass's records: the wall is about 350 more zombies-sized models in view of one frame, not a problem for the 200 + specials target, but every model of a big map's props counts too (the open job is in the quality ledger, `renderer-dynamic-model-lists-1024`).

**Snapshot message buffer (checked, not changed).** The snapshot is written into a 0x20000 byte message (MSG_Init in FUN_140C67BB0, FUN_140C67E40, FUN_140C68550; `FUN_140C69DF0(..., 0x20000)` compresses it). A message that overflows it ends only that client: FUN_140C68550 sends "disconnect" and `SV_DropClient(EXE_SERVERMESSAGEOVERFLOW)`; the netchan send refuses more than 0x20000 (FUN_140BB54C0, `Com_Error(1)`), and the client decompresses into a 0x20000 buffer ("Server message overflow", FUN_1409B8800). Entity record on the wire: the field table of FUN_140BC2C90 has 62 fields of at most 32 bits per entity type (31 types, 1,567 to 1,741 bits when every field is written), so the absolute worst entity is about 258 bytes with the number and the changed flags, 2,047 of them would be 528 KB: the buffer can overflow. Measured: 1,100 `tag_origin` models appearing in ONE server frame (all new to the client, written against the baselines: the size of a full snapshot of 1,100 entities; run a52-e2b, PASS 34/34, 3/3, 1,623 records in the snapshot) cost 36.5 KB on the wire in the largest second (compressed): about 33 bytes an entity, so 2,047 such entities need about 70 KB compressed, under 131,072 (the buffer holds the uncompressed message: at about 55 bytes raw an entity 2,047 take about 112 KB, 14 % room). Entities with more state than a model that has only an origin, angles and a model number (a zombie, a character, a vehicle) are bigger; the plan `netlab-capacity-fullsnap.json` measures the real size for any model (`-PlanSet model=<name>`). Not grown: no overflow was reached; the sites to grow it are the 0x20000 immediates of the functions named above, both sides (server msg, client decompress buffer, FUN_140BB54C0 check, and the compress call).

## GSC variable pools (a46, 15 Nov 2026)

`src/native/script_variables.cpp` (inert unless `-agent-capacity`; `-script-variables-stock` switches it off for an A/B run) moves the five tables of the script variable system
(docs in the server repository: `docs/SCRIPT-VARIABLES.md`) to component storage above the image and grows them: **children 4 segments x 0x10000 entries (local index 1..0xFFFF, 65,535 usable a
segment, 262,140 in all; stock 0xA000 / 40,959 / 163,836) and parent ids 0x10000 (ids 0..3 are the heads of the four id lists: 65,532 usable, 16,383 a segment; stock 0xDC00 / 56,316)**.
Tables: A (`0x14665A180`, u16 a parent id) and B (`0x146675980`, u16 a parent id: both only used by the savegame numbering), P8 (`0x146691180`, 8 bytes an id), P4 (`0x1466FF180`, 4 bytes an id), CH (`0x146756180`).
The hash buckets (`0x146736180`, 4 x 0x4000 u16) and the counters (`0x14665A134`) stay: the bucket function does not depend on the segment size (`(parent * 0x65 + name) & 0x3FFF + (parent & 3) * 0x4000`),
its chains only get longer (2.75 entries a bucket at 45 k children a segment).

**Widths, proven before the edit (test `tests/ops/script_variables_test.py`, `test_the_sentinel_scan_of_the_variable_system`).** Every link and index is a u16 loaded with `movzx` or stored with a word
move; no code of the variable system (0x140BFE000..0x140C11000, 357 functions) compares a link or an id with 0xFFFF or -1 (the only hits: the integer-key serializer `lea eax,[rbx+0x8000]; cmp eax,0xFFFF`, which
asks whether a value fits a short; the decrements `add ax, 0xFFFF`; AllocVariable's `cmp eax,-1`, an unsigned minimum search; loop counters `add edi,-1`) and no 16-bit compare is followed by a signed jump. So 0xFFFF is
a valid index and id: the free list of a segment ends by the entry whose next link is 0 (the initialiser writes `(j + 1) & 0xFFFF`, which is 0 for j = 0xFFFF, then clears it). Object key names are `0x40000 + parent id` (8 compares at
`0x4DC00`), integer keys start at `0x800000`: 0x50000 leaves the range clear.

**What is edited** (`ops/engine/variable_sites.py find`, 5 minutes over the analysed image and its instruction index; `check`, `emit`; result `ops/engine/variable-sites.json`, 414 + 119 + 28 rows, `script_variables_sites.inc`):
- 414 references to the four moved tables (`ref` rows: a rip displacement, or a displacement from a register that holds a known table address: image base, a table, or the counter block; new value = new target - new base).
  The code also addresses the tables from each other: `[p8 + 0xC5000]` (children), `[p8 + 0x6E000]` (P4), `[p8 + 0xA5000]` (hash), `[block + 0x80]` and `[block + 0x1B880]` (A, B): rows of the same kind. 4 rows have a base register that is
  defined on another path than the linear walk (FindVariable's bucket write-back, the move-to-front rows with `rax = P8 + 24 * index`): read by eye, marked `assumed` or in `OVERRIDES`.
- 119 segment base pairs in 84 functions (game code of the zombies scripts included: 0x1403E1000, 0x140AF49A0, 0x140B46E70, ... call the variable API with a base): `lea r,[s+s*4]` becomes `mov r,s` plus nops of the same
  length and the `shl r,0xD` after it takes 0x10: base = s * 0x10000.
- 28 constants: `cmp eax,0xA000` x2 (0x10000), `cmp ..,0xDC00` x5 (0x10000), `cmp ..,0x4DC00` x8 (0x50000), `mov eax,0xCCCCCCCD` x4 (the counter segment `base / 0xA000`; `0x80000000`: hi32(base * 0x80000000) >> 15 = base / 0x10000),
  `mov r8d,0x37000` x1 and `0x1B800` x2 (memset / copy sizes: 4 and 2 bytes an id), the `lea r,[r+0xC500]` idiom x4 (the distance P8 -> CH divided by 16: the next `lea` multiplies by 3, the access by 8) and `add rax,0x52800` x2 (the distance P8 -> hash buckets in units of 2 bytes: found by the first run, which hung: arrays were not linked into their hash chains).
- Unrelated and left alone: 10 constants inside the tables' address ranges in obfuscated or misdecoded code (listed under `rejected`, none inside the variable system), the `shl ebx,0xD` of FUN_140B3DD80 (a bitfield), ~18 other `shl 0xD`.
The VM initialisers have not run when `post_unpack` runs (the stock tables are all zero: checked; if they were formatted, the component calls FUN_140C09280 after the edit). The new tables are formatted by the shipped
initialisers (FUN_140C09200 for the ids, FUN_140C09280 for the children) with the edited bounds.

**Client project accessors (a48).** The fork's own `scr_VarGlob` accessors (`scripting/array.cpp`, `execution.cpp`, `script_value.cpp/.hpp`) used a structure of another build (40,960 objects: children at +0x98000 where the engine has +0xC5000; stride `0xA000`), so they read wrong memory on a stock game as well, and could not follow the moved tables. They are reachable in a match (`scripting::entity` field get / set from the `give health` command and the owner cheats, `scripting::array` from the GSC builtin `listfiles` and `give allammo`, every `is<array>` type test). Every access now goes through `src/native/script_var_layout.hpp`: the stock layout by default, the relocated tables once `script_variables.cpp` installs them (after its code patches), an id or child index outside the tables refused (null, safe value, first refusal logged). The fork edits are the data `ops/script-variables/accessor-edits.json`, applied to the pinned `cfca45b` sources by `ops/Apply-ScriptVarAccessorOverlay.ps1` in every ServerModules build (an unowned edit stops the build). Tests: `tests/native/script_var_layout_test.cpp`, `tests/ops/script_var_accessor_test.py`; live: the lab probe `cap_accessor_probe` (server repository, `ops/gamelab/lib/capacity.gsc`) builds a script array with `listfiles` on the relocated tables (runs a48-j1b, 232 records, joined client: 2 files read back).

**Runs (headless, private loopback, a46, client built from this component).** n = 100 `capacity-agents-headless` (stock-table pages inaccessible): PASS 22/22, 9/9, peak alive 78, children 115,578 / parents 30,901 at the peak. n = 232 `capacity-agents-soak-headless` with `alive=200` (25 windows of 30 s): PASS 168/168, 30/30, alive 197 to 200, 232 instances, **children peak 178,433 (fullest segment 45,054 of 65,535), parents peak 52,571 (fullest segment 14,964 of 16,383, 91 %)**, no engine error text. The parent ids are the next limit (the walls: about 215 alive for the parents, about 290 for the children); past it the u16 parent id of the child entry has to widen (docs/SCRIPT-VARIABLES.md in the server repository, "What the full mission target needs").

## 320 agents (a57, 16 Nov 2026)

`-agent-capacity` accepts 24, 28, ..., 320 (characters 338, `map_start` 354, 367 sentient slots). What stopped 232 -> 238 -> 255 -> 256 was three separate widths
(a55): the explicit agent number of the agent-state delta (the wire width), the character change mask of CG_SetNextSnap (8 words) and the agent count in GameStateInfo's byte.

| What | Change |
|---|---|
| agent number and clientNum, wire bits | `layout::net_id_bits()`: 7 up to 127 characters, 8 up to 256, **9 above** (5 bit counts + 24 clientNum rows are imm32 values; 240 agents is the first count with 9) |
| every other 6..8 bit integer row of the entity and agent state field lists (table 0x141BB3B20) | **90 rows widened to 9 bits above 256 characters** (generated `agent_capacity_net_rows.inc`, `ops/engine/net_rows.py find|check|emit`; every row's offset is checked before it is written): none was proven free of character numbers, a wider field changes no value; includes the one 8 bit clientNum of the base list 32 (0x141BB7C08), which the component never patched. Player state lists (34, 36) are left alone: players only |
| CG_SetNextSnap change mask | 12 words (48 bytes, 384 characters): frame grow `--extra 48`, the five mask caves regenerated (six qword clear) |
| GameStateInfo +0x546, G_GetMaxAgents | the byte (and the wire byte of the gamestate message) is `min(n, 255)`; above 255 agents its three value readers (SV init FUN_140c56a90 0x140C56AF8, the client snapshot ring FUN_1409b2620 0x1409B266C, GScr_getmaxagents 0x140C1DD99) become `mov r32, imm32 n` + nops in place; the five `cmp byte [+0x546], 0` tests stay |
| page-probe caves of the three grown frames | planned for 320: FUN_1403E61B0 X = 21,216 (frame 24,632 bytes, 7 probes), FUN_140ADDED0 9,472, FUN_140ADB8E0 4,736 |
| **saved animation cache** (a hash map of 193 buckets at 0x147994898, DObj index -> saved animation state; nodes from ONE static pool of 84 x 0x360 bytes, free list head 0x147994890, chained by the initialiser at 0x14001AE20) | the pool grows to 2,048 nodes (one per possible key: 2,048 DObj records): the extra 1,964 blocks are appended to the free list at start (`extend_free_list`). Stock: the insert (FUN_140D815A0) pops the head with no emptiness check, so the **85th key** took the head variable itself as a node and wrote key and state over the first buckets; the chain walk (FUN_140D80D60, 0x140D80DE7) then read a garbage pointer and the server crashed. Found with ghost agents: **each stock ghost holds one node for good**, so 84 ghosts end the match, with or without this component (the pre-a57 client crashes at the same instruction, runs a57-m232 and a57-m232-base; plain zombies hold none: 250 alive plain at 232 never reached it) |
| **per-frame animated bone buffers** (two static halves of 0x100000 bytes at 0x141FE5F20, chosen by the frame's parity in FUN_140342790; the allocators FUN_140346520 and FUN_1403464D0 hand out 16 byte multiples and refuse past 0xFFFF0) | each half 4 MB (shift 22, cap 0x3FFFF0) in a new 8 MB block: `lea r8` retargeted, `shl rax, 0x14` -> 0x16, two `cmp eax, 0xFFFF0` immediates. Stock: past the cap the allocator calls the fatal error function FUN_140D34180, which shows a **message box ("TOO MANY ANIMATED BONES - check if the total game bone count can be reduced")**; a client has no `+unattended`, so its main thread blocks for good (no crash, no dump, the lab's requests stop: runs a57-n320, n320b, hB, hB2). About 4.4 KB of bones a skeleton: the client stops at about 238 animated agents (the old proven range ended at 232 by luck of the plan). Found by writing a thread-stack minidump of the frozen client (`MiniDumpWriteDump` of its pid) and reading the message buffer out of the main thread's stack |
| XAnim anim-info heap (FUN_140D83DF0: 0x3FFC0 usable bytes of 16 byte units at 0x147995420, u16 indexes from 0x1479953E0) | grown pre-emptively to the u16 maximum 0x100000 bytes (65,536 units) in a new block: seven fields of the init (two lea, two imm32, four zeroed units). **Not shown to be needed**: the first reading of the frozen client's stack (stale return addresses of FUN_140D72DB0 / FUN_140D846B0) was taken for this heap's "exceeded maximum number of anim info" and was wrong; the heap holds 16,380 units for 232 agents' worth of animation in all earlier runs, and nothing measures its use |

Checked, nothing to change: the 25 unread `cmp 0x2A / 0x29` compares and the six 42-iteration loops (bounds against stock-sized arrays: agents from 42 on are not served, no store through an index); the
stack arrays of the 320 scan (97 rows, the same as at 232: the 2 overruns are the grown frames; the 85 unknown rows are not indexed by an entity, character, sentient or agent number, or hold 368 entries or more);
`G_CollectFlaggedAgents_Unbounded` still walks characters 18..41 only (its caller's 6-int array). Not settled: a store indexed by the entity space (2,048) into an array of 368..2,047 entries.

Tests: `agent_capacity_sites_test.py` (every cave and site for every count 24..320, net bits 7/8/9, the 12 word mask, refuse mirror), `agent_capacity_net_rows_test.py` (the table equals the image, the
three readers, the nonzero tests), pools test (the animation cache: 84 nodes read back from the initialiser), the records / state / snapshot / sound tests at 24..320.


## Parent ids beyond u16 (a56, 16 Nov 2026)

`script_variables.cpp` now also lifts the u16 parent id: ids of 18 bits (4 x 65,535 = 262,140 usable, stage 1: 65,532). An id is `4 x local + segment`. The u16 limit lived in
three places only (the VM stack, the hash and the callers carry 32 bits): the child's parent field (+0xE), the lookup key (`parent << 16 | name >> 8`) and the free list links of
the parent table. They now hold the **local index** (`id >> 2`). Sites, all printed before the edit by `python -B ops/engine/variable_sites.py parents`:

- 14 key builders (`shl r,0x10` of a copy of the parent id beside the hash `imul 0x65`) and the one reader of the parent field (FUN_140C05280, which rebuilds `id = 4 x local + (base >> 16)`): 15 code caves
  (`ops/engine/caves/parent-keys.*`, planned by `cave_plan.py`: `shr r,2` before the shift; the three windows that held an edit of stage 1 carry it). One of the 14 is Scr_AddClassField
  (0x140C0624F), **code that no function of the engine database holds** (the database has functions that swallow the rest of the image and gaps between them): the finder decodes every byte of
  the variable system's range, not the database's functions.
- the free list code is replaced by the component (`script_parent_pools.hpp`, native test `tests/native/script_parent_pools_test.cpp`): AllocVariable (pop), FUN_140C04910 / FUN_140C05C50 / the tail of
  RemoveRefToObject / FUN_140C08E70 (push), the list initialiser; the rebuild after loading a saved game (FUN_140C08C30) is refused with a message. The free ids of a segment are two stacks: the ids below
  0x10000 and the rest. **The shipped code is compiled with interprocedural register allocation** (a caller relies on every register the shipped callee leaves alone: FindVariable's callers read `r8d` after
  the call): a replacement written in C++ is reached through a wrapper that saves `rcx, rdx, r8..r11, xmm0..xmm5` and restores them (`wrapper_for`, `save_all` / `restore_all`, tested).
- ids the engine keeps in 16 bits outside the variable system take pool 0 (ids below 0x10000): threads (`Scr_ExecThread` / `Scr_ExecEntThread` return the thread id as u16, `Scr_FreeThread` takes a u16, two game structs keep
  it in a u16 field), the `self` of a thread (u16 in the thread object, so structs, entity objects and class entities too), the class arrays (u16 table 0x141BBA600), the dead entity chain, the server client arrays
  (`client+0x9F352`): 9 allocation sites of AllocVariable and 2 of Scr_AllocArray are redirected. Every other object takes a high id first: a 16-bit holder of a general id fails at once. A thread started on an object with
  an id above 0xFFFF stops with a message naming the object and its type (a prologue stub on the two thread allocators).
- the integer key range follows the object key bound: object key names `0x40000 + id` end at 0x7FFFF, integer key names start at 0x80000 (8 `name_bound` sites, 5 `int_low` / `int_high` pairs).

Test switches: `-script-variables-low-first` or `IW7_SCRIPT_VARIABLES_LOW_FIRST=1` (general objects take the low pool first: the stage 1 order), `-script-variables-stock` (off). Tests: `tests/ops/script_parent_ids_test.py` (finder,

**FindVariable meter (a60, lab only).** `-script-variables-meter` (or `IW7_SCRIPT_VARIABLES_METER=1`: the headless runner passes no flags of its own) with `-agent-capacity` puts a stub in front of FindVariable (`0x140C05100`): one `sub dword [counter], 1` and a `jz` a call, and 1 call in 256 first runs a sampler (all volatile registers saved: the shipped callers rely on them) that walks the same chain read only and records the entries compared (hit: the position of the key, miss: the whole chain; the shipped lookup moves a hit to the front, so a hit costs 1.03 on average). Every 10 s one `[var meter] {json}` line goes to the console (calls, sampled, hit and miss counts, mean, p50, p90, p99 of the entries compared, the 66 bin histograms, the children in use of the four segments, the re-hash check `checked` / `checked_bad` over 1,024 buckets of each report, which must stay 0). The counters sit in a data page of their own: a store into the page of the running stub costs a pipeline flush (300 ns a call, measured by running the stub bytes in a loop); in its own page the stub costs 0.4 to 0.8 ns a call. The structural reading (load factor, chain lengths, dispersion, the entries re-hashed with other bucket counts) is `ops/gamelab/iw7_var_chains.py` of the server repository, which reads the tables from outside the process.
every cave against the shipped bytes, the free path window, replaced functions, key ranges, the wrapper), `tests/native/script_parent_pools_test.cpp`.

## Players on another layout

The server announces `agentcap=agents-<n>` in its info and refuses at connect a client whose layout differs (today's
official client sends no key and is refused with "This server holds more zombies than your client can show. Update to
the capacity client to join."); a capacity client refuses a stock server the same way (`ops/agent-capacity/AgentCap-Peer-Overlay.Core.ps1`,
applied to `auth.cpp` and `party.cpp` by the build switch). The wire format differs (7-bit character index, longer
snapshots), so there is no mixed mode.

## Not done (the next limits)

- More than 100 agents: the 43 signed 8-bit fields above (corpse and character bounds, `lea r, [r - 50]`, the agent-count bounds) need
  re-encoding to 32-bit forms (longer instructions: code caves or hooks; `add1s` refuses them until then), and more than
  110 agents needs 8-bit character ids on the wire (9 bits for 200 + 105).
- The collector sub_1400A97C0 (loop bound 0x1400A9865) still walks characters 18..41: widening it overruns the 6-int
  stack array of its caller sub_140B69E20; it must be bounded first.
- A 32-bit character bitmask at +0x300 (sub_140C26630, 0x140C266A6) aliases above 32 characters (also in the stock game).
- Save-archive loops over 66 sentients and 24 agents (0x140B309C8, 0x140B314F1, 0x140B31860): not used by a zombies
  match as far as measured; with 100 agents the count (142) no longer fits their 8-bit compare.

## Fast compile check (a34)

Before a full client build of `agent_capacity.cpp` (or any unit of `src/native`) run `pwsh -NoProfile -File ops/Compile-Check.ps1 -NativeRoot <native tree built once with ops/Build-Voice.ps1> -Source src/native/agent_capacity.cpp`.
It (1) runs `ops/check_boundaries.py` and `ops/compile_check_exports.py` (every local include of the unit, `.inc` and `.hpp` too, must be in `product.json` "exports" and listed in `ops/Build-Voice.ps1`; also for a file that is still untracked), (2) copies the unit and its includes into the tree, (3) compiles only
that unit with `MSBuild client.vcxproj /t:ClCompile /p:SelectedFiles=...` (real flags, precompiled header, warnings as errors). Measured on the same error (a raw newline in a string): 2.3 s here against 127.5 s through `Invoke-EngineLab -BuildOnly` (prepare 16 s, unit tests and build 111 s); the export refusal takes 0.5 s.
Exit 0 ok, 1 export refused, 2 compile errors printed, 3 tree not ready or a build of that tree is running. A copied tree must have its `*-overlay.local.json` receipts' `Root` changed to the new path before `Build-Voice` accepts it.

## Tools made for this work (engine map family)

| Question | Tool | Command |
|---|---|---|
| What does this function do (C)? | `ops/engine-map/iw7_decomp.py` | `<RE-lab pyghidra python> -B ops/engine-map/iw7_decomp.py --ghidra <ghidra 12.1.4> --work <folder> --reference-root <refs> ADDR...` (JAVA_HOME = the RE lab JDK). First call about 70 s (imports a flat image of the unpacked sections without auto-analysis), then about 35 s for five functions. The RE-lab project made in October is of the packed exe: do not use it |
| Who touches this global, in any addressing form? | `ops/engine-map/iw7_xref32.py` | `python -B ops/engine-map/iw7_xref32.py --reference-root <refs> --db <engine map> ADDR[:SPAN] ...` (rip-relative and image-base-relative disp32; 6 to 10 s) |
| The protected code spans of a live process | `ops/engine-map/iw7_dump_spans.py` | `python -B ops/engine-map/iw7_dump_spans.py --pid <your own game process> --out <new folder>`; then `iw7_xref32.py --extra 14B2B4000=<file>` |

## Hash buckets (a62, 16 Nov 2026)

The child hash table (stock 4 x 16,384 u16 buckets at 0x146736180) is a table of the component with 2^bits buckets a segment: `-script-variables-buckets <14..17>` or `IW7_SCRIPT_VARIABLES_BUCKETS`, default 16 (512 KB). The sites (16 `and r,0x3FFF`, 15 `shl r,0xE`, 12 table references the stage 1 list lacked, the clear at 0x140C09311) are found and proven by `ops/engine/variable_sites.py buckets` (`variable-buckets.json`, `script_variables_buckets.inc`); the six `[P8 + 0xA5000]` rows and the two `add rax,0x52800` rows of stage 1 follow the table. Tests: `tests/ops/script_variables_test.py`, class `Buckets`. Measurements and the choice of 16: iw7-paris-server `docs/SCRIPT-VARIABLES.md`, "Hash buckets". `IW7_SCRIPT_VARIABLES_MODE=move` keeps 14 bits.

## Child capacity census (a64, 16 Nov 2026)

The children are the next wall of the mission mix (200 plain + 100 specials + 5 bosses: 85 to 89 % of the fullest segment of 65,535 on the stock map, projected from the soak and specials runs of a53 to a62: 54.0 k a segment at 280 plain alive measured, specials added from their measured cost). `python -I -B ops/engine/variable_sites.py segments` (option C: more than 4 child segments, segment = parent id & 7 or & 15) and `links` (option D: wider child links, one segment above 65,535 entries) count every site that a larger child capacity touches, from every byte of the variable system (20,377 instructions), the stage 1 rows and the engine database's call table; `-o file.json` keeps the lists. Nothing is edited. Test: `tests/ops/script_children_census_test.py`. The range of the tools ended at 0x140C11000, inside FUN_140C10E60 (ends 0x140C11087), and cut its last instruction: `VM_CALLS` now ends at 0x140C11090 (`parents` and `buckets` print the same sites; only the instruction count changed, 20,333 to 20,377).

| | option C, segment = id & 7 (8 segments, 524,280 children and parent ids; & 15: 1,048,560) | option D, 17 or 18 bit child index (4 segments: 524,284 or 1,048,572) |
|---|---|---|
| `and r,3` of a segment (in place, 1 byte) | 93 in the system (88 feed a segment base pair, 1 the hash read-back at 0x140C0532A, 4 index the list heads in code the component already replaces) + 29 outside it (25 functions, all fed by `and r,3`) | not needed |
| segment base pairs `lea r,[s+s*4]; shl r,0x10` | 119 (stage 1 rows): no byte change; 117 take the segment from an `and r,3` (88 in the system + 29 outside), 2 from the loop counter of the list rebuild and of the initialiser (the `cmp r,4` loops) | 119: the `shl` count 0x10 -> 0x11 or 0x12 |
| hash shift `shl r,bits` | 15: no change (the table is 8 x 2^bits) | 15: no change |
| loops over the 4 segments (`cmp r,4`) | 4 (initialiser, list rebuild) | not needed |
| counters (children in use a segment, BLOCK0 + 0x34..0x43) | 10 instructions in 6 functions (the instruction index and the walker agree); 84 instructions use the scalars behind them (a67: 83 before the walker decoded every byte of the range; the 101 fields in 38 functions of the a45 text are the whole window BLOCK0 + 0x34..0x57: the counters 10 / 6 and the scalars 91 / 32), so the counters move | unchanged |
| id <-> local index | the 14 key builder caves (`shr r,2` -> 3) and the read-back cave (scale 4 -> 8) | unchanged |
| constants and table references | the same 38 constants (new values) and 414 + 18 references | the same + P4 entry 4 -> 8 bytes, bucket u16 -> u32 |
| u16 child index accesses | none | 90 word accesses in 33 functions (64 through a stage 1 table form, 26 through a child pointer, 10 of them in functions that handle children), 52 wider accesses of the free list and value bytes through the tables, 115 ambiguous 4 or 8 byte accesses at +8 / +0x10 (stack value tags or paired links) not counted; each needs more than an immediate (caves, or the 33 functions in C++) |
| u16 holders of a child index outside the system | not applicable | 123 external call sites of the child index functions (FindVariable / GetVariable families): none stores or truncates the result to 16 bits in a 16 instruction straight-line window. Of all 15,030 external call sites, 68 have such a use, in 8 callees: 12 are the a56 holders (Scr_ExecThread 10, Scr_AllocArray 2); the other 56 are no variable id: Scr_GetEntityIdRef 13 (entity number and class from P8), an entity number parameter getter 13, an asset handle parameter getter 27 (u16 fields of the player struct), Scr_GetInt 1, a class struct getter 1 (allocates through the low pool site 0x140C04559, stored in `client+0x9F352`), 1 false positive (a tail jump) |
| component C++ that names 4 | `script_parent_pools.hpp` 8 lines, `script_variables.cpp` 18, `.hpp` 5, `script_var_layout.hpp` 2; server tools `iw7_budgets.py` (reads 4 counters, refuses other counts) and `iw7_var_chains.py` (`& 3`) | `script_variables.cpp` (the free list and the bucket code), the layout |
| memory (tables) | 21.6 MB (& 15: 43 MB), stage 2 and buckets now 10.8 MB | 18.6 MB at 17 bit (the children alone 25 MB at 18 bit) |

## Child segments (a67, 16 Nov 2026)

The child pool (4 segments x 65,535) was the next wall of the mission mix (a64: 85 to 89 % of the fullest segment on the stock map). **`-script-variables-segments 4|8|16`** (env `IW7_SCRIPT_VARIABLES_SEGMENTS` for runners that pass no flags of their own; **default 8**; 4 is the previous build exactly, 16 is proven offline and by one n = 100 run only) chooses the number of child segments of the GSC variable system: a parent's children live in segment `id & (S - 1)`, an id is `S x local + segment` (local u16, so the last id is 0x3FFFF / 0x7FFFF / 0xFFFFF: 262,140 / 524,280 / 1,048,560 usable ids and children), the hash table is `S << bits` buckets, the counters of the children in use are a table of `S` ints of the component (4 segments keep the stock block). Done in `script_variables.cpp`; the sites by `python -I -B ops/engine/variable_sites.py segment-rows` (`variable-segments.json`) and `emit-segments` (`script_variables_segments.inc`), every one proven by the census of a64 (`segments`), tests `tests/ops/script_segments_test.py`, `tests/native/script_parent_pools_test.cpp` (4, 8 and 16 segments), `tests/native/script_var_layout_test.cpp`.

| kind | sites | edit at 8 / 16 |
|---|---|---|
| `and r,3` that selects a segment | 118: 88 base pairs + 1 hash read-back in the system, 29 outside it (25 functions) | imm8 3 -> 7 / 15 |
| `and r,3` that indexes the 4 list heads | 4, in the free list code the component replaces | none (C++, `parent_pools`) |
| loops `cmp r,4` | 4 (the live child initialiser 0x140C09302; the parent initialiser and the rebuild are replaced, patched so that the code and the meter read the same count) | imm8 4 -> 8 / 16 |
| key builders `shr r,2` | 14 caves | `shr r,3` / `4` (the cave copy is made from the 4 segment table) |
| parent id read back (0x140C0531A) | 1 cave | `lea ecx,[rdx+rcx*8]` / `shl ecx,4 ; add ecx,edx` (no SIB scale 16) |
| constants | 38 (name_bound 8, int_low 5, int_high 5, parent_bound 5, p2_bytes 2, p4_bytes 1, ...) | new values: name_bound 0xC0000 / 0x140000 (object key names end at 0xBFFFF / 0x13FFFF, the integer keys start at 0x800000 and the smallest accepted integer key is -0x740000 / -0x6C0000: no collision), parent_bound 0x80000 / 0x100000 |
| segment base pairs, hash shifts | 119 + 15 | none (the base is `segment << 16`, the table `S << bits`; all 15 hash shifts take their segment from one of the patched `and`, checked by `variable_sites.bucket_flow` in the test) |
| counters (children in use a segment) | 10 instructions in 6 functions (4 in the replaced AllocVariable) | the references move to the component's table; an entry hook at 0x140C09280 zeroes all `S` of them; the stock block is watched (`stale_counters` in the meter, a fatal error in `check_guards` if it moves: a missed counter site) |
| tables | A, B, P8, P4, children, hash | 21.6 MB at 8 and 43.2 MB at 16 (children 12.6 / 25.2 MB, bits 16) |
| low pool (ids below 0x10000) | threads, structs, entity objects, class arrays and the client arrays keep their id in 16 bits | 65,532 / 65,528 / 65,520 ids: locals below `0x10000 / S` |

At 4 segments no row of this section is applied: the plan of patches is the one of components main (1,265 patches in the log line; 1,403 at 8 segments = 1,265 + 118 masks + 4 loop bounds + 10 counter references + the 6 bytes of the counter reset hook).

Measured (headless and joined, client from this component at a457f188c6, runs `a67-*`; the figures and the tables are in iw7-paris-server `docs/SCRIPT-VARIABLES.md`, "Segments"): `capacity-agents-headless` n = 100 PASS 23/23, 11/11 at 8 and at 16 segments with the stock table pages inaccessible; the soak at 280 alive PASS 168/168, 30/30 at 8 segments (fullest segment 28,179 of 65,535, 43 %; 4 segments 55,227, 84 %) and at 4; clown 20 to 40 PASS; the lab fill (240,000 distinct elements, 337,320 children in all, read back with 0 bad) PASS 17/17 at 8 segments and ends the server at 4; `netlab-capacity-soak` 320 / 280 with a joined client PASS 149/149, 43/43. Every meter line: `checked_bad` 0 and `stale_counters` 0. The next wall is the low pool (ids below 0x10000: 41 k of 65,528 at 280 plain alive). The A/B 4 against 8 segments ran on a machine at 72 to 75 % CPU (frame 50.1 against 42.0 ms mean, FindVariable 5.27 against 4.76 ms): not slower, no quiet machine measurement.

## Client character tables (a76, 17 Nov 2026)

The client object `cg` (stock 0xFDEA8 bytes, `FUN_140240A00`) was censused for the character record (0x2CA0 bytes, grown) and the flag bytes (moved to the tail), and nothing else: client tables were never read for a stock count of 42. The a73 write watch found one:
`FUN_140945FD0(local, n)` returns `cg + 0x70950 + n * 0xC0`; `FUN_140949810` (called per snapshot character from `FUN_140864450`, from `FUN_140873870`) writes 16 bytes at row + 0x24 (`[+0x24] = a; [+0x28] = b;` and `[+0x2C] = old [+0x24]`) for every character except the local one.
The stock table has 42 rows and ends at **cg + 0x728D0** (42 x 0xC0 = 0x1F80), where another member of `cg` starts; the older notes (0x72AD0, 0x73350) were arithmetic slips. No caller bounds `n`. With C = n + 18 characters, rows 42..C - 1 wrote over the members behind it, up to `0x70950 + (C - 1) * 0xC0 + 0x34`:

| agents | characters | last byte written | members of `cg` with a code-used offset in the written windows |
|---|---|---|---|
| 56 | 74 | 0x74044 | row 42: the stride 0x14 array at 0x728D0 (0x728F4..0x72904) |
| 264 | 282 | 0x7DC44 | the same, and the vtable qword of hit result 0 at 0x74278 (row 76: the owner's crash of 16 Nov), 0x795B4/0x795B8, the per-entity qword table at 0x7A580 |
| 320 | 338 | 0x80644 | those and 0x7F978 |

It is wrong from 28 agents on (46 characters); the watched vtable is reached from row 76 (56 agents stop at row 73, which is why a73's run d1 at 56 saw nothing).
**Fix:** the table moves to the tail of `cg`, after the flags (`client_char_table()` = `(client_flags() + C + 15) & ~15`; `client_size()` adds C x 0xC0). One instruction field names it: `add rdx, 0x70950` at 0x140946FD0 (field 0x140946FD3; the index of the image holds no other disp or imm of 0x70950..0x728CF in code that loads `cg`, and no bulk clear or copy names the range); it is patched to the layout's offset. The rows start zero (the object is zeroed at allocation) and are freed with it,
which is what the stock table did inside the object; at 24 agents the rows are the stock 42 and the object is 0x38 bytes larger (the flags).
Why the tail and not a separate allocation: the lifetime and the zero fill of the table must follow `cg` (one object for each local client, built and destroyed at map changes); the tail of `cg` does by construction.

**Tool:** `python -I -B ops/engine/client_tables.py scan -o <file>` decodes every function that loads `cg` and the client ranges (17,816 functions, 3,239 stride-indexed member accesses; accesses through the image base, the obfuscated accessors' jump tables, are dropped), `report <file>` groups them into 66 clusters (stride, offset, the end of 42 rows, the next member inside it),
`find` / `check` list and verify the instruction fields of the moved tables (`client-tables.json`). Test: `tests/ops/client_tables_test.py` (layout for every count, the field, no other instruction names the stock rows).

**What the census shows and does not show.** Read to their index sources: the 0x2CA0 record and the flags (character numbers, handled), the entity number tables at 0x78580 / 0x7A580 / 0x7E580 / 0x4376 x 0x20 (2048 rows), the per-hand tables (0x654 x 0x34, 0x492C8), rings and small enumerations (0x784B8 x 8 with 25 rows, 0x4F5C8, 0x597D4, 0x6EE18, 0x86C74, 0x2928), the weapon slot arrays (0x1F6C...), the per local client objects (stride 0x79950).
Of the other 156 client static candidates of `static_tables.py` six were read (material handle tables, vehicle effect handles, a serialized block): none is indexed by a character number. **Not shown: that no other member of `cg` or client global is written with a character number at 264.** That needs a record of the writes into the whole object (a whole-object write trace, or the memory watch of the object read for changed fields at a fixed stride); the write watch names a writer of up to four cells.
