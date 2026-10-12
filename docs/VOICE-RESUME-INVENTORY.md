# Voice resumption inventory - 2026-10-12

This is a source-only, read-only evidence audit for the coordinated voice work.
It starts from private `origin/main`
`21b91e3ebace48fda5ed60024719168064b2cca5`. No game, native build, audio capture,
ASR, native Add-Type, resource reservation, deployment or deletion was performed.
Only this document and ignored local inventories were created. Publication and
future experiments belong to the parent coordinator; no other chat's files were
modified. All availability observations below are dated, not launch permission.

[PR127](https://github.com/maxis0191/iw7-paris-server/pull/127) was independently
queried: MERGED, head `097f7cbc360fddb90bef1abd98756efb7248b682`, merge
`87de0a7deabf18e977713b9138d4310b037fe838`.
[Issue4](https://github.com/maxis0191/iw7-paris-server/issues/4) remains OPEN.
The current [speech witness](VOICE-SPEECH-WITNESS-2026-10-11.md) supersedes
the runtime blocker in [PR126's historical recovery](VOICE-E2E-RECOVERY.md).
The normal-exit recorder and PTT recovery must not be redone as current defects.
PR127's documented CI admission exception remains historical, not a new CI pass.

## Evidence state

Runs19 and20 are present, not merely mentioned in Git. Their result, native PCM,
recorder closure/cleanup, WAV, conversion, frozen ASR and correlation files were
read directly. Thirty-two recorded hash links across the two cases were
recomputed successfully. Six original WAV headers also pass PCM16, RIFF/data
length, channel, rate and duration checks. No acoustic analysis was rerun.

| Boundary | Run19, A to B | Run20, B to A | Meaning |
| --- | --- | --- | --- |
| Whole case | Passed/Restored true; Failure/CleanupError null | Same | Completed historical controlled lifecycle |
| Recorder | Completed; exit0; producer EOF; ownership resolved | Same | Actual closed process-tree recording |
| Cleanup | HelperClosed; phase Closed; source/WAV guards closed | Same | Terminal receipts supersede initial helper snapshots |
| Native PCM | 205 frames; 65,600 bytes in each stream | 204 frames; 65,280 bytes in each stream | Actual decoder and accepted enqueue output |
| PCM format | Mono PCM16,8192Hz;4.00390625s | Mono PCM16,8192Hz;3.984375s | Verified retained file headers |
| Surface | No truncation/failure; originals forwarded; receiver source unread | Same;204 samples,184 playing | Getter observations, not human listening |
| Final recording | Stereo PCM16,48kHz;11.97s;2,298,284 bytes | Same | Final process-tree mix exists |
| Frozen ASR controls | Source all four words, silence empty | Same | No reference prompt; default VAD0.5 |
| Native ASR | `Alpha 7, Blue Lantern` for decoded and submitted | Same, with punctuation | Controlled native word evidence |
| Final ASR left/right | `Alpha-7. We might do that.` / `Alpha-shovel. Blue legend.` | `Alpha-Chev and Blue Mindy.` / `Alpha Shepherd Blue Minded.` | Complete final-word acceptance remains open |

The two final WAV SHA256 values are:

- Run19: `D15C75C691A63AEA9116EDD2433B23A7371E7CC70856441DC785975A128679E8`.
- Run20: `30B44131FE93F06364FFBC188539AA54254DF42D95D5052458A77D85D5BAC2FD`.

Decoded and submitted WAVs have the same bytes within each case:

- Run19: `811DF4BEFE82E6A507751F9FD4F5E4F6B40E7C058AEEFB4371DEF9D8896F988B`.
- Run20: `0111188602B16EC5BE3B3306FC9212ADF0618941744970D5B7CB3AF7844E8DE5`.

Retained correlation results locate speech in both final channels: run19
lag1801.5625ms, correlations0.591/0.578, gains0.980/0.986, residual RMS2532/2634
against native1891; run20 lag1741.5625ms, correlations0.774/0.809,
gains0.986/0.985, residual1510/1340 against native1874. These are existing
measurements whose raw-result hashes were checked, not new measurements.
Unmatched output cannot identify its cause by itself: game audio, DSP effects
and another signal remain hypotheses. No active movie was observed in these
witnesses; successful active cinematic suppression is not established.

Keep `NativeDecodeSucceeded=false` in the legacy outer witness separate from
the independently closed native PCM receipts and ASR results. Conversely,
`Passed=true` is not final intelligibility or microphone acceptance. Initial
`recorder-helper.local.json` says ImagePresent/Closed=false; the terminal
`recorder-0005-cleanup.local.json` and source closure record successful closure.
Do not diagnose a current helper leak from that initial snapshot.

The run19 outer counter window has182 encoded/sent,205 relayed/playback calls,
280 diagnostic packets; run20 has204 encoded/sent/playback,18 relay delta,
300 diagnostic packets. They are different sampling windows, not loss ratios or
one cumulative frame count. Native PCM byte/frame evidence is separate.

## Observed local locations

For compact paths, define these exact observed roots:

| Alias | Absolute path |
| --- | --- |
| V | `C:/Users/ezvalo/.codex/worktrees/voice-e2e/IW7-Paris-Server` |
| D | `C:/Users/ezvalo/.codex/worktrees/modular-agent-platform/IW7-Paris-Server` |
| W | `C:/Users/ezvalo/.codex/worktrees/voice-resume-inventory/IW7-Paris-Server` |
| R19 | `V/runtime/voice-pair/20261011-054037-977-4ae1da46` |
| R20 | `V/runtime/voice-pair/20261011-054913-317-08054c08` |

V exists, is detached at the PR127 merge and reported clean tracked status.
D is an artifact donor only; its old dirty source is not the execution baseline.
Ignored `W/runtime/voice-resume-inventory.local.json` retains exact paths,
file lengths/times, checked hashes, WAV headers and metadata comparison results.
Raw player identifiers, nonces, audio, tools and bank content stay outside Git.

### Executable, source, symbols and helpers

| Artifact | Observed location | Audit result |
| --- | --- | --- |
| Latest retained witness package | `V/runtime/voice-package/iw7-paris-voice.exe` | 6,503,424 bytes; fresh SHA256 matches manifest and both runs |
| Build manifest | `V/runtime/voice-package/build-manifest.json` | 15,140 bytes; recorded isolated-modules, ServerModules/Debugger/FakeCapture true |
| Compiler output | `V/tools/iw7-mod-native/build/bin/x64/Release/iw7-mod.exe` | Present,6,503,424 bytes; metadata only |
| Matching symbol directory | `V/runtime/voice-symbols/A3A2147EDF966313A842134CC046540390BCA646829A1DD729D7799408108287/` | Trace EXE6,503,424 bytes; `iw7-mod.pdb`55,021,568 bytes; no PDB copy/hash |
| Recorder EXE | `V/runtime/audio-output-probe.exe` | 416,256 bytes; fresh hash matches both actual run helper receipts |
| Recorder C# ownership provider | `V/ops/voice-agent/Recorder-Probe.cs` | Fresh hash matches run source receipts |
| Launch reference | `V/runtime/run-speech-pair.ps1` | Read only; stale candidate path, do not execute unchanged |
| Reviewed current runner | `ops/Voice-Pair-Lab.ps1`, `ops/voice-agent/` | Same tracked versions between PR127 and audited main; source pins still required |
| Build tree | `V/tools/iw7-mod-native/` | Present; reuse in place only after later coordinated admission; no SDK/tool copy |

The package hash is
`A3A2147EDF966313A842134CC046540390BCA646829A1DD729D7799408108287`.
Manifest build time is2026-10-11T05:30:52.2654925Z; ProjectCommit is
`a4b9cc62a377efa25078e3fd53ccff841fcf4308`, **ProjectDirty=true**; pinned Aurora is
`77e6d4d24e918ee363b3feee3735c3b889dff7d7`. Do not describe this executable as
a clean build of that commit or of current main. All34 manifest SourceHashes
match V;33/34 match current main. The differing file is `paris_test_fixture.cpp`.
The runner's package/native-source gate will therefore refuse this package from
current main. Review/pin a coherent baseline or perform one coordinated later
incremental build after integration; never bypass the mismatch or replace its
manifest hashes to pretend it matches.

Current recorder EXE SHA256:
`2F31C6DEF719DC91FD152FD9E84120CC7082B1C01E22F94FD78DC48AA596700B`.
Current Recorder-Probe.cs SHA256:
`F737F52570CB3153DD9ACC45039F0800F7DB55B084615FB77FED7E4C31DD5954`.
`V/runtime/receiver-probe-build.local.json` is an older02:13 receipt with EXE
hashF046B821, superseded by the current05:29 EXE and run19/20 helper pins.
It must not be used as the latest binary pin. The run helper image paths were
temporary and their terminal deletion receipts exist; missing helper images are
expected after cleanup. Preserve original closure evidence rather than recreate
those historical paths.

### WAV, ASR and analysis tools

Within each R19/R20, the useful files are:

- `result.local.json`, `voice-witness.local.json`, `plan.local.json`.
- `voice-witness/receiver.wav`, `native-receiver-decoded.wav`,
  `native-receiver-submitted.wav`, `native-receiver.json`,
  `native-receiver-proof.local.json`, `recorder-0004-closure.local.json`,
  `recorder-0005-cleanup.local.json`, `recorder-0006-result.local.json`,
  `recorder-0007-source-closure.local.json`.
- `native-pcm-dictation/provenance.local.json`, `decoded.wav`, `submitted.wav`.
- `receiver-dictation/channels.local.json`, `left.wav`, `right.wav`.
- `whisper-vad/results.local.json` and the six frozen per-input JSON results.
- `playback-correlation/provenance.local.json`, `raw.json`.

Both fixture files still exist under
`D/runtime/voice-agent/short-speech-20261007-v4/`,128,044 bytes each. Their fresh
hashes match speechC2D4B48B and silenceF751FD70 recorded in the witness document.
Speech is four-second PCM16 mono16kHz, `Alpha seven. Blue lantern.`.

| Tool | Observed location | Verification boundary |
| --- | --- | --- |
| Whisper CLI | `V/tools/whisper-cpp/b5454/Release/whisper-cli.exe` | 479,744 bytes; fresh hash331DBA46 matches retained provenance |
| base.en model | `V/tools/whisper-cpp/ggml-base.en.bin` | 147,964,211 bytes; metadata only, retained pinA03779C8; not rehashed/copied |
| Silero VAD | `V/tools/whisper-cpp/ggml-silero-v6.2.0.bin` | 885,098 bytes; fresh hash2AA269B7 matches retained provenance |
| Tool provenance | `V/tools/whisper-cpp/provenance.local.json` | b5454, pinned model/VAD revisions and default threshold0.5 |
| ASR sources/runtime | `V/runtime/offline-asr-tool/ops/voice-agent/offline-asr/` | Present; no compilation or recognizer start |
| Latest cited SAPI package | `V/runtime/offline-asr-tool/runtime/offline-asr/package-20261011-055730-088-b9108394/package.local.json` | Present; fresh manifest hash matches R20 provenance |
| Analysis entry points | `V/runtime/analyze-receiver.ps1`, `analyze-native-pcm.ps1`, `analyze-whisper-vad.ps1`, `compare-playback.ps1` | Read/reuse sources; old scripts write into CaseRoot and reject existing outputs |
| FFmpeg | `C:/Users/ezvalo/AppData/Local/Microsoft/WinGet/Packages/Gyan.FFmpeg_Microsoft.Winget.Source_8wekyb3d8bbwe/ffmpeg-8.1.2-full_build/bin/ffmpeg.exe` | Present,242,496,512 bytes; metadata only |

Do not run the old analysis scripts over R19/R20: they are completed evidence
directories. New analysis needs a fresh small output location and retained input
pins, without copying original evidence. No upstream lookup was repeated.

## Stock: original path missing, alternatives not yet admitted

The historical CandidateRoot/StockRoot
`C:/Users/ezvalo/.codex/worktrees/agent-debugger/IW7-Paris-Server/runtime/isolated-lab/server`
does **not** exist now. Its outer worktree directory contains only the app name
marker. `map-vote-visible` similarly has only its outer marker. This audit found
no relocation record in the targeted manifest/documents; it cannot determine
whether the former roots were archived, moved elsewhere or removed. Missing paths
do not authorize reconstructing stock or restoring an entire archived worktree.

The reviewed stock manifest remains at
`D/runtime/agent-pair-inventory-20261007-v2/reviewed-stock.local.json`:
1,166 files,84,460,946,033 logical bytes. Its canonical sorted-JSON hash freshly
matches `D152B7A8798DBD3E11F7580DD0E780CD120D65D290FDA883AFBE069608B6D4F5`.
This is a manifest hash, not a fresh hash of84GB of retail assets.

Two previously documented candidate roots still have every one of those1,166
relative paths at the manifest length, using targeted metadata checks only:

| Candidate | Absolute root | Conditions still open |
| --- | --- | --- |
| Take | `C:/Users/ezvalo/.codex/worktrees/take-public/IW7-Paris-Server/runtime/take-test-server` | Correct isolated marker present; no removed-stock marker;1,165 listed files currently lack ReadOnly |
| Doom | `C:/Users/ezvalo/.codex/worktrees/spaceland-doom/IW7-Paris-Server/runtime/doom-server` | No isolated marker at expected path; no removed-stock marker;1,165 listed files currently lack ReadOnly |

One Take DLL's queried NTFS file ID matches the retained peer preparation
receipt (`amd_ags_x64.dll`,file ID00020000001D98C3). Take's `iw7_ship.exe`
currently lists only its own hardlink path. Neither sample certifies the whole
stock or proves a relocation. Presence/length is not content identity, immutability,
ownership, vacancy or startup acceptance. No process/port/resource ownership was
adopted by this audit. Preserve both candidates; parent must establish exact
ownership and complete stock compatibility before selecting one. Do not set
ReadOnly on shared retail links, create a fake marker, or lower stock guards merely
to satisfy the launcher. Old reviews claiming all1,166 files read-only are stale.

The base game remains the ordinary client source at
`C:/Users/ezvalo/Desktop/iw_game_files`. A simultaneous receiver requires a
separate identity/profile; the later reviewed pair can use immutable hardlinks
with a documented reason. Sequential comparisons reuse the base client. No full
game, SDK, model, PDB or evidence copy is needed for this inventory.

### Candidate identified from the current admin/network lots

A subsequent targeted source/receipt audit identifies the actual retained
dedicated used by both original sessions. **CandidateRoot is**
`C:/Users/ezvalo/.codex/worktrees/take-public/IW7-Paris-Server/runtime/take-test-server`.
This is backed by both cases' `identity.local.json` image parent and
`backup/recovery.local.json.GameRoot`, rather than inferred from an old guide.

| Evidence owner | Observed source head | Latest cold case relative to its checkout | Recorded result |
| --- | --- | --- | --- |
| `owner-admin-commands`, chat `Ajouter des commandes admin privées` | `4c3095251e9f0f65da6c089048900b5270c1bf31` | `runtime/cold-afk-cold-20261012-014621-242` | Ready=true,Restored=true,Failure=null; recovery transaction Restored=true |
| `network-rejoin-fire-sale`, chat `Diagnostiquer lags et déconnexions` | `a5ae3dc8871277a115ea31297f6fd723081b696e` | `runtime/cold-afk-cold-20261012-015151-633` | Same |

Both checkout paths are
`C:/Users/ezvalo/.codex/worktrees/<evidence-owner>/IW7-Paris-Server`.
Both historical process identities point to the candidate's
`iw7-canonical-main.exe`, created at01:46:28Z and01:51:59Z respectively on
2026-10-12. Both cold outputs report Beast/`cp_final`,95 free canonical slots;
their short server logs contain
`[Paris test privacy] private=1 lan_only=1 heartbeat_suppressed=1`.
These are their executed startup/restoration receipts, not tests run by this
inventory chat. They do not establish voice behavior or current vacancy.

The admin protected-client attempt
`runtime/owner-test-20261012-014129-796/result.local.json` separately records
Complete=false,Restored=false and resource-admission refusal before the runtime
transaction. That result must not be confused with the later successful cold
case, nor used alone to diagnose an unrestored dedicated. The docs
`docs/OWNER-COMMANDS.md` and `docs/REJOIN-NETWORK-TESTS.md` retain the respective
client-test limits. No process, reservation or client has been adopted here.

**StockRoot distinction:** these current one-client/cold helpers accept
CandidateRoot and GameRoot; they have no independent StockRoot parameter.
The candidate contains the retail files in place. For a future voice pair,
the precise proposed `StockRoot` is therefore **the same retained candidate
root**, subject to the reviewed pair-manifest/content/ownership checks. The
admin/network cold results are not a validation of peer hardlink preparation.
There is no newly found separate stock cache and no reason to reconstruct84GB.

Targeted metadata confirms the candidate, its isolated marker, and
`iw7-mod/lab-appdata/cdata/custom_scripts` still exist. At this observation the
`agent-peer` subdirectory and `STOCK-ASSETS-REMOVED.json` are absent. Existence of
cdata does not certify its complete identity-free peer bootstrap contract.
The base client remains `C:/Users/ezvalo/Desktop/iw_game_files`.

**Ownership versus state:** the physical retained root belongs to the Take
workspace; the admin and network sessions are its latest observed scenario
users and remain the coordination owners until the parent releases their slot.
Their last case receipts say restored. Live process/port/lease ownership and
availability for the next run were deliberately not queried or claimed here.
Only the parent may schedule reuse after those sessions finish and fresh normal
vacancy/admission checks pass. A completed source task alone is not that check.

The relevant existing source helpers, inspected without importing/executing them:

- `ops/Test-AfkRuntime.ps1` (both lots) reuses CandidateRoot in Cold mode,
  snapshots mutable files/profiles/bank through `Save-IW7BaseTransaction`, and
  restores them after owned-process closure. It does not prepare retail stock.
  `ops/Test-OwnerAdmin.ps1` and `ops/Test-RejoinFireSale.ps1` likewise reuse the
  marked candidate plus a temporary base-client executable; their12GiB runtime
  scope is separate from the voice pair's20/20GiB scope.
- `ops/Agent-Pair.Core.ps1` / `ops/Agent-Pair.ps1` in the audited21b91e3 source
  are unchanged in the inspected network head. `Get-IW7AgentPairStockManifest
  -InventoryOnly` reads path/length metadata without asset hashes.
  `Get-IW7AgentPairManifestHash` hashes the small canonical manifest only.
  `Invoke-IW7AgentPairPrepare` requires exact full admission, base vacancy,
  reviewed manifest, same-volume NTFS and bounded identity-free retained cdata;
  it hashes each source once under retained FileShare.Read handles, creates and
  verifies hardlinks, and copies only the candidate executable/bootstrap bytes.
  It has no physical-stock-copy fallback. Preparation/restoration is an owned
  transaction, not an instruction to manually create aliases or a marker.
- **Correction to interpreting the earlier ReadOnly observation:** the pair
  helper does not test or set the filesystem ReadOnly attribute. Missing ReadOnly
  is not itself a launcher refusal. The source/alias handles deny writes during
  preparation, and are explicitly released before gameplay. Therefore neither
  that flag nor the short cold tests certify stock immutability for the entire
  subsequent pair. Preserve shared attributes; apply the existing ownership,
  source-identity and runtime safeguards, rather than restore attributes or
  fabricate an additional gate. No stock helper or hash sweep ran in this audit.
- Network commit `59fc847717c55141d6a4e2e65dc37df99fe8e416` adds `sv_lanOnly 1`
  before startup and in the voice pair config, plus the native
  `ops/Apply-TestPrivacyOverlay.ps1` heartbeat suppression used by those cold
  runs. Parent must integrate that current privacy behavior into its coherent
  voice helper/build selection; old V alone predates it. Do not mix a new wrapper
  and old package and call privacy validated. Source hashes/build provenance
  remain mandatory. These are observed branch revisions, not a new merge claim.
- Do **not** use `ops/Isolated-Lab.ps1 -Action Prepare` to recover the missing
  agent-debugger root: its preparation path performs a physical `robocopy` stock
  snapshot and sets stock attributes before making lab aliases. It is not the
  reuse operation requested here. No cleanup, restoration, copy, attribute change,
  whole-disk inventory or asset rehash was performed in this follow-up.

## Budget and ordered continuation

Parent supplied C:free203,818,287,104 bytes. A later audit sample was
203,305,455,616 bytes (about189.34GiB); unrelated concurrent activity prevents
attributing that change to this task. These values replace neither a fresh
admission check nor the conservative budget: preparation at most100,000,000 bytes
per chat/1,000,000,000 combined; future additional disk use at most10,000,000,000 bytes.
The parent's later10-chat modding/voice instruction supersedes the earlier
400,000,000-byte four-chat preparation cap; all other reuse constraints remain.
The source tree starts at6,314,902 Git blob bytes; only a small document/JSON are
added. Disk allowance is not RAM/commit admission.

### Expanded session footprint: modding and voice

The parent broadened the coordinated work to a BO3-like/H1/ZoneTool modding
platform. This addition inventories only the11 new source worktrees:10 delegated
lots plus the integration parent. It changes neither the voice evidence above
nor the prohibition on heavy work in this lot.

The bounded metadata snapshot ran2026-10-12T01:46:15Z through01:46:16Z
(03:46 Paris). Each selected outer directory was observed created during the
current session between01:33:51Z and01:40:13Z and appears in Git's worktree list.
Every row is rooted at `C:/Users/ezvalo/.codex/worktrees/<name>/`; its checkout is
the `IW7-Paris-Server` child. Sizes include files in that outer root, including
small ignored outputs and the worktree pointer; they are not just tracked blobs.

| Exact new worktree name | Files | Logical bytes |
| --- | ---: | ---: |
| modding-agent-capabilities | 696 | 6,355,568 |
| modding-animation-ai | 695 | 6,359,984 |
| modding-content-surfaces | 694 | 6,359,795 |
| modding-distribution | 697 | 6,390,231 |
| modding-h1-model-bridge | 698 | 6,365,294 |
| modding-sdk-contract | 701 | 6,411,111 |
| voice-acceptance-integration | 693 | 6,341,329 |
| voice-control-acceptance | 696 | 6,370,246 |
| voice-final-mix | 693 | 6,349,794 |
| voice-mp-readiness | 705 | 6,353,870 |
| voice-resume-inventory | 694 | 6,385,914 |
| **Total source-worktree roots** | **7,662** | **70,043,136** |

The11 exact separate Git administration directories, resolved with
`git rev-parse --absolute-git-dir` under the existing shared repository's
`.git/worktrees/`, add92 files/791,669 bytes. The combined measured file-length
sum is **70,834,805 bytes (70.83 decimal MB)**. Every worktree is below100MB and
the measured scope is below the1GB preparation budget. The integration parent's
6,341,329-byte measurement is consistent with its earlier6.34MB report; file
counts include outer metadata and source edits underway during this snapshot.

No directory traversal limit was hit (10,000 files per root, depth12); no reparse
point was followed or encountered. The metadata-only walk did not hash assets,
read binaries, invoke a build or inspect old runtime trees. It excludes
`voice-e2e`, `voice-live-diagnosis`, `voice-production-audit`, all older worktrees,
shared Git object storage, session logs and other applications. Logical file
lengths are not unique NTFS allocation or an attribution of volume free-space
change. Concurrent edits also mean this is a bounded snapshot, not an atomic
volume census. The small audit JSON and this later document update are subsequent
writes, not silently folded into those snapshot totals.

There is **no observed SDK/game/runtime download or large binary copy** in this
scope. Five `.exe`-named files in
`voice-mp-readiness/IW7-Paris-Server/runtime/installer-check-67d8df20facf4efda0cc3caf4f2d407e/`
are24-43 bytes each,185 bytes combined. They are below the size of a Windows PE
header, in a test-fixture layout, and do not represent a copied runtime. That
runtime directory totals1,606 bytes. No new `tools`, `compiled` or `backups`
tree appears in the selected worktrees at this snapshot; the inventory lot's
existing ignored voice JSON was30,421 bytes. Existing SDK/helpers/stock/PDB/WAV
must continue to be reused in place.

Parent's free-C observations were203,818,287,104 then203,000,266,752 bytes.
This snapshot measured202,883,006,464 bytes. The difference is an unattributed
system observation; it must not be reported as these worktrees' disk consumption.
The reproducible per-root totals, exact Git metadata paths, size buckets, largest
files and bounds are saved in ignored
`W/runtime/session-worktree-footprint.local.json`. Any later appearance of a
large SDK/runtime copy or projected budget breach should be reported immediately
to the coordinator before further preparation; do not delete files to hide it.

### Voice experiment sequence

1. **Unique next experiment: independent listening of the retained final output.**
   Use R19/R20 `voice-witness/receiver.wav` unchanged, plus the existing native
   conversions and silence control. Parent coordinates a listener who has not
   been told the phrase; randomize labels, record their words and uncertainty
   before revealing expected words. Do not count a phrase-informed listener as
   blind evidence. Preserve native-versus-final responses separately. Budget:
   no game, build, download or recording; originals read in place; at most10MB
   new labels/assessment metadata, about10minutes. No assessment happened here.
   This directly addresses the unresolved boundary without repeating known-good
   recorder/codec runs. It can distinguish apparent ASR failure from obvious
   audible masking, but cannot establish a particular mixing cause.
2. Parent reconciles that assessment with the other source lots and integrates
   one coherent candidate. If final audio remains unclear, select exactly one
   falsifiable mix/playback change and one A-to-B comparison against retained
   baseline. Do not repeat all20 historical trials or raise codec quality on the
   strength of run14, which never reached its quality-change observation.
3. Only after the two competing sessions finish, recheck base-client vacancy,
   test-dedicated identity/stock/mutable backups and the current scheduler. Fix
   stale paths/source alignment first. A necessary incremental build reuses V's
   existing dependencies, only after coordinated source review and a4GiB RAM/
   6GiB commit build admission; do not compile alongside a gameplay group.
   Preserve the existing successful EXE, manifest and symbols without duplicating
   the whole tool tree. Rebudget or stop before disk growth exceeds10GB.
4. One future reduced, audio-enabled pair requires the full20GiB RAM/20GiB
   commit group, reserve0 RAM, independent20% commit headroom (minimum4GiB),
   and no simultaneous build/ASR. Main27016 and owner processes remain untouched.
   Historical ports27116/27117/27118 require fresh vacancy, not assumptions.
   Keep debugger activation absent, source clock after native PTT, original
   500ms freshness deadlines, preparation120s, settle at most60s, witness29s,
   PCM scope15s and recorder12s. Verify fresh engine godmode/inactivity0/cheats0
   for both roles before exposure/ARM.
5. Close and restore the whole pair before optional offline analysis. Existing
   analysis uses a separate2GiB RAM/3GiB commit lease; frozen source/silence
   controls precede receiver scoring, no prompt/reference vocabulary. Initial
   per-experiment allowance: at most250MB for WAV/log/JSON outputs; profile/bank
   rollback size is measured separately and charged to the10GB total. Stop if
   the actual backup/output projection cannot fit, rather than delete evidence.
6. After the changed final path passes, exercise B-to-A once, then separately
   released-PTT negative audio, mute/unmute, reconnect and map transition. PTT-up
   cleanup already occurred in19/20; that is not an independent released-PTT
   negative recording. Advance to ordinary physical devices, independent PCs,
   LAN/WAN, ordinary-client compatibility and Multiplayer only with their own
   bounded cases. Never turn local synthetic success into any of those passes.

## Stop, restoration and closure conditions

- Stop before mutation for occupied/unidentified owner processes, competing
  session/resource ownership, absent stock/path/marker, mismatched package/source,
  unreviewed shared retail mutability or projected disk/admission failure.
- During a future run, cancel on stale/lost original identity, nonce/generation,
  protection, ARM/recorder deadlines, failed native closure, unknown descendants,
  decoder truncation/surface failure, resource high-water policy or unexpected
  owner use. Do not renew timestamps, relax500ms, delete a lease or silently
  use a default audio endpoint. UDP silence alone is not crash evidence.
- Release native PTT, cancel both synthetic sources, finish original recorder
  exit/EOF/WAV/source closure, then stop only exact owned clients. Normal dedicated
  stop requires live zero clients for30s; confirmed fatal recovery retains
  diagnostics and exact executable/config/creation identity. If identity or
  recorder cleanup is unresolved, preserve evidence, transaction and reservation;
  do not reuse the runtime or continue another experiment.
- Restore every changed base/candidate binary, script, configuration, player
  profile, lab identity and bank from its pre-test existence/hash manifest after
  processes close. Verify byte equality and original absent paths. No Windows
  audio configuration, Main27016 change, application shutdown or purchase is part
  of this continuation. Missing historical helper files are expected cleanup;
  missing retail roots are a separate readiness problem.
- Close a technical case only with original recorder/helper/source ownership
  resolved, processes gone, stock/profile/bank restoration checked, lease normally
  released, Failure/CleanupError null and hashes archived locally. Acoustic
  acceptance is separately recorded; failure evidence stays available.
- Parent owns final cross-lot diff review, coherent commits/private PR, exact-head
  CI (or freshly documented applicable quota exception), merge and synchronized
  clean main under [GIT-WORKFLOW.md](GIT-WORKFLOW.md). Update shared STATE/BUGS/
  VALIDATION/PLAN/CHANGELOG there, outside this document-only ownership. Issue4
  and human/WAN/Multiplayer acceptance remain open; no accepted voice tag or Main
  promotion follows from this inventory.
