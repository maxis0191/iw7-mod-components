# Voice certification harness

Private tooling for this components repository. It never goes upstream.

Status, 2026-11-11: written and checked offline only (dry runs, PowerShell tests,
analyzer tests, GSC compile check, and a dry run against three real bench roots of
a fake stock). It has **never run against a game process**. Since 2026-11-11 it runs
on three disposable bench roots, never in the owner's game folder. It runs live
only after the owner allows in-game tests. Its results are agent evidence and are
not owner gameplay acceptance.

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
base-client backup and restore transaction (its optional `ExcludeDirectories`
leaves a bench's copied updater data out), `LabProcess.cs` (owned process on a
private desktop), `Invoke-IW7OwnedStop` and `Get-ServerInfo.ps1`. The bench roots
and their checks come from the server repository (`ops/bench/`, docs/BENCH.md).

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

   The two images built on 2026-11-09 are kept in
   `%USERPROFILE%\Documents\IW7-Runtime\voicecert\images\<SHA256>\`: `26656B30...`
   is the base image (`voiceRelay` false, for `-Baseline`) and `E56C655F...` the
   relay image. Both contain the lab fixture's `connect` request (source b659c95).
   Built 2026-11-11 from 0bacdd9 with the drop and disconnect observer (engine loop
   `Get-LabClient.ps1 -BuildSwitch 'ServerModules,IsolatedLab,VoiceCertify[,VoiceRelay]'`):
   `606CB10D...` base (no relay) and `E60A9038...` relay, same folder.
3. **Three bench roots.** The server, client A and client B each run from their
   own bench root (server repository `ops/bench/New-BenchRoot.ps1 -IsolatedLab`,
   docs/BENCH.md): a folder whose big game files are extra names (hard links) of
   the retained test stock `%USERPROFILE%\Documents\IW7-Runtime\private-test-server`,
   with a real copy of the mod's `cdata` in `iw7-mod\lab-appdata\cdata`. The three
   roots must be sibling folders, directly under one folder (`-LeaseScope`, by
   default their common parent). That folder is the reservation scope. Each client
   needs its own root for its own `players2`, `lab-appdata` identity and dcache.
   The server repository's wrapper `ops/voicecert/Invoke-VoiceCertifyBench.ps1`
   makes the three benches, runs the harness and removes them. Never Main, never
   Canada, never the owner's game folder. The harness never creates or deletes stock.

   What the harness writes in a root is always a new file or a real copy:
   `iw7-voicecert.exe` (staged beside the linked `iw7_ship.exe`, which is never
   touched), the server cfg and fixture, and the files the game and the lab fixture
   write. A link guard refuses to write, restore or replace any file that has more
   than one name, before the backup and again before the restore. With `-BenchCore`
   (the server repository's `ops/bench/Bench-Root.Core.ps1`), every root must be a
   valid isolated-lab bench whose port is the harness port for that role, and the
   read-only bench check runs on each root before and after the run. Any problem
   after the run (for example shared data written) is a cleanup error.
4. **The reservation.** The harness takes a shareable Runtime reservation on the
   lease scope (default 8.5 GB physical and 20 GB commit for one dedicated and two
   clients; `-LeasePhysicalGB`, `-LeaseCommitGB`). Other agents' shareable sessions
   may run at the same time. A busy refusal is retried (30 s, doubling to 300 s)
   until `-WaitForSlotSeconds` (default 3600) has passed. Only an iw7 process this
   run does not own whose program lies inside the lease scope stops the run.
5. **Tools.** PowerShell 7, an installed en-US SAPI voice (Microsoft David or Zira),
   and Python 3.12 with numpy (scipy is optional). For ASR, `faster-whisper` must be
   importable and `Systran/faster-whisper-small` must be in
   `%USERPROFILE%\.cache\huggingface`. The analyzer loads models offline only
   (`HF_HUB_OFFLINE=1`, `local_files_only=True`).
   `faster-whisper==1.2.1` is installed in the per-user site-packages (2026-11-09);
   without it every "heard" window ends INCONCLUSIVE, never PASS.
6. **No build at the same time.** The scheduler still refuses a reservation while
   a compiler or extractor runs; that refusal is retried like any busy refusal.

## How to run

Through the server repository's wrapper (it makes and removes the benches):

```powershell
$img = "$env:USERPROFILE\Documents\IW7-Runtime\voicecert\images\26656B3027FAD68CCE158390B39F93D06DDBF3AC30703D41BF66AA8D30E91D26\iw7-mod.exe"
# 1. Plan only: creates nothing, starts nothing.
pwsh -NoProfile -File <server repo>\ops\voicecert\Invoke-VoiceCertifyBench.ps1 -LabImage $img -Baseline -Modes CP -DryRun
# 2. Real benches, harness dry run (no game), benches removed at the end.
pwsh -NoProfile -File <server repo>\ops\voicecert\Invoke-VoiceCertifyBench.ps1 -LabImage $img -Baseline -Modes CP -DryRunWithBenches
# 3. The real run (a game runs): the same without the dry-run switch.
pwsh -NoProfile -File <server repo>\ops\voicecert\Invoke-VoiceCertifyBench.ps1 -LabImage $img -Baseline -Modes CP
```

The wrapper's other parameters: `-ComponentsRoot`, `-StockRoot`, `-BenchParent`
(default `%USERPROFILE%\Documents\IW7-Runtime\bench`), `-UpdaterData`, `-OutputRoot`,
the three ports and `-KeepBenches`. Anything after them goes to the harness, for
example `-IncludeEndOfGame` or `-WaitForSlotSeconds 7200`. Exit: 0 PASS (dry run:
preflight ok), 1 the run ended without PASS, 2 a cleanup is pending, 3 preparation
failed or the harness refused.

The harness alone, on roots you made yourself:

```powershell
pwsh -NoProfile -File ops\voice-certify\Invoke-VoiceCertify.ps1 -DryRun `
  -ServerRoot <scope>\server -ClientARoot <scope>\a -ClientBRoot <scope>\b `
  -BenchCore <server repo>\ops\bench\Bench-Root.Core.ps1 -LabImage $img -Baseline -Modes CP
