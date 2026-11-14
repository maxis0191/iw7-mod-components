# Engine database and the `engine` command

The engine of `iw7_ship.exe` as data: every function decompiled once by Ghidra, its calls, the code that reads or
writes each global, the strings, the structures, every immediate and structure offset used by an instruction,
memory snapshots of running games, and the team's own knowledge (names, limits, notes) written back by a command.
One command answers in seconds without opening Ghidra; the same commands are MCP tools for agents.

The dedicated server and the client are the same executable (`iw7-mod.exe` loads `iw7_ship.exe`; `-dedicated`
runs the server), so one database covers the server code (G_, SV_, agents, AI) and the client code (CG_, renderer,
animation).

## Ask

```
python -B ops/engine/engine.py find maxagents            # functions, labels, strings (with their users), notes
python -B ops/engine/engine.py at 0x140C18D76             # function+offset, label, section, callers/readers, notes
python -B ops/engine/engine.py decomp 0x140C18D00         # decompiled C (with our notes on top)
python -B ops/engine/engine.py disasm 0x140C18D00         # capstone, names of targets and strings
python -B ops/engine/engine.py callers 0x140C18D00 --depth 2
python -B ops/engine/engine.py xrefs 0x143C986C0 --kind read          # code that reads a global
python -B ops/engine/engine.py xrefs 0x144C6F208 --range 0x10         # a small table or structure
python -B ops/engine/engine.py grep "0x2a\b|42\b" --max 50           # regex over all decompiled code
python -B ops/engine/engine.py imm 0x5010                 # every instruction with that immediate (a stride)
python -B ops/engine/engine.py imm 0x546 --disp           # every [reg+0x546]: who touches a structure field
python -B ops/engine/engine.py struct gentity_s           # Ghidra types, the client fork's structs, knowledge
python -B ops/engine/engine.py mem "[0x143C986B8]+0x10" --type ptr    # value in a memory snapshot
python -B ops/engine/engine.py status
```

Addresses: `0x140C18D00`, `140C18D00`, `FUN_140c18d00`, `sub_140C18D00`, `+0xC18D00` or a known name. `--json` on
every command. Times: see "Measured".

## Write back what you learned

```
python -B ops/engine/engine.py name 0x140C18D00 G_SelectMaxAgents --evidence "decomp: clamps scr_%s_maxagents to 0x18"
python -B ops/engine/engine.py note 0x140C18D76 "agent limit clamp" --tag limit --value 24 --evidence "imm 0x18 at 140C18D76"
python -B ops/engine/engine.py notes --tag limit
```

Names and notes go to `ops/engine/knowledge/engine-knowledge.json` (committed: our own names and findings, no game
bytes). Every other command shows them at once; the Ghidra project gets the names at the next `analyze` step.
Commit the file with your work. A name already used at another address is refused (`--replace` moves it).

## MCP tools for agents

`ops/engine/engine_mcp.py` is a standard-library MCP server (stdio) whose tools are the commands above (find, at,
decomp, disasm, callers, callees, xrefs, grep, imm, struct, mem, name, note, notes, status). It starts no JVM.
`pwsh -File ops/engine/Install-EngineTools.ps1` copies the command to `<RE lab>/engine/bin` and registers the server
for Claude Code at user scope (`iw7-engine`); new sessions see the tools. The full Ghidra MCP server of
`docs/RE-TOOLS.md` (pyghidra-mcp, read-only, one admitted session) stays for interactive work inside the project.

## Where things are (machine-local, never committed: derived from the game)

