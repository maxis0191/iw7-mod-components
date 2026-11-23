# Usermap base zones: what a reload does, and the resident zone

Studio gate G1 (reference build): `usermaps/<map>/<map>.base` lists stock zones that load right before the map's own zone, so the map's fastfile carries only its own
assets. This page is what the loader and the engine do with such a zone when the same map is loaded again in the same game process (Studio's edit loop, line L2/L3),
read from the engine database (`ops/engine/engine.py decomp`), from the game's console log and from the process while it ran, 23 Nov 2026.

## The line options

```
cp_zmb                 the zone, loaded with the level's flags (DB_ZONE_GAME 0x80), the engine adds techsets_cp_zmb and patch_cp_zmb  (default, unchanged)
cp_zmb nopatch         the custom flag: the engine adds none of its extras, the loader adds techsets_/cache_ by name                    (components claude/usermap-base-keep2)
cp_zmb resident        the zone is loaded ONCE per game process with DB_ZONE_PERMANENT (0x1) alone; a later load of a map that lists it skips it while
                       the engine's zone table holds it
techsets_cp_zmb resident   (the zone's techsets, listed first by the build, because the engine adds techsets_<zone> only for a level flag)
```
Options come after the name, in any order, each once (`nopatch resident` is allowed); an unknown or repeated option rejects the line (logged, line skipped).
`compile.build` writes the resident form with `IWZ_BASE_RESIDENT=1` (Studio repository); without it the file is what it was.

## What a reload in place does today (no `resident`)

`studio live sync` after a geometry edit: `clear` + `hud studio_unload` (the live script runs `disconnect`), the new files are copied into the game's usermap folder, `forge live
reload` (a `map` command in the same process). The console log of one reload (23 Nov, test map, reference build; seconds from the unload):

```
 0.00 [IWZ local] LIVE ack op=hud unload=1
 0.28 ==== ShutdownGame (1) ====
 1.57 Loading zone cp_frontend                       (a disconnect goes through the front end: 1.3 s)
 1.85 Starting map: cp_iwz
 1.95 Loading zone cp_iwz_load
 2.00 Loading base zone cp_zmb for usermap cp_iwz     (the loader's line: this load is the base zone, flags 0x80)
 2.00 Loading zone cp_iwz
 5.7  Tried to load missing language zone: eng_cp_iwz   (the zone load is over)
 9.2  ------- Game Initialization -------              (3.5 s of map zone and engine init after the last zone)
 9.5  Loaded custom gsc ... forge_boost / iwzmap_local / patches
 ...  [IWZ level] intro_over=0 ... intro_over=1, SPAWNED, forge gate over
```
(S4 and S5 measured the same lines, `compile/README.md` of the Studio repository: zone load about 7 s of which the stock zone 3.6 to 3.8 s, front end 1.3 s, intro 1.6 s.)

What the engine does with the zones, read from its code:

* A map load queues the zones to load (`FUN_1403baea0`: a table of 373 entries of 0x8c bytes at 0x1439F6CE0). The loader's `load_before` queues the base zone through the same
  entry point with the map's own flags: the console log of the old loader says `zone flags 80`, DB_ZONE_GAME.
* The engine's zone table has 373 slots of 0x478 bytes at 0x143A124F8 (the name first, the flags at +0x470; `DB_Zones_IsValidZoneIndex`, `DB_Zones_GetZoneNameFromIndex`).
* The level is left by freeing zones **by flag mask**: `FUN_1405AE560` calls `DB_UnloadFastfilesByZoneFlags(0x80)`, `FUN_1405AE720` the mask 0x100, `FUN_1405AE6D0` 0x64B80, the
  four server-side callers 0x60000. The free loop (`FUN_140A7B7D0`) walks the slots 1..372 and frees a zone when `(mask & zone flags) != 0` (`FUN_1403BBF40`).
  **So the base zone, loaded with 0x80, is freed by every `disconnect` and loaded again by the next `map`: cp_zmb (206 MB in memory, 3.6 to 3.8 s) goes in and out of memory at
  every reload.** (A mode switch, `FUN_1405AD050`, frees by the mode's whole flag set, which includes DB_ZONE_PERMANENT: a resident zone does not survive that.)
* Every asset of a zone sits in the asset name table (`s_assetManager_table` at 0x1453E7370: 105,472 buckets, 20-byte entries, the next entry of the same chain at +0xC, the zone
  slot at +0x12). Two zones that hold an asset of the same name hold one entry each in the same chain; the free path (`FUN_140A76280`) unlinks the entries of the zones it frees
  (`FUN_140A78AB0` for an entry that has older ones behind it).

## The third load hangs

Measured by the Studio workers on 23 Nov (`compile/README.md` of the Studio repository, S4 and L3): a map with a base zone reloaded in place hangs on the third load of the process (3 of 3 sessions; a full
build, with the stock zone inside the map's fastfile, reloaded five times in a row). The game thread spins at `0x1403B5934`, the chain walk of `FUN_1403B58C0`, called from `FUN_140A789A0` (the free path:
find the entry of an asset by its header pointer in the chain of its name). Read from the engine database:

* the asset name table is an array of 20-byte entries (`s_assetManager_table` 0x1453E7370: +0 header pointer, +8 next entry of the bucket, +0xC an older entry of the same name (an override held by another
  zone), +0x10 flags, +0x11 type, +0x12 zone slot); the bucket of a name is `hash(name) % 0x19C00` (`hash = hash * 31 + c`), the walk ends at index 0;
* the walk never ends only when the chain is a ring. The table read from outside in a fresh process after ONE load (L3, `tools/reload_probe.py`): 59,938 buckets used, 89,047 entries in chains, highest entry index 89,173, longest chain 8,
  0 cyclic chains, commit 8.0 GB. In the hung process of S4: highest index 89,169, 6 cyclic chains. The table is not fuller after the hang than after one load: **the count is the same, so the table did not
  overflow; chains were corrupted.** What is special to the reference build is that two zones hold assets under one name (the map's own copies of stock names, `classify` in `compile/refbuild.py` keeps 20 to 800 of them) and the
  base zone is freed and queued again around them at every reload; the full build has one zone, no `+0xC` override chains. The engine's own unlink of an entry that has an older one behind it is `FUN_140A78AB0`.
* a zone that is never freed is never unlinked: that is the resident zone's whole argument (its entries stay, the map zone's are the only ones that come and go, in the order the engine's own patch zones are loaded and freed with every level).

This page does not prove the cause: the hung process of the proof run (below) shows it.

## The resident zone: what changes

* `usermap_base_policy.hpp`: the line option `resident`, `load_mode`, `load_flags` (a resident zone carries `DB_ZONE_PERMANENT` alone: no level bit is left for a mask to match),
  `same_zone_name`, `zone_slots`.
* `paris_usermap_base.hpp`: `zone_loaded(name)` walks the engine's zone table; a resident zone that the table holds is skipped (the log says so), one that it does not is loaded
  with the permanent flag; its companions listed on the line above it are separate lines with the same option. The loader keeps no list of its own: a zone the engine freed (a mode switch) is loaded again.
* `frame-cut-edits.json`: the lambda of the `fastfiles.cpp` edit takes the `load_mode` and builds the flags with `usermap_base::load_flags`; nothing else of the file changes.

Risks, each named before the first run: (1) the engine may need a level bit on the zone while it loads (techsets are queued only for a level flag: the build lists
`techsets_<zone> resident` explicitly for that reason); (2) `patch_<zone>` is still queued by the engine for the zone, with the permanent flag too; (3) a stock map loaded later in
the same process finds the zone already there; (4) the assets of the map zone that share a name with the resident zone's are chained in front of it, as they are today.

## Build and proof (the lead's commands)

```
# 1. tests that need no game (Build-Voice runs the native one); here:
python -B tests\ops\usermap_resident_test.py
python -B tests\ops\frame_cuts_test.py
# 2. the lab client from this branch (server repository; the native build runs the native test and the judge):
#    pwsh ops\enginelab\Get-LabClient.ps1 -ComponentsRoot C:\Users\ezvalo\Documents\IW7-Products\worktrees\components-l3
# 3. a map built with the resident list (Studio repository, branch claude/l3-loop):
$env:IWZ_BASE_RESIDENT = '1'; python -m compile.build <emit> --out <usermap>\cp_iwz --reference   # .base = techsets_cp_zmb resident / cp_zmb resident
# 4. the proof: tools\reload_probe.py (Studio) on the test map with the new client: six reloads in place, no hang, commit and the asset table stable,
#    the log says "is resident, not loaded again" from the second load on, the zone load shrinks by the stock zone's 3.6 s
$env:STUDIO_MAX_INPLACE = '9'; python tools\reload_probe.py <test map folder> <out> --reloads 6 --start
```
