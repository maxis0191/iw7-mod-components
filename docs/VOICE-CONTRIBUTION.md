# IW7-Mod voice contribution: implementation and release gates

Status: investigation in progress. There is no accepted voice feature and no
official pull request. The owner requests a generic, readable contribution with
English documentation, submitted only after complete, varied validation. The
current private server harness is research tooling, not the upstream feature.

## User-visible contract

Two compatible IW7-Mod clients connected to a Zombies dedicated server must be
able to hold an intelligible conversation in both directions using their actual
microphones. Preserve native voice enable/disable, push-to-talk press and release,
microphone activation, scoreboard mute/unmute and applicable privacy eligibility.
Leaving a match must stop match audio. Joining, reconnecting, changing maps and
reusing a player slot must not silence a legitimate speaker, play stale audio or
attribute speech to another player.

The production feature must not require Paris scripts, a server brand, a custom
map, godmode, an inactivity exception or test command-line flags. Test protection
and zombie removal remain separate, explicitly scoped fixtures. Do not include
private server configuration, credentials, identifiers, recordings, game assets or
decompiled game code in the contribution.

## Current evidence and next investigation

The production audit adds MTU/refill regressions, source-isolated ingress and
explicit WAN continuity measurements. [The focused maintainer guide](VOICE-RELAY.md)
documents the generic component, thread ownership and protocol limits. The
normal player profile bypasses the private PCM/codec diagnostics: previous fixed
codec tone results must not be presented as actual microphone/default-codec proof.
Native regression of the hardened candidate and real speech remain required.

The matching protocol-2 player package and normal dedicated profile are now
installed in the base game. [The delivery checkpoint](deployments/2026-10-04-voice-player-beta.json)
records installer boundaries, original-file/bank/client preservation and bounded
normal-profile startup/idle. This enables supervised real two-PC testing through
[the player guide](VOICE-PLAYER.md). It does not satisfy microphone or official
release acceptance. The retained stock access violation also remains uninvestigated
beyond its matching dump and immediate null-write fault.

The generic opt-in v2 adapter and its pure state/wire/transport tests are now
implemented. Latest bounded native results are in
[the sanitized checkpoint](deployments/2026-10-04-voice-bounded-native.json),
[STATE](STATE.md) and [VALIDATION](VALIDATION.md). Two local clients pass five-map
idle/output, fourteen native control expectations and five-minute simultaneous
delivery/output with passive observation of each receiver. Keep the failed
shared-mix measurement and resource-limited four-client run separately. Investigate
the historical heap corrupting write, complete compatibility/device/privacy and
adequate-hardware capacity testing, and establish real human speech before submission.
The implementation is experimental and is not ready for official submission.

### Retained native routing investigation

The following experiments preserve the research that led to the candidate.
Their proposed next steps are historical, not the current execution plan.