```

| Parameter | Default | Meaning |
| --- | --- | --- |
| `-ServerRoot`, `-ClientARoot`, `-ClientBRoot` | required | Three sibling roots, none inside another |
| `-LeaseScope` | their common parent | The folder that holds the three roots; the reservation scope |
| `-BenchCore` | none | `Bench-Root.Core.ps1`: every root must be a valid isolated-lab bench; bench checks before and after; the copied `cdata` is left out of the backup |
| `-JoinTimeoutSeconds` | 120 | A client not in game this long after its launch is stopped and launched again |
| `-JoinRetries` | 2 | How many times a stalled client is launched again |
| `-WaitForSlotSeconds` | 3600 | How long busy reservation refusals are retried |
| `-LeasePhysicalGB`, `-LeaseCommitGB` | 8.5, 20 | Declared memory of the session: the measured working sets (client about 3.7 GB, dedicated about 1.1 GB, server docs/BENCH.md) and private memory; each run records `PeakWorkingSetBytes` and `PeakPrivateBytes` per process |
| `-ReadyLineSeconds` | 40 | Zombies: an answered connect request with no `Ready loopback join` line this long after counts as a stall |
| `-InitOnly` | off | Offline self-test of the run path: preflight, guards, evidence folder and provenance, then stop before the reservation (no game) |
| `-Diagnostics` | off | Adds `-paris-incident-log` to the dedicated and `+set developer 1 +set logfile 1 +set g_consoleLog iw7-mod/logs/console.log` to every process (`+set g_log iw7-mod/logs/games_mp.log` on the server, `+set cl_noprint 0 +set cl_lessprint 0` on the clients). Logs and minidumps are collected either way. |
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
3. It starts the dedicated on a private desktop with `-allow_root_io` and
   `+set sv_lanOnly 1 +set net_ip 127.0.0.1 +set net_port <test port>`. Before any
   client starts, it requires the fixture's `armed` line (the fixture checks
   `sv_lanOnly`, the password, `sv_cheats` and the port from inside the server), a
   heartbeat, and `getinfo` showing `isPrivate=1 clients=0` and the expected map.
4. It starts client A, then client B, with `-paris-server-client-test`, the
   isolated-lab flag and `+set paris_lab_server_port <server port>`. Each gets its
   own `-voicetest` directory and a startup `+set password`. Through `commands.txt`
   the orchestrator sends `voicetest_snapshot` until the component answers, reads
   the native capture rate from the start event, and synthesizes the phrase bank
   once at that rate (SAPI, canonical 44-byte PCM16 mono WAV, 250 ms of silence on
   both ends). It then sends `cl_voice 1` and the capture-gate settings.
5. It joins each client, the way the server repository's network lab does:
   It writes `<pid> <32 hex nonce> connect` (Zombies) or `connect_mp`
   (Multiplayer) to `<client root>\iw7-mod\paris-server-client.request`
   (temporary name, then move) and reads `.response`. The lab fixture switches
   the client to that game mode, waits for its online data, then connects to
   `127.0.0.1:<paris_lab_server_port>` and prints `Ready loopback join`.
   A console `connect` is not used: in MP its errors only open a menu, so a
   failed join leaves no trace (live run mp-relay-1, 2026-11-11: ten console
   connects, no packet in the server's log, the client stayed in state 0).

   The first ask comes 20 s (Zombies) or 25 s (MP) after the launch, then every
   10 s, but never while the client reports a joining state (voice_test's
   `connection` event, states 3 to 8). State 9 does not block: in the first live
   run a client sat at 9 in its own front-end session, clientNum -1. A client not
   in game `-JoinTimeoutSeconds` after its launch is stopped through its owned
   handle and launched again with a fresh evidence folder (`<mode>\<role>-retry<n>`),
   at most `-JoinRetries` times. In Zombies a client whose request was answered but
   whose console shows no `[Paris module client] Ready loopback join to UDP <port>`
   line `-ReadyLineSeconds` (40) later counts as stalled at once: its fixture never
   called connect. A ready line naming another port than the test server stops the
   run. Every attempt, ask and answer is in `joins.json` and `processes.json`. The
   C5 reconnect asks again in the same way but never relaunches.

   A client is in game on OUR server when a fresh snapshot gives its clientNum N,
   the fixture heartbeat lists N, and the dedicated's last
   `Setting client N XUID to X` equals the XUID the client's own session holds at
   slot N (snapshot `users`). Connection state 9 alone proves nothing. A and B must
   have distinct clientNums and distinct `iw7-public*.key` files in their own
   `lab-appdata`.

   The lab fixture flags do not touch voice_test: voice_test is gated only by
   `-voicetest`. The fixture's client side injects input only on
   `paris-agent.request` (never written here) and never dispatches `+talk`; its
   safety probe to the server runs only in Zombies.
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

Before the first phase it takes the reservation, backs up the three roots and
stages `iw7-voicecert.exe` in each. It writes no marker: the benches carry it.

After the last phase, it checks the link guard again, restores the backups of all
three roots and verifies them by hash: the staged `iw7-voicecert.exe`, cfg,
fixture, marker, `players2`, `lab-appdata` (on a bench without the copied
`cdata`, but with the server's `cdata\custom_scripts`), `custom_scripts` and `logs`,
and both clients' dcache. In A and B it also restores the files the lab fixture
writes there (`iw7-mod/paris-agent.*`, `iw7-mod/paris-server-client.*` and the
fixture screenshot), the same list as `ops/Base-Client.Core.ps1`. It then releases
the reservation, runs the bench check on each root again (with `-BenchCore`) and
runs the analyzer. What the game wrote outside the backup (caches, the copied
`cdata`) stays in the bench and goes with `Remove-BenchRoot.ps1 -RunFiles`.

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

Through the wrapper: `<server repo>\runtime\voicecert\<UTC stamp>-<id>\` (ignored
by Git) holds `voicecert-bench.json` (plan, bench results, harness result, exit
code), `bench-create-*.log`, `bench-check-before-*.log`, `bench-check-after-*.log`,
`bench-remove-*.log`, `harness.log`, and the harness evidence in `harness\`.
Called directly, the harness writes `runtime\voice-certify\<UTC stamp>-<id>\` in
this repository (also ignored by Git):

```
build.json            lab image hash and build manifest, candidate HEAD, diff hash,
                      voice.cpp hash, harness file hashes, roots, lease scope,
                      bench core hash, options
