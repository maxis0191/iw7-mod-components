> History (dated 2026-10-04 to 2026-10-13). Not current instructions. Current entry point: [docs/INDEX.md](../INDEX.md).

# Resource workflow: October 2026 policy text and rollout records

Cut from `docs/RESOURCE-WORKFLOW.md` as it was at commit `a60b864`, unchanged except that relative links were
adjusted to this folder and the first two parts, which had no heading of their own, were given one. Four
parts, in their original order: the opening policy prose, the dated source
validation record that opened "Admission, ownership and lifecycle", "Codex auxiliary-process overhead", and
"Durable project context and rollout". The current rule is in [RESOURCE-WORKFLOW.md](../RESOURCE-WORKFLOW.md).
What changed since: live sessions on bench roots are admitted by memory, several at once (2026-11-10); the
judge of a head is the local `checks.ps1` run, not a hosted CI job; tests no longer use the owner's game folder.

## Part 1 - opening policy prose (owner update of 2026-10-13)

Owner update, 2026-10-13: skip all RAM/commit/headroom minima and fixed estimated
memory ceilings that prevent authorized E2E tests. No estimate-versus-available
comparison, commit reserve or memory-use percentage may refuse admission or
stop a scenario. This supersedes the former 25%/4 GiB RAM reserve, 20%/4 GiB
commit reserve, 80%/85% stop thresholds and dated workload minima. Other fixed
1 GiB/10 GiB/4 GiB allocation policies are not permission to defer an authorized
test; their implementation belongs to their own consumer, outside this scheduler.

Fresh RAM/commit and process telemetry remains required, along with the atomic
lock, lease ownership, exact identities, one heavy workload group (except shareable
runtime leases admitted by memory, see below) and guarded teardown. Missing/impossible telemetry and unknown identities require diagnosis;
they are not a memory-capacity refusal. Successful admission does not establish
safe unlimited allocation. On observed real exhaustion, reduce the valid scenario
or close only its own identified processes. Do not replace the removed policy
with another numeric barrier, RAM cleaner, arbitrary process kill, oversized
swap or kernel changes. Preserve Main27016, banks/config and occupied clients.