| What | Path under the RE lab (`%USERPROFILE%\Documents\IW7-RE-Lab`) |
| --- | --- |
| Analysable image (shipped PE with the in-memory sections) | `engine\image\iw7_ship_live.exe` (+ `.json` receipt) |
| Ghidra project | `engine\ghidra\iw7_ship.gpr` (+ `iw7_ship.analyze.json`: time and memory of each step) |
| Engine database | `engine\iw7-engine.sqlite` |
| Instruction index | `engine\iw7-insn-index.sqlite` |
| Memory snapshots | `engine\snapshots\<name>\` (`<VA>.bin` per section + `sections.json`) |
| Names from the project's sources | `engine\names\names.json` |
| Tools (Ghidra 12.1.4, Temurin 21, PyGhidra, x64dbg) | `runtime\`, listed with hashes in `toolchain-manifest.json` |

## Build the database (once per executable; resumable)

1. Sections from memory. The shipped file keeps its code protected; the real bytes exist only in a running game.
   From a full-memory dump: `python -I ops/engine/sections_from_dump.py --dump <file.dmp> --out <lab>\engine\snapshots\<name>`;
   from a running private lab server: `python -I ops/engine/live/engine_live.py dump --out <folder> --pid <pid>`.
2. Image: `python -I ops/engine/build_image.py --exe <iw7_ship.exe> --live-dump <snapshot folder> --out <lab>\engine\image\iw7_ship_live.exe`
   (imports, resources and TLS stay from the shipped file).
3. Names: `python -I ops/engine/collect_names.py --native-root <iw7-mod checkout> --rdata <snapshot>\141435000.bin --out <lab>\engine\names\names.json`
   (symbols.hpp, GSC builtin and LUI tables, the fork's structs and hook addresses).
4. Ghidra: `pwsh -File ops/engine/Invoke-EngineAnalysis.ps1 -Step analyze -WaitForSlotSeconds 3600`, then
   `pwsh -File ops/engine/Invoke-EngineAnalysis.ps1 -Step export -MaxMinutes 600 -WaitForSlotSeconds 3600`. The
   export resumes where it stopped (exit 3 = functions remain: run it again with `-Extra '--only','decomp'`).
5. Instruction index: `python -B ops/engine/engine.py index` (again after the export: it then uses Ghidra's functions).

Both Ghidra steps hold the scheduler's named resource `ghidra:<project>` as a long holder with their real memory:
builds and sessions run beside them; only another step on the same project waits.

`grep` reads the decompiled form and `imm` the instructions: a loop bound can be `cmp rsi,0xa6b0` in the code and a
pointer comparison in the C (`imm 0xa6b0` finds 8 sites, `grep 0xa6b0` 4). Use both.

## Measured (12-14 Nov 2026, this machine)

| Step or query | Time | Memory |
| --- | --- | --- |
| Sections from the 10 GB client dump (`sections_from_dump.py`) | 19 s | small |
| Live dump of a private lab server (`engine_live.py dump`) | 0.45 s for 178 MB | small |
| Image (`build_image.py`) | 0.3 s | small |
| Names (`collect_names.py`: 10,975 names, 123 structs) | 1 to 2 s | small |
| Ghidra import + names + auto-analysis + save | JVM 116 s, import 190 s, names 42 s, analysis 2,450 s (295,609 functions) | about 1.3 GB working set, JVM 441 MB used at the end |
| Instruction index (`engine.py index`: 9.8 M instructions, both code sections) | 38 s with the database, 117 s without | 150 MB peak, 280 MB file |
| Ghidra export: tables (295,050 functions, 1.32 M references, 32,425 strings, 18,047 labels, 339 types) | 153 s | 0.8 GB |
| Ghidra export: every function decompiled, 6 threads (295,016 ok, 34 failed) | 1,110 s | 1.65 GB peak; database 172 MB |
| `imm`, `xrefs`, `disasm`, `mem`, `notes`, `callers`, `find`, `at` | 0.05 to 0.2 s | small |
| `decomp` of one function | 0.3 s | small |
| `grep` over all decompiled code | 1.2 s | small |

The analysis ran 2,450 s only after its process stopped being power-throttled: at BelowNormal priority Windows 11
gave it 0.6 s of CPU in 30 s (components pull request 139 removes that throttling for every scheduler job).

## Live (a running private lab server of our own)

`ops/engine/live/engine_live.py`: `ps` (which iw7 processes are ours, by the bench manifest and the scheduler lease),
`read` / `deref` (`"[0x146B22AC8]+0x30"`, 10 to 16 ms), `watch <expr>:<type>:<ms>:<count>` (JSONL), `dump --out <folder>`
(every section of the module as it is in memory, the input of `build_image.py --live-dump`). All read-only, no
suspension; proven on a private headless dedicated server on 11 Nov 2026.

`trace` and `break` are disabled: the game ignores the debugger's break-in (every attach waits 30 s, then the
debugger suspends it), stopping by killing the debugger froze one lab server, and a software stop breakpoint in
ntdll crashed another (ledger: "tool: live trace freezes or crashes the server"). Hardware breakpoints do fire and
log (10 hits of `PlayerCmd_spawnagent`). A safe design must stop only from inside a breakpoint (`bc *; qd`) and use a
counted hardware breakpoint on a per-frame function as its clock; it is not built.

## Static tables: find the next "per character" array by reading

The engine keeps static tables (`.data` / `.bss`) with one row per character (42 = 18 clients + 24 agents), per agent
(24), per sentient (66 / 71). With `-agent-capacity` the counts grow (characters 118, agents 100, sentients 147) and a
table that is not moved is overrun. Each one used to be found by a crash (the last: the entity queue, 42 x 0x208 at
0x144EB2B70, which killed a client in its first frame after a headless server had passed twelve minutes).

```
python -B ops/engine/static_tables.py                    # about 3.5 minutes; prints the prioritised candidates
python -B ops/engine/static_tables.py --json out.json    # every candidate with evidence, room, handled column
python -B ops/engine/static_tables.py --unhandled        # only what agent_capacity.cpp does not patch
python -B ops/engine/static_tables.py --capacity-source <file or git:REF:PATH>
```

It reads the analysed image, the function table, the instruction index and the decompiled code of this database. Three
independent passes, reported per candidate:

1. loop bounds: a function with a loop that reads a capacity-dependent count (`[*(0x146B22AC8)+0x30]`, MAX_CHARACTERS,
   sentient / agent count, svs_numclients followed by an agent loop starting at 18) or compares with 24, 42, 66, 71, 41,
   65, 70 and indexes or walks a static array;
2. sizes: memset / memcpy / `rep stos` of a static destination whose length is k x stride (k = 24, 42, 66, 71), and two
   static `lea` of one function whose difference is k x a stride the function also uses (start and end of a scan);
3. index sources: an index taken from an entity (`(entity - g_entities) / 0x3F8`, the entity number read at offset 0 of an
   argument pointer) or from a sentient (`(sentient - [0x143C986A0]) / 0xA0`) and scaled into a static base.

Reader forms understood: `lea r,[rip+X]` then `[r+idx*s+d]`, `[r+d]`, `add r,S` cursors, and the image-base relative
`[a+b+disp32]`. Strides come from `imul r,r,S`, `shl`, `lea r,[r+r*k]` and the access scale. Per candidate: base, stride,
rows implied, the functions that index it, evidence lines, the room (rows from the base to the next static address that
no function of the table uses through a table register; `room_rows_far` looks past the first two rows), whether
`agent_capacity.cpp` patches the encoded references (`handled`: yes / partly / no with the open sites listed) and a
priority: A room is exactly 24, 42, 66 or 71 rows, A-size the same with only a size as evidence (a buffer, usually not a
table), A18 room 18 with a loop from 18 or a capacity count, B a capacity-bounded loop over a table with less than 118
rows of room, C an entity/sentient index with less than 147 rows of room.

It is a reading aid: a candidate still needs its decompile read (`decomp`, `xrefs --range`). It cannot see a table
reached only through a pointer stored in a global (the SV agent pool 0x145C9E590 is set by one protector stub and read
through a pointer: recorded in `pointer_globals` when the store is a `mov [rip+P],reg`), arrays of structures indexed by
a field of another structure, and arrays whose index comes from an argument of a function nobody here calls directly.
Known tables are the test ground truth (`tests/ops/static_tables_test.py`: the entity queue by all three passes, the
per-character work tables, the sentient pool and the two 71-object pools).

## What it cannot know

- Ghidra's call graph misses calls through registers and tables (virtual calls, script builtin tables); `callers`
  says so when it finds none.
- The code image comes from memory, where the client fork has already patched some functions (hooks). Bytes that
  differ between two captures of different fork builds are listed by `build_image.py`'s receipt; a function that
  starts with a jump out of the module is a fork hook, not game code.
- A memory snapshot is one moment of one process (`status` lists them). Values that change during play need the
  live tool (`ops/engine/live/engine_live.py read|watch`).
- The protector's code section (0x14B2B4000) is obfuscated: Ghidra decompiles only the parts reached by calls from
  the game code; `disasm` and `imm` cover all of it from the snapshot bytes.
