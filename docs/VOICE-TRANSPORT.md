# Generic voice transport core

## Transactional uplink quotas - 2026-10-19

The server previously debited its frame budget before checking the byte budget.
A canonical audio packet refused by the byte limit could therefore spend tokens
reserved for later fresh speech. Sequence admission alone was provisional; the
two quotas were not one transaction.

Uplink admission now stages the existing sequence window and both budgets, then
commits all three and the last-seen time only after every check passes. Frame,
byte and control limits, refill rates, wire format, handshake and client behavior
are unchanged. This does not exempt accepted traffic from either quota or turn
the transport into a raw-UDP flood defense.

The existing public-API fixture adds a byte-saturated sender and an identical
control, repeated byte refusals, then a smaller canonical packet using the still
uncommitted sequence. Its bounded clock advance refills enough bytes but less
than one frame token. It also checks listener delivery, committed replay refusal,
normal refill and backward-time refusal without private state getters.

This revision is Source-only pending separately authorized before/after compilation
and fixture execution. Earlier test results below do not qualify the new case.
No microphone, game, LAN/WAN, playback quality or CPU improvement is claimed.

## Delayed duplicate quota correction - 2026-10-13

The server and listener previously charged their frame budgets before rejecting
an old or duplicated audio sequence. A delayed copy arriving just before the next
fresh packet could therefore consume its token and drop new speech. The focused
regression reproduces the server failure on native-product baseline `20d33d6d`,
then the listener failure with only the server correction applied. The initial
test with immediate copies after fresh frames passed the baseline; that ordering
does not demonstrate this loss and its local source/logs are retained separately.

Both paths now validate the sequence on provisional receive state before charging
audio budgets, and publish the sequence only after quota admission. The version-2
wire format, session/generation checks, frame/byte limits and bounded callback
inbox are unchanged. This exempts rejected replays from fresh-speech quotas; it
does not make the transport a raw-UDP flood defense.

MSVC warnings-as-errors/runtime checks and optimized AddressSanitizer pass:
400 fresh frames at 50 frames/sec with a delayed duplicate before each next frame,
in each direction, plus rejection above the 100-frame burst limit. The existing
300-second four-speaker simulation and twelve deterministic WAN cases also pass.
These are pure transport tests with synthetic frames. No game, physical microphone,
final playback, real WAN or owner acceptance is established by this correction.

## Latest native limits

The [current bounded checkpoint](deployments/2026-10-04-voice-bounded-native.json)
records five-map protected idle/bidirectional output, fourteen native controls and
a five-minute two-speaker run measured separately on each receiver. Private codec
controls restore flags, selected mode and pending quality cache; production stays
native. Same/different-user lifecycle and clean exits are separate result fields.
The historical heap write, actual devices/privacy/UI, compatibility, native
four-player audio and real LAN/WAN speech remain open. Earlier paragraphs below
preserve failed experiments and superseded next steps.

Local static playback and negative mute/voice-off/PTT controls pass. Resumed target
tone output fails. Retail setup enables native VAD/DTX, so test suppression with
the separate saved/restored private codec control before attributing this to
transport. A reconnected client also exits with heap corruption. That lifecycle
failure remains blocking regardless of synthetic output. No codec override is
part of this generic component; real speech/native lifecycle remain unaccepted.

