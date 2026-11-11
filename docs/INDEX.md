# Index: where things are in iw7-mod-components

One line per entry. Rules for agents are in `AGENTS.md`; the list of every tool of every product is in the
server repository (`docs/DEVKIT.md`, `docs/TOOLS-INDEX.md`). Paths are relative to this repository.

## 1. I have a question about the engine

| Question | Tool | Document | Source test |
|---|---|---|---|
| What is at an address, who calls it, which function mentions a text, console variables | `ops/engine-map/iw7_engine_map.py` | [ENGINE-MAP.md](ENGINE-MAP.md) | `tests/ops/engine_map_test.py`, `tests/ops/engine_map_names_test.py` |
| Where does the game keep a value | `ops/engine-map/iw7_watch.py` with `src/native/paris_watch.cpp`, `paris_watch.hpp` | [MEMORY-WATCH.md](MEMORY-WATCH.md) | `tests/ops/memory_watch_test.py` |
| Frame rate, and which functions cost the time | `ops/engine-map/iw7_perf.py` with `src/native/paris_perf.cpp` | [PERF.md](PERF.md) | `tests/ops/perf_window_test.py` |
| A freeze | `ops/engine-map/iw7_hang.py` with `src/native/paris_hang.cpp` | [HANG.md](HANG.md) | `tests/ops/hang_report_test.py` |
| A crash | `ops/engine-map/iw7_crash.py` with `src/native/paris_stack.hpp` | [CRASH.md](CRASH.md) | `tests/ops/crash_stack_test.py` |
| Network update timing | `ops/engine-map/iw7_net.py` with `src/native/paris_net.cpp` | [NET.md](NET.md) | `tests/ops/net_report_test.py` |
| Change the live world of a lab client | `ops/engine-map/iw7_world_live.py` with `src/native/paris_world.cpp` | [WORLD-LIVE.md](WORLD-LIVE.md) | `tests/ops/world_live_test.py` |
| What is on the screen, as data: which UI elements, where, how big, which text, visible or not; defects with no picture | `ops/engine-map/iw7_ui.py` with `src/native/paris_ui.cpp` | [UI-DUMP.md](UI-DUMP.md) | `tests/ops/ui_dump_test.py` |
| Is a capture valid, did two frames differ | `ops/iw7_frame_evidence.py` | [FRAME-EVIDENCE.md](FRAME-EVIDENCE.md) | `tests/ops/iw7_frame_evidence_test.py` |
| What does a captured frame show, as data: the camera and the depth of the frame | `src/native/paris_see.cpp`; the tool is the creator SDK's `tools-source/worldkit/iw7_see.py` | [SEE.md](SEE.md) | in the creator SDK: `tools-source/worldkit/tests/test_see.py` |
| Ghidra project, scoped reads | `ops/Install-ReTools.ps1`, `ops/re-tools/` | [RE-TOOLS.md](RE-TOOLS.md) | `tests/ops/re_tools_sdk_test.py` (retained check: needs the Python environment made by `ops/Install-ReTools.ps1`) |

The Python readers are covered by source tests. The native side of these tools (`paris_perf.cpp`, `paris_net.cpp`,
`paris_hang.cpp`, `paris_world.cpp`, `paris_see.cpp`, `paris_stack.hpp`, `paris_lab_properties.cpp`, `paris_debugger.cpp`) has no
source test of its own: it is proven by live runs in the server repository's engine lab.

## 2. I need to run or build

