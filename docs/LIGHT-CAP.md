# Light cap: why a Studio map broke at 178+ lights (worker LC, 27 Nov 2026)

Studio fault FE66 (`C:\studio-data\sz\TOOL-FAULTS.md`): on the Arcade (cp_iwz usermap built by x64-zt `iwzmap`) the lit frame is clean with 177 or fewer rows in `lights.txt`; with 180 or more, black stair-stepped patches of 8x8 px appear. The question was which engine or compiler limit sits at 178-180 lights.

## Result in one paragraph

It is **not an engine limit**. The engine's light tile builder holds 256 visible lights and does not step between 177 and 180. The step is in the **compiler** (`x64-zt` `iwzmap.cpp`, `build_gfx_lights`): when the map's lights take every 32-vertex omni template slot, the reference culling sphere is lost, and every light keeps its own template culling mesh (clipped to the template's rooms, a cone on a spot slot) moved onto it. A light cut along that mesh's outline leaves the tile pattern in the frame. Fix: x64-zt branch `claude/lc-light-cap` (commit 75077d2, from `origin/claude/vl-voxel-lists-serve` = `claude/zt-serve` at ea8ede0). **Built-not-proven**: not compiled, not run; the lead builds and runs the proof below.

## Measured (live, r15 document, 200 rows, 27 Nov 2026)

| What | Value | How |
| --- | --- | --- |
| Visible frustum lights per frame | 200 (both frame slots) | `forge peek 0x141D4A158 --type u32 --count 2` |
| List of light slots | 4..8, 844..1038; sorted by camera distance | `peek 0x141D4A160` |
| `light_pool_2`, `light_pool_3` (the lights lost on the counter) | list positions 4 and 5, nearest lights, 160 units from the camera | record positions (`DAT_141E0C160`, floats 12..14) matched to `lights.json` |
| Primary lights in the world | 1039, 0 moving scriptable | `[g_world 0x148B2D7E0]+0x34`, `+0x38` |
| Compiler log of that build | `scriptable light range extended from 1014..1038 to 844..1038 (195 named lights)` and `light culling shapes: template (moved) (reference omni slot -1, radius 1)` | `zt-serve.out.log` of the work folder |
| Culling meshes of the used slots | mixed: 180 idx / 32 vtx (only 133 slots), 252/44, 204/36 ... instead of the same 32-vertex sphere on every generated light | `peek` of the per-light mesh table (`[g_world]+0x998`, 0x30 bytes per light: index count +0, vertex count +0x10, vertex pointer +0x18) |
| The frame | the counter front of arc_bay3 shows the black stair-stepped triangle again | `studio live shot --clean --camera arc_bay3` |

## The mechanism (compiler)

`assign_light_slots` gives every named light a slot of the scriptable range. When more lights are named than the template has scriptable slots (25 on cp_zmb), the range is extended downwards over static slots: `first = primaryLightCount - named = 1039 - named`. Every generated light must get the same clean culling mesh, so `build_gfx_lights` takes the 32-vertex omni sphere of one **unused** template omni slot as a reference and scales it onto each light. It looked only at unused slots (`used.count(k)` skip) and at `cw->primaryLights[k]`, which `build_com_lights` had already overwritten for used slots.

As `named` grows, `first` falls over the 32-vertex omni slots of the template one by one. When the last candidate is used, the search finds nothing: `ref == ~0u`, `own_shapes` is false, and every generated light keeps the template mesh of its own slot. On this template the lowest candidate not in the low slots is inferred to be slot 861 (the used slots hold only 32-vertex spheres from 865 up in the live table; 861..864 were overwritten), which gives `named >= 178` and the observed step (177 clean, 180 broken; 178 and 179 were not tested). The number 178 is `1039 - 861`: inferred from the live table and the arithmetic, **not** read from the template (not measured: the 177-row build log with `reference omni slot 861`).

Why the effect is a staircase: the mesh of a template slot is the template light's culling hull. It is drawn into the engine's 8x8 tile masks (`R_FrustumLights_RasterMasks`) to decide which tiles a light may touch; a light moved onto a hull of another shape loses the tiles outside that outline, and the lit surface under those tiles gets no light of it. The mask is exact to the tile, so the outline appears as 8 px steps.

## The fix (x64-zt, `claude/lc-light-cap`, 75077d2)

- `iwzmap.cpp build_gfx_lights`: the reference sphere is chosen among **all** template slots as the template holds them before the lights overwrite theirs: a used slot still holds its template mesh at that point (the loop replaces it later) and `before[]` holds its template light (origin and radius). Unused slots are preferred (the choice of every build before this one, so a map that was clean stays byte for byte equal in the choice); a used slot is the fallback.
- The reference mesh is copied before the loop and the loop uses the copy (the reference slot may itself be replaced).
- If no slot qualifies, the compiler **refuses** (`no template omni light slot has a 32 vertex culling sphere`) instead of silently falling back to the template shapes. `IWZ_TEMPLATE_LIGHT_SHAPES=1` keeps the old shapes for A/B frames. A template without `frustumLights` behaves as before.
- The choice is `iwzmap_light_ref.hpp` (`light_ref::pick`), with `tests/iwzmap_light_ref_tests.cpp` (+ `.vcxproj`, README line). Test cases: only used spheres, an unused one wins over a lower used one, the lowest unused, every sphere used, no sphere, unusable slots (other shape, view frustum planes, spot, zero radius, no data). Not compiled or run here.
- New log text: `light culling shapes: own (reference omni slot N used by a generated light, radius R)` when the fallback fires.

## What the engine really holds (decompiled, addresses of `iw7_ship_live`)

No patch is needed. For the day more than 256 lights are wanted, these are all the sites:

| Site | Value |
| --- | --- |
| `FUN_1400C2730` (R_FrustumLights_AddSorted) | list sorted by squared camera distance, position `> 0xff` dropped, count capped at `0x100`; hook `0x140E4B0B0(0x12)` on overflow |
| `FUN_1400C2950` (R_FrustumLights_Collect) | walks the visible bitset (`g_world+0xdc8`, words `+0xbd0`), 0x58-byte records to `DAT_141E0C160` (frame slot stride `0x2C898` = 0x819 records), list `DAT_141D4A160` u32[256] per frame slot (stride 0x400), depth min/max `DAT_141D4AB60` (stride 0x800), flags `DAT_141D4A960` (0x100), `DAT_141D4BB60`; zbins `DAT_141E65290` (0x2000 x u32 per slot, init `0xFF` or `0xFFFF0000`); count `DAT_141D4A158[frame]` |
| `FUN_1400C4950` (R_FrustumLights_Init) | `0x1400C4BEC`: structured buffer 0x100 x 0x58 ('frustum lights buffer'); `0x1400C4C05`: 0x8000-byte zbin buffer; `0x1400C4A53`: mask texture with 0x100 layers; masks `FUN_1400C4DA0`/`4CA0`: `tiles << 5` bytes = 8 words per tile |
| `FUN_1400C4930`, `FUN_1400C52A0`, `FUN_1400C25C0` | words per tile = `(count + 31) >> 5` (`cb2[9].x`, offset `+0x1150`), 6 for 161..192 lights: no step at 177/178 |
| `FUN_1400C1BE0`, `FUN_1400C14F0` | the tile and cluster rasters: one draw per light into slice = list position |
| `FUN_1400C2410` | copies `count * 0x58` bytes and the 0x8000-byte zbin table to the GPU buffers |

Names and the two limit notes are in `ops/engine/knowledge/engine-knowledge.json`. Beyond the 256 visible lights the farthest are dropped (not a failure like this one); the compiler is also capped by the template's slots (1039 minus the static prefix), it throws `not enough template light slots`.

## Rejected / not the cause

- Engine arrays (256), words per tile (6 at 177 and 180), the record buffer (0x100 x 0x58), the mask buffer (8 words per tile): all above 200.
- Voxel light lists (SH, `slack` 1 clean at 69,297 entries) and shadow flags (SH, 10 shadowed rows in r14 and r15): not the cause.
- A `forge capture` of the lit frame was started to read t35/t24/t37 and stopped (queued behind the live session, no power-on step, disk); not needed once the log showed `reference omni slot -1`.

## The proof the lead runs after merge

1. Build x64-zt `claude/lc-light-cap` (`msbuild tests/iwzmap_light_ref_tests.vcxproj /m:1 /nr:false /p:Configuration=Release /p:Platform=x64`, then run `build/tests/iwzmap_light_ref_tests.exe`: exit 0).
2. Build zonetool from that branch and rebuild the r15 document (200 rows): `C:\studio-data\sh\tools\run_variant.sh` with `IWZ_ZONETOOL_EXE` set to the new `zonetool.exe` (it stays the same shape: `vary.py` for the variant document, empty variant list = r15's lights).
3. The compile log must say `light culling shapes: own (reference omni slot N used by a generated light` (N known) and not `reference omni slot -1`.
4. `python C:\studio-data\sh\tools\roi.py <variant>`: the black share of the arc_bay3 counter must go from 44.3 % to 0 % (hall_near about 1 % stays: a separate, minor difference of SH).
5. A/B on the same document with `IWZ_TEMPLATE_LIGHT_SHAPES=1`: the black comes back (44 %).
6. A 177-row document (variant E): the log keeps `own (reference omni slot N)` with N unused, frame unchanged.
7. If step 4 is not 0 %, then the reference choice was not the whole cause: capture the frame (`forge capture ... --usermap`, power on first) and read t35 for the black tiles (script `C:\studio-data\lc\tools\tiledump.py`, qrenderdoc) before touching the engine.
