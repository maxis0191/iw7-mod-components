> History (dated 2026-10-16). Not current instructions. Current entry point: [docs/INDEX.md](../INDEX.md). Paths in the text are relative to the repository root as it was on that date.

# DIA Source model and provider qualification plan

Status: **Source only; NativeEligibility=false; Provider=Unknown_Unqualified;
DbgHelpPdbUnmatched=NotApplicable; H3Outcome=Refused.** This lot neither opens an
image/PDB nor inventories or activates a provider. H4 remains stopped. Nothing
here authorizes a native capsule, game run or another route through stopped T7
work. The prior [H3 observation](../DEBUGGER.md) remains unchanged.

## Managed core contract

`ops/diagnostics/ImmutableSnapshotCursor.cs` is an authored managed model, not an
IStream/COM ABI implementation. It has no interface registration, provider
binding, native call, filesystem operation or real input guard. `CopyOf` makes
one private copy of a caller-supplied byte array after checking its input cap.
The caller must stabilize that array during copying; this is not an atomic file
snapshot or a hash/identity check. No mutable input alias or result buffer is
returned: read results provide scalar byte access only. Clones share private
immutable bytes and the managed owner, with independent logical positions.

Every instance requires finite input, per-request read, cumulative copied-byte,
operation-call and lifetime clone-creation limits. All descendants share the
last three budgets; disposing a clone never replenishes them. Read/Seek/Clone
consume one call once admitted, including invalid seeks, zero/EOF reads and
per-read/byte/clone-limit refusals. Closed or call-exhausted cursors cannot admit
another operation. Refused admission has a named reason, null HRESULT, zero
count and unchanged cursor: it is not a simulated provider/COM error or EOF.
Read limits bound the **requested** count, before allocating any payload.
The cumulative byte budget charges only bytes actually copied, including
rereads through any clone. Model observations and scalar result inspection are
not stream operations; their caller-side use is not a global memory/work cap.

For admitted operations within the applicable envelope:

| Operation | Source outcome |
| --- | --- |
| Read(0) | S_OK, count 0, position unchanged, including empty/at/beyond EOF. |
| Read(cb>0) | Copy at most the available bytes; exact count and cursor advance. S_OK only for the complete request; S_FALSE only for a short EOF. No zero-fill. |
| Seek SET | Interpret all 64 offset bits as unsigned, including the high bit. |
| Seek CUR/END | Apply signed displacement with checked unsigned-result arithmetic, including long.MinValue. Invalid origin, negative result or overflow returns STG_E_INVALIDFUNCTION with unchanged position. |
| Beyond EOF | Seek may place a logical cursor there. Seek/zero/EOF reads neither access snapshot bytes nor allocate a payload proportional to that position. Positive read returns S_FALSE/0. |
| Clone | S_OK with a distinct cursor initially at the same position. No input reopen/copy; no budget reset. |

These numeric HRESULT outcomes preserve the proposed Read/Seek semantics; they
do not establish ABI compatibility. Unexpected managed allocation/copy failures
propagate as exceptions, never S_FALSE/success; the admitted call remains
charged, while cursor/byte/clone counters commit only after preparing the
outcome. The model does not inject or qualify physical I/O failures. Per-owner
locking serializes these model operations; it does not qualify a provider's
apartment or callback threading. `Dispose` is idempotent and budget-exempt so
cleanup remains available after exhaustion. The last managed cursor drops the
private backing reference once; no claim of physical memory erasure is made.

The pure managed test runner compiles only the core and authored test source
in memory. It covers input/result isolation, full/short/zero/empty EOF reads,
64-bit seek boundaries, invalid-operation immobility, beyond-EOF payload
accounting, independent clones, shared finite budgets, and a fake owner that
performs a late read after the original cursor closes. This proves only the
managed retention model. **Real raw guards, COM reference quiescence, provider
lazy I/O and actual child closure remain unqualified.**

## Complete method profile still required

The source model exposes Read/Seek/Clone and model Dispose/observations only.
It does not implement IUnknown, ISequentialStream or IStream. Every ABI method
below must receive an exact reviewed binding/ownership/error contract before
any adapter/provider compatibility claim. Absence is a gate, never silent
success.

