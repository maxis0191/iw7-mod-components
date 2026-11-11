# Native unit tests in the local judge: runs ops/Build-Voice.ps1 -TestsOnly, which compiles and runs the C++ unit
# tests of the prepared workspace (tests/native/*.cpp of this product and of its dependencies) and three script
# tests. Until 2026-11-10 only the hosted workflow ran them, and that workflow does not start.
#
# Build-Voice.ps1 takes the Build slot itself and refuses at once when it is held. That refusal happens before
# anything is compiled, so this check asks again every five seconds for a bounded time, and only on that
# refusal: the judge waits for another session's build instead of failing. Any other error is thrown at once.
# The AddressSanitizer variants (-Sanitizers) are not run here; the hosted recipe in .github/ still names them.
param([ValidateRange(0,540)][int]$WaitForSlotSeconds=420)
$ErrorActionPreference='Stop'
$repo=(Resolve-Path -LiteralPath "$PSScriptRoot/../..").Path
$waited=[Diagnostics.Stopwatch]::StartNew()
while($true){
    try {
        $global:LASTEXITCODE=0
        & "$repo/ops/Build-Voice.ps1" -TestsOnly
        if($LASTEXITCODE){throw "ops/Build-Voice.ps1 -TestsOnly exited with code $LASTEXITCODE."}
        break
    } catch {
        $busy=$_.Exception.Message -like 'Resource busy:*' -or $_.Exception.Message -like 'Resource admission lock busy*' -or
            $_.Exception.Message -like 'An existing compiler/extractor/Java analysis is running;*'
        if(!$busy -or $waited.Elapsed.TotalSeconds -ge $WaitForSlotSeconds){throw}
        Start-Sleep -Seconds 5
    }
}
Write-Output ('PASS native unit tests (ops/Build-Voice.ps1 -TestsOnly); {0:N0} s including any wait for the Build slot.' -f $waited.Elapsed.TotalSeconds)
