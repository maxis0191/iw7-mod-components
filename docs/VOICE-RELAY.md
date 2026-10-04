# Dedicated Zombies voice relay

This experimental IW7-Mod component carries the game's existing encoded voice
through the connected dedicated server. Both the server and participating clients
must enable `-iw7-voice-relay` and use compatible protocol-2 builds. An unchanged
dedicated server does not relay this protocol. No extra port or map script is
required. Human microphone/WAN acceptance is still pending.

## Behavior

The client retains native capture, codec, activation threshold and push-to-talk.
The component replaces the encoded send queue only while joining or playing on
an external Zombies server. The normal queue remains active for unrelated modes
and local games. Incoming frames use the native decoder/playback path, native
voice-enable and mute state, and the engine's playback eligibility checks.

The supported target is the pinned Windows x64 retail ABI. Hook entry bytes are
checked before installation; an unsupported signature disables the component and
prints a diagnostic. This is not compatibility with arbitrary game executables.

## Components and ownership

| File | Responsibility |
| --- | --- |
| `voice_relay.cpp` | Native signatures, accepted game joins, session registration, capture hook, scheduler and playback |
| `voice_inbox.hpp` | Thread-safe, bounded admission from the network callback to the game thread |
| `voice_wire.hpp` | Canonical little-endian serialization and strict packet/frame limits |
| `voice_transport.hpp` | Handshake, leases, recipient capabilities, rate budgets and relay decisions |
| `voice_state.hpp` | Roster generations and per-speaker sequence state |

Network callbacks inspect only a published endpoint allowlist and copy a bounded
packet. They do not parse voice state or access engine objects. The server thread
publishes actual active, game-accepted connections; the client main thread
publishes its current connected host. Decoding and all engine work happen on the
respective scheduler thread. The state lock is taken before the inbox lock; the
network callback never takes the state lock.

The server inbox reserves 32 packets per admitted IPv4:port endpoint. The client
reserves 128 packets for its sole server endpoint. A sender cannot use another
sender's allowance. Drain order is round-robin with arrival order within each
source. Packets older than 500 ms are discarded. Changing or removing an admitted
endpoint clears its pending packets. Shutdown clears admission and queued input.

## Identity and lifecycle

1. The accepted game join assigns a fresh connection incarnation. The server
   derives each user and endpoint from active engine state, never from a claimed
   packet slot or UI metadata.
2. A client sends a random nonce. The server replies with a random challenge and
   server epoch. A matching confirmation creates a listener capability and a
   fresh speaker generation, then returns a complete roster.
3. Audio carries the current server epoch, listener capability and sequence.
   Downstream audio also identifies the server-assigned speaker generation.
   Audio cannot create a roster entry or register an arbitrary native user.
4. Heartbeats refresh the 15-second lease; pending challenges last five seconds.
   Reconnect, slot reuse, server reset and map/session reset invalidate old state.
   Retransmitted controls do not reset a healthy speaker's sequence.
5. Native registration cleanup removes only users owned by this component whose
   current UID still matches. Existing unrelated registrations are preserved.

Every timer is local monotonic time. No synchronized clocks are required. The
capability handshake rejects off-path guesses and stale sessions; it does not
encrypt speech or provide protection against an observer of the game connection.

## Bounds and latency policy

Wire payloads are at most 1200 bytes, with at most ten frames of 1–254 bytes.
Uplinks reserve the 17 bytes added by relay metadata, so every accepted batch fits
downstream. Per-peer frame, byte and control budgets limit sustained work and
bounded bursts. Idle replenishment saturates before multiplication, including
very long uptimes, without overflow.

The transport discards duplicate and backward sequence numbers. It does not
retransmit audio or implement a jitter buffer or packet-loss concealment. This
keeps stale audio from accumulating, but severe reordering can discard many usable
frames. Measured transport continuity is not an intelligibility measurement;
native audio under network impairment remains a release gate. A future jitter
buffer needs its own latency, replay, lifecycle and native-audio validation.

## Build and verify

Use the repository's existing Windows x64 native build. The five generic source
files above and `voice_relay.hpp` are the focused feature; private diagnostics,
test protection, server configuration and game assets are not feature dependencies.

The engine-independent tests can also be built directly with a C++17 compiler:

```powershell
cl /std:c++17 /EHsc /W4 /WX tests/native/voice_transport_test.cpp
cl /std:c++17 /EHsc /W4 /WX tests/native/voice_inbox_test.cpp
cl /std:c++17 /EHsc /W4 /WX tests/native/voice_wan_test.cpp
```

Run the resulting executables; repeat with optimized AddressSanitizer. The full
suite additionally tests state, malformed input, the original network simulation
and metadata concurrency. WAN scenarios use four 50-frame/s speakers, a 10-ms
scheduler, independent boot clocks, loss, jitter, duplicates, reconnect, slot
reuse, restart and an 18-second outage. Twelve directions are checked separately.
Recovery deadlines, stable-interval delivery, delay and gaps are separate metrics.
The severe-impairment delivery floor checks liveness, not acceptable speech quality.

`voice_relay_status` prints aggregate readiness/relay/registration counters without
player identifiers. For release acceptance, use actual microphones on separate
machines; verify both directions, PTT release, voice toggle, mute/unmute,
reconnection and map change, plus the supported-mode and device regression matrix.
