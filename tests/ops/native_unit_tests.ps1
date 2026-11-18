# Native unit tests in the local judge: runs ops/Build-Voice.ps1 -TestsOnly, which compiles and runs the C++ unit
# tests of the prepared workspace (tests/native/*.cpp of this product and of its dependencies) and three script
# tests. Until 2026-11-10 only the hosted workflow ran them, and that workflow does not start.
#
# Build-Voice.ps1 takes the Build slot itself and, with -WaitForSlotSeconds, waits for it in the scheduler's waiting
# order (no retry loop here; 18 Nov 2026). Any refusal that is not a wait is thrown at once.
# The AddressSanitizer variants (-Sanitizers) are not run here; the hosted recipe in .github/ still names them.
param([ValidateRange(0,7200)][int]$WaitForSlotSeconds=3300)
$ErrorActionPreference='Stop'
$repo=(Resolve-Path -LiteralPath "$PSScriptRoot/../..").Path
$waited=[Diagnostics.Stopwatch]::StartNew()
$global:LASTEXITCODE=0
& "$repo/ops/Build-Voice.ps1" -TestsOnly -WaitForSlotSeconds $WaitForSlotSeconds
if($LASTEXITCODE){throw "ops/Build-Voice.ps1 -TestsOnly exited with code $LASTEXITCODE."}
Write-Output ('PASS native unit tests (ops/Build-Voice.ps1 -TestsOnly); {0:N0} s including any wait for the Build slot.' -f $waited.Elapsed.TotalSeconds)
