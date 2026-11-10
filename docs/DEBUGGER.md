# Agent debugger and supervised IW7 sessions

The debugger is a CLI evidence pipeline, with an explicitly instrumented isolated
build for deeper observations. Use it before inventing engine patches or tuning
dvars. Production UDP 27016, the owner client, voice protocol, configuration and
bank are not changed by this tool. Raw logs, dumps, CSVs, ETL, PDBs and decompiled
retail code stay local under ignored runtime/tools; reports can still contain
private paths/text and are not automatically suitable for publishing.

This manual was written in October 2026. Two things changed since and take precedence (see `AGENTS.md`,
first section): a test never runs in the owner's game folder, so where the text below says "base client" use a
bench root made by the server repository's `ops/bench/New-BenchRoot.ps1`; and sessions are admitted by memory,
several at once ([RESOURCE-WORKFLOW.md](RESOURCE-WORKFLOW.md), "Shareable runtime leases"). For a freeze, a
crash, frame cost or a value in memory, the newer single-purpose tools in [INDEX.md](INDEX.md) are faster.

The dated journal of the refused Client018 / symbol-provider qualification attempts (2026-10-15 to 2026-10-26)
that used to open this document is in
[archive/DEBUGGER-CLIENT018-2026-10.md](archive/DEBUGGER-CLIENT018-2026-10.md). Its results stay as recorded.

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

The debugger plan declares an additional 2 GiB physical / 3 GiB commit for native
tracing, observers and optional CDB/ETW diagnostics. Its historical Reduced
one-client totals are 14/15 GiB physical/commit; Full totals are 18/19 GiB.
These workload estimates and fresh memory percentages are telemetry, not fixed
admission minima or percentage stop rules. Preserve the shared scheduler's
identity, ownership, lease and heavy-workload serialization gates; see the current
[resource workflow](RESOURCE-WORKFLOW.md). Other chats keep their slots.

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

For a collection without the NVIDIA device subprocess, pass
`--no-gpu-device-sensor` directly to `iw7_watch.py`. It skips both `nvidia-smi`
discovery and launch, recording `gpu_device` coverage as `disabled_by_request`,
never as zero GPU use. Omit the flag to retain the existing discovery, command
and three-second timeout. This does not disable native DXGI budget records or
the separate PresentMon launcher in `Debug-Session.ps1`; that wrapper does not
forward this option. No performance improvement is established by disabling it.

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

PageHeap (2026-11-09): every Build-Voice image carries an `arxan.cpp` overlay that
leaves Windows PageHeap headers alone when the process has `-paris-pageheap` and
`-paris-isolated-lab` and PageHeap is really active. Without it, full PageHeap
stopped a build before game start (2026-10-04, `0xC0000005`). It has not been
retested under PageHeap. The retired `-paris-voice-native-trace` flag no longer
enables it. See docs/VOICE.md.

## Evidence and optimization discipline

Use exact hashes, source commit, process creation, fresh phases and a defined
stimulus. Preserve the pre-error data and matching PDB before rebuilding. Parser
success, native compilation, startup, automatic fixture behavior and owner gameplay
acceptance are different witnesses. Compare repeated A/B under the same map,
actors, settings, phase, duration and resource pressure; measure instrumented
versus uninstrumented overhead before accepting a performance improvement.

The compatible `high_pressure_samples` counter still counts samples with
`commit_percent >85`, and `pressure_free` only means neither compared trace
contains such a sample. The `resource.pressure` alert retains the raw percentages
and explicitly labels this legacy heuristic. These fields alone neither invalidate
an observation nor establish available capacity or memory exhaustion; they are not
admission or stop rules. A performance report remains an observation requiring
scenario, repetition and instrumentation-overhead controls.

### Declared phases and comparison windows

Legacy `metrics`, `hotspots` and comparison `changes` remain all-row descriptive
observations. Equal generic labels (or two absent contexts) never make
`contexts_match` true. A separate `phase` report and `phase_comparison` expose
closed-window values, exclusions and channel coverage. They do not establish an
optimization, actual game workload or owner acceptance.

For a future authorized collection, `iw7_watch.py --comparison-context <json>`
requires explicit `--measurement-start-seconds` and `--measurement-end-seconds`.
Both offsets must lie within `--seconds`, after the selected warmup. For example,
30 seconds of warmup followed by 120 measured seconds uses collection 150,
start 30 and end 150; the window is not extended when samples are missing.

`Debug-Session.ps1` forwards the same optional declarations to the watcher. For a
future separately authorized observation of an existing debugger lab:

```powershell
./ops/Debug-Session.ps1 -Action Observe -Seconds 150 -SkipPresentMon `
    -ComparisonContext ./runtime/debugger/context.local.json `
    -MeasurementStartSeconds 30 -MeasurementEndSeconds 150
```

Supply all three comparison options together. The offsets are whole seconds and
must satisfy `30 <= start < end <= Seconds`, using the watcher's default 30-second
warmup. Invalid combinations are refused before operational paths are used. The
helper forwards the context path without copying its schema/parser; the watcher
validates that context. Calls without comparison options keep their existing
behavior. This forwarding does not synchronize CPU acquisition or native flush
boundaries: an unsupported edge or gap leaves the fixed window descriptive or
incomparable. Context declarations do not attest actual phase, actors, pending
work, camera or settings, and this example grants no game or observation approval.

The context is a closed object with these required declarations:

```json
{
  "map": "cp_zmb",
  "phase": "round_active",
  "declared_clients": 1,
  "actors": {"zombies": 24},
  "pending": {"spawns": 0},
  "resolution": "not_applicable",
  "scale": "not_applicable",
  "options": {"dedicated": true},
  "config_hashes": {"server": "<lowercase SHA256>"},
  "script_hashes": {"scripts": "<lowercase SHA256>"},
  "builds": {"Server": "<target image lowercase SHA256>"}
}
```

Replace the explanatory hash strings with actual 64-character hashes. Counts are
explicit nonnegative integers, not booleans/default zero. Options are nonempty,
finite scalar declarations. Rendering requires positive `[width,height]` and
scale; the exact pair `not_applicable` is for headless collections only, not
unknown client settings. Build keys must match the collection targets and their
image pins. Config/script/build declarations are not automatic game-state
attestation. Compare controls exactly; build differences are displayed separately
as experimental variables, never silently treated as equal controls.

The header records a unique collection ID, requested measurement bounds and the
observed collection start in `windows.GetTickCount64.ms`. Its matching complete
row records the observed end and completion state. `monotonic` still schedules
the observer; UTC is display metadata. Neither is silently substituted for that
clock. An absent/invalid footer, mixed clocks, unequal phase durations or an
uncollected part of the window prevents qualified phase differences.
The collector takes a final acquisition at/after its requested duration before
writing completion; this does not move the requested measurement bounds. Native
periods still need actual emitted bounds: the final collector read alone does
not prove that a native channel covers the end.

CPU/I/O phase periods conservatively span the previous process-sample acquisition
start through its current end in GetTickCount64. CPU rates use separate
`python.perf_counter.seconds` brackets immediately around `obs.sample()`, before
threads or UDP work. The actual process counter read is inside that envelope;
the minimum/maximum possible elapsed intervals give lower/upper CPU percentages.
The midpoint estimate remains descriptive. Phase comparison reports p95 bounds
and does not qualify an apparent CPU delta when the ranges overlap. The clocks
are not mapped or substituted for one another; millisecond phase readings have
GetTickCount64 quantization, while rate brackets use perf_counter resolution.
Threads have their own acquisition/rate brackets, and UDP has its own bracket.
Memory snapshots retain only their process-acquisition brackets. Native `tick_ms` is preserved
as emission time; late ingestion never moves an old row into the current phase.
Only actual Source period bounds are used, including `server_ticks.window_ms`.
Unbounded render windows, GPU acquisition times and inclusive timing scopes stay
descriptive rather than deriving a period from a rate or ingestion timestamp.

Only periods entirely inside the closed window supply phase values; crossing
periods are excluded without prorating. Known temporal envelopes remain diagnostic
only: `observed_start_ms`/`observed_end_ms` report their overlap with the window.
Only fully contained periods with accepted metric values, after CPU rate-bound
validation where required, supply coverage. `accepted_start_ms`/`accepted_end_ms`
report that support's extent; even matching both window edges does not fill an
internal gap. Each channel reports count, both extents, exclusions and whether the
union of accepted periods covers the unchanged requested window. Unsupported
edges or gaps leave that channel descriptive with `uncovered_measurement_window`;
the window is never moved or shortened to match available values. Memory/thread/
UDP acquisition brackets describe snapshot uncertainty, not continuous coverage;
their phase-filtered values therefore remain descriptive. A missing/ambiguous interval or relevant coverage gap prevents that
channel's qualified difference without invalidating other covered channels.
PresentMon remains separate per PID/swapchain: without an explicit temporal clock
correspondence, it never becomes a qualified CPU/native phase comparison.

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
