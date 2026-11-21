# Console and log writer: a print never waits for the console

## Why

On the dedicated server a console line is a synchronous hand-off from the printing thread to other processes and files. Measured in the server
repository (`docs/PRINT-COST.md`, the debugger builtin timing over 35 sessions): one GSC `print` costs 1.4 to 4 ms, at most 202 ms in play, 537 and 656 ms
at load with console writers beside the server; `logprint` (the game log) at most 0.16 ms. A 242.6 ms server frame was explained to the call: 12 of 12
samples in the plan's function, `print` 202.4 ms in the same second. The script side moved its hot prints to `logprint`; the engine still blocks the
server thread on every console line (engine lines, error lines, any mod's `print`). This is the structural fix that document names.

## The chain of one console line (pinned iw7-mod cfca45b, lines of the pinned blobs)

1. GSC `print` and `println`: `function::add("print"...)` in `src/client/component/gsc/script_extension.cpp:334`, which ends in `console::info("%s\n", ...)`.
   The engine's own `Com_Printf` (`0x140343080`) is hooked to `logger.cpp print_info`, and four `Sys_Print` call sites (`0x140C6E57A`, `0x140C13641`,
   `0x140519772`, `0x140B712BA`) to `sys_print_stub`; both end in `console::info`/`console::print`.
2. `console::print` formats and calls `console::dispatch_message` (`src/client/component/console/console.cpp:118`). On the thread that printed it:
   - `rcon::message_redirect`;
   - **the console log**: `utils::io::write_file(g_consoleLog, line, append)` is a `CreateFile`, a `WriteFile` and a `CloseHandle` for every line
     (default `iw7-mod/logs/console.log`), on the disk, through any virus scanner;
   - **the console screen**: the dedicated server's console type is `terminal` (`con_type_default`, `console.cpp:30`), so
     `terminal::dispatch_message` (`console/terminal.cpp:318`) runs under `print_mutex` (a recursive mutex the console input thread also takes) and
     calls the Win32 console API, each call a synchronous round trip to `conhost.exe`: `clear_output` (`GetConsoleCursorInfo`/`SetConsoleCursorInfo`,
     `GetConsoleScreenBufferInfo`/`SetConsoleCursorPosition` twice, 8 calls), `set_cursor_pos(0)` (2), `SetConsoleTextAttribute` (2, before and after),
     the line itself through the CRT `printf` (a `WriteFile` on the console handle), then `update()` which redraws the input line (9 calls). About 22
     round trips and a file open per line. With `-stdout` the same code runs against a redirected handle (`main.cpp:157`, unbuffered): a file write per
     byte block.
   - `game_console::print` returns at once on a dedicated server.
   - Not part of `dispatch_message` but the same kind of call: `dedicated.cpp:475/493` sets the console title every second through `console::set_title`, which is a
     `SetConsoleTitleA` (a round trip to the console host) on the main thread every second, changed or not. `set_title` now skips an unchanged title.
3. Which one blocks: the round trips to the console host. When `conhost.exe` is busy or descheduled (a machine at 80 to 100 %, six console writers beside
   the server) every one of them waits for it; `ops/gamelab/console_stall.py` (server repository) makes this certain by suspending that process, and the
   stall of a frame follows. `logprint` never touches it. It is a sink, not a lock shared with another engine thread, so the fix is to move the sinks to
   a thread of their own.
