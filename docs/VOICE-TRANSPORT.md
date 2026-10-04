# Generic voice transport core

This is an engine-independent candidate, not the currently deployed v1 runtime
or an accepted IW7-Mod feature. Its headers contain no Paris configuration,
test protection, UI metadata, game assets or engine addresses.

## Responsibilities

`voice_wire.hpp` defines canonical version-2 datagrams. `voice_state.hpp` validates
complete rosters and receives per-generation audio. `voice_transport.hpp` owns
bounded handshake, lease, roster and routing state. The engine adapter must supply
current game-accepted connections, their 64-bit user identities and a fresh opaque
incarnation for every accepted connection, including the same UID/endpoint. It
must authorize source endpoints before calling the core, reset on game teardown,
expire queued work and invoke engine audio/registration on the correct thread.
These adapter obligations are not established by pure tests.

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
confirm, handshake loss and expiry, lease expiry, wire bounds and 200000 seeded
mutations. Failures are nonzero exits. Test users/IDs are synthetic constants.

Current local checks pass. Native lifecycle/registration, real microphones,
four-player soak, mute/privacy/devices, map transitions, MP/SP compatibility and
LAN/WAN remain separate gates in [VOICE-CONTRIBUTION.md](VOICE-CONTRIBUTION.md).
