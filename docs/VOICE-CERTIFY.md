# Voice certification harness

Private tooling for this components repository. It never goes upstream.

Status, 2026-11-09: written and checked offline only (dry run, PowerShell tests,
analyzer tests, GSC compile check). It has never run against a game process. It
runs only after the owner allows in-game tests. Its results are agent evidence and
are not owner gameplay acceptance.

## Overview

The harness is designed to show, with recorded evidence, whether the upstream-shaped
voice component (`iw7-mod` branch `feature/voice-chat`: `src/client/component/voice.cpp`
plus a few `symbols.hpp`/`structs.hpp` entries) carries speech between two real
clients in Zombies and in Multiplayer. It also checks the cases where a player must
not hear.

A certification is two runs: the same matrix first on the **base** image (the same
lab build without the relay, run with `-Baseline`), where every "heard" window must
come out silent, then on the **fixed** image with the relay. Each call of
`Invoke-VoiceCertify.ps1` runs one image. On these Paris images the base run is the
Paris "before" row; it is not upstream PR evidence (see Prerequisites).

Known speech enters at the start of the talker's native pipeline. The decoded audio
is recorded at the end of the listener's pipeline. All the code in between is
unmodified production code:

```
[voicetest_play: SAPI phrase] -> native voice_capture_pcm (gain, VAD, Speex)
  -> native queue -> native flush = voice.cpp hook (native recipient policy, send)
  -> test dedicated (voice.cpp relay) -> listener voice.cpp receive (cl_voice, mute)
  -> native Voice_IncomingVoiceData (Speex decode)
  -> [recv_<talker>.wav: decoded PCM per talker, at the playback enqueue]
```

The second stage is optional and not implemented: recording each client's real audio
output with WASAPI process loopback.

| File | Role |
| --- | --- |
| `ops/voice-certify/Invoke-VoiceCertify.ps1` | Orchestrator: plan, `-DryRun`, safety checks, processes, scenarios, evidence, verdict |
| `ops/voice-certify/VoiceCertify.Core.ps1` | Pure helpers: scenario matrix, event and heartbeat parsing, SAPI phrase generation |
| `ops/voice-certify/fixtures/voicecert_cp.gsc` | Server fixture for Zombies: no player damage, zombies paused, retail inactivity kick fed |
| `ops/voice-certify/fixtures/voicecert_mp.gsc` | Server fixture for MP: no player damage, team control through retail `menus::setteam`, end of game |
| `ops/voice-certify/analyze_voice.py` | Analyzer: one verdict per window, `analysis.json`, `verdict.md` |
| `ops/voice-certify/phrases.json` | Phrase bank. No word appears in two phrases. |
| `tests/voice-certify/test_analyze_voice.py` | Offline analyzer tests (SAPI phrases, simulated reception, controls) |
| `tests/voice-certify/test_voicecertify.ps1` | Offline orchestrator tests and a dry run that must start nothing and write nothing |
| `ops/voice-certify/verify_engine_addresses.py` | Static address checks (owned by the test component work) |

The old voice lab tooling was retired on 2026-11-09 (see [VOICE.md](VOICE.md)).
The harness reuses only these small shared pieces: the resource scheduler, the
base-client backup and restore transaction, `LabProcess.cs` (owned process on a
private desktop), `Invoke-IW7OwnedStop` and `Get-ServerInfo.ps1`.

## Prerequisites

