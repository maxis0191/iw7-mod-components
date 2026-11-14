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

**Accepted counts:** 24, 28, ..., 100. Two encodings bound it: C - 42 must be a multiple of 4 (the archive copy loops
move by (2C - 84) / 8 and (82C + 4) / 8 quadwords), and C + 8 <= 127 (signed 8-bit corpse and character bounds).

## Players on another layout

The server announces `agentcap=agents-<n>` in its info and refuses at connect a client whose layout differs (today's
official client sends no key and is refused with "This server holds more zombies than your client can show. Update to
the capacity client to join."); a capacity client refuses a stock server the same way (`ops/agent-capacity/AgentCap-Peer-Overlay.Core.ps1`,
applied to `auth.cpp` and `party.cpp` by the build switch). The wire format differs (7-bit character index, longer
snapshots), so there is no mixed mode.

## Not done (the next limits)

- More than 100 agents: about 30 signed 8-bit immediates (corpse and character bounds, `lea r, [r - 50]`, the rewind
  pointer disp8 0x140415C28) need re-encoding to 32-bit forms (longer instructions: code caves or hooks), and more than
  110 agents needs 8-bit character ids on the wire (9 bits for 200 + 105).
- The collector sub_1400A97C0 (loop bound 0x1400A9865) still walks characters 18..41: widening it overruns the 6-int
  stack array of its caller sub_140B69E20; it must be bounded first.
- A 32-bit character bitmask at +0x300 (sub_140C26630, 0x140C266A6) aliases above 32 characters (also in the stock game).
- Save-archive loops over 66 sentients and 24 agents (0x140B309C8, 0x140B314F1, 0x140B31860): not used by a zombies
  match as far as measured; with 100 agents the count (142) no longer fits their 8-bit compare.

## Tools made for this work (engine map family)

| Question | Tool | Command |
|---|---|---|
| What does this function do (C)? | `ops/engine-map/iw7_decomp.py` | `<RE-lab pyghidra python> -B ops/engine-map/iw7_decomp.py --ghidra <ghidra 12.1.4> --work <folder> --reference-root <refs> ADDR...` (JAVA_HOME = the RE lab JDK). First call about 70 s (imports a flat image of the unpacked sections without auto-analysis), then about 35 s for five functions. The RE-lab project made in October is of the packed exe: do not use it |
| Who touches this global, in any addressing form? | `ops/engine-map/iw7_xref32.py` | `python -B ops/engine-map/iw7_xref32.py --reference-root <refs> --db <engine map> ADDR[:SPAN] ...` (rip-relative and image-base-relative disp32; 6 to 10 s) |
| The protected code spans of a live process | `ops/engine-map/iw7_dump_spans.py` | `python -B ops/engine-map/iw7_dump_spans.py --pid <your own game process> --out <new folder>`; then `iw7_xref32.py --extra 14B2B4000=<file>` |
