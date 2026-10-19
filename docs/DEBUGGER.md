# Agent debugger and supervised IW7 sessions

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
Client clones require a concrete necessity or risk. [Instance workflow](INSTANCE-WORKFLOW.md)
supersedes older systematic client-copy requirements and launch recipes below.
Dated test results remain historical evidence.

The debugger is a CLI evidence pipeline, with an explicitly instrumented isolated
build for deeper observations. Use it before inventing engine patches or tuning
dvars. Production UDP 27016, the owner client, voice protocol, configuration and
bank are not changed by this tool. Raw logs, dumps, CSVs, ETL, PDBs and decompiled
retail code stay local under ignored runtime/tools; reports can still contain
private paths/text and are not automatically suitable for publishing.

## Entry points

| Command | Witness |
| --- | --- |
| `Debug-Server.ps1 -Action Doctor` | Tools, elevation, resource holders and memory |
| `Identity` / `Observe` | Exact PID/creation/image/hash; retained read-only handle; CPU, threads, resident/private memory, I/O, optional loopback UDP |
| `Snapshot` | Live thread/stack minidump of this worktree's exact isolated lab only |
| `AnalyzeDump` | Bounded offline CDB exception context, all-thread stacks and loaded modules |
| `Etw` | Bounded CPU ETW capture with a unique WPR instance; elevation required |
| `Decompile` | 1..128 caller-selected, unwind-bounded retail functions through existing Ghidra |
| `Debug-Session.ps1 -Action Run` | Existing protected launcher, whole-scenario admission, live sensors, case files, exact owned teardown |
| `Debug-Session.ps1 -Action Observe` | Live sensors for an already-running explicitly installed debugger lab; leaves it running |
| `python ops/iw7_debugger.py` | JSON analysis of logs/dumps/symbols/performance/presents/source/history and combined triage |

All commands require PowerShell 7/Python 3.12. `Install-Tools.ps1 -IncludeDebugger`
reuses pinned CDB and installs portable PresentMon 2.6.0 from the official release.
It does not install a service, driver, overlay or recurring automation. Existing
Ghidra/Temurin, GSC compiler and Visual Studio remain their separately pinned tools.

## Live launch recipe

Use an isolated worktree with the current resource/lab helpers. The native builder
must have its own source checkout; never borrow another active chat's dirty sources.
`Prepare` prepares only the test dedicated and its stock cache by default. Reuse
the existing stopped server snapshot. Observe gameplay from the base client;
automated separate-client recipes require a concrete SeparateClientReason. A new
server stock snapshot is substantial I/O and needs admission. Do not make a new
client snapshot for ordinary debugging or sequential A/B.

