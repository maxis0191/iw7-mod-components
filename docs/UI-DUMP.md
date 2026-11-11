# UI dump: the user interface as data

Status: built and run live on 10 and 11 Nov 2026 on Spaceland (`cp_zmb`), in private local sessions from bench roots.
Lab clients only. Nothing here is deployed.

## What it is for

An agent that builds or reviews a HUD or a menu used to look at screenshots. This tool lets it ask the running game
instead: which UI elements exist now, where, how big, with which text, visible or not. The answer is a JSON file.
A reader then checks it without any picture: elements off screen, texts on top of each other, children cut by their
parent, zero size, text too small; and a rules file gives a verdict by exit code.

Two layers are covered:

1. **Server-drawn elements** (HudElems made by server scripts; what players of the public servers see today). The
   dump holds the client's view: the element as the client received it, and the rectangle, text, font and colour
   the game computed for it in that frame.
2. **The client's Lua UI** (the stock HUD, menus, and any Lua UI the project adds): the element tree from the root.

## How to enable

`src/native/paris_ui.cpp` is always compiled into the lab client (no build switch). It is active in a client started
with `-paris-isolated-lab` (a bench root made with `-IsolatedLab`, docs/BENCH.md in the server repository). A
dedicated server never registers the commands. On start the console prints `[Paris ui] ready`.

## Commands in the game

| Command | What it does |
|---|---|
| `paris_ui_dump [tag]` | writes `iw7-mod/paris-perf/ui-<tag>.json` (schema `iw7.ui-dump/1`). A session runner moves that folder into the run folder (`<run>/perf/`). In a gamelab plan: `{"do":"ui","name":"page"}` |
| `paris_ui_lua <name>` | runs `iw7-mod/paris-ui/<name>.lua` in the UI's Lua state and writes what it returns to `iw7-mod/paris-perf/ui-lua-<name>.json` (`iw7.ui-lua/1`: `ok`, `ms`, `text` or `error`). For a probe, or to plant elements for a test |
| `paris_ui_after <ms> <command ...>` | runs a console command after a real-time delay. A menu that pauses a solo game also pauses the script that would have asked for the dump |
| `paris_ui_observers <0\|1>` | removes or restores the three observers (to measure their cost) |

A file `iw7-mod/paris-ui/walker.lua` replaces the built-in tree walker, to try a change without a build.

### Asked from outside the game (lab request file)

In a client started with `-paris-isolated-lab`, the lab request file `iw7-mod/paris-server-client.request`
(`<pid> <nonce> <action>`, `src/native/paris_test_fixture.cpp`) also takes, gated exactly like `keydown:`:

