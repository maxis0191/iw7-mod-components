> History (dated 2026-10-06 to 2026-10-26). Not current instructions. Current entry point: [docs/INDEX.md](../INDEX.md).

# Debugger: journal of the Client018 / symbol-provider qualification attempts

Cut from `docs/DEBUGGER.md` as it was at commit `a60b864` (everything between its title and "Entry points"),
unchanged except that relative links were adjusted to this folder. Every result recorded here stays as recorded,
refusals included. The manual of the debugger is [DEBUGGER.md](../DEBUGGER.md).

## Code sections in an owned private live snapshot (2026-10-26)

The guarded private scenario adapter may pass `--snapshot --snapshot-code` to
`ops/iw7_capture.py`. This requests loaded code and initialized data sections in
addition to the default thread/stack snapshot. Packed retail images can differ
from disk: without these sections CDB may show only256 actual instruction bytes
and unusable disk-derived unwind data. The mode retains the original exact
process identity/hash and exclusive new-output guards. It does not request full
process memory, change engine state or capture a crash exception. Acquisition
can perturb timing and the ignored dump may contain private data; never publish
it. A section request alone does not prove that DbgHelp included a desired range;
verify actual minidump memory coverage before attributing code or stack frames.

DbgHelp can still omit read-only vtables/unwind. A guarded scenario can add up
to eight unique `--snapshot-page 0x...` requests, aligned to4096 bytes inside the
pinned IW7 image address window `[0x140000000,0x142000000)`. The retained original
process handle supplies `VirtualQueryEx` mapping/protection provenance and exactly
4096 bytes per fully readable committed page; guard/no-access/partial reads are
refused. Fresh `.dmp.pages/` sidecars contain hashes and a local identity manifest.
This neither authenticates an image section by address alone nor traverses the
heap. Requests require snapshot mode and the caller's same private ownership
gate; no process is written, attached or suspended. Sidecars remain private.

## Client018: refused analysis, confirmed closure (2026-10-15)

The one authorized finite Analysis invocation of frozen source capsule C ended
as `ActualAnalysisRefusedKnownClosed`. It did not qualify a symbol or explain
the earlier client crash. The tool result is exactly:

```text
Status=Refused
Error=Value cannot be null. (Parameter 'path1')
IdentityMatched=false; SymbolFound=false; LineFound=false
CleanupConfirmed=true
DumpStatus=ExactWERPathMissingOrUnavailable; DumpQualified=false
RuntimeAddressLayoutVerified=false; RuntimeFaultSourceAttributionProven=false
CauseProven=false; CallstackReconstructed=false
```

The admitted contract contained a nonempty absolute PDB path. Its presence does
not establish that DbgHelp loaded that PDB. The error report retained only the
message, without an exception type, stage or managed stack. Do not attribute
the failure to a particular Path call, ABI, missing dependency or game function
from that message alone. The nominal requested RVA was `0x5C4AC`, against
compiled source `785ddd43d18c4eebd599bab10880e83d73a950e9` and upstream
`77e6d4d24e918ee363b3feee3735c3b889dff7d7`. Static image identity and a nominal
RVA would still not prove the effective client018 runtime address layout.

The original retained context, state, capsule and NativeJob owner were used
through finalization. Original pre-exit evidence recorded the owner/context
closed, all 25 original SafeFileHandles closed, the original lease null and its
registry token absent, input reverification complete, the clock stopped and
`CanExit=true`. The original terminal then actually completed with exit code 0;
it was never polled again. Independent process and scheduler observations found
the three original process generations absent and no game/compiler/VCTIP or
lease holder. Root independently checked the receipts, terminal completion and
fresh absence at 20:03:01.6118642 UTC before releasing its coordination slot.
Process/cleanup success is separate from the refused analytical result.

These bounded local text receipts remain ignored; their SHA-256 pins identify
the evidence without committing raw logs, tools, images, PDBs or dumps:

