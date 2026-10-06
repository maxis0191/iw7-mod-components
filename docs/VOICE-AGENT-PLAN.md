# Ordinary-path voice agent plan

Local source review, 2026-10-06. This document proposes future game work; it records no
new game run, driver installation, native build, microphone recording or human acceptance.
Passive endpoint inventory and original synthetic WAV generation were checked locally.
The current agent runtime and its frozen operations/native sources are unchanged.
The official upstream check was already completed; this plan does not repeat it.

## What the current implementation can prove

Read alongside [player startup](VOICE-PLAYER-STARTUP.md),
[contribution gates](VOICE-CONTRIBUTION.md), [transport](VOICE-TRANSPORT.md),
[resource admission](RESOURCE-WORKFLOW.md) and [instance policy](INSTANCE-WORKFLOW.md).
Source authority is `src/native/voice_relay.cpp`, `src/native/paris_voice.cpp`,
`tests/native/audio_output_probe.cpp` and `ops/Lab-RunPlan.ps1`.

The v2 queue replacement is restricted to an external dedicated **CP** connection.
MP, SP and local games forward the original native path. A successful MP native
control would establish a useful baseline, not v2 MP transport acceptance.
Removing the CP predicate alone is insufficient: admission, sessions, slot/user
identity, teardown, routing and mute/privacy behavior all need MP evidence.

The ordinary queue hook receives encoded native frames after existing PTT and
threshold processing. The private `run_native_probe` instead supplies synthetic
PCM after the hardware capture boundary; during a probe, the capture hook consumes
real device blocks. Its optional codec calibration changes saved/restored private
VAD/DTX controls. It must not be enabled in the ordinary-path experiment.
Use Player-mode relay arguments, audio enabled, and no `-paris-voice-native-trace`,
VoiceProbe or VoiceCodecProbe. Preserve production codec configuration.

Existing v2 counters show encoding arrivals, sends, relay activity and calls into
engine playback. A playback call is not decoded PCM or audible speech. Existing
WASAPI output diagnostics detect known tones and save no recording. Process
capture currently permits only `iw7-paris-native-trace.exe` with an exact creation
identity; it cannot be silently reused for a differently named candidate.

## Available local materials and unresolved endpoints

Initial bounded searches of the repository and retained worktrees found no WAV, MP3,
FLAC, OGG or PCM speech fixture. Do not substitute retail assets or private owner
recordings. The current worktree retains `runtime/audio-output-probe.exe` and its
source; its build identity still needs checking before use.

FFmpeg and ffprobe are already on PATH from the WinGet Gyan package,
`ffmpeg-8.1.2-full_build/bin`. Windows SAPI voice registrations include English
David/Zira and French Hortense. These provide a reproducible source for a future
synthetic spoken fixture without another download. Record the executable hashes,
voice token, text, generation settings and generated WAV hash in ignored runtime
metadata. SAPI availability is not evidence that game capture hears its output.

The new passive CoreAudio inventory reports one active and three not-present
capture endpoints, plus four active and thirteen not-present render endpoints.
It records console/multimedia/communications defaults locally; gain, privacy
permission, hardware operation and usable application-specific routing remain
unverified. No verified active virtual capture route was established by enumeration.
First identify and validate the existing intended route. The owner authorizes
necessary tools/dependencies: if ordinary OS capture of synthetic speech needs a
virtual route, an official, reversible, pinned driver may be prepared after a
documented need, current source review and rollback plan. Prefer per-application
selection and preserve owner defaults. Do not change global defaults unnecessarily.
This tool installs no driver and changes no devices or defaults.

`ops/voice-agent/Voice-Fixture.ps1` now implements passive `Inventory` and
file-only `Generate`. CoreAudio reads endpoints/properties without activating an
audio client; SAPI writes original fixed phrases directly to WAV, without render
playback or microphone capture. Endpoint IDs/defaults remain local evidence.
Run from the repository root:

```powershell
./ops/voice-agent/Voice-Fixture.ps1 -Action Inventory |
    ConvertTo-Json -Depth 8 | Set-Content runtime/voice-agent-inventory.local.json
./ops/voice-agent/Voice-Fixture.ps1 -Action Generate `
    -OutputRoot runtime/voice-agent/a-fresh-speech-fixture
