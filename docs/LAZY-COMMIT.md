# Lazy commit of the engine allocator's segments (`-lazy-commit`)

Worker LZ, 27 Nov 2026. Opt-in, off by default. Source: `src/native/lazy_commit.cpp` (the hooks), `src/native/lazy_commit_policy.hpp` (the
portable part: block table, head/tail/pad plan, fault policy), tests `tests/native/lazy_commit_test.cpp` and `tests/ops/lazy_commit_test.py`.
Status: built on paper and statically checked; **not yet compiled into a client and not measured in a running game** (the lead builds and runs the A/B below).

## The problem (worker CM, `ops/memlab/`)

A lab client at ready commits about 8.3 GB (3.7 GB resident). About 4.8 GB of the commit is segments of the engine's dlmalloc-style allocator that
were committed and never touched: `VirtualAlloc(0, size, MEM_COMMIT|MEM_RESERVE, PAGE_READWRITE)`, blocks of 16/32/64/128 MB. Windows backs commit
with page file, and the machine's commit limit (61.8 GB) caps how many clients agents can run at once.

## The allocator (read in the engine database, `ops/engine/engine.py decomp`)

dlmalloc 2.8 mspace; the layout of `mstate` read from `FUN_140eabe30` (init) and `FUN_140ead190` (sys_alloc):

| Offset | Field |
|---|---|
| +0x10 | `topsize` |
| +0x18 | `least_addr` |
| +0x28 | `top` (the top chunk) |
| +0x350 / +0x358 | footprint / max footprint |
| +0x360 | mflags (bit 0 = use mmap) |
| +0x368 | first segment record: base, size, next, sflags |
| +0x388..0x3b0 | the parameter block: lock word, page size, granularity (+0x398), mmap threshold (+0x3a0, 256 KB), trim threshold (+0x3a8) |

