# Network update measurement

Status: run live on 10 Nov 2026 (private loopback sessions through the network lab's proxy, lab client built from commit 4aeb6e1df4). The addresses below were found by memory-watch recordings, not taken from the loader's `cg_s` declaration (see "Where the values are"). Default session: 421 updates in 21.9 s (19.22 a second); the proxy's median gap between server packets was 47.6 ms (21 a second) and it counted 31.0 packets a second in all. Bad-network session (ping 300, jitter 30, loss 5 percent, burst 30): 214 updates in 16.7 s (12.79 a second), 22 late updates, 4 stalls, 64 skipped updates; the proxy dropped 55 of 668 packets. Not confirmed: that the counter is the server's snapshot number (it behaves like a sequence number, but no engine source was read); that jumps above 1 are lost updates and not two updates read in one pass.

## What it is

A small recorder inside the lab client, one extra field in the server trace, and an offline reader. It answers: how often does the client get a new update from the server, how even is that stream, and how far ahead of the server does the client's own predicted time run.

## On the client

`src/native/paris_net.cpp`. It looks at the client game state once per pass of the engine's main pipeline, while the client is in the active connection state. It reads three values (addresses in "Where the values are"):

- the update counter: a number that rises by 1 for each update of the server's stream,
- the server time carried by the latest update,
- the client's own frame clock.

All three are at fixed places in the game image: two inside the client connection data (reached through a pointer at a fixed address), one a static global. The recorder checks that the client is active, and that the pointer's memory is committed and readable, before each read.

Each time the update counter changes it keeps:

- the wall-clock gap since the previous change, in microseconds (QueryPerformanceCounter),
- the server time step since the previous change, in milliseconds (this is the server's update interval as the client received it),
- how far the client clock is ahead of the latest server time (in ms),
- the jump in snapshot number. A jump above 1 means updates were skipped; the sum of (jump - 1) is `skipped_updates`.

It also counts passes of the main pipeline and the longest run of passes without a new update. The first number seen after the client becomes active is a baseline, not an update. If the number goes backwards (a new match on the same connection) that update has no gap or step and is counted in `discontinuities`.

The arrays are sized at start (200,000 entries each). After that only counters advance and `truncated` is true. The main thread only reads the three values and stores numbers. A writer thread formats the file.

Output: `iw7-mod/paris-net/client.json`, rewritten every 5 seconds and when the client shuts down. Schema `iw7.net-client/1`: `pid`, `seconds` (active time), `passes`, `updates`, `skipped_updates`, `longest_passes_without_update`, `discontinuities`, `gaps_us`, `server_time_steps_ms`, `ahead_ms`, `first_snapshot_num`, `last_snapshot_num`, `truncated`, `source`. The console shows `[Paris net] ready` at start and `[Paris net] written updates=<n> seconds=<s>` at each write.

## Where the values are

Found on 10 Nov 2026 with `docs/MEMORY-WATCH.md` recordings (copies 10 ms apart; the client runs at 60 frames a second, so one copy per frame), read with `iw7_watch.py`. The loader's `cg_s` fields `latestSnapshotNum` and `latestSnapshotTime` (offsets 492896 and 492900 of the structure at 0x141FA6C88) were tried first and saw no updates in 25 s: nothing in the 890,000 bytes from 0x141FA6C88 behaved like an update counter.

| Value | Address | Behaviour (default session `snap/s04`) | Behaviour (bad network `snap/s06`) |
|---|---|---|---|
| pointer to the client connection data | 0x141FE58B8 (the loader's `cl_con_data`) | 0x26D90C7B0 in every session (s02, s04, s06) | same |
| update counter | pointer + 0x2014C | 99 changes in 4.94 s, every step 1, rise 20.02 a second | 90 changes, steps 1 and 2 (10 steps of 2), rise 20.22 a second |
| server time of the latest update | pointer + 0x20024 | 99 changes, jumps of 16 to 80 (mostly 48), rise 1003.5 ms a second | 95 changes, jumps up to 144, rise 1003.9 ms a second |
| client frame clock | 0x141FE5EAC (also pointer + 0x2003C) | changes every frame, steps of 16 to 17, 1000.7 ms a second | same, 1000.7 |

- The counter and the server time change in the same copy in the default session. The client clock runs 0 to 80 ms ahead of the server time (median 16 in the counter's own report).
- The counter is a number of the server's own stream, not a count of what arrived: under 7 percent loss its rise a second did not fall (20.22 against 20.02) and it shows steps of 2. A count of received updates would have fallen by about the dropped share.
- The proxy's `down.packets_per_s` (30 to 31) is higher than the counter's 20 a second: the proxy counts every packet from the server, including packets that follow another within a millisecond (the smallest gap it measured was 0.003 to 0.007 ms). Its median gap between packets, 47.6 to 48.3 ms, matches 20 updates a second.
- `0x141FE5D44` is another per-frame clock in the same area; its value minus the wall clock matched the engine's `com_frameTime` (0x1460053C0) within 1 ms, and it is 5.2 s ahead of the client clock above. It is not used.
- Other places searched with no counter near 20 or 30 a second: 64 KB each side of `clientUIActives` (0x142246C30), of `gameTime` (0x143C986D8) and of `com_frameTime`; the first 890,000 bytes from 0x141FA6C88. The `cg` block holds about 140 float fields that change at the update rate (positions, not counters).

## On the server

`src/native/paris_incident.cpp` already writes one JSON line per client slot every second when the lab server runs with `-paris-incident-log`, `-paris-isolated-lab` and `-paris-network-trace`. The line has type `reliable_window`. It now also carries `"ping"`: the value of the engine's `SV_ClientMP_GetClientPing(slot)`, which is the ping as the server computes it. It is written only for a client that is fully active (state 5 with a valid entity), the same condition as `ps_command_time`.

The same line already holds the backlog fields the reader uses: `pending`, `maximum_pending`, `ack_backlog_gate`, `negative_acks`, `moves_without_immediate_advance`, `arrivals`, `move_calls`, `text_calls`, `binary_calls`, `requested_command_bytes`, and `oldest_pending_time` (only while commands are pending).

## How to enable

- Build the client with `-Perf`: `ops/Build-Voice.ps1 -ServerModules -IsolatedLab -Perf`. This also compiles `paris_perf.cpp`. Without `-Perf` neither file is in the build.
- Start the client with `-paris-net` and `-paris-isolated-lab`.
- Start the lab server with `-paris-incident-log`, `-paris-isolated-lab` and `-paris-network-trace`. The trace files are `iw7-mod/logs/incidents/native-<pid>-<tick>-<part>.jsonl`.

## The reader

    python ops/engine-map/iw7_net.py report CLIENT.json [--trace DIR_OR_FILE ...] [--json]
    python ops/engine-map/iw7_net.py compare A.json B.json [--json]

- `report` prints from the client file: active seconds, updates and updates per second, the gap between updates in ms (median, 95th percentile, maximum), late updates (gap over twice the median), stalls (gap over five times the median), skipped updates, the median server time step, the predicted lead (median, minimum, maximum) and the longest run of passes without an update. With `--trace` it adds, per client slot, the ping (median, minimum, maximum, samples) and the median and maximum of each backlog field, plus `server_time_minus_oldest_pending_time` (derived from two fields). A directory means every `*.jsonl` in it. Lines that are not per-client samples are ignored.
- `compare` prints the client numbers of two runs side by side with the difference (B minus A). It makes no claim beyond the numbers.
- A file with another schema, or one that cannot be read, is refused with exit code 2 and a message. An empty file prints `no updates recorded`.

## The engine's own diagnostics (no code needed)

Console variables in the client:

- `cg_showmiss`: "Show prediction errors".
- `cl_extrap_tracking_enable`: "print to the console log when extrapolation events occur".
- `cl_shownet`: shows network traffic in the console. Its own description text has not been read.

## The engine's tuning variables

Names found in the engine. The loader sets some of them (`src/client/component/network.cpp` and `patches.cpp` of the loader source). For the others, the meaning below is only what the name says; the engine's own description text has not been read and should be checked in the console before relying on it.

- `sv_remote_client_snapshot_msec`: the server's update interval for remote clients. The loader sets it to 33 (range -1 to 100).
- `cl_maxpackets`: the most packets a client sends per second. The loader sets it to 1000 (range 15 to 1000).
- `cl_packetdup`: duplicate command packets sent by the client (by name).
- `cl_extrapolate`: extrapolation on the client (by name).
- `cl_smoothSnapInterval`: smoothing of the interval between updates (by name).
- `cl_adjust_time_*`: the client's time adjustment against the server (by name; several variables).
- `sv_cmdBuffer*`: the server's buffer of client commands (by name; several variables).
- `sv_minPingClamp`: a lower limit for the ping the server uses (by name).
- `cl_timeout`, `sv_timeout`: connection timeouts. The loader sets both to 90 (range 90 to 1800); its source comment says `cl_timeout` seems unused.

`python ops/engine-map/iw7_engine_map.py dvars --like <word>` lists the console-variable names the engine map finds (see `docs/ENGINE-MAP.md`).

## Limits

- The addresses belong to one build of the game image (the retail `iw7_ship.exe` of this machine) and were measured on map `cp_zmb` only. A game update moves them; repeat the recording.
- The pointer value was identical across three sessions, but it points into the heap. The recorder reads it at run time and refuses an unreadable block; it does not prove the block is the one measured.
- The counter's meaning is inferred from its behaviour. Whether a jump above 1 is a lost update or two updates seen in one pass (jitter can deliver two within one frame) is not separated.
- The counter's 20 updates a second is what the server sent in these sessions (the measured 48 ms mean step shows the server's own frame rate decides, not the loader's `sv_remote_client_snapshot_msec` of 33). The default session's 19.22 a second is lower than the recording's 20.02 because the recorder's active time includes the first seconds after the join.
- The main pipeline pass is the clock. An update is seen at the first pass after it arrives, so a gap carries up to one pass of error.
- The client's wall clock and the server's time are different clocks. Only differences inside one clock are meaningful; `ahead_ms` mixes the client's predicted time with the server's time and is a lead, not a latency.
- The server ping is the engine's own number, not a measurement of this tool.
- Without `-paris-network-trace` the server writes no per-client lines, and the trace part of the report is empty.

## Tests

`tests/ops/net_report_test.py` runs the reader on synthetic client documents and synthetic trace lines. It uses no recorded data. It does not test the native code.

To find where the game keeps a value by watching how it changes, record a block of memory with the memory watch: see `docs/MEMORY-WATCH.md`.