| Need | Where |
|---|---|
| Scheduler and leases (who may run what, and when) | [RESOURCE-WORKFLOW.md](RESOURCE-WORKFLOW.md), read "Shareable runtime leases" first. Code: `ops/Resource-Scheduler.Core.ps1`, `ops/Resource-Scheduler.ps1` |
| Native build, every profile | `ops/Build-Voice.ps1` (historic name: it is the native build entry for all profiles, not only voice) |
| Supervised sessions, incident stream, captures | [DEBUGGER.md](DEBUGGER.md) from "Entry points". Code: `ops/Debug-Server.ps1`, `ops/Debug-Session.ps1`, `ops/iw7_debugger.py`, `ops/iw7_watch.py`, `ops/iw7_capture.py` |
| Standard client build and Aurora updates | [STANDARD-CLIENT-UPDATE.md](STANDARD-CLIENT-UPDATE.md), `client-profiles.json`, `ops/Build-StandardClient.ps1`, `ops/standard-client/` |
| Private test server overlay (password, LAN only, no master heartbeat) | `ops/Apply-TestPrivacyOverlay.ps1`, `src/native/paris_test_safety.hpp`, `tests/ops/test_privacy_overlay_test.ps1` |
| Source workspace and the local judge | `bootstrap.ps1`, `checks.ps1`, `checks.json`, `ops/source_workspace.py`, `ops/check_boundaries.py`, `ops/check_product.py` |
| Test and land a change | Commands and prerequisites: `README.md`, "Run the local judge". When a run counts as a pass and when to merge: `AGENTS.md`, "How to land". What never to do (assets, keys, Main and Canada, the owner's game folder, leases): `AGENTS.md`, "Safety rules that never change" |
| Native C++ unit tests | `tests/native/`, compiled and run by `ops/Build-Voice.ps1 -TestsOnly`; in the judge as `native_unit_tests` (`tests/ops/native_unit_tests.ps1`, about 40 s, takes the Build slot) |

## 3. Voice

| Subject | Where |
|---|---|
| Status, design, build | [VOICE.md](VOICE.md). Voice is not accepted: it has not been heard working in game |
| Certification harness | [VOICE-CERTIFY.md](VOICE-CERTIFY.md), `ops/voice-certify/`, `tests/voice-certify/` |
| The relay itself | `ops/voice-relay/0001-Relay-voice-chat-through-the-server.patch` (exact bytes are pinned; never edit), applied only by `ops/Build-Voice.ps1 -VoiceRelay` through `ops/Voice-RelayOverlay.Core.ps1` |
| Kept from the retired relay's analysis | `ops/Invoke-VoiceAnalysis.ps1`, `ops/ghidra/voice-functions.csv` (may serve the new relay's address checks) |

## 4. Shipped features owned here

[OWNER-CHEATS.md](OWNER-CHEATS.md) (owner-only native console), [CUTSCENE-VOTE.md](CUTSCENE-VOTE.md),
[PLAYERS8.md](PLAYERS8.md), [AGENT-OFFHAND.md](AGENT-OFFHAND.md), [STOCK-LINKS.md](STOCK-LINKS.md).

## 5. Name trap: two tools called iw7_watch.py

- `ops/iw7_watch.py` is the live incident stream of the debugger. The server verifies it by length and hash; it
  keeps its name and its bytes.
- `ops/engine-map/iw7_watch.py` is the memory watch reader.

They are different tools. Always write the folder.

## 6. Paths other products take

Three other products take files from this repository by exact path, listed in the `dependencies` of their own
`product.json`:

| Consumer | Paths taken | Of which no longer on `main` |
|---|---|---|
| iw7-paris-server | 181 | 63 |
| x64-zt-extensions | 120 | 60 |
| iw7-creator-sdk | 26 | 3 |

- The paths are under `ops/` (root), `ops/native/`, `ops/agent-capacity/`, `ops/standard-client/`,
  `ops/voice-agent/`, `src/native/`, `tests/native/`, `tests/ops/`, `client-profiles.json` and eleven `docs/`
  paths. None is under `ops/engine-map/`, `ops/voice-certify/`, `ops/re-tools/` or `tools-source/`.
- **Do not rename or move these paths** without changing the consumer in the same piece of work.
- **The consumers do not take `main`.** They pin the branch `pin/server-447c1ad-shareable` (commit `9a3d30b`:
  `447c1ad` plus three scheduler commits). That branch is not an ancestor of `main`, and must never be deleted or
  rewritten. The paths "no longer on main" are the old voice relay, retired from `main` on 2026-11-09. The
  scheduler changes of 2026-11-10 for shareable leases exist on both lines.
- So nothing landed on `main` changes what the consumers or the public servers use today. Moving the consumers to
  `main` is separate work with its own verification on the deployment side; it is not done by editing this
  repository.
