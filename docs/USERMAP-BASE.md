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

## F9: the map's content of the data tables the engine reads by name wins (26 Nov 2026; measured, built in source, not run)

**Load order was tried and abandoned.** Queuing the base zones after the map zone (`paris_usermap_map_wins` 1 and 2, client `1f1fdc3`, `fe635e9`) links the map's assets first (the log showed the winners) but every usermap server dies about 13 s into the load: read at address 0 in `FUN_1400A0F60`, the stream-state copy of the zone load stage `FUN_140A7C8A0`, for a zone slot whose struct is empty (`FUN_1403BC9D0` zeroes a finished slot). The cause was not found and the order is not used. The code is removed.

**The data (ZoneTool v2 develop, `zonetool_dev_p.exe`, `dumpzone`).** The map zone is Station Zero's reference build (`sz_ref\cp_iwz.ff`, 153.8 MB), compared file by file with the dumps of `cp_zmb` and `patch_cp_zmb` (`C:\studio-data\r1\zt`, script `cmp.py`). 3,781 files in the map dump. Per type, same name:

| result | files |
|---|---|
| map only (name not in `cp_zmb` or `patch_cp_zmb`) | 2,871 (techsets 1,605, images 420, localized strings 301, materials 292, xsurface 81, xmodel 55, ...) |
| same name, byte-identical content | 210 (animpkg 59, root 55, scripts 16, cp 19, gesture 4, xmodel 23, sfxpkg 9, ...) |
| same name, bytes differ | 699 |

The 699 are not 699 content differences. Binary dumps hold raw pointer values (the first differing byte is at offset 6, a name pointer), so every file with the same size and few differing bytes is the same asset: xanim 337 (same size 337 of 337), xmodel 50 of 51 (one size differs), xsurface 43 of 43, images 61 of 61 (60 pointer-only, one is the probe array below), physicsasset 6, particlesystem 31 (20 with up to 744 pointer bytes, content not decided). Text types can be read: weapons 27 differ only in representation (a `,name` reference marker, `null` fields; no value differs), scriptables 137 differ in size because the stock copy refers to a sub-asset by `,name` where the map's copy has it inline (the strings are the same). The real differences:

| asset (type, name) | what differs | read by |
|---|---|---|
| `stringtable cp/zombies/zombie_perks_bit_mask_table.csv` | the map adds 5 rows: 18 `perk_machine_bakers`, 19 `perk_machine_voyage`, 20 `perk_machine_grudge`, 21 `perk_machine_double`, 22 `perk_machine_double_cd` | the stock perk scripts, by path |
| `netconststrings ncs_efx_level` | the map's list has 365 effects, the base's 349: the 16 extra are `vfx/iwz/vfx_iwz_flashlight_*` (copy of the NCS json in the shared work folder; the v2 dump has no NCS folder) | the engine, by `ncs_<kind>_level` (`FUN_1406D43C0`) |
| `rawfile vision/cp_zmb_alien.vision`, `cp_zmb_ghost_path`, `cp_zmb_int_basement`, `cp_zmb_int_triton_main`, `cp_zmb_int_triton_ride` | other values (for example `r_ssaoStrength` 2 against 1, `clut1Image shipcrib_clut` against empty) | vision names set by script and map |
| `rawfile techsets_cp_zmb`, `techsets_global`, `techsets_global_cp` | edited by the build (build record `kept_edited_or_unlisted`); not in the dump folders, content not compared | the techset loader |
| `image _reflection_probe_array` | 1.1 MB of 21 MB differ: the map's baked probes | the world |

**The failing expectations.** `accept_economy` on `sz_ref` (59 of 76) fails exactly where the perk table matters: `perk_prepower` (a perk was sold), `perk_revive.perks1` 2 for 1, `perk_tough.spent` 0 for 2500, `perk_run`, `perk_rat`, `perk_deadeye`, `perk_bakers` one perk short, `perk_limit.spent` 2000 for 0, `perk_voyage.spent` 0 for 2000: the stock perk scripts read the base's table without rows 18 to 22, the map's five perks have no bit. `post_routes` (104 of 128: `r_blow_*.volume` none / maint_corridor instead of the target volume) and the round stalls (`szf_rounds_*`) are not explained by any asset above; they may follow from the perk state (the plans that fail in rounds use perks and the rider uses the route triggers), or from the effects list / probe array, and are to be re-read after the table is fixed. The 4 failing plans fail on `sz_ref` and pass on `sz_full` with the same client, so the cause is in the reference build, and these assets are the complete content set of that build that the base wins.

