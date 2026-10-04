# Native voice investigation

## Repeated-stimulus calibration failure - 2026-10-04

Candidate 7eb246a passes the first A/B fixed-mode signals, then fails A's repeated
signal. Both VBR and ABR read zero, so disabling VBR does not explain or fix it.
Read-only live encoder checks show native quality=3, cached quality=3 and selected
submode=8 after restoration. The pinned original encode wrapper consumes a pending
quality change before encoding. Returning the selected submode to its earlier
value while leaving that cache consumed desynchronizes the private fixture.

The next correction snapshots/restores the native quality cache together with
the selected mode, only for the same encoder and unchanged quality setting. A
concurrent quality change invalidates restoration evidence and is not overwritten.
Hardware blocks remain suppressed until restoration completes. No codec reset or
production quality policy changes. Require repeat, concurrent and long-stimulus
comparisons before crediting this correction.

The [two-client five-minute soak](deployments/2026-10-04-voice-resource-soak.json)
passes delivery/stability counters and clean exits; its output-tone expectation
fails. The next private calibration also saves/disables/restores VBR and reads
ABR without setting it. This is pending native comparison, not a proven cause.

## Resource and map safeguards - 2026-10-04

Four localhost clients and the dedicated joined with distinct native identities,
complete rosters and 157.594 seconds of protected idle. A single sender delivered
60 frames to each of three receivers (180 server deliveries), but the target-tone
output expectation failed. The four-way paced experiment then aborted and the
owner reported approximately 90% physical-memory use. These are not four-player
voice acceptance. The two extra clients exited with actual code 0; observed system
use fell to 43%. Native capacity needs an adequate resource budget or remote PCs.

Prepare now defaults to two owned clients. Larger groups require explicit
`-MaxClients` at preparation, and every new launch estimates its physical-memory
peak while retaining 25% headroom. Owned test processes remain preserved when the
budget fails. Long-running native drivers also stop accepting evidence above 80%
physical use. Do not launch additional clients simply to complete a matrix row.

`ChangeMap -Map` uses only the five allowlisted maps and an exact owned dedicated
mailbox. Native dispatch requires a protected private loopback party; the helper
requires fresh godmode, inactivity=0, cheats=0, zero enemies and complete current
rosters after loading. Map-transition results remain pending for this candidate.

## Native validation continuation - 2026-10-04

The base harness now permits four distinct owned clients and all five allowlisted
Zombies maps. `Prepare -PrivateDesktop` keeps the owned game windows on a separate
Windows desktop while using the backed-up base installation. It does not create
an independent game installation or reserve CPU/GPU resources.

The private synthetic probe now returns to the main loop between paced capture
blocks. A synchronous 1.2-second stimulus prevented the same client from receiving
while it emitted and therefore could not validate simultaneous speakers. Catch-up
is bounded, connection/session changes abort, and shutdown restores controls.
The helper requires a fresh completion marker and verified codec restoration;
the mailbox acknowledgement alone is insufficient. Native simultaneous-speaker
and map results are pending for this candidate.

The first nonblocking pair (ee936ec) failed calibration: hardware capture remained
active alongside injection, yielding 120 encoded frames instead of 60, and the
configured-mode preservation check failed. Output presence does not validate that
run. The correction replaces hardware blocks only while the private post-device
stimulus is active, consumes their input without queuing a microphone backlog, and
restores the saved configured mode along with the exact VAD/DTX values. Ordinary
capture remains forwarded unchanged outside that explicit synthetic interval.

`VoiceConcurrentProbe` emits 500 paced fixed-mode frames (ten seconds) and
`VoiceSoakProbe` emits 15000 (five minutes), both through native capture/codec and
the normal generic relay. `-DispatchOnly` explicitly acknowledges scheduling so
the other owned clients can start concurrently. It does not assert completion:
the driver must verify all clients throughout, require fresh non-aborted finish
and codec-restore markers, and correlate each sender/receiver counter delta.
Verify requires complete current admission/native roster masks for every owned
generic client. Extended stimuli are private loopback fixtures, never production
device or human-speech acceptance.

