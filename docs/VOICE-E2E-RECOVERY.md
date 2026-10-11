# Speech receiver test recovery - 2026-10-11

Issue [4](https://github.com/maxis0191/iw7-paris-server/issues/4) remains open.
The owner asks for a working voice path and actual received speech evidence.
They are still playing and explicitly ask us to continue corrections meanwhile.
No owner process, Main runtime, bank, client settings or audio device is changed.

## Recovered scope

This branch starts at main `4ae64279b79a83cfacfbe6a49d945f061e9b062d`.
It brings across only the voice work from the retained modular-agent-platform
checkout, leaving its unrelated engine-capacity and model work intact:

- `75ef6ff`: pin the original kernel process image, because the IW7 loader's
  module-name alias can point at the retail executable instead of our client.
- `23679dc`: preserve the single initial, silent, unarmed map transition;
  later shutdowns or invalid protection/binding still cancel test capture.
- `b7dde30`: observe the known Aurora/MinHook PTT hook through its actual owner.
  The previous pristine-byte guard rejected the legitimately hooked input.
  This bridge is compiled only for isolated server-module test builds.
- `a1ecbd7`, followed by the retained uncommitted recorder/provider/scheduler
  changes: own the recorder from suspended creation through terminal status,
  producer EOF, WAV validation and checked cleanup. Preserve the exact source
  and original process/file handles. The scheduler now imports this provider.

The uncommitted recorder refinements had no individual commit history. This
recovery records that gap instead of attributing them to the older commits.
The hashed `PTT-InputBase.inc` is the pinned public Aurora source fixture;
its original trailing tabs are preserved by a file-specific whitespace attribute.

## Reproduced failure and correction

The recovered recorder test failed at its state getter with Win32 error31,
`Original recorder kernel image query failed`. Its real worker could finish
normally before polling. Windows could no longer return the executable path
for that exited process, although the parent still held its original handle.
This also affected the production receiver recorder after its normal timeout.

`CaptureIdentity` stays strict for live launch/admission. `CaptureObservation`
can report an exited recorder only after the original process handle is
signaled. It verifies its original PID/creation time, reads the exit code,
rehashes the retained immutable image and records the post-exit path-query
result honestly. It also handles exit racing the live image query. Observing
exit does not stand in for producer EOF, WAV validity or completed cleanup.

The native lifecycle worker now waits for explicit parent release in its live
cases. A separate immediate-exit case requires polling after confirmed exit,
then validates the final WAV and closure. This replaces a timing-dependent
sleep without bypassing the original handle checks. The worker emits test PCM;
it uses no audio device or game process.

## Current validation

Fresh CL compilation of the changed worker (`/W4 /WX /Od /RTC1`) and the real
Windows recorder lifecycle test pass: live readiness/release, normal exit before
polling, valid/truncated WAV, rejected and expired admission, original-handle
closure, immutable output and final cleanup. Its scheduler is mocked; its child
process, handles, NTFS identities, source compilation and WAV files are real.

Other passing checks: 73 recorder admission policies, 121 cleanup fault cases,
707 native PTT provenance checks, 80 PTT build-copy contracts, the actual kernel
image-alias regression, native startup binding, voice transport/reconnect/fuzz,
and seeded WAN transport models. Provider, witness, waveform-envelope and source
option tests pass. Source validation verifies supplied originals, PowerShell,
GSC parsing and the unchanged 17-script/910-identifier catalog.

These are component and simulated-network results. They do not prove speech
audibility, microphone capture, a remote PC, or Multiplayer voice support.

## Runtime gate and exact next action

The complete build was refused by the shared resource scheduler: the observed
73.11% commit use could not admit its 6GiB commitment plus the required20%
headroom. The occupied owner client alone reserved about14.86GiB. No full native
build or two-client game launch was attempted after that refusal. The owner
subsequently confirmed they are still playing. Do not terminate that client,
lower reservations or trim other applications to get admission.

When the base client is vacant and the shared scheduler admits the work:

1. Build the exact merged source with `ops/Build-Voice.ps1 -ServerModules
   -IsolatedLab -Debugger` and compile the receiver probe from its pinned source.
   Archive the build manifest, executable and source hashes locally.
2. Revalidate the retained agent-debugger dedicated, stock manifest and empty
   ownership. Use the existing `Voice-Pair-Lab.ps1` runner, base client plus its
   justified independent peer, audio-enabled20/20GiB group, and no live debugger.
   Fresh engine godmode, inactivity0 and cheats0 remain mandatory.
3. Use the pinned short phrase `Alpha seven. Blue lantern.` on A and silent input
   on B. Retain actual PTT, capture/codec/relay/native-playback counters and B's
   exact process-tree WAV with its recorder closure/hash receipts. Listen to
   that WAV and assess intelligibility; waveform correlation alone is insufficient.
4. If any step fails, fix that first failing boundary using its actual evidence.
   After A-to-B passes, exercise the opposite direction, released PTT, mute,
   reconnect and map changes. Then verify real microphone/device and remote-PC
   behavior separately. Software injection enters the normal capture interface
   but does not exercise a physical microphone or simulate two independent OSes.

No new recording of speech received in game exists from this recovery. No build
was promoted to Main and no accepted voice tag is justified.