**Design: content swap in the link step, restore before the map zone is freed.** Only the types the engine or scripts read by a fixed name and whose header is a plain structure: raw file (48), string table (50), netconststrings (58) (`usermap_base::is_data_table_type`). Images, models, scripts and every other type stay as they are (identical in content or pointer noise).
- Hook `FUN_140A77D20(new_header, existing_header, type)`, the throw-away of the link step `FUN_140A782B0` (one caller). The loading zone is `*(int*)0x143A7A7D4` (`FUN_1403BC130`). When it is the usermap's own zone or `patch_<map>` and the entry that holds the name (`DB_AssetEntryTable_FindAsset`, zone slot at +0x12) belongs to another zone, the header bytes of the map's asset (`DB_GetXAssetTypeSize`, `0x1409E5BD0`, at most 256) are copied over the entry's header. A zone's pointer to the name then reads the map's content, and so does a lookup by name and the NCS pass. The base's header bytes are kept (once per type and name).
- Hook `FUN_140A76280(table, mask, list)`, the free of the assets of a list of zone slots. When a slot of the usermap's own zones is on the list (`list` = `{u16* slots, u32 count}`), every swapped header whose entry still exists and still holds the same header pointer gets its saved bytes back, before the engine frees the map's zone memory. So a resident base and a stock map loaded later see the stock content again; the in-place reload of `studio live sync` restores and swaps again at each load.
- Log: `[usermap map wins] <type> <name>: the content of zone <map> replaces the one of zone <holder> (put back when <map> unloads)` once per swap, and `N of M swapped assets put back` at the unload.
- Dvar `paris_usermap_map_wins` (int 0..1, default 1, 0 = the old behaviour): Forge's `--dvar` is applied before the map reload, which is when the link step runs, so a plain A/B on the same client works.
- Risks, to read in the first run: (1) the structures are copied shallow, so the map's strings stay in the map zone's memory; the restore comes before the free; (2) `FUN_140A76280` may be called for other frees while the map stays (the hook only acts when a map-own slot is on the list); (3) a zone's own pointer to the asset keeps pointing at the entry's header, which is what is swapped, so no pointer is rewritten; (4) the first hint of a failure would be a crash at the unload.

**Rename route (the narrowest for the rest).** The five visions and the probe array are looked up by names that Studio's build controls (as for the lightmaps it already renames per map); the techset rawfiles and `ncs_efx_level` and the perk table are fixed names (the engine, the stock scripts). The swap above covers all of the fixed names with one mechanism; renaming stays the way for assets of other types whose content differs, none found in this set.

**Proof plans** (`tools-source/usermap-proof/plans`): `r1_five_ref.json` (target 5/5; economy is the plan that this change must fix), `r1_hint_batch.json` (70/70 stays), `r1_stock_after.json` (stock `cp_zmb` after the usermap in the same cell: `ncswalk.py` must show `ncs_efx_level` 349 and `hintdump.sh` 252 slots; this proves the restore), and a log read: `grep "usermap map wins" <server log>` must list `stringtable cp/zombies/zombie_perks_bit_mask_table.csv`, `netconststrings ncs_efx_level` and the five visions.

### F9, first run of the swap (client eaa5a11): the level did not start; the swap is now listed, not general

Cell `c4099a443` (small_ref, new client): the server reached `------- Game Initialization -------` and loaded the map's scripts (the last line is `cp_iwz_perk_doubletakes.gsc`), then nothing until Forge stopped it at 180 s (`ShutdownGame` and `0 of 33 swapped assets put back` are the stop). The log lists 33 swaps: 28 string tables (`cp/zombies/zombie_loot.csv`, `cp/cp_weapontable.csv`, the `mp/*settings*.csv` tables, ...), `animtrees/mp_script_model.atr`, `cp/constbaselines/bl_pc_cp_zmb_zombie.bin` and the three `techsets_*` rawfiles, and no netconststrings. Each is a table that the map carries as an unedited copy of the base's (the text dumps are equal). The map's copy is written by the v1 zone writer and its header is not necessarily laid out like the stock one (index and hash fields); the stock scripts that read these tables hang on it. A blanket swap is wrong; the swap is limited to what the build itself says it edited.

**`.base` lines `!<type> <name>`** (`usermap_base::parse_wins`; types rawfile, stringtable, netconststrings): only the listed assets are swapped, and without a list nothing is. Studio's reference build should write the list from the set it already knows as "edited by the build" (`refbuild.py`, `owned`), restricted to those three types. For Station Zero it is written by hand in `C:\studio-data\r1\um\sz_ref\cp_iwz\cp_iwz.base`: the perk table, `ncs_efx_level`, the five visions (the three techset rawfiles stay out until needed). The log of the next run must show only those names (`grep "usermap map wins"`).

