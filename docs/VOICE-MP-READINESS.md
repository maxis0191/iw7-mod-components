# Voice routes and Multiplayer readiness - 2026-10-12

Source audit at `21b91e3ebace48fda5ed60024719168064b2cca5` (private main).
Issue 4 remains open. This document does not enable MP voice or report a new
audio test. The initial pass was documentation-only. The parent subsequently
extended ownership to the legacy player packager and associated light tests;
the resulting correction is recorded below. Native/shared runtime files remain
unchanged. Integration/publication and later resource admission belong to the
coordinating voice chat.

## Current evidence and supported route

PR126's exited-recorder/PTT failure is corrected. PR127's protected synthetic
run 19 A-to-B and run 20 B-to-A passed and restored. Actual decoder/submission PCM
recognizes all four words of `Alpha seven. Blue lantern.` in both directions.
The actual final process-tree recordings contain received speech, but complete
final-output word recognition remains unaccepted. This is not physical-microphone,
independent-PC, WAN, human-listening or MP acceptance. See
[the current witness](VOICE-SPEECH-WITNESS-2026-10-11.md) and the explicitly
historical [recorder recovery](VOICE-E2E-RECOVERY.md).

| Scenario | Current source behavior | Evidence boundary |
| --- | --- | --- |
| Matching v2 clients and dedicated in an external CP game | Native capture/codec, `iw7voice` protocol2 relay, native session registration and playback | Bidirectional synthetic CP witness exists; final mix and real-player acceptance remain open |
| MP with `-iw7-voice-relay` | Component may install, but CP guards exclude server/client transport; encoded queue forwards to the original native function | Deliberately deferred; `installed=1` does not mean MP support |
| SP or locally hosted/listen game with v2 flag | Original queue behavior outside the external CP route; no v2 listen-server relay is instantiated | No compatibility/audio acceptance from this audit |
| Custom voice binary without v2 flag | `voice_relay_status` reports disabled; ordinary non-trace profile retains legacy `parisvoice` protocol1, itself CP-gated | Not a switch to an MP implementation; protocol1 and protocol2 do not interoperate |
| Ordinary Aurora client joining the CP server | Gameplay is intended to remain compatible with empty `fs_game`; client has no v2 handshake/receive implementation | Joining or hearing game audio cannot prove relay voice; fresh ordinary/mixed-client regression is still required |

Here CP means engine `GAME_MODE_CP`, and MP means `GAME_MODE_MP`, not simply
multiple human players in a Zombies match.

## Exact routing and gating points

References below are repository-relative, with one-based lines at the audited
commit. The retained SDK is read locally, not fetched from official upstream.

| Boundary | Source and line | Consequence |
| --- | --- | --- |
| Wire channel and native ABI | `src/native/voice_relay.cpp:28`, `:32-41`, `:68-98` | `iw7voice`; queue `0x14037D960`, selected session `0x140D32740`, incoming `0x140D59620`; native signature mismatch disables installation |
| Mode and voice toggle | `src/native/voice_relay.cpp:114-122` | `zombies()` accepts only CP; client `cl_voice` must be a true enabled bool |
| Accepted connection incarnation | `src/native/voice_relay.cpp:196-205` | Original game-state call is forwarded; a fresh incarnation is assigned only in CP after accepted connection |
| Server admission | `src/native/voice_relay.cpp:207-260` | Outside CP/loaded server, reset transport and admit no sources; inside CP require active slot, IP endpoint, incarnation, registered lobby UID and exact parsed GUID agreement |
| Native remote registration | `src/native/voice_relay.cpp:307-351`, `:475-492` | Mirror only negotiated peers, reconcile missing registration every 250 ms, retain healthy/foreign native users and preserve applicable mute state |
| Client connection | `src/native/voice_relay.cpp:354-374` | Require CP, no local server, current IP host and active native client/UI; MP exposes `gate=not_zombies` after client tick |
| Client identity | `src/native/voice_relay.cpp:386-443` | Selected session handle, local UID/slot, game challenge and host are bound; server/client slot mismatch resets the client |
| Receive/playback | `src/native/voice_relay.cpp:423-472` | Validate transport/roster generation, native registered/voiceRegistered UID, `cl_voice` and native mute/privacy function before forwarding each frame to native incoming |
| Capture/queue replacement | `src/native/voice_relay.cpp:502-532` | Native capture already applies PTT/threshold. Only connected external CP replaces the original queue. MP/SP/local games forward the original; CP loading frames may be discarded |
| Installation and roles | `src/native/voice_relay.cpp:593-645` | Explicit v2 flag and native signatures required; only dedicated processes instantiate server transport, clients get queue hook/main tick; diagnostics flag emits status every 10 s |
| Teardown | `src/native/voice_relay.cpp:284-306`, `:612-623` | Release only owned matching native users, reset client and server epoch; this is source behavior, not new reconnect/map audio proof |

