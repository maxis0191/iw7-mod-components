# Memory watch

Status: run live on 10 Nov 2026 in the lab client (build 4aeb6e1df4 and the one before it), through the network lab runner (`-Watch`). Recordings of 1,040,040, 890,000, 262,144 and 131,072 bytes were written and read; a 267 MB file (890,000 bytes, 300 copies) read in under a second. Tool notes from that run are in "Worked example".

## What it is for

It finds where the game keeps a value by watching how it behaves.
You record a block of the running game's own memory several times over a few seconds.
Then an offline tool lists the fields in that block that change in a way you describe.
For example: a 32-bit number that goes up by one about 30 times a second.
That field is a good candidate for a frame, tick or snapshot counter.

It is a lab tool. It runs only inside the owner's private lab client. Nothing is written to the game's memory.

## Record

Build the client with the lab switches, for example `ops/Build-Voice.ps1 -ServerModules -IsolatedLab`.
`src/native/paris_watch.cpp` is always compiled. It does nothing unless the client starts with both `-paris-watch` and `-paris-isolated-lab`.
It is never active on a dedicated server.

A recording is asked for through the lab client's request file, `iw7-mod/paris-server-client.request`, like the key requests. The line has three fields:

    <pid> <32 hex nonce> watch:<address hex>:<size decimal>:<interval_ms decimal>:<count decimal>

Example: `watch:141FA6C88:1040040:100:50` records 1,040,040 bytes from address 141FA6C88, 50 times, once every 100 ms.
The action is one token with no spaces. The address is hex without `0x`. A line that does not have exactly these four fields is ignored.
The request is refused while the vote witness or the scenario agent runs, and without `-paris-isolated-lab`.
A refused or ignored request writes no response, so the requester sees a timeout. The console shows the reason for a refused limit.

The console shows `[Paris watch] begin ...` at the start and `[Paris watch] written file=... bytes=...` when the file is complete.
The file is `iw7-mod/paris-watch/watch-<address hex>-<UTC yyyyMMddHHmmss>.bin` in the game folder.

How it samples:

- Each copy is made on the main thread, inside a pass of the main loop. The block is consistent with the game's own main-thread writes.
- The copy goes page by page (4,096 bytes). A page that is not committed or not readable is filled with zero and counted for that sample.
- The first copy is taken at the first pass after the request. The next ones follow every `interval_ms`. The real time of each copy is stored.
- A writer thread writes the file. The main thread never writes a file.

## Limits

- Size 16 to 4,194,304 bytes. Interval 10 to 5,000 ms. Count 2 to 600. Size times count at most 268,435,456 bytes.
- One recording at a time, until its file is written.
- The real interval can be longer than asked: a copy waits for a pass of the main loop, and a large block takes time to copy.
- A value that changes faster than the interval is seen only at the sampled moments. Use total change per second, not the number of changes (see below).
- Only the main thread's writes are consistent with the copy. A value that another thread writes can be caught half-written.

## File format

One JSON header line ending in a newline, then the raw copies back to back (`count * size` bytes).
The header has the schema `iw7.memory-watch/1`, `address` (hex), `size`, `count`, `interval_ms`, `qpc_hz`, `timestamps` (counter ticks of each copy), `unreadable_pages` (per copy) and `pid`.

## Read

`ops/engine-map/iw7_watch.py`. Python 3, no other module.
A 1 MB block with 50 copies takes under a second when most of it is constant, and about 3 seconds when every field changes.

### find

    python -B ops/engine-map/iw7_watch.py find FILE.bin --kind counter --rate-min 25 --rate-max 35

Reads every aligned field (default alignment is the width) as a little-endian signed integer, or as a 32-bit float for `--kind float`.
Options: `--width 1|2|4|8` (default 4), `--align N`, `--top N` (default 40), `--json`, `--keep-unreadable`.

Kinds:

- `counter`: never decreases, changed at least 3 times, every step between `--step-min` (default 1) and `--step-max` (default 8).
- `clock`: never decreases, changed in at least 60 percent of the intervals, 500 to 2,000 total change per second (a millisecond clock).
- `changing`: changed at least 3 times. This is the default.
- `constant`: never changed. Only the count is shown.
- `float`: 32-bit floats, finite, changed at least 3 times. Small integers also read as tiny floats, so add a rate filter.

