# Write watch: who writes this qword (`-paris-write-watch`)

`src/native/paris_write_watch.cpp`, compiled with `-Perf`, client only (a dedicated server ignores it). Off unless the client starts with `-paris-write-watch`.
The server repository's play launcher passes it to the client of every session (`-NoWriteWatch` turns it off).

## Why

An owner crash of 16 Nov 2026 (`iw7_ship.exe+0x8CA8E2`, [CRASH](CRASH.md)) read the vtable qword of element 0 of the hit-result array of the client's `cg` object
and found 0. The constructor writes `0x141440EE0` there (`FUN_140161D80`, 20 elements of 0x350 bytes at `cg + 0x74278`). A dump without the
heap cannot say who wrote the 0, so the next owner session carries a watch that names the writer when it happens.

`cg` is the pointer array `cg[local client]` at `0x141FA6C88`, but its entries are scrambled (a run read `0x4C48E77C436D0228` from it). The two allocations are plain: the Zombies (CP) client
allocates its 0xFDEA8 byte objects in `FUN_140240A00` and stores the base in `0x141FDBEF0`; the Multiplayer client does the same in `FUN_1402B5000` (0xD64C0 bytes, base in `0x141FDCF50`).
The watch uses `base + local client * stride` and arms only when the object's first qword (its vtable) is an address of the game image (the object is zero until its constructor ran).
The crash note of that day (`cg` from `DAT_141FDCF50`) used the Multiplayer array; a Zombies client uses the other.

## What it found in its first live session (16 Nov 2026, a73, five lab sessions, `-agent-capacity 264`)

Element 0's vtable qword is written by the engine itself, every frame, from the client's snapshot code, and it is 0 for most of the session:

| Measured | |
|---|---|
| writer | two stores at `game+0x94A837` and `game+0x94A842` (inside `FUN_140949810`, called from `FUN_140864450`, the per-character client info update), main thread, 11,369 times in 600 s in the longest session; the first store changes `0x141440EE0` to `0x41440EE0`, the second to `0` |
| register at the store | `rax = cg + 0x74250`; `FUN_140949810` reaches `rax` through `FUN_140945FD0`, which returns `cg + 0x70950 + n * 0xC0` (decompiled), so `n = (0x74250 - 0x70950) / 0xC0 = 76` |
| what the code does | `*(u64*)(e+0x2C) = *(u64*)(e+0x24); *(u32*)(e+0x24) = a; *(u32*)(e+0x28) = b;` with `e` that entry: 16 bytes at `e+0x24` (to `e+0x34`), of which the dword at `e+0x28` is the low half of element 0's vtable |
| not the constructor | the constructor store (`game+0x6709A`, value `0x14143D6D0`, a base vtable) and the destructor store (`game+0x16202D`) run only when `cg` is built or torn down (4 to 6 times in a session) |
| other watched elements | elements 1 to 3 (`hitresult4`) are not hit by this writer |

Inferred (not yet proven by a change): the table at `cg + 0x70950` (entry 0xC0 bytes, indexed by a character number) holds the stock 42 characters (18 players + 24 agents,
`stock_characters` of `agent_capacity.hpp`); with `-agent-capacity 264` it is indexed up to 263, and entries from 42 on lie past its end, entry 76 on element 0 of the hit results.
`grep` of `src/native` and `ops/engine` for `0x70950`: no hit, so the capacity component does not grow this table. The other entries (42 to 263) write 16 bytes each into whatever lies at
`cg + 0x73350 ...`, which this watch does not name. Not shown: that this zero is what the owner's shot met (it is consistent with `rax = 0` at `FUN_1408CA530+0x3B2`, element 0).

## What it does

1. **Hardware data breakpoint on every thread** (DR0 to DR3, write, 1, 2, 4 or 8 bytes). A helper thread suspends a thread, writes the debug registers with
   `SetThreadContext` and resumes it; nothing is allocated or locked while a thread is suspended. It looks for new threads every 100 ms, evaluates the target address
   again every 50 ms (`cg` moves at each map load) and re-arms all threads when it changed, and reads the registers of every thread back every
   `-paris-write-watch-sweep` ms (default 2000): a thread whose registers were reset is counted and armed again (`[WW] lost`). A slot that a thread already uses for another
   address is never taken. Threads that start and write within 100 ms of their start are not covered (the per-frame guard below is the backup).
