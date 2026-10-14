# Agent capabilities and the next engine investigation

## Renderer scene table observer — source candidate, 2026-10-14

`RigSceneProbe=true` adds `-paris-rig-scene-probe` only with the explicit
OriginalRigConsole/RigAssetsProbe plan. The manifest capability is
`RigSceneProbeCapability`; a historical missing field means unavailable.
This candidate has not been compiled or run. The executable described below
does not contain it. Normal/native source counts remain 34/36.

The original asset observation remains after ARM. The new observer instead uses
the existing main-thread `capture` action after an accepted active ARM, once per
that ARM and current nonce/generation/challenge. A neutral capture before ARM
cannot consume this slot. The consumer must wait for its real server creation
marker before capture; native code does not prove that marker or a server tick.
No new command, component, hook or model name argument is introduced.

Main requires the exact rig fs_game, Spaceland and current independent engine
protection aged at most 250 ms, then resolves the two fixed, exact-name,
nondefault XModel references. One existing scheduler::renderer callback copies
the pinned `GfxScene::sceneModel` table: at most 1024 model pointers, 16 KiB
total reads and eight matching POD records. Every copy checks a mutex-protected
main permit bound to process, request and ARM, its one-second deadline and the
cached protection deadline. Renderer calls no DB, dvar, game-mode or protection
API. VirtualQuery plus leaf SEH only bounds memory access; it does not pin an
engine allocation. Process-lifetime request storage avoids a freed callback
target, and teardown cancels without engine access or logging.
Its atomic shutdown latch also refuses subsequent observer work and every
renderer copy; the request storage is never deleted while callbacks may exist.

Main refreshes the permit only while the same binding/ARM remains protected,
then revalidates before publishing. Expiry, cancellation, refused counts,
reference/read failure and unreadable data produce `NoSceneObservation`.
Successful data is explicitly `SceneModelTableObserved`: raw entnum12,
renderFlags14, typed draw-info fields, DObj pointer presence and placement
quat/origin/scale/radius. Output contains no addresses, process/player identity
or nonce. Requested/sample-start/sample-end/published local ticks permit later
sequence checks. Consumers must compare creation against sample start; a later
sample-end timestamp alone cannot prove every read followed creation.

Zero matches means only `not_observed_in_this_scene_model_table`. The separate
opaque sceneDObj table is not inspected. Count stability is not an atomic
snapshot; entnum is not a qualified server entity ID; DObj presence does not
qualify its models/bones, culling, GPU resources, draw submission or pixels.
These states remain unmeasured. Root approved the separate explicit
`RigSceneStockWitness` plan switch, `-paris-rig-scene-stock-witness` flag and
`RigSceneStockWitnessCapability` boolean. They require the scene profile above
and add only the exact nondefault `zmb_coin_alien` reference, never an arbitrary
name. The default filter still contains only the two custom pointers. Witness
records are labeled separately within the same eight-record/16 KiB bounds.
An aliased or unqualified reference refuses observation. The witness model is
not part of any older runtime receipt. This source option does not establish
same-run server creation, placement or visible pixels; the independent SDK/
consumer variant supplies those later checks.

The argument-only suite passes 28 absent/false/strict-boolean/dependency checks.
Twelve source/serialized-log checks pass, including the renderer/main API
boundary, privacy and truthful unknown states. Two old checks were scoped to
their original provenance observer after new profiles made their global string
counts and first-try search stale; the original formats remain covered.
The existing C++ fixture now prepares stale request/ARM/process/binding,
cancel/expiry/count/filter cases; it has not been compiled for this candidate.
Source review and an independently admitted CPP/full build precede any runtime
qualification. Main27016, immutable native958, the prior compiled4377 image,
SDK49f/FF and banks remain outside this source-only work.

## Original rig typed asset snapshot — compiled candidate, 2026-10-14

The existing client observer runs on accepted native agent arm, after the
consumer's scene-ready check and neutral capture. Its second closed profile
requires `-paris-rig-assets-probe`, exact `fs_game=mods/sdk_original_rig_probe`,
active Spaceland CP state and the fresh independent client-protection value
matching the current nonce, server generation and connection challenge. The
old `mods/paris_model_probe` profile keeps its existing behavior. Dedicated
observation is excluded; no ninth console command or new component is added.

The observer looks up exactly the two `paris_doom_skin_two_bone_*_a` models and
`mopw/character_park_clown_zombie_shoes`. Pinned upstream `77e6d4d` declares
`DB_FindXAssetHeader` at `0x140A76E00` and `DB_IsXAssetDefault` at `0x140A780D0`.
Default status is unknown unless the latter returns normally. The typed model,
LOD0, first surface and first material handle are copied within checked memory
regions; leaf SEH catches access/in-page faults without swallowing unrelated
engine failures. Counts, raw documented flags, first-material name/pointer
equality and typed buffer/view presence are observed. No unknown flag is
interpreted, no COM/GPU/technique object is followed, and the rig records emit
no raw addresses, PIDs, nonces or player identifiers. Copies are not atomic;
pointer presence proves neither resource validity, DObj binding nor drawing.

`New-IW7BaseClientPlan -OriginalRigConsole -RigAssetsProbe` enables the client
flag only through the explicit rig plan. The new manifest capability is
`RigAssetsProbeCapability`, a boolean true only for IsolatedLab+ServerModules
builds at the existing pin. Historical absence means unavailable. Native source
inventory is unchanged: 34 normal isolated sources, or 36 when the separately
declared `CollisionProvider=true` adds its two files. Consumers must verify the
complete actual manifest, source revision and image rather than force a count.
The frozen native958 source/manifest, FF and SDK are unchanged.

Nine actual PowerShell argument checks pass without any process or compiler.
Nineteen new pure C++ profile/default-result/LOD-span/copy-bound checks compile
and run in the existing required fixture, alongside the existing 200,000-packet
seeded protocol checks. The full Release image also compiles the actual typed
observer and links successfully. Source head
`4377a5b7831520478d7a2a3af819feaaf87dac89` is clean; its unchanged 313-file,
2,901,583-byte input package verifies after building against `77e6d4d`.

The 6,125,056-byte executable SHA-256 is
`1B15AE7EB96DAF6FA494B80E5E0E2C08551E80D131757DEB11F674C781BE6A6D`;
matching PDB SHA-256 is
`F66DC4DAFA85E356DD89E35DDA585B019DD8E65BF00FA31C8051542D4B54D84B`.
The unchanged 16,457-byte manifest SHA-256, read after closure, is
`F6AC4BBDF3961F60E8F42899C7FF32F37051CE4A3909FB13D38369396671D5C3`.
The builder recorded executable/PDB hashes during its build lease. The manifest
declares `CollisionProvider=true`, 36 exact native source entries and
`RigAssetsProbeCapability=true`. Its legacy `Protocol=1` field remains unchanged;
the pinned source still defines engine protocol 2, without a new runtime claim.

The original build host exits zero. Its owned job closes every descendant,
including the observed compiler service, before disposal; the reservation is
released and postflight finds no remaining leases. Previous tracked native
overlays were preserved before the reviewed builder reapplied its pin. No game,
stock read, runtime probe, ribbon rendering or owner acceptance is qualified.

## Original rig console transport — 2026-10-14

The private launcher normally assigns `NUL` to stdin. The pinned official
`terminal.cpp` reads that exact `GetStdHandle(STD_INPUT_HANDLE)` through
`ReadConsoleInput`; writing to an attached `CONIN$` does not prove consumption.
The existing `-wincon` route instead reads `std::getline(std::cin)` and submits
the line to `Cbuf_AddText` after unpack. It is already in the frozen native958
profile; no new native API, game binary or asset lookup implementation is needed.

`New-IW7BaseClientPlan -OriginalRigConsole` explicitly selects `-wincon` and the
owned anonymous stdin pipe. For the dedicated, the consumer calls
`IW7LabProcess.StartOwned(..., waitForInputIdle, originalRigConsole: true)` with
its existing isolated dedicated-test flags plus `-wincon`. Absent opt-in retains
the existing NUL path. The owner retains the noninheritable write end alongside
the original process handle. Only six exact pool queries and the dedicated-only
rig play/stop dvars are accepted, once each per process; total bytes stay below
the pipe capacity. Input disposal while the process is alive is refused to
avoid the official wincon EOF loop. Cleanup waits/terminates the same owned
process, then closes the pipe; it never reopens a PID for sending.