Rates: `--rate-min` and `--rate-max` apply to the total change per second, which is the last value minus the first value, divided by the time between them.
Compare that number with the rate you expect.
The number of changes is limited by the sampling interval: a value that changes 30 times a second, sampled 10 times a second, changes about 10 times a second with a mean step of 3.
When a range is given the list is sorted by distance from the middle of the range (with only one bound, from that bound). Otherwise it is sorted by offset.

Copies with more unreadable pages than the quietest copy are left out, because their zero fill is not a value. A hole that is in every copy does not count. `--keep-unreadable` uses all copies.

Example on a synthetic recording (a counter that rises by 3 per copy, copies 100 ms apart):

    offset     decimal   address          first   last   changes  total/s  mean step
    0x100      256       141FA6D88         1000   1147        49    30.00       3.00

### diff

    python -B ops/engine-map/iw7_watch.py diff A.bin B.bin --width 4

Both files must be recordings of the same block.
It lists the offsets that are `constant`, `counter`, `clock` or `changing` in one recording and in another class in the other.
Use it for "what changes only while I hold fire": record once idle and once holding fire.

    offset     address        A          B             A total/s    B total/s
    0x100      141FA6D88      counter    constant          30.00            -
    0x700      141FA7388      constant   counter               -        40.00

### show

    python -B ops/engine-map/iw7_watch.py show FILE.bin --offset 0x100 --width 4 --count 3

One row per copy: the time, the unreadable page count, then `count` consecutive fields starting at the offset.
Options: `--hex`, `--float`, `--json`. Use it to read the neighbourhood of a candidate.

    sample   seconds  holes  +0  +4  +8
    0          0.000      0  1000  0  50
    1          0.100      0  1003  0  50

## From an offset to a named field

1. Pick candidates with `find` and a rate you expect. The address is the block address plus the offset.
2. Compare the offset with the structure declaration of the loader (the native source's game structures). If the block is a known structure, the offset names a field.
3. Read the neighbours with `show`: a real snapshot or time field sits next to other fields of the same structure.
4. Confirm with a second recording under a different condition (another map, paused, a different rate) and `diff`. A candidate that follows the expected change is the field. One that does not is a coincidence.
5. Record the confirmed field in the structure declaration only after that second recording agrees.

## Worked example

How the counters of `docs/NET.md` were found on 10 Nov 2026, with the network lab runner (`-Watch "<address>:<size>:10:300"`):

1. The loader declares the client state `cg` at 0x141FA6C88; its snapshot fields never changed. Recording 890,000 bytes from there (10 ms, 300 copies) showed only two frame clocks and a frame counter (62 a second), no counter at 20 or 30 a second.
2. The copies were 16.6 ms apart, not 10: a copy waits for a pass of the main loop, so one copy per frame at 60 frames a second. An update every 48 ms therefore shows as a step every third copy.
3. A pointer at 0x141FE58B8 (`cl_con_data`) held 0x26D90C7B0, the same in two sessions. Recording 262,144 bytes from that address: `find --kind counter --step-min 1 --step-max 3 --rate-min 20 --rate-max 40` listed one field, +0x2014C: 99 changes in 4.94 s, steps of 1, 20.02 a second.
4. `find --kind counter --step-min 15 --step-max 120 --rate-min 800 --rate-max 1200` listed +0x20024 (server time: 99 changes, jumps of 48 to 64) and +0x2003C (a frame clock). `show` at 0x20020 showed the counter and the time change in the same copy.
5. Under ping 300, jitter 30, loss 5 percent the proxy dropped 147 of 2,026 packets (7 percent); the counter still rose 20.22 a second, with 10 steps of 2: it follows the server's sequence.
6. The same clock was found at a fixed address by comparing each field minus the wall clock (the copies carry real time): 0x141FE5EAC matched +0x2003C within 1 ms.
7. The proxy's 30 packets a second did not match the 20 a second of the counter; its median gap of 47.6 ms did.

Notes on the tools: the 4 MB windows of the planned coarse pass were not needed. `find` has no filter on the number of changes, and no way to follow a pointer: the heap block was recorded at an address read from an earlier recording, which worked only because the address was the same in every session. A scratch numpy script listed fields by number of changes (about 140 float fields change at the update rate).

## Tests

`tests/ops/memory_watch_test.py` builds synthetic recordings (a counter, a millisecond clock, a constant, a float walk, a field that drops once, zero-filled pages, an unaligned field, a 64-bit counter) and runs all three commands on them. It uses no recorded data and does not test the native code.