| Address | Function | What |
|---|---|---|
| `0x140EABA60` | `FUN_140eaba60(capacity)` | `create_mspace`: `VirtualAlloc(0, capacity + 0x408 rounded to 64 KB, 0x3000, 4)` at **`0x140EABB2F`**, then `FUN_140eabe30` writes the mstate (0x3c0 bytes), the top chunk header and a 0x48 byte fence post at the end |
| `0x140EAD190` | `FUN_140ead190(mstate, nb)` | `sys_alloc`: tries `FUN_140eac160` (direct mmap for a request at or above the threshold: its own `VirtualAlloc` with 0x103000, **not touched**), else `VirtualAlloc(0, nb + 0x49 rounded to 64 KB, 0x3000, 4)` at **`0x140EAD20E`**; then merges with an adjacent segment (append: top extended; prepend: `FUN_140eacb00`) or `add_segment` (`FUN_140eab780`: the old top is retired to the bins, the new block becomes the top) |
| `0x140EADCD0` | `FUN_140eadcd0(base, size)` | munmap: `VirtualQuery(base)`, requires one region with `BaseAddress == AllocationBase == base`, state commit, size not above the request, then `VirtualFree(base, 0, MEM_RELEASE)`. **Fails (-1) for a block that is not one uniformly committed region.** Called by trim (`FUN_140ead420`), `release_unused_segments` (`FUN_140eace90`) and the free of a mmapped chunk (`FUN_140eac240`) |
| `0x140EABB80` | `FUN_140eabb80` | `create_mspace_with_base` (the engine's own pool memory): no VirtualAlloc, not touched |

The top is read, not guessed: `top` at +0x28, `topsize` at +0x10. Every other VirtualAlloc of the image (`FUN_140cf0cb0`, the page pool; `FUN_140eac160`,
direct mmap) is not an allocator segment and stays as it is.

## Design choice: (a) vs (b), and what was built

The task named (a) hook the call sites and commit as the allocator advances `top`, and (b) commit on touch with a vectored handler, with the kernel write
hazard (`ReadFile`, `WSARecv`, D3D uploads into a reserved page fail with `ERROR_NOACCESS`; there is no fault to catch).

Pure (a) needs every place that moves `top`: the malloc fast path, memalign, realloc growing into top, `sys_alloc` itself, prepend, trim; each is a code
site to patch with a cave, and a missed one is a crash. Pure (b) has the kernel hazard.

Built: **(b) made safe by an invariant, with (a)'s reads where they are cheap.** The allocator carves from the top chunk always upward, and each carve
writes the new top chunk's header at the end of what it hands out. That write is the first touch of any reserved page; it happens in the allocator's
own user-mode code before the caller gets the pointer; so it faults, and the handler commits **everything from the committed mark up to that
address** (rounded to 256 KB). Therefore everything the allocator has handed out is committed when the caller sees it: a kernel write cannot hit a
reserved page, and no list of `top` movers is needed. Only the never-carved rest of each segment stays reserved. The invariant needs four
things, each done:

1. **Head and tail committed at once.** Head 64 KB (the mstate 0x3c0, the first chunks, the first top header); tail 16 KB (the fence post written at
   init, and the segment record `add_segment` writes at the old segment's end).
2. **No segment merge.** The allocator merges a new block with a neighbour when the addresses touch (`seg.base + seg.size == new`, or the reverse). Merged,
   a top chunk could span an uncommitted gap and be handed out without the header write that commits it. Every lazy block reserves 64 KB more than the
   allocator is told (never committed): a block placed flush against another is still not adjacent for the allocator's arithmetic.
3. **A retired top is committed whole.** When `sys_alloc` adds a segment, the old top chunk becomes a free chunk in the bins and a later request can take
   it whole (no split, no header write beyond it). `FUN_140ead190` is wrapped to know the mspace: before the new `VirtualAlloc` the old top
   (`top .. top + topsize + 0x48`) is committed (a segment is retired only when it is nearly consumed, so the cost is small).
4. **Release works.** `FUN_140eadcd0` is replaced for registered blocks (exact base, exact size: `VirtualFree(base, 0, MEM_RELEASE)`, entry removed); the stock
   one would fail on a partially committed block, after having released it. Other blocks go to the stock function.

Not a look-alike: the memory is really reserved and committed on demand by the engine's own allocation pattern; the caller sees the same allocator,
the same layout and the same zeroed pages; nothing is simulated.

Blocks under 2 MB, a full table (4,096 blocks; a client has about 190) and any failed head or tail commit use the stock call, so a refusal is never a behaviour change.

## What the handler does and does not take

`AddVectoredExceptionHandler(1, ...)`: only `EXCEPTION_ACCESS_VIOLATION`, not DEP (information[0] = 8), only an address inside a registered block, below its
tail, not yet committed. Everything else returns `EXCEPTION_CONTINUE_SEARCH` at once (a registered-block lookup is a scan of at most 4,096 entries, only on
an access violation). If the commit fails (out of commit) the exception continues to the game's crash handler as an access violation, as the stock game
would have ended on an out-of-memory.

Known limits, stated: (1) a bug that reads or writes past the carved memory into the never-carved rest now faults and is committed silently (before: it
hit committed memory silently), so it is neither found nor made worse. (2) The lab write-watch and write-census tools (`-paris-write-watch`,
`paris_write_census.cpp`) protect pages with `VirtualProtect` and are not meant to run together with `-lazy-commit`. (3) Segments created before the
component's `post_unpack` are stock: the counters of `paris_lazy_commit` (lazy blocks vs whole blocks) show what was caught; if heaps are made
earlier than `post_unpack`, the hook point moves earlier (that is the first thing to read in the A/B).

## Console command

`paris_lazy_commit` prints the counters: lazy blocks created and live, whole blocks, faults, failed commits, tops committed on retire, releases, and the
bytes of the live lazy blocks reserved vs committed.

## Expected numbers (to be confirmed by the A/B)

Of the 4.8 GB untouched: head 64 KB + tail 16 KB + up to 256 KB of slack per live block (about 190 blocks) is about 0.07 GB, plus whatever each heap
really uses. The target is **-4 GB of commit and of page file per client** (8.3 GB to about 4.3 GB), working set unchanged (the pages were never touched,
so never resident), faults in the hundreds to low thousands over a map load (each about 30 to 100 microseconds, the commit call included).

## The A/B for the lead

Build a client of branch `claude/lz-lazy-commit` (`ops/enginelab/Get-LabClient.ps1 -ComponentsRoot <checkout>`; the source is compiled in by default
and inert without the flag). Then, one request at a time, in the background (`$exe` = the built client):

```
# 1. commit and working set, stock vs lazy, same plan, cp_zmb at ready
forge run <cp_zmb plan> --exe $exe                           # reference
forge run <cp_zmb plan> --exe $exe --launch-arg -lazy-commit # candidate
#    while each is at ready:  python -B ops/memlab/sample.py <pid> --every 5   (commit = PrivateUsage, working set, peak)
#                             python -B ops/memlab/vmmap.py <pid> --top 30     (the 16/32/64 MB private regions: committed bytes per region)
#    in the game console: paris_lazy_commit   (the counters; "lazy blocks created" should be near the 190 blocks of the stock vmmap)
# 2. the Arcade usermap: the latest C:\studio-data\live\layer_doc* (or the r13 doc_e usermap), the same pair of runs
# 3. stock plans that must still pass, with the flag
forge batch C:\studio-data\sz\arcade\r8\plans\batch.json --exe $exe --launch-arg -lazy-commit
#    and one cp_zmb plan from the Forge set (the same verdicts as without the flag)
# 4. stability: a 10 minute soak, forge run long_session --exe $exe --launch-arg -lazy-commit
#    (no crash, no "Lazy commit" error line, failed commits 0)
```

Read: commit (PrivateUsage) down by about 4 GB; working set within noise; failed commits 0; no new crash dump; the plan verdicts equal. If a crash
appears, `-paris-crash-memory` gives the dump and the first-chance access violations at addresses inside a registered block show it at once.

## Rollback

No flag, no effect: the component does nothing without `-lazy-commit`. With the flag, a failed check at start (the two call sites are not `call [VirtualAlloc]`,
no slot memory in reach) logs `[Lazy commit] not active: <reason>` and changes nothing.

## A/B result of 27 Nov 2026 and the finding (LZ)

The lead's A/B (cp_zmb at ready): stable (Arcade r13 batch 4/4, conditions-zmb pass) but **no saving**: commit 10.45 GB stock vs 10.13 GB lazy.
Diagnosis on a live session (`forge live start ... --launch-arg -lazy-commit`, cell with the lead's exe, vmmap of the client):

- The hooks are installed (peek: both call sites patched, `FUN_140ead190` detoured; the log has the ready line as its first line) and the code works:
  30 lazy blocks exist (1 x 16 MB, 29 x 32 MB, each with its 64 KB reserved pad), 80 MB not committed. So the mechanism is sound and the two
  call sites are **not where most of the committed-untouched memory comes from**.
- The client at that moment had 15.4 GB of private commit, 10.7 GB of it untouched (resident 4.7 GB). By block shape (allocations of one region,
  fully committed, exact sizes): 204 x 5.375 MB (1.1 GB), 41 x 16 MB, 10 x 64 MB (all zero, 1 MB resident), 12 x 32 MB, 54 x 4 MB, 1 x 128 MB;
  and about 400 blocks of 16 to 32 MB with interleaved committed/reserved pieces (the NT heap's segments and the engine's own page pool,
  `FUN_140cf0cb0`, already commit on demand). The 42 GB arena (PMem) is 2.45 GB committed, 0.8 GB untouched.
- Static search of the whole decompiled image finds no other `VirtualAlloc` than the five known sites, so the other big blocks come through the CRT
  heap (`HeapAlloc` large blocks), another API, or the three sites running before the component's hooks.

So the next step is a measurement, not a guess: `src/native/alloc_census.cpp` (`-alloc-census`, compiled in, inert without the flag) hooks
`ntdll!NtAllocateVirtualMemory` from `post_start` (before the engine's code is unpacked), and records every successful commit of 1 MB or more with the
first three call frames outside ntdll/kernelbase/kernel32 in a fixed table. It prints the top 30 sites by bytes (size x count, module+offset of the
caller and its two callers) to the console log every 15 s when the table changed, and on the command `paris_alloc_census`.

Rebuild and rerun for the lead: build the branch, `forge live start --map cp_zmb --exe <exe> --launch-arg -alloc-census --launch-arg -lazy-commit --session lz_diag`,
wait for ready, read the `[Alloc census]` lines of the client log (`<cell>/client.stdout.log`). The top lines say which function commits the
5.375 MB, 16 MB, 32 MB, 64 MB blocks. Then the lazy commit is moved to that caller (same invariant: reserve, commit what the owner has touched). The caveat
stays: a caller that hands the whole block to the kernel (file reads into it) needs the commit before that call, not on first touch.

## Census result and zero-page measurement (LZ, 27 Nov 2026, stock client, cp_zmb at ready, no -lazy-commit)

Census (lead's run and mine agree): the big commits it sees are the engine's **PMem** commit function `FUN_140cf0cb0` (VirtualAlloc at `0x140CF0CF3`),
called through `FUN_140cf0eb0` by `FUN_140a75290` (script/zone load buffers, `+A75592`), `FUN_140c75310` (sound buffers, `+C7542C`),
`FUN_1404b6800` (`+4B698D`, 1/2/4 MB pages), `+CF0C75` (`FUN_140cf0bb0`, the PMem stack allocator) and `+51177D`. PMem is a stack allocator over a reserved
42 GB arena (`DAT_147685xxx`, `g_mem`): its commit is exactly what was allocated, and it is **well used: of 2,452 MB committed in the arena, only
88 MB are zero pages** (the sampler of `ops/memlab` said 833 MB "untouched" only because it counts pages not in the working set, which Windows trims on an
idle client). PMem is therefore not a target, and several of its blocks are read into by the kernel (sound streaming buffers, `+C7542C`): they must stay
committed.

Measured by content, all committed private memory of the stock client read through `ReadProcessMemory`, pages that are entirely zero (a page the
engine never wrote; `scratchpad/zero.py`-style scan, to be moved into `ops/memlab` when proven useful):

| Class of allocation | committed | zero pages |
|---|---|---|
| single block 16 to 64 MB | 2,243 MB | 2,037 MB |
| several regions, over 16 MB (committed pieces inside a 16 to 32 MB reservation) | 1,792 MB | 1,507 MB |
| single block 4 to 16 MB | 1,128 MB | 1,103 MB |
| single block over 64 MB | 128 MB | 128 MB |
| PMem arena | 2,452 MB | 88 MB |
| several regions 4 to 16 MB | 807 MB | 12 MB |
| total | 8,592 MB | 4,909 MB |

So the 4.9 GB claim of worker CM holds by content (4.9 GB of zero pages), and the memory is in the **sparse pools of 4 to 64 MB**, whose profile per
MB (a block is used in patches, with long zero runs; some hold block-compressed texture data) says they are sub-allocated by the engine, not dlmalloc
mspaces (the first bytes of most are zeros, not an mstate). The census did not list them: they are committed **before `post_start`** or through the
`Ex` form of the call. The census now says which: its first lines print "before the hook: N MB in M private blocks" (a walk at hook time) and the number of
`NtAllocateVirtualMemoryEx` calls seen (that function is hooked too).

Next run for the lead: rebuild the branch, `forge live start --map cp_zmb --exe <exe> --launch-arg -alloc-census --session lz_diag`, read the first
`[Alloc census]` lines (before the hook, Ex calls) and the top sites; if the sparse pools were committed before `post_start`, the hook point has to move
earlier (the mod's start, or patching them in the image at load); if via `Ex`, the table now lists their callers.

## Census 3: every reservation and commit, by caller, with zero pages per caller (LZ)

Census 2 (lead): before the hook only 3 MB, Ex calls 0, but no sparse pool of 4 to 64 MB among the commits of 1 MB and more. The pools are therefore
reserved in one call and committed in **pieces under 1 MB**, or a sub-allocator commits into them (a block of one committed region can be many adjacent commits).
`alloc_census.cpp` now records all of it (no size threshold) in three kinds: `reserve` (MEM_RESERVE only), `new` (reserve and commit at once) and `into`
(commit into memory reserved earlier), each by the first three callers outside ntdll/kernelbase/kernel32, with calls, bytes and the largest call. Every
reservation of 1 MB or more is kept with its callers; **`paris_alloc_zero`** (and once, about 100 s after the start) walks them: per caller of the
reservation, the blocks still alive, reserved, committed and zero-page bytes. The line with the biggest zero total names the creator of the sparse pools;
its `into` callers say who commits them, in which steps.

Run for the lead: rebuild, `forge live start --map cp_zmb --exe <exe> --launch-arg -alloc-census --session lz_diag`, wait for ready and about 2 minutes
(the `[Alloc zero]` lines appear in the cell's `client.stdout.log` after the sixth 15 s tick; `paris_alloc_zero` again at will), then send the `[Alloc census]`
and `[Alloc zero]` lines. The lazy commit then moves to the creator with the most zero pages whose commits are made by the engine's own code
(a commit into a pool becomes: commit when the sub-allocator hands the piece out, which is what it does already; the saving is then in what the pools commit
ahead of use, and that is read from the `into` sizes against the zero pages).

## Census 3 reconciled, and what is real (LZ, 27 Nov 2026)

Same process, same moment (my `lz_diag3`, stock, `-alloc-census`, cp_zmb): the in-process census accounts for **4,188 MB** of committed memory in reservations
of 1 MB and more made since `post_start` (zero pages: 819 MB), while an external read of every committed private page finds **8,704 MB committed, 5,192 MB
of it zero pages**. So about **4.5 GB of private commit, nearly all zero pages, is created by a door the census does not see**: the 41 to 44 blocks of
exactly 16 MB, 27 of 32 MB, 71 of 4 MB, the 5 to 12 MB ones and the multi-region 16 to 32 MB reservations (addresses mostly below 4 GB, one allocation each).
The census sees no call for them (not as `new`, not as `reserve` + `into`), and `before the hook` is only 3 MB, so they were not there when the hook went in.
What is accounted for, and what it is:

| Where | Committed | Zero | Creator | Verdict |
|---|---|---|---|---|
| PMem arena, 70 GB reserved | 2,462 MB | 88 MB | `iw7_ship.exe+CF144B` reserve, `+CF0CF3` commits | well used; kernel reads into parts of it; leave |
| 10 x 64 MB | 640 MB | 639 MB | `renderer::umbra_query_init_stub` (`iw7-paris-voice.exe+27FF22`, upstream iw7-mod `renderer.cpp`: a thread_local 64 MB `VirtualAlloc` arena per thread for Umbra queries, never used beyond a few KB) | **made lazy** (this branch) |
| 2 x 8.4 MB | 16.8 MB | 16.7 MB | `renderer::component::post_unpack` (`+27F01C`) | made lazy with the above |
| NT heap segments | about 1,070 MB | 75 MB | ntdll | normal heap, leave |
| unseen door | about 4,500 MB | about 4,400 MB | unknown | not attributable yet |

The symbols come from the build's own PDB (`runtime/voice-symbols/<hash>/iw7-mod.pdb`, DbgHelp: `renderer::umbra_query_init_stub` at RVA `0x27FF22`).

**Real saving of this branch as it stands: about 0.65 GB per client** (the renderer's umbra arenas and two pools; the umbra arena is reserved with a head and
tail committed, the rest on first touch, written only by user-mode Umbra code). The 4.5 GB of the unseen door is not reachable until its creator is known.

New in the census for that: the first lines of each report say how many `NtAllocateVirtualMemory` calls named another process handle (a self handle would
bypass the `GetCurrentProcess()` test) and their bytes, and every report lists, with the second it was first seen, the private allocations of 8 MB and
more that no recorded reservation explains. If they are already there at t=5 s, they are made by something that does not go through ntdll's export
(a direct system call of the game's protector is the leading suspect: the shipped code is protected). If they appear later, the time says which phase.
