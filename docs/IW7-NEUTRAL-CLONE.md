# Explicit IW7 neutral clone Source profile

2026-10-15: implementation and owned synthetic Source tests only. No captured
definition body was reopened; no lease, generated source package, native build,
FF, registration, game or Main change occurred. The asset owner's distinct T2
capture (x64-zt-extensions PR212) observed full Shredder/PAP definitions with
integer base1/PAP0 unchanged. That observation does not qualify a clone,
projectile eligibility, parser roundtrip, runtime ABI or gameplay.

`ops/raygun/prepare_iw7_clone.py` adds only the explicit
`iw7-shredder-neutral-1-0` profile. The existing `prepare_weapon.py` PROJECTILE3/3
author and report remain unchanged and still refuse1/0. This Source route is
useful for IW7 clone/serializer validation independently of BO3 visuals; it is
not a projectile conversion or a playable Ray Gun.

## Fixed input and changes

Only `iw7_shredder_zm` / `shredderpap1`, exact integer1/0, true PAP boolean,
nested WeaponDef/unk0, all six original attachment slots and exactly one PAP
occurrence are accepted. Arrays/nulls and other entries remain intact. Both
turret string arrays must retain the captured four-empty-string shape; matrix
or nonempty shapes refuse. No enum/default or serializer-macro repair occurs.

Default private names are `sdk_shredder_clone_zm` and
`sdk_shredder_clone_pap_zm`; the ordinary definition variant joins them with `+`.
The pure function also accepts two other distinct validated `sdk_` names. Deep
copy preserves all supplied unknown fields, display names, mechanics and asset
references. Only internal identities, the one original PAP slot,
`notetrackOverrides.attachment`, and
`weapDef.{animOverrides,sfxOverrides,vfxOverrides}.{attachment1,attachment2}`
change. Equal strings elsewhere stay unchanged. Preservation does not establish
that a native parser consumes every supplied field.

The file operator validates a hash-pinned closed neutral manifest (16KiB cap)
before opening either definition. It checks exact donor/native-source/names,
observed integers, bounded readset, unique paths and honest qualification flags.
Each body is read with a2MiB+1 bound and must match its exact manifest size/hash.
Duplicate keys, invalid UTF-8, nonfinite/overflow numbers and redirected ancestry
refuse; integer tokens stay exact. The external manifest/hash is a local binding,
not tamper-proof provenance or BO3 authentication. Diagnostics are not templates.

Before creating a fresh absolute output directory, all four files are encoded
and bounded. Defaults are:

- `weapons/sdk_shredder_clone_zm.json`;
- `attachments/sdk_shredder_clone_pap_zm.json`;
- `zone_source/sdk_shredder_clone_zm.csv`, ordinary weapon/attachment roots;
- `neutral-clone.json`, binding input hashes and the three generated Source
  files by exact path/size/SHA256.

Files use CreateNew, flush and bounded same-stream readback. An error can leave
the new partial output retained; it is never silently reused or removed.
Definitions have2MiB caps and the report64KiB. All native-parser/FF/roundtrip/
ABI/lifetime/grant/damage/physics/PAP/game/Ready flags remain false; the old
projectile report is not reused. Game-derived inputs/outputs stay private and
ignored. This operator acquires no lease or original-context lifetime guard;
actual captured inputs still require the separately reviewed admitted caller.

## Exact Source audit and functional gap

Recipient Source `fab935826c898806855376662a8a03317b3ad8f1`,
`src/zonetool/zonetool/iw7/structs.hpp:6344`, declares0 NONE,1 BULLET,3 PROJECTILE;
both native weapon-type fields use weapType_t. This Source map does not prove
the actual engine ABI, lifetime or firing behavior.

The retained retail GSC Source pin is
`1dd48a78e55ef9c99519fc5221a206168ce2e98a`. Paths below are relative to
`decompiled/`; only references/conclusions, no game script body, are copied here.

| Source | Consequence for the private name |
| --- | --- |
| `scripts/cp/zombies/zombies_weapons.gsc:108-115` | Literal retail Shredder base/PAP cases dispatch special lethal nonmelee processing to shredder_death_logic. JSON renaming supplies no new case. |
| `scripts/cp/utility.gsc:781-790` | getrawbaseweaponname strips iw5/iw6/iw7 or alt prefixes; the sdk name remains its own raw family. |
| `scripts/cp/cp_weapon.gsc:3816-3834` | Attachment availability consults getbaseweaponname and level.attachmentmap_basetounique; native renaming supplies no table entry. |
| `scripts/cp/cp_weapon.gsc:4862-4886` | Upgrade availability requires level.pap/family registration or the existing max-PAP callback. |
| `scripts/cp/cp_weapon.gsc:4895-4913` | Retail wonder-weapon fuse/Director's Cut gates remain separate and must be preserved. |

Thus identical JSON mechanics fields do not imply inherited name-specific
Shredder damage/death logic. No callbacks, stock aliases, PAP dictionaries,
fuse/EE/DC states or server gameplay are changed. Any scoped family binding
requires its own product owner and actual behavior evidence. SDK PAP registration
can supply a later seam; init/dvar alone installs nothing and cannot repair the
separate death logic. Its custom-weapon/1 capability/dependency tuple is unchanged.

## Native parser/write/dump gate

At the same native pin, `src/zonetool/zonetool/iw7/assets/weapondef.cpp` has
parse_complete at1053 and parse at1141; weaponattachment.cpp parse is at675.
Complete weapon/nested-definition and attachment JSON, normal CSV roots,
load_depending/write, then public weapon_def::dump and weapon_attachment::dump
are the intended route. Model roundtrips and the H1 animation bridge are not
weapon roundtrip proof.

Weapon STRING_ARR parser macro38 accepts four string/null cells; dumper macro1760
can emit a repeated4x4 array for nonnull pointers. The fixed empty shape avoids
this specific mismatch, without proving full roundtrip. Script-string names,
inline21 overrides, Material*[16], curves/notetracks and attachment subblocks
still need typed comparison and nondefault dependency resolution. Raw pointer/
ID equality does not prove semantics or lifetime. Retain bounded immutable
input guards through native parser/write/dump: its filesize reads alone supply
no byte bound. Compare complete scalars/names/nulls/counts/arrays/overrides and
explicit observed normalizations; refuse unexplained loss. No native argv or
runtime capsule is authored here.

## Validation and next gate

Twelve owned synthetic tests cover narrow rewrites/full-tree preservation, all
six PAP slots, old-author refusal, strict integers/names, ambiguous/malformed
references, inheritance/diagnostic/nonfinite/matrix refusals, manifest policy
before body opens, exact bindings, growth/hash-before-decode, actual four-file
Source output/readback/hashes and before-output refusal. Existing eleven
PROJECTILE3/3 tests pass unchanged. These fixtures do not qualify T2 consumption,
a native parser, firing or a playable Ray Gun.

Next: independent Source review, then a distinct original-context Analysis
packet/GO before any stat/read/hash of the actual T2 triplet. That packet must
declare exact inputs, admission, guards, output/time bounds, unknown retention
and closure. No runnable T2 packet or actual clone was prepared. Native/FF
roundtrip and protected gameplay require separate exact review/GO. Preserve
Main/banks/melee/offhands and occupied clients; use the base client and a suitable
separate dedicated, fresh godmode/inactivity0 and sv_cheats0. Prove selection,
ammo/reload, actual firing/damage and lifetime. Real PAP payment/pickup/tier/ammo
is a separate machine transaction; a direct upgraded grant is insufficient.
BO3 models/clips/FX/audio remain separate owner inputs and do not block the
neutral IW7 clone proof.