processes.json        every process: mode, role, attempt, PID, image, creation time,
                      SHA-256, redacted arguments, desktop, evidence folder, join
                      result, how it stopped
joins.json            every join: launch or reconnect, attempt, channel (request or
                      console), each connect ask with its time and answer, each
                      change of the server's player list (count, slots, XUIDs) and
                      of the client's state, clientNum and own XUID, the port of its
                      'Ready loopback join' line, the UDP ports the client process
                      held, the in-game proof, result (joined, stalled, failed),
                      stdout tail
<mode>\<role>\console-iw7-mod-logs-console.log ...   the root's console log
                      (g_consoleLog, every line, also lines lost from buffered
                      stdout) and games log, copied before the restore; one
                      root's log spans every launch from it so far
<mode>\<role>\minidumps\  <mode>\<role>\diagnostics\   minidumps, incident and
                      freeze reports, if any
configs\<mode>-server.cfg   server cfg with the password redacted
commands.log          every command written to any commands.txt, timestamped
phrases\P01.wav ... phrases.json   SAPI phrases at the native rate, with hashes
cp\server\  cp\A\  cp\B\  mp\...   per process: commands.txt, events.jsonl,
                      stdout.log, stderr.log; clients also recv_<talker>.wav;
                      cp\A-retry1\ ... for a client launched again