## Dvar metadata cache audit - 2026-10-04

The older reconnect dump was audited against its exact executable
`63871CD3863A78DA280A195E7145CF3D2965D7D2AE230D584AE03980579DE6D9`.
Its overwritten PDB was not force-loaded. The reconstructed destructor frame has
RSI `0x1604FC348`; exact PE references identify the surrounding global at
`0x1604FC340` as the name cache used by the dvar registration hook. This mapping
is strongly supported by machine code and the pinned source. The PE contains one
CRT initializer/destructor registration; separate construction cleanup thunks
do not establish double destruction.

The pinned `game/dvars.cpp` name and description maps have unsynchronized readers
and writers. Their static destruction can also overlap native thread activity.
The private build now replaces that cache through the same API, using copies
made under a mutex and a process-lifetime registry. No engine call executes while
that mutex is held. `dvar_metadata.hpp` is generic and independently tested with
four writers, four readers, 200000 updates and a late static-destructor reader.
The build accepts only the pinned source or its exact owned overlay and records
the overlay hash in the manifest.

These changes remove concrete concurrency and shutdown risks. The old dump does
not identify the corrupting write; the original heap incident remains open until
native comparisons provide further evidence. This is not a codec correction or
proof that the relay caused the incident.

Latest reproducible results: [fixed-mode controls and reconnect](deployments/2026-10-04-voice-fixed-mode-controls.json)
pass. The native VAD/DTX path suppresses most of the synthetic target; disabling
it while retaining a previous null submode is also silent. The private control
reapplies the saved configured mode before injection, then restores/verifies
flags and checks that configured mode is preserved. It does not reset the codec
or change production encoding. Human speech and the older heap fault remain open.
Use the current [base runbook](VOICE-BASE-RUNBOOK.md). Sections below retain earlier
failed calibrations; their pending instructions are historical.

Current local signals/negative controls are recorded in
[native control evidence](deployments/2026-10-04-voice-native-controls.json).
Resume/reverse reconnect target tone fails, and a reconnected client exits with
heap corruption. Do not infer voice/lifecycle acceptance from decode counters.
VoiceCodecProbe is a separate private loopback diagnostic: it saves native encoder
VAD/DTX, disables them for the synthetic signal and restores/verifies saved values
before returning. Production codec behavior stays intact. Inspect its restore
marker, encoded bytes/tiny-frame counts, decoded target-frame delta and output.
It has not yet been validated in-game. Broad spectral metrics save no samples.

The generic helper uses `-GenericRelay` on both processes, without UI/legacy
registration witnesses. It permits A reconnect with B staying. VoiceMute/Unmute
and VoiceDisable/Enable use native APIs with exactly one remote. VoiceRestore
restores saved values only for the same session/UID; StopClient restores before
disconnect. These do not prove scoreboard UI or devices. VoiceReleasedProbe
keeps the actual talk binding released. Inspect deltas/markers/output, never
acknowledgment alone. Probe logs include begin/return ticks. The revised stimulus
is twenty 440-Hz prelude frames then forty 997-Hz frames, without codec reset. Keep
the unchanged sixty-frame target-tone failures separate from this diagnostic.

Voice is not accepted. Issue #4 remains open. Trace the original engine path before
choosing a repair; the protocol-v1 overlay remains an unaccepted fallback.

The latest paced static base witness passes synthetic playback in both directions.
[Exact scoped results](deployments/2026-10-04-voice-paced-playback.json) include the
baseline, native deltas and output metrics. It is now closed/restored. A separate
[generic transport core](VOICE-TRANSPORT.md) passes pure reconnect/control tests;
is wired into the separate opt-in v2 runtime. Earlier sections retain historical runs.

## Earlier isolated audio witness

Historical procedure: the owner subsequently requested the base installation.
Use the protected base helper for the current test plan; these isolated commands
remain available for reproducing the earlier investigation.

Use a dedicated worktree and physically independent asset snapshot as described in
[ISOLATED-LAB.md](ISOLATED-LAB.md). Reserve unused loopback ports (this investigation
uses 27316/27317). Never target the normal 27016 or another laboratory's roots.

