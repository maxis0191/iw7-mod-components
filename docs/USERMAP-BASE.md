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

## Which asset is used when two zones hold the same name (read 24 Nov 2026)

Read from the decompiled engine (`ops/engine/engine.py decomp`), no game. The raw text of every function named here is kept on the machine under `C:\studio-data\r1\engine`.

**The link of one asset, `FUN_140a782b0` (type, pointer to the header pointer).** It runs for every asset of a zone while the zone loads.

1. The name is looked up in the asset name table (`DB_AssetEntryTable_FindAsset(&s_assetManager_table 0x1453E7370, name, type)`). A name that starts with `,` is a reference: when the name is
   known, the loading zone gets the known asset and nothing is added; when it is not, `FUN_140a76ab0` makes a PLACEHOLDER entry with zone slot 0 (a copy of the type's default asset under
   that name).
2. A real asset whose name is already known: `FUN_140a78230(existing, loading zone)` walks the existing entry and the entries chained behind it (`+0xC`) and asks, for each one with a zone slot
   other than 0, `FUN_140a7c400(entry zone, loading zone)`: "is the loading zone of the same family as the zone that holds this entry". When any answer is yes the NEW asset is thrown away
   (`FUN_140a77d20` frees it, the zone's pointer is set to the existing asset): **the asset loaded first stays, the later one never exists.**
3. `FUN_140a7c400`, with `f1` the flags of the zone that holds the entry and `f2` the flags of the loading zone (zone table 0x143A124F8, flags at +0x470, `FUN_1403bc380`):
   * `f1 & 0x4F800` set: the same family only when it is the same zone slot;
   * otherwise equal flags: the same family;
   * otherwise `f2 & 0x10000`: the same family when `f1 & 0x3F` is set; `f2 & 0x20080` (a level zone, DB_ZONE_GAME 0x80): when `f1 & 0x1F` is set (any permanent zone: code, common, global, a
     resident base); in every other case: when `f2 & 0x1F` is set and `f1 & 1` is set.
4. Not the same family: the new asset gets its own entry, which `FUN_1403b56b0` hangs at the END of the existing entry's `+0xC` chain. The name still answers with the FIRST entry; the
   loading zone's own pointers go to its own copy (`*header = new entry's header`). Only when the first entry is a placeholder (zone slot 0) does the new asset take the name
   (`FUN_140a7a260`: the contents are swapped into the placeholder's header, so every pointer taken earlier now sees the real asset). `DAT_145685992` (set by `FUN_140a7b290` while a zone with
   `flags & 0x7F800` loads) narrows that swap to one case of type 0x12; for a level zone it is 0.
5. An entry of the chain becomes the first one only when the zone of the first entry is freed (`FUN_140a76280`, `FUN_140a78ab0`: zone slots and header contents are swapped, the freed zone's entry is removed).

**So the rule is: the zone loaded FIRST wins the name. No flag makes a later zone win; a later zone is either thrown away (same family) or parked behind the first one.**

**How the stock patch zone wins.** By being queued first, not by a priority. The engine's zone load function (`0x1403BA920`, the function our `fastfiles.cpp` stub replaces) queues, for a zone
`X` loaded with a level flag, in this order (calls of the queue function `FUN_1403baea0`): `techsets_X` (0x1403BAAB7), `cache_X` (0x1403BAAFB), `patch_X` (0x1403BAB37), two language forms of the patch
zone and the language zone (0x1403BAB88, 0x1403BABC7, 0x1403BAC01), and `X` itself LAST (0x1403BAC19). `patch_cp_zmb` and `cp_zmb` carry the same flags, so every asset of `cp_zmb` that the patch zone
also holds is thrown away at step 2. The relation is derived from the zone's NAME by the load function, and it is nothing but the order.

**What that means for a usermap with a base zone today.** `load_before` runs at the top of the stub for the map's zone: the base zones (and, for each, the engine's `techsets_`, `cache_`, `patch_`)
are queued BEFORE `techsets_<map>`, `patch_<map>` and `<map>`. With the base loaded with the level's flags (0x80, equal flags) or as `resident` (0x1, `f1 & 0x1F`), every asset of the map zone AND of
`patch_<map>` whose name a base zone, its patch zone or a permanent zone already holds is thrown away at step 2. It does not matter for a byte-identical copy; for an asset the map changed under a
stock name the game silently runs the stock one (measured in Studio: lightmaps, visions).

## F8, the hint table of a reference build: measured 25 Nov 2026 (the same-name hypothesis is refuted)

**Error line** (server log of `forge run C:\studio-data\c2\plans\hintprobe.json`, run `20261124-045610-0186-c2_hintprobe`): `Can't precache more assets of type 'hint string' (max is 255): 'C2 PROBE HINT NUMBER 2'`. It comes from `FUN_1405e9d90` (the hint registrar called by `PlayerCmd_sethintstring`, 0x140B3BED0): it walks the config strings 2..255 (`FUN_140c11780(i)` = the string id of slot i, `DAT_145d5af00` = the empty id), returns the slot of a string that is already there, and at slot 255 it calls `Com_Error(1, "Can't precache more assets of type 'hint string' (max is 255)")`. A hint set by script that no NCS list pre-registered takes the first empty slot; with none left the level ends.

**What fills the 254 slots: every netconststrings asset that is loaded, not one by name.** `FUN_1406d43c0` (called at level load) requires `ncs_<kind>_level` (`DB_FindXAssetHeader(0x3a, ...)`, error "Missing NetConstStrings asset"), then lists EVERY loaded asset of type 0x3a (`FUN_140a77a00`), sorts them and hands each to `FUN_1406d52b0`, which appends its strings to the per-kind list (`DAT_145205ae0 + kind*16`, entries in `DAT_145205c70`; a kind's capacity is the word at `0x1414B7764 + kind*8`; over it the function returns 0 and the load ends with EXE_TRANSMITERROR). Kind 15 is `hnt`.

**Measured in running sessions** (`forge peek`; walkers `C:\studio-data\r1\ncswalk.py <cell> <out>` and `hintdump.sh <cell> <out>`, results `C:\studio-data\r1\logs\ncs_*.json`, `hints_*.json`):

| session | hint (`hnt`) NCS assets loaded (strings) | slots used of 254 |
|---|---|---|
| stock `cp_zmb` | `ncs_hnt_eng_cp_zmb` (235), `ncs_hnt_eng_code_post_gfx` (6), `ncs_hnt_eng_patch_cp_zmb` (9), `ncs_hnt_level` (2) | 252 |
| Studio reference build (Courtyard, `.base` = `cp_zmb resident`) | the same four, same order, byte-identical table | 252 |
| full build (testmap1.l1old, 471 MB, no base zone) | `ncs_hnt_eng_code_post_gfx` (6), `ncs_hnt_level` (2), then the 2 hints its scripts set | 10 |

`loc` shows the same split: 371 strings (`ncs_loc_eng_cp_zmb` 315, `ncs_loc_eng_patch_cp_zmb` 15, code 41) with the base, 41 without. 57 NCS assets are registered with the base, 46 without.

**So the cause is not an asset that the base zone wins.** The map's `ncs_hnt_level` (2 strings) and the stock one are equal in content, and a throw-away of either changes nothing. The 244 extra slots are taken by assets with their OWN names (`ncs_hnt_eng_cp_zmb`, `ncs_hnt_eng_patch_cp_zmb`: the language-zone copies of the base and its patch zone, not in the zonetool dump of `cp_zmb`), which nothing throws away because no map zone holds a same-named asset. Loading the base zone loads those, and the engine sums them. Capacity, not precedence: the "map assets win" rule of the previous section would leave the table at 252 and does not fix F8. (It is still a valid fix for the other class: lightmaps, visions, a changed stock asset.)

**Where the fix has to be (candidates, none built):**
1. The base's language-zone NCS are what costs the slots: a `.base` option that keeps the base's language companions (`<lang>` forms of the zone and of `patch_<zone>`) out of the load (the loader already builds the extras by hand for `nopatch`). The cost: the base's localized strings (hint texts, `ncs_loc_eng_cp_zmb`) then are not there, so the map's own zone must carry the localize entries it uses (a full build does; Studio's `refbuild.py` already decides held or carried per asset, `localize` is in its WORLD list).
2. A filter in the ingestion, `FUN_1406d52b0` (0x1406D52B0): for a usermap, skip the `hnt` and `loc` kind of assets named `ncs_*_eng_<base zone>`/`_patch_<base zone>` (server and client both run it, so the indices stay equal). The 254-slot limit itself is the config string range and not movable without the network protocol.
3. Raise nothing: the limit `0xff` at `FUN_1405e9d90` and the config string layout are the protocol; not a candidate.
Not measured: which zone file holds `ncs_hnt_eng_cp_zmb` (the stub logs no zone list; by its name the language zone of `cp_zmb`), and whether the stock Spaceland scripts depend on the pre-registered slots (a hint set by script that is not in the table takes a slot at first use, so they should not).

## F8 fix: the base's hint lists are not registered (candidate 2, lead's decision 25 Nov 2026; built in source, not run)

**Why not candidate 1** (keep the base's language zone out of the load): its localize entries are still referenced by the base's stock scripts and assets (perk machines, wall buys, HUD); a reference build's map zone does not carry them, so raw keys would show.

**What it does.** `src/native/paris_usermap_ncs.cpp` hooks `FUN_1406D52B0` (the per-asset registration of the NCS pass `FUN_1406D43C0`; the only other callers are `FUN_140B7A5A0`, which registers other assets, never named `ncs_hnt_*`). While the usermap whose `.base` was read last is in the zone table and the dvar is on, an asset named `ncs_hnt_<lang>_<base>` or `ncs_hnt_<lang>_patch_<base>` (`usermap_base::is_base_hint_list`, pure text rule, tested in `tests/native/usermap_base_test.cpp`) returns 1 without registering. `paris_usermap_base::load_before` records the usermap name and the base list for it (`current_usermap`, `current_bases`; cleared when the same usermap is read without a `.base`). Nothing else changes: `ncs_hnt_level` (the map's own), `ncs_hnt_eng_code_post_gfx` (the code zone) and every other kind stay. A hint that a stock script sets still takes a slot at its first use (`FUN_1405E9D90`), so a perk machine or wall buy shows its stock text (the key is the same string, the localize entry is still loaded).
- **Expected table:** about 8 pre-registered slots (6 code, 2 level) instead of 252, plus whatever the map and the stock scripts set. Station Zero's 70 hints fit with room.
- **Server and client alike.** The pass runs on both (the sum of all lists is hashed into `DAT_145206474` and the two sides must agree). The component is registered on every pipeline (no `is_dedi` gate; `load_before` sits on the zone load itself, also on the dedicated server). Both sides need the same switch value: a client with `paris_usermap_hint_filter 0` against a server with `1` sums different lists. Default 1 on both.
- **Dvar `paris_usermap_hint_filter`** (int 0..1, default 1; 0 = the stock behaviour, for the A/B in one build). No effect on a map without a `.base`, and none on stock `cp_zmb` loaded after a usermap in the same process: the filter needs `current_usermap` in the zone table, and the level zone of the usermap is gone by then (the proof plan reads 252 slots again).
- **Reload in place** (`studio live sync`): `load_before` reads the `.base` again and sets the same names; the NCS pass runs again with the filter on, so the table is rebuilt the same way.

**Why only the hint kind.** Capacity per kind measured in the reference session (table limit at `0x1414B7764 + kind*8`, entries with the base): hnt 255 / 252 (bound); loc 2048 / 371; mdl 2048 / 1385; efx 512 / 373; wep 450 / 298; mat 350 / 47; lui, rmb, rmg, ges, acl have no table limit (-1 base); every other kind is under half of its table. Only the hint table is full, so only that kind is filtered; the others keep their lists (the language lists `ncs_loc_eng_<base>` are needed to show the base's text and cost nothing that matters).

**The "map assets win" link rule** (the previous design section) stays design only. It is the open fix for the other class: lightmaps, visions and every other asset that a map changed under a stock name and that the base zone, loaded first, silently replaces. It does not fix F8.

**Proof, the lead's commands** (plans in `C:\studio-data\r1\plans`, library `C:\studio-data\r1\lib\r1probe.gsc`, tools `ncswalk.py`, `hintdump.sh`; reference usermaps are to be built into `C:\studio-data\r1\um\sz_ref\cp_iwz` and `...\small_ref\cp_iwz`, or edit the batch):
```
pwsh ops\enginelab\Get-LabClient.ps1 -ComponentsRoot C:\Users\ezvalo\Documents\IW7-Products\worktrees\components-r1
python -B C:\forge\forge.py batch C:\studio-data\r1\plans\r1_hint_batch.json      # 70 of 70 on Station Zero and the small map (was 0 of 70); stock hint keys set by script
bash C:\studio-data\r1\hintdump.sh <cell> out.json                               # slots used: about 8 + the map's own, not 252
python -B C:\forge\forge.py batch C:\studio-data\r1\plans\r1_five_ref.json        # 70/70, 76/76, 128/128, 20/20, 10/10
# stock after usermap in the same cell: run r1_idle_stock.json on the cell that ran a usermap, hintdump.sh: 252 again
# A/B: --dvar paris_usermap_hint_filter=0 on the same plan gives the old 0 of 70
```

## F9: the map's own assets win over the base's same-named ones (built in source 25 Nov 2026, not run)

**Measured first (sz_ref, lead's build, new client a35c0d3):** the five acceptance plans pass 5/5 on `sz_full` and 4 of 5 fail on `sz_ref` (doors 70/70; economy 59/76, post_routes 104/128, rounds_start_closed 11/20, rounds_05_06 6/10). In the live NCS tables `ncs_efx_level` of the reference session has 349 strings, the base's; the map's own list has 365 (`c2\work\zonetool\cp_iwz\netconststrings\ncs_efx_level.json`, shared work folder, not the build's own copy): the map's list is the one thrown away (`ncs_mdl_level` 1355 and `ncs_wep_level` 140 have the same counts in both).
**Which same-named assets differ in content (the expected winners).** From the build's own record (`cp_iwz.build.json`, `reference.kept_edited_or_unlisted`, 142 rows the build edited or wrote): only 6 carry a name that a base zone also holds: `image,*reflection_probe_array`, `rawfile,techsets_cp_zmb`, `techsets_global`, `techsets_global_cp`, and the `vision/cp_zmb_*.vision` files; the other 136 have no same name in any base zone (custom materials, models, effects). Rows with the reason "world type" that share a name with the base (`ncs_*_level`, 23) and "patch zone" rows (869; `classify` tests the patch set before the edited set, so an edited row under that reason is not listed) cannot be told apart from stock by the build record: their content was not hashed (the asset root that would allow it is the shared work folder, rewritten by every build).

**Design: order, not engine surgery.** The link step keeps the asset of the zone linked first (section above). Park-and-promote was judged against the code and not built: the engine's free path (`FUN_140A76280` -> `FUN_140A78AB0`) copies the successor's header contents into the first entry and returns the successor's pooled header to the pool, and a zone that kept a pointer to that header depends on the pointer fix-up (`FUN_140A79DB0` / `FUN_140A259A0`) that nobody could test here; a swap would hand the base zone a header the free path then releases. The engine's own forward-reference path has no such risk: a `,name` reference to an asset that is not loaded yet makes a placeholder (`FUN_140A76AB0`, zone slot 0) and the later real asset fills it (`FUN_140A7A260`). So:
- `load_before` runs in two phases (`usermap_base::base_phase`). With `paris_usermap_map_wins` 1 (default) the base zones are queued AFTER the engine's load of the map (`techsets_<map>`, `patch_<map>`, the map zone): the map and its patch zone are linked first and win every name; the base's duplicates are thrown away at its link step (same family), and the map's references to base assets resolve through placeholders. The fastfiles stub edit (`frame-cut-edits.json`) calls `load_before(..., phase after)` after the original zone load.
- With 0 the old order (base first) runs, unchanged.
- **Base is not resident under map-wins** (`usermap_base::map_wins_mode`: permanent flag off, also for the companions): the base's thrown-away assets point at the map's headers, so the base must be freed with the map. The base is therefore freed at map unload and a stock `cp_zmb` loaded afterwards finds all its own assets (nothing of the map left in a name); the price is the base zone load (about 3.6 s) at every reload of the map. A `.base` with `resident` is honoured only with `paris_usermap_map_wins 0`.
- **Log:** the engine's drop (`FUN_140A77D20`, one caller, the link step) is hooked; when the kept copy belongs to the map zone or `patch_<map>` the line `[usermap map wins] <type> <name>: the copy of zone <zone> is kept over the base's` is written once per asset (at most 4000).
- **Risks, each to read in the first run:** (1) the engine may need the base's assets while the map zone links (a `,name` reference to a type with no placeholder path); the log would show `Error: Could not find` lines; (2) the zone queue may not run in queue order (the old base-first order relied on it too); (3) the hint filter keeps working: it only removes the base's `ncs_hnt_*` lists.
- **Reload in place (`studio live sync`):** each reload goes through the front end and queues map then base again (the base is not resident); nothing survives between loads.

**Proof plans** (`tools-source/usermap-proof/plans`, batches with `C:\studio-data\r1\um\...` paths): `r1_five_ref.json` (target 5/5 like `sz_full`), `r1_hint_batch.json` (70/70 on sz_ref and small_ref, stock hint keys), `r1_stock_after.json` (the usermap's cell switches to `cp_zmb`: read `ncswalk.py` while it waits, `ncs_efx_level` must be 349 and `hnt` 252 slots again), the reload probe: `STUDIO_MAX_INPLACE=12 python C:\studio\tools\reload_probe.py <small map document> <out> --reloads 2 --start --edit` (row kind `real`, `edit_seen` true, base zone loaded each time), and the log read: `grep "usermap map wins" <server log>` lists the winners (expected to include `rawfile techsets_cp_zmb`, the vision files, `netconststrings ncs_efx_level`).
