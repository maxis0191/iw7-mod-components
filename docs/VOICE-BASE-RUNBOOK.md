# Protected base-game voice test

This private harness validates the experimental generic relay. It is not an
official release or a substitute for real human LAN/WAN speech. Current results
and remaining release gates are in [VOICE-CONTRIBUTION](VOICE-CONTRIBUTION.md).

## Prepare and join

Use the existing base installation and a dedicated worktree. Preserve any owner's
occupied game. Build, run source checks and commit the candidate before deployment.
The preparation verifies source/build hashes and creates a dated managed-file and
bank backup. It preserves the owner's launcher, updater cdata, profile and keys.

```powershell
./ops/Build-Voice.ps1 -TestsOnly -Sanitizers
./ops/Build-Voice.ps1 -ServerModules
./ops/Test-Sources.ps1
./ops/Voice-BaseTest.ps1 -Action Prepare -GameRoot 'YOUR EXISTING GAME ROOT'
./ops/Voice-BaseTest.ps1 -Action StartServer -GenericRelay
./ops/Get-ServerInfo.ps1
./ops/Voice-BaseTest.ps1 -Action StartClient -GenericRelay
```

Wait for `--- Common Initialization Complete ---` in the owned client's stdout,
then Connect. Allow 90 seconds for normal initialization/join. On timeout preserve
logs, query live process/UDP state and diagnose before recovery. A missing UDP
reply alone does not establish a crash.

```powershell
./ops/Voice-BaseTest.ps1 -Action Connect
./ops/Voice-BaseTest.ps1 -Action Verify
./ops/Voice-BaseTest.ps1 -Action StartClient -ClientSlot B -GenericRelay
# Wait for B's native initialization before connecting.
./ops/Voice-BaseTest.ps1 -Action Connect -ClientSlot B
./ops/Voice-BaseTest.ps1 -Action Verify -ClientSlot B
./ops/Test-VoicePairIdle.ps1
```

Both clients must be distinct and active on the owned private cp_zmb dedicated.
Verify requires fresh actual engine godmode, native inactivity=0 and cheats=0.
The scoped retail-GSC inactivity exception stays bound to the protected current
UID/endpoint. The arena must report zero alive enemies, pending spawns and
reservations throughout. Native and roster masks must both be 3. The idle helper
takes nine paired samples over at least 120 seconds, exceeding the retail
90-second inactivity interval. Stop immediately if any safety condition fails.

## Observe output and native controls

The build creates `runtime/audio-output-probe.exe`. It observes the default
Windows render mix, writes aggregate metrics only and saves no audio. Keep other
system audio quiet. Establish a no-probe baseline with the executable's `5 997`
arguments; exit 1 means no strong target window, 0 means target present, and other
codes are observer errors. Do not use a contaminated baseline as causal evidence.

```powershell
./ops/Measure-VoiceOutput.ps1 -Sender A -Label default-A
./ops/Measure-VoiceOutput.ps1 -Sender A -Probe VoiceCodecProbe -Label fixed-A
./ops/Measure-VoiceOutput.ps1 -Sender B -Probe VoiceCodecProbe -Label fixed-B
./ops/Voice-BaseTest.ps1 -Action VoiceMute -ClientSlot B
./ops/Measure-VoiceOutput.ps1 -Sender A -Probe VoiceCodecProbe -Label B-muted -Expected Absent
./ops/Voice-BaseTest.ps1 -Action VoiceUnmute -ClientSlot B
./ops/Measure-VoiceOutput.ps1 -Sender A -Probe VoiceCodecProbe -Label B-unmuted
./ops/Voice-BaseTest.ps1 -Action VoiceDisable -ClientSlot B
./ops/Measure-VoiceOutput.ps1 -Sender A -Probe VoiceCodecProbe -Label B-off -Expected Absent
./ops/Voice-BaseTest.ps1 -Action VoiceEnable -ClientSlot B
./ops/Measure-VoiceOutput.ps1 -Sender A -Probe VoiceCodecProbe -Label B-on
./ops/Measure-VoiceOutput.ps1 -Sender A -Probe VoiceReleasedProbe -Label A-released -Expected Absent
./ops/Voice-BaseTest.ps1 -Action VoiceRestore -ClientSlot B
```

Repeat the control sequence with sender B and receiver A. Restore both clients in
a `finally` block when scripting the sequence. Each measurement verifies both
clients before/after, observes for 15 seconds, waits at most 20 seconds for the
observer and retains before/after counters in ignored runtime JSON. A failed
presence/absence expectation preserves its evidence and throws.

Correlate output with the native counters: a held probe offers/sends/relays sixty
frames; the receiver decodes sixty and queues 19200 bytes, while the sender does
not decode its own stream. Muted/off receivers must block those sixty frames with
zero decoder/target-frame delta. Released PTT must offer/send zero. A request
acknowledgment, output mix or playback-call counter alone is not proof.

VoiceCodecProbe is a private loopback synthetic calibration. It saves native
VAD/DTX, temporarily disables them and reapplies the unchanged configured
narrowband mode before encoding. Require `restored=1` and `mode_preserved=1` after
each probe. This avoids a retained null DTX mode; it performs no codec reset and
changes no production codec behavior. The normal constant tone can be suppressed
by native VAD/DTX, so its missing target alone cannot establish a relay failure.

## Reconnect and cleanup

Stop A, retaining its actual exit code, then start/connect a fresh A while B stays.
Verify both, repeat paired idle sampling and measure both fixed-mode directions.
Inspect admission/roster/native masks and fresh sequence delivery. This does not
cover different-identity slot reuse, map transitions or real remote clients.

```powershell
./ops/Voice-BaseTest.ps1 -Action StopClient -ClientSlot B
./ops/Voice-BaseTest.ps1 -Action StopClient
./ops/Voice-BaseTest.ps1 -Action StopServer
./ops/Voice-BaseTest.ps1 -Action Restore
```

StopClient restores controls, queues native lifecycle commands and records the
actual exit code; nonzero exits fail. StopServer requires valid zero-client UDP
responses for 30 seconds and the exact owned dedicated identity. Restore retains
current bank data and restores only managed test files. Never equate PID
disappearance or a forced recovery with clean lifecycle acceptance. Every native
build archives matching executable/PDB locally by executable hash. Keep dumps,
identifiers, recordings, private configuration and game-derived output out of Git.

The earlier reconnect `0xC0000374` remains open despite subsequent clean cycles.
PageHeap is an optional diagnostic, not normal test setup: its heavy asset-load
overhead invalidated an instrumented cleanup run. Scope it to the owned trace
image, preserve existing settings and remove new persistent per-image settings
after launch. See [native trace notes](VOICE-NATIVE-TRACE.md).