The v2 adapter does not consult `sv_voice` or `paris_mod_voice`; changing either
does not activate an MP route. Legacy `paris_mod_voice` controls the v1 server in
`src/native/paris_voice.cpp:165-176` and `:385-390`. Do not infer native capture
or privacy behavior solely from the absence of those dvars in this adapter.

Legacy v1 is also CP-only (`paris_voice.cpp:282`, `:390`, `:445-451`). Its
queue forwards the original outside its selected route (`:639-676`). Generic
v2 returns early from the legacy component unless explicit native tracing is
requested (`:1030-1045`); even then its queue hook is not installed over v2
(`:1081-1088`). Adding flags cannot supply the missing MP routing logic.

Native forwarding trace functions remain available in source: original batch
at `0x14037D5C0`, session send at `0x14037BFF0`, receive at `0x14037CFF0`
(`paris_voice.cpp:199-215`, `:1071-1088`). Trace activation checks explicit lab
flags/signatures (`:191-195`, `:1042-1045`), but the complete protected test
scenario below is CP-specific. Trace counters alone do not identify intelligible
receiver output or prove a valid MP fixture.

## Normal client and package limits

`config/Start-IW7-Zombies-Voice.bat:3` launches
`iw7-paris-voice.exe -noupdate -nosteam -cpMode -iw7-voice-relay`.
Bare double-click on exactly that executable name adds the same four flags
(`src/native/voice_relay.hpp:11-19`). Explicit arguments preserve their own
profile; no implicit defaults are added. Existing
`tests/native/voice_launch_test.cpp:7-26` specifies this behavior, including an
explicit MP argument case; it was inspected, not rebuilt in this audit.

Do not use the Zombies launcher for an MP test, or simply remove the v2 flag
and call the result stock: the custom binary also contains legacy hooks.
Use an explicitly identified ordinary-client baseline when testing ordinary
compatibility, then the exact candidate, sequentially with preserved profiles.
All v2 speakers/listeners need compatible native code and the selected v2
profile. A stock peer cannot be made relay-capable by server GSC or an asset
download. No distribution alternative is proposed here.

`ops/Package-Voice.ps1:7-20` verifies build/source/overlay hashes and rejects
isolated, trace and asset-experiment builds. Its default is v2 (`:1`, `:28-35`).
The small player ZIP contains the executable, batch, guide and license; complete
source/tests/build manifest are a separate archive (`:23-27`, `:36-62`,
`:97-115`). `Protocol=1` in the build manifest is historical metadata;
`SelectedVoiceProtocol=2` is the package's selected transport. The explicit
installer checks both (`ops/Install-VoiceClient.ps1:13-24`).

**Reproduced source-contract defect at the audited main:** packaging cannot accept a fresh
ordinary build's full manifest. `Build-Voice.ps1:223-225` always lists 23 base
sources; `Package-Voice.ps1:10-12` permits only 14. Read-only PowerShell AST
comparison finds nine rejected current sources, first `voice_capture_adapter.hpp`:

- `voice_capture_adapter.hpp`, `agent_scenario.hpp`
- `paris_model_diagnostics.cpp`, `paris_model_diagnostics.hpp`
- `paris_incident.cpp`, `paris_incident.hpp`
- `paris_afk.cpp`, `paris_afk.hpp`, `afk_inactivity.hpp`