Not understood, to read next: why no `netconststrings` reached the swap in the 33 (either the map's NCS assets are not thrown away at that call, or their type is not 58 there).

### F9: the cause of the five plans is the world assets, measured (26 Nov 2026); the fix is a header-pointer promotion

**Where the reference build differs from the full build, found by probes** (client 558f8fa, plans `r1_perkstate`, `r1_volstate`, `r1_volext`, `r1_volgeo`, `tools-source/usermap-proof`):
- The perk lists are not the cause: swaps were logged (perk table, five visions) and `perk_prepower` still sold. The state of `perk_machine_tough` before power: `requires_power` 1 in both builds, but the struct's `power_area` is `undefined` in the reference build (`platform_a` in the full build) and `powered_on` is 1 from the start, so the machine sells before power. `power_area` comes from the stock `get_area_for_power` (decompiled `2649.gsc`): the first `spawn_volume` for which `ispointinvolume(struct origin, volume)` is true.
- The nine `spawn_volume` entities are the same in both builds (names, origins, `info_volume`), and `ispointinvolume(origin, volume)` is true at the volume's own origin in both. Their EXTENTS are not: platform_a is 0 to 32 units wide in x in the reference build against 1920 in the full build (ticket_hall 96/224/96 against 768/672/160, and so on for all nine). The struct at (1100, 2370, -319) lies in no volume in the reference build. The stall of the rounds and the `r_blow_*.volume` rider results are the same fault: every zone logic of the stock zombies code reads these volumes.
- The asset table of the reference session holds, for each of clipmap, comworld, fxworld, gfxworld, glassworld and pathdata, TWO entries under the one name `maps/cp/cp_iwz.d3dbsp`: one of zone `cp_iwz` (the map's) and one of zone `cp_zmb` (the base's Spaceland world). The engine names the world assets of every level zone after the level; the base zone loads first, so its Spaceland copy answers the name and the map's copy is parked behind it (other-family path of the link step, not thrown away, so `FUN_140A77D20` never sees it and the content swap above could not reach it). The brush models of the volumes resolve against the Spaceland clipmap: other brushes, other extents. (`map_ents` and `navmesh` carry the level zone's own names, `maps/cp/cp_zmb.d3dbsp` and `maps/cp/cp_iwz.d3dbsp` separately, and are not doubled.)

**First fix (ce77b11, header-pointer swap in the link step) never fired**: no server log of the five runs holds `answers the name`. The live table read afterwards (`worldchain.py`, cell of a sz_ref run) says why: the two entries are NOT chained (`next=0` on both) and they carry the SAME header pointer: clipmap `0x145D5F980` for slot cp_zmb and for slot cp_iwz, gfxworld `0x14820FD90` for both. The world assets are not pooled copies; the engine keeps ONE global header per world type (the clipmap global is what `cm` reads) and every zone loaded as the level's base map writes its world into it and gets an entry named after the level (`maps/cp/cp_iwz.d3dbsp`, also for the base zone cp_zmb; its `map_ents` and `navmesh` keep `maps/cp/cp_zmb.d3dbsp`). Both zones were loaded with `is_base_map` true (the stub passes the level's flag to the base zones too), so the Spaceland world was written into the globals; the volumes' brush models read it.

**Fix.** The base zones are loaded as plain zones, not as the level's base map: in the fastfiles stub the base call passes `is_base_map && !paris_usermap_base::map_wins_enabled()` (dvar `paris_usermap_map_wins`, default 1; 0 = the old behaviour). The base zone then keeps its own world names (`maps/cp/cp_zmb.d3dbsp`) and never fills the level's globals; the map zone is the only base map. The swap of the listed data tables stays (the perk table etc.), the header-pointer promotion is removed. Risk to read in the first run: the engine may use the base-map flag of the first zone to unload the zones of the previous level or to start its level state; the old order (base queued first) is kept, so the map's call still comes last with the flag.
**Proof, in this order:** `r1_volext` on sz_ref: the nine extents equal the full build's (platform_a 1920/576/192); `r1_perkstate`: `s0_area` platform_a, `s0_on` 0; then `r1_five_ref` against 5/5. A crash at the next level or at the unload would be the pointer swap (the free path is the risk).