checks.json           getinfo answers and identity key hashes per mode, joins,
                      reservation (scope, declared memory, busy waits, released),
                      link guard results, bench checks before and after
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

Drop and disconnect reasons (added 2026-11-11 after live runs 1 and 3, where the
server dropped client A with no reason anywhere):

* **Server `drop`.** `SV_DropClient` (0x140C4FBA0) is a protected thunk whose entry
  iw7-mod already detours (`patches.cpp`; MinHook allows one hook per address), so
  the component hooks its 27 direct call sites instead (24 `call`, 3 tail `jmp`; the checker byte-scans the code for any it misses).
  Each site is installed only if its bytes still match at startup; `drop_hooks`
  lists how many were installed and which were skipped. Every drop then emits
  `drop` {client_num, reason, tell_them, from (return address: which path dropped),
  state, name, guid, address (ip:port)} before the native cleanup.
* **`com_error` (both roles).** The call at 0x140B8D88E inside `Com_Error` formats
  the message (code, format, varargs) into `com_errorMessage`; the component records
  {code, text, connection_state} and calls the formatter unchanged. The server's
  `disconnect` command reaches the client as `Com_Error(2, "EXE_SERVER_DISCONNECTED")`.
* **Client `disconnect`.** When the connection state falls from 3..9 to 0..2, the
  client emits `disconnect` {from_state, to_state, code, reason, error_age_ms} with
  the last `Com_Error`.
* The harness keeps these events in `checks.json` (`ServerNotes`) and names the
  reasons in its "missing from the server" failure. With `-Diagnostics` the
  dedicated also runs `-paris-incident-log` (in every Build-Voice image since
  2026-11-09), whose `client_drop` rows (reason, slot, reliable counters, stack)
  land in `iw7-mod/logs/incidents` and are collected.

Why the client console log stops at `Loading zone cp_zmb`: nothing closes it. The
retail ship build compiled almost all engine prints out; iw7-mod revives only a few
(`logger.cpp`: one `Com_Printf` at 0x140343080 with six callers, four `Sys_Print`
calls) plus its own lines. In game, nothing reaches the console, so there is
nothing to mirror; the events above are the in-game record.

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