The consumer retains that dedicated handle and calls
`Send-IW7OriginalRigConsoleCommand` from `ops/Original-RigConsole.Core.ps1` for
either identity in its protected session. This checks the live lease, private
single-client UDP state, original identities, actual native session/safety files,
unchanged client nonce and current bound/godmode/inactivity/cheats heartbeat.
Both native safety publication and heartbeat must be at most 250 ms old; the
pipe writer rechecks publication age after its kernel identity read. The frozen
safety wire publishes its observation time, not the query time; its underlying
ACK predicate retains the native 500 ms window. No protection JSON or
caller-supplied success flag substitutes for those publications.

Official `fastfiles.cpp` registers `listassetpool`: it enumerates
`DB_EnumXAssets` and prints `DB_GetXAssetName`. The fixed types are 6 (xanim),
7 (xmodel surfaces), 8 (xmodel), and 10 (material). The two model names, two
surface names, one animation name and one material name remain an explicit
rig test contract. A write receipt means bytes written only. Fresh client and
dedicated outputs must independently prove the exact expected names; an empty
result remains empty. Play is sent only after the consumer's neutral capture,
and its real GSC/native animation return and subsequent pixels remain separate
evidence. Historical DISPLAY attempts and frozen source/manifests stay intact.

The Windows transport fixture is an isolated PowerShell echo child. It tests
eight real line reads, scope/command/identity/nonce/age refusals, unchanged NUL
EOF, and exact-handle cleanup of a blocked reader. It runs no game and cannot
qualify asset pools, native wincon consumption, engine protection or animation.
Those witnesses require a new reviewed consumer composition and separately
authorized game run.

The actual Windows fixture passes 48 checks, including eight consumed lines and
post-exit/disposed refusal. Existing base-client context, behavior, original
exit-race and owned-process lifecycle tests also pass. PowerShell parsing,
diff whitespace and product ownership pass. No native build or game was run.

CI for code candidate `4ac4bfa8e6f8a4bb2c52accfeb0bd22f4d692aef` did
not start: runs `38479556499` / `38479489861`, checks `115578516426` /
`115578296025`, report the account payment/spending admission refusal. Both
actual jobs have `runner_id=0` and no steps. No CI test passed or executed;
the existing owner exception applies only to this pre-run refusal, with the
real local checks and independent review retained.

Independent review found that the first caller used the nonexistent
`Assert-IW7BaseLeaseOwnership`. The pipe-only fixture had not covered that
path. The correction reads the current scheduler status, refuses absent,
duplicate or non-running runtime tokens, and calls the existing
`Assert-IW7BaseLease(lease, plan, serverIdentity)` before protection or input.
Caller errors are terminating even when the host uses Continue. The targeted
caller fixture uses synthetic reservation metadata in its own directory with
the real scheduler reader/lock and lease assertion; it deliberately stops
before any engine protection or process-input operation.
All five targeted caller checks pass; the 48 real transport checks still pass.

## Independent client protection snapshot — 2026-10-13, source checks

`paris_test_fixture::client_protection()` returns `client_test_protection` by
value on scheduler main. It requires the isolated client-test flags, a live
remote CP client, the current loopback endpoint/expected test port and a challenge
matching the existing agent connection. It reuses the same server-confirmed
protection ACK, nonce and generation; it sends no handshake or input and grants
no capture permission. Voice flags/macros are unnecessary. Invalid state returns
an empty value. The original voice capture API and protocol stay unchanged.

The value contains PID, actual/expected port, query/observation ticks, nonce,
generation, connection challenge and observed server map. Its pure
`client_protection_current(value, now)` check retains the existing 500 ms query
age and five-map CP scope. Both ticks and `now` use the `GetTickCount64` domain.
An independent atomic thread marker rejects off-thread callers before reading
the main-owned agent state. Consumers must obtain a fresh main-thread value;
copied strings are not a world lifetime, physics epoch or pre-reset callback.
No qualified `CL_ShutdownCGame`/client-world pre-reset hook was found in the
existing pin. Collision client activation remains separately unqualified.
The frozen native958/caccd698 image, manifest and source snapshot are unchanged.

Corrected candidate `34cfdb7706b29baddea7b73fa2cb5e9fb241f87a` passes one MSVC
C++17 `/W4 /WX /Od /RTC1` compilation and real fixture execution: 20 snapshot
assertions plus the existing 200,000-packet seeded voice fuzz (29 canonical).
The original root exits zero in 3,165 ms; its owned job tree closes and its lease
is released. An earlier orchestration attempt refused child registration before
Resume and ran no compiler; its failed receipt is retained separately from the
successful retry. The native getter adapter itself is not compiled by this pure
fixture. Full native compilation, runtime behavior and client-world lifetime
qualification remain future witnesses.

## Current engine interfaces after the product split — 2026-10-13

The native editing repository is `iw7-mod-components`. Compose its declared
inputs with `bootstrap.ps1`; the generated directory is an operation input,
not an editing checkout. The server owns `Agent-Lab.ps1`, its scenarios and
`Agent-NativePackage.Core.ps1`; the asset product owns fastfile writers and the
SDK owns reusable author examples. Commands and relative links in the dated
sections below refer to their original server layout. Use the owning product's
composed package for a new run. The resource policy is telemetry-only; consume
its merged source pin before an operational package is prepared.

For a private demonstration, the existing path already provides:

| Operation | Existing interface | Required observation |
| --- | --- | --- |
| Join the retained test dedicated from the free base client | `New-IW7BaseClientPlan`, then `Start-IW7BaseClient`; Start sends `connect` | Exact owned server/client identities and a fresh protected session |
| Protect a player | GSC `player paris_test_protect()` and `player paris_test_safety_snapshot()` | `protected=1`, `bound=1`, engine `godmode=1`, `inactivity=0`, `cheats=0`, `failed=0` |
| Capture the rendering client | `Send-IW7BaseRequest $session 'capture'`; server helper `Save-IW7AgentPreActionFrame` validates the result | Fresh acknowledged 1280×720 BMP, nonce/PID binding and a new graphics tick |
| Dispatch Use or Fire | Server helper `Invoke-IW7AgentScenario` | A gameplay effect; the input acknowledgement alone proves dispatch |
| Place a custom prop | `precachemodel("paris_model_probe")`, `spawn("script_model", origin)`, then `entity setmodel("paris_model_probe")` | The non-default asset and its pixels, after the fastfile and model NetConstStrings load |

`Start-IW7BaseClient` requires an already reserved scenario, a retained server
identity, the private password and an image inside the base installation. Its
transaction restores the existing profile/mailboxes. Preserve an occupied
owner client and Main UDP27016. A snapshot preceding exposure to enemies and
continuous protection during the encounter remain necessary.

The existing model diagnostic is fixed to `mods/paris_model_probe`. The first
successful agent arm samples the named model, LOD0 mesh and model NetConstStrings
once per nonce/generation/connection. It records readable CPU fields and buffer
presence; it does not prove an allocation lifetime, loader invocation, valid
GPU resource, draw or rendered skinning. Later provenance extensions are not
implicitly present in an older native image. When reusing such an image, verify
all of its declared source files and executable against its exact historical
build separately from the current scenario/helper identity; never ignore a
source mismatch or rewrite its manifest.

An imported rig still needs its custom animation precache/NetConstStrings and
actual deformation qualified. The retail prop route is `precachempanim` plus
`scriptmodelplayanim`; its existence is not a completed custom rig. The native
source exposes `fx::PhysicsQuery_LegacyTrace`, but no static-box authoring API or
`SV_LinkEntity` binding is qualified here. GSC names `solid`, `setcontents` and
physics queries alone do not establish an original world collider.

The [exact source-tip runtime mode](SOURCE-TIP-RUNTIME.md) now separates a
zero-client compile/load/init test from protected first-spawn captures, using the
retained native package with all 34 historical source entries pinned. Source
and transaction tests pass; neither phase has run in the engine. This route
reuses Agent-Lab and does not require a new native build or client clone.

Current source-only follow-up: the [Material C witness](MATERIAL-C-WITNESS.md)
binds the new original-image FF, preserves SDK interaction/HUD and prepares an
explicit optional third ticket observer. Full graphics requires 16/16 GiB with
debugger disabled. No Material C game launch or rendered/ticket acceptance has
occurred in this preparation; historical Run 5 below remains unchanged.

Source reconciliation on 2026-10-12, based on private main
`21b91e3ebace48fda5ed60024719168064b2cca5` and retained historical branch
`11a2e38c6b2277980192531096f8144795460ef5`. This batch runs pure tests only:
no game, native compilation/interop, extraction, new live read, audio, download,
lease or Main change. The parent coordinates integration and the first heavy
workload after the admin-command and disconnect investigations finish. Historical
PASS is retained evidence, not a revalidation against today's integrated binary.