`Build-Voice.ps1:459-461` carries these into `SourceHashes`, so the packager
will throw `Native source changed since build.` even when their hashes match.
ServerModules adds two more source entries (`:226`) absent from that allowlist.
This finding does not invalidate an older completed ZIP and is not a newly
attempted build/package. The correction below restores the profile/source
contract, retaining exact hashes and the development-build refusal. Never bypass
it by deleting manifest entries or packaging the isolated witness.

The retained `voice-e2e` package was observed as `isolated-modules`,
`IsolatedLab=true`, project `a4b9cc62a377efa25078e3fd53ccff841fcf4308`, pinned
Aurora `77e6d4d24e918ee363b3feee3735c3b889dff7d7`. It is read-only shared input,
not an ordinary player release or a new build by this audit.

## Why the current CP witness cannot establish MP audio

1. `ops/Voice-Pair-Lab.ps1:106-115` hardcodes Zombies/Spaceland and `-cpMode`;
   its ownership/load check expects `cp_zmb` (`:177`). There is no MP scenario
   selected by changing the player command line alone.
2. Dedicated test protection requires CP (`src/native/paris_test_fixture.cpp:36-41`,
   `:860-873`); the connect fixture actively requests CP (`:738-744`). An MP
   observation must first establish fresh real engine godmode and inactivity 0
   with cheats 0 through a reviewed MP-specific protection path. Removing the
   CP check without validating MP entity/session assumptions is insufficient.
3. Fake capture requires isolated/client-test/audio-lab/v2 flags
   (`src/native/paris_voice_test_capture.cpp:454-463`). Its active observation
   requires `voice_relay::test_readiness()` plus both v2 roles and protected
   binding (`:410-418`). Those v2 roles cannot become ready in MP. Native MP
   instrumentation needs a separate legitimate native-session readiness
   contract; forging relay readiness would test a different route.
4. The CP finding that a client selected session registered only self is not
   an MP measurement. The native path is capture, queue, batch, selected
   session/local recipient routing, native `v` packet send, receive eligibility,
   decode/enqueue and output. Historical evidence and addresses are in
   `docs/VOICE-NATIVE-TRACE.md:611-640`. A relay roster cannot stand in for MP
   party/session users, channel/team eligibility, privacy or native recipients.
5. The relay server sends accepted audio to every other live voice capability
   (`src/native/voice_transport.hpp:219-234`); it has no team, dead-player or
   spectator routing inputs. Simply allowing MP would not establish its native
   channel rules. The CP adapter's use of `SV_MainMP_GetServerLobby` is also not
   evidence of MP support: the CP check runs before that call.
6. The retained pinned SDK sets `Voice_Init` to return only in dedicated
   (`tools/iw7-mod-native/src/client/component/dedicated.cpp:238-264`, `:339`)
   and has Steam voice stubs (`src/client/steam/interfaces/user.cpp:55-85`).
   Neither fact proves the first failing MP or CP boundary. No upstream refresh,
   download or reverse-engineering job was performed here.

The same retained SDK's dedicated selects CP for `cpMode`/`zombies`, otherwise
MP (`dedicated.cpp:432-443`). Its client command `mpMode` explicitly requests
MP (`command.cpp:470-473`). Exact arguments are necessary but still require
observing actual `GAME_MODE_MP`, loaded map and active joined clients; a menu
label or command acceptance is insufficient.

## Minimal prioritized continuation and one next MP experiment

1. Keep the already successful CP recorder and decode/submission work. Resolve
   the parent voice work's final-mix/negative-control acceptance separately;
   do not repeat PR126's fixed recorder diagnosis.
2. Before any automated MP exposure, implement and review only the missing MP
   protection, native-session readiness and passive route observations above.
   Preserve the v2 CP guards. First determine whether native MP works; extending
   relay mode guards would otherwise conceal the native baseline.
