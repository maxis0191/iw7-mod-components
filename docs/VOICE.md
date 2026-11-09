# Voice chat

## Status - 2026-11-09

- The old private Paris voice relay is retired from this repository (v1
  `paris_voice.cpp`, the v2 `voice_relay.cpp` family, the fake capture, the PCM
  witness, the push-to-talk input bridge, the voice-agent bench and the 36f7afe
  player-client build profile). The old relay never carried speech between real
  players. The server repository retires its own voice tooling in its PR #414
  (branch `codex/voice-cleanup`); the `docs/VOICE-STATUS.md` it adds is the
  server-side record.
- Its replacement is an upstream-shaped component: the local commit
  `fbf17531a4be72a31f1637dba38091c74f49cde0` on branch `feature/voice-chat`,
  based on auroramod `develop` `85ada7c61e2b8722e9d3a704db490b909bb23ccb`. It is
  not pushed anywhere. Its durable copy here is
  `ops/voice-relay/0001-Relay-voice-chat-through-the-server.patch`.
- The new relay builds (Release and Debug, upstream tree). It has **not been
  tested in game**. The owner has not accepted it.
- Main (UDP 27016) and Canada still run native image `0577712C`, which contains
  the old relay. Nothing in this change deploys anything. Their deployment
  pipeline in the server repository is unchanged and still pins this repository
  at `447c1ad`.
- Server issue #4 (voice) stays open.

## Why the old relay never worked

IW7 sends voice peer to peer. Each listener is reached through a Demonware
address handle, and iw7-mod has no Demonware. `CL_ShouldSendVoiceTo`
(`0x14099E210`) therefore rejects every player at its address-reference getter
call (`0x14099E349`), so the stock client never finds anyone to send voice to.

The old Paris relay worked around this with its own wire protocol, a private
client (`iw7-paris-voice.exe`), and for v2 the launch flag `-iw7-voice-relay`
(v1 ran without it, and did not start when it was set unless the native trace
was on):

- v1 (`parisvoice`) and v2 (`iw7voice`) were incompatible, and nothing told a
  player which one the other side spoke.
- Every player needed the private client and a player kit with a firewall rule.
- Multiplayer was never implemented; the code was guarded to Zombies only.
- On Main with real players the server relayed zero frames: on 2026-10-05 both
  local processes ran build `63888751...` with `-iw7-voice-relay`, and the second
  participant never negotiated a voice session. The remote cause was never found.

## New design

The relay keeps the game's own capture and listener rules and only replaces the
transport. It is one client and server component, `src/client/component/voice.cpp`,
plus a few entries in `src/client/game/symbols.hpp` and `structs.hpp`.

- The client hooks the voice flush (`0x14037D5C0`). It computes the listeners with
  the native rules: `CL_ShouldSendVoiceTo` with the loopback test (call
  `0x14099E2DE`) and the address-reference getter (call `0x14099E349`) answered
  by the relay, the scoreboard mute (`CL_IsPlayerMuted`) and `Voice_ShareChannel`.
- It sends the frames to the server as an out-of-band `voice` packet. The server
  forwards them to those listeners as `voiceData`. The client receive call
  (`0x1409B0714`) is hooked so the frames reach the native decoder.
- The server dvar `sv_voice` (default 1) turns relaying on or off. Native
  `+talk`/`-talk`, `cl_voice`, `cl_pushToTalk` and `winvoice_mic_threshold` work as
  in the stock game.
- No launch flag and no protocol negotiation. Both the client and the server need
  the component. It is not limited to Zombies; Multiplayer follows the native
  recipient rules. Neither mode has been tested in game.

Reverse-engineering references: `ops/ghidra/voice-functions.csv` (retail
addresses) and `ops/Invoke-VoiceAnalysis.ps1` (Ghidra decompilation of them).
`ops/voice-certify/verify_engine_addresses.py` checks every address the relay uses
against an unpacked retail dump without starting the game.

## Building the opt-in relay and the certification images

The relay is opt-in until the owner accepts it. Build from prepared inputs
(`bootstrap.ps1`), never from the editing checkout. All three switches need
`-ServerModules` (native pin `cfca45b`).

| Command | Result |
| --- | --- |
| `ops/Build-Voice.ps1 -ServerModules -OwnerCheats` | Main's profile. No relay, no probe. Writes `runtime/voice-package` as before; manifest `VoiceRelay=false`. |
| `ops/Build-Voice.ps1 -ServerModules -VoiceRelay` | Adds the relay. Writes `runtime/voice-relay-images/<SHA256>/`. |
| `ops/Build-Voice.ps1 -ServerModules -IsolatedLab -VoiceCertify` | Lab image with the certification probe and no relay: the "before" image. Writes `runtime/voice-certify-images/<SHA256>/`. |
| `ops/Build-Voice.ps1 -ServerModules -IsolatedLab -VoiceCertify -VoiceRelay` | Lab image with the probe and the relay: the "after" image. Writes `runtime/voice-certify-images/<SHA256>/`. |

