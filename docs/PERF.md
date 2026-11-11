# Performance recorder

## What it is

A recorder inside the lab client plus an offline tool. It answers two questions: how fast does the game run in this scene, and which functions of the game cost the time. It works for the unmodified game and for any change to it.

It is for lab clients only. It needs the flags `-paris-perf` and `-paris-isolated-lab`. It is compiled only when the client is built with `-Perf`:

    ops/Build-Voice.ps1 -ServerModules -IsolatedLab -Perf

The recorder is `src/native/paris_perf.cpp`. The tool is `ops/engine-map/iw7_perf.py`. Function names come from the engine map (`docs/ENGINE-MAP.md`).

For a freeze, where the main thread makes no progress at all, see `docs/HANG.md`. It shares this recorder's stack capture (`src/native/paris_stack.hpp`).

## Recording

Two console commands in the client:

- `paris_perf_begin <name>` starts a window. The name is 1 to 32 characters of a-z, 0-9 and `_`.
- `paris_perf_end` stops it and writes `iw7-mod/paris-perf/<name>.json` in the game folder.

From a test plan: the server repository's gamelab has a `perf` step, `{"do": "perf", "name": "<name>", "s": <seconds>}`. Such a plan starts the client with the recorder and with the frame-rate cap and vsync off. The run folder gets `perf/<name>.json`.

## What a window holds

- Every frame interval, in microseconds. One timestamp is taken per pass of the engine's renderer pipeline.
- A sampling profile. About 600 ticks a second are measured. Each tick samples the main thread, the render thread and three of the other threads in rotation.
- Each sample is the program counter plus the call stack inside the game image. The stack is unwound with the game image's own exception directory (69,384 entries, read at start), without any debugger.
- For a sample outside the game image (system or driver code), the first stack words that point into game code.
- The CPU time of every thread.
- The module list and the process memory.

Sampler rule (safety): between suspending and resuming a thread, the sampler touches no heap, no file and no lock.

## The tool

    python ops/engine-map/iw7_perf.py report WINDOW.json --map <engine map> [--top N] [--json]
    python ops/engine-map/iw7_perf.py compare BASE.json CANDIDATE.json [--json]
    python ops/engine-map/iw7_perf.py folded WINDOW.json --map <engine map> [--role main|render|other]

- `report` prints the frame statistics (frames, fps, median, 95th and 99th percentile, maximum, 1 % low) and, for the main thread, the render thread and the other threads, where each one spends its time: self time, inclusive time of game functions, and system time by the nearest game code on the stack. `--json` prints the same numbers as JSON.
- `compare` says whether the candidate is faster than the base, with a 95 % interval from a block bootstrap, for the mean, the median and the 99th percentile frame time. Give several repeats per side separated by commas. The windows of one side are pooled.
- `folded` prints the stacks in the folded format that flame-graph tools read: `role;outermost;...;leaf count`.

Example output, synthetic numbers (the main thread part of `report`):

    window scene: 2.0 s
    frames 100  194.2 fps  median 5.000 ms  p95 5.000  p99 20.000  max 20.00  1% low 50.0 fps  frames over twice the median: 1
    sampler 600 ticks a second, 33 samples, 0 dropped; memory 200 MB private

    main thread: 1, CPU 150 ms (8% of one core), 21 samples, 19% of them waiting in the system
      self time (where the thread was):
         47.6%  Foo
         19.0%  [ntdll.dll]
         14.3%  Multi
      inclusive time (game functions on the stack):
         66.7%  Foo
         61.9%  Multi
      system time, by the nearest game code on the stack:
         19.0%  [ntdll.dll]  <-  Multi

## First real measurement

10 Nov 2026. Unmodified game, map cp_zmb at the spawn point, no zombies, window 1280x720, uncapped, 20 s windows. Intel Core i5-13400F, NVIDIA RTX 3080.

- View "still": 3,666 frames, 184.0 fps, median 5.24 ms, 99th percentile 9.54 ms, max 18.49 ms, 1 % low 84 fps.
- View "still_b" (turned 90 degrees): 318.2 fps, median 2.91 ms, 99th percentile 5.07 ms.
- Sampler: 592 ticks a second, 58,985 samples, none dropped, 76 threads.
- In "still" the render thread used 94 % of one core. 24.4 % of its samples were in d3d11.dll and 11.2 % in the graphics driver. The largest game function was 6.1 %.
- In "still" the main thread used 55 % of one core. 39 % of its samples were waiting in the system. `CG_DrawActiveFrame` was on 36.3 % of the main thread's stacks.

So in that scene the render thread is the limit.

## Run-to-run noise

The same client and plan, run twice:

- "still": 184.0 then 192.0 fps. The median frame time differs by 2.5 %.
- "still_b": 318.2 then 331.9 fps. The median frame time differs by 3.9 %.

`compare` on one window a side called these "faster", because its interval covers frame-to-frame noise only.

Rule: a change below about 5 % is not established by one run a side. Repeat each side at least three times and pass the repeats separated by commas. Treat the base's own run-to-run spread, which `compare` prints, as the floor.

## Limits

- The frame clock is the renderer pipeline's pass. It is not proof of displayed frames.
- There is no GPU timing. A sample in the graphics driver says the thread was there, not how long the GPU took. The
  graphics card's time per pass comes from a RenderDoc capture: server repository `docs/GPU-PASSES.md`. The dedicated
  server's frame time and script cost: `docs/SERVER-PERF.md`.
- Stacks stop at the edge of the game image. For system samples there is only a nearest-game-code hint.
- The sampler itself costs time. This is not yet measured. Compare a build with and without `-paris-perf` windows open before quoting absolute numbers.
- Names are only as good as the engine map. Calls through registers and tables are not in the map.

## Tests

`tests/ops/perf_window_test.py` runs the tool on synthetic windows and a small synthetic engine map. It uses no recorded data.