```powershell
./ops/Isolated-Lab.ps1 -Action Prepare -SourceGameRoot 'YOUR GAME ROOT' -ServerPort 27316 -ClientPort 27317
./ops/Build-Voice.ps1 -ServerModules -IsolatedLab -VoiceTrace
./ops/Test-Sources.ps1
# Commit the tested candidate before installing it.
./ops/Isolated-Lab.ps1 -Action Install -Profile VoiceNative
./ops/Isolated-Lab.ps1 -Action StartServer
./ops/Isolated-Lab.ps1 -Action Status
./ops/Isolated-Lab.ps1 -Action StartClient
# Wait for Common Initialization Complete in the owned client log.
./ops/Isolated-Lab.ps1 -Action Connect
./ops/Isolated-Lab.ps1 -Action Verify
```

Require a fresh actual engine godmode marker for the current map with inactivity=0
and cheats=0. VoiceNative installs only a protection witness alongside maintained
modules; it does not run the cross-map module test or activate Rhino/Rush/kit probes.
It enables native audio explicitly, unlike the silent enemy/module lab profiles.
It preserves the private desktop, per-root AppData/keys, ownership and backups.
The isolated-voice-trace build is refused by ordinary server deployment.

## What is measured

The explicit `-paris-voice-native-trace -paris-voice-audio-lab -paris-isolated-lab`
combination installs forwarding hooks after checking all expected retail entry
signatures. No Paris voice handshake, capability, relay or audio initialization is
performed. Original function arguments, results and routing are preserved.

Ten-second status and `paris_voice_status` report counts, without audio recordings,
names, endpoints or user identifiers:

| Counter | Original engine step |
| --- | --- |
| capture | post-device capture callback |
| encoded | encoded frame entering the legacy queue |
| batch | legacy batch/session-routing invocation |
| send_attempts/send_ok | session-send invocation and its native result |
| received | native `v` packet handler invocation |
| decoded/queued_bytes | native codec and DirectSound queue results |
| session/local_slot/registered/voice_registered | selected native session and user-registration state |

Counters are cumulative, not proof of fresh audio. Correlate before/after deltas,
map/process identity, voice/PTT state and simultaneous active participants.

After Verify, `./ops/Isolated-Lab.ps1 -Action VoiceProbe` requests twenty synthetic
post-device blocks through the unchanged capture/queue/session path. It requires
native audio already initialized, loopback gameplay and voice enabled; it does not
force audio initialization. It pairs the retail +talk/-talk binding during the
synchronous capture call and restores the temporary PTT setting. Native microphone
activity mode reads a separate hardware meter, not the injected PCM block.
Acknowledgment only proves mailbox delivery; inspect the outcome and counter deltas
in the owned client log. A synthetic witness is not human speech or remote delivery.

```powershell
./ops/Isolated-Lab.ps1 -Action StopClient
./ops/Isolated-Lab.ps1 -Action StopServer
```

StopServer still requires thirty seconds of live zero-client replies. Preserve
failed logs and exact build/source hashes locally; commit only sanitized evidence.

For a second technical participant on this machine, close both owned processes,
run PreparePeer with a distinct free PeerPort, then Install VoiceNative again.
Start/connect/Verify client A first. Use `-ClientSlot B` on StartClient, Connect,
Verify, VoiceProbe and StopClient for B. Its mutable root, AppData/identity and port
are independent; its stock links target only this lab's own asset snapshot. Close B
and A before StopServer. This is a same-machine technical witness, not remote speech.

## Owner-authorized base installation test

The owner subsequently requests closing all IW7 instances and moving this work
to the existing base game installation. Close recorded clients through their
owned helpers, stop dedicateds after valid empty replies for thirty seconds, and
verify no IW7 process remains. This supersedes the independent-root restriction
for voice testing only; never deploy the isolated binary to the base installation.

