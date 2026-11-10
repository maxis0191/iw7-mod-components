# Live world editor

Status: built and run live on 10 Nov 2026 in five engine-loop sessions on Spaceland (`cp_zmb`). The final proof run passed.
Lab clients only. Nothing here is deployed and no shipped map is changed.

## What it is for

To try a change to one of the game's own maps, the usual way is to rebuild the map and load it. That takes minutes. This
component reads the running map's placed props (the world's static models) straight from the game's memory and hides
them inside a box, or by model name, in seconds. An agent can ask "what does this room look like without the cabinets,
the door, the chairs" with one console line, capture a frame, and put everything back exactly. The answer decides
whether a map change is worth building.

It is the in-game side of the map atlas (docs/ATLAS.md in the server repository). `ops/engine-map/iw7_world_live.py`
reads the dump offline, so an agent can also choose the box from numbers, without looking at a picture first.

## How to enable

The component is always compiled (`src/native/paris_world.cpp`; no build switch). It is active in a client started with
`-paris-isolated-lab` (a bench root made with `-IsolatedLab`, docs/BENCH.md in the server repository). The flag
`-paris-world` is accepted but not required: a gamelab plan cannot add a client flag (only a `perf` step adds
`-paris-perf`), so the isolated-lab flag alone turns it on. It does nothing until a command is typed. A dedicated server
never registers the commands. On start the console prints `[Paris world] ready`.

## Commands

All run on the main thread from the console; in a gamelab plan use `{"do":"cmd","text":"..."}`.

| Command | What it does |
|---|---|
| `paris_world_stats` | `[Paris world] map=<name> props=<n> surfaces=<n> lights=<n> hidden=<n> static_surfaces=<n> comworld_lights=<n> method=<mask>` |
| `paris_world_dump [collect] [tag]` | writes `iw7-mod/paris-world/<map>-props[-tag].json` (schema `iw7.world-live/1`, 4.5 MB for Spaceland, one row per prop). `collect` writes to `iw7-mod/paris-perf/` instead, the folder a session runner moves into the run folder (`<run>/perf/`), because the game folder of a bench is removed after the run |
| `paris_world_method <names>` | how to hide: `cull`, `scale`, `axis`, `origin`, `bounds` (join with `+`) or `all`. Default `scale` |
| `paris_world_hide_box x1 y1 z1 x2 y2 z2` | hides every prop whose origin is inside the box. The order of the corners does not matter. Prints `hide box=... matched=<n> hidden_total=<n>`; `matched` counts props hidden by this call |
| `paris_world_hide_model <text> [x y z radius]` | hides props whose model name contains the text (not case-sensitive), optionally only within the radius of a point |
| `paris_world_restore` | puts every hidden prop back, byte for byte; prints `restored=<n>` |

Example (a gamelab plan fragment; waits are for the picture, not for the command):

```json
{"do":"tp","at":[467,3677,0],"yaw":0}, {"do":"freeze","on":true}, {"do":"wait","s":3},
{"do":"capture","name":"before","pause":4},
{"do":"cmd","text":"paris_world_hide_box -300 2900 -100 1300 4500 600"}, {"do":"wait","s":1},
{"do":"capture","name":"hidden","pause":4},
{"do":"cmd","text":"paris_world_restore"},
{"do":"expect","that":"framediff(before,hidden)","gt":0.02,"why":"the box is not empty"}
```

Offline, on a dump:

```
python -B ops/engine-map/iw7_world_live.py near cp_zmb-props.json 467 3677 0 --top 5
python -B ops/engine-map/iw7_world_live.py box  cp_zmb-props.json -300 2900 -100 1300 4500 600 --top 10
python -B ops/engine-map/iw7_world_live.py models cp_zmb-props.json --top 10
python -B ops/engine-map/iw7_world_live.py compare cp_zmb-props.json --db <worldkit database>
```

## The structures read

All counts and rows come from the world the game has loaded: `*g_world` (the loader's symbol at 0x148B2D7E0 holds a
`GfxWorld*`).

