# Agent capabilities and the next engine investigation

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