The reconciled candidate passes A-to-B and A's sender reconnect with B staying.
Reverse steady-tone output after A's receiver restart still fails despite sixty
delivered/decoded frames. Persistent codec state is an unproven hypothesis. A
varied test prelude does not itself resolve the unchanged-tone failure. No
production codec reset/replacement is applied. Speex documents
[codec state/reset controls](https://www.speex.org/docs/manual/speex-manual/node7.html);
their role here remains an inference from local evidence.

The next adapter revision retains accepted connections through map epoch reset,
clears actual disconnects, renews accepted joins and resets a changing local UID.
Native map tests remain pending. Playback-call counters measure entry invocation,
independently from decoder deltas and output. Earlier preparation text below is
retained; current results are in VALIDATION.md/STATE.md.

This is a generic candidate, not an accepted IW7-Mod feature. The three pure
headers contain no Paris configuration,
test protection, UI metadata, game assets or engine addresses.

## Responsibilities

`voice_wire.hpp` defines canonical version-2 datagrams. `voice_state.hpp` validates
complete rosters and receives per-generation audio. `voice_transport.hpp` owns
bounded handshake, lease, roster and routing state. The engine adapter must supply
current game-accepted connections, their 64-bit user identities and a fresh opaque
incarnation for every accepted connection, including the same UID/endpoint. It
must authorize source endpoints before calling the core, reset on game teardown,
expire queued work and invoke engine audio/registration on the correct thread.
These adapter obligations are not established by pure tests. The opt-in
voice_relay.cpp engine adapter is built and has bounded synthetic integration
coverage; the remaining native and human gates are listed above.

## Opt-in engine adapter

`-iw7-voice-relay` selects the generic candidate on both client and dedicated
server; `-voice-relay-diagnostics` enables bounded aggregate status every ten
seconds. No player identity, endpoint, nonce, capability or audio sample is logged.
It is limited to external dedicated CP games, with original behavior forwarded
for MP/SP and local games. Its native queue replacement is mutually exclusive
with the private v1 queue hook. Ordinary builds without the flag retain their
existing path. Matching feature builds are required; negotiation with stock and
mixed-version clients remains unaccepted.

Expected entry signatures are checked before installation. The adapter observes
the specific post-admission native game-state call at 0x140C4F87E, not arbitrary
UI announcements or merely a connection request. It issues a fresh incarnation
after that call, only for a current connected client. The active server roster
requires the actual native slot, endpoint, player GUID and registered server
session UID to agree. Engine teardown rotates the server epoch and clears queued
work. The client also binds its state to the current server challenge, selected
native session and local native slot. Native admission/drop analysis output stays
local; the drop entry in the reference is already detoured and is not a complete
original-function decompilation.

The first native pair fails on B despite both ready handshakes: the one-shot
mirror leaves one native user and all sixty relayed frames are rejected before
decode. The revised adapter reconciles missing current registrations every 250
ms, preserving healthy users and native mute/privacy. Aggregate roster/native
masks and attempt/failure counters make readiness distinguishable from playback
eligibility. The exact initial native refusal/clearing point remains unproven.

Network callbacks parse into an inbox bounded to 128 packets; engine work occurs
on the server/main scheduler. Packets older than 500 ms are discarded. The client
registers remote users from accepted server snapshots, preserves native mute and
calls native privacy/mute checks before Voice_Incoming. It releases only native
registrations it created whose current UID still matches. Existing foreign native
registrations are not replaced; that compatibility path and queued-audio cleanup
still require native tests. No new audio codec, godmode, anti-AFK or UI metadata is
part of this component. The private fixture supplies those testing facilities.

The server issues a fresh epoch on reset. A client sends a fresh 128-bit nonce,
receives a server challenge and confirms it. The server then issues a private
listener capability and a separate public speaker generation. Only a welcome
matching the current nonce/challenge may introduce the listener capability.
Repeated confirmation resends the same welcome without rotating replay state.
A new hello creates only a pending challenge; it cannot replace a live stream.
Expired handshakes restart with a fresh nonce. Controls retry after loss.

Rosters are server-owned snapshots with monotonic revisions. Their native slots,
identities and generations are explicit. A changed slot resets only that speaker's
sequence/rate state; duplicate snapshots do not. An absent member must have zero
identity/generation. Duplicate identities/generations, zero generations, conflicting
revisions and stale snapshots are rejected atomically. Audio cannot add a member,
choose a generation or rewind the roster. Old server/listener/speaker generations
are rejected. Serial arithmetic accepts forward sequence wrap and drops duplicates,
backward frames and ambiguous half-range jumps.

Uplink audio carries the sender's private capability. The server derives the
speaker slot/identity from its current connection, replaces the downstream
recipient capability, includes the public speaker generation and excludes self
echo. The public generation must never be used as the private capability. Neither
source addresses nor user IDs in UI metadata authorize a new game connection.

This UDP protocol does not provide encryption or a platform identity signature.
Opaque capabilities bind transport state to the game-accepted connection and
current endpoint; they are not a claim that the underlying game admission path
cryptographically authenticates users. Validate that path separately before making
security claims or exposing the candidate to untrusted traffic.

## Bounds and recovery

Each datagram is at most 1200 bytes, each encoded frame 1-254 bytes, each audio
datagram at most 10 frames and the roster at most 18 slots. The parser rejects
unknown versions/types, trailing bytes, truncation and noncanonical snapshots,
without publishing partial state. There is no allocation based on an unchecked
wire length. The core checks canonical size again at its typed receive boundary.

Per sender budgets bound controls to a burst of 8/refill 4 per second, frames to
100/refill 60 per second and bytes to 24000/refill 16000 per second. Time must be
monotonic. A five-second challenge expires; a fifteen-second lease requires a new
handshake. Ready clients send one heartbeat per second. Heartbeat snapshots repair
lost roster changes. The receive policy drops reordered audio rather than buffering
late speech; a jitter buffer and measured latency/loss behavior remain open.

The adapter must bound its callback inbox and total send fanout. The core alone
does not prevent a raw-UDP flood, spoofed source-address traffic, simultaneous
engine queue use or stale playback already handed to a native audio buffer.

## Repeatable checks

```powershell
./ops/Build-Voice.ps1 -TestsOnly -Sanitizers
./ops/Test-Sources.ps1
git diff --check
```

MSVC compiles the pure tests with warnings-as-errors and runtime checks, then
optimized AddressSanitizer builds. CI runs the same command. Tests cover both
audio directions, no self echo, delayed/duplicate/reordered frames, a surviving
listener during speaker reconnect, accepted-game incarnation changes, slot reuse,
server reset, stale roster rollback, duplicate confirm, retired hello/guessed
confirm, handshake loss and expiry, lease expiry, sustained delayed duplicates
without loss of fresh speech, fresh-frame burst quotas, wire bounds and 200000 seeded
mutations. Failures are nonzero exits. Test users/IDs are synthetic constants.

A separate deterministic simulation exercises five minutes of four simultaneous
50-frame/s speakers with 10% datagram loss, 0-40-ms jitter, delayed duplicates,
same-UID reconnect, different-UID slot reuse and server restart. Every direction
sustains transport and all clients recover. Its counters are synthetic transport
evidence; it is not native soak or real speech/latency acceptance.

Current pure checks and the Release engine build pass. Local map/control/soak
results do not close historical heap investigation, real microphones,
four-player native voice, privacy/devices, MP/SP/local or mixed-version behavior
and LAN/WAN human conversation. See [VOICE-CONTRIBUTION.md](VOICE-CONTRIBUTION.md).
