> History (rules dated 2026-10-13 to 2026-10-16). Not current instructions. Current instructions: [AGENTS.md](../../AGENTS.md).

# AGENTS.md: the October 2026 rules, as they were

Below the line at the end of this header is the text that followed the first section of `AGENTS.md` at commit
`a60b864` (its lines 39 to 77), byte for byte. The first section ("Current workflow for every agent - owner rule
2026-11-10") was not touched and is still the first section of `AGENTS.md`.

Where each old rule went. "Safety n" is rule n of "Safety rules that never change" in the current `AGENTS.md`.

| Old rule (line of the old file) | Today | Place in the current AGENTS.md |
|---|---|---|
| Primary objective is deep control of the engine itself; BO3 is one use, not the ceiling (41-43) | still the aim; the tools for it now exist | first section, point 6; "What this repository is"; `docs/INDEX.md` |
| Follow the SDK's ENGINE-MODDING-STRATEGY.md and RE-TOOLS.md (43) | the route is now the dev kit and the index | "What this repository is" (where to look) |
| Execution orchestrator keeps worker reports; hourly strategic review (44-45) | no longer exists | none (history only) |
| Preserve specific stops, retired Rhino and the cancelled HUD showcase (45-46) | kept | Safety 12; "What needs the owner" |
| What the repository holds; other products own the rest (48) | kept | "What this repository is" |
| Classify the change by product; canonical owner only for declared exports (50-52) | kept | "What this repository is"; "How to work here" (exports) |
| Do not add server logic, another product's tree, game assets, binaries, symbols, credentials, player data, decompiled dumps (52-53) | kept | Safety 1; "What this repository is" |
| Extend an interface or dependency rather than copying (54) | kept | "What this repository is" |
| Keep author/license notices and exact upstream pins (55) | kept | Safety 2 |
| Never force-push history (55) | kept | Safety 3 |
| Preserve unrelated work, ignored evidence and frozen plans (57) | kept | Safety 7; "How to work here" (exact bytes, dated documents) |
| Historical results do not qualify relocated inputs (57-58) | kept | Safety 10 |
| Owner resumed authorized work on 2026-10-13; respect each task's scope (58-59) | superseded by the standing rules of 2026-11-10 | first section |
| Refactoring/source tests alone do not authorize game, server, extraction or deployment (59-60) | kept | Safety 4 |
| Main UDP 27016 stays protected (60) | kept, Canada added | Safety 4; first section, point 9 |
| Heavy native builds need complete shared resource admission (61) | kept | first section, point 4; "How to work here" (Build slot) |
| All fixed RAM/commit/headroom minima removed; estimates are telemetry only (61-64) | changed in part: since 2026-11-10 shareable live sessions are admitted by memory with a reserve; exclusive jobs stay telemetry only | Safety 8 points to `docs/RESOURCE-WORKFLOW.md`, which states both |
| Keep the account-wide lock, exact identities, ownership, leases, serialization, guarded teardown (64-65) | kept; serialization now applies to builds, extractions, analyses and exclusive Runtime leases, not to shareable sessions | Safety 8; first section, point 4 |
| Unknown identity / invalid telemetry requires diagnosis (65-66) | kept | Safety 8 |
| Never delete a holder's lease, adopt an occupied client or archive a live worktree (66-67) | kept | Safety 7 |
| On real exhaustion reduce the scenario or close only your own work; no new numeric barrier, RAM cleaner, arbitrary kill, oversized swap or kernel change (67-70) | kept, except that the memory admission of shareable sessions is a numeric rule decided on 2026-11-10 | Safety 8 |
| Read docs/RESOURCE-WORKFLOW.md for consumer pin routing (70) | kept; the pin is now stated in the index | Safety 8; "How to land"; `docs/INDEX.md` |
| Use coherent codex/* commits (72) | branches are `claude/<topic>` | "How to land" |
| Owner-private PRs, exact-head checks, merge commits (72-73) | kept; the check is the local run | "How to land" |
| Inspect actual CI jobs; only the account quota refusal is excepted; executed failures must be fixed (73-75) | superseded (owner rule 2026-11-10): GitHub's checks are ignored, the local `checks.ps1` run on the exact head is the judge; a failing local check must still be fixed | first section, point 9; "How to land" |
| Do not change visibility, billing, protection or credentials (75) | kept | Safety 2; "What needs the owner" |
| Return clean synchronized main; report source/build/runtime/owner validation separately (76-77) | kept | "How to land" |
| No upstream PRs (77) | changed: a contribution may be prepared here, but nothing is sent to the public project without the owner | "What needs the owner" |
| No automatic Codex memory changes (77) | not carried over (it concerned the automatic memory of the Codex tool) | none (history only) |

Rules that were not in the old file and are in the current one: private test servers (Safety 5), owner-only
console keys (Safety 9), voice not accepted (Safety 11), game instances started by another application (Safety 7),
"Tool first" (owner rule 2026-11-10, "How to work here"), nothing sent to the public game-client project without
the owner.

---

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