## Executable catalog, using the existing helpers

```powershell
pwsh -NoProfile -File ops/modding/Agent-Capabilities.ps1 -Action List
pwsh -NoProfile -File ops/modding/Agent-Capabilities.ps1 -Action Check
pwsh -NoProfile -File ops/modding/Agent-Capabilities.ps1 -Action Demo
pwsh -NoProfile -File ops/modding/Agent-Capabilities.ps1 -Action Plan -Capability vertical
pwsh -NoProfile -File ops/modding/Agent-Capabilities.Tests.ps1
```

`Check` checks current helper files and hashes, plus bounded immutable Git evidence
objects. `CurrentCheckoutMatches=false` exposes missing/stale evidence in the
checkout; it does not mean the historical test failed. An unavailable historical
object refuses Check; do not silently relabel the corresponding capability.
CI's short checkout need not contain those experimental commits: the regression
suite exercises the real evidence checker against an owned tiny synthetic Git
repository, including missing-reference refusal and changed current contents.
It still checks all actual source paths. No command fetches history implicitly;
synthetic checks never promote historical runtime status or bypass local Check.
The catalog retains claims and their limits separately. It does not automatically
parse a historical PASS into a present runtime certification.

`Demo` calls the real `Read-IW7AgentScenario` and observation-mode guards for the
existing actions/aim cases, then executes the existing combat and revive pure
regression suites. Their synthetic transcripts exercise identity/freshness,
attributed effects, cancellation, release ACK ordering and false-proof refusals.
No mailbox is written, native input dispatched or gameplay claimed. The broad
`agent_scenario_test.ps1` includes Add-Type; it is intentionally not called during
this source-only gate. No duplicate scenario engine, input driver or debugger was
added. The adapter imports only the pure scenario and run-plan definitions.

`Plan` returns data, never launches a process or obtains admission. Runtime recipes
must be bound to the parent's exact candidate/package after integration. Budgets
come from `Get-IW7LabRunPlan`: reduced single client 12/12 GiB, pair 20/20 GiB,
server debugger 6/7 GiB. Debugger single client is 14/15 GiB; full-quality visual
acceptance requires its separately admitted full plan. RAM reserve remains zero;
independent 20% commit headroom and one heavy group remain in force.

## Recovered capabilities and acceptance boundaries

| Capability | Retained actual witness | Remaining boundary |
| --- | --- | --- |
| Move/fire/reload/jump/Use bit | Case `20261006-223259-952-8aec1e6d`, native effects and inspected 1280x720 frame | Use bit alone is not a trigger interaction; not all maps/normal graphics |
| Aim | Four server angle changes, release and stable-origin measurements, then combat feedback controller | Keyboard holds have frame-dependent release; not universal analog navigation |
| Kill | `8e743245...:docs/AGENT-COMBAT-SCENARIO.md`, case `20261007-101457-629-69e18733`: 13 aim holds, four Fire holds, attributed 150→117→6→0 bullet damage, retail death and ledger 1→0 | One protected natural zombie, limited arena; effect parser alone does not prove dispatch/owned log |
| Manual teammate revive | `108648b...:docs/deployments/2026-10-07-retail-revive-readiness-and-publication.json`, sixth CD0 pair: 400ms cancelled Use, 2000ms positive Use for retail 1500ms, fresh terminal, health100/100, trigger removed, restoration | Deliberate stock laststand, not natural damage; distinct from instant `.revive`; successful historical code needs integration |
| HUD delivery/pixels | Fresh cache and corrected 0.1.0→0.1.1 seeded update, one GET, exact cache, attached Lua and inspected corrected layout | Remote delivery and owner acceptance absent; preceding overlap/download-loop/crash retained |
| Rigid imported model | 1040-byte FF, one-bone cube, 24 vertices/12 triangles, exact cache and separately inspected two poses | No character deformation, full shading, imported weapon, collision or navigation proof |
| Debugger/capture | Existing `iw7.debugger/1`, owned identity, logs/dumps/PE-PDB correlation, native capture and dedicated diagnostics | Live CDB watch/attach is not this offline-dump contract; callback cadence is not displayed FPS |

The combat/revive/capacity guide headlines on main (and some historical guide
headlines) predate their later successful receipts. Combat's complete guide is
already byte-equivalent to the retained successful reference, despite its stale
headline. The revive receipt and two capacity receipts are absent from this main
checkout. Read the immutable receipt first. Do not repeat these passed scenarios
merely to rediscover infrastructure.
The catalog pins the successful references without replacing the old failure
history. The historical worktree's unrelated recorder/Blender/RE edits remain
untouched and are not implicitly part of this source delivery.

For future assets, reuse `Agent-Lab.ps1`, `Base-Client.Core.ps1`, typed scenario
mailboxes, combat observers, `Agent-Pair-Lab.ps1`, native capture and the debugger.
New work should provide only the missing asset-specific observer and assertions.
An imported weapon needs matching definition/ammo, view/world models, attachments,
animation/notetracks, damage/projectile behavior, sound/FX and reload evidence.
An imported actor needs spawn, pursuit/navigation, attack, damage/death, corpse,
wave accounting, cleanup and cross-client render/audio evidence. A stock kill or
successful asset lookup cannot establish those closures.

## Smallest useful import → Use → HUD → rejoin vertical

The new opt-in `Agent-Lab -ObservationMode vertical` supplies the joint observer
and controlled rejoin driver. It has source and synthetic test evidence only.
Existing model/HUD modes remain separate. The SDK owns `sdk_beacon.gsc`, the rigid
cube, real `script_model` trigger, counters and private GSC HUD. The fixture only
protects, observes and emits records; it never increments SDK state, synthesizes
the accepted trigger, changes player origin/angles or forces stock intro flags.

The SDK contract is version 0.1.0, source SHA-256
`8BA85B3F5B3014D0C4D02B0E71F49BF617959B486502E4C63243B065ABC2A0B6`,
at `sdk/modding/examples/beacon/sdk_beacon.gsc` (SDK commit `1041195`). Integrate
that source before this scenario's DryRun. The SDK source preparation receipt is
not a compiled FF. Build a new **named sdk_beacon zone** under the separately
admitted builder; an old `paris_model_probe` FF is not a substitute.

Required launcher bindings are `GameRoot`, `CandidateRoot`, `PackageRoot`,
`VerticalFFPath`, `VerticalFFSHA256`, `VerticalFFBytes` (1..1,048,576) and
`VerticalSDKSourceSHA256`. Start with `-ObservationMode vertical -DryRun` against
the integrated checkout and reviewed artifacts, then seek the parent's runtime
admission. `-Debugger:$false` accepts the complete 34-source Modules + IsolatedLab
profile; requested debugger/capacity observations still require the 39-source
debugger profile. Agent input, protection and frame capture are compiled
independently of that debugger. The package checker requires PowerShell 7.3+,
the pinned upstream/profile and PR140 privacy overlay, an exact executable hash,
and every expected source exactly once. An older binary without the native
privacy overlay is refused.

Source identity is either the exact declared bytes or one uniform LF/CRLF
substitution whose hash matches exactly. No whitespace trimming, BOM removal,
mixed-newline repair or missing source is allowed. The evidence preserves both
raw hashes, the comparison mode and the original `ProjectDirty` value; it never
rewrites the manifest or attests a clean build. The retained network candidate
`7862B2A5C21047A8FD4095C6DF2FA96A40B3766F92649FCFFE80ABB193517A97` matches 31 sources
exactly and three only by this newline rule. Its prepared build directory has
since been reused, so it is not an intact transformed-source snapshot. Fresh
native privacy, protection and runtime behavior remain separate required checks.

The binding checker hashes bounded, locked reads of FF and GSC bytes. It verifies
declared artifact identity, not FF structure, package closure, build provenance or
rendering. Receipts therefore retain `DeclaredArtifactBinding=true`,
`CommunityPackageValidated=false`, `OfflineBuildProofValidated=false` and
`PixelsVerified=false`. The SDK package validator owns offline package acceptance.

1. The existing complete resource group, vacant owner client, private candidate,
   scoped backups and stock reuse guards run before staging. Cache and shadow
   paths are snapshotted; foreign files/subdirectories and Lua shadows are refused.
   A loopback-only bounded HTTP worker serves exactly `/mods/sdk_beacon/mod.ff`.
   HUD/model routes keep their previous 1,600-byte limits; only beacon allows 1 MiB.
