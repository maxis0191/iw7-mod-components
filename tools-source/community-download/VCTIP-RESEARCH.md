# VCTIP lifecycle research, 2026-10-12

Plan B compiled and passed all 46 functional cases, but remained globally Failed
when its original job did not drain within two seconds. The last observed VCTIP
member had verified original-job membership, creation and image identity. Owned
cleanup closed the job and released the lease; it did not qualify the failed run.
Plan A remains separately recorded as a compile failure plus drain failure.

This investigation is read-only. It did not invoke the compiler, linker, VCTIP,
another native harness, a resource reservation, or a new helper. It changed no
installed tool, registry value, environment setting, deadline or acceptance rule.

## Exact installed components

These are file metadata and SHA-256 observations, not `/Bv` or help executions.
The installed toolchain directory is `14.44.35207`, while its patched components
report product version `14.44.35229.0`.

| File | File version | Bytes | SHA-256 |
| --- | --- | ---: | --- |
| cl.exe | 19.44.35229.0 | 677776 | FE251EF50A1545B1B0835EE17B1E785459712B38D79E45B5C1D3D28970A36619 |
| link.exe | 14.44.35229.0 | 3252616 | A364AF801A8539E4324D9489313DBF001D959128451FC99A27B24676BBAC058F |
| vctip.exe | 14.44.35229.0 | 335288 | D591358C6AEE4B673562CA3B3A15C250E612708394FE3B44A7A7EDA2470570A5 |

VCTIP's file description identifies it as the Microsoft VC compiler/tools
experience-improvement uploader. Bounded string reads of these three binaries
also found the matching versioned VCTIP pipe/mutex names in both compiler and
linker. No disassembler, dump, CLR assembly load or bulk toolchain scan was used.

## Primary-source explanation

Microsoft's [BuildXL MSVC tool definition](https://github.com/microsoft/BuildXL/blob/main/Public/Sdk/Experimental/Msvc/VisualCpp/visualCpp.dsc#L46-L52)
explicitly classifies VCTIP as a surviving compiler child used for telemetry.
Its sandbox policy permits that child to break away. That is evidence of a known
lifecycle, not a policy we can copy: this harness requires every child to remain
inside the retained original job through confirmed closure.

Microsoft's [CMake Tools changelog](https://github.com/microsoft/vscode-cmake-tools/blob/main/CHANGELOG.md)
also records removing a compiler-version probe because descendants including
VCTIP could retain output pipes after the compiler finished. Our harness already
reads tool versions from file metadata; it must still compile the actual tests.

Inference: the observed post-worker VCTIP membership is consistent with this
known auxiliary-process lifecycle and explains why a successful test executable
can coexist with a failed two-second natural-drain requirement. The local runs
do not measure VCTIP's normal eventual exit time, prove why it stayed alive
internally, or establish an exact timeout for version 14.44.35229.0.

## Documented configuration candidate and its limits

Microsoft's [VSCEIP documentation](https://learn.microsoft.com/en-us/visualstudio/ide/visual-studio-experience-improvement-program?view=vs-2022#registry-settings)
specifies the Build Tools opt-out through the DWORD `OptIn=0` at
`HKLM\SOFTWARE\Wow6432Node\Microsoft\VSCommon\17.0\SQM` on 64-bit Windows.
The ignored local research receipt preserves the currently observed value and
policy-key state. Neither was changed. This is a machine-wide Build Tools
preference, not a per-invocation compiler environment switch. Microsoft describes
optional-data collection being disabled; required diagnostics are separate.
The documentation does not guarantee that VCTIP will never launch or will exit
within two seconds. Therefore this is a legitimate configuration candidate to
review, not a proven lifecycle fix.

The installed `VsDevCmd.bat` checks `VSCMD_SKIP_SENDTELEMETRY` at line 250 before
its `Send-VsDevShellTelemetry` call. Its SHA-256 is
`C004278E64444BF3524360F960511B5CE7B1D0306910F08A4EBCF1C42FF9BD6D`.
Our worker does not call that batch file or `vcvars`; it invokes the exact compiler
directly. Setting that variable alone has no demonstrated relevance to the
compiler-created VCTIP observed here. No supported process-local VCTIP opt-out
was established by the targeted official-source search.

The installed VCTIP binary embeds help for `-upload:[optout|optin|skip]` and
`-timeout:<seconds>`. Static help strings do not establish side effects, whether
the compiler propagates options, or whether upload opt-out prevents process
creation. These options were not invoked. The embedded unstable-state command
is likewise not an authorized substitute for a supported opt-out.

## Next review decision

If a VSCEIP preference change is explicitly selected, preserve its current typed
value first, apply only the documented setting, and authorize one separately
admitted witness using the same original-job supervision, 46 cases, `/W4 /WX`,
4/6 GiB profile, 32 MiB bound and existing deadlines. Record any rollback choice
and the observed process lifecycle independently from optional telemetry policy.
If VCTIP still survives, the run must still fail; do not retry or widen limits.

No new runnable Plan C is prepared from an unproven switch. No global process
kill, installed-file removal/rename, fake executable, breakaway exception,
toolchain clone or reclassification of the forced cleanup is proposed here.

Local research receipt: `.scratch/vctip-readonly-research-20261012.json`, SHA-256
`5CD709BFB9E4E6BAC02B79DE74DC60AAE26E776A7A46CB740EE544FEEE0E2EE9`.
