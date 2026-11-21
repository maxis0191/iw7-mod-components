# Render meter: what the renderer refuses, measured without a person (a90, 18 Nov 2026)

The owner's playtests of 16 and 18 Nov (Spaceland, 200 real zombies) showed zombies, brutes and parts of the map flickering, zombies invisible for seconds or popping in. Nobody saw it without him.
`-paris-render-meter` makes it a number: every pool the renderer refuses to fill, the skinned cache against its size, which entities the client processed and drew each frame, video memory.
Source: `src/native/paris_render_meter.cpp` (components; the Perf build switch, with `-paris-isolated-lab`). The play launcher and the QA rig start the client with it by default (server repository
`ops/play/Start-CapacityPlay.ps1`, `-NoMeters` leaves it out). Reader and verdict: `ops/qa/qa_verdict.py` (`d_render`), `ops/qa/render_compare.py` (two runs side by side), server `docs/GAME-QA.md`.

## What it records

One JSON row every 10 s and one at exit in `iw7-mod/paris-render-meter/render-meter.jsonl` (the QA rig and the play launcher copy the folder to `<run>/render-meter/`), and a `[RenderMeter]` console line.

| Row | Content |
|---|---|
| `warn_table` (once) | the text the engine has for every renderer warning id, 160 of 0xA0: the table at 0x141BD3440 read from the running game |
| `config` (once) | agent capacity, hooks installed |
| `window` / `final` | `scenes`, scene interval mean and max ms; `skin` (below); `lists` (the four dynamic model lists, peak against capacity); `draw` (players 0..17, agents 18..18+capacity-1, world: drawn, processed, unseen means and min/max, `vanish`, `hole`, `snapshot_hole` per window and the worst frame); `drawsurf_full` (warning 0x29 by list, with the function that wrote); `vram` (DXGI `QueryVideoMemoryInfo`, the process's use against its budget, shared memory); `threads`; `warnings` (every id that ever fired: total, window count, last call site, the first two arguments, the engine's text) |

- **Warnings.** FUN_140E4B0B0(id, a, b, c) is the renderer's one report of a refused pool or draw (150 call sites, ids 0 to 0x9F). iw7-mod's own `renderer.cpp` already detours it (umbra and static
  model list messages): a second detour on the same address pops an ERROR box "Unable to create hook at location: 0000000140E4B0B0" that **blocks the client's main thread on the lab's hidden desktop**
  (first client run of the meter: the join timed out, found with an EnumDesktopWindows listing). The meter resolves the stock detour's jump (relay) at the first scene end and hooks what it jumps to.
  Before hooking any game address grep `src/client/component` of the native tree for it.
- **Skinned cache.** `r_SkinnedCacheSize` (default 563,200 vertices of 32 bytes, 4 bytes of tension data) a frame. The allocators FUN_140DDCE40 / DDCFA0 / DDD0F0 add to atomic counters
  at `[[0x148F73088]+0x18F8]` and `+0x1900`, refuse past the size (warning 0xB) and the counter goes on growing: its value at FUN_140E29C50 (end of the render commands) is the whole demand.
  `r_SkinnedCacheThreshold` (default 0.85) sets the flag DAT_148B9D66C. The meter reads demand, size and flag each frame.