The canonical implementation is now private
[iw7-mod-components](https://github.com/maxis0191/iw7-mod-components).
Consumers must advance their explicit product dependency pin and regenerate a
verified source package before using this policy. Do not edit generated inputs
or silently repin a frozen plan/receipt. The compatibility fields `Allowed=true`,
`PhysicalReserve=0`, `CommitReserve=0`, `HighWater=false` apply to valid telemetry;
`Policy=TelemetryOnly` identifies this decision. `Memory-Budget.ps1` uses the
same policy through its legacy assertion API, and `Lab-AssetProcess.ps1` observes
fresh telemetry without a percentage stop. Timeouts, original creation handles,
registration failure, confirmed teardown and quarantine are preserved. No other
export/artifact guard is changed by this resource policy update.

Current instance policy (2026-10-06): use the base game client for ordinary
in-game and sequential A/B tests; stage server changes on a separate test dedicated.
Client clones require a concrete necessity or risk. Instance workflow (`docs/INSTANCE-WORKFLOW.md`, server repository)
supersedes older systematic client-copy requirements and launch recipes below.
Dated test results remain historical evidence.

Agents may develop, review and run light tests in parallel. Preserve the account-wide
**one heavy workload group at a time** policy, except shareable runtime
leases, admitted by memory ([Shareable runtime leases](../RESOURCE-WORKFLOW.md#shareable-runtime-leases---2026-11-10)):
one isolated gameplay scenario (server and its explicitly declared client(s)),
one native build, one asset extraction, or one reverse-engineering analysis.
Each chat keeps its own sources, files and test identity. A private desktop or a
Git worktree does not supply additional RAM, VRAM or CPU capacity.

The owner explicitly authorizes implementation, necessary tools and coordination
between the current IW7 chats. This does not turn estimated capacity into a
guarantee of unlimited simultaneous games. Additional applications and game
allocation spikes can still exhaust a machine. No performance acceptance is
inferred from successful source tests or a short resource observation.

## Part 2 - source validation record of 2026-10-13

2026-10-13 source validation: resource scheduler, memory assertion, real owned
asset-process and native memory suites pass. Synthetic zero RAM/commit headroom
and estimates greater than machine totals are admitted without allocating that
memory. Fresh re-entry observations persist, while a competing holder, unknown
launcher/child identity, malformed state and unavailable telemetry still refuse.
The real two-process admission race has one winner, PID reuse stays safe and
orphan/failed-job teardown remains guarded. A real small PowerShell child runs
to exit zero despite the old high-water signal; registration, timeout and
telemetry failures still confirm its closure. The native ABI and 100 actual
GetPerformanceInfo reads pass. These are source/process lifecycle tests; no
game, retail extraction, Main deployment or owner gameplay is claimed.

The composed candidate's 46 declared source groups are locally qualified: 45
passed in the complete run, then the final Java resolver group passed after
using the existing portable JDK21 on the command-local PATH. The initial Java
invocation did not start (WinError2); its failure log is retained. The rerun
acquired/released the shared lease and exited zero. CLI Status/Measure also
retained fresh native samples with the new policy. Exact-head CI is recorded in
the linked PR; a job with runner_id=0 and no steps is unexecuted, never a pass.

### Codex auxiliary-process overhead

A grouped live inventory also found 70 `node.exe` processes totaling about
3.9 GiB working set, including repeated three-process chrome-devtools MCP stacks
(npx, wrapper, server). A later sample identified 30 chrome-devtools Node processes
at 1.619 GiB resident/2.682 GiB private commit and 20 legacy `node_repl.exe` helpers
at 0.235 GiB resident. Counts changed as other agents completed; these are snapshots,
not a leak diagnosis or a guaranteed amount reclaimable immediately.

The versioned `.codex/config.toml` disables only the two legacy custom MCP IDs
`chrome-devtools` and `node_repl` for this trusted IW7 project. The app's bundled
`cua_repl`, native telemetry, browser tools and other projects remain available.
The actual installed Codex CLI, run from this worktree, reports `enabled=false`
for both via `mcp get --json`; user-level configuration was not edited.
Official [MCP configuration](https://learn.chatgpt.com/docs/extend/mcp) supports
`enabled=false`, and [project overrides](https://learn.chatgpt.com/docs/config-file/config-advanced)
are loaded only for trusted projects. This removes avoidable startup duplication
when the configuration is loaded by later chats/agents. Existing app-owned
connections are not killed or claimed reclaimed. A new/reloaded session must
confirm the effective config; do not interrupt active work by restarting the app.
If a specific task requires either legacy tool, use an explicit temporary
configuration override and account for its footprint; do not re-enable it globally.

The 2026-10-04 read-only inventory found 31.80 GiB visible RAM (2x16 GiB DDR4-3200),
i5-13400F (10 cores/16 logical processors), RTX 3080 with 10,240 MiB VRAM, and a
system-managed 18 GiB pagefile. Its observed peak usage was 14,617 MiB; that is a
historical high-water observation, not attribution to an individual test.
The active plan was Bitsum Highest Performance. No power plan, driver, memory
compression, service, firewall, owner graphics setting or kernel setting was changed.

Working set is resident memory; private bytes are commit, with different accounting
and sharing. Microsoft's [memory counter mapping](https://learn.microsoft.com/en-us/windows/win32/memory/memory-performance-information)
explains the distinction. [EmptyWorkingSet](https://learn.microsoft.com/en-us/windows/win32/api/psapi/nf-psapi-emptyworkingset)
evicts resident pages; it is not a release of allocations. Do not run RAM cleaners,
periodic trims, standby-list purges or suspension as a fake capacity increase.

The [pagefile extends the commit limit](https://learn.microsoft.com/en-us/troubleshoot/windows-client/performance/introduction-to-the-page-file)
but does not make SSD access as fast as RAM. Leave it system-managed here. Free
disk was about 34.9 GiB during this inventory: do not make another 84 GiB stock
copy on this volume. Inventory and reuse an existing suitable test dedicated;
a new chat/worktree does not justify another snapshot. Follow
`docs/STORAGE-WORKFLOW.md` (server repository) for retained and retired stock. At that
original checkpoint, lab server/client roots linked only their internal read-only
stock copy. The 2026-10-06 inventory records two candidate dedicateds also using
their retained parent lab's stock, with separate mutable state.
Global cache deduplication would need manifests, immutable content and ownership
verification before changing hardlinks; deleting other active chats' assets is
not an optimization. Preserve banks, matching PDBs and crash evidence.

CPU affinity, EcoQoS, timer/HPET changes, disabled security, GPU driver replacement,
forced low memory caps and VM/GPU virtualization have no measured benefit for this
incident. They can change timing or crash behavior and were not applied. Low build
priority and bounded compiler concurrency address known avoidable interference.
GPU use is monitored, not reserved by a validated VRAM allocator; one scenario
and capped functional rendering limit contention without proving frametime safety.

The pinned local IW7-Mod dedicated implementation already bypasses its render
thread, DirectX/UI setup, texture imagefile loading and transient graphics loads.
Adding a second unverified "headless" patch is not supported by this finding.
The meaningful next reduction is avoiding unnecessary rendering clients and
whole donor asset loads. A later read-only Windows sample found about 1.01 GiB
nonpaged pool, 1.16 GiB paged pool, 10.43 GiB normal-priority standby cache and
0.19 GiB modified pages. These single values do not diagnose a kernel leak.
Standby pages are reusable; purging them is not a demonstrated throughput gain.

```powershell
./ops/Resource-Scheduler.ps1 -Action Measure -Seconds 30
```

This bounded observer writes ignored JSONL with RAM/commit, paging, CPU, disk
queue, selected process footprints and optional NVIDIA VRAM/utilization readings.
It also records aggregate Node and legacy REPL process counts, working sets and
private bytes so a later normal session can measure the MCP change. Those totals
include other projects and shared resident pages; they are not immediately
reclaimable-memory estimates. No auxiliary process is terminated by the observer.
No passwords/command lines are recorded. Windows CIM and installed `nvidia-smi`
are sufficient; no new driver or resident optimizer is needed. `wpr.exe` is
available if a reproducible residual stall needs ETW analysis. Missing optional
GPU telemetry is recorded; missing RAM/commit telemetry refuses admission.

For substantial additional real simultaneous rendering, use another authorized
Windows/GPU machine with its own legitimate assets and run the same bounded
protocol there, or expand hardware after measuring the desired workload. Neither
cloud provisioning, hardware purchase nor remote-agent setup happened here.

## Durable project context and rollout

The private [iw7-paris-server repository](https://github.com/maxis0191/iw7-paris-server)
owns server integration decisions/evidence. Each split product owns its source;
the scheduler and this policy belong to iw7-mod-components. The older central
index wording below is superseded by the 2026-10-13 product migration. Public owner forks
[iw7-mod](https://github.com/bigmangeekf/iw7-mod) and
[x64-zt](https://github.com/bigmangeekf/x64-zt) contain only suitable generic source
contributions. No private project config, proprietary assets or credentials may
be copied there. Existing visibility was verified; no repository visibility changed.

Local Git worktrees contain candidates and ignored tools/runtime evidence. Main
and GitHub retain reviewed source, versioned tests, current decisions and sanitized
validation. Follow GIT-WORKFLOW.md: coherent commits, private PR, final diff review,
successful CI for the exact head, merge commit and clean synchronized main in its
existing checkout. Do not reset the dirty original checkout owned by another chat.

The historical primary checkout received an additive AGENTS routing notice
to fetch/read the current main workflow and use its isolated worktree's reviewed
helpers. Its complete previous instruction text was backed up under ignored
runtime and verified as the unchanged suffix. Its pre-existing source changes
remain uncommitted there; they were not staged into this resource PR or reset.
The exact merged project `.codex/config.toml` was also copied into its previously
absent project-config path (SHA-256
`71B7DD7730EA72194FBB20D7EA92B93B6F2362AE8AD630186F4FE98396E8C216`).
The installed CLI from that primary directory reports both legacy MCP IDs disabled.
The global user configuration and existing chats were not restarted or edited.
This prevents new chats opening the old directory from treating stale launchers
as the current admission policy while preserving unrelated work.

The active enemy, voice and public-profile chats were contacted under the owner's
explicit coordination instruction. Update existing worktrees to the merged helper
before launching again; older launchers can bypass any cooperative policy.
Runtime launcher integration merged in [PR #53](https://github.com/bigmangeekf/iw7-paris-server/pull/53)
as `395f22b`, after both CI jobs passed on exact head `c73e11f` (run 37215619910).
The review reproduced a repeated-state-write failure caused by PowerShell binding
the File.Replace backup argument to an empty path. The merged correction uses a
real temporary backup; repeated state/heartbeat writes and locked-file preservation
pass. Retained child handles and injected failure cleanup also pass without games.
Keep capacity/quality/long soak acceptance separate from these source/lifecycle tests.

The first implementation merged in [PR #50](https://github.com/bigmangeekf/iw7-paris-server/pull/50)
after both CI jobs passed for its exact head. A real second build request was
refused while the voice chat held its lease; a 30-second build observation peaked
at 50.43% physical and 52.89% committed use. The registry was observed empty after
the build released it. See the sanitized measurements (`docs/deployments/2026-10-04-resource-admission.json`, server repository)
and retain [capacity issue #49](https://github.com/bigmangeekf/iw7-paris-server/issues/49)
for the remaining runtime and sustained-load gates.