### F9, the entity shape list (26 Nov 2026; measured, built in source, not run)

**What the live tables say** (client b4d1e1b, `clipprobe.py`, `havokprobe.py`): the map's `map_ents` is the same in the reference and the full build (71,992 chars, 9 volumes `?146` to `?154`, 155 trigger models, 420 hulls; the nine trigger hulls hold the full build's sizes, 800x700x176 and so on); the clipmap global points at it (`clipMap+0x58`); the runtime trigger array has an entry for 146 to 154 in both. In the reference session a second `map_ents` of zone `cp_zmb` is loaded (449,830 chars, 146 triggers, 411 hulls). Both headers carry a Havok packfile (magic `57E0E057 10C0C010`) at `+0x158` with its size at `+0x150`: 671,472 bytes each. `ispointinvolume` ends in a physics point query (`FUN_14055A5B0` -> `FUN_14055A7A0` -> `FUN_1405509E0` -> `FUN_140580270`), so a volume is a shape of the Havok world, and `C:\studio\stock\README.md` "Where the game takes entity shapes from" (M5) already measured that this world takes the entity shape LIST from the base zone's copy: with a list that does not reach index 146 and up, the volumes 146 to 154 test as nothing. That is the cause of the perk power areas (`get_area_for_power` finds no volume), the rider volumes and the round stalls.

**Fix** (`paris_usermap_ncs.cpp`, hook on the level NCS pass `FUN_1406D43C0`, which runs at every level load after all zones are linked): walk the asset table for `map_ents` entries (type 27); the entry of the usermap's own zone supplies size (`+0x150`) and data pointer (`+0x158`); every other `map_ents` entry gets them written into its header. The consumer of the list was not found in the engine (the readers of `clipMap+0x58` are 120 functions, the Havok loaders are reached through tables), so the swap is made on the data both candidates read; whichever copy the engine takes, it gets the map's list. Before the map's zone is freed (`FUN_140A76280`, as for the other swaps) the base's own size and pointer go back, only when the header still holds the written values. Log: `[usermap map wins] map_ents of zone cp_zmb: the shape list (671472 bytes) of zone cp_iwz is used instead of its own` and `N of M map_ents shape lists put back`. Dvar `paris_usermap_map_wins` (default 1). The earlier stub change (base zones as plain zones, `is_base_map` false) moved nothing and is taken out again; the stub is the proven one.

**Risks:** if the physics world is built before the NCS pass the swap is late (the log line shows it was applied, the volumes still fail: then hook earlier, the zone load end); the list is read once, at world build, so a swap after it changes nothing.

**What the stock route can drop after this, if the volumes pass:** the `--full` builds for entity-shape edits: a stock map's room collision, resized or new shapes (M5 ways a and b; stock/README M12/M13 "collision_route", more than the ten stock clip brushes), and the cmodel index limit of 216 (a cmodel past the stock count hung the load because the base's shorter list was read). The Studio stock-map edits by reference then use the map's list. Not proven until `r1_volext` shows the nine extents of the full build.

### F9: the cause is proven, the fix writes the map's shape BYTES over the base's buffer (26 Nov 2026)

**Measured.** (1) Dumps of the three zones (ZoneTool v2): the reference zone's `maps/cp/cp_iwz.d3dbsp.ents.data.hkx` is byte-identical to the full zone's (md5 `09473a06...`, 671,472 bytes) and differs from Spaceland's by 1,558 bytes in 171 runs: the donor boxes that `iwzmap_volumes.cpp` rewrites for the nine volumes. So refbuild loses nothing. (2) At those offsets a loaded packfile equals its file (1,558 of 1,558, both zones), so the differing bytes can be written into a loaded buffer. (3) Forge `--patch` (`tools-source/usermap-proof/plans/patch_shapes.json`, 876 edits that each check the stock bytes first) writing the map's 1,558 bytes over the resident base's packfile of a `sz_ref` cell (`cp_zmb` list at `0x9F130DF90`, the address is the same at every boot of the same build) and then the plan's own map reload: `r1_volext` gives the FULL build's nine extents (platform_a 1920/576/192, ticket_hall 768/672/160, ...) and `r1_perkstate` gives `s0_area` platform_a / ticket_hall / generator_room with `powered_on` 0 for the machines that need power. Without the patch the same plans give the tiny extents and `s0_area` undefined. (4) The earlier hook that wrote the map's size and pointer into the base's `map_ents` HEADER ran before `Game Initialization` (log of the run) and changed nothing: the physics world is built from the base's buffer, not through those header fields.