2. Before **each** connection, require challenge-bound UDP `cp_zmb`, running,
   private and zero clients plus a **new append** of native private/LAN/heartbeat
   suppression telemetry. Old log text is insufficient. The same launch-owned log
   is held against replacement throughout that observation. Random password,
   startup/config `sv_lanOnly=1` and loopback binding remain in force.
3. Wait for actual engine protection, stock intro completion, unfrozen/live/grounded
   player, stable origin and one SDK model/HUD owner. Bind records to server PID,
   generation, client nonce, slot, connection, entity and instance. Native stamps
   must be fresh; partial/replayed/malformed/unprotected records cannot authorize
   input. Original source and downloaded FF hashes are checked.
4. Capture before, aim with the existing bounded keyboard feedback helper, then
   hold real Use for 400 ms. The SDK must emit its accepted `sdk_beacon_used` event
   while Use is pressed and inside the acknowledged input window. Require one
   team increment, personal 1, model yaw +30 degrees and matching HUD settext
   intent, followed by a fresh released sample. An input bit or ACK alone fails.
   Capture after and request an acknowledged abort even on failure.
5. Close HTTP **before** the first `Stop-IW7BaseClient` restores its profile.
   Preserve the exact downloaded FF under the outer transaction. Require 30 s
   empty private UDP and another fresh native privacy witness; then restart only
   the owned base client with a new nonce. The exact entity/instance/server
   generation and origin must survive, team remains 1 and personal resets to 0.
   Repeat one real Use to reach team 2/personal 1/yaw 60 and capture again. HTTP
   stays closed for this retained-cache rejoin. This proves neither an in-process
   reconnect nor a second fresh download. A failed second launch retains its
   context for the outer cleanup rather than restoring underneath a live process.

Source scope is `Agent-Vertical.Core/Runtime/Tests.ps1`, the GSC fixture, minimal
Agent-Lab and HTTP route changes, and the data-only capability plan. No new native
TU or input implementation is needed. Existing Base-Client/Agent-Scenario/native
capture helpers retain ownership, abort, crash and restoration behavior.

Limits remain explicit: no runtime attempt, FF build or C# compilation occurred
in this batch. Before/after captures are collected for human/agent pixel review;
settext/angles are intent, not visible quality. The rigid original cube is the
first control; a different imported textured/animated asset, fixed second viewing
pose, seeded package update, simultaneous clients and map rotation are later
witnesses. Natural spawn movement over 2 units, a rejoin outside the 120-unit Use
range or bounded aim envelope fails safely; this driver does not teleport or
fabricate a convenient spawn. Runtime/admitted follow-up may extend ordinary
movement only after preserving that failure evidence.

Proposed execution ceiling: reduced 12/12 GiB, no stock copy, existing pinned
tools, package under 1 MiB for the rigid control and at most 128 MiB new retained
logs/frames per run. These are proposal ceilings, not measured maxima or a new
admission. If a native rebuild is required, budget it separately at 4/6 GiB and
obtain the parent's storage allocation first; no new SDK/PDB/tool copy is allowed
by this preparation batch. Full material/animation visual QA is a later full
graphics scenario, not inferred from this reduced smoke test.

## 48 agents: exact current stopping point

The selector clamp is only one constraint. Retained source/disassembly evidence
identifies selector `0x140C18D00`, a byte count at GameStateInfo+0x546, server pool
base/count `0x143C986B8/C0` with stride `0x5010`, independent SV pool
`0x146B2C508` with stride `0x3F08`, 42-entry character-reference allocation and
client consumers capped at 42. For 18 players plus 48 agents, 66 characters must
be allocated/constructed/serialized consistently. The `[42,58)` reservation and
all CP entity layouts still need proof; the historical crash dereferences
entity58+0x190 while the SDK calls +0x180 `agent`. A null guard cannot allocate it.
No six-bit network field has been proven: 66>64 is a question, not a codec finding.
Trace actual encoder/decoder callers, null sentinels, save/restore versions,
client arrays/animation and all index consumers before any protocol decision.

Later historical work is stronger than main's canary-only next step:

- Actual count/base stores: DWORD `0x14C1ED666`→C0 from EAX24, QWORD
  `0x14BFE5A29`→B8 from RBX. Eighteen writes and actual hardware canaries observed.
- 06CB closure: timely COMPLETE1062ms, restored registers, exact resume, closed
  helper/VEH/handles and restored candidate. Followup 9F receipt: COMPLETE1281ms,
  no failures, 18 writes and closed readers/restoration/lease.
- Followup bytes establish REP clear semantics, a 491904-byte fill (=24×0x5010),
  and initialization `DWORD [RBX+RAX+0x4A90]=0x7FF`. Full loop and allocator remain
  unproven. Next control-flow targets are `0x14B5383F9` and static exit call
  `0x140AC6AA0`; this is not evidence those paths executed completely.
- Two identical CD0 package launches changed only bytes `0x141238362/363` in
  parent page `0x141238000` (C4 A7→76 21), despite stable double reads within each
  case. The initialization reader correctly refused. Both cases restored and
  closed; no initialization pages or writer attribution follow from them.

**Next decisive experiment is attribution of that startup-changing word**, before
another initialization capture. Do not repin a third run blindly, mask the bytes,
disable the integrity guard or relaunch the old late watcher for attribution.
The retained untracked prototype already exists in `modular-agent-platform`:

| Source-only prototype | SHA-256 read on 2026-10-12 |
| --- | --- |
| `src/native/paris_word_provenance.cpp` | `AD4439715100BE15BF991C039D847B01A14A67C28DF5D6194FF1FEB4E6F7D952` |
| `src/native/paris_word_provenance.hpp` | `55038774E63742D1EE1F7209FC0C94DFA9B84B6FAD46D75657DB70A0E2A92E71` |
| `ops/agent-capacity/Provenance-LifecycleOverlay.Core.ps1` | `1A963BBE11547D292F0E9EF2C175E4D67FD899035BFA2E72B7E85EE566C9BA7A` |
| `ops/agent-capacity/Provenance-BuildCopy.Core.ps1` | `030C1864C1CA8992E841F3AA892E8329481F8E0C5E3F2B20CF245A42B8853366` |

Its header proposes one TID, four 64-byte snapshots around loaded/post_load/
post_unpack, stable double reads (512 bytes), a 2-byte watch, 64 records, 10s and
200ms checkpoint requests. It explicitly excludes restart/capacity-watch modes.
Its pure unit compilation is historical; the full distinct STARTUP profile and
real writer capture never completed. The parent reports the former recorder
build obstacle corrected by PR126; that does not compile or validate this TU.
Source hashes above are an inventory, not a review approval or a kernel witness.

After GO, first review and isolate that small source group against current main;
do not copy the dirty historical Build-Voice wholesale. Build under a separate
4/6 GiB group, then propose a server-only 6/7 GiB startup case on retained stock.
Bind exact package/source hashes, lifecycle window, original handles and output
closure ACK. Require an actual canary, before/after word, writer RIP/context and
bounded forward instruction evidence. A changed snapshot without a trap is an
unattributed change; one TID is not all-thread coverage. Preserve every refusal.
Only an attributed transformation with exact surrounding bytes can justify the
initialization-reader update and two fixed 4096-byte pages at `0x14B538000` and
`0x140AC6000`. Retain double-read/mapping/hash/closure guards. Proposed new evidence
ceiling is 32 MiB excluding a separately budgeted native build, with no new game
assets. Allocation/free/reset, both pools, index/snapshot/client paths and actual
48 simultaneous actors still require later independent evidence.

## New maps: required chain and concrete source gaps

Local pinned sources were inspected without an upstream update check:
IW7 SDK `36f7afedb9e4c8c665b6e29227e3f5c660ed63d6`,
`src/client/game/types/database.hpp:147` onward; ZoneTool
`d5e2117344f68d6ed6c1053eb3547dae6b2603d9`,
`src/zonetool/zonetool/iw7/zone.cpp:652` and H1 converter
`src/zonetool/zonetool/h1/converter/iw7/assets/clipmap.cpp`.
Existing tool checkout overlays remain untouched. These are inspected local
sources, not claims about a pristine or latest upstream release.

