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

Camera: the player held on the Spaceland planter at (700, 3420, 70), yaw 270, pitch 35, Rush at capacity 264 / cap 200; stock: 24 records. Steady windows only (agents in the field).

See the table in the server note `a90-flicker.md` and `docs/GAME-QA.md`; the numbers of the proven fix are below.

| Counter | 24 | 200 (stock) | 200 (draw surface list grown) |
|---|---|---|---|
| warning 0x29 draw surfaces refused, per second | 0 | 245.5 | **0** |
| warning 0x0D scene surface buffer full, per second | 0 | 33.0 | 30.1 |
| warning 0x56 worker ring full, per second | 0 | 17.5 | 16.8 |
| warning 0x12 frustum grid lights, per second | 1,828 | 1,582 | 1,518 |
| skinned cache demand peak / size 563,200 | 84,261 | 396,041 | 421,068 |
| frames over the skinned cache size | 0 | 0 | 0 |
| lists peak (params / lights / draws / other pass) | 403 / 31 / 340 / 66 | 579 / 207 / 336 / 242 | same |
| video memory used / budget (MB) | 7,843 / 8,369 | 7,621 / 8,673 | 7,872 / 8,374 |
| agents drawn / processed | 23.7 / 23.7 | 199.99 / 199.99 | 200.0 / 200.0 |
| agent `vanish`, `hole`, `snapshot_hole` per scene | 0 / 0 / 0 | 0 / 0 / 0 | 0 / 0 / 0 |

Reading: the one counter that is zero at 24 and non-zero at 200 and means "a part of a model is not drawn" is 0x29 (list 1 of the draw surfaces: 256 entries for every dynamic model of the frame).
It is gone with the grown list (`agent_capacity.cpp`, section 3c: 8,192 entries, two table values, applied behind the stock initialiser). 0x0D, 0x56 and 0x12 remain.

## Not done

- 0x0D: the scene surface buffer is 256 KB because the surface record keeps its offset as a u16 in 4 byte units, and 24 code sites add the buffer's base inside the frame data. Growing it means
  moving the buffer out of the frame data and widening the unit (8 byte units: allocation sizes are 28 + 24 n bytes, so they must be rounded) in the three allocators and the 14 readers.
- 0x12 (lights): stock behaviour of the map at any zombie count (1,800 a second at 24); a grid cell keeps its 256 nearest lights.
- The image streamer, xmodel and material streaming, and LOD tables have no counter yet (the Brutes' missing textures).
- Frame-diff of still frames (`ops/qa/frame_flicker.py` in the server repository) is a tool, not a result: the camera of `flicker-200` looks past the crowd.