An opt-in image never goes to `runtime/voice-package`, which Main, the labs and
other tools read. Its folder holds `iw7-mod.exe`, `iw7-mod.pdb` and
`build-manifest.json`. A certification image also gets `voice-certify-build.json`,
the record `ops/voice-certify/Invoke-VoiceCertify.ps1` checks before a run
(`overlays.voiceRelay` is `false` for the before image). An existing folder is
never overwritten.

How the overlays work (`ops/Voice-RelayOverlay.Core.ps1`):

- The patch is pinned by SHA-256 (`C705EC49...`), together with the LF hashes of
  the two headers before and after, and of `voice.cpp`. It applies only to native
  pin `cfca45b11ee14641945b9a264a95638387f48a4a`.
- It is applied in a fresh temporary repository with `core.autocrlf` off, and the
  results must match the pinned hashes. Native checkouts made with
  `core.autocrlf=true` hold CRLF headers; they are compared after CRLF to LF
  normalisation.
- A receipt in the native root (`voice-relay-overlay.local.json`,
  `voice-certify-overlay.local.json`) records the original bytes before any
  source changes. Every build first restores those exact bytes. A changed file is
  preserved and the build stops. The `structs.hpp` and `symbols.hpp` rows must
  hold the original bytes; the `voice.cpp` and `voice_test.cpp` rows must not.
  Removal skips a file that is already back to its original state (absent, or
  equal to its original hash), so an interrupted apply or removal can finish.
- Without a receipt, a build stops when `voice.cpp` or `voice_test.cpp` exists or
  when `structs.hpp`/`symbols.hpp` differ from the pinned commit.
- The manifest fields `VoiceRelay` and `VoiceCertify` come from the verified
  receipts, not from the switches.
- A rebase of `feature/voice-chat` (for example for the Aurora PR), a new relay
  commit or a ServerModules pin bump changes every pinned constant. Regenerate the
  patch with `git format-patch -1 <commit> --no-signature`, update
  `Get-IW7VoiceRelayPin` and run `tests/ops/voice_relay_overlay_test.ps1
  -ReferenceRepo <iw7-mod clone>`.
- `ops/Build-StandardClient.ps1` has no relay switch. It refuses a `voice_test`
  translation unit, so the lab probe never reaches the players' client.

Certification on these images is evidence for the Paris build (`cfca45b` plus
the Paris overlays). It is not evidence for the upstream PR head; upstream before
and after rows need an upstream build.

## Certification

See [VOICE-CERTIFY.md](VOICE-CERTIFY.md). It needs the owner's permission for
in-game tests; until then only its dry run and offline tests run.

## Production swap checklist

Do none of this before the owner has tested and accepted the new relay in game
(owner rule: approval after testing, then both servers).

1. Owner accepts the relay in game, with relay-enabled clients (the certification
   images, an upstream iw7-mod release that contains it, or a deliberate
   standard-client opt-in; `Build-StandardClient.ps1` has none today).
2. If the relay commit changed, re-record the pin (see above) and rerun the
   overlay test with `-ReferenceRepo`.
3. In this repository, make the relay part of Main's build: a reviewed change so
   that `Build-Voice.ps1 -ServerModules -OwnerCheats` includes the relay and writes
   `runtime/voice-package` (today `-VoiceRelay` writes only
   `runtime/voice-relay-images`). Keep Protocol=1 until the server stops
   requiring it.
4. In the server repository, follow the production swap checklist in its
   `docs/VOICE-STATUS.md` (added by server PR #414). It owns every server step
   (deploy guards, GSC voice module, Main and Canada). For its pin bump: its
   `iw7-mod-components` `files` list names 63 paths that no longer exist here, and
   every `Build-Voice.ps1` and `Build-StandardClient.ps1` run now loads
   `ops/Voice-RelayOverlay.Core.ps1`. Add the patch with `-VoiceRelay` and
   `src/native/voice_test.cpp` with `-VoiceCertify`.
5. Other products pin retired files at older revisions (x64-zt-extensions and
   iw7-creator-sdk list the old voice closure). At their next pin bump they drop
   those entries; a product that runs Build-Voice from prepared inputs also adds
   `ops/Voice-RelayOverlay.Core.ps1`, plus the patch and `src/native/voice_test.cpp`
   when it uses `-VoiceRelay` or `-VoiceCertify`. This repository's own
   `iw7-paris-server` dependency in `product.json` still imports
   `ops/Agent-Pair.Core.ps1`, `ops/Voice-BaseTest.ps1`, `ops/Voice-Pair-Lab.ps1`,
   `ops/fixtures/agent_voice_pair_fixture.gsc` and `tests/fixtures/voice_native.gsc`.
   Nothing here uses them since the old voice tests went. Changing that list needs
   a regenerated `dependencies.zip`, so they are dropped at this repository's next
   server pin bump.
6. The owner updates the voice wording of this repository's AGENTS.md (line 10,
   "voice protocol"); agents do not edit it.

## Lab flags that remain