| Chain | Existing source clue | Minimum new-map witness |
| --- | --- | --- |
| Render world | GfxWorld, transient zones, materials/images/shaders; ComWorld/lights, FxWorld/glass as needed | World roundtrip with stable geometry/light/streaming and inspected full-quality frames |
| Collision/physics | ClipMap, MapEnts, physics shapes and dynamic entities | Player floor/wall/stair movement, bullet trace and AI contact use consistent collision |
| Entities/game setup | MapEnts/addon, spawn/script triggers and map GSC | Real spawn, one Use trigger, round/exit lifecycle without missing callbacks |
| Navigation | PathData and NavMesh serializers, graph/resource/obstacle/link data | AI path around an obstacle, traverse required links, reach/attack target and clean up |
| Delivery/network | Exact FF/cache/version plus server/client matching ownership | Fresh join, update, rejoin and map rotation, with entity/UI state consistent across clients |

The H1 converter explicitly writes null physicsAsset for trigger/submodel entries
and null cmodel info (`clipmap.cpp:94,118,194..196`). The navigation parser reads
existing `pGraphBuffer`/working-graph data (`iw7/assets/navmesh.cpp:43..52`);
that is not a navigation generator. ZoneTool dispatch entries prove source
support exists, not complete authoring/serialization. Its `paris_rhino*` pack
guard also excludes world/map/navigation types: do not reuse that narrow
profile as a new-map builder. Coordinate format, collision and nav graph work
with those owners; no new map compiler or universal H1 importer is claimed here.

## This batch's validation and handoff

Executed on 2026-10-12: catalog Check/Demo, 38 portable adapter checks including missing
source/evidence refusal, existing combat/revive regression suites, and 33 existing
Python debugger tests (`python -B tests/ops/debugger_test.py`, no bytecode cache).
Actions/aim parse at 20,600/20,800ms worst-case with 8/9 assertions respectively.
All three PowerShell files parse; whitespace checks pass. These are source/model
checks, not native compilation, GSC runtime or fresh pixels. The source-only
checkout totals about 6.4 MB, safely below the 100 MB preparation allocation.

The initial capability batch owns `ops/modding/Agent-Capabilities*` and this document.
The parent integrates the coherent local commit, updates shared STATE/BUGS/
CHANGELOG/VALIDATION/PLAN once, and coordinates private PR/exact-head CI/merge.
No runtime or Main promotion is part of this delivery. Next action is integration
of the recovered PASS evidence and the small joint vertical observer; the 48
startup attribution remains a separate, centrally admitted experiment.

### Joint observer follow-up (2026-10-12, source only)

The initial capability batch above was followed by the vertical source described
in this document. Its pure suite passes **97 controls** using the real record
parser, bounded aim/pass driver and rejoin orchestration with simulated wire,
process and capture adapters. It checks missing real events, stale/future/replayed
records, entity/session/counter/angle drift, privacy denials, protection loss,
input abort, HTTP-before-profile closure and failed-rejoin ownership retention.
The pass-driver test exposed and corrected a clock ordering bug: timestamp after
reading newly appended log text, rather than rejecting a record written during
that read as if it came from the future. Synthetic transport behavior is not
native input, HTTP delivery, gameplay, teardown or pixel proof.
The fixture also passes GSC Tool 1.5.1.359 parse (not runtime compilation), all
changed PowerShell sources pass AST parsing, and whitespace checks pass. The 38
capability controls (including existing combat/revive pure suites) and 33 Python
debugger tests were rerun successfully. C# HTTP route compilation is still pending
the parent's admitted validation; no `Add-Type` was executed locally.

The parent integrates this coherent local follow-up after the SDK source commit,
adds the pure suite to its CI owner files, and completes private PR/exact-head
CI/merge plus shared STATE/BUGS/CHANGELOG/VALIDATION/PLAN updates. The first next
action is the separately admitted named-zone/native build; only a later explicit
runtime admission may run this fixture. Main27016 and existing runtime files
remain untouched by this source work.

### Admitted beacon runtime attempt and delayed feedback correction (2026-10-12)

The admitted run `20261012-025611-746-c01d8ac6` used fixed source
`22da0494912be6a23d9a082f40aebedbee418b72`, one 12 GiB physical / 12 GiB
commit reservation, the base client, retained candidate stock, and `Debugger:false`.
No native build, stock copy or Main deployment occurred. Pinned inputs:

| Input | SHA-256 |
| --- | --- |
| Native executable (6,090,240 bytes) | `7862B2A5C21047A8FD4095C6DF2FA96A40B3766F92649FCFFE80ABB193517A97` |
| Beacon FF (1,048 bytes) | `76ED0701DC1480C501604DB04999F300394C65877AA24A70DFE7AFC2CD662D4A` |
| SDK GSC source | `8BA85B3F5B3014D0C4D02B0E71F49BF617959B486502E4C63243B065ABC2A0B6` |
| Passive vertical fixture | `2186E99A6F95F91AE8E272F589DA0E69E9C16A524B558B9B4039F9ABDFA1441A` |

The exact HTTP GET delivered the FF. Fresh UDP getInfo reported **protocol 2**,
`fs_game=mods/sdk_beacon`, `mod_hash=7B685062`, private running `cp_zmb`.
The first Use was accepted by the actual SDK trigger, observed 78 ms later, and
fell inside the acknowledged input window. Team/personal became 1/1 on the
same entity/instance; model yaw became 30 degrees. Native 1280x720 BMP hashes
before/after were `87F7BC2E90456702E6709E19DED39D62EEE5C0AFAA35DD8A546B701A3B51C19C`
and `66CC52046A724DEE1C4092D095799281E516C6DB53E4933351785CF465890F62`.
PNG format conversions preserve the original BMPs. Image inspection confirmed
the rendered BEACON counter changing from YOU 0 / TEAM 0 to YOU 1 / TEAM 1,
the Activate beacon hint and a dark cube. Exact rotation is telemetry evidence;
the camera changed too. Picmip/bump/spec were reduced to 2: material identity,
normal visual quality and owner acceptance remain unproved. Native package
source inventory/newline provenance does not attest a pristine build snapshot.

After the first owned client closed, HTTP was closed and the same FF cache was
retained. The second client connected with a new nonce; the same server
generation, entity, instance and target origin retained TEAM 1, with YOU reset
to 0. Its second Use **was not reached**. The controller rejected an unchanged
angle after client release ACK: fresh server samples at +93/+187/+297 ms still
reported pitch 0, whereas the first actual change arrived at +390 ms and
settled to -2.31262 degrees at +500 ms. The run therefore remains **failed**:
`Feedback pulse has no bounded observed effect.` This is measured feedback
latency, not proof of a missing input or a validated full rejoin scenario.

The follow-up correction opts the vertical into at most 750 ms of waiting for
an actual angular effect after release ACK. Existing identity, protection,
freshness (500 ms), position, angle and post-effect stability checks still run;
no second input is sent from an ACK without observed effect. No-effect expiry
still fails, and other scenarios retain zero extra grace by default. Pure
tests replay these delayed observations and reject expired, stale, unprotected,
moved-origin, cross-axis and excessive-angle samples. The vertical suite passes
127 controls; this correction still requires a fresh admitted runtime attempt.
Independent review caught a defect in the initial grace implementation: a first
effect arriving at +900 ms could restart the stability filter and become accepted
at +1100 ms. The correction records the first actual effect on every fresh
post-release sample before stability filtering and rejects a late arrival. The
new replay also checks that this witness resets for each pulse. The initial
implementation and its correction remain separate commits; no game was run
between them.

Final result records `Passed:false`, `Restored:true`, `CleanupError:null`.
Fresh process/resource inspection at 03:02:14 UTC found no test process and no
lease. Only Main remained, with its pre-run creation identity, command line and
binary hash unchanged. Restoration verifies managed-file/profile hashes;
the existing profile/cache backups are retained. Native privacy and protection
were observed on both connections: engine godmode, inactivity 0 and cheats 0.
Retail initialization errors in `init_cryobomb` / `init_forgefreeze` remain
open and are not attributed to the beacon. Raw logs, identifiers and machine
paths stay in ignored runtime evidence; this record is sanitized.

### Second runtime attempt: server Use arrives after client release

Run `20261012-031247-081-1c188b33` used fixed source
`f14760c3078e3a8e8f8ca010b15873029951013a` and the same native, SDK, FF,
fixture and 12/12 GiB reservation. The dedicated started at 03:12:55 UTC.
The first pass again delivered the exact FF and completed its accepted Use,
release and captures. Fresh getInfo after each connection reported protocol 2,
`mods/sdk_beacon`, hash `7B685062`, private `cp_zmb`, zero clients between/after
passes. The second connection preserved the entity/instance/generation and
TEAM 1, reset YOU to 0, then reached an actual SDK Use and TEAM 2 / YOU 1,
with model yaw 60 degrees. Aim calibration succeeded under the reviewed bound.

