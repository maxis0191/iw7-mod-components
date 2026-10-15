# Agent debugger and supervised IW7 sessions

## Client018: refused analysis, confirmed closure (2026-10-15)

The one authorized finite Analysis invocation of frozen source capsule C ended
as `ActualAnalysisRefusedKnownClosed`. It did not qualify a symbol or explain
the earlier client crash. The tool result is exactly:

```text
Status=Refused
Error=Value cannot be null. (Parameter 'path1')
IdentityMatched=false; SymbolFound=false; LineFound=false
CleanupConfirmed=true
DumpStatus=ExactWERPathMissingOrUnavailable; DumpQualified=false
RuntimeAddressLayoutVerified=false; RuntimeFaultSourceAttributionProven=false
CauseProven=false; CallstackReconstructed=false
```

The admitted contract contained a nonempty absolute PDB path. Its presence does
not establish that DbgHelp loaded that PDB. The error report retained only the
message, without an exception type, stage or managed stack. Do not attribute
the failure to a particular Path call, ABI, missing dependency or game function
from that message alone. The nominal requested RVA was `0x5C4AC`, against
compiled source `785ddd43d18c4eebd599bab10880e83d73a950e9` and upstream
`77e6d4d24e918ee363b3feee3735c3b889dff7d7`. Static image identity and a nominal
RVA would still not prove the effective client018 runtime address layout.

The original retained context, state, capsule and NativeJob owner were used
through finalization. Original pre-exit evidence recorded the owner/context
closed, all 25 original SafeFileHandles closed, the original lease null and its
registry token absent, input reverification complete, the clock stopped and
`CanExit=true`. The original terminal then actually completed with exit code 0;
it was never polled again. Independent process and scheduler observations found
the three original process generations absent and no game/compiler/VCTIP or
lease holder. Root independently checked the receipts, terminal completion and
fresh absence at 20:03:01.6118642 UTC before releasing its coordination slot.
Process/cleanup success is separate from the refused analytical result.

These bounded local text receipts remain ignored; their SHA-256 pins identify
the evidence without committing raw logs, tools, images, PDBs or dumps:

| Receipt | Bytes | SHA-256 |
| --- | ---: | --- |
| `tool-result.json` | 1340 | `6123AD0F9C95DF94D7DFCFE651D816460D4F837EE7770B9241A6C7B0A1B6FFB2` |
| `admitted-contract.json` | 1208 | `AB41B3E33990D1DCDA5A68931349797C8F4BE641EB9DCE10C25F1B805F5CE314` |
| `actual-original-preexit-b.local.json` | 1860 | `FD9802191B39379A8160A24A573E31B7C6D825AFD7EDBF6B0EA3B3A7A3359B2D` |
| `actual-independent-closure.local.json` | 1929 | `3D30D8E164A39FC9C4477B8D2A45C6BA77CCAFBCDB5AF082812D82A69747AD30` |
| `actual-closed-review.local.json` | 4450 | `CDE9BA1C67B9D32EEFCE8B7BA41B9DEE62627CA00C18323DD694D6262E62DE6F` |

Capsule C is 11135 bytes, SHA-256
`26CFD497B2A5915A2F0FB6838C295A3F1350D1B84913E2B9AD71E7A6D94BD8B9`.
A/B were not executed; A/B/C and their analytical outputs remain frozen. The
first metadata proof helper failed on an unsupported PowerShell ReadOnlySpan
cast and closed its writer in `finally`; additive helper B used a byte loop.
That correction neither reconstructed the original context nor replayed analysis.

The next step is source-only investigation and a separately reviewed sibling
with bounded stage/exception diagnostics before Path and P/Invoke calls. No
additional image/PDB/DLL/dump access, analysis replay, attach, game launch,
capture, stack reconstruction or game fix is authorized by this checkpoint.
A new exact capsule review and distinct Analysis GO are required for execution.

### D2: diagnostic failure stage observed, analysis still Refused