**Fix** (`paris_usermap_ncs.cpp`, `ents_apply`, hook on the level NCS pass `FUN_1406D43C0`, which logs before `Game Initialization`): for each `map_ents` entry that is not the usermap's, when its shape list has the map's size, the bytes that differ are copied from the map's list into the base's buffer (offset, original and written byte are kept), and `ents_restore` writes the originals back when a zone of the usermap is on the list of the zone free (`FUN_140A76280`), only while the bytes still hold what was written. Log: `[usermap map wins] map_ents of zone cp_zmb: 1558 bytes of its shape list (671472) now those of zone cp_iwz` and `N of M map_ents shape lists put back`. Dvar `paris_usermap_map_wins` (default 1).

**Not proven by the experiment:** that the in-process write at the NCS pass is early enough (it logs before `Game Initialization`, the Forge patch was written before the reload, so the order is the same as far as the log tells); that a different size of the two lists never occurs (then nothing is copied and a warning is logged); the five plans.

### F9, the leak at the stock transition (26 Nov 2026, client 75fda5a, cell c72ab391a)

Plan `r1_to_stock` (the usermap, then `map cp_zmb` in the same cell): at the usermap both packfiles read `d6b9fbad...` (the base's buffer carries the map's bytes); at the switch the log shows `1 of 1 map_ents shape lists put back` and, right after it, `map_ents of zone cp_zmb: 15318 bytes of its shape list (671472) now those of zone cp_iwz` at the NCS pass of the STOCK level: the map's `map_ents` entry was still in the asset table, so the hook wrote the map's bytes into the stock level's own buffer. Fix: the write is armed by the load of the usermap's zone (`paris_usermap_base::ents_pending`, set by `load_before` when the `.base` was read) and disarmed by the first NCS pass; a `map` restart of the same zones does not load the zone, so the written bytes stay; a stock level never arms it. The restore still runs at every NCS pass and at the zone free, whatever the dvar says.
Note on the A/B: Forge applies `--dvar` after the cell booted, so a cell that booted with the dvar at 1 keeps the written bytes through the following map restarts (no zone load, no NCS pass); the batch of the 'off' runs was therefore not an off run. The on/off comparison needs the old client (a35c0d3) or a launch-time dvar (ledger: forge-no-launch-time-dvar).

### F9, the navigation world (26 Nov 2026; measured, built in source, not run)

**Measured** (client 75fda5a, `navworld.py`): the runtime navigation worlds are structures at `0x144E3C0A8` (stride 0x268, active index `0x144E4F4B4` = 0). World 0 keeps the data pointers of the navmeshes of the level at `+0x238` and `+0x240` and their count in the low dword at `+0x260`. Reference build: `+0x238` = `0x9E4006798` (the data of the base's `cp_zmb` navmesh, header `0x1438682A8`), `+0x240` = `0x9F3FFD370` (the map's, header `0x143868338`), count 2. Full build: both slots `0x9EC299D40` (the map's only mesh), count 1. The probe `r1_nav` (`getclosestpointonnavmesh` at the spawn points where the zombies stand): z 1.17 and 4.5 in the reference build, 0.0 in the full build; the map's navmesh is 2,226,834 bytes, the base's 653,342, so no byte copy is possible. Overwriting the base's header pointers (7 edits) or the world's first data pointer (`+0x238`, Forge `--patch`) changed nothing: the world is rebuilt at every game initialisation from its source list. The source list: `FUN_1405EAAD0(header)` (called from the per-type load hook `FUN_1403B7340`) appends every navmesh header whose name is not `maps/default.d3dbsp` to a list of at most four (`"loading too many navmeshes"`), in link order: the base zone's first.

**Fix** (`paris_usermap_ncs.cpp`, `navlist_stub`): while a usermap with a `.base` is being loaded (`paris_usermap_base::nav_pending`, set by `load_before` when the `.base` was read, cleared by the next top-level zone load that is not the usermap's and by the free of the usermap's zones) a navmesh header whose name is not `maps/cp/<usermap>.d3dbsp` (and not the default one) is not appended: the world is built from the map's navmesh only, as in a full build. A stock level loaded afterwards appends its own. Log: `[usermap map wins] navmesh maps/cp/cp_zmb.d3dbsp of a base zone is not handed to the navigation world (usermap cp_iwz)`. Dvar `paris_usermap_map_wins`. Risk: a resident base is linked once; on a reload the list holds only the map's already, nothing is skipped (the log shows no line then). If the world still shows count 2 in `navworld.py` the append is not the only source.