The overall result still **failed** before the second after-capture. Its Use
validator incorrectly required the server event to precede the client's release
ACK. Both use the same monotonic clock, but they describe different observation
points: request at tick 104017171, native client press at 104017234, release ACK
at 104017671, actual server SDK Use (pressed=1) at 104017828, or **157 ms after
ACK**. Later server samples show the released state and exact 2/1 counters.
These are positive activation/persistence observations, not an accepted full
scenario or a substitute for the missing final capture. An interim status
prematurely called the second pass successful; that claim was retracted as soon
as the absent after-capture exposed the still-running validation failure.

The follow-up validator accepts an actual server event only between the request
and at most 750 ms after release ACK, with fresh observation within 500 ms.
It additionally requires a released server sample strictly after both that
event and the ACK, at most 1500 ms after ACK, with exact identity and one-step
counter changes. The runtime wait cannot finish on a pre-event released sample.
Receipts expose client release, server event lag and server release separately.
The 139-control pure suite covers +157/+750 ms acceptance, +751 ms rejection,
pre-event/same-tick/late release refusal, and the actual pass driver receiving a
delayed event after an apparently released pre-input sample. Two otherwise valid
Use events with distinct record IDs also reject and abort input. No runtime
outcome is inferred from those synthetic tests. The second before-capture is
nearly black during the arrival fade and is not a readable visual witness; no
brightening or retouching was performed. The missing after-capture follows the
validator failure and does not establish a renderer failure.

The next driver also retains an additional native frame after measured aim
convergence and before Use. It labels this `before-use-after-aim`, with
`BeforeGameplayAction:false` and `BeforeUse:true`, and preserves the initial
frame separately. This avoids relying only on the too-early fade capture without
altering pixels, changing render settings or claiming that server READY proves
image readability. Fresh protection/range/aim are rechecked before Use after
capture; later image inspection still decides what the frame actually proves.

At 03:16:28 UTC, result was `Passed:false`, `Restored:true`, `CleanupError:null`;
fresh process/resource inspection found no test process or lease, and Main's
creation identity and binary hash remained unchanged. The run's sources were
fixed until this closure. All evidence and rollback backups remain retained.
The two retail initialization errors also predate this SDK test: see
`deployments/2026-10-06-agent-debugger.json`, `BUGS.md` and `VALIDATION.md`.
The retail functions dereference trigger structures without a defined check,
but the exact non-object causing this runtime failure is not established.
No SDK attribution or suppressive retail patch is justified by this evidence.

### Third attempt: live Main bank audit and separate owned recovery

Run `20261012-032431-768-1b928c5f` used fixed source
`fa236d276ab263c52f10a75c245bf745188d8bd4`, the same pinned inputs and one
12/12 GiB reservation. The dedicated started at 03:24:40 UTC. The first pass
completed its real Use, counters 1/1, released input and three native captures
(initial, after aim/before Use, after Use). Rejoin did not start. During the
first client restoration, the strict Main audit detected four changed bank
files: three balances and one previous-value file. Main executable, configuration
and scripts were unchanged. The initial result remains `Passed:false`,
`Restored:false`, with the original protected-file error and cleanup error.

Main's read-only UDP query then reported one player. Its recent logs show a
native endgame, a three-player handoff, cleanup and map rotation; those three
account identities match the changed balances. The deployed bank callback saves
each player's remaining points on game-ended. This is strong log/source/timing
correlation with normal Main gameplay, not an attributed file-writer trace.
No account identifiers or balances are included in this versioned record.

Recovery preserved every current Main balance and the failed result/manifests.
After 30 seconds of fresh empty private UDP replies, the exact candidate received
quit. It did not close within ten seconds; the existing owned-handle helper
terminated that same process and confirmed exit (code 3758096385). Candidate
restoration completed at 03:29:36 UTC. At 03:30:20, canonical bank roots were
distinct with no redirected ancestor/descendant and **66 NTFS file identities,
zero shared identities**. The pinned launcher used the candidate directory as
the process working directory. No Main bank path was a recovery write target.

The separate `owned-recovery.local.json` completed at 03:31:50 UTC: 21 managed
base files passed existence/hash checks, profile trees matched, and current Main
bank hashes matched before/after recovery. The strict bank-audit failures and
original `Restored:false` records remain untouched. Normal guarded lease release
completed; 03:32:25 inspection found an empty registry and only Main, with its
original creation identity and binary hash. This recovery is not a retroactive
scenario PASS. Logs/frames totaled about 16.3 MB, below the 128 MiB ceiling.

The source follow-up introduces an explicit Agent-Lab-only bank audit policy.
Ordinary Base-Client restoration remains strict. The policy checks independent
canonical bank roots and NTFS identities before staging, records the candidate
working directory/configuration/script binding, and rechecks bank isolation at
restoration. Main bank paths may never overlap managed files or restored profile
trees. The wrapper invokes the original restoration, independently verifies owned
file hashes/profile trees and the static Main file inventory, then records
`ManagedFilesRestored`, `StaticMainUnchanged`, `MainBankDeltaObserved` and
`MainBankWriterAttributed:false` separately. A bank delta stays observable and
unattributed; neither current values nor original protected hashes are rewritten.
Static Main changes and corrupt owned backups remain blocking failures.

Cleanup now attempts exact candidate closure even if a client restoration audit
has failed. It requires confirmed closure before any later restoration, attempts
each owned restoration, and releases the reservation only after all stages
succeed. The new temporary-file/synthetic-lifecycle suite passes 61 controls,
including shared bank hardlink/junction rejection, live bank preservation,
strict-default refusal, static file changes/additions, corrupt owned backups,
profile/bank overlap, candidate closure following an audit error and lease
retention on unknown closure or failed restoration. The 139 vertical controls
and existing Base-Client/context regression suites also pass. This source change
has not yet been game-tested; no fourth run is claimed.

Independent review then found that the initial bank-overlap guard compared raw
forward-slash spellings while the restoration resolver also accepts Windows
backslashes and dot components. The correction resolves every managed target
and profile to its canonical absolute path before restoration writes. A target
equal to or below Main bank is forbidden; a profile equal to, above or below it
is forbidden. Tests use valid backups and unchanged sentinel files to prove the
guard runs before any write, covering mixed separators, case, dot components,
trailing separators and ancestor/descendant profiles. A `bank-other` sibling
still restores normally. The earlier implementation and correction remain
separate commits; no bank corruption was observed and no game ran between them.

### Reused Doom candidate: beacon-only source profile

The coordinator selected an existing stopped Doom dedicated for reuse, with a
durable destination outside managed worktrees. This is a parameter change, not
a new game copy or an import of another candidate's backup. Read-only inspection
found 17 original custom CP scripts and the candidate's own bank/configuration;
bank isolation again checked 66 NTFS file identities with zero shared Main IDs.
The native package, 1048-byte FF and SDK source hashes still match the inputs
above. The existing `doom-test.marker` identifies this separate dedicated, but
the Agent-Lab/native appdata gate requires its exact isolation marker as well.
No marker was written during this inspection. The old read-only plan remains a
historical receipt; final parameters must bind the new root to the verified move
receipt before the separately authorized marker adoption and DryRun.

For vertical mode only, staged CP now contains exactly `sdk_beacon.gsc` and
`agent_vertical_fixture.gsc`. Both depend on retail utility/native test APIs,
not other Paris custom scripts. The transaction retains all original candidate
scripts and restores their exact bytes. This prevents Doom's custom init/clip
setup, rather than relying solely on `paris_mod_doom=0` to disable its encounter.
Native protection and the existing native package remain unchanged; no absence
of compiled Doom components is claimed. All other Agent-Lab modes keep the same
catalog script selection and ordering. The plan records its two staged scripts.
The vertical suite now passes 145 controls, including a real temporary-file
17-to-2-to-17 restoration, duplicate catalog handling and unchanged non-vertical
selection. No game was launched for this profile change.

Follow-up source review caught a remaining unconditional bank-script hash read
in the launch policy receipt, after the minimal stage had removed that script.
It would stop a real vertical run before process creation; DryRun returns before
this stage and cannot prove it. The receipt now records `BankScriptStaged:false`
and a null hash for vertical, while ordinary modes still require and hash the
staged source. Unexpected source or compiled bank scripts in the minimal stage
are refused. Five temporary-file checks cover these cases; the restoration
suite passes 66 controls. No game ran with the incomplete profile.

At 04:08:11 UTC, after the coordinator's verified same-volume move, the durable
candidate was adopted under the shared admission lock. Its canonical root and
NTFS identity matched the hash-bound move receipt. Main was the only IW7 process,
with its unchanged creation identity and executable hash; the lease registry was
empty. All 1,205 original files retained their identities, sizes and attributes;
the 39 mutable hashes matched before and after adoption. Bank isolation checked
66 file identities with none shared between Main and candidate.