3. Integrate the package-contract correction below before the next normal build
   and release, then check stock/candidate mixed gameplay and candidate voice.
   This is independent of whether native MP needs a transport repair.

**One next MP experiment, after step 2:** a protected native-MP A-to-B witness
in a private test dedicated, two legitimately connected active same-team clients,
with original queue/batch/send/receive behavior forwarded and no relay-witness
fallback. Use a known four-second source at the actual capture interface and
silent receiver input, with ordinary paired native PTT down/up. Observe actual
mode, native local/remote session UID/slot/voice registration, mute/privacy/team
eligibility, encoded queue/batch, native send result, receiver packet acceptance,
decoder PCM, accepted enqueue bytes and final process-tree receiver WAV. Bind
every stage to the exact original process/build/session and one sender; retain
closure, hashes and restoration. Do not copy the sender source into receiver data.

The phase immediately before pressed PTT is a released-PTT negative control
with the same source available: no target receiver PCM or target speech may
appear. Target speech must appear only in the pressed phase, then stop after
release apart from bounded already-buffered output. Unprompted recognition must
first pass source and silence controls and then recover all four words from
both received PCM and final output; retain a listening assessment separately.
Counters, `installed`, PTT icons, `ready`, waveform correlation or a native
Voice_Incoming call are not sufficient success criteria. If a boundary fails,
stop at that first measured failure; do not widen routing or mute/privacy gates.

Budget proposal for that one later experiment: reuse existing test stock,
one dedicated plus base client A and the already justified independent peer B;
start from the prior 20/20 GiB group reservation, and increase it if fresh MP
estimates require more. This is a proposed admission request, not measured MP
capacity. RAM reserve remains 0 and independent commit headroom 20%; no concurrent
heavy group, no reservation reduction to force admission. Allow at most 5 minutes
for launch/readiness and one recording sequence of at most 29 seconds, then exact
cleanup/restoration. No new retail/SDK/PDB copy; incremental receipts/PCM/WAV
budget below 25 MiB, with crash artifacts retained separately under existing policy.
Stop before capture if valid MP protection/readiness cannot be established.

A successful local synthetic A-to-B run would prove only that specified native
MP path. Reverse direction, actual player PTT, mute/unmute, reconnect/map change,
team/opponent/spectator/dead-player routing, stock-client regression, microphones,
independent PCs and WAN/human intelligibility remain distinct subsequent gates.

## Checks performed in the initial audit

- Fetched existing private origin; created a source-only worktree from the
  audited main. No SDK/assets/runtime evidence were copied from `voice-e2e`.
- Read current routing source, retained pinned SDK source and PR126/127 evidence.
  No game, build, audio recording/analysis, native Add-Type or reservation ran.
- `tests/ops/voice_client_install_test.ps1` passed on inert text payloads in this
  worktree: positive/repeated install, seven rejected invalid packages,
  recoverable backups and official-binary/profile sentinel preservation. It
  exercises installer boundaries, not ZIP creation or real-player compatibility.
- Parsed build/package PowerShell and compared their literal AST source sets:
  23 mandatory base sources, 14 allowed, nine rejected as listed above. No full
  package was created. `git diff --check` passed for this document.

Preparation occupied 6,353,250 bytes before the final document review, below the
100 MiB preparation ceiling. This is logical file size, not an NTFS allocation
or free-space claim; no retail files were created.

## Package correction and targeted validation

The parent authorizes correction of `ops/Package-Voice.ps1` and its tests.
Only the two normal profiles are accepted: `native-helper` with the explicit
23 base files and `ServerModules=false`, or `server-only` with those files plus
the two Doom files and `ServerModules=true`. The profile must be a string and
ServerModules a boolean. All required source entries must occur exactly once,
have a canonical allowed filename and a matching SHA256. Missing, duplicate,
unknown, wrong-profile, path-like and laboratory sources fail before output
directories are created. New source files require deliberate review; there is
no universal allowlist or manifest-entry deletion fallback.

