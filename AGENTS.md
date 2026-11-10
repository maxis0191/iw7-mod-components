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

## What this repository is

- The private native side of the IW7 products: engine and client components, the scheduler that admits sessions
  and builds, the tools that answer engine questions (`ops/engine-map`), the debugger, the voice relay patch and
  its certification harness, scoped test hooks.
- It owns exactly the paths in `product.json` `exports`. Server gameplay rules live in iw7-paris-server, asset
  serializers in x64-zt-extensions, creator tooling in iw7-creator-sdk. Extend an interface or a dependency;
  never copy another product's tree or put server gameplay logic here.
- Where to look: `docs/INDEX.md` (this repository), then the server's `docs/DEVKIT.md`.
- Read `origin/main` from your own worktree. The main checkout on the working machine can be many commits
  behind; never take its files as the current state, and never change it for a task.

## Safety rules that never change

1. Never add to this repository: game assets, binaries, symbols or PDBs, credentials, private keys, player data,
   bank data, decompiled game dumps, another product's full tree.
2. Keep author and license notices and the exact upstream pins. The repository is private; nothing private goes
   into a public fork. Do not change visibility, billing, branch protection or credentials.
3. Never force-push, never rewrite published history; merge with merge commits.
4. Main (UDP 27016) and Canada are never a test target. Nothing reaches players without the owner's approval,
   and then it goes to both servers. A refactor, a passing source check or a merge authorizes no game, server,
   extraction or deployment action.
5. Every test server is private: a non-empty random `g_password`, `sv_lanOnly 1` set at launch before any
   heartbeat, bound to loopback by default, on a native test build that suppresses the master heartbeat; verify
   this before a client connects. `sv_cheats` stays 0. Implemented here by `ops/Apply-TestPrivacyOverlay.ps1`
   and `src/native/paris_test_safety.hpp`.
6. Never copy the game and never test in the owner's game folder: bench roots only, removed only with the bench
   remover (point 2 of the first section).
7. Other sessions' work is not yours: never stop a game process you did not start; never touch a game instance
   another application started; never delete another holder's lease; never adopt an occupied client; never
   archive or remove a live worktree. Preserve unrelated work, ignored evidence and frozen plans.
8. Queue through the scheduler (`-WaitForSlotSeconds`), no retry loops. Establish exact process identity and
   ownership before any teardown, and close only your own identified processes. On real memory exhaustion reduce
   the scenario: no RAM cleaner, arbitrary process kill, oversized swap or kernel change. An unknown identity or
   invalid telemetry is diagnosed, not worked around. The rule itself is `docs/RESOURCE-WORKFLOW.md`.
9. Owner-only console access (`docs/OWNER-CHEATS.md`): the owner and server trust files and private keys are
   never regenerated, published, copied to other players, printed or removed. A native update must not silently
   drop the owner capability. Admin chat commands and an extra `sv_cheats` lock were cancelled by the owner and
   are not reintroduced.
10. A result is a measured run, never a prediction. A historical result does not qualify moved or rebuilt
    inputs; an old runtime receipt is never reused for new inputs; a failed result stays recorded as failed.
11. Voice is not accepted: never claim that speech works in game until the owner has heard it
    (`docs/VOICE.md`, status).
12. Retired, not to be resumed without the owner: Spaceland Rhino, the old voice relay, the cancelled HUD
    showcase.

## How to work here

- Tool first. Real work in the game is also the test of the tools. Whenever a tool, the workflow or the environment is seen to be slow, unoptimized, buggy or blind, or a new tool would be a real jump, fix or build that FIRST, prove it with a measured run, document it, then return to the job. Never grind: the same build or launch repeated more than about three times for one question, a cause that is guessed instead of read from data, minutes of waiting for what a file check answers in seconds, a result judged by looking at a picture, a manual step done twice: each of these means stop and improve the tool.
  (Owner rule, 2026-11-10.)
- Edit the canonical tracked file; never a generated source workspace (`runtime/...`).
- Every tracked file is declared in `product.json` `exports`; the ownership gate refuses the rest. A new tool
  comes with its test, its `checks.json` entry, its document and a line in `docs/INDEX.md`. A check that needs a
  tool absent from the working machine goes under `retained_checks` with the reason; a real test is never
  deleted or made to "skip and pass" to hide a failure.
- Paths taken by other products (`docs/INDEX.md`, "Paths other products take") are not renamed or moved without
  changing the consumer in the same piece of work. `ops/iw7_watch.py`, `ops/voice-relay/*.patch`,
  `tools-source/community-download/`, the frozen plans in `ops/agent-capacity/`, `docs/evidence/` and
  `migration/` keep their exact bytes.
- Native build entry: `ops/Build-Voice.ps1` (historic name; it builds every native profile).
- Builds are exclusive and take the Build slot; do not start a live session during a check run.
- Dated documents are records. Do not edit them to make them current; write the current fact in the living
  document and leave the record as it was.

## How to land

- Branch `claude/<topic>`, coherent commits, private pull request. Preserve failed approaches and reverts.
- Judge: `./bootstrap.ps1 -Output runtime/<short>`, then `./checks.ps1 -Workspace runtime/<short>`, once per
  head, in the background. Post the result on the pull request, merge with a merge commit, return to a clean
  `main`. `./checks.ps1 -Workspace runtime/<short> -Only <id>` re-runs one check after a fix; the head is still
  judged by a full run.
- GitHub's own checks are ignored: they do not start, and their workflow runs only when asked by hand.
- Report source, build, live run and owner acceptance separately.
- Consumers adopt a change only by moving their pin and regenerating their source inputs. They pin a branch
  that is not `main` (`docs/INDEX.md`); that branch is never deleted or rewritten.

## What needs the owner

- Anything deployed to players (Main and Canada): owner approval first, then both servers.
- Repository visibility, billing, branch protection, credentials.
- Public distribution or licensing of private code.
- Anything sent to the public game-client project (upstream IW7-Mod): nothing is sent to that project, no issue,
  no pull request and no message, without the owner. A contribution is prepared and proven here, following the
  Aurora pull request rules, and waits for his decision.
- Resuming a retired effort (rule 12), admin chat commands, an extra `sv_cheats` lock.

## History

Older rules and their dates are in `docs/archive/AGENTS-HISTORY-2026-10.md`, with a table saying what replaced
each. They are not instructions.