| Action | Does |
|---|---|
| `uilua:<name>` | `paris_ui_lua <name>` (`[a-z0-9_]{1,24}`) |
| `uidump:<tag>` | `paris_ui_dump <tag>` (`[a-z0-9_]{1,24}`) |
| `rawkey:<key>:<0\|1>` | a real key event through `CL_KeyEvent` (0x1409A7980, the address the fork's `input.cpp` hooks, so its console, gui and custom-bind code run first, as for a physical key). `<key>`: a name `Key_KeynumToString` gives (any case) or one lowercase letter or digit (its ASCII code). Prints `[Paris rawkey] key=.. num=.. down=.. catchers=<before> after=<after> bind="<binding>" sys_ms=.. tick_ms=..` |
| `rawchar:<code>` | one char event through `CL_CharEvent` (0x1409A7350); codes 8, 9, 13, 27, 32..126 |

A refused request gets no response (the requester times out). The server repository's network lab relays these from a
server fixture (`[IWZ local] CLIREQ <action>`, its docs/NETLAB.md "Client requests") and copies `iw7-mod/paris-perf` back.

## The reader

`ops/engine-map/iw7_ui.py` (no dependency beyond Python):

```
python -B ops/engine-map/iw7_ui.py show   <dump> [--layer hud|lui] [--visible] [--content] [--depth N] [--world]
python -B ops/engine-map/iw7_ui.py find   <dump> --text <regex> | --id <regex>
python -B ops/engine-map/iw7_ui.py check  <dump> [--baseline <dump before the change>] [--ignore RULE,RULE] [--json]
python -B ops/engine-map/iw7_ui.py diff   <dump a> <dump b>
python -B ops/engine-map/iw7_ui.py expect <dump> <rules.json>
python -B ops/engine-map/iw7_ui.py frame  <dump> <frame.bmp> [--base <frame without the elements>]
```

| Command | Exit code |
|---|---|
| `show` | 0 |
| `find` | 0 found, 1 nothing found |
| `check` | 0 no finding, 1 at least one |
| `diff` | 0 the same, 1 changes |
| `expect` | 0 every rule holds, 1 a rule failed, 2 the rules file is wrong |
| `frame` | 0 every rectangle agrees with the frame, 1 otherwise |

Every command exits 2 on a file that is not a dump.

### check

| Rule | Meaning |
|---|---|
| `OFF_SCREEN` | a visible text or picture is wholly outside the screen |
| `PARTLY_OFF_SCREEN` | part of it is outside (more than one pixel) |
| `TEXT_OVERLAP` | two visible texts share at least 10 % of the smaller one (`--overlap`). A text and its own ancestor or descendant are not compared |
| `CLIPPED` | a text or picture has more than 2 % of its rectangle outside an ancestor that clips its children |
| `ZERO_SIZE` | a visible text or picture has no width or no height |
| `SMALL_TEXT` | a text is lower than 10 pixels at 720 lines, scaled with the screen (`--min-text`) |

Only visible elements with a text or a picture are judged. The stock HUD already has findings of its own (the fan of
cards in the corner is laid out partly outside the screen). `--baseline <dump>` leaves out every finding that the
baseline dump also has, so the answer is what a change added.

### expect

The rules file is a list (or `{"rules": [...]}`). A selector is a text pattern, or `{"text": ..., "id": ..., "layer": "hud"|"lui"}`
(`id` matches the path of a Lua UI element, for example `MainPlayerInfo/PlayerCash$`).

```json
[
  {"present": "MAXIS TERMINAL", "near": [821, 129], "tol": 6, "why": "the title is at the top left of the panel"},
  {"visible": {"id": "MainPlayerInfo/PlayerCash$"}},
  {"hidden": {"id": "waveNumberSplash"}},
  {"absent": "Game over"},
  {"no_overlap": [{"id": "PlayerCash$"}, {"id": "TicketNumber$"}]},
  {"inside_screen": "toggle Rush"},
  {"count": {"layer": "hud", "eq": 11}},
  {"no_findings": {"ignore": ["SMALL_TEXT"]}}
]
```

`near` is the top left corner in pixels; `tol` defaults to 3 % of the screen height.

### frame

For a dump and a frame captured at the same moment, `frame` measures each visible text or picture twice: the share of
pixels inside its rectangle that differ from the colour around it ("ink"), and, with `--base`, the share that changed
against a frame without the elements, inside the rectangle and in a ring of 4 pixels just outside. A rectangle agrees
when there is ink inside and none around, or when the inside changed and the ring did not. The ring leaves out the
pixels of the element's neighbours; an element wholly surrounded by others cannot be judged, and a sprite with
transparent margins or a rotated one will not agree. This is how the rectangles below were proven; it is also the way
to check a new kind of element before trusting its numbers.

## The JSON

```
schema, tag, map, serial, time_ms
screen      width, height (pixels of the frame), scene_width, scene_height, aspect
placement   the game's own screen placement: scales between its 640x480-based units and pixels, viewable and adjustable areas
hud         count, element_bytes, overflow, elements[]
lui         walker, alignment (names of the text alignment numbers), elements[], count, truncated, root   (or: error)
cost        request_to_capture_ms, lui_walk_ms, build_ms, request_to_file_ms, observer_calls_in_the_frame
```

One HUD element:

| Field | Meaning |
|---|---|
| `i`, `address`, `type`, `draws` | order of drawing in the frame, where the client holds it, the type number, how often it was drawn in the frame |
| `drawn` | the game laid it out and drew it. `false`: the game's own visibility test refused it (the fields below are then absent) |
| `rect` | `[x, y, width, height]` in screen pixels, top left origin: the game's own result, after alignment, scale, safe area and resolution |
| `label`, `text` | the text the game resolved (localised label, then the text); colour codes such as `^5` are kept. A player-name element (type 3) has the name the client knows |
| `label_width`, `text_width`, `font`, `font_pixels`, `font_scale`, `font_height` | measured widths in the game's units, the font file, its native height, the final scale, the final line height in pixels |
| `color` | `[r, g, b, a]`, 0 to 1, after the game's fade computation |
| `picture`, `material` | for a material element: the rectangle and the material name of the picture the game really drew |
| `raw` | the 184 bytes of the element as the client holds it, in hexadecimal |

The reader decodes `raw` (`decode_hud_raw`): `x`, `y`, `z`, `target_ent`, `font_scale`, `font`, `align_x`, `align_y`,
`horz_align`, `vert_align` (with names), `color`, `from_color`, `fade_start`, `fade_time`, `label`, `width`, `height`,
`material_index`, the move, scale and font-scale animations, `time`, `duration`, `value`, `text_index`, `sort`,
`glow_color`, `flags`. The bytes it does not name stay in `raw`.

One Lua UI element (a flat list in depth-first order; `p` is the parent's `i`, -1 for the root):

| Field | Meaning |
|---|---|
| `i`, `p`, `d`, `id` | index, parent index, depth, the element's `id` |
| `class` | the Lua class when it is not a plain element: `UIText`, `UIImage`, `UIStyledText`, `UIRadialProgressBar`, ... |
| `rect` | `[left, top, right, bottom]` in screen pixels: the layout rectangle the engine reports |
| `alpha` | the element's own alpha when it is not 1. The reader multiplies it down the tree |
| `rgb` | the colour when it is not white |
| `text`, `text_size`, `align` | the text, its measured `[width, height]` in pixels, the alignment number. The reader places the glyphs inside the layout rectangle by the alignment; that glyph rectangle is what `check`, `find` and `frame` use |
| `image` | the material name of the element's picture |
| `clips` | the element cuts its children (stencil) |
| `world` | the element and everything under it is drawn on a surface of the 3D world, not on the screen |

A Lua UI element is **visible** for the reader when its alpha, multiplied by the alpha of every ancestor, is above
zero, and it has a rectangle.

## How it works, and why this way

**HUD elements: observe the game, do not recompute.** The first idea was to read the element array and redo the
layout (alignment, scale, safe area, resolution). The client's pointer to its state is stored encoded and the
functions that decode it check who calls them, so calling them from the lab code is not safe. The game's own
per-element functions have no such check. Three of them are observed for exactly one frame per dump:

| Address | What it is | How it was confirmed |
|---|---|---|
| `0x1407E3BD0` | draws one HUD element: `(local client, element)` | the engine map gives the only function that uses the text "hudelem string" and its one caller. Live: 9 elements made by a script plus 2 of the stock game gave 11 rows; after the script destroyed its 9, 2 rows |
| `0x1407E3D50` | lays out one element: fills a record with x, y at 0 and 4, width and height at 0xC and 0x10, label at 0x14 and text at 0x418 (1,024 bytes each), their widths at 0x414 and 0x818, the font at 0x820, scale and line height at 0x828 and 0x82C, the colour at 0x830, the time at 0x840 | disassembly; live, the texts and the rectangles agree with the frame (see "Proof") |
| `0x140313640` | draws a stretched picture in pixels: `(x, y, w, h, s0, t0, s1, t1, colour, material)` | disassembly (it forwards to the renderer's stretched-picture command); live, the panel of the test page came back as `white` with the panel's rectangle |

The element itself (`hudelem_s`, 184 bytes; the last field the game reads is `flags` at 0xB4) was decoded from the
game's layout code and then confirmed field by field: a script set known values and the dump returned them.

| Offset | Field | Offset | Field |
|---|---|---|---|
| 0x00 | type | 0x54, 0x58 | width, height |
| 0x04, 0x08, 0x0C | x, y, z | 0x5C | material index |
| 0x10 | target entity | 0x60 to 0x6C | scale animation |
| 0x14 to 0x20 | a value that is interpolated over time (purpose not known) | 0x70 to 0x84 | move animation |
| 0x24 to 0x30 | font scale and its animation | 0x88, 0x8C | time, duration |
| 0x34 | font | 0x90, 0x94 | value, text index |
| 0x38 | alignment of the element (x in bits 2 and 3, y in bits 0 and 1) | 0x98 | sort (a float) |
| 0x3C | alignment on the screen (horizontal in the high four bits, vertical in the low four) | 0x9C | glow colour |
| 0x40, 0x44 | colour, colour to fade from (four bytes each) | 0xB4 | flags (bit 0: foreground) |
| 0x48, 0x4C | fade start and time | | |
| 0x50 | label | | |

Read back from a live run: a font scale arrives in tenths (0.78 set, 0.8 held; 1.05 set, 1.1 held), an alpha in
steps of 8/255 (1.0 set, 248/255 held; 0.86 set, 216/255 held), a colour in 255 steps. Screen alignments 0 to 7 were
each set by a script and read back: `subleft left center right fullscreen noscale alignto640 center_safearea`
(vertical: `subtop top middle bottom fullscreen noscale alignto480 center_safearea`); 8 to 10 are named by the order
of the game's own list (`left_adjustable center_adjustable right_adjustable`) and were only seen on stock elements.

**Lua UI: a Lua walker, not a native walk.** The UI's Lua state already answers everything needed: a walker in Lua
goes from `Engine.GetLuiRoot()` through `getFirstChild` and `getNextSibling` and asks each element for `getRect`,
`getCurrentRGBA`, `getText`, `getElementTextDims`, `getCurrentAlignment`, `GetImage`, `getUseStencil` and `IsInWorld`.
These names were found by listing the engine's method table from Lua in a live run (178 methods). A native walk
would have needed the layout of the engine's element structure, which is not known, to get the same numbers. The
walker returns the JSON text. It writes a picture as the address of its material handle, and native code replaces
that by the material's name afterwards (a call from Lua into native code per picture is not needed). The Lua class
of an element comes from the table chain above it.

## Cost (measured, 11 Nov 2026, 1280x720, stock HUD: 691 Lua UI elements, 2 to 11 HUD elements)

| What | Measured |
|---|---|
| Size of one dump | 89 to 95 KB (stock HUD, 2 to 11 HUD elements); 126 KB with the pause menu open (950 Lua UI elements) |
| From the request to the file | 127 to 148 ms at 60 frames a second, about 8 frames: one to arm, one observed, the walk on the UI's next turn, one to write. The game keeps running meanwhile |
| The Lua walk (the one frame that pays) | 8 to 40 ms for 691 to 697 elements, 11 ms in the middle of ten dumps; 22 ms for 950 |
| Building and writing the JSON | 0.07 to 0.23 ms |
| Calls to the observers in one frame | one draw and one layout call per HUD element (2 to 11 here), one picture call per material element (0 to 2) |
| Frame time with the observers installed and no dump asked | not different from without them. One uncapped session of twelve 8 s windows in the order on, off, off, on: median frame 4.89 ms with, 4.83 ms without (+1.3 %; the first window, still loading, left out), while windows of the same state differ by 5.2 %. `iw7_perf.py compare` on all twelve: +2.9 % median, "a smaller change than 5.24 % is not established" |

When no dump is asked, each observer is one compare of a flag, and the frame tick one compare.

One lesson is kept in the code: the first version asked the system whether each address was readable before reading it
(two queries per picture). In this process a query costs about half a millisecond, and one walk took 150 to 560 ms.
Guarded reads took it back to the numbers above.

## Proof

All runs: 10 and 11 Nov 2026, `cp_zmb`, 1280x720, private local sessions from bench roots (loopback, random password),
gamelab plans with the `ui`, `hud` and `capture` steps. The frames and dumps stay outside the repository.

**P1. A server-drawn page.** The plan draws a page with the calls and the numbers of the Maxis terminal panel
(`newclienthudelem`; a `white` backdrop of 312x109 at x -6, y 80 anchored to the right, a rule of 2, a title at
scale 1.05, six rows at 0.68 to 0.78), takes a dump and a frame, destroys the page, takes both again.

| Measure | Result |
|---|---|
| HUD elements in the dump before, with the page, after | 2, 11, 2 |
| Texts of the page found in the dump with a rectangle | 7 of 7 (`MAXIS TERMINAL` at 821,129 135x20; the rows at 821,156 to 821,255) |
| The two pictures | `white` 803,120 468x164 and 803,120 468x3: the rectangle of the picture the game drew equals the layout rectangle |
| Rectangles that agree with the frame (`frame --base` the frame before the page) | 8 of 9: ink inside 24 to 38 % of a text's rectangle and 0 to 1.7 % in the ring around it; the panel changed 34 % of its pixels against the frame before and 0 % of its ring. The one that does not agree is the last row: 2 % of the ring under it holds descenders |
| `diff` page to closed | 9 removed, nothing else |
| Texts or pictures of the page in the dump after | none |

This is a page made by the test plan in a local session, not the `.menu` page itself on a dedicated server: the
terminal script runs only on a dedicated server, and the runner that joins a client to one takes no dump yet. The
client-side path (elements received from the server, laid out and drawn) is the same.

**P2. The stock Lua UI.** One dump of the stock HUD half a minute into the session: 691 elements, 11 levels deep; 135 texts
and 274 pictures by class; 109 on world surfaces; 42 visible texts or pictures on the screen. Known texts are there
with the right place: round `1` at 1217,37 and `SCENE` at 1162,46, clip `8` at 1067,648, reserve `32` at 1091,666,
cash `500` at 139,676 with `$` at 124,676. Against a frame with the HUD hidden (its alpha set to 0 by a Lua line),
6 elements agree by pixels: the clapboard picture, `SCENE`, the grenade icon, the first card of the fan (two
elements), the cash `500`. The others sit against textured neighbours or are rotated sprites and cannot be judged by
this pixel test; 10 are not drawn at all (see "not covered").
A stock menu: the pause menu (`CPPauseMenu`, opened by a Lua line) gives 950 elements, 259 more than the HUD,
under `LUIRoot/flowManager/CPPauseMenu`; the scoreboard (`ZomScoreboard`) 728, 37 more, with the player row and the
five column icons.

**P3. Defects found with no picture.** The project's Lua HUD (`bo3_zombies_hud`) could not be loaded on the lab
client. With the module in `iw7-mod/ui_scripts/bo3_zombies_hud/` and its opt-in file in place, the client ended with an
access violation (exit code 0xC0000005) at start, in the main menu, right after the module printed that its dispatch
hook was installed (`hook version=0.7.0 kind=dispatch installed=1`); twice in two launches. The session runner
kept no crash dump. The same client starts normally without the module. The cause was not looked for here.
So the defects were planted, twice:

| Planted | `check --baseline <dump before>` reports |
|---|---|
| Server-drawn: a line at the right edge, two cash texts 30 units apart | `PARTLY_OFF_SCREEN` (66 % off screen) and `TEXT_OVERLAP` (46 % of the smaller); 2 findings, nothing else |
| Lua UI: a line at the right edge, two cash texts, a portrait picture lower than the frame that clips it | `PARTLY_OFF_SCREEN` (52 %), `TEXT_OVERLAP` (50 %), `CLIPPED` (55 % of the portrait outside its frame); 3 findings, nothing else |

Without `--baseline` the stock HUD adds 15 `PARTLY_OFF_SCREEN` of its own (the fan of cards and the devil head in the
corner are laid out partly outside the screen).

**P4. Cost.** See "Cost" above.

## What is covered and what is not

Covered: every HUD element the client draws in the frame (text, value, timer, material), with the game's own
rectangle; the whole Lua UI tree of the frame (the stock HUD, open menus, a project's own Lua UI), with layout
rectangles, measured text sizes, alpha, colour, picture names, clipping.

Not covered, stated plainly:

- **The real shape of a text.** A text rectangle is the measured width and the line height. Descenders can leave it
  by a pixel or two (seen on the test page). Wrapped text, glow and shadow are not described.
- **What a picture shows.** A picture is a rectangle and a material name. Transparent margins inside a sprite are not
  known, so `PARTLY_OFF_SCREEN` on a picture can be harmless (the stock fan of cards). The pixels need `frame`, or a
  reader of the material.
- **Rotation and scale of Lua UI elements.** The engine reports the layout rectangle before the element's own rotation
  and scale. A rotated card is listed unrotated. It needs the engine's element structure (not decoded) or a native
  observer of the Lua UI's quads.
- **Lua UI hidden by another way than alpha.** A mask picture, a radial bar at zero, an element scaled to nothing
  still count as visible. In the stock HUD this was 10 of 42 visible texts and pictures (a ticket mask,
  eight segments of the grenade bar, one timer text). The same native observer would settle it.
- **Animations.** A dump is one frame. The HUD element's own fade, move and scale fields are in `raw`; a Lua UI
  animation in progress shows only its current alpha and rectangle. Take two dumps and `diff`.
- **3D world-space markers.** A waypoint HUD element (type 13) is listed with its fields and no rectangle. Lua UI drawn
  on world surfaces (arcade screens) is listed and marked `world`, and never judged as a screen position.
- **What the engine draws outside both layers**: the console, the build text at the bottom of the screen, the
  crosshair, subtitles, the kill feed if it is not Lua. They are in no dump.
- **Drawing order between the two layers** and between Lua UI siblings: not judged. `sort` of a HUD element is given.
- **Other players' names and addresses.** A dump of a private session holds none. A player-name HUD element or a
  scoreboard would carry names: dump only private test sessions. Anything shaped like an IPv4 address is replaced by
  `<address>` in every string the native code writes; bytes above 0x7F are written as `\u00XX`, so a non-ASCII text
  is not readable as such.
- **The frontend** (main menu) was not dumped; nothing prevents it.

## Files

| File | Role |
|---|---|
| `src/native/paris_ui.cpp` | the commands, the three observers, the Lua walker text, the JSON writer |
| `ops/engine-map/iw7_ui.py` | the reader |
| `tests/ops/ui_dump_test.py` | tests of the reader on synthetic dumps and frames |
| server repository `ops/gamelab` | plan steps `ui`, `hud`, `hudclear` (docs/GAMELAB.md there) |
