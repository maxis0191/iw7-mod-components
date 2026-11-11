# Server meter: server frame time and script cost per function and per thread

## What it is

A meter inside the lab dedicated server plus an offline reader. It answers: how long does each server frame take,
and which script functions and which script threads cost that time. It exists so that the Station Zero budgets
("under 0.3 ms of server frame", "scripts under 0.5 ms of server frame") can be measured instead of guessed.

It is compiled only into a client built with `-Perf` (the server is the same executable started with `-dedicated`),
and it is active only in a dedicated server started with `-paris-isolated-lab`, which the headless gamelab runner
always adds. Source: `src/native/paris_sperf.cpp`. Reader: `ops/engine-map/iw7_sperf.py`.

## Recording

Two console commands of the server:

- `paris_sperf_begin <name>` opens a window (1 to 32 characters of a-z, 0-9 and `_`).
- `paris_sperf_end` closes it and writes `iw7-mod/paris-sperf/<name>.json` in the server's game folder.

From a headless gamelab plan (server repository, `docs/GAMELAB.md`) they are `cmd` steps:
`{"do": "cmd", "text": "paris_sperf_begin base"}`, a `wait`, then `{"do": "cmd", "text": "paris_sperf_end"}`. The
headless runner moves the windows into `<run>/sperf/` before it removes the bench.

## What a window holds

- Every server frame: its start and how long the engine's server frame function ran (0x140B15E20, the function
  iw7-mod's scheduler calls once per server frame; the script VM's threads run inside it), measured with the
  performance counter around the call. This is the time the server spends on a frame, not the 50 ms between frames.
- A sampling profile of the script VM: about 1,000 times a second the sampler suspends the server thread and reads the
  VM's call stack (the frames of `scr_VmPub`, and for the running frame the position kept in `scr_function_stack`).
  A sample is "script" when the VM has at least one frame, "frame without script" when the thread is inside the server
  frame function but no script runs, "idle" otherwise.
- The function table iw7-mod keeps of every loaded script (file, function, start of its code), so the reader turns
  code positions into `file::function` offline.

Outside a window the cost is two counter reads and one flag test per server frame.

Sampler rule (as `paris_perf`): between suspending and resuming the thread it reads plain memory only. A frame pointer
outside the VM's frame array counts as a failed sample.

## The reader

    python -B ops/engine-map/iw7_sperf.py report WINDOW.json [--top N] [--json]
    python -B ops/engine-map/iw7_sperf.py compare BASE.json CANDIDATE.json [--top N] [--json]

- `report`: server frames (count, rate, mean, median, 95th and 99th percentile, maximum, frames over 33 ms), the
  sampler counts, the script time per server frame, then three tables in milliseconds per server frame with a
  two-sigma interval: self time (the running function), inclusive time (the function anywhere on the stack), and
  threads (the outermost function of the stack, which is the function a thread was started with).
- `compare`: the change of the server frame time, and the script functions and threads whose time per frame changed
  most; `largest increase` names the function that grew most beyond its interval. Several windows per side can be
  given separated by commas; they are pooled.

A cost in milliseconds per server frame is the share of the window the server thread spent there (samples over
ticks) times the window's length, divided by the number of server frames.

## Proof

PROOF_PLACEHOLDER

## Limits

- The running frame's position is read from `scr_function_stack`. The interpreter (`sub_140C0CFE0`, called by
  `VM_Execute`) stores the code position there at every opcode dispatch (`mov [0x146B22908], rsi` at 0x140C0D0C2, next to
  the opcode store at 0x140C0D0B2), so it is at most one instruction old. Builtin functions (engine code called from
  script) count to the script function that called them.
- A callback the engine runs from outside the server frame function (for example a client command) is still sampled
  as script, with `frame` 0 in its stack row; the frame time does not contain it.
- Nested VM calls (a builtin that runs another script function) add their frames to the same stack: the outermost
  function is then the first thread's.
- One window at a time; the server thread is the thread that ran the first server frame.

## Tests

`tests/ops/sperf_report_test.py` runs the reader on synthetic windows.