./tests/ops/voice_agent_fixture_test.ps1
```

Generation chooses the first installed English SAPI token unless an exact
`-VoiceTokenId` is supplied. Output must be fresh; audio inside the repository is
restricted to ignored runtime. The manifest records original text, token,
PCM mono16kHz16bit, rate/volume, generator/asset hashes and OS version. Repeated
generation with the same installed token/settings produced identical WAV hashes;
cross-machine/engine-version byte identity is not promised. Tests check actual
RIFF chunks, format, bounded duration, non-silent samples, distinct phrases,
hashes, existing-output refusal and unchanged CoreAudio defaults.

Retained fixtures are in ignored
`runtime/voice-agent/original-speech-20261006-final/`: `ptt.wav`, `reconnect.wav`,
`manifest.local.json` and `inventory.local.json`. They contain original synthetic
speech of approximately 9.4 and 9.5 seconds, not owner audio. Source waveform validity
is verified; no listening/transcription, game capture, codec, transport, decode or
render acceptance is claimed. Listening is still required before a speech test.

No second independent game-capable endpoint has been verified by this review.
The presence of ssh does not establish a host, retail installation, audio devices
or permission to operate it. An existing separate PC, if supplied and verified,
can host one matching client with its own RAM/commit and normal microphone/output.
It needs exact build hashes, protected candidate connectivity and its own resource
admission. Do not create another local clone or call another process an independent
endpoint. Opening ports or changing Main/router configuration is outside this plan.

## Capacity measurement before a pair

Keep current estimates: reduced client 8 GiB RAM/commit, dedicated 4 GiB, debugger
2 GiB RAM/3 GiB commit. A reduced one-client debug group is 14/15 GiB; a two-client
debug group is 22/23 GiB. The pair was refused under the earlier physical-headroom
policy on approximately 32 GiB RAM with approximately 10 GiB baseline. The owner
has since removed the RAM percentage/reserve margin and the 80% RAM watcher stop; use the updated
merged scheduler and watchers. Do not reintroduce those superseded RAM rules here.
Commit admission remains independently governed by the current scheduler. Disabling audio,
trimming working sets or omitting planned debugging is not a valid voice estimate.
An explicitly designed run without live debugger/profiler may reserve 12/12 GiB
for one client or 20/20 GiB for a pair, with debugger flags actually absent before
launch. This is a different complete scenario, not a revised client estimate or
live lease reduction. With the former approximately 10 GiB baseline, the debug
pair projects approximately 32 GiB and the explicitly non-debug pair approximately
30 GiB; current capacity/admission must decide, not rounded arithmetic. Passive
audio observation still needs its own budget bound. Removing a RAM margin does
not establish measured client peaks or speech quality.

1. Reserve the entire admitted one-client scenario before staging/launching.
   Use the base client, retained dedicated candidate, reduced graphics, real audio,
   isolated appdata, exact process identities and full snapshot/restoration. Keep
   UDP 27016 and an occupied owner client intact. The parent owns launch/recovery.
2. Capture an idle machine baseline, then system physical/commit and each owned
   process working set/private bytes throughout cold startup, first playable
   spawn, 120-second protected idle, device initialization, spoken capture, codec
   activity and clean exit. Use `Resource-Scheduler.ps1 -Action Measure` in bounded
   segments (maximum 300 seconds), preserving continuous segment timestamps.
   Add process high-water counters where available: one-second samples alone can
   miss spikes. Retain page activity, GPU memory, CPU, disk and failure evidence.
3. Repeat cold runs and a representative map/load transition sequentially. CP
   and MP require separate profile evidence. A 15-second sample or one successful
   spawn is preliminary. Do not shrink a live lease. A reconnect crash remains
   a lifecycle failure regardless of its low sampled memory.
4. Produce separate per-client, server, observer and debugger maxima, measured
   system deltas, sample duration and omitted phases. Working sets share pages;
   sums and baseline subtraction are not guaranteed reclaimable capacity. Propose
   a reviewed estimate no smaller than observed high-water bounds plus explicit
   load/map variation and measurement uncertainty. Any revised estimate needs
   evidence for those bounds; do not invent a percentage to force admission.
5. End the original scenario and release its lease. Recompute a complete pair
   using the revised evidence, current baseline and current RAM/commit policy.
   Admit only if both limits pass. Keep monitoring and stop safely on pressure.
   If the pair remains refused, retain the estimate and use a verified independent
   endpoint, or finish the single-endpoint capture/encode evidence while waiting.

The current Base/Agent-Lab path requires a one-client CP fixture, and the current
Agent-Lab profile sets voice off. It is not an existing pair/MP runner. A future
voice runner must explicitly reserve both endpoints before launch, support two
current protected CP players, retain snapshots for both isolated profiles and
release PTT on every exit. A second local profile is justified only for the
simultaneous pair, under the instance-policy exception; no retail game clone.

## Intelligible stimulus through the ordinary device path

Prepare two ignored PCM WAVs with different SAPI voices and known text, for example
"Alpha seven. The blue lantern is beside the quiet river. Four nine two." and
"Bravo three. The green bicycle waits near the wooden bridge. Six one eight."
Use 16-bit mono PCM and record actual rate/length rather than assuming the game's
capture rate. Include silence before/after and a varied speech envelope. Verify
the source by listening locally and transcribing the phrase before network use.
These are synthetic speech fixtures, never two humans conversing.

Prefer a verified existing hardware capture route. Playback of the known WAV from
an external speaker into the selected physical microphone tests ordinary capture
but introduces acoustic coupling; retain that limitation. An existing virtual
microphone can be prepared if necessary through official pinned tooling, with
verified routing, documented necessity, bounded permissions and reversible
installation/configuration. Preserve the owner's defaults and record rollback.
Playing a WAV on the Windows render endpoint alone does not feed the
game microphone. Injecting PCM into `capture_voice` or replacing encoded frames
may be a codec/transport test but fails this ordinary-device gate.

For a same-machine pair, shared microphone input and a common render device can
confound direction and recording. Run A-to-B and B-to-A separately, with only the
intended sender's ordinary PTT active; identify the receiver by PID/creation and
use per-process output capture. A device-wide recording can contain the source
speaker or unrelated audio and cannot establish receiver playback. A truly
independent endpoint with headphones avoids these local ambiguities.

## Minimal observability delta after the runtime freeze

Add an opt-in passive diagnostics path rather than enabling the synthetic harness.
Do not change engine eligibility, team/dead routing, mute/privacy decisions, codec
settings, registrations or device defaults for the sake of a green test. Validate
entry signatures and retain original return values/thread behavior. Keep engine
work on its existing thread; counters must be bounded and concurrency-safe.

| Boundary | Minimal evidence | What it does not establish |
| --- | --- | --- |
| Capture device/native capture | initialized/selected-device witness, native block/sample counts, bounded RMS/silence summary, ordinary PTT/activation gate, timestamp | Encoding, delivery, or intelligibility |
| Codec input/output | native input samples, nonempty encoded frames/bytes and error counts, unchanged VAD/DTX/mode witness | Packet delivery or audible output |
| Sender/server/receiver transport | v2 negotiation stages and current generation; aggregate hello/confirm/eligible/voice masks, accepted/rejected frames with reason, matched receive-window totals | Decoder success or human privacy acceptance |
| Decoder/native playback queue | successful decoder output blocks/PCM bytes, queue success/error counts, timestamps | Actual rendered speech |
| Receiver rendering | exact-process WASAPI WAV plus capture interval/format, no default-device fallback | Human conversational quality on real LAN/WAN |

Current `encoded` counts queue entries; label it accordingly. `playback_calls`
counts engine entry invocations. Neither is a decoded-frame count. New counters
must describe their actual boundaries. Raw PCM is opt-in and confined to the
known synthetic fixture experiment, not enabled by ordinary player diagnostics.
Store WAVs/dumps locally in ignored runtime with bounded duration/size and hashes;
never commit audio, identifiers, endpoints, capabilities or packet secrets.

Small proposed source ownership for the next reviewed change:

- `src/native/voice_relay.cpp`: expose one consistent client/server status record
  with actual game mode, adapter route (`v2_cp` or `native_passthrough`), installation
  state and reason/stage. MP should explicitly report v2 unsupported and native
  passthrough on both sides instead of appearing as a failed CP handshake. Keep
  existing diagnostic counters and privacy-safe masks. Test CP/MP gating without
  deleting or widening it. No MP v2 hello is expected in this delta.
- A narrowly scoped passive native observer: factor verified capture/encode/decode
  counter hooks from private trace logic, with no probe, forced PTT, audio init,
  codec override or alternate routing. Expose native registered/eligible state
  for MP as well as CP; an unavailable MP boundary must report unavailable rather
  than invoke a CP ABI speculatively. This needs signature tests and runtime proof.
- `tests/native/audio_output_probe.cpp`: parameterize the expected image/hash with
  exact PID/creation checks and add bounded WAV export for a selected process.
  Reject foreign/reused PID and default-device fallback. Keep existing tone mode.
- A future voice-specific input driver: validated `+talk`/`-talk` ordinary binding,
  bounded duration and unconditional release on timeout/protection loss/teardown.
  Current gameplay Agent-Scenario exposes no talk binding and arm lasts 30 seconds;
  it cannot be treated as an existing long-duration voice/PTT controller.

This delta makes negotiation and native passthrough observable in CP and MP. A
separate MP v2 feature would require an explicit reviewed design and baseline;
it must preserve native team/dead/privacy rules and be tested independently.

## Execution matrix and evidence gates

For CP use a private isolated dedicated with current protected players, actual
godmode/inactivity=0/cheats=0 heartbeat, retail-safe quiet arena and zero ordinary
alive/pending/reserved enemies. Stage the voice witness alone with reviewed
scripts; do not combine it casually with the input-effects fixture. Avoid legacy
Main-base voice scripts and stale helpers. For MP use a separate stock MP control
profile on test ports, fresh mode-appropriate safety/eligibility evidence and no
CP zombie fixture. A missing MP protection/runner implementation is a pending
dependency, not permission to reuse the CP heartbeat.

| Test | Required evidence/result |
| --- | --- |
| Silence/PTT released | Capture may poll, but no offered spoken frames or receiver fixture speech |
| A-to-B, then B-to-A | Known phrase traverses every boundary; receiver recording independently intelligible, timestamps and counters match each direction |
| Native voice disabled / receiver scoreboard mute | Engine decision observed; receiver phrase absent; unmute restores subsequent phrase without codec override |
| Ordinary PTT / ordinary mic activation | Both native selection paths separately evidenced, release never leaves transmission active |
| Disconnect/reconnect, map transition, same/different-user slot reuse | Fresh negotiation/session evidence, old data rejected, correct new phrase reaches intended current receiver; clean exits and no heap fault |
| MP native control | Original-path negotiation/eligibility and speech evidence; record team/dead/privacy restrictions without forcing them |
| MP with relay flag | Explicit native passthrough witness, same routing behavior; does not claim v2 MP support |

Use fresh baseline log offsets and per-test windows. Silence and unrelated source
audio are negative controls. Listen to the receiver WAV independently (a reviewer
transcribes without the source text), report words/numbers recovered, clipping,
dropouts, delay and failure; an automatic transcription alone is not sufficient.
Known source onset and captured receiver onset may estimate end-to-end delay on
one clock; independent hosts need measured clock alignment/uncertainty. Hash the
source and receiver recordings and manifest, keep identities local, record exact
build/profile/map plus clean teardown and restored file/bank hashes.

After synthetic ordinary-path evidence, retain the human gate: two consenting
players on independent PCs, real microphones/headphones, intelligible speech in
both directions, ordinary controls/mute/privacy, reconnect and map changes on
real LAN/WAN. Startup, tones, decoder counts, synthetic speech or simulated loss
cannot replace this owner acceptance. No current result claims it has passed.

## Prepared virtual audio route (2026-10-07)

VB-CABLE Pack45 has been downloaded from the [official vendor](https://vb-audio.com/Cable/index.htm),
pinned and verified by `ops/voice-agent/Prepare-VirtualCable.ps1`. The helper only
downloads/extracts/checks signatures; it never runs setup. Local kernel-policy
verification of both the INF and SYS against the Microsoft-signed catalog passed.
The driver is **not installed** and no device/default/volume has changed. The
official route is playback **CABLE Input** to recording **CABLE Output**; it can
feed ordinary DirectSound capture without replacing PCM or the codec. Vendor
installation requires administrator rights and a reboot and may change Windows
defaults automatically ([reference manual](https://vb-audio.com/Cable/VBCABLE_ReferenceManual.pdf)).

The passive inventory includes CoreAudio endpoint GUIDs and DirectSound capture
enumeration. Microsoft's [endpoint GUID documentation](https://learn.microsoft.com/en-us/windows/win32/coreaudio/pkey-audioendpoint-guid)
defines the correspondence used by DirectSoundCaptureCreate. The exact factory
chain is now established by bounded retained-byte inspection and PE imports:
`Voice_Init 0x140D597C0 -> 0x140B79D00 -> 0x140B7A070 -> callsite 0x140B7A095 -> thunk 0x1411BDF0E -> IAT 0x14B2B2EA0`.
The original PE imports DSOUND ordinal 6 at that IAT address; the installed Windows
DSOUND export table identifies ordinal 6 as **DirectSoundCaptureCreate**, not
Create8. The factory passes RCX=NULL (default device), RDX=`&0x145D5DC48`
(capture interface output), R8=NULL (aggregation). It sets the callback slot at
`0x145D5DC50` through `0x140B79D00`, to `0x140B79CD0` whose retained thunk leads
to the existing capture/encode callback `0x140B79D30`. The Create8 string elsewhere
in rdata is not evidence of this call's API. Microsoft's
[capture-device creation guidance](https://learn.microsoft.com/en-us/previous-versions/windows/desktop/ee416362%28v%3Dvs.85%29)
describes NULL as the default system capture device; this is distinct from the
explicit default-voice GUID. No supported capture-selector dvar is proven.

Microphone-volume initialization at `0x140D5A2E0` separately selects capture/eConsole
through IMMDeviceEnumerator; it does not establish the factory device. Playback
creation at `0x140B798C0` separately passes NULL to DirectSoundCreate8. The retained
Voice_Init entry is patched for dedicated mode and these snapshots do not prove
that the current real client successfully initializes any endpoint. The actual
factory HRESULT, buffers/format and callback input need a fresh passive witness.

Prepare the next reviewed delta in this order:

1. Observe the ordinary client's actual capture-factory GUID, HRESULT and format
   without opening a second capture stream. Prepare a narrowly reviewed
   isolated-lab-only callsite adapter at `0x140B7A095`; leave the DSOUND DLL and
   process-wide IAT untouched. Resolve the original function from the verified
   IAT before installing the adapter. Require the expected callsite/thunk bytes
   and original NULL GUID argument. An explicit startup argument supplies the
   selected GUID before Voice_Init (avoid dvar registration/initialization races).
   Enable only the isolated-lab build/client flags and marker/test-port context;
   the ordinary owner client retains its original call. Match the active CABLE Output endpoint GUID to DirectSound
   enumeration and fail closed if unavailable. Preserve capture, PTT, codec and
   privacy gates; do not fall back to the owner's microphone. Native sources stay
   frozen until the current runtime finishes and the delta is reviewed.
2. Before any later installation, retain all six capture/render default roles,
   endpoint IDs/GUIDs/states and existing driver package identity. Install only
   the verified package and coordinate the required reboot with the runner.
   Re-enumerate immediately and restore any installer-changed defaults from that
   snapshot; refuse restitution if a concurrent owner change makes ownership
   ambiguous. Never enable Listen-to-device or change volume unnecessarily.
3. Render the original SAPI WAV to the explicit CABLE Input endpoint ID with
   bounded duration. Record negotiated device format and conversion from the
   16 kHz mono source; the driver default format does not prove the codec format.
   Use explicit CABLE Output capture GUID for the sender and exact receiver
   PID/creation/hash process-loopback WAV for output. Device-wide loopback is
   insufficient because it can include the source or unrelated applications.
4. Admit the complete pair with current estimates before launching. Run A-to-B
   then B-to-A with distinct phrases and ordinary PTT; preserve separate evidence
   at capture, encoding, transport, decoding and rendering. Release PTT on every
   failure/teardown, stop only exact owned processes and restore client files.
   Track the installed dependency separately from test state. If installation
   must be rolled back, use the official removal/reboot path for that exact new
   package and verify endpoint/default restoration; do not remove another user's
   existing audio dependency.

The independent recorder is now implemented in `tests/native/audio_output_probe.cpp`
with `ops/voice-agent/Record-Receiver.ps1`. Its opt-in `--record` mode requires
PowerShell 7.4+ for the wrapper; Windows process-loopback activation support is a
runtime gate and failure never selects a system endpoint. The native mode requires
exact PID, creation FILETIME, full image path and SHA-256; retains process and
immutable image handles; rechecks liveness/identity through capture; exclusively
creates a bounded PCM16 stereo 48 kHz WAV (1..60 seconds). It never falls back to
system loopback. The historical tone mode remains available. Windows exposes
process-tree loopback, so the recorder rejects children observed before/after and
every 100 ms using a bounded recursive closure with duplicate/cycle rejection;
short-lived children and orphaned descendants can escape snapshots.
This is not PID-only or audio-session isolation. Failed WAVs remain unfinalized and the
wrapper retains a failure manifest/log rather than reporting completion.
Before completion the wrapper independently verifies RIFF/data sizes, frame
alignment, PCM16 stereo 48 kHz format and the requested duration/size bound.
The wrapper retains the recorder image without write/delete sharing and owns its
original process handle. A total watchdog (requested duration plus 15 seconds,
maximum 75 seconds) and 4 MiB combined log bound stop only that handle on failure,
never the IW7 receiver, a PID resolved again, or descendants. The diagnostic
manifest retains the probe PID/creation, exit code, deadline status and elapsed
time. Non-audio worker tests verify valid/truncated WAV paths and exact helper
timeout with the parent preserved; they do not establish WASAPI runtime support.
Compilation `/W4 /WX`, actual self-image hash/identity negative tests, strict
argument/bound tests, WAV header checks and historical tone self-tests pass without
activating capture. No live audio has been recorded. The explicit CABLE Input
player and actual capture GUID witness are still pending.
`Select-Capture.ps1` and `Capture-Route.Core.ps1` prepare an exact active virtual
endpoint/CoreAudio/DirectSound GUID correlation, rejecting personal/default,
inactive or ambiguous devices. `CaptureAdapterPolicy.hpp` is preparatory code
under `ops/voice-agent`, not included in the IW7 binary; its mock factory tests
   verify all lab/identity/signature/endpoint gates, unchanged HRESULT/output pointer
and no default fallback. Runtime integration remains pending after source freeze.

Next action: review the capture-factory witness/explicit selector and bounded
explicit-endpoint player, then profile a single audio-enabled
client with current estimates. Pair admission needs justified measurements or a
verified independent endpoint. No OS capture, codec transport, audible receiver
speech or human conversation is claimed by the current file-only fixtures.

Driver transaction preparation (2026-10-07): `Cable-Transaction.ps1` provides
Snapshot, InstallPlan, RestorePlan and RollbackPlan only. It executes no setup,
default-setting, driver deletion, elevation or reboot. The local snapshot found
three NVIDIA MEDIA packages, no VB-CABLE package or active/inactive CABLE endpoint,
and a filtered token (`Elevated=false`, elevation type `limited`). There is no
existing CABLE route to reuse in that snapshot; re-enumerate before installation.

The verified signed Pack45 setup accepts `-i -h`: its retained parser selects
installation and hides the setup window. This is evidence from the vendor binary,
not a command-line promise in the reference manual. The official
[reference manual](https://vb-audio.com/Cable/VBCABLE_ReferenceManual.pdf) requires
administrator execution and a reboot after installation/removal. Use an already
elevated coordinated shell with no occupied game; never trigger implicit UAC or
an automatic reboot during a replay. Installation remains unexecuted.

Executable preparation sequence (PowerShell 7.4+, from the repository):

```powershell
./ops/voice-agent/Cable-Transaction.ps1 -Action Snapshot -OutputRoot "$PWD/runtime/voice-agent/cable-before-FRESH"
./ops/voice-agent/Cable-Transaction.ps1 -Action InstallPlan -PreparedRoot "$PWD/runtime/voice-agent/vbcable-pack45-verified-final"
# Later, only in the coordinated elevated installation window:
# invoke the exact returned Setup with Arguments -i -h, WorkingDirectory and Hidden window
# retain a fresh immediate-after snapshot before any role restitution or reboot
./ops/voice-agent/Cable-Transaction.ps1 -Action RestorePlan -PreparedRoot "$PWD/runtime/voice-agent/vbcable-pack45-verified-final" -BeforePath BEFORE_JSON -AfterPath AFTER_JSON
./ops/voice-agent/Cable-Transaction.ps1 -Action RollbackPlan -PreparedRoot "$PWD/runtime/voice-agent/vbcable-pack45-verified-final" -BeforePath BEFORE_JSON -AfterPath AFTER_JSON
```

Snapshots retain all six capture/render roles, endpoint IDs/GUIDs/states,
DirectSound enumeration, MEDIA devices/bindings, OEM INF names/hashes and raw
driver-store output. Installation planning rechecks the pinned archive, setup
signature and every extracted file. Restitution proposes only installer-changed
roles still pointing to the same newly added CABLE endpoint; a concurrent owner
choice, ambiguous role or inactive original endpoint refuses the plan. Recheck
each role immediately before setting it and verify all six afterward.

The official [SoundVolumeView interface](https://www.nirsoft.net/utils/sound_volume_view.html)
supports `/SetDefault` with an exact endpoint ID and role 0/1/2. A local official
2.53 archive has been downloaded but not executed. Authenticode is `NotSigned`;
ZIP SHA-256 is `EE2C45553FB9FB31B71DB88B537C18E25C1A387A4A9009D081BDB38265C68E1F`,
EXE SHA-256 is `B5AF5BD60F7A29AF8CB4D8A566382B90F0FE07CAC97228D218CB913F3382D647`.
Its technical review is required before using it for restitution. No wildcard,
friendly-name matching or `all` role is planned.

Rollback identifies exactly one newly added OEM INF matching the verified cable
INF hash. Retain its bindings and an export before deleting only that OEM name
with `/delete-driver oemN.inf /uninstall`; no `/force`, wildcard or automatic
reboot. These are [documented PnPUtil operations](https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/pnputil-command-syntax).
Refuse pre-existing or changed packages. A fresh binding/default review remains
necessary before executing rollback; the plan does not itself prove deletion safe.

Pure transaction regressions (`tests/ops/voice_agent_cable_transaction_test.ps1`)
cover exact changed-role restitution, already-restored roles, concurrent owner
changes, inactive originals, pre-existing/changed OEM packages and locale-neutral
driver enumeration. Remaining installation prerequisites are an already elevated
coordinated context, reviewed restitution tool and a coordinated reboot. Ordinary
voice evidence additionally needs the explicit GUID adapter and render player,
then admitted sender/receiver runtime measurements; no audio path is claimed yet.

`Execute-Cable.ps1` now supplies the concrete opt-in executor. Without `-Execute`
it only returns the plan. Execution requires an already elevated token, the exact
technically reviewed restorer hash, fresh runtime journal root and no IW7/Aurora
process. It holds package/restorer files against write/delete, rechecks identity
between phases, saves before/after/current snapshots and verifies the six original
defaults. `-RollbackOnFailure` exports then removes only the verified added OEM;
binding conflicts, owner role changes or unresolved commands refuse mutation.
No reboot, UAC, wildcard or forced removal is issued. An installer/CLI timeout
retains exact PID/creation/image/hash in a persistent pending marker and blocks
retry or rollback until diagnosed; it does not kill an installer mid-transaction.

The pinned setup's hidden flag at `0x14001B744` is set by parser `-h` and branches
from `0x140005D3D` to the successful return before its browser/MessageBox block.
The latter decodes a VB-Audio ThankYou URL, not a reboot command, and displays
"Reboot your system to secure the installation". The installation path uses
SetupAPI and UpdateDriverForPlugAndPlayDevicesA; its examined dynamic imports do
not include a reboot API. No automatic machine reboot instruction was found in
this pinned installation/hidden completion chain. Windows can still report a
required reboot; that is retained for a coordinated human intervention, never
automatically acted upon. Evidence remains in ignored `setup-*.local.json` files.
Executor state-machine mocks pass refusals, changed-role restitution, exact export
and deletion after setup failure, and no rollback while setup is unresolved or an
owner role changes. These tests execute no driver or audio command.

Native GUID selector prepared for review: `voice_capture_adapter.hpp` is now the
shared native/test policy. Build-Voice defines `IW7_PARIS_ISOLATED_VOICE_CAPTURE`
only in its copied IsolatedLab voice translation unit and records transformed
source hash/profile; normal builds exclude the selector. No startup GUID means no
selector hooks even in the isolated binary. Explicit selection additionally needs
client-test, isolated and voice-audio-lab flags, exact marker, test port, current
image SHA-256, exact endpoint ID/GUID and unique CABLE Output correlation through
CoreAudio and DirectSound. Every actual factory/volume call requires the fresh
native client session PID/nonce written after this process's creation.

Prepared startup selectors are `-paris-lab-capture-guid=...`,
`-paris-lab-capture-endpoint=...`, `-paris-lab-capture-image-sha256=...` and
`-paris-lab-capture-port=27116`. Image bytes are hashed and retained without
write/delete sharing. Factory arguments, pinned instruction bytes, ordinal-6
export/IAT identity and the uninitialized capture/volume globals are checked;
unexpected calls or vanished endpoint return failure without default fallback.
Admission enumerates devices/properties only; it opens no audio stream.

The same selector redirects the exact IMMDeviceEnumerator call at
`0x140D5A35A` from capture/eConsole to `GetDevice(approved endpoint ID)`, preserving
its HRESULT branch. This prevents the retail volume object from belonging to the
owner's default microphone while capture belongs to CABLE. The bounded retained
neighbors show `0x140D5A420` calls IAudioEndpointVolume::SetMasterVolumeLevelScalar
at slot `0x38` on global `0x1477A0190`; initialization reads scalar/mute and
registers callbacks on that same object, while `0x140D5A280` unregisters/releases
it. Thus preserving only the capture factory would not protect owner gain.
No default setter or gain setter is added by this adapter. These neighboring
owners do not constitute an exhaustive whole-image reference scan; peer review
and a passive factory/volume witness remain required before audio acceptance.
Policy/COM mock tests compile `/W4 /WX` and pass explicit endpoint volume success,
failure without owner fallback, wrong flow/identity refusal and normal-path
forwarding. The complete isolated native build passed on source `38e15c9`
(binary SHA-256 prefix `70A0697D`), with the selector inactive during the subsequent
input witness. Explicit GUID/volume admission and real audio remain unverified.

Default restitution on any returned setup is now independent of optional driver
rollback. Post-snapshot failure retries twice, then refuses unproven writes;
original failure and restitution failures remain separately journaled. The
`NoAutomaticRebootInstructionFound` field describes inspected evidence, not an
exhaustive guarantee. Root's attempted read-only SoundVolumeView export was
rejected by automatic approval review with `blocked by policy`; nothing executed.
Do not retry it through another route or substitute private IPolicyConfig ABI.
Driver installation remains blocked on a reviewed executable restitution route;
the GUID adapter and passive bench can advance without installing a driver.

Explicit source renderer is prepared independently under `ops/voice-agent`:
`render_wave.cpp`, `RenderWave.hpp`, `Render.Core.ps1` and `Play-Source.ps1`.
It accepts only one active exact CABLE Input endpoint ID/GUID and a hash-verified
original mono PCM16/16 kHz WAV with at most 240000 frames (15 seconds). No default
endpoint query, fallback, volume/mute setter or Listen-to-device path exists.
Source and helper image files remain locked against mutation. The helper validates
CoreAudio identity again before opening its explicit WASAPI shared render client.
It uses the endpoint mix format (PCM16 or float32, mono/stereo, 8..192 kHz), records
rate/channels/bits/encoding, and explicitly interpolates the 16 kHz source while
duplicating mono into stereo when needed. Unsupported formats refuse playback.

The helper bounds its stream loop to 20 seconds, stops/releases its own client on
all exits and drains submitted frames before success. The wrapper imposes an
independent 25-second total watchdog on the exact owned helper handle using the
existing `OwnedProbe`; it never stops an IW7 process or unrelated child. Fresh
completion evidence must match source frame count, negotiated format and exact
converted frame count before its local manifest reports completion. This proves
buffer submission/drain only, not receiver audibility or intelligibility.

The renderer and pure tests compile `/W4 /WX`. C++ RIFF/header/frame/format and
known-sample conversion tests pass; PowerShell route and completion tests reject
inactive/personal/ambiguous endpoints, malformed WAVs, stale/duplicate logs,
wrong frames, unsupported bounds and fallback markers. No render client has been
activated. The independent helper builder now compiles both new C++ files and runs
`tests/ops/voice_agent_render_test.ps1`; both are included in private CI, keeping
actual streaming out of CI.

Ordinary PTT preparation is separate from historical synthetic probes. Retained
retail whitelist table `0x1414D1B70` has `+talk` at index 81/string
`0x1414D2DC8`, and `-talk` at index 82/string `0x1414D2DD0`; no voicerecord name
appears in its 118 entries. The downstream common table cases 81/82 resolve to
its no-op epilogue, while a lower MP route maps to `0x140368419`/`0x1403693E9`.
That initially suggested an unclosed PTT chain, but the ordinary entry has special
81/82 branches before either lower dispatcher. The ordinary CP/MP producer and
getter are now statically proven below. The actual audio consumer still needs a
separate witness before claiming microphone capture or codec input. Do not use
post-device PCM probes, VAD/PTT dvar overrides or a stale timestamp as substitutes
for that proof. No PTT or audio action was dispatched during this preparation.

PTT evidence correction: ordinary entry `0x14032A3B0` uses ECX=local client,
EDX=binding, R8D=physical key and R9D=event time. It compares binding 81 at
`0x14032A3C7`, before UI checks or game-mode-specific vtable dispatch. The special
branch uses key structure `0x141FE5B4C + local*0x460`, inserts the key into either
of its two slots and, if inactive, writes retail timestamp `0x1460053C0` to +0x08
then word `0x0101` to +0x10/+0x11 at `0x14032A420`. It returns immediately.
Binding 82 at `0x14032A436` removes only the matching physical key and clears
active +0x10 only when no other key remains; unmatched releases return unchanged.
Thus it preserves another held PTT key rather than globally releasing talk.

Getter `0x14036FE40` reads exactly `0x141FE5B5C + local*0x460`, the same active
byte. This proves the ordinary input-to-PTT-state path for both CP and MP without
following the obfuscated lower MP object. Root independently reviewed the early
branches/getter. The earlier statement that a downstream no-op implied an
unhandled ordinary talk binding was incorrect; the historical source comment
about talk being handled before MP/SP dispatch was correct. No native source was
changed for this correction.

Shareable pinned evidence: entry prefix 282 bytes, SHA-256
`18B3FB9295FC6E85A10255BABC40D0368BCDBE2686351AD9E2384B3BB00C814A`,
with pdata record RVA begin/end/unwind `0032A3B0/0032A4CA/0171E894` (follow its
chained ranges for the shared epilogue). The complete 22-byte linear getter
through RET has SHA-256
`ED81DBCB75EE924B2DEFDF56E9CDE53E3CC030D9AB3CF925178813A60BC9527A`.
Its signature is `4863C14869C860040000488D050B5DC7010FB60401C3`; it has no exact
pdata entry. Raw bytes, chain ranges and ABI are retained only in ignored
`runtime/voice-agent/ptt-ordinary-contract.local.json`; expected text-reference
SHA-256 is `5F2953F04A8D5F2A53D1E5A5E076DE8F29D5B5303CA652F2420FEC8D2A6A9138`.
These are static retained-reference witnesses, not runtime acceptance.

`PTT-Contract.Core.ps1` prepares a pure 200 ms ordinary press/release plan with
bindings 81/82, one exact owned key and matching process/session evidence. It
requires typed fresh native identity/protection/UI observations, vacant talk
slots and inactive PTT. For the state-only bench it additionally requires
cl_voice disabled, absent native voice initialization/capture interface and no
audio probe; missing observations refuse rather than implying audio absence.
Observe getter 0→1→0 with fresh seq/step/tick correlation and release the exact
owned key on every exit. No action, dvar override, PCM hook or audio stream is
performed by this plan. Its CP/MP pure refusal tests pass. The actual driver and
MP protection fixture remain separate implementation work; static mode parity
does not prove that today's CP-specific safety fixture admits an MP runtime.

`ops/voice-agent/Build-Render.ps1` now compiles only the independent render helper
and pure tests into a fresh ignored output directory, retains source/executable
hashes and runs no audio stream. The actual lean Windows `/W4 /WX /RTC1` helper
build and both C++/PowerShell test sets pass. Exact private-phase commands and
evidence limits are in `ops/voice-agent/README.md`; no main builder or native source
was changed for this helper tranche.

## CP to MP compatibility map and next candidate — 2026-10-07

This is a source plan, not an MP launch or audio result. It uses retained upstream
`77e6d4d24e918ee363b3feee3735c3b889dff7d7` (`dedicated.cpp`, `party.cpp`,
`game/structs.hpp`) and the current tracked generic v2 relay. No upstream poll,
native modification, driver action or audio stream was performed for this map.

| Boundary | Current source behavior | Required MP evidence / minimal change |
| --- | --- | --- |
| Dedicated mode | Pinned `dedicated.cpp` selects CP only with `cpMode`/`zombies`, otherwise MP; executes `default_mp.cfg` for MP. Its dedicated `Voice_Init` patch disables local audio devices. | Explicit MP arguments/config, real loaded MP map and gametype, local audio only in rendering clients. A native MP launch capability is not a completed protected MP runner. |
| Relay installation | `-iw7-voice-relay` installs v2 on either process after signature checks. `zombies()` still gates accepted incarnations, server synchronization and client connection. | Report actual mode and native passthrough explicitly; installation alone must not be labelled an MP v2 session. |
| Module/dvars | V2 reads typed boolean `cl_voice`; it does **not** read `paris_mod_voice`. That module switch belongs to legacy v1 `paris_voice.cpp`. With generic relay and no native trace, that component returns before its v1 module gate. | Treat v2 flag and typed `cl_voice` as the actual current controls. If a future common module switch is desired, define and test its semantics separately; never assume `paris_mod_voice=0` stops v2. Retain original engine settings without guessing an `sv_voice` override. |
| Sender path | Queue hook `0x14037D960` forwards the original queue for MP today. CP external games replace that queue only after the ordinary capture/codec/PTT path. | Baseline MP must keep original queue/capture/codec/VAD/PTT. A negotiation-only candidate must also keep original queue and reject v2 audio messages. |
| Server identity | V2 requires active IP client, accepted-join incarnation, hex GUID matching registered lobby XUID, and an admitted exact endpoint. Pinned party server-info hook registers XUID in `SV_MainMP_GetServerLobby`; private-slot rules include agent count. | Witness actual MP slot/XUID equality internally, active humans versus bots/agents, accepted-join callback and generation on reconnect. No synthetic registration to make an otherwise ineligible MP peer pass. Keep raw identities local. |
| Client session | Selected session `0x140D32740`, controller `0x140347690`, slot `0x140D32920`; session handle, host, challenge, local user and slot trigger resets. | Verify selected MP game session and own slot against native roster; a lobby/session name containing MP does not prove runtime equivalence. Mode change must invalidate the negotiated state too. |
| Registration ownership | `mirror_roster` preserves same-user mute, can register missing remote users, refuses foreign registered occupants; `release_users` removes only recorded same-user registrations. | First MP candidate observes registrations without replacing them. Full v2 later needs proof that remote registrations and voice flags survive without changing team/privacy semantics or native-owned users. |
| Recipient routing | `voice_transport.hpp::server::receive` broadcasts accepted audio to every other leased peer. No team, dead, spectator or native destination predicate is supplied. | **Blocking for MP v2 audio:** derive actual engine-authorized sender→recipient eligibility. Do not widen the CP predicate and broadcast enemy/dead/private speech. Missing/ambiguous authorization fails closed. |
| Receiver privacy | V2 checks typed `cl_voice`, exact registered member/XUID and `engine::muted` at `0x14037BBA0`, then calls `Voice_Incoming` at `0x140D59620`. | Preserve those checks and prove actual platform/scoreboard behavior. Receiver mute does not establish server team/dead delivery eligibility, nor undo data already sent to an unauthorized receiver. |
| Capacity | Wire/state arrays support 18 speakers. Pinned session layout has compile-time size/offset assertions; its game-client team/session fields are not presently an authorization adapter. | Cap the initial candidate at two humans and reject out-of-range slots; no 48-player voice claim. Layout assertions are source facts, not a runtime team/dead policy proof. |
| Protection and audio admission | Current `paris_test_fixture` private heartbeat and client connect path are CP-specific; `client_request` can explicitly select CP. Explicit capture selector also requires its fresh owned native client session. | Implement a separate mode-aware MP fixture/runner before MP automated PTT or capture. Do not reuse CP auto-join/heartbeat and silently switch the test back to Zombies. |

The first candidate should make MP observable while retaining native transport.
Proposed ownership after the current native freeze: `voice_relay.cpp` for a
read-only mode/session status record and a pure mode policy test; a separate
mode-aware lab fixture for MP protection/admission. It should report
`native_passthrough_mp`, current session validity, slot/registered/voice masks,
and eligibility unknown separately from false. Do not log XUIDs, endpoint
addresses or privacy settings identifying an owner. With no new lab flag, CP
v2 behavior and MP/SP/local passthrough must remain identical.

A second, still silent candidate can add explicit lab-only **MP negotiation**
once that fixture exists. Require isolated build/marker, exact process/session,
loopback test ports, fresh protection and two independently reserved endpoints.
Reuse wire parsing, generation/challenge/replay/rate budgets, but reject audio
up/down, keep the original queue, and observe native registrations rather than
calling `mirror_roster`. Its source tests must prove absent flag behavior,
MP-only admission, malformed/foreign endpoint rejection and no audio dispatch.
Its live witness is hello/confirm/current slot/generation with reconnect and
map/mode transition resets; it is not MP voice acceptance. A guarded no-audio
PTT 0→1→0 witness can then use the proven ordinary 81/82 entry contract without
enabling a microphone or creating a private PCM route.

The full MP port remains blocked on a bounded retail authorization trace. The
pinned SDK exposes `gclient_s.sess.sessionState` (asserted offset 19092) and
`sess.cs.team` (19424), but reading these two fields is insufficient: FFA, team,
spectator, intermission, alive/dead rules, private-party channels and engine
dvars can change permissions. Trace the ordinary voice recipient selection
and its actual predicates from known queue/send consumers; use one verified
engine predicate or a faithfully tested adapter. Do not infer a universal
same-team-only rule. The existing relay transport needs an explicit recipient
filter input so unauthorized recipients are excluded **before** sending encoded
frames. Generation and authorization must be revalidated at dispatch, with
unknown state refusing audio. This requires a separate reviewed native delta;
the present source has no such MP policy implementation.

The ordinary speech matrix follows the native MP baseline first, then the same
cases on a reviewed v2 candidate: permitted teammate/FFA speech; enemy isolation
according to the original mode; alive→dead, dead→alive, dead→dead and spectator
transitions; scoreboard mute/unmute; native voice disabled; disconnect/reconnect,
slot reuse, team change and map change. Use distinct original SAPI phrases through
explicit CABLE Input rendering → approved DirectSound capture GUID → ordinary
capture/encode/PTT → selected transport → native decode/render → owned receiver
process-tree loopback. Record whether each recipient was permitted, encoded
frames sent to that recipient, decoder/enqueue work and matching receiver phrase
window. Known voice-disabled or forbidden cases require silence as well as no
unauthorized relay delivery; positive counters alone cannot prove intelligibility.

The current machine has no completed two-endpoint voice admission and no live
virtual route witness. Budgets stay at their current estimates until repeated
actual CP/MP measurements justify revision, or a genuinely independent second
endpoint is available. The SoundVolumeView execution was rejected by automatic
review (`blocked by policy`); no retry or alternate execution route is included
here. A driver/default-restoration block does not prevent the silent MP/session
work above, but still prevents claiming the complete audio route is ready.
