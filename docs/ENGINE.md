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
4. Ghidra: `pwsh -File ops/engine/Invoke-EngineAnalysis.ps1 -Step analyze -WaitForSlotSeconds 7200`, then
   `pwsh -File ops/engine/Invoke-EngineAnalysis.ps1 -Step export -WaitForSlotSeconds 7200` (repeat the export until it
   exits 0: each slice holds the Analysis slot at most `-MaxMinutes`, so waiting builds pass between slices; the
   second and later slices take `-Extra '--only','decomp'`).
5. Instruction index: `python -B ops/engine/engine.py index`.

Both Ghidra steps run under the scheduler's Analysis reservation (one Java analysis at a time on the machine).

## Measured

(filled from the real run)

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