| Field | Offset | Meaning | Confirmed by |
|---|---|---|---|
| `GfxWorld::dpvs.smodelCount` | in `GfxWorldDpvsStatic` | number of placed props | 17,010 on Spaceland = ground truth |
| `GfxWorld::surfaceCount` | 28 | world surfaces | 10,760 = ground truth. `dpvs.staticSurfaceCount` is 10,694: not the same number |
| `GfxWorld::primaryLightCount` | 52 | primary lights | 1,039 = ground truth; `ComWorld::primaryLightCount` of the same map also 1,039 |
| `dpvs.smodelDrawInsts` | array of 184-byte `GfxStaticModelDrawInst` | one row per prop | row count and every field below equal an independent on-disk reader (below) |
| row `placement.origin` | 0 | position, 3 floats | same reader, largest difference 0.00002 |
| row `placement.axis` | 12 | 3 by 3 floats, as stored | same reader, 0 differ |
| row `placement.scale` | 48 | float | same reader, 0 differ. The field that hides a prop |
| row `model` | 56 | `XModel*`, `name` first | same reader: all 17,010 names equal |
| row `cullDist` | 160 | `unsigned short` | same reader, 0 differ |
| row `flags` | 162 | `unsigned short` | same reader, 0 differ |
| `dpvs.smodelInsts[i].bounds` | `GfxStaticModelInst`, mid point and half size | frustum bounds | same reader, 0 differ |

The independent reader is another agent's database of the same map from its on-disk dump (a table `smodels`). Command
`compare` against it, on the dump written at the start of the final run: 17,010 live props, 17,010 rows, 0 model names
differ, 0 positions beyond 0.01 (largest 0.00002), and cull, flags, scale, axis and bounds 0 differ. On the dump written
while 792 props were hidden, exactly 792 rows differ, in the scale field only, and `scale` is 0 in all of them.

## How hiding works

For each hidden prop the component keeps the original bytes of every field it changes and writes them back on restore.
When the world pointer changes (map unload or a new map) the saved state is dropped without writing to the old memory;
the pointer is checked by a light main-thread tick and again, with the count, the array pointer and the world checksum,
at every command.

The method is the engineering question, so five were tried on the same 792 props in one view of Spaceland (frame 1280 by
720; the change of two frames of an unchanged view is 2.2 mean absolute difference and 2.6 to 3 percent of pixels changed
by more than 16 of 255):

| Method | Hidden against before | Result |
|---|---|---|
| `cull` (`cullDist` = 0) | 2.04 mean, 1.9 % of pixels | no effect: inside the noise |
| `bounds` (frustum bounds moved down and emptied) | 2.35, 2.7 % | no effect |
| `axis` (placement axes zeroed) | 3.61, 8.6 % | partial: some props go, a door stays |
| `scale` (placement scale = 0) | 8.71, 24.7 % | works: the door, a police car, glass doors, wall boxes are gone |
| `origin` (z minus 100000) | 10.40, 30.8 % | works |
| `scale+origin`, `all` five (second run) | framediff 0.0309 and 0.0291 against 0.0315 for `scale` alone | no better than `scale` |

`scale` is the default: one float, the same effect as the combinations, the least that changes. The placement of the row is
what the draw path reads; `cullDist` and the frustum bounds are evidently not what decides (why was not investigated).
A hidden prop is a real hole: what stood behind it is drawn.

## Live proofs

Final run (5 of 5, `world_proof3`, PASS, 45 of 45 steps, 7 of 7 expectations). Spawn (467, 3677, 0), looking along yaw 0,
player frozen, a box of 1,600 by 1,600 by 700 units around the view:

| Proof | Result |
|---|---|
| Stats | `props=17010 surfaces=10760 lights=1039`, first time and every time (also `comworld_lights=1039`) |
| Dump | 17,010 rows. Nearest to the spawn: `park_turn_style_blue` x3 at 41.4, 45.8 and 65.0 units, `door_zombies_employee_door` at 77.5, `lab_desk_02_cabinet` at 93.4 |
| Box, corners given in reversed order | `matched=792`, `hidden=792`; the same call again `matched=0 hidden_total=792`. The offline reader finds the same 792 rows in the dump |
| Noise | two captures of the unchanged view: framediff 0.0064; against `before` 0.0073. Pixels: 1.90 mean, 1.46 % over 16 |
| Hidden | framediff **0.0397** against `before` (about 5 times the noise). Pixels 11.00 mean, 32.8 % over 16 |
| Restored | framediff 0.0081 against `before`: the noise. Pixels 2.41, 2.9 % |
| Everything hidden (`-100000 ... 100000` box) | `matched=17010`; framediff 0.0353; the game kept running; `restored=17010` |
| Restored after everything | dump `sha256` equal to the first dump (byte for byte, 17,010 rows, 4,570,989 bytes). framediff 0.0100, pixels 3.08, 5.6 % over 16 (the neon lights animate) |
| One door | `paris_world_hide_model employee_door 581 3638 1 100`: `matched=1`; framediff 0.0265. Without radius `door_zombies_employee_door` matches 19 props (seen in an earlier run) |
| After all of it | `paris_world_stats` still `props=17010 ... hidden=0`; the plan ended with its end marker, no crash |

Collision (observed once): the player walked from (467, 3677) toward (700, 3665) through the door at x about 580. With the
door hidden he stopped at (561.0, 3660.8) after moving 95 units; with the door shown, at (561.0, 3660.8) after 95. A
hidden prop still blocks the player: collision is not changed. (Four runs, door hidden and door shown: 95 and 95, 96 and 95, 95 and 97, 95 and 95 units.)

A hidden prop does not change the lighting baked into the world: lightmaps and light probes were computed with the prop in
place, and nothing here recomputes them. In the frames the lit patches on the walls stay as they were. Whether real-time
shadows of a hidden prop disappear was not looked at.

## The five sessions

| Run | Plan | Result |
|---|---|---|
| 1 | five methods on one box | the build took 90 s; stats and dump right the first time; capture of `a2` lost (a second capture too soon after the first): FRAME_MISSING |
| 2 | four views, `scale+origin`, `all`, one door, a walk | 12 of 13 expectations. The one that failed was a view (yaw 180) that has few props in the box: framediff 0.0126 against a threshold I set at 0.02. The dump tag was not applied (found; fixed in the next build) |
| 3 | final proof plan | three frames lost, one hold of the forward key not answered |
| 4 | the same with the performance recorder | four of seven; one frame lost. Frame intervals in all four windows steady (largest 11 ms; the first window one of 103 ms at the start of the window). Not a stall of the game |
| 5 | the same, a frame every 4 s | PASS 7 of 7 |

Lost frames in runs 3 and 4 are the game's own `capture_frame`: it sometimes needs several seconds, a second request in
the meantime is refused (`Capture already pending`), and the frame shows the world at the moment it is taken, not the
moment it was asked. A plan that changes the world less than 4 seconds after a capture can get a frame of the new state.
The plans here ask for a capture, then wait 4 seconds.

## Limits

- Client only. Other players do not see anything; the server's world is unchanged.
- Collision does not change (observed above): only the draw list is edited.
- Baked lighting does not change. Shadows and light that were computed with the prop in place stay.
- Lab clients only (`-paris-isolated-lab`), never a retail or deployed client.
- It hides props. It does not move, add, rotate or replace them, does not edit world surfaces (walls and floors are not
  props) and does not edit lights.
- Props only: 17,010 rows on Spaceland. Dynamic entities, script-moved models and effects are not in this list.
- A rebuilt map is still needed to ship a change. This shows what the change would look like.
- Not tested live: a map change with props hidden (the state is dropped by the pointer check; reasoned, not run), a
  dedicated server (not registered there), maps other than Spaceland.

## Files

| File | Role |
|---|---|
| `src/native/paris_world.cpp` | the commands, hiding, restoring |
| `ops/engine-map/iw7_world_live.py` | `near`, `box`, `models`, `compare` on a dump |
| `tests/ops/world_live_test.py` | 17 tests on synthetic dumps: the three commands, the refusals, `compare` |