```powershell
./ops/Build-Voice.ps1 -ServerModules
./ops/Test-Sources.ps1
# Commit the tested candidate before preparation.
./ops/Voice-BaseTest.ps1 -Action Prepare -GameRoot 'YOUR EXISTING GAME ROOT'
./ops/Voice-BaseTest.ps1 -Action StartServer
# Wait for a challenge-verified Get-ServerInfo response with sv_running=1,
# mapname=cp_zmb and clients=0 before starting the client.
./ops/Voice-BaseTest.ps1 -Action StartClient
# Wait for Common Initialization Complete in the current client log.
./ops/Voice-BaseTest.ps1 -Action Connect
./ops/Voice-BaseTest.ps1 -Action Verify
./ops/Voice-BaseTest.ps1 -Action VoiceProbe
./ops/Voice-BaseTest.ps1 -Action Capture
```

Prepare requires a verified normal server-only build and all IW7 processes closed.
It backs up every temporary file plus bank data and records recovery metadata
before any managed write. It adds a side-by-side trace executable, two temporary
configs and the protection witness in the existing game root. Original iw7-mod.exe,
normal launchers/configs, current bank, Aurora AppData and owner keys are preserved.
The trace requires `-paris-voice-base-test` plus the appropriate protected server/
client fixture flag. Port 27016, empty fs_game, private access and cheats=0 remain.
Native protection is loopback-only and reapplied on each spawn.

Protection is also maintained every 100 ms after registration. Verify requires a
current native heartbeat for every client and an arena with zero actors, pending
spawns and reservations. The voice witness pauses the retail supplier and removes
unexpected enemies through their normal death lifecycle. Godmode and g_inactivity=0
alone do not prevent retail GSC's separate ninety-second movement kick: the scoped
fixture extends the existing bots kick hook to suppress only
EXE_PLAYERKICKED_INACTIVE for the same protected local identity. Other kicks and
ordinary/remote players keep their normal behavior. Online party/session semantics
are retained; xblive_privatematch is not changed to conceal the watchdog.

For an explicit same-installation technical peer, use `-ClientSlot B` on client
actions after A is verified. Standard Aurora suffixes separate their keys. Require
both Verify calls, two distinct engine identities and at least 120 seconds idle
with current protected=2, inactivity=0 and zero-enemy heartbeats. Close B first.

Use StopClient, StopServer, then Restore with the same helper after the test.
Restore verifies backup hashes, restores/removes only recorded temporary files and
retains the current bank. Ordinary Server.ps1 deployment still refuses lab binaries.
This base witness also cannot prove two-machine speech or automatic Aurora delivery.

## Explicit native registration and recipient witness

This causal experiment uses the same backed-up base helper. Start both clients
with the explicit flag, after Prepare/StartServer and verified server readiness:

```powershell
./ops/Voice-BaseTest.ps1 -Action StartClient -RegistrationWitness
# Wait up to 90 seconds for Common Initialization Complete.
./ops/Voice-BaseTest.ps1 -Action Connect
./ops/Voice-BaseTest.ps1 -Action Verify
./ops/Voice-BaseTest.ps1 -Action StartClient -ClientSlot B -RegistrationWitness
# Wait for B's Common Initialization Complete, then its protected active join.
./ops/Voice-BaseTest.ps1 -Action Connect -ClientSlot B
./ops/Voice-BaseTest.ps1 -Action Verify -ClientSlot B
./ops/Voice-BaseTest.ps1 -Action Verify -ClientSlot A
```

Require nine paired Verify samples, fifteen seconds apart, spanning at least
120 seconds. Every sample needs protected=2, native_inactivity=0 and the zero
alive/pending/reserved arena. Refusal, disconnect or stale protection invalidates
the run; preserve logs and inspect the original refusal before recovery.

```powershell
./ops/Voice-BaseTest.ps1 -Action WitnessRoster -ClientSlot A
./ops/Voice-BaseTest.ps1 -Action WitnessRoster -ClientSlot B
Start-Sleep -Seconds 1
./ops/Voice-BaseTest.ps1 -Action WitnessRoster -ClientSlot A
Start-Sleep -Seconds 2
./ops/Voice-BaseTest.ps1 -Action VoiceProbe -ClientSlot A
./ops/Voice-BaseTest.ps1 -Action VoiceProbe -ClientSlot B
```