2. **Vectored exception handler** (first in the chain). It answers only `EXCEPTION_SINGLE_STEP` with a set DR6 bit of a slot, clears that bit and continues (every such trap is swallowed: nothing else in the process sets
   hardware breakpoints, and an unhandled single step would end the client, for example a stale register of a thread not yet re-armed after the target moved).
   It reads the value (old = the last value the trap saw, new = now) and counts the trap against a **site**: (RIP, target, kind of the old value, kind of the new value), the kinds being the expected value, zero, or other (up to 64 sites; a store of changing
   values from one instruction is one site). Only the first trap of a site, and only when the new value is not the expected one (or `-paris-write-watch-all`), is stored as a record in a
   lock-free ring (512): thread, RIP, eight registers, the 16 bytes before RIP, an unwind of the stack (`RtlVirtualUnwind`) and a scan of the stack for return addresses that
   follow a `call`. A full table counts and logs nothing more. The statistics line lists the eight busiest sites with their count and last value. It never allocates, logs or takes a lock. A data breakpoint traps **after** the store: RIP is the instruction that follows it. For a block write
   (memset, memcpy, `rep stos`) RIP is inside the block routine and the stack names the writer.
3. **Output.** Each record is written at once to `iw7-mod/paris-write-watch/ww-<UTC time>-<pid>.log` by the helper thread (durable) and printed with the `[WW]` prefix by the
   main thread each frame, followed by the last console lines that mention a zone or a weapon (`Loading zone mp_weapon_world_...`: the engine's own text, taken by a hook of
   `console::dispatch_message`).
4. **Per-frame guard** (`-paris-write-watch-no-guard` turns it off): once a frame the main thread reads every target and logs the first frame where it differs from the expected
   value (and each further change, 20 at most), with the frame number, the milliseconds since start, and the last 8 zone and weapon lines. It does not need the debug registers: it says
   "zero and stayed zero" even when something reset them.
5. **Statistics** every 60 s (`[WW] stats`): frames, guard microseconds per frame, helper cpu, threads armed, lost registers, traps, logged records, handler microseconds per trap,
   and the traps per writer thread (`[WW] stats writer thread`): that answers which threads write the watched memory.

## Options

| Option | Meaning |
|---|---|
| `-paris-write-watch [<targets>]` | on. `<targets>` is a comma list of up to four: `hitresult` (`cg+0x74278`, expect `0x141440EE0`), `hitresult4` (the first four hit results, default), `scratch` (lab only: a cell of the component itself, for the proof), or `<expression>[=<expected hex>\|=any][:1\|2\|4\|8]` |
| expression | `+` and `-` of numbers (`0x74278`), `cg` (`cg[0]`), `cg0`..`cg7`, `game` (0x140000000), `[<address>]` (the qword stored at an address), `scratch`. Resolved after `cg` is allocated; unresolved while it is 0 |
| `-paris-write-watch-all` | log every write, not only the ones that leave a value other than the expected one |
| `-paris-write-watch-sweep <ms>` | how often every thread's registers are read back (default 2000, at least 200) |
| `-paris-write-watch-main-only` | arm the main thread only |
| `-paris-write-watch-no-hw`, `-paris-write-watch-no-guard` | only the guard, or only the hardware breakpoints |
| `-paris-write-watch-selftest <modes>` | lab only: run the test writes by themselves 15 s after the first frame (modes below) |

Names of the targets that are not given are `hitresult4`.

Lab only (`-paris-isolated-lab`): the console command `paris_ww_test <scratch\|scratch_thread\|scratch_memset\|scratch_values\|real>` (and, for `-paris-write-watch-selftest`, `crash`) writes 0 into a watched cell from a function of the
component (`test_store`; `test_block` calls `memset`) and judges the newest record: `[WW-TEST] PASS` when its RIP is inside `test_store` (a block write: when `test_block` is on its stack),
`scratch_thread` writes from a thread created after the arming (and needs `tid` other than the main thread), `real` writes 0 into the real `cg+0x74278` of the running client for one instruction
and writes the stock value back.

`scratch_values` stores 300 different values from one instruction and passes when the watch counted the traps and logged at most three records; `crash` writes through a null pointer on the main thread (the crash
handler then writes its dump: the launcher must wait for it and end the session as `client_crashed`).

## Baseline: the writers a healthy session already shows (16 Nov 2026, `-agent-capacity 264`, `cg+0x74278`)

| RIP | What | When |
|---|---|---|
| `game+0x6709A`, `game+0x67073` | constructor stores of the hit-result vtable (a base vtable `0x14143D6D0`, then `0x141440EE0`) | at each cg construction (map start), 4 to 6 times a session |
| `game+0x16202D`, `game+0x161DBB` | the stock vtable written back by the hit-result constructor/destructor loop | same |
| `game+0x12BFCD9` | block clear (the zero fill of `FUN_140240A00` before the constructor) | same |
| `game+0x94A837`, `game+0x94A842` | **the per-frame stores of `FUN_140949810` through table entry 76 (see above): the finding** | every frame with a client info update, about 20 a second |

