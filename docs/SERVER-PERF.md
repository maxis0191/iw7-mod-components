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

- Every server frame: its start and how long the game's frame function ran (0x140B213F0, G_RunFrame of the CP game
  module: it takes the level time, stores it, counts the frame, runs the script VM's threads and iw7-mod's server
  scheduler pipeline), measured with the performance counter around the call. A first build timed 0x140B15E20 (the
  call iw7-mod's scheduler wraps): it took 0 us a frame and the script ran outside it, so it is not the frame. This is the time the server spends on a frame, not the 50 ms between frames.
- A sampling profile of the script VM: about 600 times a second, each tick moved by a random 0 to 1 ms so the samples do
  not lock to the server frame's timer grid, the sampler suspends the server thread and reads the
  VM's call stack (the frames of `scr_VmPub`, and for the running frame the position kept in `scr_function_stack`).
  A sample is "script" when the VM has at least one frame, "frame without script" when the thread is inside the server
  frame function but no script runs, "idle" otherwise.
- The function table iw7-mod keeps of every loaded script (file, function, start of its code), so the reader turns
  code positions into `file::function` offline.
- Snapshot entity counts (key `snapshot`, read only: no cap is changed), per list `calls`, `max`, `mean`, `capped` (calls whose count had reached the
  cap, so the list was closed early) and `cap`:
  `entities` is the entity records of ONE client's snapshot list: `FUN_140C67230` writes it and counts the records in the dword at `[rsp+0x40]` of its
  frame; the list is closed with 0x7FF (11 bits) at 0x140C6765B, the single exit of both the normal end and the cap path (cap: `[0x146B3985C]`,
  `sv_maxSnapshotEntities`, 768; the loop stops at `cmp eax,[0x146B3985C]`, 0x140C67478), so the call there is replaced by a stub that reads the count
  (the frame is `_AddressOfReturnAddress()` + 8) and runs the original call unchanged; one call per client per snapshot. `common_a` is `FUN_140C64310`'s
  return value (the all-client list, cap `[0x146B39858]` = 1024; wrapped as a detour). `common_b` is the count the list of entities above 17 holds in `[0x146B39830]` (cap `[0x146B39860]` = 1024; `FUN_140C647A0` builds it once after a reset by `FUN_140C64BA0` (it writes the count and the built flag `[0x146B3CC0C]`), not every frame: the first smoke run saw no call of it in 600 s of frames, so the value is read once per frame inside the list A hook; `calls` of `common_b` therefore equals those of `common_a`). "Capped" means count >= cap: a list that holds exactly the cap and no more is counted as capped too. Every hook compares the expected code bytes
  first and is left out with an error line when they differ (the line `snapshot counters installed=<n> of 2` says how many were installed).

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

Run live on 11 Nov 2026 (i5-13400F; headless gamelab, cp_zmb, one bot, waves off; client built from commit 80d1aad
with `-Perf`; evidence in the agent's run folders `IW7-Runtime/tf9/sperf-3`, `sperf-4`, `sperf-5`, outside the
repositories). The server repository's plan `tests/scenarios/gamelab/headless-sperf-burn.json` with
`tests/fixtures/sperf_burn.gsc` (installed with `-ServerCopy`) opens a 20 s window `base`, switches on 6,000
iterations of arithmetic every server frame in the script function `sperf_burn_work` (thread `sperf_burn_loop`), and
opens a 20 s window `burn`. Three runs, each PASS, 400 server frames a window, about 550 sampler ticks a second.

| Run | Frame median, base -> burn (exact) | `sperf_burn_work` self time (sampled) | Named as largest increase |
|---|---|---|---|
| 1 | 0.553 -> 1.949 ms (+1.396) | +1.110 ms +-0.142 | yes |
| 2 | 0.566 -> 2.007 ms (+1.441) | +1.191 ms +-0.147 | yes |
| 3 | 0.560 -> 1.959 ms (+1.399) | +1.178 ms +-0.147 | yes |
| pooled (`compare` with three windows a side) | 0.560 -> 1.968 ms (+1.409) | +1.160 ms +-0.084 | yes; thread `sperf_burn_loop` +1.158 ms |

So the provoked cost is found and named by function and by thread, and the two meters agree to within 0.25 ms: the
exact frame timer says +1.41 ms, the sampler gives +1.16 ms to the function and +0.26 ms to other script (the
animation update thread `notetracks_mp::ai_update` +0.18 ms, which this run does not explain). Base: script costs
about 0.15 ms of a 0.56 ms server frame with one bot and no wave.

Two corrections came from these runs. A first build timed 0x140B15E20 (the call iw7-mod's scheduler wraps): every frame
read 0 us and the script ran outside it, so the meter now times G_RunFrame. And without the random offset the samples
locked to the timer grid: 4,000 iterations read 0.054 ms a frame and 70,000 read 11.9 ms, 13 times apart per
iteration; with the offset 6,000 iterations read 1.1 ms, in line with the frame timer.

A window is about 300 KB; most of it is the function table (210 script files, 8,169 functions on cp_zmb).

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

## Light windows and slow frames (a74, 16 Nov 2026)

The commands below are in `src/native/paris_sperf.cpp`; the flight recorder of the server repository (`docs/ZOMBIE-CAPACITY.md` 6e, `ops/play/flight_report.py`) uses them.

- `paris_sperf_begin <name> light` (and `paris_perf_begin <name> light` in the client's meter, `src/native/paris_perf.cpp`): the same window without the sampler thread. It holds the server frame times, the snapshot entity counters and the CPU of the process over
  the window (`cpu_seconds` in the window file of the server meter, new; `user_ms`/`kernel_ms` of each thread in the client's). The sampler thread (a thread suspension about 600 times a second)
  was measured at +0.27 of a core on the server and +0.24 on the client while a window is open (a68); a light window has no such thread. The file says `"sampler":{"mode":"light",...}` with no ticks and no stacks, and `iw7_sperf.py` and
  `iw7_perf.py` read it (frame statistics; no script cost). A window without the word is as before.
- `paris_fr_slow <ms>`: the slow-frame watchdog, off by default (0). One thread wakes every 4 ms and reads two atomics (the frame in progress and when it began). Only when the frame in progress is already older than `<ms>` it suspends the server thread
  for one read of the script VM's call stack, as the window sampler does, up to 12 times in that frame. At the end of such a frame the server thread writes one line:
  `[FR] t=<level time> native_slow_frame ms=<the frame> serial=<frame count> samples=<n> script=<n in script> engine=<n outside the script VM> leaf=<innermost functions, counted> thread=<outermost functions, counted>`.
  The line goes to the server's game log (`iw7-mod/logs/games_mp.log`) through the buffered handle `G_LogPrintf` uses (`paris_log_stream`), not to the console: console output costs about 0.16 ms for every byte on the lab server
  (a 1,300 byte `print` added 215 ms to a frame at 200 alive, 16 Nov 2026), so a recorder that printed would make the frames it measures. The same holds for GSC `print` in any recorder: use `logprint`.
  The frame is sampled while it runs, so the line names what made THIS frame slow (a script function by file and name), and `engine=` counts the samples that found no script running (the frame was in engine code). The first <ms> of the frame are not sampled.

Cost: see the measured runs in the server repository's `docs/ZOMBIE-CAPACITY.md` 6e.


## Weapon gives (a80, 17 Nov 2026)

`src/native/paris_weapon_log.cpp`, option `-paris-weapon-log` (dedicated server; compiled into every build, inert without the option; the play launcher of the server repository passes it, `-NoWeaponLog` removes it).
Every call of the script methods `giveweapon` (0x817D), `takeweapon` (0x83B8), `switchtoweapon` (0x83B5) and `switchtoweaponimmediate` (0x83B6) writes one line to the game log (`iw7-mod/logs/games_mp.log`, through
`paris_log_stream`, the file the slow-frame watchdog and the script recorder write to; the flight recorder collects it):

`[FR] t=<level time> weapon_give fn=<call> ent=<entity number> w=<weapon name> frame=<server frame> caller=<file::function> chain=<outer callers, innermost first, joined by '<'> verified=<1|0>`

- Where it hooks: the engine's method table (`gsc::meth_table`, the array the script VM dispatches through, `script_extension.cpp`). The engine fills it at game start; the component's server-pipeline loop replaces the four entries by wrappers
  the first frame it finds a stock handler there (and again if the engine fills the table again) and writes `[FR] t=<time> weapon_log_handler fn=<call> id=<id> handler=<address of the stock handler>`. Earlier hooks on `G_GivePlayerWeapon` and on a
  guessed builtin never fired (the script give does not pass through them); the table entry is the function the VM calls.
- The hook does: read the call, append a fixed record (4,096 of them, server thread only, no lock) and call the stock handler. A full ring counts `lost`; a call from another thread counts `foreign`. Names are made once a server frame in the scheduler's
  server pipeline (the same thread, so the script function table cannot change under it) and cached by code position; the ring is also written at a script shutdown. A `weapon_log_stats recorded= lost= foreign= written= hook_ns= drain_ns=` row follows every minute of server frames
  with gives and at once when something was lost.
- How the caller is read: `scr_function_stack->pos` is the code position just after the call opcode, inside the calling function; `scr_VmPub->function_frame_start[k].fs.pos` hold the outer frames of the same thread (as `paris_sperf.cpp` reads them). Positions are mapped to
  `file::function` through the function table iw7-mod keeps (`scripting::script_function_table_sort`). `verified=1`: the two bytes before the position are the id of the method that runs, so the call came from script bytecode. A call from native code (the owner's `give` console command goes
  through `scripting::call`) leaves the position of whatever script ran before and is written `verified=0`. The chain ends at the root of the thread (a thread resumed by a notify or a wait has no outer frames); the names are the compiled ones: a production script that
  `#define`s an alias (`#define upgrade_players check_owner`) shows `check_owner`, and `ops/play/flight_report.py` translates them back.
- `-paris-weapon-log-measure`: the hook times itself (`paris_weapon_log_stats` prints `hook_ns_per_call` and `drain_ns_total`). Not for play.
- Cost (measured 17 Nov 2026, headless production server, Rush on, client built from 56f71e5; plans `tests/scenarios/gamelab/weapon-give-recorder-cost-*.json` of the server repository, reader `ops/play/burst_cost.py`): a burst is 500 `giveweapon` plus 500 `takeweapon` in one server frame (1,000 calls),
  10 bursts a light window, 2 windows a session. **The hook:** 52.7 to 63.9 ns a call, timed inside the hook with two performance counter reads (`-paris-weapon-log-measure`, 20,000 calls; the counter reads are part of the figure, so it is an upper bound). **The drain** (naming the caller and chain, formatting, one append to the log handle
  per frame): 21.0 ms for the 20,000 calls, 1.05 us a call, on the server thread at the end of the frame that held them. **Frame time A/B** (3 sessions a side, 6 windows, 60 burst frames a side): off 5.565 ms a burst, on 6.117 ms: +0.553 ms a burst (+0.55 us a call), with 0.71 ms of noise between windows, so the difference is below the resolution of the frame time (it agrees with hook plus drain, about 1.1 us a call).
  A real session gives a few dozen weapons a minute (the 300 s session of the proof: 220 calls, 0.7 a second): the cost is a few hundred microseconds of the server's time in a minute. 20,000 calls in a minute lost no record (ring of 4,096; a frame holds at most 1,000 in these bursts).
- What it does not see: a weapon the engine gives from native code that does not run the script methods (a perk, a game rule inside the engine), and a method called through `gsc::method::add`'s custom path (none of the four is).

## Tests

`tests/ops/sperf_report_test.py` runs the reader on synthetic windows.
