# Network update measurement

Status: written, not yet built or run live. The reviewer updates this line.

## What it is

A small recorder inside the lab client, one extra field in the server trace, and an offline reader. It answers: how often does the client get a new update from the server, how even is that stream, and how far ahead of the server does the client's own predicted time run.

## On the client

`src/native/paris_net.cpp`. It looks at the client game state once per pass of the engine's main pipeline, while the client is in the active connection state. It reads three engine values:

- `cg.latestSnapshotNum`: the number of the newest update from the server.
- `cg.latestSnapshotTime`: the server time of that update.
- `cg.predictedPlayerState.commandTime`: the client's predicted time.

`cg` is an object at a fixed address in the game image (`symbol<cg_s>`, not a pointer to follow). The recorder checks that the client is active and the game state is initialised before each read.

Each time the snapshot number changes it keeps:

- the wall-clock gap since the previous change, in microseconds (QueryPerformanceCounter),
- the server time step since the previous change, in milliseconds (this is the server's update interval as the client received it),
- how far the predicted time is ahead of the latest server time (`commandTime - latestSnapshotTime`, in ms),
- the jump in snapshot number. A jump above 1 means updates were skipped; the sum of (jump - 1) is `skipped_updates`.

It also counts passes of the main pipeline and the longest run of passes without a new update. The first number seen after the client becomes active is a baseline, not an update. If the number goes backwards (a new match on the same connection) that update has no gap or step and is counted in `discontinuities`.

The arrays are sized at start (200,000 entries each). After that only counters advance and `truncated` is true. The main thread only reads the three values and stores numbers. A writer thread formats the file.

Output: `iw7-mod/paris-net/client.json`, rewritten every 5 seconds and when the client shuts down. Schema `iw7.net-client/1`: `pid`, `seconds` (active time), `passes`, `updates`, `skipped_updates`, `longest_passes_without_update`, `discontinuities`, `gaps_us`, `server_time_steps_ms`, `ahead_ms`, `first_snapshot_num`, `last_snapshot_num`, `truncated`, `source`. The console shows `[Paris net] ready` at start and `[Paris net] written updates=<n> seconds=<s>` at each write.

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

- The values come from two fields of a partly known structure (`latestSnapshotNum` and `latestSnapshotTime` of `cg_s`) and a third from the player state. A live run must confirm them: the update rate must match what the proxy sees, about 30 a second.
- The main pipeline pass is the clock. An update is seen at the first pass after it arrives, so a gap carries up to one pass of error.
- The client's wall clock and the server's time are different clocks. Only differences inside one clock are meaningful; `ahead_ms` mixes the client's predicted time with the server's time and is a lead, not a latency.
- The server ping is the engine's own number, not a measurement of this tool.
- Without `-paris-network-trace` the server writes no per-client lines, and the trace part of the report is empty.

## Tests

`tests/ops/net_report_test.py` runs the reader on synthetic client documents and synthetic trace lines. It uses no recorded data. It does not test the native code.

To find where the game keeps a value by watching how it changes, record a block of memory with the memory watch: see `docs/MEMORY-WATCH.md`.