Inspect fresh Registration/Recipient/Client-info witness lines and the next native
status after at least ten seconds. Acknowledgments prove mailbox receipt only.
Current registration success is metadata=1/attempted=1/added=1 per client. The
tested route still fails with eligible=0 and send/receive/decode=0, despite valid
client-info and matching teams. If metadata=0, retry the announcements and inspect
guard counts; silent Release debug logging is not evidence of packet absence.
Do not bypass native mute/privacy decisions to manufacture a passing test.

The UI metadata source is explicitly unsuitable for production authentication.
Close B/A and the verified-empty dedicated, Restore, and restart without the
witness flag before ordinary play; this clears experimental native registrations.
See [the English contribution matrix](VOICE-CONTRIBUTION.md) for acceptance gates.

## Static localhost playback experiment

Research only: the legacy v1 generation defect remains open. This experiment is
not a production relay or reconnect test. Use a fresh backed-up preparation and
start the dedicated with `StartServer -RelayWitness`; start both clients with
`StartClient -RegistrationWitness -RelayWitness` (B also needs `-ClientSlot B`).
Follow the initialization, Connect, Verify and nine-sample protected idle sequence
above. Announce the two identities with WitnessRoster, then call RegisterWitness
on A and B before any audio. Require registered=2/voice_registered=2 and
client_ready=1 in both logs. The server only accepts exactly localhost clients
that currently pass its full protected-player policy.

```powershell
./ops/Voice-BaseTest.ps1 -Action RegisterWitness -ClientSlot A
./ops/Voice-BaseTest.ps1 -Action RegisterWitness -ClientSlot B
# Baseline: no synthetic signal. Exit 1 means no strong tone; exit 2 is an error.
./runtime/audio-output-probe.exe 5 997
```

While a second output measurement is running, issue VoiceProbe on A only, inspect
its sixty-frame sender delta and B's native decoder/queue/playback delta, then
repeat in the other direction after the rate-limit refill. The stimulus is a
997-Hz, 8-kHz post-device signal; native DirectSound may shift its rendered
frequency. The output tool reports bounded spectral/RMS metrics and saves no
recording. It measures the default Windows mix: require baseline/absence controls
and native per-client counters before attributing a signal to the receiver.
The paced candidate's decoded_peak_rms/decoded_tone_ratio are cumulative
997-Hz PCM maxima; pair them with fresh decoder deltas rather than treating a
previous maximum as a newly observed signal.
Do not accept a signal if direct native send occurred, a participant disconnected,
protection expired, or mute/registration refused the speaker. Stop and restore the
whole static witness before ordinary play. Real microphones/two PCs are still
required for the official feature's acceptance.

## Retained first attempt

Candidate aae11b0 built and runtime-linked on private cp_zmb; its client joined with
fresh engine godmode/inactivity=0/cheats=0. Native audio/capture and local session
registration were present (local slot 0, one registered/voice-registered user).
Its activity-mode synthetic blocks encoded zero: the separate hardware mic meter
stayed below the native threshold. That failed witness cannot establish a capture
or routing defect. The correction uses paired native PTT. Retail interaction setup
warnings (cryobomb/forgefreeze) are retained locally and not counted as voice proof.

Candidate 9e80d06 also encoded zero: the MP gameplay dispatcher does not implement
talk; the common binding dispatcher handles it first. The corrected witness calls
that common path and reports held/released state and encoded-frame delta explicitly.
Do not infer a production PTT bug from this harness error.

Its first two-client attempt was invalidated by duplicate generated public keys.
Separate root-specific mutexes made both clients use suffix 1; upstream key entropy
was still machine/suffix-based and deterministic. Client B replaced A, leaving only
one active participant. The build overlay now adds the isolated AppData path to
entropy only under -paris-isolated-lab. Existing duplicate B keys were backed up
locally and reset only inside its stopped root; no owner key was touched. Verify
requires distinct current public identities and two active clients before evidence.

