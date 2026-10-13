# Native Zombies voice

## Current two-player beta preparation - 2026-10-04

The current bounded local candidate is generic protocol 2. Create its private
player package with `ops/Package-Voice.ps1 -GenericRelay`; the package declares the
selected protocol and binds its launcher hash. Follow [VOICE-PLAYER.md](VOICE-PLAYER.md).
The test uses server-mediated UDP on the existing game socket. Local synthetic
evidence is separate from real microphone/LAN/WAN acceptance and the official
contribution gate.

`ops/Server.ps1 -Action DeployVoice -GenericRelay -KeepCurrentScripts` activates
the checked native build after thirty seconds of valid zero-client UDP. It backs
up custom/ordinary launchers, the earlier executable and bank data, preserves the
currently deployed GSC/configuration and writes a separate generic server launcher.
It never stops the owner's client. Subsequent `-Action Start -Binary Voice` uses
the selected protocol in the local activation manifest. `-Action RollbackVoice`
returns to the original server after the same occupancy gate. Keep raw process
records, logs and private hashes outside Git.

No agent protection or synthetic capture flag belongs in this player profile.
The known historical heap incident and the full [release matrix](VOICE-CONTRIBUTION.md)
remain open. [The current delivery record](deployments/2026-10-04-voice-player-beta.json)
proves normal v2 startup, preserved base files and a 126.344-second idle witness.
The stock dedicated process required the authorized fatal-process recovery
exception after a matching crash dump, read-only native zero-occupancy inspection
and diagnostic/bank backups. Its null-write cause remains unknown. This incident
did not pass the ordinary UDP gate; that gate refused before deployment changes.
Keep the owner client running until the owner chooses to use the player launcher.
Earlier protocol-1 descriptions below are historical research.

The owner requested implementing unsupported voice, prioritizing Zombies. This authorizes native client/server work beyond the earlier GSC maintenance scope. Custom source is in `src/native/`; immutable originals and the four gameplay scripts are preserved.