The separately authorized D2 invocation on 2026-10-15 remains `Refused`.
It records `Stage=Resolve.Native.SymSetOptions`, exception type
`System.ArgumentNullException`, `HResult=-2147467261`, parameter `path1`, and
the same error message as C. Its untruncated managed exception stack contains
`PowerShellAssemblyLoadContext.NativeDllHandler` and
`Path.Combine(path1, path2, path3)` while resolving the first P/Invoke.
`InputPdbNonEmpty=true`, `HelperAssemblyLocationEmpty=true`, and
`LastNativeCallReturned=false` were observed. This localizes this D2 tool failure;
it does not prove why the underlying native library load failed, establish C's
unrecorded failure stage, or explain the earlier client018 crash.

`IdentityMatched`, `SymbolFound`, `LineFound`, dump qualification, actual runtime
layout/source attribution, game cause and reconstructed game stack remain false.
The exact WER path was missing/unavailable. `CleanupConfirmed=true` is the
diagnostic helper's cleanup result, separate from analytical qualification.

The same original context/state/capsule and NativeJob owner reached known
closure: all 25 original SafeFileHandles closed, inputs reverified, original
lease/token absent, clock stopped, `CanExit=true`, and actual original terminal
exit 0. Root independently verified the original terminal completion, receipts,
three original process generations absent and games/compiler/VCTIP/leases empty
at 20:31:09.0526693 UTC before releasing its coordination slot. No original
terminal was repolled, no analysis replayed and no opaque input reread after
release. A metadata helper rejected a duplicated hash character before writing
closure evidence; an additive helper corrected that transcription while the
original proof and analytical outputs stayed unchanged.

| D2 receipt | Bytes | SHA-256 |
| --- | ---: | --- |
| `tool-result.json` | 2556 | `85CB72EF344B8079E871E0AF42995C51B52D8FD7E868A751D79738C45CA39A25` |
| `actual-original-preexit.local.json` | 3050 | `29B90B7AAE46D3C1A304BF0FE0AEA7A1F9D957117BDC2541AC5F8FC69D04996F` |
| `actual-independent-closure.local.json` | 2042 | `EE4FBAEA26F4789CBFC5F601C36F83EB3380180BB7E9D887AF5613B26AD15900` |
| `actual-closed-review.local.json` | 5508 | `64F796CCC11EE81E797186E02D9F0D8B0BB67F09A0FEF63F0A49B749D8D8FD65` |

D2 capsule: 17542 bytes, SHA-256
`E301114FFCCC11FAA7ECE62D0FEBD5972F8947F55A13ABADE90AC8AB1A15625C`.
D was not executed; C/D/D2 and results remain frozen. The next loader correction
is source-only until a new exact capsule review and distinct Analysis GO.

Current instance policy (2026-10-06): use the base game client for ordinary
in-game and sequential A/B tests; stage server changes on a separate test dedicated.
Client clones require a concrete necessity or risk. [Instance workflow](INSTANCE-WORKFLOW.md)
supersedes older systematic client-copy requirements and launch recipes below.
Dated test results remain historical evidence.

The debugger is a CLI evidence pipeline, with an explicitly instrumented isolated
build for deeper observations. Use it before inventing engine patches or tuning
dvars. Production UDP 27016, the owner client, voice protocol, configuration and
bank are not changed by this tool. Raw logs, dumps, CSVs, ETL, PDBs and decompiled
retail code stay local under ignored runtime/tools; reports can still contain
private paths/text and are not automatically suitable for publishing.

## Entry points

| Command | Witness |
| --- | --- |
| `Debug-Server.ps1 -Action Doctor` | Tools, elevation, resource holders and memory |
| `Identity` / `Observe` | Exact PID/creation/image/hash; retained read-only handle; CPU, threads, resident/private memory, I/O, optional loopback UDP |
| `Snapshot` | Live thread/stack minidump of this worktree's exact isolated lab only |
| `AnalyzeDump` | Bounded offline CDB exception context, all-thread stacks and loaded modules |
| `Etw` | Bounded CPU ETW capture with a unique WPR instance; elevation required |
| `Decompile` | 1..128 caller-selected, unwind-bounded retail functions through existing Ghidra |
| `Debug-Session.ps1 -Action Run` | Existing protected launcher, whole-scenario admission, live sensors, case files, exact owned teardown |
| `Debug-Session.ps1 -Action Observe` | Live sensors for an already-running explicitly installed debugger lab; leaves it running |
| `python ops/iw7_debugger.py` | JSON analysis of logs/dumps/symbols/performance/presents/source/history and combined triage |