```powershell
./ops/Install-Tools.ps1 -IncludeDebugger
./ops/Build-Voice.ps1 -ServerModules -IsolatedLab -Debugger
. ./ops/Resource-Scheduler.Core.ps1
Invoke-IW7ResourceJob -Scope $PWD.Path -Kind Extract -Owner 'debugger stock snapshot' `
    -PhysicalBytes 6GB -CommitBytes 8GB -Body {
        ./ops/Isolated-Lab.ps1 -Action Prepare -SourceGameRoot <legitimate-stock-root> `
            -ServerPort 27416 -ClientPort 27417
    }

# Dedicated-only: compilation/linkage/simulation witness, no player gameplay.
./ops/Debug-Session.ps1 -Action Run -Seconds 60

# Conditional separate-client automation: first document a concrete necessity,
# then explicitly prepare that client with the same SeparateClientReason.
# Prefer the base client for ordinary gameplay/debugging; this old automation
# does not yet manage base-client launch/restoration. Reduced is not normal FPS.
./ops/Debug-Session.ps1 -Action Run -Client -ReducedGraphics -Seconds 120 `
    -SeparateClientReason '<concrete necessity or base-instance risk>' `
    -ExpectedFps 30 -ExpectedTPS 20
```

Run installs the explicit Modules/debugger profile on its already prepared
loopback ports, launches through Isolated-Lab, then runs a combined observer. The client
uses the existing CrossMap protected fixture; this is an automated fixture, not
an unrestricted human-play mode. It requires fresh engine godmode/inactivity=0/
cheats=0 throughout, as enforced by the existing lab monitor. Run closes only
its newly started client/server through the lab's identity/empty-session guards.
Observe does not close a pre-existing session. An ownership/occupied-session
conflict retains the processes/reservation for diagnosis rather than guessing.

The debugger plan declares an additional 2 GiB physical / 3 GiB commit for native
tracing, observers and optional CDB/ETW diagnostics. Its historical Reduced
one-client totals are 14/15 GiB physical/commit; Full totals are 18/19 GiB.
These workload estimates and fresh memory percentages are telemetry, not fixed
admission minima or percentage stop rules. Preserve the shared scheduler's
identity, ownership, lease and heavy-workload serialization gates; see the current
[resource workflow](RESOURCE-WORKFLOW.md). Other chats keep their slots.

## What arrives in real time

`runtime/debugger/session-*/live.jsonl` and stdout contain typed alerts and explicit
coverage gaps. Each process has its own CPU/thread/memory series; they are never
averaged together. Current policy is a starting diagnostic policy, not an engine
specification: frame spikes above twice the selected frame budget, repeated GSC
simulation cadence below 70% of ExpectedTPS, CPU above one busy core's 90% for five
samples, and sustained private-memory growth above 32 MiB/min over at least 25 s with
more than 16 MiB growth. Startup warmup is 30 s. Transitions reset the cadence streak.
An allocation trend is a leak candidate; retained allocations across comparable
round/map boundaries or allocation stacks must establish the leak.
Five consecutive renderer/Present windows below 80% of the selected expected
cadence raise a channel-specific drop alert. Three windows with an active scope
and no completion raise an unreturned-call hypothesis; CPU and all-thread stacks
must distinguish a spinning loop, wait, loading or an interrupted VM invocation.
Idle GSC waits are excluded when fresh UDP reports zero clients.

Logs are tailed with partial-line handling. New crash ZIPs are parsed, including
their exception, access type, module/RVA and CodeView identity. After process exit,
the watcher drains final logs/dumps for five seconds. Fatal/link/runtime/canonical
string/asset-limit/protection symptoms remain separate classifications. Nothing
automatically restarts, deploys or applies an optimization.

PresentMon runs as a PID-filtered, uniquely named session, without its restart-as-
admin or stop-existing-session flags. Its v1 CSV retains actual Present intervals;
the analyzer separates swapchains and computes frame-time quantiles/present rate.
Present cadence is not necessarily displayed FPS: dropped, occluded or generated
frames and display cadence require interpretation. Missing access/CSV/presentations
are reported as missing coverage, never as smooth rendering. NVIDIA device VRAM,
utilization and temperature are optional and cover the whole shared GPU.

The diagnostic build also records cadence at the pinned fork's existing render-
present callback, with eight fixed swapchain channels. This works without ETW
privileges, but callback rate is still not displayed FPS. A local COM query on
the rendering thread samples the process DXGI local-segment memory budget on
adapter node zero once per second. Unsupported devices/failed HRESULTs remain
visible; it cannot attribute every allocation or cover every multi-GPU node.
No additional renderer detour, overlay or GUI is installed.

The explicit native build times the pinned scheduler's server engine call plus
its pipeline, main engine call, and GSC builtin function/method dispatches. These
are inclusive wall scopes, including waits/nested calls. IDs resolve through the
matching `iw7_func.cpp`/`iw7_meth.cpp` tables. It does not instrument every GSC
bytecode/function automatically or measure exclusive CPU per script. A small
dedicated GSC frame coroutine reports distinct simulation times and resets; this
is a VM-frame witness, not packet rate or a claim about every subsystem's TPS.

For a specific script suspect, bracket a region only in a separate lab candidate:

```c
token = paris_debug_begin(17);
// The exact region under investigation.
paris_debug_end(17, token);
```

Region IDs 0..255 carry no player text. Pair tokens in their original invocation;
regions including `wait` measure wall duration. Float tokens lose precision as
the run ages, while automatic native scopes retain the steady-clock resolution.
Fixed counter storage records starts/completions and clock failures; a VM error
can skip scope completion. Do not assume a missing completion is an infinite loop.
Active scope counts survive window flushes so a call spanning several windows
remains visible; an aborted VM call can also leave a persistent active count.
Native recording is bounded to 600 s / 16 MiB. Session observation is bounded to 600 s /
128 MiB. Gaps, missing probes, profiler expiry and collector failure are evidence
limits, not clean-health reports. Longer leak investigation needs repeated scoped
sessions and comparable retained-memory checkpoints.

## Fast incident commands

```powershell
$identity = ./ops/Debug-Server.ps1 -Action Identity -ProcessId <exact-pid> | ConvertFrom-Json
./ops/Debug-Server.ps1 -Action Observe -ProcessId $identity.PID `
    -ExpectedImage $identity.Image -ExpectedCreatedUtc $identity.CreatedUtc `
    -ExpectedSHA256 $identity.SHA256 -Threads -Port 27016 -Seconds 30

python ops/iw7_debugger.py --output runtime/incident.json triage `
    --logs <log> --dumps <crash.zip> --traces <capture.jsonl>
python ops/iw7_debugger.py dump <crash.zip>
python ops/iw7_debugger.py symbols --image <exact.exe> --pdb <exact.pdb> --dump <crash.dmp>
./ops/Debug-Server.ps1 -Action AnalyzeDump -InputPath <crash.dmp> -SymbolsPath <matching-symbol-directory>
python ops/iw7_debugger.py perf <trace.jsonl> --token-root <pinned-gsc-tool-src/gsc/engine>
python ops/iw7_debugger.py presents <presents.csv> --pid <exact-client-pid>
python ops/iw7_debugger.py compare <baseline.jsonl> <candidate.jsonl>
python ops/iw7_debugger.py index
python ops/iw7_debugger.py blame src/custom_scripts/cp/<script.gsc> --line <line>
python ops/iw7_debugger.py case --scenario 'map, actors, settings, stimulus, phase' --artifacts <files>
```

Symbols checks compare PE CodeView GUID/age with the PDB info stream and optional
dump module CodeView/timestamp/image size. The file name alone is insufficient.
Wrong symbols return exit2. The dump parser does not unzip arbitrary paths and
accepts repeated unused DbgHelp stream placeholders. Retail engine frames often
have no public PDB; retain their exact module/RVA and matching unpacked references.
A faulting module/last changed line can be the victim of earlier corruption.

Snapshot uses external MiniDumpWriteDump; it can perturb timing and is not a crash
exception capture. Offline CDB has a 120 s process limit and closes only its own
diagnostic child on timeout. Microsoft symbol downloads require the explicit
MicrosoftSymbols switch. ETW uses named WPR instances and never cancels another
recording. An already admitted debugger lab can supply its exact RuntimeLeaseToken
for one serialized CDB/ETW operation within its preplanned diagnostic budget;
Ghidra requires its separate heavy slot. WPR needs elevation; the current desktop
session cannot silently provide it.

## Evidence and optimization discipline

Use exact hashes, source commit, process creation, fresh phases and a defined
stimulus. Preserve the pre-error data and matching PDB before rebuilding. Parser
success, native compilation, startup, automatic fixture behavior and owner gameplay
acceptance are different witnesses. Compare repeated A/B under the same map,
actors, settings, phase, duration and resource pressure; measure instrumented
versus uninstrumented overhead before accepting a performance improvement.

The compatible `high_pressure_samples` counter still counts samples with
`commit_percent >85`, and `pressure_free` only means neither compared trace
contains such a sample. The `resource.pressure` alert retains the raw percentages
and explicitly labels this legacy heuristic. These fields alone neither invalidate
an observation nor establish available capacity or memory exhaustion; they are not
admission or stop rules. A performance report remains an observation requiring
scenario, repetition and instrumentation-overhead controls.

### Declared phases and comparison windows

Legacy `metrics`, `hotspots` and comparison `changes` remain all-row descriptive
observations. Equal generic labels (or two absent contexts) never make
`contexts_match` true. A separate `phase` report and `phase_comparison` expose
closed-window values, exclusions and channel coverage. They do not establish an
optimization, actual game workload or owner acceptance.

For a future authorized collection, `iw7_watch.py --comparison-context <json>`
requires explicit `--measurement-start-seconds` and `--measurement-end-seconds`.
Both offsets must lie within `--seconds`, after the selected warmup. For example,
30 seconds of warmup followed by 120 measured seconds uses collection 150,
start 30 and end 150; the window is not extended when samples are missing.

The context is a closed object with these required declarations:

```json
{
  "map": "cp_zmb",
  "phase": "round_active",
  "declared_clients": 1,
  "actors": {"zombies": 24},
  "pending": {"spawns": 0},
  "resolution": "not_applicable",
  "scale": "not_applicable",
  "options": {"dedicated": true},
  "config_hashes": {"server": "<lowercase SHA256>"},
  "script_hashes": {"scripts": "<lowercase SHA256>"},
  "builds": {"Server": "<target image lowercase SHA256>"}
}
```

Replace the explanatory hash strings with actual 64-character hashes. Counts are
explicit nonnegative integers, not booleans/default zero. Options are nonempty,
finite scalar declarations. Rendering requires positive `[width,height]` and
scale; the exact pair `not_applicable` is for headless collections only, not
unknown client settings. Build keys must match the collection targets and their
image pins. Config/script/build declarations are not automatic game-state
attestation. Compare controls exactly; build differences are displayed separately
as experimental variables, never silently treated as equal controls.

The header records a unique collection ID, requested measurement bounds and the
observed collection start in `windows.GetTickCount64.ms`. Its matching complete
row records the observed end and completion state. `monotonic` still schedules
the observer; UTC is display metadata. Neither is silently substituted for that
clock. An absent/invalid footer, mixed clocks, unequal phase durations or an
uncollected part of the window prevents qualified phase differences.
The collector takes a final acquisition at/after its requested duration before
writing completion; this does not move the requested measurement bounds. Native
periods still need actual emitted bounds: the final collector read alone does
not prove that a native channel covers the end.

CPU/I/O phase periods conservatively span the previous process-sample acquisition
start through its current end in GetTickCount64. CPU rates use separate
`python.perf_counter.seconds` brackets immediately around `obs.sample()`, before
threads or UDP work. The actual process counter read is inside that envelope;
the minimum/maximum possible elapsed intervals give lower/upper CPU percentages.
The midpoint estimate remains descriptive. Phase comparison reports p95 bounds
and does not qualify an apparent CPU delta when the ranges overlap. The clocks
are not mapped or substituted for one another; millisecond phase readings have
GetTickCount64 quantization, while rate brackets use perf_counter resolution.
Threads have their own acquisition/rate brackets, and UDP has its own bracket.
Memory snapshots retain only their process-acquisition brackets. Native `tick_ms` is preserved
as emission time; late ingestion never moves an old row into the current phase.
Only actual Source period bounds are used, including `server_ticks.window_ms`.
Unbounded render windows, GPU acquisition times and inclusive timing scopes stay
descriptive rather than deriving a period from a rate or ingestion timestamp.

Only periods entirely inside the closed window supply phase values; crossing
periods are excluded without prorating. Their known intervals can establish
coverage at the edges. Each channel reports count, observed temporal extent,
exclusion reasons and whether the period union covers the window. Memory/thread/
UDP acquisition brackets describe snapshot uncertainty, not continuous coverage;
their phase-filtered values therefore remain descriptive. A missing/ambiguous interval or relevant coverage gap prevents that
channel's qualified difference without invalidating other covered channels.
PresentMon remains separate per PID/swapchain: without an explicit temporal clock
correspondence, it never becomes a qualified CPU/native phase comparison.

Arbitrary visual/gameplay bugs, all bytecode loops, every allocation owner and
all engine subsystems cannot be inferred by this tool. Add targeted assertions,
regions, allocation/ETW stacks or framebuffer evidence when the broad sensors
identify a suspect. The tool records its blind spots so an absent alert cannot
be mistaken for proof that everything is correct. See dated validation/issue
for the actual runtime coverage attained, including any admission refusal.

Validation remains tracked in [issue 87](https://github.com/maxis0191/iw7-paris-server/issues/87).
The actual protected client request was refused by memory admission; native
renderer/VRAM gameplay and comparative overhead are pending. PresentMon returned
access denied in this desktop session; WPR refuses before starting when not
elevated. No privileged measurement was fabricated.
The selected-function Ghidra adapter completed a real one-function analysis with
the retained local text/rdata/unwind sections; this verifies the adapter, not
every inferred decompiler type or the semantics of a proposed engine patch.

Primary references: [CDB !analyze](https://learn.microsoft.com/en-us/windows-hardware/drivers/debuggercmds/-analyze),
[WPR named instances](https://learn.microsoft.com/en-us/windows-hardware/test/wpt/wpr-command-line-options#instancename),
[MiniDumpWriteDump](https://learn.microsoft.com/en-us/windows/win32/api/minidumpapiset/nf-minidumpapiset-minidumpwritedump),
[DXGI process video-memory budget](https://learn.microsoft.com/en-us/windows/win32/api/dxgi1_4/nf-dxgi1_4-idxgiadapter3-queryvideomemoryinfo),
[PresentMon console](https://github.com/GameTechDev/PresentMon/blob/v2.6.0/README-ConsoleApplication.md),
[official release](https://github.com/GameTechDev/PresentMon/releases/tag/v2.6.0).
Official Aurora develop was checked once for this task at c0a1c6d; no upstream
update was adopted. The native diagnostic build retains reviewed fork 77e6d4d.
