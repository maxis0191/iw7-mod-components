> History (dated 2026-10, written 2026-11-09). Not current instructions. Current entry point: [docs/INDEX.md](../INDEX.md).

# Voice: history of the retired relay and its evidence index

Cut from `docs/VOICE.md` as it was at commit `a60b864` (its last two sections), unchanged except that the
three machine paths of the evidence index now start with `<codex worktrees>/` instead of the local user folder.
The current status, design and build of voice are in [VOICE.md](../VOICE.md).

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

- Run19 (A to B): `<codex worktrees>/voice-e2e/IW7-Paris-Server/runtime/voice-pair/20261011-054037-977-4ae1da46`
- Run20 (B to A): `<codex worktrees>/voice-e2e/IW7-Paris-Server/runtime/voice-pair/20261011-054913-317-08054c08`
- Witness package `iw7-paris-voice.exe` SHA-256
  `A3A2147EDF966313A842134CC046540390BCA646829A1DD729D7799408108287`, in
  `.../voice-e2e/IW7-Paris-Server/runtime/voice-package`.
- Final WAV SHA-256: Run19
  `D15C75C691A63AEA9116EDD2433B23A7371E7CC70856441DC785975A128679E8`, Run20
  `30B44131FE93F06364FFBC188539AA54254DF42D95D5052458A77D85D5BAC2FD`.
- The inventory's own record:
  `<codex worktrees>/voice-resume-inventory/IW7-Paris-Server/runtime/voice-resume-inventory.local.json`.

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