4. The same path is taken by the CRT `printf` that `terminal.cpp` hooks (`printf_stub`, line 306 to 314): it calls `terminal::dispatch_message` directly and is not
   queued (a handful of lines from the process's own code; see the limits).

## What was built

- `src/native/paris_console_writer.hpp` (no game types, tested alone): `queue` is a bounded ring of 4096 lines and 1 MiB of text (slots keep their
  string capacity, so a push copies bytes and allocates nothing once warm); `writer` owns the ring and one thread.
- `src/native/paris_console_writer.cpp`: the component. In a dedicated server it starts the writer in `post_unpack`.
- `ops/frame-cuts/frame-cut-edits.json` (the overlay of fork edits as data, `docs/FRAME-CUTS.md`) edits three fork files:
  - `console/console.cpp`: `dispatch_message` keeps the rcon check, then offers the line to `paris_console_writer::submit`; when it is taken the call returns.
    The old body is `write_sinks`, run by the writer thread through `console::dispatch_message_queued`; there the console log is appended through the kept
    handle of its own (`paris_console_writer::console_log_stream()`, an `append_log` of `paris_log_stream.hpp`, flushed after every batch) instead of open/write/close per line;
    it is not the instance `G_LogPrintf` uses, so the game log's mutex never waits for this disk write. `set_title` skips an unchanged title.
  - `exception.cpp`: the crash wait described below.
  - `console/terminal.cpp`: the screen sink is split: `dispatch_message_direct` (the old body without the rcon check) and `dispatch_message` (rcon check, then
    the direct sink). The writer thread uses the direct one: the rcon check belongs to the thread that printed the line, a line queued before an rcon
    command must not be sent to the rcon client when the writer gets to it later.

The producer holds one mutex for the copy of one line and returns. It never waits for a sink and never allocates in steady state.

## Behaviour

- **Order and bytes**: one writer, one ring, FIFO: the same lines in the same order as the old synchronous path; the bytes of a line are copied unchanged
  (embedded NULs too). Lines of different threads interleave in the order they reached the ring.
- **Full ring**: the new line is dropped, counted, and the writer writes `[console writer] dropped N lines` at the place of the gap, when it gets there.
  A producer is never blocked. A line longer than the ring (1 MiB) is dropped.
- **Start-up and shutdown**: lines before the component starts (and every line in a client, a `-syscon` window, or with the switch off) are printed on the
  calling thread as before. `pre_destroy` and `atexit` close the ring, the writer writes what is queued, prints its counters and ends (waits at most 3 s
  for a writer that is stuck in a sink, then leaves it); lines printed after the close are printed on the calling thread.
- **Crash**: the game's own exception filter (`exception.cpp`, `exception_filter`) calls `paris_console_writer::wait_for_lines_on_crash()` before it writes its
  dump: it waits up to 300 ms until every line accepted so far has been written by the sinks and flushed (a lock-free counter, set after the flush of the batch
  that held the line, so a line the writer already took out of the ring but has not written is waited for too). It returns at once on the writer thread and when
  the writer is not running. Nothing else is hooked: no vectored handler, so exceptions the engine handles itself (Arxan, the write watch) are untouched.
- **Tools that read the console**: the console log is flushed after every batch (a few ms behind); the start-up lines (`/nickname` self-test line, `Ready`,
  `[script variables]`, `[agent capacity]`) arrive as before, a few ms later.

## Counters

`queued`, `written`, `dropped`, `max_enqueue_us` (the longest time a producer spent in `submit`), `max_sink_write_us` (the longest single sink write),
`slow_sink_writes` (sink writes over 50 ms). One line, `[console writer] queued=... written=... dropped=... max_enqueue_us=... max_sink_write_us=...
slow_sink_writes=...`:

- once a minute, only when something was dropped or a sink write exceeded 50 ms in that minute;
- always when the writer stops;
- on demand: console command `paris_console_writer_stats`.

## Switch

On by default in a dedicated server of a ServerModules build (the component is compiled only there: the fork edits exist only at that pin).
`-paris-no-console-writer` on the command line turns it off: the server prints on the calling thread exactly as before (use it for the A side of an A/B run).

## Limits (what this does not do)

- The CRT `printf` hooked by `terminal.cpp` (`printf_stub`) is not queued; a line printed that way can be written before queued lines that were printed earlier.
- `-syscon` (a window owned by the main thread, `SendMessage` into it) stays synchronous.
- `g_consoleLog` is read by the writer thread when it writes; changing the dvar while lines are queued applies the new path to them (the dvar is set at launch).
- A writer stuck in `conhost.exe` stops the console output, not the server: lines queue, then drop and are counted; the console log stops with it (one writer for
  both sinks, to keep the order). Splitting the two sinks into two writers is the next step if the stuck case is measured in the field.
- Not compiled and not measured yet: the header, the component and the unit test were written without a build (the lead builds); see the plan below.
- The claim that the console host round trips are what blocks rests on `docs/PRINT-COST.md` and `ops/gamelab/console_stall.py` of the server repository (suspending
  `conhost.exe` makes `print` stall, `logprint` not), not on a measurement made for this change.

## Tests

`tests/native/console_writer_test.cpp` (compiled and run by `ops/Build-Voice.ps1` with the other native unit tests; no game): ring order and bytes, wrap-around,
a full ring drops and counts and the notice sits at the gap, byte limit, close, a stalled sink (20 ms a line, 100 lines) does not stall the producer (under 500 ms),
shutdown writes what is queued, a closed writer refuses lines, six producers of 5,000 lines (each producer's own order kept, none dropped), a throwing sink keeps
the thread. Standalone compile, from a Visual Studio command prompt: `cl /nologo /std:c++17 /EHsc /W4 /WX /Od /RTC1 tests\native\console_writer_test.cpp`.
`tests/ops/frame_cuts_test.py` and `tests/ops/frame_cuts_overlay_test.ps1` check the fork edits against the pinned blobs (counts, order of the hand-off after
the rcon check, removal gives the pinned bytes).

## A/B plan (the lead measures)

Same build, switch on against `-paris-no-console-writer` (same machine, same time, three pairs; the server repository, `docs/PRINT-COST.md` method):
1. `tests/scenarios/gamelab/rush-boundary-stall-headless.json` with `python -B ops/gamelab/console_stall.py --bench-parent <bench folder>` beside it (suspends the console host
   300 ms after each `round_end`): without the writer frames over 100 ms with `leaf=paris_rush::array_levelthread`, with the writer none from console prints.
2. `tests/scenarios/gamelab/print-cost-modes.json` (cost of one `print` per console mode; read with `ops/play/window_cost.py`): `print` mean frame cost should drop
   to that of `logprint`.
3. `tests/scenarios/gamelab/print-cost-session.json` (200 alive, 15 rounds), with six console-writing processes beside the server: frames over 75 and 100 ms and the
   `[console writer] ... max_enqueue_us=` line.
Read in each run: the `[console writer]` line at the end of `server.stdout.log`, and that `dropped` is 0.
