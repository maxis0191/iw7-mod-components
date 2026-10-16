# Source-guard root candidate: pure managed data derivation

`ops/diagnostics/SourceGuardRootCandidate.cs` implements one bounded Source
function, `Derive(N, R, before, after)`. It consumes supplied observations,
compares complete Source-file identities and derives a candidate from exact
N-R. No filesystem, native/COM binding, provider, process, registry, owner, guard,
lease, host or launch logic is present. A candidate is immutable data, not an
authority/eligibility token. OperationalRoot remains NotObserved_NotConfigured,
PendingRouteQualified/NativeEligibility=false, Provider=Unknown_Unqualified,
DbgHelpPdbUnmatched=NotApplicable and H3Outcome=Refused.

The caller supplies immutable path strings, declared capacity2048 WCHARs and
the unmodified DWORD return length. The captured buffer must include the reported
terminator; it may omit the unwritten tail. A successful length is1..2047, with
valid UTF16, no embedded NUL and NUL exactly at that end. Oversized/partial
captures, zero return, different capacity and required-size returns refuse.
Nothing beyond the reported terminator is interpreted. All scans/allocations
are bounded before use; there is no retry or capacity growth.

R must be rooted with one backslash and valid nonempty components. Exact dot/
dotdot, trailing dots/spaces, colon/ADS, slash, control, wildcard, tilde aliases
and four explicit slash-lookalikes (U+2044/U+2215/U+FF0F/U+FF3C) refuse. Other
well-formed Unicode component text is preserved without normalization. This is
a narrow lexical profile, not validation of an actual filesystem pathname.
N must strictly contain R as an ordinal suffix. The remaining prefix must be
`\Device\` plus one ASCII letters/digits/underscore/hyphen component, at most256
WCHARs total. This explicit conservative device-name profile refuses other
punctuation; it does not discover or infer a volume number. Candidate root adds
only R's verified leading separator, at most257 WCHARs/514 counted bytes/516
terminated-buffer bytes. Byte counts describe data, not a qualified native ABI.

Each Source identity contains a ulong volume serial and a private copied
16-byte opaque file ID. All128 ID bits and64 volume bits must match. The caller
must stabilize the input ID array while constructing the observation; later
mutation cannot alter it. No ID array escapes. Null identity is unavailable;
known zero data stays distinguishable from unavailable data. Equality alone
does not establish same-handle provenance, freshness, root identity or trust.

This function covers ONE observation pair/pass. It does not acquire S1..S4,
compare an initial candidate against a later candidate, identify an actual
root, configure authority, settle pending work, or qualify locality/atomicity/
auxiliary I/O. Those remain separately reviewed future caller/lifecycle gates.
No metadata budget or native operation is exercised by these Source tests.

Validation uses the authored pure C# core/test via an in-memory Add-Type runner.
The causal tests cover missing/partial/truncated path observations, exact
terminator/UTF16 rules, case-sensitive suffix proof, device/relative grammar,
DWORD length overflow resistance,256/257 and2047/2048 boundaries, full ID/volume
width changes and copied-array isolation. No existing native fixture is run.
