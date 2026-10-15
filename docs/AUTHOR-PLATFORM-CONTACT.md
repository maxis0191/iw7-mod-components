# Source Author platform contact adapter

This is a separate, project-specific derivative of the frozen a572 player
fixture. `collision_player_contact.gsc`, `Collision-Player.Core.ps1` and
`Invoke-CollisionPlayerContact.ps1` remain unchanged. No native ABI, process
launcher, lease controller, asset serializer or generic event bus is added.

The content owner is Creator SDK commit
`662c548965e11c9c881abe7dc8d74042d9f1aec6`. Its
`sdk/modding/examples/original-authoring/platform-contact/sdk_author_platform.gsc`
is 5404 bytes, SHA-256
`3B6F34FDF6F5176BECEFC5294B992E658751921F5B07931E28A31D05634EFD25`.
These are Source interface pins, not a runtime result. The operation receives
that separately sealed SDK Source product; the SDK implementation is not copied
into this product. The caller must verify the same script and the same reviewed
`mod.ff` in both roles before launching the dedicated/base client.

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

The two Source tests cover pending/preview plans, three unowned/preview Run
refusals with zero live effects, the frozen physics transcript's 22 causal
refusals, and Author lifecycle/identity/transform/count/time/order mutations.
Pinned gsc-tool parsing checks grammar only; engine compilation is untested.

No Author fastfile, native build, visual runtime, actual Use trigger, player
contact, prediction or owner gameplay has been qualified by this change.
Next: finish SDK/World/caller Source review and exact pins, then prepare a new
explicitly authorized capsule. Do not replay or edit frozen a572/E inputs.