All commands require PowerShell 7/Python 3.12. `Install-Tools.ps1 -IncludeDebugger`
reuses pinned CDB and installs portable PresentMon 2.6.0 from the official release.
It does not install a service, driver, overlay or recurring automation. Existing
Ghidra/Temurin, GSC compiler and Visual Studio remain their separately pinned tools.

## Live launch recipe

Use an isolated worktree with the current resource/lab helpers. The native builder
must have its own source checkout; never borrow another active chat's dirty sources.
`Prepare` prepares only the test dedicated and its stock cache by default. Reuse
the existing stopped server snapshot. Observe gameplay from the base client;
automated separate-client recipes require a concrete SeparateClientReason. A new
server stock snapshot is substantial I/O and needs admission. Do not make a new
client snapshot for ordinary debugging or sequential A/B.

```powershell
./ops/Install-Tools.ps1 -IncludeDebugger
./ops/Build-Voice.ps1 -ServerModules -IsolatedLab -Debugger
. ./ops/Resource-Scheduler.Core.ps1
Invoke-IW7ResourceJob -Scope $PWD.Path -Kind Extract -Owner 'debugger stock snapshot' `
    -PhysicalBytes 6GB -CommitBytes 8GB -Body {
        ./ops/Isolated-Lab.ps1 -Action Prepare -SourceGameRoot <legitimate-stock-root> `
            -ServerPort 27416 -ClientPort 27417
    }

# Dedicated-only: compilation/linkage/simulation witness, no player gameplay.
./ops/Debug-Session.ps1 -Action Run -Seconds 60

# Conditional separate-client automation: first document a concrete necessity,
# then explicitly prepare that client with the same SeparateClientReason.
# Prefer the base client for ordinary gameplay/debugging; this old automation
# does not yet manage base-client launch/restoration. Reduced is not normal FPS.
./ops/Debug-Session.ps1 -Action Run -Client -ReducedGraphics -Seconds 120 `
    -SeparateClientReason '<concrete necessity or base-instance risk>' `
    -ExpectedFps 30 -ExpectedTPS 20
```

Run installs the explicit Modules/debugger profile on its already prepared
loopback ports, launches through Isolated-Lab, then runs a combined observer. The client
uses the existing CrossMap protected fixture; this is an automated fixture, not
an unrestricted human-play mode. It requires fresh engine godmode/inactivity=0/
cheats=0 throughout, as enforced by the existing lab monitor. Run closes only
its newly started client/server through the lab's identity/empty-session guards.
Observe does not close a pre-existing session. An ownership/occupied-session
conflict retains the processes/reservation for diagnosis rather than guessing.

The debugger plan reserves an additional 2 GiB physical / 3 GiB commit before the first
game process, for native tracing, observers and optional CDB/ETW diagnostics.
Reduced one-client totals 14 GiB physical / 15 GiB commit; Full totals 18/19 GiB. Refusal
is expected on this 32 GiB workstation under background load. Do not lower the
budget or bypass the scheduler to produce a test. Other chats keep their slots.

## What arrives in real time

`runtime/debugger/session-*/live.jsonl` and stdout contain typed alerts and explicit
coverage gaps. Each process has its own CPU/thread/memory series; they are never
averaged together. Current policy is a starting diagnostic policy, not an engine
specification: frame spikes above twice the selected frame budget, repeated GSC
simulation cadence below 70% of ExpectedTPS, CPU above one busy core's 90% for five
samples, and sustained private-memory growth above 32 MiB/min over at least 25 s with
more than 16 MiB growth. Startup warmup is 30 s. Transitions reset the cadence streak.
An allocation trend is a leak candidate; retained allocations across comparable
round/map boundaries or allocation stacks must establish the leak.
Five consecutive renderer/Present windows below 80% of the selected expected
cadence raise a channel-specific drop alert. Three windows with an active scope
and no completion raise an unreturned-call hypothesis; CPU and all-thread stacks
must distinguish a spinning loop, wait, loading or an interrupted VM invocation.
Idle GSC waits are excluded when fresh UDP reports zero clients.

Logs are tailed with partial-line handling. New crash ZIPs are parsed, including
their exception, access type, module/RVA and CodeView identity. After process exit,
the watcher drains final logs/dumps for five seconds. Fatal/link/runtime/canonical
string/asset-limit/protection symptoms remain separate classifications. Nothing
automatically restarts, deploys or applies an optimization.

PresentMon runs as a PID-filtered, uniquely named session, without its restart-as-
admin or stop-existing-session flags. Its v1 CSV retains actual Present intervals;
the analyzer separates swapchains and computes frame-time quantiles/present rate.
Present cadence is not necessarily displayed FPS: dropped, occluded or generated
frames and display cadence require interpretation. Missing access/CSV/presentations
are reported as missing coverage, never as smooth rendering. NVIDIA device VRAM,
utilization and temperature are optional and cover the whole shared GPU.

The diagnostic build also records cadence at the pinned fork's existing render-
present callback, with eight fixed swapchain channels. This works without ETW
privileges, but callback rate is still not displayed FPS. A local COM query on
the rendering thread samples the process DXGI local-segment memory budget on
adapter node zero once per second. Unsupported devices/failed HRESULTs remain
visible; it cannot attribute every allocation or cover every multi-GPU node.
No additional renderer detour, overlay or GUI is installed.

The explicit native build times the pinned scheduler's server engine call plus
its pipeline, main engine call, and GSC builtin function/method dispatches. These
are inclusive wall scopes, including waits/nested calls. IDs resolve through the
matching `iw7_func.cpp`/`iw7_meth.cpp` tables. It does not instrument every GSC
bytecode/function automatically or measure exclusive CPU per script. A small
dedicated GSC frame coroutine reports distinct simulation times and resets; this
is a VM-frame witness, not packet rate or a claim about every subsystem's TPS.

For a specific script suspect, bracket a region only in a separate lab candidate:

```c
token = paris_debug_begin(17);
// The exact region under investigation.
paris_debug_end(17, token);
```

Region IDs 0..255 carry no player text. Pair tokens in their original invocation;
regions including `wait` measure wall duration. Float tokens lose precision as
the run ages, while automatic native scopes retain the steady-clock resolution.
Fixed counter storage records starts/completions and clock failures; a VM error
can skip scope completion. Do not assume a missing completion is an infinite loop.
Active scope counts survive window flushes so a call spanning several windows
remains visible; an aborted VM call can also leave a persistent active count.
Native recording is bounded to 600 s / 16 MiB. Session observation is bounded to 600 s /
128 MiB. Gaps, missing probes, profiler expiry and collector failure are evidence
limits, not clean-health reports. Longer leak investigation needs repeated scoped
sessions and comparable retained-memory checkpoints.

## Fast incident commands

```powershell
$identity = ./ops/Debug-Server.ps1 -Action Identity -ProcessId <exact-pid> | ConvertFrom-Json
./ops/Debug-Server.ps1 -Action Observe -ProcessId $identity.PID `
    -ExpectedImage $identity.Image -ExpectedCreatedUtc $identity.CreatedUtc `
    -ExpectedSHA256 $identity.SHA256 -Threads -Port 27016 -Seconds 30

python ops/iw7_debugger.py --output runtime/incident.json triage `
    --logs <log> --dumps <crash.zip> --traces <capture.jsonl>
python ops/iw7_debugger.py dump <crash.zip>
python ops/iw7_debugger.py symbols --image <exact.exe> --pdb <exact.pdb> --dump <crash.dmp>
./ops/Debug-Server.ps1 -Action AnalyzeDump -InputPath <crash.dmp> -SymbolsPath <matching-symbol-directory>
python ops/iw7_debugger.py perf <trace.jsonl> --token-root <pinned-gsc-tool-src/gsc/engine>
python ops/iw7_debugger.py presents <presents.csv> --pid <exact-client-pid>
python ops/iw7_debugger.py compare <baseline.jsonl> <candidate.jsonl>
python ops/iw7_debugger.py index
python ops/iw7_debugger.py blame src/custom_scripts/cp/<script.gsc> --line <line>
python ops/iw7_debugger.py case --scenario 'map, actors, settings, stimulus, phase' --artifacts <files>
```

Symbols checks compare PE CodeView GUID/age with the PDB info stream and optional
dump module CodeView/timestamp/image size. The file name alone is insufficient.
Wrong symbols return exit2. The dump parser does not unzip arbitrary paths and
accepts repeated unused DbgHelp stream placeholders. Retail engine frames often
have no public PDB; retain their exact module/RVA and matching unpacked references.
A faulting module/last changed line can be the victim of earlier corruption.

Snapshot uses external MiniDumpWriteDump; it can perturb timing and is not a crash
exception capture. Offline CDB has a 120 s process limit and closes only its own
diagnostic child on timeout. Microsoft symbol downloads require the explicit
MicrosoftSymbols switch. ETW uses named WPR instances and never cancels another
recording. An already admitted debugger lab can supply its exact RuntimeLeaseToken
for one serialized CDB/ETW operation within its preplanned diagnostic budget;
Ghidra requires its separate heavy slot. WPR needs elevation; the current desktop
session cannot silently provide it.

## Evidence and optimization discipline

Use exact hashes, source commit, process creation, fresh phases and a defined
stimulus. Preserve the pre-error data and matching PDB before rebuilding. Parser
success, native compilation, startup, automatic fixture behavior and owner gameplay
acceptance are different witnesses. Compare repeated A/B under the same map,
actors, settings, phase, duration and resource pressure; measure instrumented
versus uninstrumented overhead before accepting a performance improvement.

Arbitrary visual/gameplay bugs, all bytecode loops, every allocation owner and
all engine subsystems cannot be inferred by this tool. Add targeted assertions,
regions, allocation/ETW stacks or framebuffer evidence when the broad sensors
identify a suspect. The tool records its blind spots so an absent alert cannot
be mistaken for proof that everything is correct. See dated validation/issue
for the actual runtime coverage attained, including any admission refusal.

Validation remains tracked in [issue 87](https://github.com/maxis0191/iw7-paris-server/issues/87).
The actual protected client request was refused by memory admission; native
renderer/VRAM gameplay and comparative overhead are pending. PresentMon returned
access denied in this desktop session; WPR refuses before starting when not
elevated. No privileged measurement was fabricated.
The selected-function Ghidra adapter completed a real one-function analysis with
the retained local text/rdata/unwind sections; this verifies the adapter, not
every inferred decompiler type or the semantics of a proposed engine patch.

Primary references: [CDB !analyze](https://learn.microsoft.com/en-us/windows-hardware/drivers/debuggercmds/-analyze),
[WPR named instances](https://learn.microsoft.com/en-us/windows-hardware/test/wpt/wpr-command-line-options#instancename),
[MiniDumpWriteDump](https://learn.microsoft.com/en-us/windows/win32/api/minidumpapiset/nf-minidumpapiset-minidumpwritedump),
[DXGI process video-memory budget](https://learn.microsoft.com/en-us/windows/win32/api/dxgi1_4/nf-dxgi1_4-idxgiadapter3-queryvideomemoryinfo),
[PresentMon console](https://github.com/GameTechDev/PresentMon/blob/v2.6.0/README-ConsoleApplication.md),
[official release](https://github.com/GameTechDev/PresentMon/releases/tag/v2.6.0).
Official Aurora develop was checked once for this task at c0a1c6d; no upstream
update was adopted. The native diagnostic build retains reviewed fork 77e6d4d.
