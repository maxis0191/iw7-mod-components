# Write watch: who writes this qword (`-paris-write-watch`)

`src/native/paris_write_watch.cpp`, compiled with `-Perf`, client only (a dedicated server ignores it). Off unless the client starts with `-paris-write-watch`.
The server repository's play launcher passes it to the client of every session (`-NoWriteWatch` turns it off).

## Why

An owner crash of 16 Nov 2026 (`iw7_ship.exe+0x8CA8E2`, [CRASH](CRASH.md)) read the vtable qword of element 0 of the hit-result array of the client's `cg` object
and found 0. The constructor writes `0x141440EE0` there (`FUN_140161D80`, 20 elements of 0x350 bytes at `cg + 0x74278`); no stock path stores 0. A dump without the
heap cannot say who wrote the 0, so the next owner session carries a watch that names the writer when it happens.

`cg` is the pointer array `cg[local client]` at `0x141FA6C88` (the crash note of that day pointed at `DAT_141FDCF50`, the Multiplayer array of 0xD64C0 objects; the
Zombies client allocates its 0xFDEA8 objects in `FUN_140240A00` and stores them in `cg[i]`, `FUN_140984180` reads `(&cg)[local client]`).

## What it does

1. **Hardware data breakpoint on every thread** (DR0 to DR3, write, 1, 2, 4 or 8 bytes). A helper thread suspends a thread, writes the debug registers with
   `SetThreadContext` and resumes it; nothing is allocated or locked while a thread is suspended. It looks for new threads every 100 ms, evaluates the target address
   again every 50 ms (`cg` moves at each map load) and re-arms all threads when it changed, and reads the registers of every thread back every
   `-paris-write-watch-sweep` ms (default 2000): a thread whose registers were reset is counted and armed again (`[WW] lost`). A slot that a thread already uses for another
   address is never taken. Threads that start and write within 100 ms of their start are not covered (the per-frame guard below is the backup).
2. **Vectored exception handler** (first in the chain). It answers only `EXCEPTION_SINGLE_STEP` with one of our addresses in a set DR6 bit, clears that bit and continues.
   It reads the value (old = the last value the trap saw, new = now). Unless the new value is the expected one (or `-paris-write-watch-all`), it stores a record in a
   lock-free ring: thread, RIP, eight registers, the 16 bytes before RIP, an unwind of the stack (`RtlVirtualUnwind`) and a scan of the stack for return addresses that
   follow a `call`. It never allocates, logs or takes a lock. A data breakpoint traps **after** the store: RIP is the instruction that follows it. For a block write
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

Lab only (`-paris-isolated-lab`): the console command `paris_ww_test <scratch\|scratch_thread\|scratch_memset\|real>` writes 0 into a watched cell from a function of the
component (`test_store`; `test_block` calls `memset`) and judges the newest record: `[WW-TEST] PASS` when its RIP is inside `test_store` (a block write: when `test_block` is on its stack),
`scratch_thread` writes from a thread created after the arming (and needs `tid` other than the main thread), `real` writes 0 into the real `cg+0x74278` of the running client for one instruction
and writes the stock value back.

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

## Cost

See the measured runs in the server repository's [ZOMBIE-CAPACITY](https://github.com/maxis0191/iw7-paris-server/blob/main/docs/ZOMBIE-CAPACITY.md), "Write watch". The per-frame guard is two small memory reads inside a structured-exception guard; the helper thread
wakes every 50 ms; a trap costs one exception round trip (microseconds) and happens only when the watched qword is written.
