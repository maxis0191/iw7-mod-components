# Live two-player voice failure - 2026-10-05

The owner reports that current executables still produce no audible conversation.
The occupied normal server was inspected without stopping either game process,
changing settings, injecting audio, attaching a debugger or restarting the server.

## Observed boundary

- Both local processes run Release SHA-256
  `63888751184B632D56A2CEA94F5B767E7026B5C5F38DCA92AF75038135B5976D`
  with `-iw7-voice-relay`. This local failure is not the earlier stock-shortcut case.
- Fresh challenge-validated UDP reports public `cp_zmb`, two clients, four slots,
  `sv_running=1` and empty `fs_game`.
- The local client's existing console status showed `ready=1`, `slot=0`,
  `encoded=396`, `sent=396`, `playback_calls=0`, `rejected=0`, `muted=0`,
  `roster_mask=1`, `native_mask=1`. A fresh read-only status after its reconnect
  showed 486 encoded/sent frames and the same one-participant roster.
- Server diagnostics show accepted game joins but zero relayed frames and zero
  rejected voice packets. Dedicated `ready=0`/`roster_mask=0` are client-only
  fields in this build; they do not mean the server component is disabled.
- Bounded read-only engine metadata confirms both game slots are active, IPv4,
  registered, and have matching native-session and game identities. No raw user
  IDs, names, endpoint addresses, tokens or audio were retained in this record.
- Matching local PDB symbols locate the server's transport state. Both slots are
  eligible and have accepted-join incarnations. The local slot has a confirmed
  voice handshake. The other slot has no pending/confirmed handshake, no ready
  capability and an untouched control budget at inspection time.

Thus the immediate failure is a missing second voice participant. The local
client reaches the server's voice transport, but the server cannot relay to a
second listener that has not negotiated. Encoding/send counters do not establish
microphone intelligibility. These observations do not identify the remote cause:
missing launch option, incompatible build, client readiness or remote transport
still require the other machine's evidence. Voice handshake does not depend on
holding push-to-talk or enabling the microphone, so those cannot by themselves
explain the absent remote negotiation.

## Next discriminating check

Ask the other participant to run `voice_relay_status` in their game console while
connected and return the complete line. Unknown command requires checking the
actual executable and launch arguments; the player batch includes
`-iw7-voice-relay`. With a recognized command, inspect `installed`, `ready`, `slot`,
`rejected` and roster alongside server state before proposing a code/network fix.
Both clients should list both participants (slots 0/1 give `roster_mask=3`).
Then test real microphone speech in both directions, PTT release and mute.

No closure/restart of the owner's game or occupied server is required for this
next check. A later binary replacement needs an owner-chosen client closure and
the normal 30-second empty-server/identity guard. No firewall/router change,
rebuild, deployment or voice acceptance is justified by this snapshot. Issue #4
remains open. Ignored runtime retains the passive diagnostic scripts and sanitized
metadata snapshot; current executable identity must be rechecked before reuse.

Resource Status initially timed out reading CIM performance counters; a later
sample succeeded with no leases, 59.59% physical and 63.47% commit usage. No heavy
job was launched and no admission refusal was bypassed.
