# Persistent, scoped Ghidra inspection

The primary goal is reusable control of IW7's own engine and rules. BO3 is an
optional corpus, not a prerequisite. Follow the SDK's
[engine strategy](https://github.com/maxis0191/iw7-creator-sdk/blob/main/docs/ENGINE-MODDING-STRATEGY.md).
This tool supports targeted research; it does not recover a complete engine,
prove an inferred ABI, or remove an existing execution stop.

## Installed components and reproducibility

`ops/Install-ReTools.ps1` reuses explicitly supplied Ghidra and Java installations
and creates a separate Python environment. The package is `pyghidra-mcp` 0.2.7
at upstream commit `42d8f80551a765441b1a723f6f1ff45aa3914d5e`. The accompanying
requirements lock pins the resolved dependency versions, including PyGhidra
3.1.0. The installer verifies VCS provenance and records local paths and source
hashes in `iw7-install.json`. It installs no service and changes no global PATH
or Codex configuration. Installation alone leaves `RuntimeQualified=false`.

The existing local Ghidra 12.1.4/JDK21 installation supplies BSim. It is not
downloaded again. Resolve its paths from the retained toolchain manifest; never
copy machine paths or binary payloads into the repository.

```powershell
./ops/Install-ReTools.ps1 -InstallRoot '<new-or-existing-isolated-venv>' `
  -GhidraRoot '<existing-ghidra>' -JavaRoot '<existing-jdk>' -Python '<python3.12>'
```

Upstream normally schedules whole-program semantic indexing both at startup
and on first access. `ops/re-tools/serve_project.py` instead uses its existing
read-tool handlers with a context that creates no Chroma client or index worker.
It opens an existing local `.gpr/.rep` only, runs no analysis/import, exposes no
edit/import/save/delete tools, and closes the project with `save=False`.
Semantic code/string-index search is deliberately absent. Normal project locks
and read caches still exist; this is not a filesystem sandbox.

## One admitted session, multiple readers

Coordinate an Analysis slot with the execution orchestrator. Use the current
canonical resource helpers, preserve the complete host/child identities, and
keep the reservation until the original session process and children close.
An idle JVM still belongs to that admitted session; do not leave it behind a
released lease. Persistent means repeated queries within a session and reuse of
the saved project between sessions, not an unaccounted permanent service.

Set command-local `JAVA_HOME` to the existing JDK. Submit the following executable
and arguments to the existing reviewed process/job owner under an Analysis lease
(see [resource workflow](RESOURCE-WORKFLOW.md)). The lease wrapper alone is not a
process-tree owner: keep its original handles through shutdown and empty-job
verification. The qualification below reused the existing `NativeJob` provider.

```powershell
& '<venv>/Scripts/python.exe' -B ./ops/re-tools/serve_project.py `
  --project '<approved-project>.gpr' --ghidra '<existing-ghidra>' `
  --state '<local-session-state>' --stop-file '<fresh-stop-file>' `
  --port 8765 --max-seconds 300
```

It binds only `127.0.0.1`. Creating the specified stop file or reaching the
lifetime requests graceful shutdown. In-flight native work can outlast that
request: the outer owner must enforce its timeout and confirm closure. A
second process cannot concurrently edit/open the same locked Ghidra project.
Initial imports, additional analysis and annotation changes remain separate
explicit operations by that project's owner.

Other chats can query the existing session through
`ops/re-tools/query_project.py`, without a Codex restart or a JVM per chat:

```powershell
& '<venv>/Scripts/python.exe' -B ./ops/re-tools/query_project.py list_project_binaries
& '<venv>/Scripts/python.exe' -B ./ops/re-tools/query_project.py decompile_function `
  --arguments '{"binary_name":"/approved.bin","name_or_address":"known_function","timeout_sec":10}'
```

The same endpoint is a standard Streamable HTTP MCP at
`http://127.0.0.1:8765/mcp`. Do not globally enable a connection that every new
chat would expect to be permanently running. The CLI is available for existing
chats; its model compatibility is tested without HTTP, but its command entry
point has not been exercised against the real server. The real test below uses
two inline MCP clients. Optional client registration does not start the server.

## Qualification and limits

`ops/re-tools/qualify_tools.py` creates only 48 authored x64 bytes: two identical
small functions and a different control function. The bytes are analysed, never
executed. An external Windows owner starts the Python root in its original
job and retains the original process/job handles through closure. The script
imports that fixture into a fresh project, compares
actual BSim vectors, then closes it and opens one inspection server. Two MCP
clients make four repeat decompilation requests and test refusal of import.
The fixture checks consistent output and no Chroma creation. Its stdout/stderr
pipes retain at most 1 MiB per child and fail on overflow. Optimized Python is
refused before effects, including inherited `PYTHONOPTIMIZE`. A separate parent
receipt must confirm the original Python root exited and the original job has
zero active processes before releasing the Analysis reservation. The script's
JSON alone does not prove descendant closure. Retain the same owner and lease
when that state is unknown. Reuse the orchestrator's reviewed job owner.
Keep failure logs and fix source before retrying; do not switch to game input.

The generated local qualification JSON records timings and the actual result.
It does not establish an IW7 ABI, cross-game matches, a BSim database search,
concurrent mutation safety, gameplay, or speedup versus the previous adapter.
BSim similarity is a lead: even a perfect match cannot validate transferred types.
Measured engine research remains a separate, narrowly scoped next operation.

## Recorded qualification, 16 October 2026

Source `f721bf95e94a07cf40cc858ff231cc11a0f1951a` passed the authored-fixture test.
Two successive real MCP clients requested four decompilations from the same
server/project and received identical output. Project listing and decompilation
were exercised; nine registered read tools do not mean nine qualified tools.
The unregistered import tool was refused. No Chroma state was created in the
test's state directory, and the server exited zero. The original process owner
observed Python exit zero and zero active job processes before closing handles
and releasing the lease; the host was retained for final coordinator review.

BSim similarity was 1.0 for the duplicate authored functions and 0.0 for the
different control. Decompilation calls took 0.463439, 0.015811, 0.027056 and
0.014341 seconds. These are small-fixture observations, not an IW7 performance
benchmark or a comparison against the previous adapter. Total child test time
was 26.141 seconds; the parent lifecycle completed in 27.543 seconds.

Earlier failures remain in Git history and local evidence: A used an incomplete
Java loader class name; B reached BSim but expected three transport values from
the pinned SDK that yields two; C connected and listed tools but used `isError`
instead of the SDK's `is_error`. Each failed attempt exited one and its original
job closed. The minimal fixes are separate commits. The added three-case
`tests/ops/re_tools_sdk_test.py` passes using real pinned SDK models/signatures
with fake sessions and transport (0.028 seconds in the recorded run); it catches
these client-shape errors without HTTP, Ghidra or a JVM.

Local qualification JSON SHA-256:
`854CA2D1A349F1C38754CECF7C04D44CDFBD04FD2BC2EC8334D954698F59287D`.
Original-host postflight SHA-256:
`DD004A269F411182A3098056973156091906EC7B98411D68FED8499C23C7EEC1`.
Machine paths, process identities and generated project files remain local.

Primary sources: [PyGhidra](https://github.com/NationalSecurityAgency/ghidra/tree/master/Ghidra/Features/PyGhidra),
[pinned MCP source](https://github.com/clearbluejar/pyghidra-mcp/tree/42d8f80551a765441b1a723f6f1ff45aa3914d5e),
[BSim](https://github.com/NationalSecurityAgency/ghidra/tree/master/GhidraDocs/GhidraClass/BSim).
# Scoped capacity crash reader — 2026-10-19

The optional capacity harness reuses the installed Microsoft WinDbg
1.2606.22001.0 package. Its CDB SHA256 is
`5F54ABAFCA3AE5638BBF807D402FABB350A64575C1DFA9FBFC7F5732DF5BEE67`.
For registration within the original candidate Runtime lease, retain only
`cdb.exe`, `dbgeng.dll`, `dbghelp.dll`, `dbgcore.dll` and `dbgmodel.dll` under
the candidate's `iw7-mod/capacity-tools`. Recheck all five against that installed
package before use; retain their sizes/hashes in the local toolchain receipt.
The existing server installer already pins this WinDbg release with IncludeWinDbg.

This does not relax scheduler scope or process admission. The harness may invoke
the reader only after a confirmed fatal of its own exact client, through the
original owned desktop and lease. Noninvasive/nonsuspending `-pvr` capture and
confirmed reader closure precede the normal client/profile restoration. Main
and unrelated clients are never capture targets. The initial out-of-scope AppX
reader was refused and closed; the later scoped offline smoke is tool evidence,
not a successful full live-fatal capture or a gameplay result.

## Engine map

`ops/engine-map/iw7_engine_map.py` is a separate, offline tool. It builds a
SQLite map of the game executable's functions, calls, strings and names from
machine-local section files and turns profiler or crash addresses into function
names. It needs no Ghidra project. See [ENGINE-MAP.md](ENGINE-MAP.md).