[Private harness PR #39](https://github.com/bigmangeekf/iw7-paris-server/pull/39)
merged after its exact head passed source and native-protocol CI. A protected,
same-machine pair remained idle for 140.422 seconds, with cheats=0 and zero alive
enemies, pending spawns or reservations. Each client encoded twenty native frames
with paired PTT. Each selected client voice session registered only itself; native
send, receive and decode stayed zero. This is a failed routing witness, not voice
acceptance. [Exact evidence](deployments/2026-10-04-voice-native-trace.json).

Investigate client remote-user registration and the engine's recipient selection,
direct send and server fallback paths. Compare CP with MP using the same counter
definitions. A minimal native repair is preferable only if valid evidence shows
that it preserves routing and eligibility. Do not select the custom relay simply
because its synthetic codec test passes. Its protocol-v1 speaker reconnect epoch
defect remains open.

The next causal experiment uses `StartClient -RegistrationWitness` in the base
helper. Before `VoiceProbe`, require both owned clients to pass Verify. Call
`WitnessRoster` on A and B to announce each local engine identity through the
existing clientinfo/memberInfoUpdate UI channel, then wait for both metadata
snapshots. The first experiment attempted zero registrations; source and installed
Lua contain no existing clientinfo emitter. The next attempt also exposed a witness
bug: Session_FindRegisteredUser's absent value is 0xFFFFFFFF, as used by the pinned
party adapter, rather than UINT64_MAX. Zero attempts alone did not isolate either
guard. The corrected witness reports metadata/known/invalid/attempted/added counts.
Neither failed witness can test whether registration restores native delivery. The probe
tries the existing Session_RegisterRemotePlayer API for the remote UI identity,
using only the loopback connected-server fallback. Observe registration and native
send/receive deltas. This metadata is not authenticated production roster state:
never include this opt-in witness as the shipping feature or call its success
speech acceptance. It exists only to isolate a native registration prerequisite.

The corrected witness now registers both remote users successfully. Both clients
report two registered voice users, encode twenty frames and batch three times;
native send/receive/decode remain zero. The 129.282-second protected pair passes.
This isolates a further routing/recipient prerequisite, rather than proving a
registration repair sufficient. Inspect native channel, mute and eligibility
return values before choosing a production architecture.

The next pair remains protected for 129.563 seconds and measures local=0,
muted=0, shared_channel=1, eligible=0 in each original recipient filter. Inspect
the native client-info inputs next. [Sanitized evidence](deployments/2026-10-04-voice-registration.json).

The client-info validity/team inputs pass on both clients. The native filter's
remote-address reference is null in the tested UDP-adapter path. The pinned
adapter replaces Demonware packet I/O, skips secure connections and declines
remote XNADDR NAT traversal. Native registration alone cannot restore that
reference. First prove native playback through a bounded server-mediated witness;
compare MP and avoid describing this as a CP-only defect without that control.

## Code and review requirements

The generic engine adapter and wire/state/transport headers do not depend on
Paris GSC scripts, game-folder paths or player accounts. The adapter still targets
the supported retail ABI/signatures and Windows x64; this is portability within
IW7-Mod's supported game, not across arbitrary engines or binaries. The private
beta executable also contains server/diagnostic components. The future official
patch must extract the focused generic feature and its tests/docs rather than
submit this entire private bundle. Distribution through the official updater
belongs to the maintainers after the full validation gate.

- Keep the change focused on voice. Match IW7-Mod's source layout and style;
  separate engine adaptation, pure validation/state and test tooling.
- Give functions and types concrete names, use named engine symbols and document
  required layout assertions. Explain the reason for an engine hook or protocol
  field in a short comment; avoid undocumented offsets and monolithic callbacks.
- Use bounded parsing, queues and state. Validate remote input before touching
  engine memory. Bind speakers to the actual active connection and generation,
  rather than a packet-supplied slot or unverified UI metadata.
- Treat replay, reorder, reconnect, slot reuse, capability/version mismatch and
  stale audio as explicit state transitions. Preserve mute/privacy checks against
  the correct current speaker. Retain original behavior in unrelated game modes.
- Install hooks only for the supported binary and expected entry signatures.
  Unsupported layouts must fail closed with an actionable message.
- Keep engine work on its required scheduler thread. Make lifecycle ownership,
  disconnect cleanup, queue limits and synchronization visible in the code.
- Build Debug and Release with existing warnings-as-errors. Review the complete
  final diff and compare the candidate with the official source revision already
  inspected for this task. Do not refresh upstream repeatedly.

## Validation matrix

Every result must identify the source revision, executable hash, map, participants,
test configuration and evidence type. "Pending", "failed" and "inconclusive" are
distinct outcomes. A disconnected receiver invalidates an audio comparison.

| Form of test | Required scenarios and success criterion | Current status |
| --- | --- | --- |
| Source review | Trace capture through routing and playback; audit input bounds, eligibility, identity and lifecycle; inspect final upstream-sized diff | Native path partly mapped; feature review pending |
| Pure unit tests | Parser boundaries, every message/state transition, duplicates/replay, wraparound, stale speaker generations and slot reuse | Generic state/wire/control lifecycle tests pass locally; final adapter review pending |
| Seeded fuzz and sanitizers | Truncated/oversized/malformed input, arbitrary bytes, bounded allocations and queue saturation; no crash or memory error | Core and new actual ingress-queue tests pass optimized AddressSanitizer, including 150000 outsider packets and 100000 concurrent attempts; native engine memory coverage remains open |
| Transport simulation | Deterministic loss, jitter, duplicate/reordered packets, delayed old handshake/audio and reconnect while a listener survives | Original five-minute test plus nine four-minute WAN profiles pass their stated continuity/recovery bounds. Stable-interval minimum delivery is 100% clean, 91% transatlantic and 42% severe reordering; this is not speech-quality acceptance. Native loss/latency pending |
| Native local integration | Two simultaneous distinct active clients; capture, encoded, send, receive, decode and playback deltas correlated with the injected signal | Both short directions on five maps and 15000 simultaneous frames per receiver pass; actual input device is outside this post-device stimulus |
| Audio measurement | Known signal observed on receiver output with correct timing; muted/disabled/released-PTT controls show absence of that signal | Fourteen expectations and independent full-soak receiver measurements pass; detected-tone gap bound is 3000 ms, not speech latency acceptance; shared-mix failure retained |
| Real LAN conversation | Two physical PCs and two humans, actual microphones and speakers/headsets, intelligible speech both directions, no echo or wrong speaker | Pending |
| Real WAN conversation | Same live conversation across different external connections through the existing dedicated-server arrangement | Pending |
| Controls and devices | PTT release, voice toggle, activation threshold, each direction's mute/unmute, privacy eligibility, input/output device change and unavailable device | Fourteen native expectations pass, including both resume directions. UI/privacy/activation/actual devices pending |
| Lifecycle | A reconnects while B stays; B reconnects; slot reused by a different identity; delayed old frames; map change; server restart; disconnect stops audio | Both same-UID reconnects and different-UID reuse of the same native slot pass protected idle and both output directions; post-disconnect silence, five client exits and map changes pass. Older heap write, delayed native frames and server-restart recovery remain open |
| Capacity and soak | One, two and four participants; simultaneous speakers, prolonged idle/talking, queue bounds, reconnect cycles; record latency, loss and resource use | Two clients pass five-minute delivery/output; peak physical/commit use 58.3%/68.4%. Four local clients fail audio under resource pressure; adequate-hardware native capacity, network latency/loss pending |
| Map coverage | Spaceland, Rave, Shaolin, Attack and Beast, including ordinary joins and map transitions | Protected idle over 130 seconds and both short output directions pass on all five maps; corrected Attack-to-Beast transition passes. Ordinary unprotected gameplay remains owner acceptance |
| Compatibility/regression | Standard client joins/gameplay, mixed feature versions, voice-disabled server, unsupported signatures, MP/SP behavior, normal AFK/kick behavior | Pending |
| Reproducibility | A second clean build/test setup reproduces the same results from the documented revision and commands | Full Debug and fresh source-archive Release builds pass locally; archive source/overlay hashes checked. Independent second-machine runtime reproduction pending |

For every agent integration run, require fresh actual engine godmode,
`g_inactivity=0`, the scoped retail-GSC inactivity exception and `sv_cheats=0`
throughout exposure. Voice tests must have zero alive enemies, pending spawns and
reservations; keep suppliers paused. Require both active clients and at least 120
seconds of idle protection before accepting pair evidence. Follow
[VOICE-NATIVE-TRACE.md](VOICE-NATIVE-TRACE.md) for the current backed-up base helper.
Never terminate an owner's occupied client or interrupt an occupied game.

## Submission gate and maintainer documentation

Do not open an official IW7-Mod PR while any required row is failed, pending or
inconclusive. CI/build/startup, an icon, codec output or same-machine injection
cannot replace the two-machine conversation. Keep
[acceptance issue #4](https://github.com/bigmangeekf/iw7-paris-server/issues/4) open
until owner evidence resolves it. No accepted tag before that checkpoint.

Prepare the generic candidate in our fork first. The future English maintainer
document must explain the reproducible problem, the chosen root cause, the
before/after behavior, architecture and compatibility, how to build, how to run
the tests, observed results and remaining supported-scope limits. The future PR
body must summarize the final implementation and link its exact-head CI and test
evidence. Avoid including the private investigation history or server operations
in the official patch. Keep detailed failed candidates in this private workspace.

Passing the documented matrix establishes the tested revision and supported
scenarios. It must never be described as proof for every future engine build,
device or network. The owner's requested quality gate is enforced through these
explicit checks and real-player evidence, not a claim of universal perfection.