- Verified from outside by exact bytes: `ops/iw7_watch.py` (server), the dependency archive named in
  `dependency-package.json`, `ops/voice-relay/*.patch`, `tools-source/community-download/` (own manifest and
  receipts).

## 7. Kept, with no check of their own

| File | Note |
|---|---|
| `ops/RenderDoc-Capture.py` | last used October 2026; called by nothing; no check |
| `ops/Get-ServerInfo.ps1`, `ops/Get-SourceIdentity.ps1` | helpers called by other scripts here; no check of their own |
| `ops/RenderDoc-Fixture.py`, `ops/Send-ServerCommand.py`, `ops/Install-ReTools.ps1` | run by hand (named only by documents: `VOICE.md`, `COLLISION-PROVIDER.md`, `RE-TOOLS.md`); called by no script; no check |
| `ops/New-OwnerCheatsKit.ps1` | makes key files; the judge runs it only inside `tests/ops/owner_cheats_test.ps1`, in a scratch folder. Never add a check that prints or makes real keys |
| `ops/Test-CollisionProvider.ps1` | the only caller of `tests/native/collision_provider_test.cpp` outside the native build |
| `ops/Package-CapacityClient.ps1`, `ops/agent-capacity/Smoke-Normal.ps1`, `config/Launch-IW7-Paris48.bat` | capacity 48/64 effort (October 2026), still the subject of open pull requests |
| `ops/voice-agent/Recorder-Probe.cs` | last file of a retired folder; used by `ops/Resource-RecorderOwnedProcess.Core.ps1` and its test |
| `tools-source/community-download/` | self-contained harness; its tests run through its own `Harness.ps1` and `run_tests.py`, not through `checks.json` |
| `ops/agent-capacity/inventory.json`, `ops/agent-capacity/recipe.json` | frozen plans taken by the server by path; they contain machine paths of the day they were made and are not edited |
| `src/ui_scripts/bo3_zombies_hud/`, `ops/Test-BO3HUDSource.ps1`, `ops/raygun/` | October prototypes; their source checks still pass |

## 8. History

Dated documents are records, not instructions. A document was left in place when another product names its path
or an open pull request edits it; it then starts with a line saying it is history.

Archived in `docs/archive/`:

| Document | What it records |
|---|---|
| `AUTHOR-PLATFORM-CONTACT.md` | source adapter for author platform contact, October 2026 |
| `RETAINED-WORK-INTEGRATION.md` | how retained October work was integrated after the extraction |
| `RUNTIME-PROBE-DESIGN.md` | a proposal, never built; see MEMORY-WATCH and WORLD-LIVE |
| `DIA-PROVIDER-QUALIFICATION.md`, `SOURCE-GUARD-ROOT-CANDIDATE.md` | plan and candidate of the refused debugger symbol-provider qualification |
| `IW7-NEUTRAL-CLONE.md` | neutral clone source profile of the Ray Gun prototype |
| `DEBUGGER-CLIENT018-2026-10.md` | journal of the refused Client018 / symbol-provider attempts, cut from `DEBUGGER.md` |
| `RESOURCE-WORKFLOW-HISTORY-2026-10.md` | October policy prose, validation and rollout records, cut from `RESOURCE-WORKFLOW.md` |
| `VOICE-HISTORY-2026-10.md` | history of the retired relay and its evidence index, cut from `VOICE.md` |
| `README-2026-10.md` | the README as it was until 2026-11-10 |
| `AGENTS-HISTORY-2026-10.md` | the October rules of `AGENTS.md`, with a table saying what replaced each |

History left in place in `docs/`: `AGENT-CAPACITY.md` (in French), `MODDING-ENGINE-RE.md`,
`AURORA-OCTOBER-UPDATE.md`, `BO3-ZOMBIES-HUD.md`, `RAYGUN-WEAPON.md`, `COLLISION-PROVIDER.md`,
`COLLISION-PLAYER-CONTACT.md`. Evidence files (`docs/evidence/*.json`,
`docs/agent-capacity-qualification-20261019.json`) and `migration/` (provenance of the extraction from the server
repository) are never edited.