| Receipt | Bytes | SHA-256 |
| --- | ---: | --- |
| `tool-result.json` | 1340 | `6123AD0F9C95DF94D7DFCFE651D816460D4F837EE7770B9241A6C7B0A1B6FFB2` |
| `admitted-contract.json` | 1208 | `AB41B3E33990D1DCDA5A68931349797C8F4BE641EB9DCE10C25F1B805F5CE314` |
| `actual-original-preexit-b.local.json` | 1860 | `FD9802191B39379A8160A24A573E31B7C6D825AFD7EDBF6B0EA3B3A7A3359B2D` |
| `actual-independent-closure.local.json` | 1929 | `3D30D8E164A39FC9C4477B8D2A45C6BA77CCAFBCDB5AF082812D82A69747AD30` |
| `actual-closed-review.local.json` | 4450 | `CDE9BA1C67B9D32EEFCE8B7BA41B9DEE62627CA00C18323DD694D6262E62DE6F` |

Capsule C is 11135 bytes, SHA-256
`26CFD497B2A5915A2F0FB6838C295A3F1350D1B84913E2B9AD71E7A6D94BD8B9`.
A/B were not executed; A/B/C and their analytical outputs remain frozen. The
first metadata proof helper failed on an unsupported PowerShell ReadOnlySpan
cast and closed its writer in `finally`; additive helper B used a byte loop.
That correction neither reconstructed the original context nor replayed analysis.

The next step is source-only investigation and a separately reviewed sibling
with bounded stage/exception diagnostics before Path and P/Invoke calls. No
additional image/PDB/DLL/dump access, analysis replay, attach, game launch,
capture, stack reconstruction or game fix is authorized by this checkpoint.
A new exact capsule review and distinct Analysis GO are required for execution.

### D2: diagnostic failure stage observed, analysis still Refused

The separately authorized D2 invocation on 2026-10-15 remains `Refused`.
It records `Stage=Resolve.Native.SymSetOptions`, exception type
`System.ArgumentNullException`, `HResult=-2147467261`, parameter `path1`, and
the same error message as C. Its untruncated managed exception stack contains
`PowerShellAssemblyLoadContext.NativeDllHandler` and
`Path.Combine(path1, path2, path3)` while resolving the first P/Invoke.
`InputPdbNonEmpty=true`, `HelperAssemblyLocationEmpty=true`, and
`LastNativeCallReturned=false` were observed. This localizes this D2 tool failure;
it does not prove why the underlying native library load failed, establish C's
unrecorded failure stage, or explain the earlier client018 crash.

`IdentityMatched`, `SymbolFound`, `LineFound`, dump qualification, actual runtime
layout/source attribution, game cause and reconstructed game stack remain false.
The exact WER path was missing/unavailable. `CleanupConfirmed=true` is the
diagnostic helper's cleanup result, separate from analytical qualification.

The same original context/state/capsule and NativeJob owner reached known
closure: all 25 original SafeFileHandles closed, inputs reverified, original
lease/token absent, clock stopped, `CanExit=true`, and actual original terminal
exit 0. Root independently verified the original terminal completion, receipts,
three original process generations absent and games/compiler/VCTIP/leases empty
at 20:31:09.0526693 UTC before releasing its coordination slot. No original
terminal was repolled, no analysis replayed and no opaque input reread after
release. A metadata helper rejected a duplicated hash character before writing
closure evidence; an additive helper corrected that transcription while the
original proof and analytical outputs stayed unchanged.

| D2 receipt | Bytes | SHA-256 |
| --- | ---: | --- |
| `tool-result.json` | 2556 | `85CB72EF344B8079E871E0AF42995C51B52D8FD7E868A751D79738C45CA39A25` |
| `actual-original-preexit.local.json` | 3050 | `29B90B7AAE46D3C1A304BF0FE0AEA7A1F9D957117BDC2541AC5F8FC69D04996F` |
| `actual-independent-closure.local.json` | 2042 | `EE4FBAEA26F4789CBFC5F601C36F83EB3380180BB7E9D887AF5613B26AD15900` |
| `actual-closed-review.local.json` | 5508 | `64F796CCC11EE81E797186E02D9F0D8B0BB67F09A0FEF63F0A49B749D8D8FD65` |

D2 capsule: 17542 bytes, SHA-256
`E301114FFCCC11FAA7ECE62D0FEBD5972F8947F55A13ABADE90AC8AB1A15625C`.
D was not executed; C/D/D2 and results remain frozen. The next loader correction
is source-only until a new exact capsule review and distinct Analysis GO.

### E: exact native load refused with access denied

