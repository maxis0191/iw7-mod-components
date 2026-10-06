$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. "$repo/ops/Base-Client.Core.ps1"
if (!('IW7LabProcess' -as [type])) { Add-Type -Path "$repo/ops/native/LabProcess.cs" }
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('iw7-base-exit-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
$owned=$null
function Assert-Test($Value,$Message) { if (!$Value) { throw $Message } }
function Assert-IW7BaseVacant([string]$GameRoot,[int]$OwnedPid=0) {
    if ($script:Occupied) { throw 'Unowned occupant retained.' }
    if ($OwnedPid -ne 0) { throw 'Exit restoration must require completely vacant installation.' }
    $script:VacancyChecked=$true
}
try {
    $exe=(Microsoft.PowerShell.Management\Get-Process -Id $PID).MainModule.FileName
    $script:Owned=[IW7LabProcess]::StartOwned($exe,'-NoProfile -NonInteractive -Command "Start-Sleep -Milliseconds 700; exit 0"',$testRoot,(Join-Path $testRoot 'stdout'),(Join-Path $testRoot 'stderr'),('IW7ParisLab_'+[guid]::NewGuid().ToString('N')),$false)
    $owned=$script:Owned
    $p=Microsoft.PowerShell.Management\Get-Process -Id $owned.Id
    $identity=[pscustomobject]@{PID=$owned.Id;Image=$exe;CreatedUtc=$p.StartTime.ToUniversalTime().ToString('o');SHA256=(Get-FileHash -LiteralPath $exe).Hash}
    $p.Dispose()
    $game=Join-Path $testRoot 'game';[IO.Directory]::CreateDirectory("$game/iw7-mod/players2") | Out-Null
    [IO.File]::WriteAllText("$game/iw7-mod/players2/config.cfg",'original profile')
    $plan=[pscustomobject]@{GameRoot=$game;MutableFiles=@();ProfileDirectory='iw7-mod/players2';ProfileDirectories=@('iw7-mod/players2')}
    $transaction=Save-IW7BaseTransaction $plan (Join-Path $testRoot 'backup')
    [IO.File]::WriteAllText("$game/iw7-mod/players2/config.cfg",'temporary profile')
    $context=[pscustomobject]@{Handle=$owned;Client=$owned;Identity=$identity;Plan=$plan;Transaction=$transaction;Lock=$null}
    # Deterministically finish the exact child after the initial HasExited
    # check but before PID lookup; this reproduces the observed cleanup race.
    function Get-Process([int]$Id) {
        if ($Id -eq $script:Owned.Id) { if (!$script:Owned.WaitForExit(10000)) { throw 'Test child did not exit.' } }
        Microsoft.PowerShell.Management\Get-Process -Id $Id -ErrorAction Stop
    }
    $script:VacancyChecked=$false;$script:Occupied=$false
    Stop-IW7BaseClient $context
    Assert-Test ($transaction.Restored -and $script:VacancyChecked -and !$context.Handle) 'Exited original handle did not permit vacant restore/disposal.'
    Assert-Test ([IO.File]::ReadAllText("$game/iw7-mod/players2/config.cfg") -eq 'original profile') 'Exit race lost owner profile restoration.'
    $owned=$null
    Remove-Item Function:Get-Process
    # A mismatched identity is never suppressed merely because a retained
    # object exists. The live child remains owned and is stopped only by handle.
    $owned=[IW7LabProcess]::StartOwned($exe,'-NoProfile -NonInteractive -Command "Start-Sleep -Seconds 5"',$testRoot,(Join-Path $testRoot 'stdout2'),(Join-Path $testRoot 'stderr2'),('IW7ParisLab_'+[guid]::NewGuid().ToString('N')),$false)
    $p=Microsoft.PowerShell.Management\Get-Process -Id $owned.Id
    $wrong=[pscustomobject]@{PID=$owned.Id;Image=$exe;CreatedUtc=$p.StartTime.ToUniversalTime().AddDays(-1).ToString('o');SHA256=(Get-FileHash -LiteralPath $exe).Hash};$p.Dispose()
    $context.Handle=$owned;$context.Identity=$wrong;$context.Transaction=$null
    $refused=$false;try { Stop-IW7BaseClient $context } catch { $refused=$_.Exception.Message -match 'identity changed' }
    Assert-Test ($refused -and !$owned.HasExited -and $context.Handle) 'Real identity conflict was swallowed or child terminated.'
    $owned.Terminate(0);Assert-Test ($owned.WaitForExit(5000)) 'Owned test child cleanup failed.'
    # Vacancy refusal after confirmed exit must retain the handle/transaction.
    $context.Transaction=[pscustomobject]@{Restored=$false};$script:Occupied=$true
    $refused=$false;try { Stop-IW7BaseClient $context } catch { $refused=$_.Exception.Message -match 'Unowned occupant' }
    Assert-Test ($refused -and !$context.Transaction.Restored -and $context.Handle) 'Occupied restoration was accepted or ownership lost.'
    $script:Occupied=$false
    $owned.Dispose();$owned=$null
    # Simulate a reused PID lookup after the original kernel object exits:
    # returning another live process must still produce a comparison refusal.
    $script:Owned=[IW7LabProcess]::StartOwned($exe,'-NoProfile -NonInteractive -Command "Start-Sleep -Milliseconds 700; exit 0"',$testRoot,(Join-Path $testRoot 'stdout3'),(Join-Path $testRoot 'stderr3'),('IW7ParisLab_'+[guid]::NewGuid().ToString('N')),$false)
    $owned=$script:Owned
    $p=Microsoft.PowerShell.Management\Get-Process -Id $owned.Id
    $identity=[pscustomobject]@{PID=$owned.Id;Image=$exe;CreatedUtc=$p.StartTime.ToUniversalTime().ToString('o');SHA256=(Get-FileHash -LiteralPath $exe).Hash};$p.Dispose()
    function Get-Process([int]$Id) {
        if (!$script:Owned.WaitForExit(10000)) { throw 'Test child did not exit.' }
        Microsoft.PowerShell.Management\Get-Process -Id $PID
    }
    $refused=$false;try { Assert-IW7BaseIdentity $identity $owned } catch { $refused=$_.Exception.Message -match 'identity changed' }
    Assert-Test ($refused -and $owned.HasExited) 'Observed reused-PID identity mismatch was swallowed after original exit.'
    Remove-Item Function:Get-Process
    $owned.Dispose();$owned=$null
    'PASS base-client exit: real original-handle exit race, exact vacant restore, live identity-conflict refusal, occupied refusal; no PID termination.'
} finally {
    if ($owned) { if (!$owned.HasExited) { $owned.Terminate(0);$null=$owned.WaitForExit(5000) };$owned.Dispose() }
    $absolute=[IO.Path]::GetFullPath($testRoot)
    if (!$absolute.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $absolute -Leaf) -notlike 'iw7-base-exit-*') { throw 'Test cleanup containment refused.' }
    Remove-Item -LiteralPath $absolute -Recurse -Force
}
