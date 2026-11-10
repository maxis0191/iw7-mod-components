> History (dated 2026-10-15). Not current instructions. Current entry point: [docs/INDEX.md](../INDEX.md). Paths in the text are relative to the repository root as it was on that date.

# Source Author platform contact adapter

## Typed DisplayOnly phase

`Invoke-AuthorPlatformContact.ps1 -Phase DisplayOnly` is a Source-only addition
until a separate reviewed Runtime capsule receives explicit GO. `Contact` is
the case-sensitive default and retains the existing complete F0/F1/Use/F2 path.
The caller must select the SAME Phase for Plan and Run, seal the new operation
Source/fixture pins, and stage its generated config. Display config adds
`paris_author_platform_display_only=1` while `paris_collision_probe_arm=0`;
Contact config explicitly sets display_only=0. A phase mismatch cannot qualify
display readiness. Existing frozen packages are never edited or relabelled.

DisplayOnly stops at the already-existing protected retail readiness and SDK
visual creation. The fixture publishes fresh native-stamped P and the same
visual token/entity/instance, checks zero uses and both arm values at zero, and
never reaches contact audit, placement, native createbox, movement or Use.
The operation runs ONE existing native capture step, without an aim pulse or
any new input driver, then requires a subsequent fresh protected observation
of that same visual/P. The original frame remains the existing capture API's
unaltered BMP artifact with its recorded SHA256. Its freshness/dispatch and
normal input release are evidence of a captured frame, not visible pixels.

The returned schema is `iw7.author-platform-display/1`, with `Phase=DisplayOnly`,
`DisplayEpisodeExecuted=true`, `ContactNotRun=true`, `OriginalCapture` and
`Input`. It deliberately has no `MeasurementPassed` property. `PixelsVerified`,
rendered bounds, prediction, owner acceptance, lifecycle closure, lease release
and real original-host exit all remain false. Sidecar is
`author-platform-display-<token>.local.json`; the actual frozen anchor plan is
still `author-platform-anchor-<token>.local.json`, now with its explicit Phase.
Caller55 must accept this typed outcome and run its usual original close,
restoration, Main/bank audit and retained-handle/lease path. The fixture cannot
fall through to contact while it waits for that close; SDK still owns visual
teardown on disconnect/game_ended. Full Contact remains a separate later choice.

Compiled GAME provenance is source `785ddd43d18c4eebd599bab10880e83d73a950e9`,
EXE6153728/SHA012E6CDD... and manifest16536/SHA63E6270E..., with Source receipt
CE89219B.... These are the already-recorded identities in
`docs/evidence/2026-10-14-collision-player-native25.json`, not a new PE read or
build. Inspection of that exact compiled commit confirms protection/stamp,
ordinary native input and capture; retail script_model/precachemodel/setmodel
need no newly compiled observer or native handler. Later operation Source
`785e9832...` and current main helpers are distinct from the compiled GAME image.

Runtime SDK stays exactly `6dcfc719e0535509f109c593fa4342ce201b5523`. D6 StageSDK
`24edc27ff7f379613d51ae9d91b3f10054d67b6a` and ConsumerSDK
`62cf38834a0cbcd7243a3d52ce6100c1edbd9cdc` remain different roles/identities even
when GSC5404/SHA3B6F and geometry bytes match; both are explicit refusal cases.
D6 final publication failed and is known closed. Its FF1904/SHA6A4C9743... and
readback metadata are not reopened or adopted here. World owns exact geometry,
FF/readback and original-frame interpretation; no FF rebuild follows this edit.

Source tests cover the actual display branch with metadata-only doubles, fresh
visual/clock/phase guards, partial publications, forbidden contact/Use, capture
ordering/release and accurate provisional result fields. They create no BMP,
native process, lease, game or opaque artifact. GSC runtime linking/compilation
and pixels remain untested; this Source scope did not execute a PE parser.

This is a separate, project-specific derivative of the frozen a572 player
fixture. `collision_player_contact.gsc`, `Collision-Player.Core.ps1` and
`Invoke-CollisionPlayerContact.ps1` remain unchanged. No native ABI, process
launcher, lease controller, asset serializer or generic event bus is added.

The content owner is Creator SDK commit
`6dcfc719e0535509f109c593fa4342ce201b5523` (SDK PR27 merge). Its
`sdk/modding/examples/original-authoring/platform-contact/sdk_author_platform.gsc`
is 5404 bytes, SHA-256
`3B6F34FDF6F5176BECEFC5294B992E658751921F5B07931E28A31D05634EFD25`.
These are Source interface pins, not a runtime result. The operation receives
that separately sealed SDK Source product; the SDK implementation is not copied
into this product. The caller must verify the same script and the same reviewed
`mod.ff` in both roles before launching the dedicated/base client.

The original Native PR44 package admitted SDK commit
`662c548965e11c9c881abe7dc8d74042d9f1aec6`. The final merged SDK changed the
platform authoring JSON to diffuse texture slot 1; its GSC remains byte-identical
at the hash above, with the same four functions, Use state and placement. This
Source adoption changes only the exact SDK revision gate. It refuses both the
old SDK revision and the unmerged feature head even with identical GSC bytes.
Old Native/SDK packages and receipts remain immutable; the caller must use a new
Native Source package and the separately sealed merged SDK package. No C++, FF
or native binary rebuild is implied or performed.