The sole candidate mutation was `CreateNew` of
`iw7-mod/paris-isolated-lab.marker`: exact ASCII `iw7-paris-isolated-lab-v1`,
25 bytes, no BOM/newline, SHA-256
`705F28699E62148C720F7C88C4AE2C63C085DAB6F46610582161F312E0AE8BCA`.
The original Doom marker and old read-only plan remained unchanged. This is
adoption metadata, not runtime validation. Any rollback must first confirm owned
process closure and the same canonical root and exact marker hash.

The actual `Agent-Lab.ps1 -DryRun` then passed at source `569a772`, binding the
durable root, move/adoption receipt hashes, reviewed native/FF/SDK inputs, only
the beacon and passive observer scripts, and 12 GiB physical/12 GiB commit.
The new local plan is under
`runtime/agent-candidate-plans/doom-durable-20261012-040801/`; its SHA-256 is
`B4E3C777F7512D08AC515033DF7C0FA5697DA3FD02633B55FBC68B62109C1C12`,
and the adoption receipt SHA-256 is
`004D3359BDB2ED13C7C1D72BB7D9B640CF89A0BB659E0D74D4CB0C2AFFCADE4F`.
DryRun reserved no resources and started no game. A fresh 04:08:36 UTC snapshot
still showed Main alone and zero leases. The coordinator's runtime GO remains
false, with animation then material FF work taking priority. Complete vertical
restart/restoration and visual acceptance remain unproved.

### SDK report: exact classification of the two pre-existing retail errors

Read-only classification of all three closed SDK candidate `server.stdout.log`
files finds exactly two complete `script runtime error` blocks per run: one
`init_cryobomb`, then one `init_forgefreeze`. They remain **errors, unresolved**;
they are not downgraded to warnings or removed from the report.

Both blocks print the exact instruction diagnostic
`while processing instruction OP_CastFieldObject: 0x140c07d63`. Each has precisely
two stack frames, in this order:

| Error | First frame | Caller frame |
| --- | --- | --- |
| Cryobomb initialization | `init_cryobomb` in `scripts/cp/maps/cp_zmb/cp_zmb_interactions.gsc` | `init` in `scripts/cp/cp_interaction.gsc` |
| Forge Freeze initialization | `init_forgefreeze` in `scripts/cp/maps/cp_zmb/cp_zmb_interactions.gsc` | `init` in `scripts/cp/cp_interaction.gsc` |

The report compares each entire five-line block, including its header, opcode,
address, both frames and closing delimiter; only CRLF-to-LF normalization is
used. A matching function name somewhere inside a different stack is insufficient.
All three logs place these blocks at lines 147–151 and 152–156. They occur after
the SDK initialization marker in these runs, so their timing alone cannot exclude
SDK involvement. Their pre-existence is separately supported by the versioned
[October 8 original-script comparison](deployments/2026-10-08-map-vote-unanimity.json),
at immutable commit `e012849b70530f5062021b5e15d7acd76f27a23b`: it records both
errors with the original map-vote script, `WholeMapClean:false`, and restored
baseline/candidate state. That earlier receipt was re-read; its older raw logs
were not revalidated during this classification.

| Closed SDK run | Cryobomb / Forge Freeze | Other complete runtime blocks / unparsed runtime headers | Server stdout SHA-256 |
| --- | --- | --- | --- |
| `20261012-025611-746-c01d8ac6` | 1 / 1 | 0 / 0 | `E062A1EC92932B9E894A69C3201F54463A42096B8D9720E6C9D5165BA20EF9C5` |
| `20261012-031247-081-1c188b33` | 1 / 1 | 0 / 0 | `68E6C86DDED4EEF2B58BA24B4387E9DF5ADA31BFFF8449CE97E1037B5238E7AD` |
| `20261012-032431-768-1b928c5f` | 1 / 1 | 0 / 0 | `0C45BE1C840D888888BD71BFD6C6FDFD9135FBBD9F9567FE6DFBA04847C79882` |

These counts concern complete runtime-error blocks in those three server stdout
files only, not all diagnostic categories, client logs or future runs. Original
log hashes matched before/after reading; all three original scenario results
remain failed. The ignored local report
`runtime/agent-candidate-plans/sdk-retail-errors-20261012.local.json`, SHA-256
`DF0F681FD7F44959CA33B9CCD1CBC01DB2C5D7C5768542D808EDD1198149E33B`, retains the
six complete blocks and original failure/restoration fields.

The opcode/stack does not identify the invalid field/value, its originating
cause or the gameplay impact. These traces neither prove a new beacon defect
nor prove the retail interactions work. No retail patch, runtime-error filter,
allowed-error set or acceptance gate changed. Every future error must remain
reported: a changed opcode/address/frame, additional frame, incomplete block or
extra occurrence needs separate comparison and cannot inherit this historical
classification. The next runtime still needs fresh admission at the unchanged
budget and the coordinator's explicit GO; this report starts no game.

### Run 4: interaction/restart passes; runtime integrity fails on missing cdata

The coordinator authorized one cycle at source `69fd1e0` (executable source
unchanged from reviewed `569a772`). Fresh admission reserved the full 12/12 GiB
at 04:27 UTC; the candidate used the durable Doom stock, the same reviewed
native/1048-byte FF/SDK/observer hashes and the two project scripts. Native
privacy, scoped engine godmode, inactivity 0 and cheats 0 were observed. No
second cycle or retail repair was performed. The sanitized, hash-bound record is
[Run 4 evidence](deployments/2026-10-12-sdk-beacon-run4.json); raw logs, captures,
transactions and full error blocks remain under ignored
`runtime/agent-lab/20261012-042704-926-54f4946d/`.

The targeted witness succeeds: first real Use gives team 1/personal 1; after
closing and restarting the owned client, the same server object persists with
team 1/personal 0, then real Use gives team 2/personal 1. Input release is observed
on both passes. The exact cache survives, the HTTP worker closes before rejoin,
and the second client has a new process/session. This is a controlled client
restart, not an in-process reconnect. Original `result.json` and
`scenario.result.json` remain `Passed:true`; they do not contain a complete
retail runtime-error gate and must not be presented as global acceptance.

**Runtime integrity is not validated.** The final closed server stdout contains
221 complete runtime-error blocks: the two exact pre-existing Cryobomb/Forge
Freeze errors plus **219 new unresolved errors**. They are not allowlisted:

| New diagnostic | Count | Observed log phase |
| --- | --- | --- |
| `OP_dec` in `cp_zmb::update_team_door_buy_on_spawn` | 3 | First client identity setup, before its first protected heartbeat/READY |
| `OP_EvalLocalVariableObjectCached: 0x140c08a57` in `gametype_zombie::is_player_near_interaction_point` | 54 | Between connections and after the final connection |
| `distancesquared`: `Type undefined is not a vector`, same leaf function | 54 | Same intervals |
| `OP_less: 0x140c07e82`, same leaf function | 54 | Same intervals |
| `OP_JumpOnTrue` in `gametype_zombie::get_closest_player_near_interaction_point` | 54 | Same intervals |

The AI stacks continue through the nearest-player function and retail
`scripts/anim/notetracks_mp.gsc::ai_update`, with unresolved intermediate frames.
There are 160 AI blocks between the two active witness windows and 56 after the
second, with none inside those windows. The first AI block is after the first
owned client's verified closure/restoration (04:28:30 UTC). Log-order/native-tick
brackets place its first group around 04:28:31–41, and the last around
04:30:21–31; the error blocks themselves have no timestamp or captured variable
values. The three spawn errors are bracketed around 04:27:51–04:28:01. Both
client stdout logs contain zero runtime-error headers; that does not erase the
server errors. A missing `sounddata/cp/cp_zmb.json` diagnostic is also retained.

Read-only comparison identified a missing candidate prerequisite. Run 3 loaded
Aurora's `custom_scripts/cp/patches.gsc` and `cp_mp/inspect.gsc` from its retained
private `cdata`, in addition to project scripts. The reused Doom root had no
private `iw7-mod/lab-appdata` before adoption. Agent-Lab starts with `-noupdate`
and does not provision that updater content: Run 4 loaded only the two project
scripts and lacked the Aurora patch and sound table. Nothing originally present
in that candidate's private cdata was deleted; the absent-before appdata state
was restored after the run. The earlier assertion of two *project* scripts was
insufficient to establish a complete Aurora runtime environment.