Any agent, from files only: the server repository's
`ops/voicecert/Invoke-VoiceCertifyBench.ps1 -ComponentsRoot <this checkout> -LabImage <image>`
makes the benches, runs this harness and removes them. No window is driven. Both modes
join through the lab fixture's request file (`connect` for Zombies, `connect_mp`
for Multiplayer). Images come from the server repository's
`ops/enginelab/Get-LabClient.ps1 -BuildSwitch 'ServerModules,IsolatedLab,VoiceCertify[,VoiceRelay]' -Json`.

## Live results, 11 and 12 Nov 2026

Images built from components `8df627f`: certify base `B69F8FDA…` (no relay) and
certify relay `5ACE010E…` (iw7-mod `fbf1753`, patch `C705EC49`). Private
passworded unadvertised dedicated on loopback, three bench roots, Spaceland
`cp_zmb` (map change to `cp_rave`) and `mp_frontier`. Agent evidence, not
owner acceptance.

| Run | Image | Windows | Result |
|---|---|---|---|
| relay-full-2 | relay | Zombies C0 to C6 | 11 of 11 PASS: both directions heard (word recognition 100% in 6 of the 7 heard windows, 80% in C4b), mute and `cl_voice 0` silent, reconnect and map change heard |
| final-base-1 | base | Zombies C0 to C6 | 11 of 11 silent, the talker encoding throughout |
| mp-relay-5 | relay | Multiplayer M0, M1, M2, M4 | 8 of 8 PASS: same team heard both ways (100%), opposite teams alive silent (the game's own rule), free-for-all heard both ways (100%) |
| mp-base-7 | base | Multiplayer M0, M1, M2, M4 | 8 of 8 silent: 0 samples received while the talker encoded 106 to 132 voice frames in each talk window (mp-base-7; mp-base-5 lost its dedicated to an engine stall loading `ui_boot`, ledger "dedicated stalls loading zone ui_boot") |

M3 (intermission) runs only with `-IncludeEndOfGame`; it was not run.

Measured per run: a Zombies run is about 4 min of game once admitted; peaks
1.11 GB (server) and 3.68 / 3.65 GB (clients) working set, 18.8 GB private in all.

Faults met on the way, each read from the run's own evidence and fixed in the tool:

| Fault | Fix |
|---|---|
| Reservation of a guessed 11 GB waited an hour | measured 8.5 GB / 20 GB; peaks recorded per process |
| Retail Zombies watchdog kicked an idle client | native `paris_test_protect` exception (a GSC replacement of the gametype queue was tried and reverted: Spaceland and Rave carry their own copies) |
| "thunderstorm" scored as 60% of "thunder storm" | neighbouring words written as one count |
| MP console `connect` failed silently | `connect_mp` request action |
| Harness deleted iw7-mod's cdata scripts: MP players kicked (invalid team) | only `iw7-mod\custom_scripts` removed |
| MP idle check and 15 bots | fixture turns both off, `ai=N` in the heartbeat |
| Both MP players on one team forfeited the match | `level.disableforfeit` |
| Retry pauses of 300 s lost the queue place at every ask | asks again every 60 s |
| Admitted session died on a busy admission lock | scheduler on main (components PR 140, which contains 136): registration and release wait for the lock |
Where the console log is: iw7-mod writes every console line to `g_consoleLog`
(default `iw7-mod/logs/console.log`, relative to the process folder, so
`<root>\iw7-mod\logs\console.log` for a bench) and the game log to `g_log`
(`iw7-mod\logs\games_mp.log`) while `logfile` (a bool, default on) is set.
Retail IW7 registers no `developer` dvar (the engine map has no such name), so
`+set developer 1` only creates an unused dvar. `iw7-mod\logs` is a backed-up
folder, so the restore removes the logs; the harness copies them first.
Minidumps go to `<root>\minidumps\iw7mod-crash-*.zip`.

How the server tells clients apart (engine map, 2026-11-11). The client puts a
`qport` in its connect string from its connection state (`[clc + 0x2000C]`,
`sub_1409AAAF0`); IW7 has no `net_qport` dvar. The server keeps it per client at
`client + 0x9E9A4`. Retail matches a known client by base address plus that value
(`SV_ClientMP_DirectConnect` 0x140C4EE0A..0x140C4EE27, and the packet lookup
`sub_140C58AB0`, a Quake `SV_PacketEvent` shape). iw7-mod (network.cpp) turns both
value checks off (`nop` at 0x140C4EE1A, `jmp` at 0x140C58B2B, "ignore dw handle")
and replaces `NET_CompareBaseAdr` and `NET_CompareAdr` with a compare of the IP
and the port. So under iw7-mod a client is its IP and UDP source port only: two
loopback clients can share a qport without effect, and collide only if they send
from the same port. The port is `net_port`; iw7-mod's `init_socket` moves to the
next port (up to +9) when the asked one is busy. `joins.json` now records the
ports each client process really held.

## Known limits

* The retail Zombies watchdog kicks a player who has not moved for 90 s once two are
  present, whatever `g_inactivity` says, also on a private passworded dedicated
  (live run cp-relay-3: `EXE_PLAYERKICKED_INACTIVE` for client A during C4b).
  Three scripts carry their own copy of it and its `add_to_kick_queue`: the
  gametype `scripts\cp\gametypes\zombie`, Spaceland `cp_zmb` and Rave `cp_rave`.
  Replacing the gametype copy alone misses Spaceland (live run final-relay-1: kicked
  again while the replacement counted 0 attempts; reverted). The fixture therefore calls
  `paris_test_protect` on every player every 0.25 s: the lab images' native exception
  refuses the kick itself, whatever script asks for it. `checks.json` keeps the
  refusals the server counted (`KicksBlocked`, from its `[Paris test safety]` line).
  The method exists only in the Build-Voice lab images and works only in Zombies.
* The harness removes only the server's own scripts (`iw7-mod\custom_scripts`).
  iw7-mod's updater scripts in `cdata\custom_scripts` stay, as on any iw7-mod server:
  without `mp\ranked.gsc` the retail `connect_validateplayerteam` kicks every MP
  player 1.5 s after joining (`EXE_PLAYERKICKED_INVALIDTEAM`, live run relay-full-2).
  An MP phase stops at once when the server did not load it.
* Multiplayer on a dedicated is a matchmaking game for the retail scripts, so two more
  things meet an idle test client there (live run final-base-1): `scripts\mp\teams::watchafk`
  kicks a player with no kill or assist who has not moved for 60 s of play
  (`EXE_PLAYERKICKED_INACTIVE`), and iw7-mod's `cdata\custom_scripts\mp\bots.gsc` fills
  every free slot with bots (`bots_enabled` is registered true and read-only; 15 bots took
  the slot client B needed). The MP fixture replaces `checkforafk` (its only copy) and
  `bot_connect_monitor` with no-ops, and prints the AI count as `ai=N`; the harness
  stops the phase as soon as a bot appears.
* Both players on one team leave the other empty, and a matchmaking team game then
  forfeits and restarts the map (`scripts\mp\gamelogic::updategameevents`; live run
  mp-relay-2 lost window M0's reply to the restart). The MP fixture sets `level.disableforfeit`,
  which that check honours.* MP team control simulates nothing on the client. It calls the retail
  `scripts\mp\menus::setteam` on the server, which kills the player and lets the
  retail respawn path run. This is valid only with `scr_skipclasschoice 1`.
* M3 depends on intermission lasting long enough for one phrase. The window
  tolerates the map unloading afterwards.
* The game writes files outside the backed-up directories (screenshots, crash
  dumps, caches). On a bench they stay until `Remove-BenchRoot.ps1 -RunFiles`
  removes the bench; the wrapper does that at the end unless `-KeepBenches`.
