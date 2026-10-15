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
the C# owner declarations compile. Existing recorder changes are already present:
every substantive added line from the retained Recorder-Probe, Recorder.Core and
their two changed tests appears in current source. The provider has since added
explicit sender direction and server-handle support; keep that newer interface.
The source-bound recorder helper and its cleanup tests already match exactly.
Do not overwrite these implementations with their older copies.

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
