$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (!('IW7LabProcess' -as [type])) { Add-Type -Path "$repo/ops/native/LabProcess.cs" }
. "$repo/ops/Lab-Lifecycle.ps1"
$shell = (Get-Process -Id $PID).Path

function Assert-True($value, [string]$message) {
    if (!$value) { throw $message }
}
function Open-TestProcess([int]$exitCode, [int]$delay = 2) {
    $child = Start-Process -FilePath $shell -ArgumentList @('-NoProfile','-Command',('"Start-Sleep -Seconds ' + $delay + '; exit ' + $exitCode + '"')) -WindowStyle Hidden -PassThru
    # Cache this original process handle before any operation that could fail.
    $null = $child.Handle
    try {
        $identity = Get-CimInstance Win32_Process -Filter "ProcessId=$($child.Id)"
        if (!$identity) { throw 'Test child exited before ownership capture.' }
        $created = $identity.CreationDate.ToUniversalTime().ToFileTimeUtc()
        $owned = [IW7LabProcess]::OpenOwned($child.Id, $identity.ExecutablePath, $created)
        [pscustomobject]@{Child=$child;Owned=$owned;Image=$identity.ExecutablePath;Created=$created}
    } catch {
        if (!$child.HasExited) { $child.Kill(); $child.WaitForExit() }
        $child.Dispose()
        throw
    }
}
function Close-TestProcess($test) {
    try { if (!$test.Owned.HasExited) { $test.Owned.Terminate(66); $null = $test.Owned.WaitForExit(5000) } }
    finally { $test.Owned.Dispose(); $test.Child.Dispose() }
}

foreach ($code in @(0,7,259)) {
    $test = Open-TestProcess $code
    try {
        Assert-True ($test.Owned.WaitForExit(10000)) "Timed out waiting for exit $code."
        Assert-True ($test.Owned.ExitCode -eq $code) "Actual exit code differs from $code."
        Assert-True ($test.Owned.HasExited) 'Exited process is not signaled.'
    } finally { Close-TestProcess $test }
}
$test = Open-TestProcess 0 60
try {
    foreach ($wrong in @([pscustomobject]@{Image=($shell + '.wrong');Created=$test.Created},
                         [pscustomobject]@{Image=$shell;Created=($test.Created + 10000000)})) {
        $refused = $false
        try {
            $unexpected = [IW7LabProcess]::OpenOwned($test.Child.Id, $wrong.Image, $wrong.Created)
            $unexpected.Dispose()
        } catch { $refused = $_.Exception.ToString().Contains('identity changed') }
        Assert-True $refused 'Wrong image/creation must refuse ownership.'
        Assert-True (!$test.Owned.HasExited) 'Identity refusal altered the innocent process.'
    }
    Assert-True (!$test.Owned.WaitForExit(10)) 'Running process unexpectedly signaled.'
    $exitRefused = $false
    try { $null = $test.Owned.get_ExitCode() } catch { $exitRefused = $_.Exception.ToString().Contains('still running') }
    Assert-True $exitRefused 'Running process must not supply an exit code.'
    $test.Owned.Terminate(66)
    Assert-True ($test.Owned.WaitForExit(5000)) 'Owned termination did not finish.'
    Assert-True ($test.Owned.ExitCode -eq 66) 'Forced exit code was lost.'
} finally { Close-TestProcess $test }
foreach ($requestFails in @($true,$false)) {
    $test = Open-TestProcess 0 60
    try {
        $result = Invoke-IW7OwnedStop $test.Owned { if ($requestFails) { throw 'Injected mailbox write failure.' } } 1
        Assert-True ($result.Kind -eq 'forced' -and $result.Code -eq 3758096385) 'Failed/timed-out request was counted as clean.'
        Assert-True ($test.Owned.HasExited) 'Failed stop left its owned child alive.'
        Assert-True ([bool]$result.RequestError -eq $requestFails) 'Stop failure reason was lost.'
    } finally { Close-TestProcess $test }
}
$test = Open-TestProcess 0 2
try {
    $request = '123 0123456789abcdef0123456789abcdef stop'
    $mailboxPath = Join-Path ([IO.Path]::GetTempPath()) ('iw7-stop-scope-' + [guid]::NewGuid().ToString('N') + '.request')
    $result = Invoke-IW7OwnedStop $test.Owned { [IO.File]::WriteAllText($mailboxPath, $request) } 10000
    Assert-True ([IO.File]::ReadAllText($mailboxPath) -eq '123 0123456789abcdef0123456789abcdef stop') 'Stop callback shadowed its caller mailbox request.'
    Assert-True ($result.Kind -eq 'clean' -and $result.Code -eq 0) 'Acknowledged normal child exit was counted as forced.'
} finally {
    Close-TestProcess $test
    if (Test-Path -LiteralPath $mailboxPath) { Remove-Item -LiteralPath $mailboxPath }
}
$unconfirmed = [pscustomobject]@{HasExited=$false}
$unconfirmed | Add-Member ScriptMethod WaitForExit { param($ms) return $false }
$unconfirmed | Add-Member ScriptMethod Terminate { param($code) }
$refused = $false
try { $null = Invoke-IW7OwnedStop $unconfirmed {} 1 } catch { $refused = $_.Exception.Message.Contains('not confirmed') }
Assert-True $refused 'Unconfirmed termination was counted as stopped.'
Write-Output 'PASS: retained process handles, exits 0/7/259, timeout, identity refusal and scoped termination.'
