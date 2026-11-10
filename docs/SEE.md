# Frame facts: the camera and the depth of a captured frame

Status: built and run live on 10 and 11 Nov 2026 on Spaceland (`cp_zmb`), lab clients only. Nothing here is deployed.

## What it is for

A frame capture is a picture. To know what the picture shows without judging it by eye, two more facts are needed for
the same frame: where the camera was, exactly, and how far away the thing drawn at each pixel is. This component
records both. The tool that turns them into answers ("what is at this pixel", "is this prop visible", "is this thing
floating", "what disappeared") is in the creator SDK: `tools-source/worldkit/iw7_see.py`, documented in its
`docs/SEE.md`. It lives there because it needs the SDK's world database and the model files of a map dump; this
repository has no reader of world geometry.

## How to enable

`src/native/paris_see.cpp` is compiled into a client built with the debugger switch and the isolated-lab switch (the
engine loop's switches, server repository docs/ENGINELAB.md). It is active in a client started with
`-paris-isolated-lab` (a bench root made with `-IsolatedLab`). A dedicated server never registers it. On start the
console prints `[Paris see] ready` and the dvar `paris_see_ready` is `1`.

## Commands

| Command | What it does |
|---|---|
| `capture_frame <name>` | replaced in a lab client. Writes the same picture as before (`iw7-mod/screenshots/<name>.bmp`) and the camera of that frame: `iw7-mod/paris-perf/see-<name>.json` (schema `iw7.see-camera/2`). When both are written the dvar `paris_see_done` holds `<name>`. A session runner moves the files into the run folder (`<run>/<name>.bmp`, `<run>/perf/see-<name>.json`) |
| `paris_see_depth` | arms the next capture: it also writes the depth buffer of the same frame, `iw7-mod/screenshots/<name>__z.bmp` |
| `paris_see_target <text>` | choose the depth target by a part of its name; `auto` goes back to the default, `Frontend Depth` |
| `paris_see_targets` | writes `iw7-mod/paris-perf/see-targets.json`: every render target of the engine (name, size, format); 166 on Spaceland |
| `paris_see_listen 0` / `1` | measurement switch: takes the present listener away (no capture can complete) and puts it back |

In a gamelab plan: `{"do":"capture","name":"view","depth":true,"pause":0.5}` (server repository docs/GAMELAB.md). The
step waits for `paris_see_done`, so the next step cannot change what the frame shows.

## The camera file

```json
{"schema":"iw7.see-camera/2","name":"iwz_view",
 "frame":{"file":"iwz_view.bmp","written":true,"width":1280,"height":720,"dxgi_format":28},
 "scene":{"width":1280,"height":720,"display_width":1280,"display_height":720,"scene_aspect":1.77777779,"display_aspect":1.77777779},
 "camera":"the engine's own projection (CG_WorldPosToScreenPosReal) of world points: [x, y, z, screen x, screen y], in frame pixels",
 "projection_at_request":[[x,y,z,sx,sy], ...],
 "projection_after":[[x,y,z,sx,sy], ...],
 "depth_asked":1,
 "depth":[{"file":"iwz_view__z.bmp","target":"Frontend Depth","index":109,"width":1280,"height":720,"dxgi_format":19,"image_format":20,"min":0,"max":0.03,"zeros":133816,"bytes":3686454,"ms":{"copy":1.8,"convert":2.8,"write":2.9}}],
 "depth_candidates":[{"index":109,"name":"Frontend Depth","dxgi_format":19}],
 "presents":{"asked":15311,"taken":15312},"ms":{"asked_to_present":4.8,"colour":15.6,"depth":9.2}}
```

The camera is recorded as up to 320 world points and the screen position the engine itself gives each of them
(a lattice over the whole map, then a finer one inside the box of the points that were on the screen). Those pairs
determine the camera exactly: `iw7_see.py camera <frame>` solves and prints position, axes and field of view. Measured:
the solved camera reproduces the engine's projection of the 320 points to a median of 0.00005 pixel (worst 0.013), and
for a player standing at (467, 3677.05, 0.10) looking along yaw 0 it gives the eye at (466.894, 3677.050, 60.102),
yaw 0.000, pitch 0.000, tangents of the half field of view 0.849427 and 0.477803 (80.69 and 51.08 degrees).

`projection_at_request` is taken on the main thread when the capture is asked, `projection_after` on the main thread
in the first frame after the renderer took the picture. When the two give the same camera, the camera of the picture
between them is that camera; the tool prints the difference (0.0 for a frozen player in every proof frame).

Why not read the view structure: the engine keeps the view in its client globals, and the pointer to them (an array at
0x141FA6C88, one entry per local client) is stored encrypted. The engine decrypts it inline wherever it is used
(`CG_WorldPosToScreenPosReal`, 0x1407A5490 and its body at 0x1407A54B0, starts with that decryption: a rotation and
exclusive-or chain keyed on the process). Read as a plain pointer it is not an address: the first two builds of this
component did that and wrote a camera of zeros.

## The depth file

A 32-bit BMP, top row first, the size of the depth target (1280 by 720 here: 3,686,454 bytes). The 4 bytes of a pixel
are one little-endian float: the raw device depth, copied without conversion. (A BMP so that the session runners,
which collect `iwz*.bmp`, bring it into the run folder without a change; an image viewer shows noise.)

Measured on three views against the world database (the SDK tool's `fit`): device depth = 3.9375 / z, where z is the
distance along the camera's forward axis in world units (fitted 3.937495, 3.937499, 3.937493, with an offset below
0.00000005). Reversed and without a far plane: 0 where nothing was drawn (the sky), larger is nearer. Two captures of
an unchanged view hold bit-identical values on 99.98 % of the pixels. The player's weapon is drawn into the same
buffer with values near 0.98 (52,163 pixels in the test view): hide it (`cg_drawGun 0`) for a frame that is to be
measured.

## Where the facts are found in the engine

| Fact | Where | How confirmed |
|---|---|---|
| Camera | `CG_WorldPosToScreenPosReal` (0x1407A5490), called with `ScrPlace_GetActivePlacement()` | 320 points reproduced to 0.00005 pixel by a pinhole camera; eye height 60.10 above the player's origin; the depth of 889,638 pixels of a view agrees with the database drawn through that camera |
| Depth | the engine's render-target pool (entries of 288 bytes from 0x149B3F238, a `GfxImage` at +16, 2,048 entries); the scene-sized depth-stencil target named `Frontend Depth` (index 109 here, `DXGI_FORMAT_R32G8X24_TYPELESS`) | listed live with `paris_see_targets` (166 targets, 103 with a depth-stencil binding, one of them scene-sized); the values fit 3.9375 / z on three views |
| Picture | the swap chain's back buffer, as the game's own `capture_frame` | same file format and name as before |
| Present | the loader's hook of the engine's present function (0x140E59A40) in `gui.cpp`, under the render mutex (handle at 0x148B1BC98) | the picture, the depth and the frame counter come from one call |

## How it hangs on the frame

The loader presents a frame in `gui.cpp` (`r_present_frame_stub`): under the engine's render mutex it draws the tool
overlay, runs the frame capture, then calls `paris_debugger::render_frame`. This change adds one listener to that last
call (`paris_debugger::set_present_listener`), so the copy of the picture and the copy of the depth happen in one
callback of one present. `capture_frame` is registered again by this component after every other component, so the
lab client's captures all take this path; the game's own capture code is not changed. A main-thread step then takes
the second set of projected points, writes the camera file and sets `paris_see_done`.

When no capture is pending the present callback does one atomic increment and two atomic loads, and the main-thread
step one atomic load.

## Cost (measured)

| What | Result |
|---|---|
| Frame time with the listener, nothing captured | unchanged within the noise. One session, the same still view, four windows of 15 s with the listener on, off, on, off (`paris_see_listen`): median frame time 7.41, 7.88, 7.80, 7.26 ms. On against off differs by 0.03 ms; two windows of the same state differ by 0.4 to 0.6 ms. (Measured before the main-thread step was added; that step is one atomic load a frame and was not measured apart) |
| A capture without depth | the picture copy and its file: median 14.4 ms in the renderer (8.0 to 24.6 over 21 captures), the work the game's own `capture_frame` did before. The camera adds two sets of projected points on the main thread (not timed apart) and a 33 KB file |
| A capture with depth | the depth adds a median of 9.6 ms (8.8 to 14.5; copy 1.8 to 6.3, conversion 2.8 to 3.4, file 2.5 to 2.9). The first depth capture of a session took 182 ms: every render target is examined once to find the depth target, then its place is remembered. So a capture with depth is one long frame of about 25 ms |
| From the request to the present that serves it | 2 to 7 ms (the next present) on a view that was not just edited; 36 to 44 ms right after a world-editor command |
| From the script's request to the script seeing the frame done | 50 to 300 ms on a still view, 600 to 1,100 ms right after a world-editor command (`taken_ms` of the gamelab capture step, in script frames of 50 ms). In an earlier session, while a build was compiling on the machine, a frame was taken 5.3 s after it was asked; the step now waits, so the plan cannot run ahead of the picture |
| Files | picture 3,686,454 bytes; depth 3,686,454 bytes (1280 by 720 floats); camera file 33 KB (two sets of 320 points) |

## Limits

- Lab clients only (`-paris-isolated-lab`, built with the debugger switch). The camera needs a loaded map: in the menu
  the file holds no points and the tool refuses it.
- The camera is exact for a camera that does not move between the request and the frame. For a moving camera the two
  recorded cameras differ and the tool says by how much; which of them the picture shows is then not known.
- The depth buffer holds what writes depth. It does not hold: transparent things (glass, smoke, most effects), decals,
  the sky, and the HUD and other things drawn over the frame (the build text at the bottom of the picture is one).
- The depth is read as the engine left it at the present. A thing drawn with its own depth range (the player's weapon)
  is in it with values that are not its distance.
- Only the `Frontend Depth` target was measured, at 1280 by 720, without multisampling, on Spaceland. Another window
  size, a scene scale other than 1 and other maps were not run.
- `paris_see_listen 0` is for measuring: while it is off a capture never completes.

## Files

| File | Role |
|---|---|
| `src/native/paris_see.cpp` | the commands, the picture, the depth file, the camera file |
| `src/native/paris_debugger.cpp`, `.hpp` | one present listener (`set_present_listener`) |
| `ops/Build-Voice.ps1` | copies `paris_see.cpp` into the build when the debugger and isolated-lab switches are on |
