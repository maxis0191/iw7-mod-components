> History (dated 2026-10-15, voice paragraph revised 2026-11-09). Not current instructions. Current entry point: [docs/INDEX.md](../INDEX.md). Paths in the text are relative to the repository root as it was on that date.

# Retained work integration - 2026-10-15

The owner requests integration of the retained non-Rhino work. This product owns
native/process/voice infrastructure; gameplay scripts stay in the server product.
Spaceland Rhino is retired. No native binary or client change is implied here.

## Preserved work and canonical behavior

The original scoped gameplay-bot branch is merged without rewriting its history.
It remains gated to protected private lab use. The full current resource policy
stays TelemetryOnly, with the shared lock, exact ownership and checked teardown.

The formerly unpublished strict startup owner and suspended-tool registration
are now canonical source. The synthetic admission suite passes 64 controls and
the C# owner declarations compile. Until 2026-11-09 the retained recorder
changes were already present: every substantive added line from the retained
Recorder-Probe, Recorder.Core and their two changed tests appeared in source, and
the provider had added explicit sender direction and server-handle support.
On 2026-11-09 the old voice bench was retired: `Recorder.Core.ps1`,
`Providers.Core.ps1` and the voice recorder tests remain readable with
`git show 5b3524b:<path>`. Only `Recorder-Probe.cs` stays, because
`ops/Resource-RecorderOwnedProcess.Core.ps1` loads it; do not overwrite it with an
older copy.

The bounded STARTUP writer-provenance component, predicate test, profile/overlay
helpers and source fixture are retained with their tests. They are diagnostic
source, not a proven writer identity or 48-agent result. The helper remains
PlanOnly by default and requires the exact reviewed 77e6d4d lifecycle source.
Build-Voice exposes the retained WordProvenance switch only with ServerModules,
IsolatedLab and Debugger. Ordinary builds remove only known leftover sources
and restore only the exact owned lifecycle bytes; they never enable the probe.
An enabled full diagnostic build/runtime remains unqualified. The fixture is a
byte-pinned copy of the owner's IW7-Mod fork main.cpp at
77e6d4d24e918ee363b3feee3735c3b889dff7d7; preserve its upstream attribution and
the repository's existing upstream license. Profile/copy controls pass 63 cases.

## Speech fixture correction

Retired 2026-11-09 with the old voice bench: `ops/voice-agent/Speech-Cache.Core.ps1`
and `tests/ops/voice_speech_cache_test.ps1` remain readable with
`git show 5b3524b:<path>`. See [VOICE.md](../VOICE.md). The rest of this section
describes them as they were.

The earlier hosted SAPI repeatability failure is real and remains in PR2 history.
Fixed text/token/settings did not establish byte-identical independent synthesis.
The generator now freezes the first original two-stimulus synthesis under an
exact descriptor containing token, text, format, settings, OS and source hashes.
Later calls reuse verified original bytes. Each manifest states whether synthesis
occurred and retains its original timestamp and descriptor. There is no new
claim of independent re-synthesis, microphone capture or receiver playback.

The original strict hash-repeatability assertion is retained. An added production
helper test uses a deliberately changing producer: one descriptor synthesizes
once; another descriptor generates different bytes. Reuse is identical, and
altered audio/text/voice metadata fails closed without silent regeneration.
The actual installed SAPI fixture test and its PCM/audibility/hash/default checks
pass locally. Hosted validation still requires a new executed run; billing
refusal before runner/steps is not a passing CI or a recurrence of the old test.

## Server access crash

The retained standalone invalid-password hook is superseded by the dedicated
last-seen null guard already integrated in the approved upstream pin. The actual
installed Main binary 408ECFAE... logs that guard active on 2026-10-15. Reinstalling
the older standalone hook would duplicate and weaken that corrected path.

Runtime recorder audio, writer identity, extended capacity and owner microphone/
WAN acceptance remain separate from this source integration and its tests.