A site outside this table in an owner log is a new writer.

## Reading a hit

```
[WW] hit #0 target=... addr=0x... tid=<id>(main|name) rip=game+0x... (the store is the instruction BEFORE rip) old=0x... new=0x... tick=...
[WW]   regs rax=... rcx=... rdx=... ...
[WW]   16 bytes before rip: ...
[WW]   unwind: game+0x... game+0x... ...
[WW]   stack scan (return addresses after a call): game+0x... ...
[WW]   event t=<ms> ms: Loading zone mp_weapon_world_...
```

`game+0x<offset>` is relative to the image base 0x140000000; `python -B ops/engine/engine.py at 0x14<offset>` and `decomp` name the function. The benign zero writes: `FUN_1402B5000` and
`FUN_140240A00` zero the whole `cg` block before constructing it (right after `cg[i]` is stored, before the helper arms), the constructors `FUN_140161E50` / `FUN_140161D80` write the stock value
(not logged), the destructor `FUN_140161FA0` writes the stock value back (not logged).

## Cost and coverage (measured, 16 Nov 2026)

A Paris session of 917 s (662 s after the join) with `hitresult4` on a hidden lab client, `-agent-capacity 264`, a weapon churn: the helper thread 5.8 s of cpu in 668 s (0.9 % of one core: a thread scan with `NtGetNextThread` every 100 ms,
every thread read back every 2 s), the guard 1.1 us a frame (max 10 ms, the frame of a map change), the handler body 0.7 us a trap (max 93 us) for 25,326 traps (38 a second, one writer of the engine), 84 threads, the console printing of a new
record at most two lines a frame. The client frame rate was 62 (the launcher caps it at 60): a frame-time effect below the cap is not shown, and nothing is claimed about frame time. More in the server repository's
[ZOMBIE-CAPACITY](https://github.com/maxis0191/iw7-paris-server/blob/main/docs/ZOMBIE-CAPACITY.md), 6f.

Not covered: about 9 threads of the 84 deny `SuspendThread` (error 5; each is named once in the log with its start address and name) and cannot be armed, a thread that starts and writes within 100 ms, and writes made by the kernel or by another process.
`lost` counted 0 to 8 threads per session (once, right after `cg` moved at a map start; the helper arms them again within one sweep; why they were reset is not determined).

## Write census: every store into a whole object (`-paris-write-census`, a76)

`src/native/paris_write_census.cpp` (`-Perf`, lab only: needs `-paris-isolated-lab`) answers "which instruction writes where in this object", for the whole object instead of four cells. Every page of a region is made `PAGE_READONLY`; a store faults in a vectored handler,
which counts it per writing instruction (RIP), keeps the lowest and highest offset and the first 128 distinct offsets, makes the page writable, sets the trap flag and continues; the single step puts the protection back. Reads never fault. Nothing is allocated or locked in the handler.
A page that faults more than `-paris-write-census-limit` times (default 20,000: the first stores of a page are seen, a table's rows still show) is released for good and listed (`# released`): the writers of that page are then incomplete. Slow on purpose: a census run, never a play session.

| Option | Meaning |
|---|---|
| `-paris-write-census [<regions>]` | comma list: `cg` (the Zombies client object of local client 0; re-armed when it moves; its size follows `-agent-capacity`) and `abs:<hex address>:<size>` (a static block, up to 12 MB) |
| `-paris-write-census-limit <n>` | stores a page may fault before it is released (default 20000) |
| `-paris-write-census-delay <s>` | arm this many seconds after the client started (the map load and the join are too slow under page protection: a netlab client armed from the start never joined) |

Output: `iw7-mod/paris-write-census/census-<time>-<pid>.tsv`, rewritten every 5 s (the play launcher copies it to `OutputRoot/write-census`; `-WriteCensus cg` of `Start-CapacityPlay.ps1`).
Columns: region, RIP (relative to the image), stores, stores on the main thread, distinct offsets (up to 128), lowest and highest offset, gcd of the sampled offsets (the stride of a table), the first sampled offsets.
Reading: run the same scripted scene at a small count and at a large one and `python -I -B ops/engine/census_diff.py <small.tsv> <big.tsv>`: a writer that exists only at the large count (`only_big`) or whose offsets reach further (`reaches`), with a stride and 20 or more distinct offsets, is a table indexed by a number that grew with the count.
