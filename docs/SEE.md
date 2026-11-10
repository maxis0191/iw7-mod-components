# Frame facts: the camera and the depth of a captured frame

Status: built and run live on 10 Nov 2026 on Spaceland (`cp_zmb`), lab clients only. Nothing here is deployed.

## What it is for

A frame capture is a picture. To know what the picture shows without judging it by eye, two more facts are needed for
the same frame: where the camera was, exactly, and how far away the thing drawn at each pixel is. This component
writes both. The tool that turns them into answers ("what is at this pixel", "is this prop visible", "is this thing
floating", "what disappeared") is in the creator SDK: `tools-source/worldkit/iw7_see.py`, documented in its
`docs/SEE.md`. It lives there because it needs the SDK's world database and the model files of a map dump.

## How to enable

`src/native/paris_see.cpp` is compiled into a client built with the debugger switch and the isolated-lab switch (the
engine loop's default switches, server repository docs/ENGINELAB.md). It is active in a client started with
`-paris-isolated-lab` (a bench root made with `-IsolatedLab`). A dedicated server never registers it. On start the
console prints `[Paris see] ready`.

## Commands

| Command | What it does |
|---|---|
| `capture_frame <name>` | replaced in a lab client. Writes the same picture as before (`iw7-mod/screenshots/<name>.bmp`) and the camera of that frame: `iw7-mod/paris-perf/see-<name>.json` (schema `iw7.see-camera/1`). A session runner moves both into the run folder (`<run>/<name>.bmp`, `<run>/perf/see-<name>.json`) |
| `paris_see_depth` | arms the next capture: it also writes the depth buffer of the same frame, `iw7-mod/screenshots/<name>__z.bmp` |
| `paris_see_depth all` | the next capture writes every depth target of the engine as `<name>__z<k>.bmp` (used once, to find the right one) |
| `paris_see_target <text>` | choose the depth target by a part of its name; `auto` goes back to the default |
| `paris_see_targets` | writes `iw7-mod/paris-perf/see-targets.json`: every render target of the engine (name, size, format) |

In a gamelab plan: `{"do":"capture","name":"view","depth":true,"pause":4}` (server repository docs/GAMELAB.md).

## The camera file

```json
{"schema":"iw7.see-camera/1","name":"iwz_view",
 "frame":{"file":"iwz_view.bmp","written":true,"width":1280,"height":720,"dxgi_format":28},
 "scene":{"width":1280,"height":720,"display_width":1280,"display_height":720,"scene_aspect":1.77777779,"display_aspect":1.77777779},
 "camera":{"tan_half_fov":[..,..],"origin":[x,y,z],"axis":[[forward],[left],[up]],"z_near":..,"unknown":[..,..],"viewport":[x,y,w,h],"view_offset":[..]},
 "camera_at_request":{...},
 "probes":[{"world":[x,y,z],"screen":[x,y],"ok":1}, ...],
 "depth_asked":1,"depth":[{"file":"iwz_view__z.bmp","target":"<name>","index":..,"width":..,"height":..,"dxgi_format":..,"min":..,"max":..,"zeros":..,"ones":..,"bytes":..}],
 "depth_candidates":[...],"presents":{"asked":..,"taken":..},"ms":{"asked_to_present":..,"colour":..,"depth":..}}
```

- `camera` is read in the present callback, on the renderer thread, in the same call that copies the picture and the
  depth. `camera_at_request` is read when the capture is asked (main thread). When the two differ the camera was
  moving: the tool reports the difference.
- `axis` rows are the world directions of the camera's forward, left and up. `tan_half_fov` are the tangents of half
  the horizontal and vertical field of view.
- `probes`: three points in front of the camera and where the engine's own projection routine puts them on the
  screen. A tool can check its camera maths against the engine with them.
- `ms`: time from the request to the present that served it, time to copy and write the picture, time to copy and
  write the depth.

## The depth file

A 32-bit BMP, top row first, the size of the depth target. The 4 bytes of a pixel are one little-endian float: the
raw device depth, copied without conversion. (A BMP so that the session runners, which collect `iwz*.bmp`, bring it
into the run folder without a change; an image viewer shows noise.)

@@DEPTH@@

## Where the facts are found in the engine

| Fact | Where | How confirmed |
|---|---|---|
| @@ENGINE@@ |

## How it hangs on the frame

The loader presents a frame in `gui.cpp` (`r_present_frame_stub`, a hook of the engine's present function at
0x140E59A40): under the engine's render mutex (handle at 0x148B1BC98) it draws the tool overlay, runs the frame
capture, then calls `paris_debugger::render_frame`. This change adds one listener to that last call
(`paris_debugger::set_present_listener`), so the copy of the picture, the copy of the depth and the camera read
happen in one callback of one present. `capture_frame` is registered again by this component after every other
component, so the lab client's captures all take this path; the game's own capture code is not changed.

When no capture is pending the callback does one atomic increment and two atomic loads.

@@COST@@

## Limits

@@LIMITS@@

## Files

| File | Role |
|---|---|
| `src/native/paris_see.cpp` | the commands, the camera file, the depth file |
| `src/native/paris_debugger.cpp`, `.hpp` | one present listener (`set_present_listener`) |
| `ops/Build-Voice.ps1` | copies `paris_see.cpp` into the build when the debugger and isolated-lab switches are on |