The separately authorized E invocation on 2026-10-15 remains `Refused`, at
`Resolve.Loader.LoadExactDbgHelp`. Its `System.DllNotFoundException` has
`HResult=-2146233052` (`0x80131524`); the message reports that the exact pinned
WinDbg-package `dbghelp.dll` **or one of its dependencies** could not load:
`Access is denied. (0x80070005 (E_ACCESSDENIED))`. The exception HResult and the
embedded native load error are distinct. This does not identify the particular
DLL, ACL, AppModel or dependency condition responsible for that refusal.

`LoaderLoadAttempted=true`, `LoaderLoadReturned=false`, and
`LoaderReferenceAcquired=false` were observed. No symbol P/Invoke was attempted.
`LoaderReferenceReleased=true` means no owned reference was returned;
`CleanupConfirmed=true` is separate from analysis success. Identity, symbol,
line, dump, runtime-layout/source attribution and game-cause qualification
remain false; the exact WER path was missing/unavailable. This diagnostic load
refusal does not explain the earlier client018 game crash.

The same original context/state/capsule and NativeJob owner closed, all 25
original SafeFileHandles closed, inputs reverified, original lease/token absent,
clock stopped, `CanExit=true`, and original terminal actually exited 0. Root
independently verified the receipts and terminal completion, original three
process generations absent and games/compiler/VCTIP/leases empty at
20:57:49.0416122 UTC before releasing its slot. No terminal was repolled, no
analysis replayed, no opaque input reread after release and no permission,
alternative DLL/host/ABI or live workaround applied.

| E receipt | Bytes | SHA-256 |
| --- | ---: | --- |
| `tool-result.json` | 2667 | `D4D2C67F125C06A37CB4B335049B9368E27EC740121D4ED95DC9B4D013CC8EC9` |
| `actual-original-preexit.local.json` | 3142 | `1E0938DDE5E2F765F070A91A84CE2FEA2BB30E43E54757E8C99DC5BE5FD1884C` |
| `actual-independent-closure.local.json` | 1985 | `E22AA73733A126D5F0BF3A6CAA9D2DB98282E8457AF22B5073B0871DF09527CC` |
| `actual-closed-review.local.json` | 5234 | `DA31680D2F88D9745722EA0ED69A1F868818053A13C22B03795467D2B64F870F` |

E capsule: 20829 bytes, SHA-256
`7F1E185CCDA8105C7490174F0CADD79D6D0CEABF67AAA7AC2466C0D4C1007F7F`.
E and all predecessors/results remain frozen. Any official tool/configuration
choice is a source proposal first, with new exact review and authorization
before installation, acquisition, native loading or EXE/PDB/dump analysis.

### Q0B: SDK publisher metadata refused by the frozen chain policy

The one separately authorized Q0B metadata qualification on 2026-10-15 UTC
remains `Refused`. Windows returned `Valid` for the embedded Authenticode
signature, with a Microsoft Corporation code-signing signer. The independent
current-time .NET chain returned `Built=false`, `NotTimeValid`; the signing
certificate expired on 2026-05-06. That path ended in Microsoft RCA 2010,
whereas frozen Q0B required RCA 2011 and a successful current-time chain.
`MicrosoftPublisherQualified=false` and
`AssessmentReason=StrictOfflineIdentityChainUnqualified` remain unchanged.
This is not evidence of a forged file or an invalid Windows signature.
The exact authenticated signing timestamp was not exposed and remains unknown.