IsolatedLab, ExperimentalAssets, VoiceTrace, Debugger and VoiceCaptureSelectorBuild
must explicitly be boolean false. Declared fake-capture, PTT-bridge, capacity-watch
and capacity-checkpoint overlays must be disabled. Existing executable, upstream,
startup, dvar and other overlay hash checks remain. Upstream Git query failure is
also an explicit refusal. Older incomplete manifests require a reviewed rebuild,
not relabeling. This changes package admission, not installed player files.

`tests/ops/voice_package_test.ps1` constructs a tiny local Git SDK fixture and
inert text executable; it never copies the real SDK, game or retained evidence.
Its source manifest is derived from the real build script's literal source lists,
so a future build-source addition exercises the packager's explicit contract.
Three actual synthetic ZIP releases pass: native-helper v2, server-only v2 and
native-helper v1. Tests open both archives and verify player-file membership,
launcher/protocol selection, corresponding native/overlay hashes, source manifest,
test include paths, archive receipts and exclusion of an untracked private marker.

72 rejection cases pass: all 25 possible required sources individually missing,
unknown/wrong-profile/laboratory/path-like sources, duplicates, malformed/mismatched
hashes, actual source drift, invalid/mismatched profiles, nonboolean/absent flags,
enabled development overlays, missing required or changed provenance, upstream
identity and executable mismatch. Each refusal checks that no output root was
created and the input executable remained unchanged.

Both PowerShell 7 and Windows PowerShell 5.1 pass the suite. The initial 5.1 test
failed because its .NET Framework ZIP writer uses backslashes in entry names;
inspection found the correct four player files. The test reader now normalizes
separators while requiring exactly one matching logical entry and the exact
player-file set. Archive production behavior was not changed to hide that failure.
The existing CI installer test invokes the new package suite; its positive/repeat
installation, seven invalid-package boundaries and preservation checks also pass.
All three changed PowerShell files parse and `git diff --check` passes. No compiler,
native Add-Type, audio device, game or resource reservation is involved.

Preparation plus retained synthetic test outputs measured 12,450,423 logical
bytes before final documentation, still below the 100 MiB limit. No genuine
player release was produced; building/packaging real candidate binaries waits
for coordinated admission and the parent's GO.

## MP adaptation preparation: additional receiver boundary

Further source review finds an additional reason not to launch the current
runner as an MP test. `src/native/paris_voice_test_capture.cpp:325-342` creates
the per-frame receiver context only inside `received_playback`; its only caller
is `voice_relay.cpp:465`. Decoder/enqueue hooks collect only while that context
exists (`paris_voice_test_capture.cpp:171-187`). Native MP incoming does not
pass through this relay wrapper, so those hooks alone would yield no attributable
MP PCM proof. The current receiver witness also explicitly rejects
`paris-voice-native-trace` (`:506-518`) to avoid competing decode/enqueue owners.

The smallest substantiated implementation plan therefore has four boundaries:

1. Add an explicit MP plan/map expectation to the runner while keeping CP the
   default; remove no current CP guards or restoration checks.
2. Give MP its own reviewed protection and joined/native-session readiness,
   including exact local/remote slot/UID, native channel eligibility and original
   process/session lifecycle. Validate MP entity/flag assumptions before exposure.
3. Bind capture ARM to that actual native MP readiness instead of faking v2
   roster/generation evidence. Preserve original deadlines, PTT provenance,
   scope cancellation, source isolation and current CP behavior.
4. Give native MP incoming and decoder/enqueue observation one consistent hook
   owner, with verified native callsite/signature and synchronous context binding.
   Bind PCM to the real incoming remote user before the original call, never
   to fabricated relay frames; forward originals and retain actual output proof.

No safe native MP patch is implied merely by replacing GAME_MODE_CP with MP.
Native incoming ownership, MP protection and channel/session correlation are
still unverified execution boundaries. This task prepares their exact source
requirements without changing native code or claiming MP functionality.

No Main 27016 change, owner-client action, Windows-audio change, external message,
purchase or acceptance claim is part of this work. Local coherent commits are
supplied for parent integration; no separate PR/merge is made under this
delegated publication boundary.