## Fixed geometry and ownership

P is the actual protected stock-spawn pose, frozen only after retail intro,
weapon, control and grounded readiness. Coordinates supplied to Plan are preview
only and cannot enter Run. World owns the independently reviewed geometry and
authoring transform contract; this adapter consumes its fixed platform case:

| Quantity | Game coordinates |
| --- | --- |
| Authored model local bounds | (-128,-128,0) to (128,128,16) |
| Visual origin | P + (0,0,96) |
| Visual angles / scale | (0,0,0) / 1 |
| Native absolute AABB | P + (-128,-128,96) to P + (128,128,112) |
| Native center / half extent | P + (0,0,104) / (128,128,8) |
| Player placement | P + (0,0,208) |

SDK creates one `notsolid` script_model, `sdk_author_platform_model`. The fixture
creates a separate solid physics owner and calls the existing `collision_createbox`
with absolute world bounds. It does not transform those bounds again or apply the
native provider's internal 1/32 scale. Visual/entity transform observations do
not establish actual renderer bounds, pixels or absence of asset collision.

The same SDK record, token, entity and instance must survive prepared, F0, F1,
F2 and after-fall snapshots. F0 is a fall while the visual is present and the
native box absent. F1 lands on the box, stands for 600 ms, then uses ordinary
forward input for 300 ms and observes bounded movement plus released stability.
Only then does the fixture call SDK `arm_use`. The adapter observes one real
`usebuttonpressed()` rising edge. SDK alone waits on its entity's retail
`trigger` and increments `uses` from 0 to 1. No notification, count increment or
synthetic trigger is emitted by the fixture.

The fixture requires the same SDK player/token/entity and a trigger timestamp
inside the observed Use interval before removing the native box. A 100 ms upper
edge tolerance allows the trigger thread and 50 ms fixture poll to run in either
order; an old, early, repeated or foreign trigger fails. SDK range is 160 game
units and FOV is 360. If retail Use does not trigger, the operation fails rather
than fabricating success or expanding the bounds/range.

F2 removes the native body with its owner alive, observes the ordinary fall and
lower landing, deletes the physics owner, takes the final same-visual snapshot,
then calls SDK teardown. Failure attempts to clear only the owned native body
and asks SDK to tear down its own visual. SDK ownership/restoration ambiguity is
reported as failure; original caller cleanup remains mandatory.

## Caller interface

`ops/Invoke-AuthorPlatformContact.ps1` defaults to pure Plan. It requires the
exclusive private Author caller, `fs_game=mods/sdk_author_platform`, SDK enable
and Author/contact flags, cp_zmb, one client, loopback 27116, password/LAN-only,
fresh engine protection, inactivity=0 and sv_cheats=0. Native image ownership
continues to use the reviewed 785/012E cohort through the unchanged a572 guard.
There is no hybrid Rig+collision session or reinterpretation of a frozen E asset.

Run parameters are `Token`, `HelperRoot`, `HelperReceiptSHA256`,
`SourceReceiptSHA256`, `SDKSourceRoot`, `SDKSourceReceiptSHA256`, and the retained
actual `Session`, `ServerHandle`, `ServerIdentity`; `Capture` is optional.
`Phase` defaults to `Contact`; DisplayOnly always takes its single capture,
independently of the optional Contact `Capture` switch.
The operation retains no replacement lifecycle object. The original caller owns
prestart FF/script staging, the original lease and handles, valid zero-client
shutdown, restoration, bank/Main comparison and observation of real host exit.

Result schema is `iw7.author-platform-measurement/1`. `Measurements.Physics`
uses the unchanged a572 reader, then the narrow Author reader requires the
same visual identity, ordered snapshots, armed/released interval, observed Use
edge, SDK retail trigger, exact acknowledgement and final visual removal.
`LifecycleClosed`, `LeaseReleased` and `OriginalHostExitObserved` remain false
until separately established by the caller. The result never claims renderer,
render/bounds, client prediction or owner acceptance.

## Source checks and next action

The Source tests cover pending/preview plans, three unowned/preview Run
refusals with zero live effects, eleven SDK contract refusals including old and
unmerged revisions, the frozen physics transcript's 22 causal refusals, and
Author lifecycle/identity/transform/count/time/order mutations. The optional
positive SDK test reads the actual separately sealed merge receipt and GSC,
using `SDKSourceRoot` and `SDKSourceReceiptSHA256`; synthetic receipt metadata
is used only by the pure refusal cases.
Pinned gsc-tool parsing checks grammar only; engine compilation is untested.

No Author fastfile, native build, visual runtime, actual Use trigger, player
contact, prediction or owner gameplay has been qualified by this change.
Next: finish SDK/World/caller Source review and exact pins, then prepare a new
explicitly authorized capsule. Do not replay or edit frozen a572/E inputs.
