# Native voice investigation

Voice is not accepted. Issue #4 remains open. Trace the original engine path before
choosing a repair; the protocol-v1 overlay remains an unaccepted fallback.

## Independent audio witness

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

## Retained first attempt

Candidate aae11b0 built and runtime-linked on private cp_zmb; its client joined with
fresh engine godmode/inactivity=0/cheats=0. Native audio/capture and local session
registration were present (local slot 0, one registered/voice-registered user).
Its activity-mode synthetic blocks encoded zero: the separate hardware mic meter
stayed below the native threshold. That failed witness cannot establish a capture
or routing defect. The correction uses paired native PTT. Retail interaction setup
warnings (cryobomb/forgefreeze) are retained locally and not counted as voice proof.

## Static evidence and open choices

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
