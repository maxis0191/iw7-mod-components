## Current workflow for every agent - owner rule 2026-11-10

This section replaces older test, build and delegation instructions wherever they differ (they are kept below
as history). The owner's keys: best quality, speed, light weight, total efficiency. A result is a measured run,
never a prediction.

Start here, in the server repository (iw7-paris-server): `docs/DEVKIT.md` says which tool answers which question; `docs/TOOLS-INDEX.md` (when it lands) lists every tool on every branch, merged or not; `docs/DEVKIT-PLAN.md` lists what exists, the holes and the open work; `docs/QUALITY-OBSERVATORY.md` says how problems are found without the owner.

1. Check the files first. Before any build or launch run the file checks for your kind of content (weapon audits
   and mod preflight for weapons; `iwz_emitcheck.py check|diff|route|at` for a map source; the build-log gate and
   the loader readback after a build). A build or a launch made to learn what a file check can say is waste.
2. Never copy the game, and never test in the owner's game folder. Make a bench root (`ops/bench/New-BenchRoot.ps1`,
   2 seconds, hard links); remove it only with `ops/bench/Remove-BenchRoot.ps1 -RunFiles`.
3. Test without a game client whenever no screen is needed: `ops/gamelab/Invoke-GameLabHeadless.ps1` runs a test
   plan on a private server with a bot in about 40 seconds and 1.1 GB. Use a client plan
   (`ops/gamelab/Invoke-GameLab.ps1`) only for frames, frame rate or key presses. One plan answers many questions;
   write expectations; the exit code is the verdict.
4. Sessions queue themselves: pass `-WaitForSlotSeconds`; never write retry loops; never stop a game process you
   did not start; never touch a game instance another application started. The scheduler admits sessions by free
   memory, several at once; builds stay exclusive.
5. Need a lab client: `ops/enginelab/Get-LabClient.ps1`. Changed native code: `ops/enginelab/Invoke-EngineLab.ps1`
   (commit, build in about 70 seconds, plans, verdict).
6. Engine questions: the engine map (what is at an address, who calls it, which function mentions a text, console
   variables), the memory watch (where the game keeps a value), the performance recorder with `iw7_perf.py`
   (frame rate and the functions that cost the time; a change under about 5 % needs three runs a side), the freeze
   reporter, the crash reader. All in iw7-mod-components `ops/engine-map` and its `docs/`.
7. Network questions: `ops/netlab/Invoke-NetLab.ps1` (chosen ping, jitter and loss; key-to-server time).
   Long runs: `ops/soak/Invoke-Soak.ps1`. Every place of a map: `ops/atlas/atlas.py` with the `survey` step.
8. Problems go into the ledger (`ops/quality/ledger.py`), not only into a chat; read its `list` before starting.
9. Landing: the local `checks.ps1` run on the exact head is the judge; GitHub's own checks do not run. Do not run
   a live session while a check run is in progress (some checks need the build slot). Nothing is deployed to
   players without the owner, then to both public servers.
10. Delegation in Claude Code sessions (owner, 2026-11-10): the most capable model designs, writes precise briefs,
    reviews and makes or validates the live proofs; Sonnet subagents write code, tests and documents and land
    branches; Opus for the hardest pieces. Briefs name exact paths, commands, limits and what proves the work.

Older lines this replaces: testing in the owner's base game folder; one heavy session on the whole machine;
waiting for GitHub checks; per-test game copies; launching once per question.
# Product ownership

Owner correction, 2026-10-16: the primary objective is deep, reusable control of
IW7's own engine and rules. BO3 is an optional use case, not a prerequisite or
ceiling. Follow the SDK's ENGINE-MODDING-STRATEGY.md and this product's RE-TOOLS.md.
The execution orchestrator keeps worker reports and resource sequencing;
hourly strategic review is not an extra routine approval gate. Preserve specific
stops, retired Rhino and the cancelled HUD showcase.

Private engine/client components, voice protocol, native diagnostics, scoped test hooks and shared process/resource helpers. Server gameplay rules and asset serializers have other owners.

Before editing, classify the change by product and inspect `product.json`,
README.md and the migration map. This repository is the canonical owner only
for its declared exports. Do not add server logic, another product's full tree,
game assets, binaries, symbols, credentials, player data or decompiled dumps.
Extend an explicit interface/dependency rather than copying implementations.
Keep author/license notices and exact upstream pins. Never force-push history.

Preserve unrelated work, ignored evidence and frozen plans. Historical results
do not qualify relocated input identities. The owner resumed authorized IW7 work
on 2026-10-13; respect each task's scope. Refactoring/source tests alone do not
authorize game, server, extraction or deployment. Main UDP27016 stays protected.
Heavy native builds need complete shared resource admission. Owner update
2026-10-13 removes all fixed RAM/commit/headroom minima, projected-memory
refusals and percentage stop thresholds. Estimates and fresh native snapshots
are telemetry only; keep the account-wide lock, exact process identities,
ownership, leases, heavy-workload serialization and guarded teardown. Unknown
identity/invalid telemetry still requires diagnosis. Never delete a holder's
lease, adopt an occupied client or archive a live worktree. If actual exhaustion
is observed, reduce the valid scenario or close only your own identified work;
do not substitute a new numeric barrier, RAM cleaner, arbitrary kill, oversized
swap or kernel change. Read docs/RESOURCE-WORKFLOW.md for consumer pin routing.

Use coherent codex/* commits, owner-private PRs, exact-head checks and merge
commits. Inspect actual CI jobs. Only the existing account quota refusal before
any runner/step has the owner's conditional exception; executed failures must
be fixed. Do not change visibility, billing, protection or credentials.
Return clean synchronized main; report source/build/runtime/owner validation
separately. No upstream PRs or automatic Codex memory changes.