1. **Owner permission for in-game tests.** Without it, run only `-DryRun` and the offline tests.
2. **Lab images.** Build both from prepared inputs (`bootstrap.ps1`) under the
   shared scheduler:
   ```powershell
   ops\Build-Voice.ps1 -ServerModules -IsolatedLab -VoiceCertify              # base image (no relay)
   ops\Build-Voice.ps1 -ServerModules -IsolatedLab -VoiceCertify -VoiceRelay  # relay image
   ```
   Each build writes `runtime\voice-certify-images\<SHA256>\` with `iw7-mod.exe`,
   `iw7-mod.pdb`, `build-manifest.json` and `voice-certify-build.json`. Pass that
   `iw7-mod.exe` as `-LabImage`; the orchestrator reads the record beside it. The
   images carry three private overlays:
   * the test component `voice_test.cpp` (added through its own receipt), which is
     inert without `-voicetest <dir>`;
   * the isolated AppData overlay. `paris_lab_properties.cpp` moves AppData to
     `<cwd>\iw7-mod\lab-appdata` under `-paris-isolated-lab`, and the key-entropy line
     from `Build-Voice.ps1` gives each root its own identity;
   * the test privacy overlay (`Apply-TestPrivacyOverlay.ps1`). It suppresses the
     master heartbeat under `-paris-server-test` and `-paris-isolated-lab`.

   The record looks like this (`overlays.voiceRelay` is `false` for the base image):
   ```json
   { "schema": "iw7.voice-certify-build/1", "sha256": "<image SHA-256>", "image": "iw7-mod.exe",
     "overlays": { "voiceTest": true, "voiceRelay": true, "isolatedAppData": true, "testPrivacy": true },
     "upstream": "<native pin>", "relay": { "upstreamCommit": "...", "patchSHA256": "...", "files": [] },
     "voiceTestSHA256": "...", "projectCommit": "...", "projectDirty": false, "builtUtc": "..." }
   ```
   The orchestrator refuses an image whose hash or overlays differ. Use the base
   image with `-Baseline`.

   These images are the Paris fork (`cfca45b` plus the Paris overlays). Their
   results are evidence for the Paris build, not for the upstream PR head; upstream
   before and after rows need an upstream build.
3. **Test dedicated.** A retained, marked, stopped test root, for example
   `%USERPROFILE%\Documents\IW7-Runtime\private-test-server`. It must have
   `iw7-mod\paris-isolated-lab.marker`, game files, and `cp_zmb.ff`, `cp_rave.ff` and
   `mp_frontier.ff`, or the maps you pass. Never Main and never Canada.
4. **Client roots.** Client A runs from the base installation, and no owner client
   may be running. Client B runs from a peer root inside the server root, by default
   `<server>\agent-peer`, which is also the resource reservation scope. Two
   simultaneous receivers are the documented reason for this separation: each needs
   its own `players2`, `lab-appdata` identity and dcache. Prepare the peer root once
   with the existing reviewed pair preparation (the NTFS hardlink transaction behind
   `Agent-Pair-Prepare.ps1` / `Invoke-IW7AgentPairPrepare` in the server repository).
   Do not make a new physical retail copy. The harness never creates or deletes stock.
5. **Tools.** PowerShell 7, an installed en-US SAPI voice (Microsoft David or Zira),
   and Python 3.12 with numpy (scipy is optional). For ASR, `faster-whisper` must be
   importable and `Systran/faster-whisper-small` must be in
   `%USERPROFILE%\.cache\huggingface`. The analyzer loads models offline only
   (`HF_HUB_OFFLINE=1`, `local_files_only=True`).
   `faster-whisper==1.2.1` is installed in the per-user site-packages (2026-11-09);
   without it every "heard" window ends INCONCLUSIVE, never PASS.
6. **No other heavy job.** The shared scheduler refuses to start while a build,
   extraction or other lab is running.

## How to run

```powershell
# 1. Always first: prints every process, file change, command and assertion; starts nothing, writes nothing.
pwsh -NoProfile -File ops\voice-certify\Invoke-VoiceCertify.ps1 -DryRun `
  -ServerRoot $env:USERPROFILE\Documents\IW7-Runtime\private-test-server `
  -ClientARoot $env:USERPROFILE\Desktop\iw_game_files `
  -LabImage runtime\voice-certify-images\<SHA256>\iw7-mod.exe -IncludeEndOfGame

# 2. Only with the owner's permission: the same command without -DryRun.
```

| Parameter | Default | Meaning |
| --- | --- | --- |
| `-Modes` | `CP,MP` | Phases to run, each with its own server and client processes |
| `-ServerPort` / `-ClientAPort` / `-ClientBPort` | 27416 / 27417 / 27418 | Loopback test ports (27100-27999). 27016 is refused. |
| `-CpMap`, `-CpSecondMap`, `-MpMap` | `cp_zmb`, `cp_rave`, `mp_frontier` | Maps used |
| `-IncludeEndOfGame` | off | Adds M3. The post-game rotation then loads FFA for M4. |
| `-CaptureGate` | `Vad` | `Vad` sends `cl_pushToTalk 0` and `winvoice_mic_threshold`. `Ptt` assumes the test component holds push-to-talk itself. |
| `-MicThreshold` | 300 | VAD threshold. The retail default is 3276.8 (range 0-65536; the dvar is compared to `level*65536`). |
| `-CaptureRate` | 0 (auto) | Phrase rate. Auto uses the native rate from the client's start event. |
| `-AsrModel` | `small` | faster-whisper model name, resolved from the local cache |
| `-EmptyStopSeconds` | 30 | Zero-client window required before the test dedicated gets `quit` |

Offline checks, all runnable without the game:

```powershell
pwsh -NoProfile -File tests\voice-certify\test_voicecertify.ps1
python -I tests\voice-certify\test_analyze_voice.py -v
tools\gsc-tool\gsc-tool.exe -m comp -g iw7 -s pc -y voicecert_cp.gsc   # server repo tool; also voicecert_mp.gsc
```

The analyzer and its tests run with `-I`. The analyzer then adds back only the
per-user site-packages directory, where numpy is installed on this machine, and
nothing from the script or working directory.

## Run sequence

For each mode the orchestrator does the following:

1. It writes `iw7-mod\voicecert_server.cfg`: random `g_password`, `sv_lanOnly 1`,
   `net_ip 127.0.0.1`, `sv_cheats 0`, `g_inactivity 0` and `voicecert_enable 1`. For
   MP it adds `scr_skipclasschoice 1`, forced respawn and no time or score limit.
2. It installs the mode's fixture. Every other server `.gsc` is moved out of the
   way for the run, including `lab-appdata\cdata\custom_scripts`.
3. It starts the dedicated on a private desktop with
   `+set sv_lanOnly 1 +set net_ip 127.0.0.1 +set net_port <test port>`. Before any
   client starts, it requires the fixture's `armed` line (the fixture checks
   `sv_lanOnly`, the password, `sv_cheats` and the port from inside the server), a
   heartbeat, and `getinfo` showing `isPrivate=1 clients=0` and the expected map.
4. It starts client A, then client B. Each gets its own `-voicetest` directory and
   a startup `+set password`. Through `commands.txt` the orchestrator sends
   `voicetest_snapshot` until the component answers, reads the native capture rate
   from the start event, and synthesizes the phrase bank once at that rate (SAPI,
   canonical 44-byte PCM16 mono WAV, 250 ms of silence on both ends). It then sends
   `cl_voice 1`, the capture-gate settings and `connect 127.0.0.1:<port>`.
5. A client is in game when a fresh snapshot gives its clientNum and the fixture
   heartbeat lists that player. A and B must have distinct clientNums and distinct
   `iw7-public*.key` files in their own `lab-appdata`.
6. It runs the scenarios. Each window:
   1. takes fresh client snapshots (which flush the recordings) and a server
      snapshot, and checks the heartbeat (younger than 6 s);
   2. notes the byte length of the listener's `recv_<talker>.wav`;
   3. sends `voicetest_play <phrase>` and waits for `play_start` and `play_end`;
   4. waits a 2.5 s tail, takes snapshots again (the client numbers must be
      unchanged) and notes the length again.

   The two byte lengths delimit exactly the audio decoded during the window.
7. It sends `quit` to B and then A, through their owned handles. Termination
   happens only after 20 s. The server gets `quit` only after `getinfo` shows zero
   clients for `-EmptyStopSeconds`. Otherwise it is preserved, and the backups and
   reservation are retained.

After the last phase, it restores the backups of all three roots and verifies them
by hash: the staged `iw7-voicecert.exe`, cfg, fixture, marker, `players2`,
`lab-appdata`, `custom_scripts` and `logs`, and B's dcache. In A and B it also
restores the files the lab fixture writes there (`iw7-mod/paris-agent.*`,
`iw7-mod/paris-server-client.*` and the fixture screenshot), the same list as
`ops/Base-Client.Core.ps1`. It then releases the reservation and runs the analyzer.

## Scenario matrix

Expected results follow the native recipient rules (CL_ShouldSendVoiceTo and the
GSC-set `cg_*` voice dvars). In Zombies everyone is on allies with
`cg_deadChatWithTeam 1`. In team MP without lives, same team hears whatever the
life state, enemies never hear, and intermission or end of game sets
`cg_everyoneHearsEveryone 1`. In FFA both teams are 0.

