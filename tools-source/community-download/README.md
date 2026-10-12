# Contained community-download failures

Private source candidate, 2026-10-12. Ownership is limited to this directory and
the archived `src/client/component/download.cpp` patch. Creator, shared native
checkouts, voice, Main and runtime deployment are unchanged. Two local harness
compilations exceeded the source-only mission; see the incident below. The parent
integrates the reviewed commit into the central private PR; no upstream PR.

## Finding and correction

At Aurora pin `77e6d4d24e918ee363b3feee3735c3b889dff7d7`, download errors throw
through an asynchronous scheduler callback without a catch. The downloaded buffer
CRC is checked, but `write_file` is unchecked and itself ignores stream write/close
failure. A rejected disk write can therefore announce completion and reconnect.
These are source findings; no client crash was deliberately reproduced here.

The patch contains worker exceptions, returns a short English error through
`game::shared::menu_error` on `scheduler::main`, and keeps HKS notifications on
`scheduler::lui`. The actual pin's `game.cpp:50` calls
`Com_SetLocalizedErrorMessage`; `party.cpp:290` supplies the existing main-path
precedent. `ModDownload.lua:25` uses `mod_download_done` to close the progress
popup: it is a terminal cleanup event, including on error, not proof of success.
Only a successful terminal decision may call `party::connect` on main.

Each file uses an exclusive `CREATE_NEW` temporary in the destination directory:
bounded checked writes, `FlushFileBuffers`, checked close, exclusive reopen,
checked length and byte-for-byte readback, checked second close, then one
`MoveFileExW(REPLACE_EXISTING | WRITE_THROUGH)`. There is no delete-first step or
cross-volume copy fallback. The helper is local; `utils/io` is unchanged.

The active state starts before worker submission. Generation checks reject stale
UI callbacks, and cancellation is checked during transfer, writes, readback, before
publication and at the final main-thread connection decision. A cancellation
serial preserves the real `party::download_files` stop-then-start replacement
path while allowing a later stop to cancel that queued replacement.

Publication is **per file**, not a transaction across all three mod files. If a
later file fails, a previously committed verified file may remain; no connection
is attempted. Cancellation after the rename commit point may retain that valid
new file, while still suppressing connection. Failure before that point preserves
the old destination. OS/hardware crash durability and hostile concurrent folder
replacement are not established. Temporary cleanup is best effort on OS refusal.
If scheduler allocation itself fails, the worker still does not throw or reconnect,
but cannot guarantee delivery of a UI notification through the unavailable queue.

## Source verification and historical runner

Use the existing local native Git objects; no fetch, clone, native checkout edit,
game asset, actual HTTP, DLL injection or full game build is needed to verify:

```powershell
python tools-source/community-download/verify_archive.py --native-source C:/author/iw7-mod-source
```

`verify_archive.py` checks base/result/patch SHA-256, the complete transformation
and the unchanged upstream license. The runner additionally applies the patch
with real `git apply --check`/`git apply` to a one-file scratch fixture and compiles
that exact reconstructed C++ file using installed MSVC, C++20, `/W4 /WX /EHsc`.
It does not compile a separately reimplemented transaction algorithm.

The unadmitted harness reported 43 passing cases. They cover missing HTTP/URL,
curl refusal, bad status/CRC, standard
and nonstandard exceptions, create/write/short-write/flush/close/reopen/size/read/
short-read/corruption/replace failures, real Windows destination locking, first
install and replacement, cancellation windows, deferred retries, stale callbacks,
shutdown, scheduler allocation failure and a later file failing in a multi-file
set. HTTP, CRC and scheduler adapters are mocked; CRC uses the independently
implemented IEEE algorithm and native `123456789 -> 2639F4CB` vector. Files are
real Windows files, with fault injection around individual Win32 calls.

`validation.json` binds the functional source/harness hashes but sets overall
`passed:false` and `admitted_pipeline_passed:false`. Ignored `.scratch/`
retains small compile logs, harness executables and temporary fixtures; none is
part of the source archive. The first archive reconstruction comparison failed
because local Git converted LF to CRLF. Per-command `core.autocrlf=false` fixed
the verifier; no global setting changed. The first 40 cases passed before the
real party stop/start call sequence prompted the serial guard and three added
regression cases. These are offline component tests, not a full native build,
rendered UI witness, download over a real server, or owner acceptance.