The retained Run 3 updater patch and current local Aurora-managed copy match
SHA-256 `307F03A1427C18CF58A0861E86E2023BE58661338202A1FF246E41A4C7DC02B6`
(3243 bytes). Its existing replacements guard exactly the failing paths: reject
an undefined nearest player/interaction before the distance call, and initialize
door prices for at least one player when a dedicated starts empty. The clean
local retail reference at `1dd48a78e55ef9c99519fc5221a206168ce2e98a` shows the
unguarded distance operands and a door initializer with cases 1–4 but no zero
case, followed by the three unguarded donation decrements at spawn. Reference
file hashes are recorded separately; no equivalence to the loaded retail
bytecode was established. This strongly supports the missing updater guards as
the mechanism, but their restorative effect has not been tested. Candidate root,
project module selection and updater-data availability changed together, so
this is not a controlled single-variable A/B. Native and retail map/AI code
still execute despite the minimal project script profile.

The coordinator separately inspected the two native rejoin before-Use/after-Use
BMPs: SDK HUD changes from `You:0 Team:1` to `You:1 Team:2`; a dark cube is visible
in both and `Activate beacon` is readable after. Retail portrait/ammo/cash are
absent in before-Use and visible after, with a nearby 500 indicator. The cause of
that HUD timing is unproved. These images do not prove normal texture quality or
a certain visible rotation. The original `PixelsVerified:false` is preserved;
the separate visual review is bound to the original BMP hashes.

Restoration completed at 04:30:42 UTC. At 04:31:00, Main was the sole game process
with unchanged creation/image identity; test ports and resource leases were
absent. All four owned transactions were independently rechecked at 04:36:36,
including the candidate's 17 original scripts and absent private appdata.
Managed restoration and static Main checks pass; no Main bank delta was observed.
Six native frames plus logs total about 21.33 MiB, below the 128 MiB limit.
No original result, log or capture was rewritten to change its outcome.

Next: review and bind the required Aurora updater cdata as an explicit candidate
prerequisite, with preparation refusing incomplete environments. Do not repair
retail code, widen allowed errors, copy another candidate's identities/bank, or
retry gameplay under this one-cycle authorization. Any correction/retest needs
its own reviewed plan and the coordinator's next GO. Overall acceptance remains
blocked by this recorded runtime incident.

### Issue 149: explicit Aurora data prerequisite before planning or launch

[Issue #149](https://github.com/maxis0191/iw7-paris-server/issues/149) requires
a protected retest verifying the prerequisite, absence of the new errors and
restoration. Run 5 below now supplies that bounded technical witness; the two
older errors remain separately tracked in issue 150. The old adoption checked
retained stock, marker, native package and SDK inputs; the old DryRun returned before launch staging and never
inspected updater cdata. A marker and a successful plan therefore did not imply
a complete runtime. This was a missing preflight contract, not permission to
remove updater-managed content or replace it with our own retail patches.

`Agent-Lab.ps1` now requires explicit `-UpdaterDataRoot` and
`-UpdaterDataSHA256` before DryRun can return. The digest binds the entire sorted
directory/file inventory, relative paths, lengths and raw SHA-256 file hashes;
it is independent of the machine path and NTFS identities. The helper bounds the
tree to 512 MiB, 512 files and 128 directories, requires the CP patch, shared
inspect script and Spaceland sound table, and rejects redirects, foreign top-level
paths, partial candidates, content drift and candidate/provider hardlink aliases.
The explicit provider must be outside the candidate. A reviewed digest is an
input binding, not an independent upstream-release attestation.

The local Aurora-managed provider contains 84 files and 23 subdirectories,
394,436,292 bytes, with inventory digest
`2649231856356E5B5BEE4A6D043AA13E547CCC26E3D5F7B8A385E0F1A03F4F6A`.
Seven updater zone files account for 370,828,272 bytes; scripts, sound tables and
UI account for the rest. This provider is copied as a complete updater tree;
no retail game snapshot, identity, bank or parent AppData directory is imported.
Real provider files were only inventoried, not staged during this correction.

An already identical, independent candidate tree is reused. An absent tree is
reported as `StagingRequired:true`, `CandidateVerified:false`, with explicit
copy bytes; it is never called ready by DryRun. During a future admitted run,
the existing lab-appdata transaction is saved before staging. The helper uses
the same whole-tree Robocopy flags as reviewed `Isolated-Lab Prepare`, checks
the source inventory again before and after copying, and verifies every target
hash and independent file identity. A changed/partial existing tree is refused,
not overlaid. Normal transaction restoration preserves existing bytes or restores
the original absence, including after a partial copy. The two project SDK
scripts remain separate from this Aurora prerequisite.

Before a client may join, the fresh server stdout must also show the Aurora
patch loaded and its `main` executed; a missing Spaceland sound-table diagnostic
refuses the join. This load witness accepts no unrelated runtime errors. Existing
error reporting/acceptance limits, native privacy/protection, the full 12/12 GiB
reservation and Base/Resource helpers are unchanged.

The new updater suite passes 34 controls using tiny synthetic provider files,
the actual transaction/Robocopy path and the real Agent-Lab missing-provider
DryRun refusal. It covers hashes, missing/foreign files, redirects, hardlink
aliases, provider drift, no-copy reuse, existing-byte/absent-before restoration,
partial-copy failure and missing/incomplete runtime load witnesses. The 66
restoration and 145 vertical controls remain passing. That correction checkpoint
comprised source and file tests only; real provider staging and runtime validation
follow in Run 5.

### Run 5: Aurora prerequisite verified, no new errors in the closed witness

The single authorized protected retest used clean integrated source
`40cb54420686b389970a26df2c5c93263451a672`, including updater correction `f891ece`
and the bounded closed-log auditor. All 308 bound source inputs remained exact
through closure. The original 1048-byte beacon FF and native executable were
unchanged. The prepared command and plan hashes are recorded in the
[sanitized Run 5 receipt](deployments/2026-10-12-sdk-beacon-run5.json).
An initial local wrapper precheck stopped before invoking Agent-Lab because its
vacancy helper was not imported; adding that existing import caused no source,
runtime or data mutation. Only one effective Agent-Lab invocation occurred.

Fresh full admission at 05:06:03 UTC allowed 12 GiB physical plus 12 GiB commit,
with Main alone, no lease, a vacant base client, free test ports and 66 independent
bank file identities. Run `20261012-050608-665-1158cf9d` staged all 84 provider files
(394,436,292 bytes) under the original lab-appdata transaction, then verified their
inventory and independent identities. Fresh logs show Aurora `patches.gsc` loaded
and its `main` executed; the missing Spaceland sound-table diagnostic is absent.
The provider inventory also matches after the run. No new retail patch, game
stock copy, Main deployment or project module was added.

The targeted scenario passes both real Uses with fresh engine protection and
private-server telemetry. The same entity 760 and instance 52650 survive the
controlled client restart. First Use produces team 1 / personal 1; the rejoined
client starts at team 1 / personal 0 and reaches team 2 / personal 1. Both release
and abort acknowledgements are retained. The exact cache survives while HTTP is
closed before rejoin. This is a controlled restart, not an in-process reconnect.
The original `Passed:true` result and scenario receipts remain unmodified.

After the processes closed, the integrated auditor read all six stdout/stderr
logs. The server's 83,252-byte stdout contains **two complete known unresolved
blocks, zero new blocks and zero incomplete blocks**: `init_cryobomb` at lines
81–85 and `init_forgefreeze` at 86–90. Both client logs and all stderr logs contain
zero blocks. The 219 new Run 4 blocks do not recur in this witness. This supports
the missing Aurora prerequisite correction without proving universal gameplay
or changing error allowances. Overall runtime integrity remains **not passed**:
the two existing errors remain errors under
[issue #150](https://github.com/maxis0191/iw7-paris-server/issues/150).

The launcher exits zero with restoration confirmed. At 05:10:09 UTC, Main retains
its exact process and executable identity; all three owned processes, test ports
and leases are absent. Four transaction manifests independently match the current
owned files/profile trees, including restoration of the candidate's absent private
appdata. Static Main checks pass and no Main bank delta is observed. Six native
BMPs plus logs total 22,238,271 bytes, below 128 MiB. Their hashes are retained;
`PixelsVerified:false`, reduced-graphics limits and owner acceptance remain unchanged.

Next: integrate this closed evidence into the central issue/PR record and continue
the separate issue 150 source investigation. No additional run is authorized by
the one-cycle Run 5 GO, and no global runtime or material acceptance is implied.
