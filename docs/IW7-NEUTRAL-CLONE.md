# Explicit IW7 neutral clone Source profile

2026-10-15 current checkpoint: U1d consumed the captured T2 triplet under its own
Analysis admission and verified a complete private clone Source pair, CSV and
manifest with ordinary closure. Integer base1/PAP0 and the observed attachments6
PAP slot remain unchanged. This qualifies Source cloning only; native parsing,
FF/roundtrip, runtime ABI/lifetime, registration, firing/physics, PAP transactions
and gameplay remain unqualified. No native build, FF, game or Main change ran.
The earlier PR60 implementation/synthetic-test checkpoint opened no captured
body or lease; the later U1d result below is separate evidence. T2's original
neutral capture is recorded in x64-zt-extensions PR212.

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
refuse. Trees retain the neutral reader's 32,768-node/8,192-element/64-depth
bounds and consistent positive readset counters; integer tokens stay exact.
The external manifest/hash is a local binding,
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

Fourteen owned synthetic tests cover narrow rewrites/full-tree preservation, all
six PAP slots, old-author refusal, strict integers/names, ambiguous/malformed
references, inheritance/diagnostic/nonfinite/matrix refusals, manifest policy
before body opens, exact bindings, growth/hash-before-decode, actual four-file
Source output/readback/hashes and before-output refusal. Existing eleven
PROJECTILE3/3 tests pass unchanged. These fixtures do not qualify T2 consumption,
a native parser, firing or a playable Ray Gun.

That Source checkpoint was followed by a separately reviewed/admitted actual
U1d operation below. Next: a bounded Source proposal using the existing IW7
writer/parser/dependency/dump path, then its own exact review/admission/GO before
opening the clone bodies or running native/FF work. Protected gameplay also
requires separate exact review/GO. Preserve
Main/banks/melee/offhands and occupied clients; use the base client and a suitable
separate dedicated, fresh godmode/inactivity0 and sv_cheats0. Prove selection,
ammo/reload, actual firing/damage and lifetime. Real PAP payment/pickup/tier/ammo
is a separate machine transaction; a direct upgraded grant is insufficient.
BO3 models/clips/FX/audio remain separate owner inputs and do not block the
neutral IW7 clone proof.

## Actual U1d clone Source and closure, 2026-10-15

Root's distinct Analysis GO approved one physical bundled NoExit/dot invocation,
using PR60 merge `5fbc198395fe67da75c8e927dbcf587cfbab72ae`. Entry35,431 bytes /
SHA256 `7a19c7847feb4fe24e9c9600b22f96d1f2e4513f8acf6e38cb6787c4bda10643`
and plan7,702 bytes /
`ad025b13edeeb99ee4546ed00427b4c3c315ceb2f81c6b45203b502f89efaf88`
were frozen. Fourteen actual Source causals had exercised the plan/15 held
Source guards, BOM/parser composition, strict comparison/report/stdout, actual
creator retention, ordinary closure and unknown finalization retention without
invoking the entry body, providers, private native types, a lease or T2 bodies.

The operation held the exact original T2 manifest/base/PAP files under its new
lease, verified their hashes and existing independent closed readers, then ran
one Python -B -S through unchanged H1/OriginalArena with its clean environment.
The existing interpreter was freshly bound from its actual original read guard
under admission; no historical Python hash was invented or substituted. Two
exact merged Python sources were copied into an owned fresh script directory,
with immediate returned-stream enrollment and individual creator-handle proof.
The old PROJECTILE3/3 author stays unchanged and still refuses1/0.

Python exited0 in252.689ms. It produced exactly four Source artifacts:

| Artifact | Bytes | SHA256 |
| --- | ---: | --- |
| weapons/sdk_shredder_clone_zm.json | 37,896 | `e343565c10030ecaa93f323be669dc1caf4284f8ec97ca82d33a62debc823055` |
| attachments/sdk_shredder_clone_pap_zm.json | 3,860 | `23f2f7a5870c5464dc91f5ccf1f0f75cba67e64b649b6f0225abaaa7df3998e4` |
| zone_source/sdk_shredder_clone_zm.csv | 66 | `f539cb31e182b7648cac4eb4da369e344d0a8da1a877c4fbed1dc23ef105f2c8` |
| neutral-clone.json | 2,027 | `62e0b56c47a632b6325a2023a7aa9c345a56b251346a41d7320931aae5930cbe` |