| Id | Mode | Setup | Talker > listener | Expect |
| --- | --- | --- | --- | --- |
| C0 | CP | none (idle control, nothing injected) | A>B and B>A | silent |
| C1 | CP | none | A>B | heard |
| C2 | CP | none | B>A | heard |
| C3a | CP | B: `voicetest_mute <A>` (the scoreboard's session choice and native mute) | A>B | silent |
| C3b | CP | B: `voicetest_unmute <A>` | A>B | heard |
| C4a | CP | B: `cl_voice 0` | A>B | silent |
| C4b | CP | B: `cl_voice 1` | A>B | heard |
| C5 | CP | A: `disconnect`, then `connect` | A>B | heard |
| C6a | CP | server: `map cp_rave` | A>B | heard |
| C6b | CP | after the map change | B>A | heard |
| M0 | MP war | fixture: `teams same` (idle control) | A>B and B>A | silent |
| M1a / M1b | MP war | same team, both alive | A>B / B>A | heard |
| M2a / M2b | MP war | fixture: `teams opposite`, both alive | A>B / B>A | silent |
| M3 (optional) | MP war | fixture: `endgame` (retail `forceend`) | A>B | heard |
| M4a / M4b | MP dm | `g_gametype dm` and `map`, or the post-M3 rotation | A>B / B>A | heard |

Every silent case has a heard case under the same setup: C3b and C4b undo C3a and
C4a, and M1 precedes M2. A silence therefore never stands alone.

## Pass criteria

Each window's verdict comes from `analyze_voice.py`:

* **heard: PASS.** All of the following hold:
  * `play_start` and `play_end` were seen on the talker;
  * the listener decoded audio from the talker;
  * speech-band energy (300-3400 Hz, 20 ms frames, threshold 25 dB below the source
    phrase's loud frames, never below -50 dBFS) covers at least 60 % of the source
    phrase's speech;
  * faster-whisper (CPU, int8, English, no prompt) recognizes at least 75 % of the
    phrase's words. Case, punctuation and a singular/plural difference do not count
    against it.

  The envelope cross-correlation is reported. It decides the verdict only with
  `--require-xcorr`. It separates the right phrase from a wrong one, but too weakly
  to stand alone. Without ASR the verdict is INCONCLUSIVE, never PASS.
* **silent: PASS.** The listener has zero decoded samples from that talker, no
  `recv` event for it, and an unchanged snapshot `recv` counter. The window is valid
  only if the talker's injection was confirmed and the talker encoded frames (an
  `encoded` event or a rise in the snapshot's `encoded` counter). Otherwise the
  silence proves nothing and the verdict is INCONCLUSIVE. If samples leaked, ASR
  reports any phrase words in them.
* **Idle controls** (C0, M0) need zero decoded samples in both directions. They show
  that heard audio in other windows comes from the injection and not from a live
  microphone.
* **Run verdict.** PASS only if every window passed and the run completed. Any FAIL
  makes the run FAIL. Otherwise the run is INCONCLUSIVE. Stage-1 PASS means the
  production pipeline delivered decoded speech to the right players and to no
  others. It does not prove audible playback on speakers (stage 2) and is not owner
  acceptance.

## Evidence layout

`runtime\voice-certify\<UTC stamp>-<id>\` (ignored by Git):

```
build.json            lab image hash and build manifest, candidate HEAD, diff hash,
                      voice.cpp hash, harness file hashes, options
processes.json        every process: role, PID, image, creation time, SHA-256,
                      redacted arguments, desktop, how it stopped
configs\<mode>-server.cfg   server cfg with the password redacted
commands.log          every command written to any commands.txt, timestamped
phrases\P01.wav ... phrases.json   SAPI phrases at the native rate, with hashes
cp\server\  cp\A\  cp\B\  mp\...   per process: commands.txt, events.jsonl,
                      stdout.log, stderr.log; clients also recv_<talker>.wav
checks.json           getinfo answers and identity key hashes per mode
windows.json          every window: client numbers, byte range, event counts, heartbeat
analysis-input.json   analysis.json   verdict.md   (final verdict table)
backups\Server|A|B\   restore transactions (local only)
failure.json          only when the run failed
result.json           Verdict, failure, cleanup error, Restored, OwnerAcceptance=false
```

## Event contract consumed by the orchestrator

The orchestrator reads `events.jsonl` (one JSON object per line, with `t` and
`event`). It tolerates the aliases in `VoiceCertify.Core.ps1`
(`$VcEventNames`, `$VcFieldNames`), and the test component must provide at least:

| Event | Fields used | Use |
| --- | --- | --- |
| startup event: `start`, `ready`, `init` or `voicetest_start` | `rate` (or `sampleRate`, `nativeRate`, `captureRate`) | Phrase synthesis rate |
| client `snapshot` | `client_num` (or `clientNum`), cumulative `encoded`, `recv` (`{"<talker>": samples}`) | Role-to-client mapping. Before and after each window it gives the talker's encoded-frame delta and the listener's decoded-sample delta. The whole object is kept as evidence. |
| `play_start`, `play_end` | none | Injection confirmed |
| `encoded` | none (the count is reported) | Talker capture proven (validity of silent windows) |
| `recv` | `talker` | Listener-side cross-check of the WAV byte count |
| `error`, `play_error` | any | Stops the run immediately |

The orchestrator also sends `voicetest_snapshot` to the dedicated at each window. The
engine-side `team` and `session_state` per client stay in `server\events.jsonl`.

`recv_<talker>.wav` must be PCM16 mono, appended continuously, with `<talker>` the
talker's clientNum (its voice session slot). A client snapshot must flush pending
samples before it is written, so the file length read after the snapshot is an exact
window boundary. The analyzer also tolerates a stale header. While no phrase plays,
the component must feed silence instead of the real microphone. Otherwise the idle
controls fail by design.

As of 2026-11-09 the `src/native/voice_test.cpp` draft is written to this contract
(not yet run): `start` carries `rate`; the snapshot carries `client_num`, `encoded`
and `recv`, and flushes the recordings; a virtual microphone feeds silence or the
phrase, and the real device is meant never to reach the pipeline.

## Test component

`Build-Voice.ps1 -VoiceCertify` copies `src/native/voice_test.cpp` into `src/client/component`,
through a receipt that every later build removes by exact hash. Ordinary builds
never contain it, and the standard client build refuses it. Without
`-voicetest <absolute dir>` it does nothing. On start it compares every engine
address it uses with the retail bytes in its table (`check_voice_test_bytes.py`
re-checks the table against the dump offline); on any mismatch it logs `error` and
`start.ok=false` and installs nothing.

Client hooks:

* **Virtual microphone.** The capture device callback (`0x140B79CD0`, a `jmp` to
  `voice_capture_pcm`) is replaced by a counter, so the real microphone never reaches
  the pipeline. Every main frame the component calls `voice_capture_pcm` itself with
  the elapsed time's worth of samples: the phrase while `voicetest_play` runs, silence
  otherwise. Gain, VAD, Speex and the queue are the native ones.
* **Talk gate.** `cl_pushToTalk 0` and a low `winvoice_mic_threshold` (VAD), sent by
  the orchestrator; both are archived dvars, restored with the profile.
* **Encoded counter.** The only call of the encoded-frame queue (`0x140B79F13`) counts
  frames and passes them on.
* **Recorder.** The only call of the playback enqueue inside `Voice_IncomingVoiceData`
  (`0x140D5972A`) records the decoded PCM, attributed to its talker through the
  playback stream table `0x1477A01C0`, into `recv_<talker>.wav`. Samples the playback
  buffer refused are still recorded and counted as `dropped`.

Sessions: the users table, `client_num` and the mute check use the game session
(`0x146B4E080`), which is where `voice.cpp` registers players and reads mutes.
`voicetest_mute` / `voicetest_unmute` pick the session the way the scoreboard does
(front end: none; lobby running: lobby session; party in game: party session; else
the game session) and call the native mute/unmute. Snapshots report all three
session choices (`session`, `voice_session`, `scoreboard_session`), so a mismatch
between where the scoreboard writes mutes and where the relay reads them is visible.

Commands: `voicetest_play <wav>`, `voicetest_stop`, `voicetest_mute <n>`,
`voicetest_unmute <n>`, `voicetest_snapshot`, `voicetest_mark <label>` (client);
`voicetest_snapshot`, `voicetest_mark` (server). Events: `start`, `connection`,
`voice_state`, `command`, `play_start`, `play_end`, `play_error`, `encoded`, `recv`,
`mute`, `mark`, `snapshot`, `error`, `stop`; each line has `t` (Sys_Milliseconds) and
`wall` (UTC ms, for cross-process ordering).

## Who runs it

In-game runs are delegated to Codex (`codex exec`, GPT-6.1 Sol, medium reasoning)
with a self-contained brief; agents never drive the game window. Codex's proven
client method (2026-11-09) launches from the game folder with
`-noupdate -nosteam -wincon -stdout -nointro`, sends console commands on stdin and
connects only once the menu is up (`cpMode;` about 25 s, `connect` about 50 s after
launch); `+connect` on the command line fires too early. The orchestrator sends
`connect` through `commands.txt` only after the client's first snapshot, but its
`-cpMode` launch flag is unproven: the first real run must confirm the client
reaches the expected mode, or switch to `cpMode` through `commands.txt`.

## Known limits

* The GSC fixtures give script-level protection: the player damage callback is
  replaced and zombies are paused. The Build-Voice lab images also contain the
  Paris fixture's `paris_test_protect` (native engine godmode), but it works only in
  Zombies (its private fixture check requires CP) and the harness fixtures do not
  call it yet.
* MP team control simulates nothing on the client. It calls the retail
  `scripts\mp\menus::setteam` on the server, which kills the player and lets the
  retail respawn path run. This is valid only with `scr_skipclasschoice 1`.
* M3 depends on intermission lasting long enough for one phrase. The window
  tolerates the map unloading afterwards.
* The game writes files outside the backed-up directories (for example
  `main\*.dcache` in the base root, screenshots and crash dumps). These are the same
  limits as the earlier base-client transaction.