| Future ABI surface | Unresolved gate |
| --- | --- |
| QueryInterface / AddRef / Release | Official identities, ABI, alias/reference ownership, callback threading and release accounting; model Dispose is not Release. |
| Read / Seek / Clone | Exact HRESULT/count/64-bit signatures, pointer validation and model-envelope refusal mapping. The core does not supply a binding. |
| Write / SetSize | Explicit failure-only read-only behavior; no mutation. |
| CopyTo / Commit / Revert | Exact unsupported-method failures or reviewed implementation; provider requirements unknown. |
| LockRegion / UnlockRegion | Exact unsupported-method behavior and provider requirements unknown. |
| Stat | Fixed length and read-only metadata, NONAME, default-name/allocator ownership and full STATSTG layout; no disk path exposure. The model's Length property is not Stat. |

The [official IStream profile](https://learn.microsoft.com/en-us/windows/win32/api/objidl/nn-objidl-istream),
[Read](https://learn.microsoft.com/en-us/windows/win32/api/objidl/nf-objidl-isequentialstream-read),
[Seek](https://learn.microsoft.com/en-us/windows/win32/api/objidl/nf-objidl-istream-seek)
and [Clone](https://learn.microsoft.com/en-us/windows/win32/api/objidl/nf-objidl-istream-clone)
are the primary semantics references. Partial Source coverage does not imply
that a DIA provider accepts this method subset.

## Future provider qualification proposal (no discovery authorized)

The separately authored [Source-guard root candidate](SOURCE-GUARD-ROOT-CANDIDATE.md)
derives a bounded candidate from supplied immutable observations only. It has
no native binding or authority/eligibility effect; all provider gates below remain.

Each item currently has status **Unknown_Unqualified**. First submit a bounded
metadata proposal identifying exact intended inputs/actions for review. Do not
inventory folders/registry, activate anything, install an SDK, or select a
registered fallback under this plan.

| Evidence to propose | Qualification still owed |
| --- | --- |
| Exact provider | Intended file/version, trusted provenance and separately admitted identity/hash evidence; presence is not assumed. |
| Architecture | x64 host/provider compatibility and documented target-machine enum domains; never equate different domains by numeric coincidence. |
| Interfaces | Official matching DIA header/interface provenance and exact identifiers, signatures, HRESULT availability and string ownership. No guessed vtables. |
| Activation | One explicit reviewed activation route and dependency/auxiliary-I/O scope; no fallback registration search/change. An anonymous ingress does not confine provider I/O. |
| Apartment | Explicit initialization, callback threading, ownership and teardown plan for that provider/host; no presumed apartment behavior. |
| Full adapter | Review every method above, finite calls/read/log/output limits and failure mapping before compatibility tests. |
| Lifecycle | Retain the exact future raw guard, immutable snapshot, adapters and aliases through load/openSession/all lazy queries, known child closure and input reverification; unknown retains the original actual owner/context/clock/lease. No reconstructed ownership. |

[loadDataFromIStream](https://learn.microsoft.com/en-us/visualstudio/debugger/debug-interface-access/idiadatasource-loaddatafromistream?view=visualstudio)
S_OK prepares the source; it does not establish complete consumption, PE/PDB
identity or zero auxiliary I/O. A future diagnostic must keep separate outcomes
for provider/ingress, fresh guarded PE-RSDS versus PDB global-scope GUID/age,
nominal symbol candidate, checked function containment, bounded unambiguous
line coverage, and cleanup/actual process closure. Unavailable properties stay
unavailable. A nearest symbol is not containment. No source-file retrieval or
historical PDB fallback is authorized. DbgHelp ABI/runtime layout/crash cause/
callstack/H3 acceptance remain unqualified; PdbUnmatched stays NotApplicable,
never a synthesized zero.

[Release's returned count](https://learn.microsoft.com/en-us/windows/win32/api/unknwn/nf-unknwn-iunknown-release)
is test information, not proof of provider quiescence. Fake retention tests do
not discharge any real lifecycle gate. The next allowed step is Source review
of this plan; metadata actions and every native operation require separate GO.
