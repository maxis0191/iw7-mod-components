# Frame cuts: two costs taken out of every server frame (a51, 16 Nov 2026)

The server sampling profiler (server repository, `docs/SERVER-SAMPLE.md`, study a50) measured where a 50 ms server frame goes at 200 live
zombies. Two items were not game work at all, they were the iw7-mod fork's own code running on every opcode and on every damage event:

| Item | Where | Cost at 200 alive, loaded machine |
|---|---|---|
| per-opcode `replacefunc` check | `gsc/script_extension.cpp`, `vm_execute_stub` at 0x140C0D0A4: `pushad64`, a call, a `std::unordered_map` lookup and `popad64` before every script opcode | 4.3 ms (6.2 with the code cave) |
| game log writes | `game/game.cpp`, `G_LogPrintf`: `utils::io::write_file` = create directory, open, write, close, for every damage and kill line | 2.3 ms (NtCreateFile alone 1.5) |

The same edit file also carries the console writer's three fork edits (`console.cpp`, `terminal.cpp`, `exception.cpp`): see [CONSOLE-WRITER.md](CONSOLE-WRITER.md).

## What was changed

**Opcode filter.** `replacefunc` is not a lab feature: the Paris mod redirects about a hundred stock functions with it in production, and every
gamelab plan with `kick` off redirects one (`add_to_kick_queue`). So the check cannot be installed only when the first `replacefunc` runs, and it
cannot exit early on an empty map. What can be cheap is the answer "no": `src/native/paris_vm_filter.hpp` keeps a 64 KB table, one byte per value of
the low 16 bits of a replaced code position, set by `replacefunc` (and by the cutscene overlay's `redirect_code`), cleared with the map at script
shutdown. The stub now does, before it saves any register: `push rax; mov rax, table; movzx r15d, si; cmp byte [rax+r15], 0; pop rax; je end`. R15 is
dead there (the instruction at `end` rewrites it); `pop` leaves the flags of the `cmp`. A zero byte (all but about 0.6 % of the opcodes with 400 replaced
positions) goes straight to the original three instructions; a set byte takes the old path (`pushad64`, exact map lookup), so a position that shares its
low 16 bits with a replaced one is decided exactly as before. Nothing else uses the map or the stub (read in full: the debugger overlay adds scopes
elsewhere in the file, the cutscene overlay's `redirect_code` is the only other writer and now marks the filter too).

**Log handle.** `src/native/paris_log_stream.hpp` keeps one open append-mode handle per path (at most 8) and `G_LogPrintf` appends through it; if
the file cannot be opened or written the old open/write/close runs for that line. The component `paris_log_stream.cpp` flushes once per server
frame (`scheduler::loop` on the server pipeline), at every script shutdown (map change, `scripting::on_shutdown`) and at exit (`pre_destroy`). The
bytes on disk are those of the old code, in the same order: `tests/native/log_stream_test.cpp` compares 5,000 lines on two paths with the old
write, `ops/profile/gamelog_compare.py` (server repository) does it on a real run. A reader sees the log at most one frame (50 ms) late; a crash
loses at most the lines of the last frame. `console.log` (`g_consoleLog`, `console::dispatch_message`) is the other append caller; it is not in the
server frame profile and is left as it was, because the console log is what a crash is read from.

## How the fork edits are carried

Same rule as the script accessors (a48): nothing is pushed to the fork repository; the edits are data, `ops/frame-cuts/frame-cut-edits.json`, text
replacements of the pinned `cfca45b` blobs (four in `script_extension.cpp`, two in `game.cpp`, each with the number of matches it must have), applied
by `ops/Apply-FrameCutsOverlay.ps1` in every ServerModules build, recorded in the build manifest as `FrameCutsOverlay`. The new sources
(`paris_vm_filter.hpp`, `paris_log_stream.hpp/.cpp`) are copied with the other native sources.

`script_extension.cpp` is also rebuilt from the pinned blob by the debugger overlay, which refuses any text it does not know. So the edits are made
reversible: `ops/FrameCuts.Core.ps1` can take them out of a text (`Remove-IW7FrameCutText`, used by `Apply-DebuggerOverlay.ps1` before its comparison)
and put them in (`Add-IW7FrameCutText`, used by the overlay, after the debugger step and before the receipt-keeping overlays: cutscene, owner cheats,
voice). `game.cpp` has no other overlay and must equal the pinned blob without the edits (an unowned edit stops the build).

Trap: a native tree that was built with the frame cuts is refused by the debugger overlay of an older branch ("Unowned profiler source edit"). Build
a branch that has them in a tree of its own; the shared tree `a33-native` is not touched by this change until a main with it is built there.

## Tests

`tests/native/vm_filter_test.cpp` (table semantics, false-positive rate), `tests/native/log_stream_test.cpp` (bytes identical to the old write, order,
flush, close, reopen, a second writer, 12 paths with 8 handles, two threads), `tests/ops/frame_cuts_test.py` (edit counts against the pinned blobs, the
stub's instruction order, every writer of the map marks the filter, wiring), `tests/ops/frame_cuts_overlay_test.ps1` (applies on a clone of the
pinned tree; idempotent; removal gives the pinned bytes; with the debugger overlay on twice and off; unowned edits refused),
`tests/ops/cutscene_test.ps1` (a redirect is marked when the filter is in the file). Live: server repository plan
`tests/scenarios/gamelab/frame-cuts-headless.json` (24 functions replaced while the VM runs, 24 neighbours untouched, 2,000 calls in a loop; 22,000 log
lines compared with the expected text and with the old client's file).

## Measured

Old client = the a48 lab client (`el-a3f2b0b1af-2e4db777`), new client = the frame cuts build (`el-ddd9ebd452-2e4db777`, SHA-256 DE7CD250...), same build switches
(`ServerModules,IsolatedLab,Debugger,Perf,AgentCapacity`). Headless, plan `capacity-agents-soak-headless` with `capacity=232,alive=200,margin=2,amin=196,
refill_s=120,until_s=300,session_s=2400`, one engine bot, normal conditions; old and new side by side on the same machine at the same time, with the
server sampling profiler on each (100 Hz). Round 2 swapped the ports. Both rounds on both clients: PASS 168/168 steps, 30/30 expectations, peak alive 200.
Windows with 196 or more alive only (20 and 21 windows of 30 s, about 12,000 frames a side).

| per 50 ms server frame | R1 old | R1 new | R2 old | R2 new |
|---|---|---|---|---|
| frame function (server meter, mean) | 30.50 ms | 22.46 ms | 37.07 ms | 29.07 ms |
| frame function p50 / p99 | 29.9 / 43.7 | 22.0 / 33.3 | 35.4 / 62.4 | 28.0 / 48.8 |
| sampler: inside the frame function | 24.89 | 21.09 | 30.18 | 27.29 |
| sampler: busy outside it (the opcode code cave sits here) | 6.06 | 2.09 | 7.14 | 2.22 |
| sampler: busy in all | 30.95 | 23.18 | 37.32 | 29.51 |
| sampler group "script hook on every opcode" (`get_replaced_pos`) | 3.50 | no samples | 4.10 | no samples |
| sampler group "damage log file writes" (`G_LogPrintf`) | 1.74 | 0.04 | 2.27 | 0.04 |

The frame function is 8.0 ms shorter in both rounds (26 % and 22 %), the busy time of the server thread 7.8 ms shorter in both (a quarter of its
busy time, 16 % of the 50 ms budget). The two machine loads differ between the rounds (the second round ran next to other sessions), the difference
does not. The new client's opcode check is not visible in the sampler (the cave has no unwind data and the fast path is five instructions); its cost
is not measured on its own, only as the part of the difference that the micro runs below also show.

Identical script work in every frame, nothing else running (`frame-cuts-headless`, window `spin`: 200 frames of 20,000 loop iterations, about 200,000
opcodes a frame; three runs a side, old and new in parallel): frame function 3.41 / 3.43 / 3.50 ms old, 2.27 / 2.31 / 2.34 ms new: 1.1 ms less for
200,000 opcodes = 5.7 ns less on every opcode, with one function replaced (the plan's `kick` hook; the production mod replaces about a hundred). Log
(window `logs`: 100 `logprint` lines in each of 200 frames): 24.8 / 25.2 / 25.7 ms old, 1.56 / 1.66 / 1.77 ms new (0.24 ms a line, 0.015 ms a line).

Same bytes: the 22,000-line log of that plan (20,000 lines in bursts of 100 a frame, 2,000 in one frame), old client against new client, three pairs
and one earlier pair: identical after the time prefix (22,002 lines each, same size 903,957 bytes), each file equal to the text the plan must produce
(`gamelog_compare.py check`: nothing lost, doubled, cut or reordered). `replacefunc` through the filter: 24 functions replaced while the VM runs all
reach their replacement, 24 neighbours run themselves, 2,000 calls in a loop all redirect, on both clients.

Regression: `capacity-agents-headless` (n = 100, 78 alive) on the new client: PASS 23/23 steps, 11/11 expectations, peak alive 78 (run a51-n100), as on the
old client (a48-j2b).

Not proven: the production mod's hundred replaced functions through the filter (the plan replaces 25); the cutscene redirect marking (offline
test only, no live cutscene run); a crash within one frame of the last log line (by design the last frame's lines can be lost); the server on the
public machine (nothing was deployed).
