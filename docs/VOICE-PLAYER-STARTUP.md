# Player startup and ordinary audio-path witness - 2026-10-05

Current instance policy (2026-10-06): use the base game client for ordinary
in-game and sequential A/B tests; stage server changes on a separate test dedicated.
Client clones require a concrete necessity or risk. [Instance workflow](INSTANCE-WORKFLOW.md)
supersedes older systematic client-copy requirements and launch recipes below.
Dated test results remain historical evidence.

The earlier live failure had two game players but only one negotiated voice
participant. The remote cause remains unknown; the owner requests useful local
work beyond waiting for another machine's status. This change removes reproduced
launch ambiguities and makes the remaining readiness gates observable.

## Corrected launch paths

The repository's canonical batch previously lacked `-iw7-voice-relay`, although
the generic ZIP added it during packaging. Using that batch with the current
server selected the historical protocol-1 component. It now contains the same
protocol-2 command as the player package. Packaging selects generic v2 by default;
an explicit `-GenericRelay:$false` retains the historical diagnostic package.

A plain double-click on the specifically named `iw7-paris-voice.exe` now applies
`noupdate`, `nosteam`, `cpMode` and `iw7-voice-relay` before component startup.
The pinned flag parser calls the tested shared policy using the actual module
filename and argument count. Case/path handling is tested. Any explicit argument
list, the ordinary `iw7-mod.exe` and the isolated executable preserve their old
profiles. This is a private packaged-player convenience, not a default change
for all Aurora clients. A custom shortcut with arguments still needs its flags.
The build/package bind the modified flag parser by SHA-256 and include its actual
source with the corresponding source archive.

`voice_relay_status` is now registered even when the relay option is absent. The
client reports a disabled option, unsupported signatures, wrong mode, local game,
missing server, loading, absent session/local identity/slot, slot mismatch,
negotiation or readiness. Packet/hello/confirm counts distinguish a missing
attempt from a missing response. The dedicated reports `server_running`,
`eligible_mask` and `voice_peers_mask`; its historical client-only ready field
remains for compatibility. No user identifiers, endpoint addresses or audio
content are added to these diagnostics.

These changes do not force microphone/PTT settings or replace the voice codec,
packet protocol, mute/privacy checks or relay authorization. A startup mismatch
can explain silence; this does not prove it was the other player's actual cause.

## Independent engine witness

`Isolated-Lab -Action Install -TestProfile VoiceNative -VoiceMode Player` selects
the generic relay without private capture/decode/codec tracing hooks. Native
retains the older engine investigation; Relay explicitly combines v2 with the
protected synthetic harness. Synthetic VoiceProbe is refused in Player mode.
Mode selection is saved for both server and clients and covered by operations
tests. The independent stock snapshot, AppData/keys/bank, loopback ports
27416/27417/27418 and private Windows desktop preserve the owner's normal server.

The complete two-client Reduced reservation was refused at 31.78% physical /
28.42% committed use. No unreserved peer was launched. The separately reserved
one-client plan successfully connects in Player mode. Lab executable SHA-256:
`B8BB64DA970BB7C6EC268B74F16B3D9E70427D5E8EA8A19DBAC605155BB986E7`.
Seventeen periodic ready samples span approximately 160 seconds; one hello and
one confirm establish the session, received controls increase from 3 to 161,
and rejections remain zero. The server reports eligible/voice masks of 1.
There is one participant, so these masks do not claim peer audio delivery.

Fresh Verify confirms real engine godmode, inactivity=0, cheats=0, zero live /
pending / reserved enemies and the current supervisor. Peak observed physical
and committed use were 48% each. The Player synthetic-probe refusal is verified.
The owned client exits cleanly with code 0; the exact lab dedicated stops after
30 seconds of valid zero-client UDP. Normal UDP27016 remains available.
Existing retail/updater GSC interaction/contract diagnostics are retained in raw
logs; the voice handshake witness does not certify all stock scripts.

No one spoke during this witness: encoded/sent/playback remain zero. This tests
ordinary-path initialization, handshake and protected idle, not microphone
intelligibility or two-PC output. Bare-launch policy tests are separate from this
engine launch, which uses explicit laboratory arguments. Issue #4 stays open.
The next human test uses the same current ZIP on both machines, verifies both
participants in the voice roster, then checks speech, PTT, mute and reconnect.

## Distributable and deployment boundary

Final normal Release SHA-256:
`AD167072C11765AC2C4684CAFCCA94810004604475691A002563F97AC5502BCA`.
The manifest records IsolatedLab=false, VoiceTrace=false, ExperimentalAssets=false
and the server-only module profile. Native checked-runtime and AddressSanitizer
suites pass, including launch policy, protocol/state/transport, simulated WAN,
ingress bounds/concurrency and metadata lifetime. The modified flag-parser hash
is `A7E5AEBCE575E24F610A3640DFC8B80ED2D82EB5683D27A68D34B44D77154ACD`.

The four-file player archive contains the executable, one v2 batch launcher,
quick instructions and upstream license. ZIP contents, the single relay switch,
executable hash and matching source flag-parser/test were independently checked.
Player ZIP SHA-256:
`474199D0058A53F784CF7F67B8D4F9B4E3CDF38D53CE8B44E6AA2DA4495C5E1A`.
Corresponding source ZIP SHA-256:
`C977CE80DC2FBE8EC0AC5F4389C47C173A913C96E2F90638A56125F88227118F`.
Packaging records code commit `d666b035fd80aa07f5856bb494c01cba1c1caa24`;
the accompanying documentation and ASan-runner inclusion are committed separately.
A resource-snapshot CIM timeout initially refused archive admission; a normal
retry acquired the required lease and succeeded without changing the gate.

The owner client had already closed before the isolated witness. The original
normal dedicated remained running throughout. It gained one remote game player
before deployment, so it still runs 63888751 at this checkpoint. No player is
removed to install the correction; deployment waits for valid empty-server
admission and preserves the existing GSC/config/bank profile.

Later the owner confirmed the server empty. The ordinary 30-second UDP/identity
guard passed and AD167072 was deployed with the local player launcher/manifest.
All 24 startup markers and active v2 readiness pass; 54 pre-existing files,
including 36 backed-up bank files, retain their hashes. The preserved-profile
checker first demanded undeployed optional Max Ammo; its inventory correction
passes without another restart. [Deployment record](deployments/2026-10-05-voice-player-startup.json).
This supersedes the pending-installation checkpoint, not the pending speech gate.

An independent external option is [Mumble](https://www.mumble.info/downloads/),
which supplies Windows client/server voice separately from IW7. It requires an
additional client for each player and an accessible voice server; it does not
repair IW7's native voice. No Mumble service, port or firewall rule was installed.