- `-paris-voice-local-test` (client, with `-paris-isolated-lab`): one loopback
  join to the isolated lab dedicated on UDP 27116. The server's
  `ops/Isolated-Lab.ps1` Baseline and Slasher profiles use it. It now lives in
  `src/native/paris_test_fixture.cpp`. The old 300-second self-quit, the 27016
  path and the voice self-tests are gone. The name is historical. Without
  `-paris-isolated-lab` the flag now does nothing: `ops/RenderDoc-Fixture.py` and
  the server's `Module-ClientProbe.ps1` and `Rhino-ClientProbe.ps1` (retired
  Main-port helpers) pass it without that flag and no longer auto-join.
  `ops/RenderDoc-Fixture.py` is retired with them; its only caller is the
  RenderDoc path of `Rhino-ClientProbe.ps1`, whose launch actions refuse to run.
- `-paris-voice-base-test` (dedicated): enables the fixture's protected map
  requests (`ops/agent-capacity/Watch-Server.ps1`, the server's
  `Test-GameplayDrop.ps1`). The name is historical.
- `-paris-pageheap` with `-paris-isolated-lab`: when Windows PageHeap is active,
  the anti-debug helper in `arxan.cpp` leaves the PageHeap headers alone. Without
  it, full PageHeap stopped a build before game start (2026-10-04, `0xC0000005`).
  The fix was never retested under PageHeap. Only this flag pair enables it; the
  retired `-paris-voice-native-trace` no longer does.
- `agent_scenario.hpp` keeps its `talk` button (native `+talk`). The lab fixture
  rejects it today.

## History of the retired implementation

- 2026-01-06: an Aurora administrator confirmed that iw7-mod has no voice support.
- 2026-10-04: player beta of the v2 relay on Main. The stock dedicated process
  crashed during that work (a heap incident with a null write); the cause was
  never found. A PageHeap trace profile was added for diagnosis.
- 2026-10-05: live diagnosis on Main: zero relayed frames, the second participant
  never negotiated. Launch ambiguities of the private player client were fixed the
  same day.
- 2026-10-11: protected synthetic two-client witness (Run19 A to B, Run20 B to A)
  with fake capture and the push-to-talk bridge. The decoded PCM held all four
  words of the test phrase in both directions. The final mixed output was not
  accepted as intelligible. No human speech and no second PC.
- VB-CABLE was downloaded but never installed; its render helper never ran.
- 2026-10-12: the Multiplayer audit confirmed the relay was Zombies-only.
- 2026-10-19: transactional uplink quotas in the v2 transport.
- 2026-11-01: a fresh player kit was built and packaged; never live-tested.
- Engine facts recorded on the way: IW7 uses Speex with DirectSound capture and
  playback, and the engine reported a playback rate of 8192 Hz.

## Evidence index

Deployment and test records stay in the server repository (never delete them);
its `docs/VOICE-STATUS.md` lists them under "Evidence index".

Retained ignored evidence of the 2026-10-11 witness, as recorded by the
2026-10-12 inventory:

- Run19 (A to B): `C:/Users/ezvalo/.codex/worktrees/voice-e2e/IW7-Paris-Server/runtime/voice-pair/20261011-054037-977-4ae1da46`
- Run20 (B to A): `C:/Users/ezvalo/.codex/worktrees/voice-e2e/IW7-Paris-Server/runtime/voice-pair/20261011-054913-317-08054c08`
- Witness package `iw7-paris-voice.exe` SHA-256
  `A3A2147EDF966313A842134CC046540390BCA646829A1DD729D7799408108287`, in
  `.../voice-e2e/IW7-Paris-Server/runtime/voice-package`.
- Final WAV SHA-256: Run19
  `D15C75C691A63AEA9116EDD2433B23A7371E7CC70856441DC785975A128679E8`, Run20
  `30B44131FE93F06364FFBC188539AA54254DF42D95D5052458A77D85D5BAC2FD`.
- The inventory's own record:
  `C:/Users/ezvalo/.codex/worktrees/voice-resume-inventory/IW7-Paris-Server/runtime/voice-resume-inventory.local.json`.

On 2026-11-09 none of these paths exists any more: the `voice-e2e` and
`voice-resume-inventory` worktree folders hold only an empty
`.codex-worktree-name` marker. The full identities (32
hash links, WAV headers, tool pins) are in the retired inventory document.

The retired documents are in Git history. Read them with
`git show 5b3524b:docs/<name>`: `VOICE-AGENT-PLAN.md`, `VOICE-BASE-RUNBOOK.md`,
`VOICE-CONTRIBUTION.md`, `VOICE-E2E-RECOVERY.md`,
`VOICE-LIVE-DIAGNOSIS-2026-10-05.md`, `VOICE-MP-READINESS.md`,
`VOICE-NATIVE-TRACE.md`, `VOICE-PLAYER-STARTUP.md`, `VOICE-PLAYER.md`,
`VOICE-RELAY.md`, `VOICE-RESUME-INVENTORY.md`,
`VOICE-SPEECH-WITNESS-2026-10-11.md`, `VOICE-TRANSPORT.md`, and the earlier
`VOICE.md`. The retired code is at the same commit.