Parent readback independently compared complete JSON trees, allowing only the
two private identities and known references to the one original PAP. Unknown
fields, array/null shapes, integer values/classes and finite floating values were
preserved. The observed PAP occurrence is in attachments6;1/0 was not coerced.
CSV roots, closed typed report, source/generated hashes, false qualification
flags and closed Source-only stdout all matched. The smaller output byte counts
are JSON serialization differences; no supplied JSON field omission was accepted.

CIM registration recorded an original identity-observation error. Existing H1's
catch verified its actual original job was already empty and recorded that
explicit outcome; the RegistrationError is preserved rather than represented
as successful registration. Actual original root0, Active0 and exit0 were still
required before job closure. No cause of the CIM error or PID reconstruction is
inferred from the short duration.

Source artifacts total43,849 bytes. Two code copies plus stdout bring generated
files to69,316 bytes; the three lifecycle receipts add13,009, for82,325 bytes.
The fixed group180/phase60 seconds and16MiB+1MiB policy were unchanged. No retry,
clock reset, stock alias, native CLI, CPP, FF, game or dependency package ran.
The exact whole-phase duration was not retained; the tool duration above and
same-original preexit88,454ms are separate measured observations.

Ordinary finalization held all actual15 Source,16 file and three publication
handles through prebounded receipts and final same-stream readback. The final
disk receipt truthfully remains ReleasedOriginalGuardsHeldPendingReadback with
GuardsDisposed false/CanExit false. The later same-context preexit verified all
34 original handles closed, both individually retained creator SafeFileHandles
closed/Verified and both raw creator streams unreadable/unwritable. Each raw
stream was the same object as its creator record. Global/script/AppDomain/root,
context/state/plan and every guard/creator list were directly reference-checked.
The original NativeJob was retained Closed=true, context closed, lease null,
both readbacks/disposal true and original group clock unchanged; the last
deadline check occurred before disposal/CanExit. Explicit inline exit completed
the actual terminal with exit0. Fresh19:37:30 UTC postflight found original
host/parent/Python identities absent and no games/CPP/VCTIP or resource leases.
Root independently read/hash-checked the five receipts, corroborated fresh
absence at19:39:06 UTC and released its heavy ledger.

| Source receipt | Bytes | SHA256 |
| --- | ---: | --- |
| measured-before-release.json | 12,133 | `ea90ce1997b3576210fd5e9249ae76ee6aa3aab90e6e1f7dd878a94a8ea24993` |
| closure-before-release.json | 346 | `7605dfc724992cc32b82be796fe20568c0eb92d1de9282c2096d345934b21d69` |
| final-closure.json | 530 | `beef28c92cb64768a8c386b1a3b3579b5d215087509035984edea528bea1c338` |
| preexit-original-context.local.json | 2,269 | `e2fbcda7b5436f8f8146211717f25e83f2e61fdb93aac4aac1924be59e450cf1` |
| postexit-absence.local.json | 377 | `e04df6370a61c677e87e2f2f5fca0c4cc0f2bfc0cc0431c4665d04534451d304` |

The immutable pre-Root actual handoff is10,834 bytes / SHA256
`c2d70f2104460fb278bf0a872935a57b46ced8c90a57842a2350442fbb7b9287`.
Root qualification is additive (1,122 bytes / SHA256
`c6226a48a26727d3d6ea7c8b58f63138869e87526b78cbb46aaf559d328f8886`);
original pending flags remain intact. The
publisher read only Source receipts and copied metadata after release, never
T2/clone bodies or runtime PE/DLL. This is ActualCloneSourcePASSKnownClosed only.
Native parser/FF/roundtrip, ABI/lifetime, registered grant, renderer, damage/
physics, real PAP transactions and gameplay all remain false. Private names
still do not inherit name-specific Shredder GSC mechanics.