Microsoft documents [timestamped Authenticode verification after certificate
expiry](https://learn.microsoft.com/en-us/windows/win32/seccrypto/time-stamping-authenticode-signatures),
and publishes both [RCA 2010 and RCA 2011](https://www.microsoft.com/pkiops/docs/repository.htm).
Those facts do not retroactively change Q0B's policy or result. Its version
resource strings are claims, not SDK bundle-content/version qualification.
No setup/help/modify/MSI, SDK/tool/symbol acquisition, debugger DLL load, game,
EXE/PDB/dump analysis or installation occurred. No trust store, policy or ACL
was modified. The earlier game crash cause remains unproven.

The same original context/state/capsule, factory witness, clock and NativeJob
owner reached known closure. All 19 original SafeFileHandles closed; original
inputs were reverified before release; the original lease/token was absent,
the clock stopped at 2342 ms and `CanExit=true`. Before cleanup, both AppDomain
keys matched the same original context/factory witness/clock. After cleanup,
both keys were NULL, with the original aliases retained through actual exit.
The timestamp/signer certificates and independent chain were disposed.

A dot-sourced exit helper returned to the original prompt and was not counted
as exit. After rechecking the full original gate, direct interactive exit
actually completed with code 0. That terminal was never polled again.
Independent metadata at 21:58:30.4786619 UTC found all three original process
generations/PIDs absent, with games/compiler/debuggers and leases empty. Root
verified the original receipts, terminal completion and fresh absence before
releasing its coordination slot. Closure success remains separate from refusal.
There was no qualification replay or cached input access after release.

| Q0B receipt | Bytes | SHA-256 |
| --- | ---: | --- |
| `qualification-result.json` | 5399 | `B44925757381973BE367FB5DDE0AADF899A6EA5EC5AD0A672388F14990D94103` |
| `actual-original-postflight.local.json` | 1996 | `4187194DC9A68D70050B7311555BCFD30C17EBC2715CD087B3A52CC03FA805AE` |
| `actual-independent-closure.local.json` | 4326 | `EDADB1BACED71C637BA64872B6A875850B8FCCE441789D0C2CEB79718C7E9DE5` |
| `actual-closed-review.local.json` | 9468 | `75B9A7DC654FDB8FF33206515D549CEA9B28D2363793C113B9AB91896E91ACCC` |

Q0B capsule: 11114 bytes, SHA-256
`C886AE5EC8D4D14285F5E28CD0BF360E7BF25738C7E793C7E43928F52E3415BA`.
Q0 was never executed; Q0/Q0B and all earlier results remain frozen. The next
action is independent Source review of timestamp-aware Windows publisher
evidence and the official Microsoft authorities, with failed current-time
validation kept explicit. Any new real qualification needs a new exact
capsule review and distinct Analysis GO; installation has a separate gate.

### Q1B: Windows publisher metadata verified, SDK readiness unqualified

The one separately reviewed and authorized Q1B invocation on 2026-10-15 UTC
returned `WindowsAuthenticodePublisherVerified_MetadataOnly`.
Windows returned `Valid` for the embedded signature; the signer had explicit
code-signing EKU and an unambiguous Microsoft Corporation organization. The
same Windows-returned timestamp certificate had explicit timestamp EKU.
The actual signature certificates and independent chain were disposed before
the positive publisher decision, with no observation or cleanup failure.

This uses the newly reviewed Windows Authenticode timestamp-aware publisher
policy. The independent current-time chain remains `Built=false` with
`NotTimeValid`, and `CurrentTimeChainPassed=false`; its path ends in the
officially published Microsoft RCA 2010. No ignore flag or guessed historical
VerificationTime was used. `RootPathAuthenticatedAtSigningTime=false`,
`ExactSigningTimeUtc=null` and `ExactWindowsBackend=Unobserved` remain explicit.
The failed current-time chain was not relabelled successful. The preceding Q0B
result stays Refused under its different frozen policy and remains immutable.

The positive status covers publisher metadata only. Version-resource strings
remain claims. SDK bundle contents, installed SDK versions, installation
prerequisites, debugger ABI, game crash cause and owner gameplay are not
qualified. No setup/help/modify/MSI execution, SDK/tool/symbol acquisition,
debugger DLL load, game or EXE/PDB/dump analysis occurred. Normal Windows trust
may use its OS resolver/cache; no application trust policy/store or ACL was
modified. This result does not authorize an installation automatically.

The same original context/state/capsule, factory witness, clock and NativeJob
owner reached known closure: all 20 original SafeFileHandles closed, original
inputs reverified before release, owner exit 0, original lease/token absent,
clock stopped at 2434 ms and `CanExit=true`. Both AppDomain keys matched the
same original context/witness/clock before cleanup and both were NULL after,
with the original aliases retained until direct interactive exit. The original
terminal actually exited 0 and was never polled again. Independent metadata
at 22:29:50.4453925 UTC found all three original process generations/PIDs
absent, with games/compiler/debuggers and leases empty. Root independently verified the original receipts, terminal completion and
fresh absence before releasing its coordination slot. No cached input was
accessed after release, no context reconstructed and no analysis replayed.

| Q1B receipt | Bytes | SHA-256 |
| --- | ---: | --- |
| `qualification-result.json` | 6291 | `809D145A1805112F15246F9AD99DAD8ADA463E60D40D6058B28E63B422A8397F` |
| `actual-original-postflight.local.json` | 2037 | `118BF1CA2B36C72DFA300BD75CFA4837EC7FE17979C161D59717F33F0E09602B` |
| `actual-independent-closure.local.json` | 4906 | `1E2ADE7F83F2AD63B11A0DDCAD2AB1C009FDAB7C8C74916556F6F916477E0180` |
| `actual-closed-review.local.json` | 9836 | `A342463D5259B86E2A87B7BB229E22964F973D748409EF270CAFE87C070E4550` |

Q1B capsule: 10283 bytes, SHA-256
`248ED6C6C6DFBD5438B7311D9D0706DC880128E3045E87D16EB9CA6119E2B69D`.
Its 99 new Source checks cover the actual collector/model with authored
objects; unchanged Q0B phase/lifecycle code retains its earlier test evidence.
All predecessor sources/results and the closed Q1B result remain frozen.
Next is a separately reviewed SDK Debugging Tools installation/elevation and
shared-MSI-service lifecycle proposal preserving installed CPP/features;
actual installation and later opaque DLL qualification each need their own gate.

### G2: System32 metadata and seven direct export names qualified, no load

The one separately reviewed and authorized G2 invocation on 2026-10-15 UTC
returned `System32MetadataAndSevenDirectNamesQualified_NoLoad` for the exact
`C:\Windows\System32\dbghelp.dll`: 2317640 bytes, SHA-256
`2D2EC94891162A61D86789133623B47D64D74C15D6BE99473B25AD7A6468CF39`.
Its version-resource claims were file version `10.0.26100.9549
(WinBuild.160101.0800)` and product version `10.0.26100.9549`.
The bounded managed PE reader observed an AMD64 PE32+ DLL, nine sections and
252 export names. All seven required names were present and non-forwarded:
`SymInitializeW`, `SymLoadModuleExW`, `SymSetOptions`, `SymGetModuleInfo64`,
`SymFromAddr`, `SymGetLineFromAddr64` and `SymCleanup`. Their addresses were
not executed. Name presence and version strings do not qualify an ABI.

Under the separately reviewed OS-signature policy, Windows returned `Valid`,
`SignatureType=Catalog` and `IsOSBinary=true`. The signer had exactly one
unambiguous Microsoft Corporation organization and explicit code-signing EKU;
the returned timestamp certificate had explicit timestamp EKU. The actual
returned certificates were disposed before the positive decision.
`RootAtSigningTimeQualified=false`, `ExactSigningTimeUtc=null` and
`ExactWindowsBackend=Unobserved` remain explicit. Normal Windows verification
may use its OS resolver/cache; this was not a globally offline trust test.
No manual X509 chain/time override, trust-store/policy or ACL change occurred.
The SDK setup's earlier Q0B/Q1B results were not adopted as DLL evidence.

No target DLL load, dynamic export lookup or DbgHelp native call occurred.
Interface/module identity, ABI, symbol/function/line mapping, actual client
runtime layout, game crash cause and reconstructed game stack remain
unqualified. No other PE/PDB/dump, game, installer, MSI, SDK/tool/symbol
acquisition or System32 replacement was involved.

The same original context/state/capsule, factory witness, clock and NativeJob
owner reached known closure: all 19 original SafeFileHandles closed, original
inputs reverified before release, owner exit 0, original lease/token absent,
clock stopped at 2903 ms and `CanExit=true`. Both AppDomain keys matched the
same original context/witness/clock before cleanup and both were NULL after,
with the original aliases retained through direct interactive exit. The
original terminal actually exited 0 and was never polled again. Independent
metadata at 23:24:21.5610446 UTC found all three original process generations
and PIDs absent, with games/compiler/debuggers and Version 1 leases empty.
Root independently verified the receipts and original terminal completion,
then fresh absence at 23:27:22.756 UTC before releasing its coordination slot.
No DLL input was accessed after release and no qualification was replayed.

| G2 receipt | Bytes | SHA-256 |
| --- | ---: | --- |
| `qualification-result.json` | 5079 | `AB49D0BAF47344B132FEF16D1FFBE9FCABC221E0DC56F315C96B9AE104242A34` |
| `actual-original-postflight.local.json` | 2048 | `6C59697ABE62DCCB28E19A52C1BDDCCA32905016393241A76936A0D3E4FD2D1C` |
| `actual-independent-closure.local.json` | 4372 | `250136BF8599F92613DCFA781130098549DB8B705EC9201E04465890C1B8C201` |
| `actual-closed-review.local.json` | 12555 | `8A806107B3F275C692C572EF5B1A950BC754BC619FE94AB48A01C29C001A6011` |

G2 capsule: 9947 bytes, SHA-256
`FAD838F995F359DAF04279616B50F2B3AE1B22CE735FCAD092FAF5D63A3EE728`.
The 99 new Source checks comprise 29 authored PE regressions, 52 OS-collector
checks with authored certificates and 18 mixed delta causals. They cover the
two reviewed G1 corrections: exactly one organization RDN and globally disjoint
readable RVA intervals including headers. The unchanged phase/lifecycle code
retains its prior evidence; it was not rerun as a new Source suite. G1 was never
executed. All predecessor sources/results and the closed G2 result remain frozen.

Next is a small Source proposal for a local-RVA native Gate2 with the same seven
bindings and full declared structures, plus immediate native-failure/error and
declared-size diagnostics. Native ABI/module identity and each mapping outcome
need actual separate qualification. A new exact capsule review and distinct GO
are required before any target DLL load or further image/PDB analysis. SDK
installation remains a reserved option without a demonstrated necessity.

### H1/H2: native qualification refused; both original invocations closed

H1's one authorized invocation on 2026-10-16 UTC failed before admission:
its 111-character `Owner` exceeded the scheduler's unchanged
`ValidateLength(1,100)`. No lease, factory witness, native child or runtime root
was created, and no opaque analysis input was accessed. Its original 12 Source SafeFileHandles closed,
clock stopped at 492 ms and `CanExit=true`. The main key was cleared after
comparing the same actual context/capsule/clock; the factory key was genuinely
never populated. No witness was fabricated. `InputReverified=false` remains
explicit because no admitted input reverification occurred. The original
NoExit host exited directly, then the caller's two original descriptor handles
closed and the outer terminal truly exited 0. Root checked those receipts,
terminal completion and fresh original process/lease absence before releasing
its slot. Closure does not turn this failed launch into an analytical success.

H2 is a separately reviewed sibling with a 60-character Owner and separate
capsule/root/keys. Its 35 new Source checks use the actual pinned scheduler's
Owner parameter declaration in a function whose entire body is authored.
The real binder rejects the exact old 111-character literal before that body,
accepts the exact new 60-character literal and boundary 100, and rejects 101
and empty. The real resource function is never invoked by those tests. A first
fixture failed to resolve an internal exception type literal; additive fixture B
checks the actual exception FullName. Both fixture sources remain preserved.
The scheduler's limit and the failed H1 result were not changed.

The one authorized H2 native invocation returned `Refused` at
`Resolve.ValidateModuleIdentity`, with `System.IO.InvalidDataException` and
the message `PE/PDB GUID-age mismatch`. The frozen predicate is a conjunction
over module Type, Base, PdbUnmatched, DbgUnmatched, Guid and Age. H2 did not
publish those six returned module values, so the failing member is unknown.
The message is not proof that a GUID alone differs or that the ABI is incompatible.

The explicit System32 DLL load returned an owned reference. Reaching this stage
means the frozen control flow passed initialization, a nonzero expected module
load result and successful module-info retrieval. `SymFromAddr` and line lookup
were not reached. All six failure-only last-error fields are null; no error 87
was observed. Declared managed sizes were Module 1680, Symbol 88, name offset 84
and Line 40; those measurements alone do not qualify the native ABI.

The PE observation was GUID `914449b2-5161-4fa3-ae71-c2c4d45e2d80`, age 8,
image size 6590464 and timestamp 1791986569. The loaded module's six values
remain unobserved in the result. Interface/module identity, symbol/function/line
mapping, actual game runtime layout, crash cause and reconstructed stack remain
unqualified. No game, attach, exception capture, scan, disassembly, symbol server,
installation or acquisition occurred. Earlier results remain immutable.

H2 returned `CleanupConfirmed=true` and `LoaderReferenceReleased=true`; the
worker reverified all three original inputs and closed their handles. The same
actual parent context/state/capsule/witness/clock/owner reached known closure:
all 21 original parent SafeFileHandles closed, inputs reverified before release,
owner exit 0, original lease/token absent, clock stopped at 3048 ms and
`CanExit=true`. Both AppDomain keys matched the original context/witness/clock
before cleanup and both were NULL after, with the same aliases retained through
direct interactive exit. The caller's two original descriptor handles remained
held across the NoExit call, then closed before its own receipt and actual outer
exit 0. The original terminal was never polled again.

Independent metadata at 00:17:32.7248982 UTC found all three original process
generations/PIDs absent, with games/compiler/debuggers and Version 1 leases
empty. Root independently checked receipts, original terminal completion and
fresh absence at 00:18:27.8466459 UTC before releasing its slot. The stopped
3048 ms group clock is distinct from the 86550 ms outer terminal duration.
No opaque input was accessed after release and no native analysis replayed.
A read-only inspection first referenced a nonexistent `Owner.Process` property;
its corrected display used the same original owner. That display error did not
mutate the context or constitute a native failure.

| H1/H2 receipt | Bytes | SHA-256 |
| --- | ---: | --- |
| H1 `actual-closed-review.local.json` | 7418 | `57DF22A052D6692539D4689C5B71DA1678569785ECD45DFA88720734A893EEBE` |
| H2 `qualification-result.json` | 3152 | `457C30A82C1246AA13C71E562184D70BBC09FD5E0466B847A9A3E82D5911C528` |
| H2 `actual-original-postflight.local.json` | 2003 | `F22DD856547D20D9B4C14350C956B5AC47E7B106B357C7344CF2459251E3BB30` |
| H2 `actual-caller-descriptors-closed.local.json` | 1221 | `F4FB170CD38288C12A861BD2D9246DC1A748DB636DD56CFB0336F30A25E5B162` |
| H2 `actual-independent-closure.local.json` | 2104 | `53A748244DD108FB23BCBA69EF05878C3807D02A95557CADFC877AFAA19F83EE` |
| H2 `actual-closed-review.local.json` | 9704 | `95D454401D6BFCCDF6FE2EE68BAD321B106D3FC4A69012DC2E71D7D3CD93B22A` |

H1 capsule: 9812 bytes, SHA-256
`DFAA00161242E23FFED2CDF0DE6DB0A6D2C9D9DB07B01ACBFBE224496217C68B`.
H2 capsule: 11361 bytes, SHA-256
`B26CC5D672DD8715524590ACCF1B85790E0572ED1AF9B43B8862CD2F73C59FDF`.
The earlier 78 composition checks, 31 caller-guard causals, 20 structural checks
and 42 managed authored causals are carried by their frozen pins and not rerun.

Next is a Source-only diagnostic proposal to copy the six owned module values
and six comparison booleans immediately after successful module-info retrieval,
before the unchanged predicate. A failed/not-reached call must leave no fabricated
snapshot. Imports, structs, options, call order and module acceptance stay fixed.
Any operational sibling then needs exact review and a distinct fresh Analysis GO.

### H3: only PdbUnmatched refuses; its underlying cause remains unknown

The one separately reviewed H3 invocation on 2026-10-16 UTC remains `Refused`
at `Resolve.ValidateModuleIdentity`, with the legacy message
`PE/PDB GUID-age mismatch`. Its new owned diagnostic snapshot identifies the
single failing clause of the unchanged conjunction:

| Returned module field | Observed | Required comparison | Result |
| --- | --- | --- | --- |
| Type | 3 | equals 3 | true |
| Base | 268435456 | equals synthetic base 0x10000000 | true |
| PdbUnmatched | 1 | equals 0 | **false** |
| DbgUnmatched | 0 | equals 0 | true |
| Guid | 914449b2-5161-4fa3-ae71-c2c4d45e2d80 | equals the pinned PE CodeView GUID | true |
| Age | 8 | equals the pinned PE CodeView age | true |

Thus H3 refused specifically on `m.PdbUnmatched==0`. The GUID and age match
the expected PE observation. The meaning/cause of the returned flag in this
load scenario is not established; it is not a native last-error code. No error
87 was observed. Do not infer a GUID-only mismatch, ABI incompatibility or game
crash cause, retroactively attribute H2's unpublished values, or weaken the
predicate to force a positive result.

The explicit DLL load and module-info retrieval reached the diagnostic snapshot.
The seven imports, full structures, options, call order and module acceptance
were unchanged. `SymFromAddr` and line lookup were not reached. Interface/module
identity, ABI, symbol/function/line mapping, actual runtime layout, game-cause
and stack qualification remain false. No game, attach, exception capture, scan,
disassembly or installer was invoked; no symbol-server path or acquisition was
requested. Native-library I/O and network behavior were not independently traced.
The existing `SECURE`/`NO_PROMPTS` options alone do not prove offline execution
([Microsoft option documentation](https://learn.microsoft.com/en-us/windows/win32/api/dbghelp/nf-dbghelp-symsetoptions)).

Native symbol cleanup and the owned library-reference release were confirmed.
The worker reverified all three original inputs and closed their handles. The
same actual original context/state/capsule/witness/clock/owner retained all
21 parent guards through input reverification and publication readbacks, then
closed them. The original lease/token was absent, clock stopped at 3039 ms and
`CanExit=true`. Both fixed AppDomain keys matched the same originals before
cleanup and both were NULL after; original aliases survived through direct
interactive exit. The caller's two actual descriptor guards remained held
across NoExit, then closed before its own receipt and true outer terminal exit 0.
No original terminal was repolled and no analysis replayed.

Independent metadata at 00:44:10.5581275 UTC found all three original process
generations/PIDs absent, with games/compiler/debuggers and Version 1 leases
empty. Root independently inspected receipts, original terminal completion and
fresh absence at 00:44:45.6078646 UTC before releasing its slot. The stopped
3039 ms clock is distinct from the 82555 ms outer terminal duration. No opaque
input was reread after release. Closure success does not qualify the refused
analysis.

| H3 receipt | Bytes | SHA-256 |
| --- | ---: | --- |
| `qualification-result.json` | 3532 | `82035700B0E9C6057F5D7FBEE74E34FE339F7FC7061C8B9B39C34B9E74C276AB` |
| `actual-original-postflight.local.json` | 2001 | `06EB1E16EC71FF03632FB6064AD76638FB30BE34C602E285E4353D5AE603B21F` |
| `actual-caller-descriptors-closed.local.json` | 1221 | `78B7CED98DFB9BAC4CFFDA78BD4454CDB78EB099B9C21B872CC66733C05AB525` |
| `actual-independent-closure.local.json` | 2494 | `56864ACD877B8DBDD62762A339B9E176A07D7AD3254883E95F7D57BE7775B941` |
| `actual-closed-review.local.json` | 9209 | `1B39823FB11C21B6DEE5CD33DE8A13FE31854794AF7740443251794F300C46E5` |

H3 capsule: 13256 bytes, SHA-256
`6764BCC13A200DCD951017FD28F63AB110886F35B9F134EE7EE803F4C95E4286`.
The 31 new Source composition checks and 72 previously approved authored
diagnostic causals remain separate from this real native observation; older
suites were carried without rerun. All H/H1/H2/H3 sources and results stay frozen.

The current follow-up is a [pure managed snapshot/cursor model and DIA provider
qualification plan](DIA-PROVIDER-QUALIFICATION.md). Its Source tests do not
qualify a provider, real guard, COM lifecycle or native retry. H4 remains stopped
and H3 remains Refused. Provider metadata, complete ABI/method review and any
native access each need separate review/GO. No flag/type/ABI/acceptance relaxation
is authorized by this checkpoint.

Current instance policy (2026-10-06): use the base game client for ordinary
in-game and sequential A/B tests; stage server changes on a separate test dedicated.
Client clones require a concrete necessity or risk. Instance workflow (`docs/INSTANCE-WORKFLOW.md`, server repository)
supersedes older systematic client-copy requirements and launch recipes below.
Dated test results remain historical evidence.

The debugger is a CLI evidence pipeline, with an explicitly instrumented isolated
build for deeper observations. Use it before inventing engine patches or tuning
dvars. Production UDP 27016, the owner client, voice protocol, configuration and
bank are not changed by this tool. Raw logs, dumps, CSVs, ETL, PDBs and decompiled
retail code stay local under ignored runtime/tools; reports can still contain
private paths/text and are not automatically suitable for publishing.