Candidate 2dba1ba confirms native held/released PTT and twenty encoded frames in
the protected solo witness. Batch runs but no session-send occurs in that solo
case; no recipient exists. The corrected pair has two distinct keys/server IDs,
but each new connection returns the previous client to the frontend. Only one
client remains active, so this attempt is invalid for routing/receive conclusions.
Native screenshots establish the frontend/gameplay split. The cause is unresolved;
the owner requests continuing in the base installation rather than extending this
same-machine isolation investigation. The same failure reproduces there with
standard Aurora identities. The owner identifies inactivity kicks; pinned retail
reference confirms the independent GSC watchdog described above. The first voice
fixture's one-shot protection was insufficient. These failed pair attempts are
invalid for native voice routing conclusions and remain retained as incident evidence.

## Client exit verification - 2026-10-04

Full PageHeap first stops candidate 643e806 before game initialization with
`0xC0000005`. Matching executable/PDB and the native exception dump identify
the pinned anti-debug helper writing legacy heap-header offsets into the
PageHeap layout. This is a diagnostic compatibility failure, distinct from the
earlier reconnect exit corruption. The private build overlay now preserves
heap headers/flags when both the native trace flag and Windows PageHeap flag
are present. Ordinary launches retain upstream behavior. Retest before claiming
that this permits heap-corruption diagnosis. Enable verification only for the
owned trace image, then remove its persistent image setting immediately after
launch; it remains active in that process until exit.

StopClient retains a handle to the verified owned process before requesting quit.
It records the exit code and fails on any nonzero result. PID disappearance alone
does not establish a clean exit. Candidate b84619f reproduced `0xC0000409` even
with one protected client and no remote registration/audio. A matching executable
and PDB identify `abort`, `terminate`, C++ unwinding and the main scheduler's
scope-exit callback. The exception subcode is `FAST_FAIL_FATAL_APP_EXIT` (7).

The fixture had executed quit synchronously from that noexcept callback. Lifecycle
commands now enter the native command buffer. c2de172 passes protected solo exit
with code 0; pair/reconnect cleanup remains pending. Raw dumps stay ignored.
This fixture failure does not establish a transport memory-corruption bug.

## Static evidence and open choices

Corrected candidate 67c7c36 passes both base Verify calls and retains two idle
protected clients for 140.422 measured seconds. At that point 1606 retail GSC kick
calls have been suppressed and the arena remains zero alive/pending/reserved.
Each client encodes twenty native frames with pressed/released PTT, but its selected
voice session registers only self (A slot 0, B slot 1), while dedicated registers
two users. Batch runs, with zero native send/receive/decode/playback. The missing
client remote-session registration is the next narrow investigation, not a proven
complete root cause. The pinned client memberInfoUpdate handler stores UI metadata
without Session_RegisterRemotePlayer; server player-info does call that API.
The second client is closed and the protected base solo remains available.
[Exact candidate/build and counter evidence](deployments/2026-10-04-voice-native-trace.json).
The protected-test correction and forwarding trace are tracked in
[PR #39](https://github.com/bigmangeekf/iw7-paris-server/pull/39); voice acceptance
remains open in [issue #4](https://github.com/bigmangeekf/iw7-paris-server/issues/4).

Local post-unpack reference inspection finds capture -> queue (0x14037D960) ->
batch (0x14037D5C0) -> selected session/local-user lookup -> `v` serialization ->
session send (0x14037BFF0). Native receive (0x14037CFF0) validates session users
before mute checks and decode/playback. The dedicated Voice_Init suppression and
Steam interface stubs alone do not prove where a connected Zombies session fails.
The official source was already reviewed at 02a9aee; no upstream refresh is needed.

A server-only repair is not established. Compare real CP and MP witnesses and two
machines before selecting the final layer. If clients need code changes, ordinary
automatic availability requires Aurora adoption and an official updater release.
Prepare generic source/tests for our private fork; no upstream PR or external
message is authorized. Protocol-v1 reconnect generation, jitter/loss, slot-to-session
mute mapping, device changes and version compatibility remain open independently.
