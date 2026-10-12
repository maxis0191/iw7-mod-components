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

The completed vertical does not yet exist. `Agent-Lab` currently selects model
or HUD fixtures exclusively; model mode accepts only wait/capture. The actions
observer proves a Use bit, and its first-client intro readiness is not a general
late-join observer. Concatenating their PASS strings would manufacture evidence.

After the parent integrates the asset/package work, use one existing candidate,
one base client and one small versioned package. Keep the previously visible rigid
cube as a control beside the new licensed/source-owned asset. Bind one real usable
trigger to the exact imported entity and show that package's version in the HUD.

1. Require fresh cache/download hash, DB/fixture readiness, native protection,
   and a fresh frame. Inspect the new asset and control at two fixed fixture poses.
2. Observe an initially released Use, publish bounded ordinary Use, require its
   release ACK and a *target-owned retail interaction* tied to the exact entity,
   player and generation. Observe the resulting HUD state and inspect its pixels.
3. Disconnect/rejoin sequentially through the existing owned lifecycle. Require
   the same package hash/version, a fresh playable/protected generation, exactly
   one UI/trigger owner, retained expected state and no duplicate callback. Repeat
   a single interaction and capture; then restore original files and release.

The missing work is that thin joint observer plus a rejoin readiness predicate,
not a new native input stack. Do not force the stock intro flags or count a Use
ACK as interaction. A first bounded run can omit rejoin and explicitly report
only the first two stages; full vertical acceptance still requires stage 3.
Current package requirement (`ServerModules` + `IsolatedLab` + `Debugger` source
manifest) remains even for `-Debugger:$false` runtime input-only mode.

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

Only `ops/modding/Agent-Capabilities*` and this document belong to this change.
The parent integrates the coherent local commit, updates shared STATE/BUGS/
CHANGELOG/VALIDATION/PLAN once, and coordinates private PR/exact-head CI/merge.
No runtime or Main promotion is part of this delivery. Next action is integration
of the recovered PASS evidence and the small joint vertical observer; the 48
startup attribution remains a separate, centrally admitted experiment.
