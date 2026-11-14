# Concurrent agent work and resource telemetry

This is the rule of the machine-wide scheduler (`ops/Resource-Scheduler.Core.ps1`) that every worktree of every
IW7 product shares on one Windows account. In short, as of 2026-11-10:

- **Live sessions on bench roots run several at once, admitted by memory.** A Runtime lease that declares itself
  shareable is admitted while the declared and the measured free memory allow it, with a reserve kept for the
  owner's desktop. This is the normal case; read [Shareable runtime leases](#shareable-runtime-leases---2026-11-10)
  first.
- **Exclusivity follows what is really shared (named resources, since 2026-11-12).** A request names what it
  needs alone (its work folder or bench root always; a ZoneTool folder, a Ghidra project, the GPU, the machine
  when it says so) and runs beside every lease that names nothing in common with it, when memory fits. A native
  compile, a zone build, a dump, headless sessions and an analysis run side by side. Read
  [Named resources](#named-resources---2026-11-12) first. A check or a script that can wait uses
  `Invoke-IW7QueuedResourceJob -WaitForSlotSeconds <n>`; callers in the server repository pass
  `-WaitForSlotSeconds`. Never write a retry loop around a refusal.
- **Waiting is served in arrival order** (since 2026-11-11). A refused request that asks again keeps its place;
  a waiting build stops new sessions so the running ones drain, and the sessions that waited behind it go before
  any newer build. Read [Waiting order](#waiting-order---2026-11-11). `-Action Status` shows the queue,
  `-Action Waits` the waits as data.
- **An exclusive (not shareable) Runtime lease** that names nothing holds the machine (a declared base client
  image, the voice certification). One that names its resources (`-Resources gpu`) runs beside what it does not
  share.
- **A request admitted alone is never refused for memory** (owner update of 2026-10-13): the first lease on an
  empty machine is granted whatever the numbers. Beside other leases every request is admitted by memory. Fresh telemetry is still required; missing
  or impossible telemetry and unknown process identities are diagnosed, they are not a capacity refusal.
  The compatibility fields `Allowed=true`, `PhysicalReserve=0`, `CommitReserve=0`, `HighWater=false` apply to
  valid telemetry and `Policy=TelemetryOnly` identifies this decision; `Memory-Budget.ps1` uses the same policy.
- **What never changes:** the atomic account-wide lock; lease ownership and exact process identities; guarded
  teardown of only your own identified processes. Never delete another holder's lease, never adopt an occupied
  client, never archive a live worktree. On real exhaustion reduce the scenario or close only your own work: no
  new numeric barrier, RAM cleaner, arbitrary process kill, oversized swap or kernel change. Main (UDP 27016),
  banks, configuration and occupied clients are preserved.
- A successful admission does not promise unlimited allocation, and no performance result follows from a source
  test or a short observation.

Consumers take this scheduler through their dependency pin and a regenerated source package (see
[INDEX.md](INDEX.md), "Paths other products take"); they do not edit generated inputs.

The sections after "Shareable runtime leases" were written in October 2026 and are kept as the manual of the
mechanisms (leases, owned processes, the retained-release form, telemetry). Where they speak of testing with the
base client, `AGENTS.md` (first section) takes precedence: tests run from bench roots. The October policy prose,
its validation and rollout records are in
[archive/RESOURCE-WORKFLOW-HISTORY-2026-10.md](archive/RESOURCE-WORKFLOW-HISTORY-2026-10.md).

## Named resources - 2026-11-12

Why. "A build needs the machine alone" stalled the machine three times on 11-12 Nov 2026 (admission log): at 21:45
one 1.5 GB headless soak session held its lease while 12 builds and 10 sessions waited up to 55 minutes with
12.8 GB free; at 23:30 a native C++ compile held the single build reservation for about 90 minutes while 21
requests waited, nearly all ZoneTool builds and dumps that share nothing with a compile (10.8 GB free; a client
session gave up after 60 minutes); at 01:30 a Ghidra analysis (kind Analysis, hours long) held the machine 40+
minutes while 17 builds waited, one for 87 minutes. `tests/ops/resource_scheduler_resources_test.ps1` replays the
three from the log: they fail on the core before this change and pass on it.

What each kind of work really shares (read from the code and the log):

| Work | Writes or holds alone | Shares with others |
|---|---|---|
| native compile (MSBuild, cl, link) | its build tree (`build/`, `runtime/` of its worktree) | memory, cores |
| ZoneTool build or dump (`zt.ps1`) | its work folder: `zonetool.exe` runs there and writes `zone/`, `dump/` there | memory; reads the stock game files (read only) |
| headless session | its bench root, a random loopback port | memory |
| client session | its bench root, the GPU (one window) | memory |
| Ghidra analysis | its Ghidra project | memory (Java heap), mostly one core |
| policy and unit tests (`-ShortSeconds`) | their own `runtime/` folder | memory |

Nothing in this table needs "the machine". The rule:

1. **Names.** A request carries `-Resources <names>`: `class` or `class:value` (letters, digits, `.`, `_`, `-`
   for the class; a path value is canonical, so `zonetool:C:\w\zt` equals `zonetool:c:\w\zt\`). Two names
   conflict when their classes are equal and a value is missing or `*`, or both values are paths that overlap
   (one inside the other), or the values are equal. `machine` conflicts with every name. Every request also holds
   its own scope: `runtime:<scope>` for a Runtime lease, `work:<scope>` for the others. Names in use: `machine`,
   `gpu`, `analysis`, `zonetool:<folder>`, `native-build:<tree>`, `ghidra:<project>`; any other class is allowed.
2. **Admission.** A new lease is refused (retryable: `Resource busy: <Kind> owned by <owner>. It holds '<name>',
   which this request needs too ('<name>').`) only by a held lease that names a conflicting resource. Beside other
   leases it must fit in memory: the declared total stays within the budget (total minus the 8 GB reserve) and
   measured free memory, minus what running leases have declared and not taken yet, covers it. A build's or an
   analysis's taken memory is the working set of its owner and every process below it; a session's is its
   registered processes. `-Cores <n>` (optional) are counted against the logical processors. Alone on the machine
   a request is admitted whatever the memory, as before.
3. **Defaults for callers that name nothing** (nobody has to change at once): a shareable Runtime holds its bench
   root; a Build or an Extract its work folder; an Analysis its work folder and `analysis` (one undeclared analysis
   at a time); an exclusive Runtime `machine`. A lease or a queue ticket written by a core before this change has
   no `Resources` field and holds `machine` (that core assumed it was alone and still refuses everything while
   another lease is held, so its holders keep their old guarantees).
4. **Waiting order.** An older ticket holds a request back only when it names a conflicting resource (arrival order
   between jobs that cannot run together; a short request may still pass within the 300 s bound), or when it has
   waited the aging time (600 s), is not declared long, and would no longer fit in memory beside the request (later
   requests stop taking memory so the machine drains for it), or when it was written by an older core and has
   waited the aging time. An older ticket that cannot fit even when every running lease ends never holds anything
   back. A holder that releases and asks again waits behind older conflicting tickets like anyone.
5. **Long holders.** `-Long` marks a soak, an analysis or a long compile. Its lease never delays requests it shares
   nothing with (rule 2), and its waiting ticket never stops later requests for memory (rule 4).
6. **Compilers belong to the lease that started them.** A compiler, ZoneTool or Java process below a held lease's
   owner or registered process (parent links, each parent no younger than its child) is that lease's own: it no
   longer refuses other admissions, and it keeps only its own lease from being released. One that no lease started
   still refuses every admission (`An existing compiler/extractor/Java analysis is running`).

`-Action Status` shows what each lease `Holds`, and for each waiting ticket its `Resources`, `Long` and a `Why` that
names the holder and the shared name, or the memory numbers. The admission log records the names and the declared
memory of every grant and refusal.

How a caller declares (examples):

```powershell
# a ZoneTool run in its own work folder (zt.ps1)
Enter-IW7ResourceLease -Scope $Work -Kind Build -PhysicalBytes 6GB -CommitBytes 8GB -Owner $Owner -Resources "zonetool:$Work"
# a native compile of a worktree
Invoke-IW7ResourceJob -Scope $repo -Owner 'native build' -PhysicalBytes 4GB -CommitBytes 6GB -Resources "native-build:$repo" -Body { ... }
# an hours-long Ghidra analysis of one project
Invoke-IW7ResourceJob -Scope $repo -Kind Analysis -Owner 'engine database analyze' -PhysicalBytes 10GB -CommitBytes 12GB -Resources "ghidra:$project" -Long -Body { ... }
# a client session (needs the GPU, not the machine)
Enter-IW7ResourceLease -Scope $bench -Kind Runtime -PhysicalBytes 5GB -CommitBytes 6GB -Owner 'client' -BaseClientImage $exe -Resources gpu
# a measurement that must have the machine alone
Enter-IW7ResourceLease ... -Resources machine
```

Callers that may load an older core feature-detect with
`(Get-Command Enter-IW7ResourceLease).Parameters.ContainsKey('Resources')` and pass the names only when present.

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
0. **Only a ticket that could be served holds anyone back** (fix of the deadlock of 11 Nov 2026, 15:10-15:40: an
   8 GB client ticket, aged past 600 s on a machine with 5.5 GB free and no lease running, held back 8 later
   requests, 1.5 GB headless servers and a build included, for 28 minutes). An older shareable ticket counts
   for rules 3 and 4 only while its request is no more than measured free memory (available minus what running
   sessions still have to take) plus the memory declared by running shareable leases, and no more than the
   declared budget. Otherwise later requests that fit go first and the ticket keeps its place. The refusal by
   order says how many were passed: `... go first: 'h1' (...) (2 earlier request(s) that cannot fit now are passed).`
3. **Exclusive requests** (Build, Extract, Analysis, a Runtime lease without `-Shareable`) wait for every older
   ticket that could be served (rule 0): arrival order.
4. **Shareable requests** that fit in memory are admitted at once unless an older **exclusive** ticket waits.
   So a waiting build stops new sessions from the moment it asks; the running ones drain and the build gets in.
   Sessions that asked before a newer build go before it (rule 3), so a chain of builds cannot starve sessions.
   A shareable request may pass an older shareable ticket that does not fit (a small server beside a waiting
   client), except once that ticket has waited 600 s: then it goes first as well.
5. **Short exclusive requests** (`-ShortSeconds 1..120`, declared by the caller: the checks that hold the Build
   slot for seconds) may go ahead of older tickets when they are admissible right now (no lease held), as long
   as no older ticket has been overtaken for more than 300 s in total. Holding a short lease longer than
   declared is logged (`Overran`), never stopped.
6. Re-entry of a held lease is never queued. A new shareable request that can never fit as the machine stands
   (more than free memory plus what running shareable leases declare, or more than the declared budget) is
   refused at once, its ticket leaves the queue and the refusal is logged with `NeverFits`. The text names the
   numbers and contains none of the words runners wait on, so the runner stops at once instead of waiting:
   `Refused: this session can never fit on this machine as it stands: it needs 8.0 GB, measured free memory is
   5.5 GB and running shareable sessions hold 0.0 GB, so waiting can give at most 5.5 GB (...). Not queued. ...`
   (until 11 Nov only a request above the budget was refused, with a `Resource busy:` text that runners waited
   on until their bound). `-RequireNewLease` refusals are not queued.
   A request above the declared budget is refused at once even while an exclusive build or session holds the
   machine (before 11 Nov evening it was queued behind the holder and refused only on its next ask). Below the
   budget, while an exclusive lease holds, it waits: the holder's memory comes back when it ends.
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
  `LastAskedSecondsAgo`, asks, caller PID, `CanFit`, `Why`) and `HeldSeconds` per lease. Status never writes.
  Its first field `Why` says why the head ticket waits, with the numbers, for example
  `Head of queue: 'IWZ custom map local session' (Runtime shareable, waiting 33m18s) needs 8.0 GB, free 6.7 GB
  (...), held 0.0 GB by 0 running shareable session(s). It cannot fit as things stand (at most 6.7 GB can come
  free by waiting): later requests that fit go first; asked again, it is refused.` `ShareableReachBytes` is the
  most a shareable request can get by waiting.
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

### The admission lock is part of the wait - 2026-11-11, evening

Why. Every request, refusal, release and Status takes `admission.lock` (an exclusive handle on a file in the
registry folder; every core, old and new, uses the same file). Until this change a caller that did not get it in
10 s threw `Resource admission lock busy; retry later.`, a text no runner waits on, so queued callers died after
waiting their turn: the engine loop after 1,718 s, a headless runner after 23 min, the SDK `zt.ps1` after 9 min.
Measured on the live registry (19 queued callers): the lock was busy 89 % of a minute (57 holds, median 0.73 s,
longest 3.0 s), because each holder listed the machine's ~700 processes through WMI (0.4-0.8 s, more under load)
and scanned them once per ticket and per lease inside the lock. Reproduced with 16 callers asking every 5 s on a
test registry with the live queue: 23 of 97 asks died on the busy lock, the lock was busy 96.5 % of the time.

What changed (`Invoke-IW7ResourceLock`, `Enter-IW7ResourceLease`, `Get-IW7ResourceStatus`):

- **The process list is taken before the lock** (`Get-IW7ProcessListing`), and the native memory reader is
  compiled before it. A lease created, or a ticket asked, after the list was taken is never judged finished or
  gone from it. A list that aged over 3 s while its caller waited is taken again outside the lock (twice at
  most). Release and child registration keep their list inside the lock (a child may have just started).
- **Scans are indexed**: one process by PID is a `.Where(...,'First')`, not a pipeline; the scope scan of a lease
  runs only when it decides whether the lease is finished.
- **Waiting for the lock is fair and bounded by the caller's queue wait**: new cores first take a named mutex
  (one per registry folder), which Windows hands over in arrival order, then the file. A request that still has
  no lock after 60 s gets `Resource busy: the scheduler admission lock is held by other callers (waited 60 s).
  Continue light work; retry when released.`: every runner and `Invoke-IW7QueuedResourceJob` wait on
  `Resource busy`, so they ask again. Release, registration and Status wait up to 300 s. The old text is also
  retryable in `Test-IW7RetryableRefusal`.

Measured after (same 16-caller load): 0 of 152 asks refused for the lock; lock busy 26 % of the time; a hold
takes 35-60 ms (was 0.4-3 s); after the first two asks of each process, lock wait plus hold is 54 ms median,
221 ms at the 95th percentile. A lock held 15 s by another caller: the old core's queued caller died at 10.6 s,
the new one was granted at 16 s. Unit test: `tests/ops/resource_scheduler_admission_lock_test.ps1`.
Callers on an older core still list processes under the lock and still die after 10 s on it: they take the fix
with a new bootstrap (server) or workspace (SDK).

Evidence: `tests/ops/resource_scheduler_queue_test.ps1` (23 cases, synthetic callers, clock and memory: arrival
order, a build not starved by sessions, sessions not starved by builds, aging, memory, expiry, a dead caller, a new
process keeping the place, short requests and their bound, re-entry, an unreadable queue, older-core leases,
status, the wait report; and the deadlock of 11 Nov rebuilt from its logged queue and memory, an aged ticket that
stops holding back when it can no longer be served, a build not held back by a client ticket that cannot fit; the
three new cases fail on the core before the fix) and the live runs recorded in the server repository's
`docs/BENCH.md`.

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

## Admission, ownership and lifecycle

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
| Native build, one MSBuild node, compiler `/MP` disabled | 4 GiB | 6 GiB | BelowNormal priority inherited by synchronous children; power throttling off for the host and its children unless the owner's game runs (see "Job speed and the owner's game") |
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
client under `docs/INSTANCE-WORKFLOW.md` of the server repository; separate clients
require a documented necessity or risk. Historical base-instance
entry points now refuse new launches before reading machine settings or changing
files: Module-ClientProbe Start, Rhino-ClientProbe agent Start/Spawn and every
Rhino-Rounds Deploy action. Their diagnostic/owned Stop/Restore paths remain;
Rhino-Test Deploy was already parked. The explicit stock OwnerPreview and normal
Server.ps1 operations retain their existing owner/session guards. Neither is an
agent shortcut around resource admission. No existing process is stopped by this
retirement. Seven real command-entry refusal cases run in the server's CI; its
voice cleanup (server PR #414) removed Voice-BaseTest and its four cases.

The Voice-BaseTest GenericRelay switch, the isolated VoiceNative profile and its
VoiceMode Relay/Player/Native variants belong to the retired voice relay (see
[VOICE.md](VOICE.md)); this repository no longer builds or supports them. Voice
certification uses `ops/voice-certify/Invoke-VoiceCertify.ps1`
([VOICE-CERTIFY.md](VOICE-CERTIFY.md)): one shareable Runtime reservation for the
test dedicated plus two clients, scoped to the folder that holds their three bench
roots, admitted by memory before launch and retried while busy.

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
strict check results and literal legacy parity, and that the power-throttling
guard starts after the lowering and is stopped before the restore on every path
(check `resource_scheduler_retained_release_source_test`). It returns before the Core
import, real registry and historical cross-process contenders. Those Source
causals do not establish a real lease, NoExit host, descendant closure,
compiler/build/game result or full legacy-suite pass. Subsequent child coverage
and postbuild evidence remain separate work.

Build-Voice and Build-RhinoZoneTool acquire a heavy-job lease around compilation,
default to one MSBuild node, disable compiler multiprocess expansion, disable
node reuse and run at BelowNormal priority with power throttling off (next
section). The caller's priority is restored in `finally`. `TestsOnly` remains
lightweight and does not reserve a whole game slot.

### Job speed and the owner's game

All three job forms (`Invoke-IW7ResourceJob`, its retained-release form and
`Invoke-IW7QueuedResourceJob`) lower the host to BelowNormal for the body, and
`Start-IW7ResourceJobQos` switches Windows power throttling (EcoQoS: efficiency
cores, low clock) off for the host and for every process the body starts, until
the body ends. Windows 11 throttles hidden background processes even on an idle
machine, BelowNormal ones most of all, and a parent's opt-out is not inherited:
measured on 12 Nov 2026 (i5-13400F, CPU-bound child started with `&` from the
body, 8 s, three runs each): before 0.51-0.65 CPU s per wall s and 37-45 million
loop iterations, after 0.97-0.99 and 81-86 million (about 2x). The lead measured
a Ghidra analysis at 0.6 s of CPU in 30 s at BelowNormal, 45.2 s once unthrottled.
The guard lists process ids ten times a second (`EnumProcesses`) and opens only
new ones; its cost is about 0.2 s of CPU a minute. A grandchild whose parent
exits within 100 ms of starting it is missed. A job object cannot be used: the
agent shells run inside a job that lets children break away silently.

**The owner's game keeps priority:** while `iw7-cb-aurora.exe` runs, the guard
hands throttling back to Windows (our BelowNormal jobs go to the efficiency cores
again) and BelowNormal lets the game win every CPU contention. After the job the
host's state is handed back to Windows as well. The real-job check in
`tests/ops/resource_scheduler_test.ps1` reads the explicit state of the host and
of a child the body starts (1/0 = never throttle) and the game fallback (0/0).
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
for (`Resource busy: ...`, `Resource admission lock busy; retry later.` (another caller held the admission lock a few seconds), or a compiler/extractor/Java analysis still running); an unknown identity, invalid
telemetry, an unreserved laboratory or a duplicate lease is thrown at once. It has no retained-release form.
`tests/ops/cutscene_test.ps1` and `tests/ops/owner_cheats_test.ps1` use it with `-ShortSeconds 120` and a
2100-second bound (their `checks.json` entries set `timeout_seconds` 2400; `ops/check_product.py` reads it,
default 600), so the local judge waits in turn for another session's build instead of failing. Since 2026-11-11
it takes `-ShortSeconds` and prints one line a minute with its place while it waits. `Invoke-IW7ResourceJob` itself is unchanged and still
refuses at once. Evidence: the cases under "Invoke-IW7QueuedResourceJob" in `tests/ops/resource_scheduler_test.ps1`
(temporary registry, synthetic processes); no live contention run is claimed.

One named exception to "never write a retry loop around a refusal": `tests/ops/native_unit_tests.ps1`.
`ops/Build-Voice.ps1 -TestsOnly` takes the Build slot itself and refuses at once, before anything is compiled, so
that check asks again every five seconds, for at most 420 seconds, and only on the busy refusal; any other error
is thrown at once. It is the same wait as the two tests above, written around the build entry because that entry
has no queued form. Do not copy the pattern elsewhere: use `Invoke-IW7QueuedResourceJob`.

## Choose the least expensive valid witness

| Question | Minimum useful witness | Invalid shortcut |
| --- | --- | --- |
| Protocol, parser, counters, data transformations | Unit tests and offline source/asset checks | Starting a full renderer for every edit |
| GSC linkage, server initialization | Dedicated logs and exact hashes | Claiming player behavior from startup |
| AI, combat, Rush, connection state | One protected low-cost client with telemetry | Removing actors required by the scenario |
| Voice relay (routing, mute, teams) | `ops/voice-certify`: known speech injected at native capture, decoded PCM per talker at the receiver; reduced textures | Muting game audio or treating injected speech as human speech |
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