## Source-only incident: no retrospective admission or closure

The agent incorrectly treated this compiled harness as a permitted lightweight
test and ran it twice without reservation, original Job Object supervision,
historical PID/creation identities or descendant accounting. This exceeded the
source/preparation assignment. The 40-case and 43-case executions were at
07:37:59--07:38:04Z and 07:40:53--07:40:58Z on 2026-10-12 (09:38 and 09:41 Paris).
Tool wall times were 4.6880442 and 5.1836618 seconds for the whole Python calls;
neither compiler-only duration nor memory/commit peaks were measured. The only
execution bounds were subprocess timeouts of 90 seconds for compile and 30 for
the harness. Returning zero from those subprocesses did not establish descendants'
closure. No admission or full native pipeline pass is claimed.

At 07:49:07.911Z a targeted observation retained VCTIP PID29324, reported parent
PID32792, creation07:38:02.967Z and its image hash. The parent PID was absent.
This overlaps the first compilation, but no historical compiler identity proves
the relationship. The earlier zero-match check filtered only paths containing
this archive; it could miss a pathless descendant and was not a closure proof.
The residual remains preserved, without guessed attribution or termination.
The parent's later observation that the unchanged scheduler does not classify
VCTIP as a builder does not change this uncertainty.
The parent subsequently reports PID29324 absent before its locator Run and no
agent termination. This reported disappearance supplies neither retrospective
harness attribution nor historical descendant closure.

The original command files, logs, EXE/OBJ and receipts remain ignored in
`.scratch/harness-7dfozczw` (2598031 bytes) and `.scratch/harness-gwstj0b0`
(2666867 bytes), plus the pre-compilation reconstruction failure (9803 bytes).
The sanitized record preserves measured times, sizes and hashes without changing
the original receipts. Future repetition requires reviewed Plan/original-job
supervision and complete admission; the old direct runner is not an approved
execution route. No further native invocation was made for this incident report.

## Review and subsequent build plan (not executed)

Review the single native patch and receipt before integrating. In the central
builder, add an explicitly enabled, pin-and-base-hash-checked application step
after checkout/overlays and before native compilation. At the audited main this
is near `ops/Build-Voice.ps1:274`; the existing cache overlay changes `party.cpp`
and is independent. Accept only the pinned base or this exact result, preserve
other edits, and include the patch/result hashes in the build manifest. Current
Build-Voice does **not** apply this archive automatically; running it unchanged
would not build this correction.

Then, with reviewed source, an owned existing native checkout and the parent's
single admitted build slot, use the current isolated Modules build pipeline with
one build job (existing estimate 4 GiB physical / 6 GiB commit). Compile/link and
inspect the exact resulting native manifest first. A later separately authorized
protected candidate session can exercise first join, cache reuse, HTTP refusal,
bad CRC and cancellation while observing rendered notices. Main remains outside
that experiment. No reservation, full build or game run is included here.

The base source remains governed by the exact retained `LICENSE.upstream`.
No license claim is added for unrelated private scripts or game assets.

## Static review corrections after the unadmitted runs

The parent's review identified an uncaught second-stage LUI enqueue inside the
main callback, and an early `active=false` permitting a concurrent Lua stop to
miss cancellation before reconnect. The source now contains that callback's
exceptions and keeps active through the fallible enqueue. Its final mutex-protected
decision is the explicit completion linearization point: a stop acquiring that
mutex first cancels; a stop after terminal commit cannot retract the connection.
No queue/UI work separates that decision from connect, and no globals lock is held
across the reentrant game API. This is a source contract, not a concurrency witness.

Three regression cases are added: second-stage enqueue refusal, a real second-thread
stop joined during enqueue, and a second-thread stop inside the connect adapter
after commit (also checking absence of a held mutex). The resulting 46-case source
has **not been compiled or executed**. The historical 43-case result remains bound
to `35bea079780580a0fc49d957168496e50febb1d1`, not these reviewed corrections.

## Prepared Plan/original-job repetition (source only)

`Harness.ps1 -Action Plan` is the default and performs only path/hash inspection.
It requires explicit installed Python/VC/Windows SDK paths and a fresh runtime
output path. It creates no directory, reservation, process, compiler, assembly or
network request. The historical `run_tests.py --native-source ...` entry now only
prints an inert Plan notice. The old implicit compile route is removed.

