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
| reserved scriptable parts (an agent's model takes 31) | 2,048 | 8,192 (`-scriptable-parts <m>`, at most 65,535) | sub_140BF7770, sub_140BF96A0, sub_140BF9A70, sub_140BFA3D0, sub_140BF6F20 |

Every field is compared with its shipped value before anything is written; one difference and the game stops with the
address (nothing is half-applied). Relocated tables sit within 2 GB of the image (the code reaches them by 32-bit
displacements) with guard bytes checked every 0.5 s.

**Accepted counts:** 24, 28, ..., 232 (`refuse()`, a34). The barriers, in the order `refuse()` checks them: C - 42 must be a multiple of 4 (the archive
copy loops move by (2C - 84) / 8 and (82C + 4) / 8 quadwords); at most 232 agents (`max_analysed_agents`: G_GetMaxAgents and the GameStateInfo
hold the count in a byte, an agent's entity number is one byte up to 238); the snapshot's character change mask (CG_SetNextSnap: a 32-byte room
opened by its frame grow, 8 words = 256 characters, 250 at 232 agents); the page-probe caves of the three grown frames, planned for 232 agents
(frame_extra of FUN_1403E61B0 = (2 x 279 - 71) x 32 = 15,584, frame 0xD58 + X = 19,000 bytes, 5 probes; FUN_140ADDED0 = (279 - 71) x 32 = 6,656,
3 probes; FUN_140ADB8E0 = (279 - 71) x 16 = 3,328, frame 0x4F0 + X = 4,592 bytes, 2 probes, a cave it did not have before; 279 = n + 47 sentient
slots). None of these functions had a stack probe call of its own (their stock frames are below a page); the planner adds the probe. The
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

Not converted, read only (a33 step 4): `cmp dword [rbp+0x700], 0x2a` at 0x1407AE222 in FUN_1407ae190 (CG interpolation of one entity: for position type 3
and an entity number below 42 it interpolates between the two snapshots through FUN_1407b6850 and returns). An agent numbered 42 or more does not take
that branch today (at 100 agents too): it gets the generic trajectory path. The proposal is one more wide site (`cmp [rbp+0x700], characters`);
it changes what agents 42..C-1 do at every count, so it is not part of the byte-site work.

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
