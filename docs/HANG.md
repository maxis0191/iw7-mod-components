# Freeze reporter

Status: built and run live on 10 Nov 2026 (see "Run live, 10 Nov 2026").

## Run live, 10 Nov 2026

The reporter compiled at the first build (65.5 s) and ran in 12 private loopback sessions. In every session the client and the server each wrote one report, for the map load: the main thread makes no progress for more than 2 seconds while loading. So a normal map load produces a report, and reports during loading are expected.

Example, client: a freeze of 6,055 ms with 8 samples. 75 % of the samples are on one stack that waits in the system library below a chain of six game functions. One sample is inside `DB_FindXAssetHeader`. 80 other threads are listed.

The absence of a report is information too. A join stall (about one lab join in three stops after the server's info reply) was captured with the reporter on and no freeze report was written; the client still answered a later `stop` request. So that stall is not a frozen thread.

## What it is for

When the game's main thread stops making progress, a freeze or a long hitch, the usual result is "it hung". This reporter records where the thread is stuck. A developer gets function names instead.

It is for private lab builds only. It runs inside the game process, on a client and on a dedicated server.

## How to enable

Start the game with both flags:

    -paris-hang -paris-isolated-lab

Both are needed. Without them the component does nothing. It is always compiled, so no build switch is needed. The code is `src/native/paris_hang.cpp`. The stack capture it shares with the performance recorder is `src/native/paris_stack.hpp`.

The threshold is 2000 ms. The environment variable `PARIS_HANG_MS` can set another value from 250 to 60000. It is read once at start. A value that is missing, not a number or out of range is ignored and the default is used. The console flag `+set` is not used, because it is not reliable this early.

On start the console prints `[Paris hang] ready process=<client|server> threshold_ms=<n> unwind=<0|1>`.

## How it works

The main loop stores the time of its last pass on every pass. On a dedicated server the server loop stores its own time as well. A watchdog thread wakes every 250 ms and compares those times with the clock.

When a time is older than the threshold, a freeze begins:

- The watchdog samples the stuck thread at once, then every 500 ms, up to 240 samples.
- It samples every other thread of the process once, at the start. A frozen thread is often waiting for another one.
- It writes one file when the loop comes back.
- After 120 s of freeze it writes the file anyway and marks it `still_frozen`. It keeps watching, and the console line is printed when the loop finally returns.

A freeze shorter than the threshold writes nothing. Two freezes are two files, even less than a second apart. At most 50 files are written per run. Later freezes are only counted, and the console line says "not written".

A map load that blocks the main loop for longer than the threshold also counts as a freeze.

After the loop is back, the main thread prints once:

    [Paris hang] main thread made no progress for <ms> ms; written <file name>

## What a file holds

The file is `iw7-mod/paris-hang/hang-<UTC yyyyMMddHHmmss>-<n>.json` in the game folder. Schema `iw7.hang/1`.

- `pid`, `process` (`client` or `server`), `began_utc`, `frozen_ms`, `threshold_ms`, `still_frozen`.
- `image`: the game image, as in a performance window.
- `main_thread`: the id of the stuck thread. `stalled_pipeline` says which loop stopped (`main` or `server`).
- `samples`: for the stuck thread, a list of `[milliseconds since the freeze began, "pc;pc;...", "scan;scan"]`. The first list is the program counter and the call stack inside the game image, leaf first. The second list is used when the program counter is outside the game image: the first stack words that point into game code.
- `others`: the same for the other threads, as `[thread id, "pc;...", "scan;..."]`.
- `modules`: base, size and name of every module, to name addresses outside the game image.
- On a server only: `server_pipeline_frozen`, true when the server loop was stopped as well.

All addresses are hexadecimal. The engine map turns them into names.

## The reader

    python -B ops/engine-map/iw7_hang.py report HANG.json [--map MAP.sqlite] [--json] [--top N]

Without `--map` only addresses are shown. The engine map is described in `docs/ENGINE-MAP.md`.

How to read the output:

- The header says the process, how long it was frozen, and how many samples there are.
- "Where the main thread was" lists each distinct stack once, leaf first, at most 12 frames. Each stack has its share of the samples and the time range it covered. The stack with the most samples is marked `stuck here`. `--top` limits how many stacks are printed.
- A stack that starts in a system module is shown as `[module]`, followed by the nearest game code found on the stack.
- "Other threads at the start" has one line per thread: its leaf, and the first game frame after it.
- The last line is the signature.

Exit code 2 means the file has another schema, is truncated, or is damaged. `--json` prints the same content as an object, with the `signature` key.

## The signature

The signature is one line, fit for the problem ledger:

    freeze in <leaf> < <first game frame> < <second game frame>

It comes from the stack marked `stuck here`. Offsets are removed, so the same freeze gives the same line each time. Example (illustrative names): `freeze in [ntdll.dll] < CL_Frame < Com_Frame`.

## Safety rule of the sampler

Between suspending a thread and resuming it, the watchdog does nothing but read the thread's context and unwind its stack. It touches no heap, no file and no lock, because the suspended thread may hold any of them.

The watchdog also avoids the heap while it builds and writes the report. Its buffers are static and the file is written with plain system calls. It never uses the game's console. The thread list and the module list are taken before any thread is suspended.

## Limits

- Stacks stop at the edge of the game image. A thread blocked inside the system shows that module, and only the nearest game code from the stack.
- A thread that waits for another thread shows only the wait. The cause must be read from the "other threads" list.
- The other threads are sampled once, at the start. A thread that moves on later is not seen.
- The sampled stack is only as good as the game's unwind data. A function without data ends the stack early.
- Names are only as good as the engine map.
- A freeze is detected by the heartbeat of the main loop. A stall that does not stop the loop, such as a long frame that still completes in time, is not seen. Use the performance recorder for that (`docs/PERF.md`).

## Tests

`tests/ops/hang_report_test.py` runs the reader on synthetic reports and a small synthetic engine map. It uses no recorded data. The native part is not covered by an automatic test yet.
