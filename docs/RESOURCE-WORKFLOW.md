# Concurrent agent work and resource telemetry

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

Waiting is served in arrival order (since 2026-11-11): a refused request that asks again keeps its place;
a waiting build stops new sessions so the running ones drain, and the sessions that waited behind it go before
any newer build. Read [Waiting order](#waiting-order---2026-11-11). `-Action Status` shows the queue,
`-Action Waits` the waits as data.

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
Client clones require a concrete necessity or risk. [Instance workflow](INSTANCE-WORKFLOW.md)
supersedes older systematic client-copy requirements and launch recipes below.
Dated test results remain historical evidence.

Agents may develop, review and run light tests in parallel. Preserve the account-wide
**one heavy workload group at a time** policy, except shareable runtime
leases, admitted by memory ([Shareable runtime leases](#shareable-runtime-leases---2026-11-10)):
one isolated gameplay scenario (server and its explicitly declared client(s)),
one native build, one asset extraction, or one reverse-engineering analysis.
Each chat keeps its own sources, files and test identity. A private desktop or a
Git worktree does not supply additional RAM, VRAM or CPU capacity.

The owner explicitly authorizes implementation, necessary tools and coordination
between the current IW7 chats. This does not turn estimated capacity into a
guarantee of unlimited simultaneous games. Additional applications and game
allocation spikes can still exhaust a machine. No performance acceptance is
inferred from successful source tests or a short resource observation.

## Admission, ownership and lifecycle

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

`ops/Resource-Scheduler.Core.ps1` is the common admission API. Every worktree uses
the same account-wide registry under `%LOCALAPPDATA%/IW7Paris/ResourceScheduler`.
A file handle opened with no sharing serializes snapshot/check/reserve/write.
The atomic JSON replacement retains one previous version for diagnosis. Registry
content is local operational state, not source and not a security boundary.

Callers that require an initial reservation, rather than runtime re-entry, can
opt into `Enter-IW7ResourceLease -RequireNewLease`. Inside the existing admission
lock, immediately after the real registry reader validates the state, this mode
refuses **any existing lease** before process enumeration, finished-runtime
reclamation, re-entry, memory observation, budget calculation or registry writes.
This includes the same owner, scope or base-client image and orphaned or unknown
owners. A prior empty photograph cannot authorize a lease that wins the race
before this locked read. A malformed registry remains a reader refusal.

Omitting the switch, or explicitly passing `-RequireNewLease:$false`, preserves
the existing runtime re-entry behavior, token, maximum estimates and refreshed
memory observation. A refused initial reservation must not fall back to an
unflagged retry, adopt or release another lease, or delete registry state. This
optional API does not activate a consumer: advance its explicit Native pin and
prepare fresh verified source inputs before adoption.

The dedicated `resource_scheduler_initial_admission_source_test` check selects
`-InitialAdmissionSourceOnly` before the legacy suite imports Core or starts
contenders. It exercises the actual admission and registry-reader AST with
in-memory registry/process/lock/telemetry/write fakes. Its evidence is Source
control flow and compatibility, not a real lock race, registry write, native
memory sample, process lifecycle, game test or physical NoExit qualification.

Reserve the **complete planned scenario before starting its first process**.
RAM and commit estimates are separate observations, without reserves or an
estimate-based launch refusal. Baseline usage includes Windows, Codex, browsers
and the owner's running game/server. Record the complete planned scenario with
positive estimates; these describe intent, not a minimum amount that must be
available or a memory cap. Do not shrink a live lease to conceal planned work or
assume a process has reached its peak just because startup uses little RAM.
Every successful admission/re-entry retains its fresh `MemoryObservation` in the
lease; Status and Measure still read current native telemetry.

The following historical estimates are planning references, not admission
requirements, measured maxima or supported-client-count limits:

| Workload | Physical estimate | Commit estimate | Qualification |
| --- | ---: | ---: | --- |
| Native build, one MSBuild node, compiler `/MP` disabled | 4 GiB | 6 GiB | BelowNormal priority inherited by synchronous children |
| Native build, two nodes, explicitly selected | 8 GiB | 12 GiB | Same exclusive lease; no gameplay overlap |
| One reduced client | 8 GiB | 8 GiB | Logic/audio evidence only |
| One full-quality client | 12 GiB | 12 GiB | Required for unqualified texture/material evidence |
| Isolated dedicated | 2-4 GiB | 2-4 GiB | Use the greater profile-specific estimate, add it to client budgets |

Low estimated headroom does not refuse a full-quality pair or defer an authorized
test. Choose the scenario that answers the question and observe actual behavior.
Two reduced voice clients require both clients plus the dedicated in one group.
The historical samples do not establish four-client performance acceptance.

```powershell
./ops/Resource-Scheduler.ps1 -Action Status
. ./ops/Resource-Scheduler.Core.ps1
$lease = Enter-IW7ResourceLease -Scope $absoluteLabRoot -Kind Runtime `
    -PhysicalBytes 16GB -CommitBytes 16GB -Owner 'visual enemy test'
# Use the lab's existing protected launcher, not arbitrary Start-Process.
# After each child identity is captured:
Add-IW7ResourceProcess -Token $lease.Token -ProcessId $ownedChildPid
# After the lab has stopped its exact clients/server through its normal guards:
Exit-IW7ResourceLease -Token $lease.Token
```

Runtime re-entry for the same lab is idempotent and may increase its total
estimate; its local state lock must serialize launches within that lab. Registered
resident/private allocations are already in the live snapshot, so re-entry
records the remaining projected growth as telemetry. There is no kernel memory
cap or projected-headroom gate. Unregistered labs, compilers, ZoneTool and Java analysis also block
new heavy admission. Existing owner processes are never stopped by this API.

For a separate dedicated using the base client, declare the exact absolute client
executable with `Enter-IW7ResourceLease -BaseClientImage` on the initial runtime
reservation. Budget server plus client together. Only that image with both
`-paris-isolated-lab` and `-paris-server-client-test` may attach outside the scope;
an ordinary owner client cannot be adopted. The declaration cannot change on
re-entry, and an unregistered declared test client retains the lease. Older leases
without this optional field remain valid for clients inside their lab scope.

Process records bind PID, creation time and image. Missing identity retains the
reservation. PID reuse never authorizes killing or adopting a process. A runtime
lease may be reclaimed only when its owner, attached children and any process
under its lab root are gone. Orphan builds remain quarantined, since detached
compiler children can live outside the scope. After diagnosing and closing the
exact job, `-Action Release -Token <exact token>` refuses release if its owner or
a possible heavy child remains. There is no TTL that silently frees a live game.
Never delete the registry to bypass contention.

The scheduler itself never kills or suspends any game. The lab watchdog retains
responsibility for observed real exhaustion, fresh godmode/inactivity, diagnostic
capture and identity-checked orderly stop. Admission cannot prevent a user from
launching another unrelated application afterwards. There is no fixed RAM/commit
use percentage that stops or invalidates a run. Record both as telemetry.

Use `ops/Isolated-Lab.ps1` for the test dedicated. New sessions use the base game
client under [INSTANCE-WORKFLOW.md](INSTANCE-WORKFLOW.md); separate clients
require a documented necessity or risk. Historical base-instance
entry points now refuse new launches before reading machine settings or changing
files: Voice-BaseTest Prepare/StartServer/StartClient/TrimMemory,
Module-ClientProbe Start, Rhino-ClientProbe agent Start/Spawn and every
Rhino-Rounds Deploy action. Their diagnostic/owned Stop/Restore paths remain;
Rhino-Test Deploy was already parked. The explicit stock OwnerPreview and normal
Server.ps1 operations retain their existing owner/session guards. Neither is an
agent shortcut around resource admission. No existing process is stopped by this
retirement. Eleven real command-entry refusal cases run in CI.

The old Voice-BaseTest GenericRelay switch is historical v2 evidence, not a current
launch recipe. Use isolated VoiceNative Install with VoiceMode Relay for explicit
v2 plus private audio tracing, or Player for v2 without private capture/decode/codec
hooks. Native retains the original investigation profile. Player refuses synthetic
VoiceProbe; one-client readiness does not prove two-client speech. The complete
planned scenario still needs admission before launch.

## Waiting order - 2026-11-11

Why. Before this, a refused caller simply asked again later and whoever asked at the right instant won. Measured
on 11 Nov 2026 with 4 to 6 workers: a zone build waited 25 to 75 minutes behind other workers' back-to-back
headless sessions (one gave up after its 3600 s wait), a session waited 30 minutes while one worker chained
builds, and three checks of the local judges that hold the Build slot for seconds failed 13-minute runs.

What the scheduler keeps (unchanged): one exclusive lease or several shareable Runtime leases admitted by memory,
the account-wide lock, identity checks, never deleting another holder's lease, and the call itself: nobody
changes how `Enter-IW7ResourceLease` or `Invoke-IW7QueuedResourceJob` is called.

The rules, all applied inside the admission lock:

1. **Ticket.** A request refused for a reason that passes (`Resource busy: ...`, a duplicate of a held lease,
   a running compiler, a lab without a lease, an unreadable identity) gets a ticket in `queue.json`, next to
   `leases.json`: scope and kind (one ticket is one intended lease), owner label, declared memory, `-ShortSeconds`,
   the caller's process identity and its parent's, the time of the first and the last ask. Asking again for the
   same scope and kind (from the same or a new process) refreshes the ticket and keeps its place. A grant removes it.
2. **Expiry.** A ticket expires at once when neither its caller nor the caller's parent process is alive (the
   parent covers runners that ask again in a new process each time), and otherwise when it is not refreshed in
   time: 90 s after a single ask, then twice the last interval between asks plus 30 s, between 90 and 660 s (a
   runner whose pauses grow to 300 s keeps its place). Every expiry is logged with its reason.
3. **Exclusive requests** (Build, Extract, Analysis, a Runtime lease without `-Shareable`) wait for every older
   ticket: strict arrival order.
4. **Shareable requests** that fit in memory are admitted at once unless an older **exclusive** ticket waits.
   So a waiting build stops new sessions from the moment it asks; the running ones drain and the build gets in.
   Sessions that asked before a newer build go before it (rule 3), so a chain of builds cannot starve sessions.
   A shareable request may pass an older shareable ticket that does not fit (a small server beside a waiting
   client), except once that ticket has waited 600 s: then it goes first as well.
5. **Short exclusive requests** (`-ShortSeconds 1..120`, declared by the caller: the checks that hold the Build
   slot for seconds) may go ahead of older tickets when they are admissible right now (no lease held), as long
   as no older ticket has been overtaken for more than 300 s in total. Holding a short lease longer than
   declared is logged (`Overran`), never stopped.
6. Re-entry of a held lease is never queued. A shareable request larger than the whole budget is refused and
   never queued (it could never fit). `-RequireNewLease` refusals are not queued.
7. The queue is advisory: an unreadable or foreign `queue.json` reads as empty, a queue or log write that fails
   is ignored, and no queue error ever refuses, grants or removes a reservation.

Bounded waiting. Let D be the longest time anyone holds a lease and P the longest pause between a waiting
caller's asks. A build waits at most for the holders present when it asked (at most D), then for the older
tickets: older sessions run side by side (at most D more) and each older exclusive request holds for at most D:
**W(build) <= (2 + k) x D + P**, k = older exclusive tickets; with nobody ahead, **D + P**. A session waits at most
for the exclusive tickets older than it and their holders, the same bound; a session that does not fit waits at
most 600 s before it goes first, then D for memory to drain. Short requests add at most 300 s to anyone.

Making waiting visible:

- `./ops/Resource-Scheduler.ps1 -Action Status` adds `Queue` (place, owner, kind, `WaitingSeconds`,
  `LastAskedSecondsAgo`, asks, caller PID) and `HeldSeconds` per lease. Status never writes.
- A refused caller's message keeps its old text (callers match `Resource busy:`) and adds its place:
  `... Queue: place 2 of 3, asked first 4m10s ago; ahead: 'zone build' (Build, waiting 6m02s).` A refusal by
  the order itself reads `Resource busy: waiting in turn: 1 earlier request(s) go first: ...`.
- `admission-log.jsonl` (same folder, rotated at 8 MB to `admission-log.1.jsonl`) has one line per grant
  (`WaitSeconds`, asks), refusal (place, reason), expiry and release (`HeldSeconds`). No token is written.
- `./ops/Resource-Scheduler.ps1 -Action Waits [-Since <time>] [-Json]` prints the grants in order, the waits
  per owner and the longest wait (`Get-IW7ResourceWaitReport`).

Mixed population (callers still running an older core for a few hours after the pin moves): an older core never
reads or writes `queue.json` or the log, so it cannot damage them, and its leases are read as before. It ignores
tickets: an older caller can still take a free slot ahead of a waiting newer one, exactly as before this change,
and it records no ticket of its own (it is not protected either). The newer core sees every lease an older core
writes and queues behind it; a ticket of an older-core caller does not exist, so nothing waits for a caller that
will never be served. Fairness is complete once every running caller has re-read the core (a new bootstrap or a
new runner process); nothing breaks in between.

Callers that poll by reading Status and asking only when nothing is held (the SDK's `zt.ps1` before 11 Nov) never
get a ticket and are starved as before: callers ask `Enter-IW7ResourceLease` itself, every 5 to 60 s.

Evidence: `tests/ops/resource_scheduler_queue_test.ps1` (20 cases, synthetic callers, clock and memory: arrival
order, a build not starved by sessions, sessions not starved by builds, aging, memory, expiry, a dead caller, a new
process keeping the place, short requests and their bound, re-entry, an unreadable queue, older-core leases,
status, the wait report) and the live run recorded in the server repository's `docs/BENCH.md`.

## Shareable runtime leases - 2026-11-10

Admission by memory. Decision delegated by the owner to the working agent,
2026-11-10, after he asked for ten to twenty agents to run instances at once. It
replaces the earlier fixed count of two shareable leases.

Rule, in four points:

1. A Runtime lease may declare itself shareable (`-Shareable`). Every other lease
   must then be a shareable Runtime lease, and bench scopes must not overlap.
2. `-PhysicalBytes` of a shareable lease is the memory its whole session needs,
   all its processes together (a lease may now hold several game processes).
3. Declared budget: the `PhysicalBytes` of all shareable leases plus the new
   request must stay within total physical memory minus the reserve.
4. Measured memory: the available physical memory, minus the part of the existing
   shareable leases' declared memory that their registered live processes have not
   yet taken (declared minus working set, never below zero, per lease), must be at
   least the request. This stops two sessions admitted seconds apart, before
   either has loaded, from both counting the same free memory. A hard cap of 24
   shareable leases (`Get-IW7ShareableRuntimeLeaseLimit`) guards against runaway
   requests; it is not the real limit, memory is.

Why memory and not a count. Measured: a full game client is about 9 GB private
and 3.7 GB working set; a headless dedicated server with three bots is about
1.2 GB. Two full clients side by side left about 6 GB free of 31.8 GB, so a count
of two was right for clients and wasteful for servers: fifteen servers fit where
two clients do. The exclusive rule had refused about 2,370 requests (79% of local
game-session attempts).

The reserve is `Get-IW7ShareableReserveBytes`: 8 GB by default, kept for the
owner's desktop and his own game. Set the environment variable
`IW7_SHAREABLE_RESERVE_GB` to a number from 2 to 64 to change it (decimal point,
for example `12.5`); anything else is ignored. It is read at each admission.

What callers must declare: the measured session need, not a guess upward, for
example 2.5 GB for a headless server session, 10 GB for a full client, 12.5 GB for
a server plus a client. Under-declaring is caught by the measured-memory check
only at admission time; once admitted, nothing re-checks a session that grows
beyond its declaration, and it then silently eats the margin of the others.
Declare honestly and keep margin.

Unreadable identities (found by a live run of 8 sessions on 10 Nov 2026, where one
waiting request failed with `Reserved process identity unavailable`): when the
registered processes of ANOTHER lease cannot be identified at that moment (a server
just starting or exiting), a shareable admission neither throws nor drops that lease:
it is retained and counted as having taken nothing, so its whole declared memory
stays reserved, and a request that then does not fit gets the normal
`Resource busy:` measured-memory refusal. Everything else keeps the strict check:
re-entry of the same lease, release, `Add-IW7ResourceProcess` and exclusive requests
still refuse with that identity error.

Who may opt in: launches from an isolated bench root in a private loopback session.
Never Main. Never the base client. Each bench root is its own lease scope.

```powershell
$lease = Enter-IW7ResourceLease -Scope $absoluteBenchRoot -Kind Runtime `
    -PhysicalBytes 2.5GB -CommitBytes 3GB -Owner 'bench a' -Shareable
```

What the scheduler enforces:

- `-Shareable` is valid only with `-Kind Runtime` and without `-BaseClientImage`.
- A shareable request that fails any condition gets a message beginning
  `Resource busy:` (callers match that text) that names the failed condition with
  numbers in GB. Examples:
  - `Resource busy: shareable declared memory budget exceeded: existing shareable leases declare 20.0 GB and this request needs 10.0 GB, above the budget of 24.0 GB (32.0 GB total minus a 8.0 GB reserve). ...`
  - `Resource busy: not enough measured free memory: 21.0 GB available minus 20.0 GB still to be taken by existing shareable sessions leaves 1.0 GB, and this request needs 2.5 GB. ...`
  - `Resource busy: shareable Runtime cap of 24 leases reached; owned by ... and 19 more. ...`
  - A non-shareable lease in the way: `Resource busy: <Kind> owned by <Owner>`, as before.
- A request without `-Shareable` is refused by any other lease, exactly as before,
  and is not subject to the memory rule.
- Re-entry on the same scope and kind cannot change the flag. The lease keeps the
  larger of the old and new declared bytes. A re-entry that grows the declaration
  is checked against the budget and measured memory (counting what the lease has
  already taken); if it does not fit it is refused with `Resource busy:` and the
  lease and the registry are left unchanged. A re-entry that does not grow adds no
  demand and is not refused.
- `-RequireNewLease` still refuses any existing lease, shareable or not. Do not
  combine it with `-Shareable` if the second bench must be admitted.
- A lab process inside another shareable lease's scope, or registered to it, is
  not foreign for a shareable request. For any other request it still is. A lab
  process that no lease covers still refuses.
- Running compilers, ZoneTool, MSBuild, cl, link or Java still refuse.
- `Add-IW7ResourceProcess` accepts several game processes on a shareable lease
  (for example a dedicated server and a client). Its other checks are unchanged:
  the process must be inside the reserved lab and have a verifiable identity.
- Release, finished-lease cleanup and Status work per lease. Releasing or cleaning
  one lease never removes or changes another.
- Status shows `Shareable` per lease (false for a lease without the property),
  `ShareableRuntimeLimit` (the cap), and, so that a waiting caller can print why it
  waits: `ShareableReserveBytes`, `ShareableDeclaredBytes`,
  `ShareableRemainingDeclaredBytes`, `ShareableAvailableBytes` (measured) and
  `ShareableUnloadedBytes` (declared but not yet taken; a lease whose processes
  cannot be identified counts as fully untaken).
- `Invoke-IW7ResourceJob` only takes Build, Extract and Analysis, so it has no
  `-Shareable` switch.

What stays exclusive: Build, Extract and Analysis leases, Runtime leases without
the flag, base-client leases, and any lease written by an older copy of the core
without the flag.

Mixed versions (an older copy of this file has a fixed limit of 2 shareable
leases and one game process per lease; both copies read the same registry):

- Older copy reading leases admitted by a newer copy: with two or more other
  leases it refuses a new shareable lease (limit of 2), and it refuses a second
  game process on a lease. It is stricter, never looser. It may also refuse the
  re-entry of an existing lease when three or more leases are held; that is a
  refusal, not an overrun.
- Newer copy reading leases of an older copy: it counts their declared bytes
  (older callers declared 12 GB per client) and their live working sets, and admits
  by memory. It is stricter than before for big declarations and looser by count.
- An older copy that rewrites the registry keeps the `Shareable` property
  (`ConvertFrom-Json` and `ConvertTo-Json -Depth 10` keep unknown properties).
- The one unsafe-looking case: an older copy never checks memory. Beside one large
  lease admitted by a newer copy (for example 12.5 GB), an older copy admits a
  second lease (it sees only one other lease), so the declared total may exceed the
  newer copy's budget. It is not worse than the old accepted envelope of two
  clients (about 18 GB working set) because the older copy still refuses a third,
  and newer admissions afterwards see the declared and measured memory. It only
  matters if an older copy keeps running; callers must take `-Shareable` from the
  newest core only.

Not verified: a live run of more than two sessions at once (the reviewer will do
it). Evidence is the synthetic suite `tests/ops/resource_scheduler_shareable_test.ps1`
(temporary registry, synthetic process list and synthetic 32 GB memory snapshot).
## Build, extraction and analysis

### Inactive retained-release opt-in (Source only)

`Invoke-IW7ResourceJob` has an inactive opt-in comprising `BeforeReleaseCheck`,
`OriginalContext` and `RetentionRoot`. No builder or runtime caller opts in.
All three parameters **omitted** retain the literal legacy implementation, its
Body arguments and admission estimates. An explicit null, partial triple or
used/malformed input refuses before admission. This addition does not qualify
normal-build child containment, artifact inventory, compiler output or a launch
path. The earlier six-slot-only implementation and its 69 Source assertions
were insufficient: mutable mirrors could lose ownership/errors after unwind,
and token arrays could evade late filtered comparisons.

`OriginalContext` is the caller's original mutable `PSCustomObject`, with exactly
six ordinary, settable note properties. These are diagnostic mirrors, not
authority. Do not convert, clone or deserialize this object. Its fresh shape is:

```powershell
# Data shape only; not an authorized invocation or a process-lifetime guard.
$originalContext = [pscustomobject]@{
    ResourceJobLease = $null
    ResourceJobFirstErrorRecord = $null
    ResourceJobFirstException = $null
    ResourceJobSecondaryErrors = $null
    ResourceJobReleaseAttempted = $false
    ResourceJobReleaseReturned = $false
}
```

Before Invoke, the original caller creates one fresh, registered, empty mutable
`PSVariable` in its retained scope. It retains that exact variable in its own
original root and registers the same object in the current AppDomain at
`IW7.ResourceJob.RetainedRelease.` plus the variable's ASCII identifier (at most
64 characters). Pass the actual variable as `RetentionRoot`; a name, copied
receipt or reconstructed owner is insufficient. Core validates its actual CLR
type, registration, empty value, absence of validation attributes and mutable
options before Enter. Core binds a standard .NET read-only owner view, makes
that variable ReadOnly and checks the
same variable/value/AppDomain binding before admission. This is not a caller
activation recipe.

Private-scope writers retain the same context and all six original property
objects independently of those mirrors. Immediately after Enter, before mirror
writes, token getters, priority setup or Body, the owner retains the actual
returned lease. Body and hook cannot find the writers by ordinary child-scope
variable lookup. The owner exposes bounded read-only collections/entry metadata,
not their mutable backing stores. Removing/replacing/nulling a mirror refuses
release without repairing it or overwriting foreign data; the original lease,
properties and errors remain reachable from the caller's variable and AppDomain
after return or exception. Read-only views retain live object references; this
is not isolation against deliberate in-process reflection or root destruction.

The callback receives the same context explicitly and must observe it without
changing its slots or roots. Only one Boolean `true` result approves the check;
strings, numbers, arrays, multiple outputs, no output, false or an exception
refuse release. Priority restoration must also be known. Before/after Body and
hook, and immediately before Exit, Core rechecks the original roots/view and
every committed error-journal entry. The live original token property must hold
one `System.String` of exactly 32 lowercase hex characters and match the captured
string with ordinal `String.Equals`. Arrays, coercion, filtered `-cne` results,
fallback tokens and token repair cannot authorize release. There is still one
admission.

The first captured ErrorRecord and Exception remain the same objects. Before
fallible mirror projection, Core assigns the first once and appends each of the
four finite failure frontiers (setup/Body, priority, check, release) to its private
journal. Its read-only live view contains ordinal/frontier and original
ErrorRecord/Exception references. The secondary view is bound before Enter;
`Clear`, reorder, replacement or entry edits cannot erase authoritative records.
Count, order, values and reference identities are verified, not only list
identity; overflow refuses release. Ordered secondaries cannot mask an earlier
setup/Body error.
PowerShell can expose another outer ErrorRecord when it propagates; that does
not replace the retained first inner record or Exception. A known failed Body
may release after an approving check and known priority restoration, but remains
failed. A failed release attempt keeps its lease reference and records no known
release. `ResourceJobReleaseReturned` means only that Exit returned; fresh
registry absence and real host closure remain separate proofs. Do not serialize
the live context, lease, ErrorRecord or Exception.Data.

This adapter never creates/closes native owners, disposes caller guards, changes
CanExit/Passed/Ready, resets/stops the caller's clock or exits the host.
**A refusing hook alone does not retain a noninteractive PowerShell process.**
Before any future activation, its original caller must have a separately
reviewed exact physical/managed NoExit entry, fixed AppDomain/PSVariable roots
retaining the same context/owners/handles/guards/lease/clock across return or
throw, and an original-host terminal gate after real closure/readbacks. Returning
from a sourced script or leaving a lease file is not a true-exit proof. No PID or
JSON reconstruction is a substitute. Without that caller, this API is inactive
and has no runtime-retention qualification.

The narrow `tests/ops/resource_scheduler_test.ps1
-RetainedReleaseSourceOnly` mode runs the actual function and token predicate
extracted by AST with fake admission/release/process/priority/check dependencies
and owned managed root witnesses. It checks actual lease/error references after
unwind, private-writer visibility, read-only journal mutations, token frontiers,
strict check results and literal legacy parity. It returns before the Core
import, real registry and historical cross-process contenders. Those Source
causals do not establish a real lease, NoExit host, descendant closure,
compiler/build/game result or full legacy-suite pass. Subsequent child coverage
and postbuild evidence remain separate work.

Build-Voice and Build-RhinoZoneTool acquire a heavy-job lease around compilation,
default to one MSBuild node, disable compiler multiprocess expansion, disable
node reuse and run at BelowNormal priority. The caller's priority is restored in
`finally`. `TestsOnly` remains lightweight and does not reserve a whole game slot.
Do not nest a lease wrapper around an already guarded builder.
Build-RhinoAutoDownload now also reserves its synchronous ZoneTool invocation,
with the same 6 GiB physical/8 GiB commit estimates as the other Rhino pack builder.
This keeps offline historical pack work possible without reopening parked gameplay.

For an unintegrated asset/decompiler tool, run its entire synchronous invocation
under the common wrapper, with measured or conservative estimates:

```powershell
. ./ops/Resource-Scheduler.Core.ps1
Invoke-IW7ResourceJob -Scope $absoluteWorktree -Kind Extract -Owner 'asset closure' `
    -PhysicalBytes 6GB -CommitBytes 8GB -Body {
        # Invoke the existing synchronous tool and check its real exit code here.
    }
```

No sleeping game should be held while compiling. Finish the bounded encounter,
collect its evidence, stop the owned pair, then build. On refusal, continue source
review, test construction and documentation; retry after the active owner releases.
The registry reports the current holder and the waiting order. It is an admission gate with a waiting order of
callers that keep asking, not a job queue that runs work by itself, and not an OS limit on arbitrary direct
executable launches.

### Queued plain job - 2026-11-10

`Invoke-IW7QueuedResourceJob` takes the same arguments as the plain form of `Invoke-IW7ResourceJob` plus a
mandatory `-WaitForSlotSeconds` (1 to 86400). While the slot is held it asks for admission again every five
seconds, up to the bound, then throws the last refusal. Only a refusal that names a temporary holder is waited
for (`Resource busy: ...`, or a compiler/extractor/Java analysis still running); an unknown identity, invalid
telemetry, an unreserved laboratory or a duplicate lease is thrown at once. It has no retained-release form.
`tests/ops/cutscene_test.ps1` and `tests/ops/owner_cheats_test.ps1` use it with `-ShortSeconds 120` and a
2100-second bound (their `checks.json` entries set `timeout_seconds` 2400; `ops/check_product.py` reads it,
default 600), so the local judge waits in turn for another session's build instead of failing. Since 2026-11-11
it takes `-ShortSeconds` and prints one line a minute with its place while it waits. `Invoke-IW7ResourceJob` itself is unchanged and still
refuses at once. Evidence: the cases under "Invoke-IW7QueuedResourceJob" in `tests/ops/resource_scheduler_test.ps1`
(temporary registry, synthetic processes); no live contention run is claimed.

## Choose the least expensive valid witness

| Question | Minimum useful witness | Invalid shortcut |
| --- | --- | --- |
| Protocol, parser, counters, data transformations | Unit tests and offline source/asset checks | Starting a full renderer for every edit |
| GSC linkage, server initialization | Dedicated logs and exact hashes | Claiming player behavior from startup |
| AI, combat, Rush, connection state | One protected low-cost client with telemetry | Removing actors required by the scenario |
| Native voice transport/output | Reduced textures, actual audio, per-receiver loopback | Muting sound or confusing injected tones with human speech |
| Textures, shaders, animations, FX | Full-quality client, native frames and observation | Fullbright, missing mip detail, disabled FX or hidden required assets |
| Frametime/performance acceptance | Normal intended settings, defined scenario, frame timings and soak | 720p/30fps reduced test as a claim about normal gameplay |

Keep 1280x720 and 30 fps for bounded functional fixtures unless the measured
feature requires more. Retain the true audio path for audio tests. Reduced
`r_picmip`, bump and spec values belong only to the isolated client profile.
Restore/profile-reset before judging texture quality. Godmode, inactivity bypass
and `sv_cheats=0` stay mandatory. Test dedicated AppData/keys/bank/ports stay
separate from Paris Main. Base-client files/profiles are backed up and restored;
separate client assets/profiles are conditional on necessity or concrete risk. Remove unrelated enemies for audio/UI tests through legitimate
lifecycle cleanup; do not change counters or remove the combat subject.

Extract minimal enemy dependency closures, including only required sound aliases.
Reuse hashes/pinned packs when inputs are unchanged; build only the changed layer.
Whole donor-map loads are a known invalid strategy. Do not enlarge asset pools as
a substitute for finding unwanted dependencies. Preserve actual rendering/audio
checks after any extraction or shader serializer change.

## Windows, GPU, storage and diagnostic decisions

### Fresh native memory telemetry - 2026-10-05

Repeated WMI memory-provider timeouts refused admission and interrupted a protected
replay even though measured RAM/commit stayed below the limits. Both admission and
the watchdog now read fresh RAM/commit through Windows GetPerformanceInfo. Page
counts are converted with the returned page size, with checked arithmetic and
snapshot validation. Native failure still refuses admission; there is no cached
fallback. The original admission thresholds were retained at that checkpoint;
the 2026-10-13 decision above supersedes them. Process identity
remains independently checked. Paging rates unavailable through this API are null.
The Windows ABI and 100 real reads pass in CI's operations test.
[Microsoft API](https://learn.microsoft.com/en-us/windows/win32/api/psapi/nf-psapi-getperformanceinfo),
[field definitions](https://learn.microsoft.com/en-us/windows/win32/api/psapi/ns-psapi-performance_information).

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
[STORAGE-WORKFLOW.md](STORAGE-WORKFLOW.md) for retained and retired stock. At that
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
the build released it. See the [sanitized measurements](deployments/2026-10-04-resource-admission.json)
and retain [capacity issue #49](https://github.com/bigmangeekf/iw7-paris-server/issues/49)
for the remaining runtime and sustained-load gates.
