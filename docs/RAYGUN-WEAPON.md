# Private Ray Gun weapon authoring

2026-10-14: functional source authoring, not a built or played Ray Gun.

The minimum IW7 route is its registered `WeaponCompleteDef` with nested
`WeaponDef`, its ordinary player inventory/weapon code, and a real PAP
`WeaponAttachment`. No new native hook or live definition clone is needed for
this source tranche. The pinned IW7 ZoneTool parser reads a **complete**
`weapons/<name>.json`; it allocates a definition and parses every field. It has
no `baseAsset` inheritance. Its attachment parser reads
`attachments/<name>.json`, including `papAttachment`, projectile, ammunition and
damage fields. The normal asset dependency/writer path supplies both assets.

`ops/raygun/prepare_weapon.py` emits those two actual JSON inputs and a zone CSV.
It takes hash-pinned, complete IW7 source templates: a player primary projectile
weapon and an existing projectile PAP attachment already listed by that weapon.
It clones the entire JSON trees, preserves unknown fields and mechanics, changes
the private asset identities, and replaces that PAP reference in its original
attachment slot and parser-recognized `notetrackOverrides.attachment` and
`weapDef.{animOverrides,sfxOverrides,vfxOverrides}.{attachment1,attachment2}`.
Other equal strings, including unknown data/ammunition names, remain unchanged.
It does not guess another slot,
append a foreign attachment or author a sparse definition with invented defaults.
The proposed private identities are `sdk_raygun_zm` and `sdk_raygun_pap_zm`; the
normal engine variant is `sdk_raygun_zm+sdk_raygun_pap_zm`. These names do not
claim to be BO3 retail identities.

The first template must contain a clip, reserve ammunition, ammunition per shot,
damage, positive projectile speed/lifetime, FP/TP models and a weapon animation
package. Non-player/model-only/hitscan definitions are refused. The existing
`paris_doom.cpp` use of `iw7_zapper_grey` establishes a projectile source path;
it does not establish a reloadable player template. No qualified player weapon
JSON has yet been supplied to this new operator. Synthetic test inputs are not
retail templates and must never be packaged as the real candidate.

Without visual overrides, emitted definitions retain the IW7 template visuals
and are explicitly labelled **IW7 prototype**. When the asset owners provide
converted FP model, TP model and full weapon animation-package references, pass
all three together. The operator sets the corresponding FP/default-view,
TP/default-world/shadow and animation-package fields. Dual/complex visual
templates are refused by this small mapping; they need an explicit extension.
The operator emits no model, animation, texture, FX or sound asset. It never
marks supplied references as authenticated BO3 assets. The animation owner must
preserve the actual 260-slot IW7 package/timers/notifies and qualify the mapped
idle/fire/reload/raise/drop/ADS roles, rather than emit a short invented package.
Existing FX/sound/projectile references remain from the templates until their
owners supply observed converted assets.

## Source operation

Use a fresh absolute ignored output directory and the SHA-256 of each complete
source JSON. For example, with independently prepared template paths:

```powershell
python -B ops/raygun/prepare_weapon.py `
  --weapon-json <player-projectile-template.json> --weapon-sha256 <64-hex> `
  --pap-json <that-weapons-pap-attachment.json> --pap-sha256 <64-hex> `
  --output <fresh-absolute-source-directory>
```

Optional arguments are `--view-model`, `--world-model` and
`--animation-package`, supplied as one complete reference group. The output is:

- `weapons/sdk_raygun_zm.json`: full native weapon source.
- `attachments/sdk_raygun_pap_zm.json`: full native PAP attachment source.
- `zone_source/sdk_raygun.csv`: normal `weapon` and `attachment` roots.
- `raygun-authoring.json`: identities, inherited/adapted status and validation limits.

This operation reads bounded source JSON and writes source only. It does not
parse/link a fastfile, preload a retail zone, launch a compiler/game, stage a
player installation, acquire a lease or change Main. Templates and generated
definitions contain private game-derived data and stay ignored; only this
operator, synthetic tests and documentation belong in Git.

## Runtime completion

Packaging/loading, registration and actual player behavior remain required.
Use the existing IW7 `giveweapon`/`switchtoweapon` path for the initial protected
mechanics fixture, preserving melee/offhands. An asset name or successful
dispatch is not proof of a grant. Measure selected weapon, FP/TP presentation,
clip decrement, reserve/reload behavior, actual projectile travel/impact,
direct/splash damage, FX/audio, death/rejoin and zone lifetime.

The prepared attachment/engine variant does **not** register the private base
with the retail Zombies PAP machine. The caller/server owner must inspect the
exact retail `cp_weapon::return_weapon_name_with_like_attachments` and upgrade
callback/table path, map the private attachment through that normal mechanism,
then test a real machine purchase, payment, inventory/tier change and ammunition
preservation. Giving the variant directly can test the definition, but cannot
qualify a PAP transaction. Do not fabricate an EE/fuse/DC state or unlock cheats.

Every real build/FF/game phase needs its distinct reviewed capsule and Root slot,
fresh engine godmode/inactivity protection, cheats=0 and existing bank/Main
isolation/restoration. F53/G53 work owned elsewhere is not authorization for
concurrent native/asset/game work here. No runtime or owner acceptance follows
from the authoring tests.

Primary source references (pinned, not an upstream update request):

- IW7-Mod `77e6d4d24e918ee363b3feee3735c3b889dff7d7`: `game/types/database.hpp`
  (`WeaponCompleteDef`, `WeaponDef`, `WeaponAttachment`), `component/command.cpp`
  (`cmd_give` ordinary script calls), and `component/gsc/script_error.cpp`
  (private attachment-name handling).
- x64-zt `fab935826c898806855376662a8a03317b3ad8f1`: IW7
  `assets/weapondef.cpp:1053`/`:1141` and `assets/weaponattachment.cpp:675`.

Local validation: eleven synthetic authoring tests cover full-field/mechanics
preservation, correct PAP slot/ref rewriting and engine variant, actual source
file output, complete visual mapping, unsupported definitions/slots/paths and
changed hashes and capped growth before hash/decode. They do not run a native
serializer or qualify an engine asset. Independent review rejected source head
`6abbaa8` for an unbounded read after its size check and a global string rewrite;
both approaches remain in history. The corrected reader reads at most cap+1
bytes and refuses growth before hash/decode, while attachment renaming is
restricted to the recognized paths above. No rejected candidate was built or
run in game.

The separate x64 pair-classification diagnostic uses schema
`iw7.player-pair-profile/1`, not complete weapon/attachment templates. This author
rejects it explicitly in either input even if positive full-template fields are
forged around the schema. The existing valid PROJECTILE3/3 validation, deep copy,
mechanics preservation and serialized output behavior are unchanged. No enum1
acceptance or conversion is introduced. The extra synthetic rejection test is
Source-only; it does not qualify a retail pair or new native profile execution.

The later explicit neutral IW7 clone profile is documented in
[IW7-NEUTRAL-CLONE.md](archive/IW7-NEUTRAL-CLONE.md). It preserves the observed Shredder
base1/PAP0 trees for a separate clone/roundtrip path; this PROJECTILE3/3 author
remains unchanged. Neither Source implementation qualifies a playable Ray Gun,
name-specific Shredder callbacks, a native roundtrip or retail PAP purchase.

The subsequent U1d invocation consumed the exact captured triplet under its own
Analysis lease and independently verified the complete private clone Source
pair/CSV/report, with ordinary original-context closure. Its observed PAP slot
is attachments6 and types remain1/0. This separate Source-cloning result changes
none of the native/gameplay limits above; see the actual checkpoint in that doc.