Aurora administrator m jkzy confirmed missing support on [6 January 2026](https://discord.com/channels/945420505157083208/1208634261213552750/1458029166417936476). The [June 2025 configuration discussion](https://discord.com/channels/945420505157083208/1208634295296462858/1388596410395660339) includes a user's `sv_voice` setting, which is not evidence that transport exists. Authenticated Discord searches and official source were inspected without posting messages.

## Implementation

Voice remains unaccepted. The current forwarding investigation and corrected
protected base-game harness are in [VOICE-NATIVE-TRACE.md](VOICE-NATIVE-TRACE.md).
Protocol 1 below is an experimental fallback with an unresolved speaker reconnect/
slot-generation defect; it is not established as the final architecture.

IW7 contains DirectSound capture/playback and Speex. Legacy sending depends on online party/session connections. Empty Steam voice methods in the mod are not sufficient to identify the cause: this engine uses its own audio chain. The experimental overlay intercepts encoded local frames and relays them through the existing game UDP socket.

- Protocol 1 negotiates a random challenge and server-issued endpoint capability. Only active Zombies clients may negotiate/send/receive. The server derives each speaker from the exact connected endpoint and validates its claimed slot.
- Frames send promptly. Limits: 1200 bytes/datagram, ten frames, 254 bytes/frame, bounded inbox, replay protection and frame/byte rate limits. Engine calls run on server/main pipelines.
- Native PTT, mic settings, threshold, `cl_voice`, scoreboard mute lookup and privacy checks are retained. Their complete gameplay behavior still requires owner acceptance.
- Endpoint/identity changes, disconnects and timeouts invalidate capabilities. Every speaking/listening participant needs the custom build. Stock clients retain gameplay but do not speak this protocol.
- Scope: Zombies only. Multiplayer's team/dead/spectator routing is deferred. UDP voice is not encrypted; no confidentiality guarantee is claimed.
- Synthetic calibration returns only to its connected sender, subject to capability, replay and rate checks. It never transmits a test tone to other players or echoes to unconnected endpoints.
- During a connected Zombies map load, stale captured frames are discarded rather than added to the unroutable legacy party queue. A new active connection negotiates again.

## Build and operation

`ops/Install-Tools.ps1 -IncludeNativeVoice` installs the necessary Microsoft tools. `ops/Build-Voice.ps1` builds pinned Aurora source with our component overlay. `-TestsOnly` runs the standalone protocol checks. Provenance is in TOOLS.md. Ignored `runtime/voice-package` holds the executable and SHA-256/source manifest. Never commit game assets, reference dumps, binaries or private logs.

`ops/Package-Voice.ps1` creates a fresh private player ZIP, including complete pinned upstream source/submodules, the two modified component files and GPL/dependency licenses. No game assets or supplied Paris GSC scripts are bundled. `ops/Install-VoiceClient.ps1` checks the binary hash, preserves previous custom files and installs alongside the official launcher. It refuses to replace a running different build. The player launcher contains only `-noupdate -nosteam -cpMode`; no server IO or development flags. See VOICE-PLAYER.md.

`ops/Server.ps1 -Action DeployVoice` validates hashes, requires at least 30 seconds of zero-client live responses, backs up managed files/launchers and bank data, then installs `iw7-paris-voice.exe` alongside the official launcher. Custom builds use `-noupdate`; `iw7-mod.exe` stays intact. `-Action RollbackVoice` safely returns to the official server without touching bank/scripts. `-Binary Stock` or `-Binary Voice` explicitly selects a start; otherwise the local activation manifest selects it.

No router change or extra public port: UDP 27016 remains in use. `ops/Set-VoiceFirewall.ps1` allows only this native executable's server UDP 27016. Windows created an explicit Public-profile UDP deny when the new executable started; that exact executable's UDP deny was disabled because deny overrides allow. Official launcher/TCP/router rules are preserved. Changes are recorded locally. UAC may be required.

## Diagnostics

- `paris_voice_status`: readiness, captured/sent/relayed/decoded counts, actual PCM/DirectSound queued bytes, queue errors, native capture callbacks, registered-session count and rejected/muted counts. No names, credentials or audio content.
- `paris_voice_selftest`: twenty synthetic frames through the actual engine codec; verifies output size and signal energy, without microphone/network transmission.
- `paris_voice_network_test`: twenty synthetic frames via the server back into this client's native incoming/playback path. A brief local tone may be audible. Requires a ready Zombies connection and voice enabled.
- `-paris-voice-diagnostics`: status every ten seconds during technical tests.
- `-paris-voice-local-test`: development-only fixture connects to 127.0.0.1:27016 after initialization, runs one network calibration once ready, and exits its test client after 300 seconds. Never add this to normal player launchers.
- With that local fixture only, `-paris-voice-relay-test` sends 1000 synthetic frames after a 60-second joining window. It sends to other connected voice clients. Run only in an owner-free development session.
- `-paris-voice-capture-test` makes that relay fixture inject synthetic PCM after the device, through native gain/threshold/encoding and the real queue hook. PTT is temporarily changed only for each synchronous test call and restored. This proves the post-device chain, not intelligible live speech.
- `-paris-voice-gate-test` checks native voice-disable, released PTT and remote mute/unmute APIs on both local clients; temporary settings/mute state are restored. Actual scoreboard UI and owner settings still need acceptance.
- `tests/native/audio_output_probe.cpp` measures Windows WASAPI loopback RMS and matched 400..480 Hz signal energy to account for native adaptive playback frequency. It saves metrics only, with no recording.

Calibration uses signed 16-bit PCM and the engine's actual 8192 Hz playback rate. Early float-input/8000 Hz test assumptions were corrected before recording final audio-output evidence. Dedicated servers never initialize an audio device.

Codec tests, protocol tests, startup and network tests are distinct. None alone proves real microphone-to-other-player intelligibility, remote Internet delivery, mute UI, device routing or map transitions. The owner performs final two-player acceptance. No first-attempt guarantee is asserted.