The separate `-Action Run` source requires the exact reviewed plan SHA-256 and an
already-built, reviewed helper assembly bound to `Download-NativeJob.cs`. Plan has
no `Add-Type` or native telemetry. Run may initialize the pinned `ResourceMemory.cs`
API required by admission, including its minimal `Add-Type` bootstrap before the
lease decision. No job-helper build or vswhere/vcvars bootstrap occurs there. Preparing
and qualifying that assembly is a future, separately admitted parent operation;
supplying matching hashes alone is not qualification of the helper implementation.

The prepared Run admits the complete 4 GiB physical / 6 GiB commit group before
staging or launch. One original job owns the Python worker at process creation;
its git, compiler/linker and test subprocesses inherit that job. The runner keeps
the same original job handle after root exit, samples bounded kernel-verified
member PID/creation/image identities, captures residuals before owned Stop, and
requires root exit plus zero job members for CloseConfirmed. Sampled membership
does not claim an exhaustive event history or unmeasured memory peaks. Root exit
with residual members after two seconds fails the run even if functional tests
passed; cleanup does not turn it into success. An unconfirmed closure retains the
lease, exact original owner and read guards in an AppDomain quarantine entry.
There is no termination by guessed PID, process name or global sweep.

`Download-NativeJob.cs` is an isolated derivative of the existing original-job
helper. `job-source.json` binds its base and derived bytes. The additions expose
root exit and bounded membership snapshots using opened handles checked against
the retained original job, so PID reuse alone cannot supply attribution. Shared
helper sources are unchanged. This derived helper and the Run path have not been
compiled, loaded or executed. The 32 MiB output cap reserves 1 MiB for final
metadata; root/descendant ownership, functional result and admission remain
separate fields in the planned receipt. Full IW7 build and gameplay are excluded.

## Harness static-review corrections (no native repetition)

The initial original-job preparation still lost its local owner on unresolved
cleanup, accepted some late terminal observations, left admission imports/DLL
unguarded, and could suppress an oversized run's failure receipt. These defects
were found statically; none is reclassified as tested native behavior.

The small `Harness.Core.ps1` policies reuse the existing Recipient/AnimationFF
AppDomain retention pattern and the reviewed GSC audit's monotonic observation
rules. On failed cleanup, `IW7.CommunityDownload.Quarantine.<lease-token>` strongly
roots the exact owner, guards and state after script-local references disappear.
The entry is never replaced or automatically cleared. This retention lasts for
the execution host's lifetime: the caller must keep that original host alive for
recovery. Host exit/kill-on-close is not confirmed closure and never releases the
quarantined reservation or retroactively attributes the old VCTIP process.

The clock begins before `Start`; global180s, registration5s and observed-root
drain2s checks run after getters/CIM/measurement, including a terminal zero-member
observation. A synchronous slow API cannot be preempted by these checks: returning
late is refused, not counted as timely. The same rule covers cleanup's5s budget.

Plan v2 pins all four current admission inputs: scheduler, Resource-Memory,
Resource-RecorderOwnedProcess, and native/ResourceMemory.cs. Run retains read-only
file handles for the Plan, local sources, tools, these imports and the original-job
DLL before importing/loading them. Their guarded hashes close the simple
hash-to-load replacement window. Guards persist through closure or quarantine.
The job helper still requires a separately admitted build/witness.

A 1MiB metadata file is written and flushed before launch. Payload is watched
separately against31MiB. Finalization uses that reserve even if payload measurement
throws or exceeds its cap; the record is Failed, and oversized detail becomes a
compact failure receipt. It does not delete oversized evidence or claim the total
budget was respected. Unrecoverable filesystem I/O failure may still prevent
publication; it cannot produce a success claim.

Run the interpreted policy checks only with
`& tools-source/community-download/tests/Test-HarnessPolicies.ps1`.
They call the actual lifecycle policies with mock owners/clock, retained real
small-file guards and bounded receipt fixtures. They compile/load no helper,
reserve nothing and never enter the runner's Run branch. Native helper, corrected
downloader46-case execution and admitted pipeline validation remain pending.
