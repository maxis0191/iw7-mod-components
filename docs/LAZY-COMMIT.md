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
