# Plan C residual qualification: source feasibility, 2026-10-12

Later source-only continuation: T7 `ba365d4` / main `691833c` revealed an existing
H1 collector already bound to the same Probe owner. The
[current runner](README.md#current-plan-c-reuse-the-h1-compiler-stage)
therefore separates the direct compiler root from the test executable and reuses
H1 unchanged. The Sound-only assessment below is preserved as its earlier
decision record; its proposed native-helper extension was not implemented.
At that source-only checkpoint Plan C remained unexecuted. The later single
authorized [native C witness](native-validation-c-20261012.json) passed; Plan B
remains Failed. The earlier Sound-only proposal below was not implemented.

Status: proposal only; no implementation, executable Plan C, native load, helper
build, reservation or Run. Plan B remains **Failed** despite 46 functional passes.
Its forced cleanup is not reclassified. VSCEIP, the OS, installed tools and the
two-second drain deadline remain unchanged.

## Finding

Sound's `BuildReceipt.Core.ps1` is a narrow receipt adapter over the reviewed v6
completion provider. It overrides `Assert-AuditCompletionReceipt` and delegates
capture, retained file guards, residual identity, original-job Stop and fresh
zero-active confirmation to `Complete-AuditBuildEvidence`.

That mechanism is not directly compatible with this downloader. A safe change
requires a native observation/stream-lifecycle adaptation as well as a receipt
adapter. Merely importing Sound's callback, changing a receipt field, or treating
the existing partial member sample as complete would not satisfy the requested
proof. This study therefore stops before turning that coupling into a new runner
framework or replacing the existing original-job owner.

## Verified source boundaries

The following local provider bytes matched their manifest during this study;
matching a source pin is not execution evidence for a downloader adaptation.

| Source | SHA-256 |
| --- | --- |
| Sound `BuildReceipt.Core.ps1` (source commit `d5b22141b8ec4a4c275c35ea36e57c7dc7ff5e2a`) | `9e1da8f8a6bab282acdef2028f2d35d3e32d1b6511ed13aa2ab5a1cf886e6501` |
| v6 `completion.ps1` | `9710dd10beaa1db17d0bca51916679145f5d76460bc3c43463f888bc9aff3ad0` |
| v6 `residual_policy.ps1` | `86c2d8f3f6c79e5dd644f11741521f74b3ccd6960f45189ba41da38f17ef3888` |
| v6 `Rig.JobMembers.cs` | `5a02254764277b62f752792f1ec4f5b93b85237b171a3381a78d58f6af190e91` |
| Current `Probe-NativeJob.cs` | `ddefa72ff2b98286cd585d1178c13e67dcd646bbcf39d51365660901366c5ca8` |

The PowerShell v6 providers identify source revision
`eabe74ab65d8ce2a943b54d24b15a60749a0cf2a`. The member collector has its own
hash-bound source entry. The downloader's existing DLL and witness remain those
in `job-source.json`; no new assembly was compiled or loaded here. Unrelated
dirty Sound build files were not adopted or modified.

| Required proof | Current downloader | Required change before Plan C |
| --- | --- | --- |
| Original root exit code 0 before residual closure | Public `ExitCode` is populated only by `CloseConfirmed` | Read the retained original process handle after its wait signals exit; retain source/DLL binding and check the deadline after each observation |
| Exactly one completely enumerated job member | `Capture-OriginalMembers` is explicitly partial | Adapt the existing bounded native collector to the exact Probe owner and its `SafeFileHandle`; do not fabricate counts from the process inventory |
| Compatible retained job handle | v6 collector accepts only `IW7.CommunityBuild.BuildJob` with an `IntPtr` field | Add an exact, pinned Probe binding with a safe borrowed-handle lifetime; do not duplicate, replace or close the original job |
| Validated completion before Stop | Receipt is currently read only after `TreeExited` | Validate a fresh run-bound receipt and actual artifacts while the original job and guards remain retained |
| Closed output streams before Stop | Compiler/test output uses regular files; native root output/error writer handles remain open until `CloseConfirmed` | Provide a reviewed writer-close/seal operation after root exit and prove that no inherited writer remains, or reuse a reviewed normal-EOF transport; existing receipt booleans cannot prove this |
| Unchanged budgets | Downloader uses global 180s, drain 2s, cleanup 5s, 32MiB output | Preserve them explicitly; v6 completion has a 3600s global check, different clock representation and 128MiB read aggregate, so it cannot be imported wholesale |

`Rig.JobMembers.cs` already supplies bounded original-job PID enumeration,
membership checks and PID/creation/image/parent observations. Its current owner
binding rejects Probe. The Probe DLL's existing accounting import supplies an
active count, not the complete PID list required by the residual predicate.
The unused `Download-NativeJob.cs` is not a qualified substitute.

The worker's `with` blocks close its own compiler/test log files, but do not prove
that descendants closed inherited handles. Root logs are also regular files, so
calling their current end of file a normal pipe EOF would be false. A future
regular-file seal must acquire and retain read-only guards denying write/delete
sharing after every producer handle is closed; failure to acquire a guard is a
qualification failure. The operation that closes the owner's writer handles must
be reviewed in the helper's lifecycle, not silently added through private-field
disposal. No such stream seal exists in the selected helper today.

## Smallest defensible adaptation to propose

Keep the existing original-job owner, admission, quarantine, source guards and
budget policies. Reuse the reviewed residual identity predicate without weakening
its requirements. Extend the existing collector/helper at their maintained source
only for the missing Probe observation and stream-seal capabilities; do not
introduce a second job owner or a generic replacement execution framework.

A downloader-specific receipt adapter and one qualification branch would then
perform this sequence entirely within the existing drain window:

1. Observe root exit from its original retained process handle, preserve the
   first observation timestamp, and require exit code 0. Start no replacement
   drain or cleanup allowance for qualification.
2. Obtain a complete bounded first capture: original-job accounting reports one
   active member and enumeration reports one assigned/listed member. Read that
   member through a retained process handle; reject every error or ambiguity.
3. Validate a new receipt bound to the exact Plan digest, source pins, run ID,
   lease token and original root PID/creation. Independently validate the actual
   compiler/test exit records, expected command including `/W4 /WX`, unchanged
   46 expected case names exactly once, exact `RESULT 46 passed`, executable,
   reconstructed overlay and all required output hashes under retained guards.
   Do not trust `functional_passed` or substring counting alone. Empty stderr
   files are valid artifacts and need explicit bounded hashing support.
4. Require successful output sealing before any intentional Stop. Retain compiler
   and VCTIP image-file guards, then take the complete final capture. Reuse
   `Get-AuditPinnedResidualIdentity` for exact image, file hash/size, generation,
   membership and capture order. The same single VCTIP must survive both captures.
5. Only after completion, stream and identity proofs all pass, terminate the
   retained original job. Immediately obtain fresh original-job accounting and
   original-root observations. Require Active=0 and root exit=0, check the same
   deadlines after observations and after `CloseConfirmed`, then release normally.

The configured compiler remains pinned to toolset `14.44.35207`, SHA-256
`fe251ef50a1545b1b0835ee17b1e785459712b38d79e45b5c1d3d28970a36619`.
Its sibling VCTIP must be exactly 335288 bytes with SHA-256
`d591358c6aee4b673562ca3b3a15c250e612708394fe3b44a7a7eda2470570a5`.
File-byte identity does not attest loaded memory. A stable observed parent PID
does not prove the parent's generation or compiler ancestry; the reviewed
predicate explicitly leaves those claims false. It proves membership in this
original job, not that VCTIP was a direct child of the Python root.

The proposed successful mode must record intentional qualified residual closure
separately from natural drain and failed cleanup. Qualification failure, a second
member, foreign membership, PID reuse, wrong image/hash, missing output proof,
or any late synchronous call remains Failed. Existing exact-job cleanup may then
run within its separate five-second cleanup budget; it never rescues acceptance.
Unconfirmed or late cleanup retains the original owner, guards and lease in the
existing quarantine. Confirmed timely cleanup releases them while retaining the
Failed result.

## Completion boundary

This is a bounded design proposal, not a prepared candidate. The minimal next
source step belongs at the existing native collector/helper boundary: expose
complete Probe-compatible observation and reviewed stream sealing. It needs an
explicit new source/assembly/witness binding; the old helper witness cannot
qualify changed code. Only then can the small downloader adapter and rejection
tests be prepared without pretending the native prerequisites already exist.

Future source tests should cover stale/malformed receipts, 45/47 or duplicate
cases, open writer handles, changed artifact bytes, incomplete/multiple members,
generation changes, wrong pins, late Stop/zero observation, and quarantine on
unconfirmed closure. Mock tests cannot qualify native collection or stream
closure. No Plan C Run is authorized or performed by this proposal, and no Plan B
artifact or historical validation result is changed.