- **Draw continuity.** FUN_140E2D9D0 (draw command of one dynamic model, argument 3 = entity number; called from several threads) and CG_ProcessEntity FUN_1407AA9E0 set one bit per entity in
  2,048 bit maps; at the end of each scene (FUN_140E328E0) the maps are compared with the last two scenes. `vanish`: drawn in the last scene, processed now, not drawn now. `hole`: drawn, not drawn,
  drawn again. `snapshot_hole`: processed, absent, processed again (the entity left the client's snapshot for one scene).
- FUN_140E328E0 has one detour, owned by the meter; `paris_perf.cpp` subscribes to it (`paris_render_meter::subscribe_scene_end`).

## The census: every fixed pool on the draw path, its size and what happens when it is full

Warning ids are from the engine's own table (`warn_table` row). "Silent" = no warning id; found by reading the code.

| Pool | Function (address) | Capacity | When full | Warning id |
|---|---|---|---|---|
| dynamic model parameter records | FUN_140E2D9D0 / 140E2FF80 | 1,024 x 32 B at 0x149FF3E1C | the model is not drawn (a52 made it safe; stock null write) | 0x9A |
| model lights | same | 1,024 x 0x1C at 0x149FFBE1C | model without its light | 5 |
| draw records | same | 1,024 x 0x90 at 0x14A0B6640 | model not drawn | 1 |
| draw records, other pass | same | 512 x 0x590 at 0x14A002E20 | model not drawn | 2 |
| skinned cache | FUN_140DDCE40, 140DDCFA0, 140DDD0F0 | `r_SkinnedCacheSize` 563,200 vertices | surface not skinned this frame | 0xB |
| **draw surface list of the dynamic models** | FUN_140E2D000 (R_AddDObjSurfacesCamera, three variants at 140E2C7E8, 140E307BD) | 24 lists; capacity table u32 at 0x149EEAA00, bases at 0x149EEAAC0, counts at 0x149EEAA60 (set by FUN_140E34A80); **list 1: 256 entries (4 KB at 0x149E0AD80)** | the surface is not drawn | **0x29** |
| **scene surface buffer** | FUN_140E147E0, 140DE2390, 140DDDF20 (+ 14 readers, 24 sites with the base offset 0xB5580 of the frame data) | 0x40000 bytes, atomic offset at `[[0x148F73088]+0x18A0]`; the surface record keeps the offset as a u16 of 4 byte units | the surface is not drawn | **0x0D** |
| frustum grid lights | FUN_1400C2730 | 256 lights a grid cell, nearest kept | the farthest lights of a cell are skipped | 0x12 |
| static models visible, their surfaces, their delayed materials (iw7-mod already scaled the lists x32 and prints these three) | FUN_140DCE190 and neighbours, renderer.cpp | record bytes 16,384 | static model not drawn | 0x17 to 0x19 |
| umbra query arena | renderer.cpp (64 MB per thread) | | query fails | 0x73 to 0x75 |
| worker command rings (one per command kind) | FUN_140E4B3C0 | per ring | the caller waits or runs the command itself (a stall, not a drop) | 0x56 |
| per-frame animated bone buffers | FUN_140346520 / 1403464D0 | 2 x 0x100000 (grown to 4 MB by the capacity component) | fatal: an error box (blocks the client) | none |
| anim info heap, saved animation cache | FUN_140D83DF0, FUN_140D815A0 | grown by the capacity component | corruption or crash | none |

Not found as warning branches (and so not measured by id): the image streamer and the xmodel / material streaming (the Brutes' missing textures), model and material LOD tables. They need their own
counters: next step below.

## Measured, 24 against 200 (QA plans `flicker-24` and `flicker-200`, same camera, client at the owner's `cg_fov 120`)

Camera: the player held on the Spaceland planter at (700, 3420, 70), yaw 270, pitch 35, Rush at capacity 264 / cap 200; stock: 24 records. Steady windows only (agents in the field): 290 s at 24 (run f24-full), 280 s at 200 before and after.

See the table in the server note `a90-flicker.md` and `docs/GAME-QA.md`; the numbers of the proven fix are below.

| Counter | 24 | 200 (stock) | 200 (draw surface list grown) |
|---|---|---|---|
| warning 0x29 draw surfaces refused, per second | 0 | 245.5 | **0** |
| warning 0x0D scene surface buffer full, per second | 0 | 33.0 | 30.1 |
| warning 0x56 worker ring full, per second | 0 | 17.5 | 16.8 |
| warning 0x12 frustum grid lights, per second (at the owner's cg_fov 120) | 1,678 | 1,582 | 1,518 |
| skinned cache demand peak / size 563,200 | 76,293 | 396,041 | 421,068 |
| frames over the skinned cache size | 0 | 0 | 0 |
| lists peak (params / lights / draws / other pass) | 403 / 31 / 340 / 66 | 579 / 207 / 336 / 242 | same |
| video memory used / budget (MB) | 7,792 / 6,062 to 8,369 (other sessions share the card) | 7,621 / 8,673 | 7,872 / 8,374 |
| agents drawn / processed per scene | 23.95 / 23.95 | 199.99 / 199.99 | 200.0 / 200.0 |
| agent `vanish`, `hole`, `snapshot_hole` per scene | 0 / 0 / 0 | 0 / 0 / 0 | 0 / 0 / 0 |

Reading: the one counter that is zero at 24 and non-zero at 200 and means "a part of a model is not drawn" is 0x29 (list 1 of the draw surfaces: 256 entries for every dynamic model of the frame).
It is gone with the grown list (`agent_capacity.cpp`, section 3c: 8,192 entries, two table values, applied behind the stock initialiser). 0x0D, 0x56 and 0x12 remain.

**The lights are the field of view, not the zombies.** At the stock 24 zombies warning 0x12 fires 1,678 times a second at the owner's `cg_fov 120` and **0 times at `cg_fov 65`** (plan `flicker-24-fov65`, 110 s). FUN_1400C2730 inserts a light into the distance-sorted list of a frustum grid cell (256 entries a cell, `uint` index lists at 0x141D4A160 + 0x400 x set, built by FUN_1400C2950) and skips the farthest lights of a cell that is full: with the wide view more lights stand in the frustum than a cell holds, and which of the far lights are skipped changes as the view moves, so lights (and the surfaces they light) of the map flicker at any zombie count. 256 is the name `FRUSTUM_GRID_MAX_LIGHTS`, shared with the shaders that read the grid: not changed here.

## The two scene buffers (engine-crowd-overhaul, 21 Nov 2026)

Run stage0d (183 agents in view, the stage 0 move in place, no crash, old regions undamaged) put the crowd's flicker on two counters. The entity, dobj and snapshot pools are not the cause: drawn = processed = 183 every scene, `vanish`, `hole` and `snapshot_hole` are 0.

| Buffer | Where | Index | Demand at 183 in view | Capacity | Refusals (stage0d, 189 s metered) |
|---|---|---|---|---|---|
| scene surfaces (0x0D: the surface is not drawn: **the flicker**) | +0xB5580 of each frame, counter `+0x18A0`, allocators FUN_140E147E0, 140DE2390, 140DDDF20 | u16 of 4 byte units (record +6, FUN_140DE2390's record, low 16 bits of the sort key) | 417 KB mean, 430 KB peak | 256 KB = all a u16 of 4 byte units addresses | 3,611,878 |
| motion blur surfaces (0x77) | +0x577180 of each frame (64 KB; +0x587180 is other frame data), counter `+0x18A4`, allocators FUN_140DDCCD0, 140DDCE00 | u16 of 4 byte units at record +0x3E; readers through the accessor FUN_140E34000 (19 callers) and one inlined cmp (0x140E2D70E) | 65.7 KB mean, 67.9 KB peak | 64 KB | 844,045 |

- **Motion blur buffer: grown to 256 KB** (`agent_capacity.cpp` 3g2, table `agent_capacity_surf2_sites.inc` from `surf_sites.py --buffer 2`: 4 base sites in the whole code; limits 0x140DDCCFE and 0x140DDCE17
  0x10000 -> 0x3FFF0, so the index never reaches the "none" value 0xFFFF). Its u16 of 4 byte units already reaches 256 KB: base move only, in the stage 0 transaction. `-paris-surf2-stock` keeps it stock.
  The meter's `surf_demand_bytes.*.cap` is the live capacity. Built and syntax-checked, **not yet run**.
- **Stage 0 table fix:** capstone reports `disp_size` 2 for a 0x66-prefixed instruction with a disp32, so `cmp ax,[rsi+0xB55BC]` at 0x140E752D4 was missing from the stage 0 table (it compared against
  the poison after the move). `surf_sites.py` now reads the four bytes at `disp_offset` and skips rip-relative operands: 86 sites.
- **Scene surface buffer: not done.** The limit is the u16 of 4 byte units (`shr eax,2` at 0x140E1528C and 0x140DE243D, the key's `and edx,0x3FFFC` / `shr rdx,2` at 0x140E2CF01 / 0x140E2CF21 and
  `shr rax,2` at 0x140E2D4C2). 8 byte units (512 KB, one scale bit) hold about 220 in view, not 300 (~700 KB), so the unit has to be 16 bytes (1 MB). x86 has no scale 16: the plan scales the index once
  where it enters a register (`movzx r32,r16` -> + `lea r,[r*4]` in a cave), so every `[base + r*4 + d]` after it addresses base + 16 idx + d. `ops/engine/surf_units.py` walks every use of every root it finds from the 86 base
  sites: **41 roots, each use a scale-4 operand, a kind 1 add/lea or a 64 bit copy, 0 unresolved** (a value live at a call argument, a branch out of the code or the end of the decoded fragment counts as
  unresolved). Its limits: it accepts any scale-4 use, whatever buffer it addresses, and does not see implicit register reads (`rep movs`, shifts by `cl`); roots found only forward from the u16 loads are not
  searched yet. Work left before it can be built: (1) the 26 pointer sites it lists: 4 allocator byte pointers (0x140DDE6EA, 0x140DE23FE, 0x140DE2433, 0x140E152B3: fine once the allocations are 16 byte
  aligned) and readers whose root is a `movzx` from memory the backward search does not reach (FUN_140E30360/140E30550: `movzx r15d,word [rcx+6]` then `lea rsi,[rsi+r15*4]`; FUN_140E2C6A0 stores
  the raw index to the stack at 0x140E2C6B3 and passes `idx*4` on in edx: those two escapes need reading); (2) producers `shr 2 -> 4`, the key mask 0x3FFFC -> 0xFFFF0 and its OR constant
  0x80000003FC0000 -> 0x2000000FF000000, the kind 2 modulus over 20 bits; (3) the three limits 0x40000 -> 0xFFFF0 (0x140DE23CA, 0x140E15272 and FUN_140DDDF20's); (4) 16 byte allocation sizes in the
  three xadds and FUN_140DE2390's record placed at +4 (its index points at record + 0x1C).
- 0x12 (lights): an engine limit that the owner's fov 120 reaches (see above): the cell lists are a static table with the stride 0x400 at 0x141D4A160 and the 256 is shared with the grid shaders; the change needed is a bigger table and stride in the builder, its readers and the shaders (or fewer lights in the frustum).
- The image streamer, xmodel and material streaming, and LOD tables have no counter yet (the Brutes' missing textures).
- Frame-diff of still frames (`ops/qa/frame_flicker.py` in the server repository) is a tool, not a result: the camera of `flicker-200` looks past the crowd.
