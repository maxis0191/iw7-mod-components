# Agent debugger and supervised IW7 sessions

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
