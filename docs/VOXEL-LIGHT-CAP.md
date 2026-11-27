# Voxel light list cap: the u16 address, what reads it, and what the compiler now does about it (worker VX, 27 Nov 2026)

Arcade round 17 (`C:\studio-data\work\doc2-254c9d40`): the zone compiler's static light voxel lists were at 98 % of the 65,535 entries a u16 address reaches (`slack 1: 5261 lists kept, 64101 entries`, 638,616 leaf refs to a light the leaf is outside of). The question: can the engine's 16 bit address be widened, and what can the compiler do without an engine change?

## Result in one paragraph

The 16 bit limit is a **GPU view format**: the engine copies `GfxVoxelLeafNode[]` (u16 per leaf) and `lightListArray` (u16 per word) straight into two immutable `DXGI_FORMAT_R16_UINT` buffers (`FUN_140DD0B90`, one call each at `0x140DD0D89` and `0x140DD0DF4`). Widening the leaf view to `R32_UINT` (and expanding or scaling the u16 leaf values on the CPU while uploading) lifts the cap with one code cave, **if** the shaders declare the leaf as a plain `Buffer<uint>` (not read: see "Not known"). **Built, not proven**: the compiler side, which needs no engine change, now keeps the lists at **55,728 entries with 14,413 extra refs** on the r17 lights instead of 64,101 and 638,616 (the model's numbers; x64-zt `claude/vx-voxel-cap`, Studio `claude/vx-voxel-cap`, not compiled or run). The compiler change does **not** raise the hard wall (its last rung is the old slack 8); it makes the way to the wall about 44 times cheaper in extra light evaluations.

## What the engine does (decompiled, addresses of `iw7_ship_live`)

| What | Where |
| --- | --- |
| `GfxWorld` voxel trees | count `g_world+0x9A8`, array `g_world+0x9B0`, stride **0x70** (`GfxVoxelTree`, `structs.hpp`) |
| Tree fields used by the renderer | `+0x18` top-down count, `+0x1C` internal count, `+0x20` **leaf count**, `+0x24` **lightListArraySize** (int), `+0x28` header, `+0x30` top-down nodes, `+0x38` internal nodes, `+0x40` **leaf array (u16)**, `+0x48` **light list array (u16)**, `+0x50` CPU dynamic light list (u32, `internal count` words per frame slot), `+0x58/+0x60/+0x68` set to `+0x28/+0x30/+0x38` once the GPU copies exist |
| GPU upload (every tree, once per world) | `FUN_140DD0B90` (`0x140DD0B90..0x140DD0EFA`, unnamed in the database; `FUN_140DD1640` frees them) |
| One buffer + SRV | `FUN_140DD2810(byteWidth, numElements, dxgiFormat, usage, cpuAccess, ..., initialData, out[2], debugName)`: `CreateBuffer` (usage 1 immutable, bind 8 shader resource) then `CreateShaderResourceView` (dimension buffer, format, first element 0, count) |
| Leaf buffer `voxelLeafNode` | count `[tree+0x20]` (`0x140DD0D62`), data `[tree+0x40]` (`0x140DD0D6F`), **format `lea r8d,[r9+0x38]` = 0x39 = R16_UINT** (`0x140DD0D53`), byte width **`lea ecx,[rdx+rdx]`** = 2 per leaf (`0x140DD0D81`), call `0x140DD0D89` |
| Light list buffer `voxelLightList` | count `[tree+0x24]` (`0x140DD0DCD`), data `[tree+0x48]` (`0x140DD0DDA`), format 0x39 = R16_UINT (`0x140DD0DBE`), byte width `2 * count` (`0x140DD0DEC`), call `0x140DD0DF4` |
| Other buffers of the same loop | header (`voxelTreeHeader`), top-down `voxelTopDownViewNode`, internal `voxelInternalNode`, and two dynamic `voxelInternalNodeDyamicLightList` (`R32_UINT` = 0x2A, `4 * internal count` bytes, CPU write, `0x140DD0E62`) |
| SRV tables per tree index (max 32) | header `0x148B1BF20` (stride 8), top-down `0x148B1C020`, internal `0x148B1C220`, leaf `0x148B1C420`, light list `0x148B1C620` (stride 0x10 each; the SRV pointer is the second qword), dynamic `0x148B1C820` (two per tree) |
| Binding | `FUN_140DDB840` (callers `FUN_140E5D710`, `FUN_140E5D3A0`, `FUN_140E5C9C0`): header on slot 4, **t26 top-down, t27 internal, t28 leaf, t29 light list, t30 dynamic list**; also `FUN_140E22BC0` (via `FUN_140E23220`, only when the world has trees and view flag `+0x1348 & 4`), `FUN_140E21D40`, `FUN_1404BE250`, `FUN_1404C35F0`, `FUN_140E3FD40` |
| Which tree a view uses | `FUN_140E3C1F0` (`"No valid voxel trees..."`): the first non-empty tree whose bounds contain the camera origin (`view+0x100..0x108`), index in `view+0x1DD4` |
| Per frame CPU write | `FUN_140E5ED90` copies the dynamic list of the frame slot into `0x148B1C820+`; `FUN_140E315C0` / `FUN_140E31710` fill it (modes 1..5) |
| Mode | dvar `r_forwardPlusMode` (`DAT_1483E9418`, enum at `0x141BC1900`: 0 auto, 1 Bitmask F+, 2 Bitmask F+ Decal, 3 Debug: Bitmask F+, 4 F+ Voxel Tree, 5 Debug: F+ Voxel Tree, 6 Debug: Brute Force F+), resolved in `FUN_140E3AF40` (`0x140E3B2E2`) into `view+0x265C`: a world with trees (`0x140E0B370`) gets the dvar, **auto = 1 (Bitmask F+)**; a world without trees maps modes 1 and 3 to 0 |

So the address chain is: leaf value (u16, from the zone) -> load at t28 -> index into the light list buffer (t29) -> header word `spots << 7 | omnis`, then the light indices. The index is an integer inside the shader; only the **leaf element width** limits it to 65,535. The light list buffer itself can be longer than 65,535 elements (its view has `lightListArraySize` elements): only list *starts* are limited. The compiler could place the last list across the 65,535 boundary (worth at most the longest list, 25 words on r17; not done, not read in the shader).

### Is the voxel tree read in the default frame?

Probably not by the opaque lit pass. The RenderDoc input map of a lit frame (`C:\studio\view\results\inputmap_cap1.md`) lists for the pixel shader `t24` (88 byte light records), `t35` (tile masks) and `t37` (z bins) and **no `R16_UINT` buffer**: the shading is the frustum light tile path (`LIGHT-CAP.md`). The voxel buffers are bound by `FUN_140DDB840` (a pass with a draw or dispatch of its own, mode dependent) and by the debug and decal paths. Measured: the input map. **Not measured**: which passes of a frame sample t26..t30 (a capture of every pass is needed: `forge capture`, then the resource usage of the leaf buffer), and what output changes if the lists are wrong. The A/B below answers the second one.

## How the 16 bit address can be widened (engine side, not built)

One code cave in `FUN_140DD0B90` at the leaf buffer (`0x140DD0D53..0x140DD0D89`); the light list buffer and the shaders stay as they are **if** the leaf is a `Buffer<uint>` in the DXBC (`dcl_resource_buffer (uint,uint,uint,uint) t28`; a typed load returns the same 32 bit value for an `R16_UINT` and an `R32_UINT` view).

1. **Scaled address (zone format unchanged, recommended).** Per tree: `K = ceil(lightListArraySize / 65535)` (1 for every stock zone: nothing changes). When K > 1 the cave allocates `leafCount * 4` bytes, writes `u32(leaf) * K`, creates the buffer with `ByteWidth = 4n` and format `0x2A` (R32_UINT), and frees the temporary (the buffer is immutable: D3D copies the initial data). The compiler aligns every list start to a multiple of K (pad words, at most K-1 per list: about 2,500 words at K = 2 for 5,000 lists) and stores `address / K`. K = 2 gives 131,070 words, K = 4 262,140. A zone built this way is wrong on an engine without the cave (the leaf would be read as an address, not address / K), so the compiler must only do it behind a switch the mod sets.
2. **Wide leaves in the zone.** The loader streams `GfxVoxelLeafNode` as 2 bytes; making it 4 needs the zone loader site (not found in this pass) as well as the format and width. More invasive, same capacity.

Not touched by either: `lightListArray` stays `unsigned short` (light slot indices fit), the header word, the internal node format.

**Not known** (decides whether this works): (a) the leaf declaration in the shaders that read t28 (DXBC of the pass bound by `FUN_140DDB840`: look for `dcl_resource_buffer` on t28 and any `and ... 0xffff` on the loaded value); (b) a CPU reader of `[tree+0x40]` other than the upload (none found among the functions that read `g_world+0x9B0`: `FUN_140DD0B90`, `FUN_140DD1640`, `FUN_140E3C1F0`, `FUN_140E5ED90`, `FUN_140E315C0`, `FUN_140E31710` and the binders; not a proof); (c) that nothing else keeps a copy of the zone's leaf array. A live check before any cave: `forge peek` the SRV of the leaf buffer (`0x148B1C428 + 0x10 * tree`) and read its description in a capture.

### The engine already has another multiplier: more trees

`voxelTreeCount` can be more than 1 (the engine holds up to 32; every tree has its own light list array of 65,535 words). A view uses the first tree that contains the camera, so a tree must cover everything the camera in its region can see: pixels outside its bounds get no voxel lights. For a connected map like the Arcade the trees would overlap almost completely, so this is no gain there; for a map made of separate halls it is. The compiler builds one tree (`build_voxel_tree` uses `voxelTree[0]`).

## What the compiler does now (x64-zt `claude/vx-voxel-cap`, built-not-proven)

Before: one **slack** for all: a leaf may use the list of a set it is a subset of with at most `slack` extra lights; the smallest slack 1..8 that fits. The cost of a leaf is its extra lights, but a set held by 40,000 leaves and a set held by 2 leaves were charged the same, and the lists are mostly the rare sets (r17: 11,316 sets, median 3 leaves, 6,476 sets with 3 leaves or fewer).

Now: the **budget** policy (`iwzmap_voxel_lists.hpp`: `budget_slack`, `choose_budget`; Studio `voxellights.py` the same, step for step, the same fixture numbers in both tests). A set held by `n` leaves may take `budget / n` extra lights (at most 8), so the extra evaluations one absorbed set adds over the whole map stay under the budget: rare sets are absorbed hard, big ones stay exact. The compiler takes the smallest budget of 1 2 3 4 6 8 12 16 24 32 ... whose lists fit; the last rung (every set at slack 8) is the old limit, so nothing that built before is refused now.

- `IWZ_VOXEL_SLACK=n` alone: the old uniform policy (for the A/B). `IWZ_VOXEL_BUDGET=n`: that budget only (0: no absorbing, refused above 65,535 entries). Both set: the budget wins. Studio reads both from the recipe's compiler environment.
- Log: `voxel light lists: N distinct sets, E0 entries with a list each; budget B (largest slack S): K lists kept, E entries (limit 65535), longest list L lights, X leaf refs name a light the leaf is outside of`.
- The refusal text names the budget and the largest slack.

### Predicted for r17 (`lights.txt` of `doc2-254c9d40`, 175 rows; the model reproduces the compile log exactly: 134,432 entries, 64,101 at slack 1)

| Policy | Entries (limit 65,535) | Lists kept | Extra refs | Extra refs per light ref |
| --- | --- | --- | --- | --- |
| none | 134,432 | 11,316 | 0 | 0 |
| slack 1 (the log of the build) | 64,101 | 5,261 | 638,616 | 0.189 |
| slack 2 | 39,238 | 3,159 | | 0.309 |
| **budget 4 (the new default for this document)** | **55,728** | **5,056** | **14,413** | **0.0043** |
| budget 8 | 40,388 | 3,766 | 25,886 | 0.0077 |
| budget 16 | 28,346 | 2,726 | 45,712 | 0.0135 |
| budget 32 | 20,543 | 2,021 | 73,110 | 0.0216 |
| budget 128 | 13,356 | 1,298 | 162,436 | 0.048 |
| slack 8 (the old last rung) | 9,619 | 718 | | |

Expected new log line: `budget 4 (largest slack 4): 5056 lists kept, 55728 entries (limit 65535), longest list 24 lights, 14413 leaf refs name a light the leaf is outside of`; and `voxel light tree ... 5057 light lists (55728 entries)`. The 55,728 is 85 % of the cap: nearly the same fill as before, with 44 times fewer extra light evaluations, and the next rung is far away.

Headroom (random copies of existing omni lights, shifted by up to 600 units, added to the r17 rows; model only):

| Rows | Entries with a list each | Old: slack, entries | New: budget, entries, extra refs per light ref |
| --- | --- | --- | --- |
| 175 | 134,432 | 1, 64,101 | 4, 55,728, 0.0043 |
| 195 | 159,624 | 2, 46,446 | 6, 57,421, 0.0061 |
| 215 | 217,619 | 2, 61,291 | 12, 58,346, 0.0108 |
| 255 | 281,538 | 3, 54,483 | 16, 65,394, 0.0148 |
| 335 | 774,410 | 7, 58,657 | 96, 62,836, 0.0651 |

The budgets are tried on a ladder and the smallest that fits is taken, so the new entries sit just under the cap by design; the cost column is what changes. The refusal point is the same as before (slack 8 for every set). Past 256 visible lights the engine's own light list cap (`LIGHT-CAP.md`) bites first.

### Rejected on the data

- **Union merging** of two kept lists (agglomerative, bounded by the tightest member): 59,700 entries at slack 1 against 64,101, with more extras per ref than plain slack 2 at the same entries; not worth the code.
- **Sharing a list tail with another list**: a list is `header, lights...` with the counts in the header, so a shared tail needs the header word of one list to equal a light index of the other; rare, not built.
- **Dropping lights from leaves whose sphere misses** goes the wrong way: the lists are already exactly the sphere-touching sets; the extra refs are the only slack and they are what the policy now minimises. Binning with a smaller radius than the light's would change the picture.

## The proof the lead runs after building

1. `msbuild tests/iwzmap_voxel_lists_tests.vcxproj /m:1 /nr:false /p:Configuration=Release /p:Platform=x64`, run `build/tests/iwzmap_voxel_lists_tests.exe`: exit 0 ("all checks passed"). In Studio: `python -B -m unittest tests.test_voxellights` passes with the same numbers (hand made 18 and 10 entries, fixture 3097 / 3093 / 3032 / 2963 / 2940, the 1,600 big sets 35,203); the Studio gate `python -B gate.py` passed (805 tests, 0 failures).
2. Build zonetool from `claude/vx-voxel-cap` and rebuild the r17 document (`C:\studio-data\sz\arcade\r17\build17.py doc2`, or `run_variant.sh` with `IWZ_ZONETOOL_EXE` set to the new `zonetool.exe`). The compile log (`work\doc2-*\zt-serve.out.log`, line `voxel light lists:`) must read `budget 4 ... 5056 lists kept, 55728 entries ... 14413 leaf refs`. If it differs the model is wrong: keep the log line and fix `voxellights.py` from it.
3. A/B frames, same cameras (`C:\studio-data\sh\tools\run_variant.sh <name> [VAR=val]`, seven cameras): `new` (default), `old` with `IWZ_VOXEL_SLACK=1` (the log must read `slack 1 ... 64101`), `wide` with `IWZ_VOXEL_SLACK=8` (9,619 entries, very different lists). Compare `new` against `old` and `wide` camera by camera: mean luminance from `stepmetric.lum` equal within the noise of two runs of the same document (run `old` twice for the noise), `roi.py <name>` black share of `arc_bay3` and `hall_near` unchanged (0 % and about 1 %), and no black area: `(lum < 0.03).mean()` of the whole frame not above `old`. **If `wide` equals `old` pixel for pixel, the voxel lists are not read by the lit frame at all** (the likely result, see above): the cap then only matters for builds, not for pictures, and the report must say so.
4. For the engine side: a `forge capture` of a lit frame and the resource usage of the leaf buffer (`0x148B1C428`); read the DXBC of every shader that binds t28 for its declaration and any mask.
