$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. "$repo/ops/Base-Client.Core.ps1"
if (!('IW7LabProcess' -as [type])) { Add-Type -Path "$repo/ops/native/LabProcess.cs" }
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('iw7-base-exit-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
$owned=$null
$script:ExitChecks=0
function Assert-Test($Value,$Message) { if (!$Value) { throw $Message };$script:ExitChecks++ }
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
    # Small observations test refusal paths without opening/replacing a process.
    # They are not engine/process-owner implementations or runtime evidence.
    function New-TestOwnedObservation([bool]$Signaled,[bool]$WaitConfirms=$false,[bool]$WaitThrows=$false) {
        $observation=[pscustomobject]@{Id=$identity.PID;Signaled=$Signaled;WaitConfirms=$WaitConfirms;WaitThrows=$WaitThrows;WaitCalls=0;WaitMilliseconds=0}
        $observation|Add-Member ScriptProperty HasExited { $this.Signaled }
        $observation|Add-Member ScriptMethod WaitForExit { param([int]$Milliseconds)
            $this.WaitCalls++;$this.WaitMilliseconds=$Milliseconds
            if($this.WaitThrows){throw 'Original handle observation unavailable.'}
            if($this.WaitConfirms){$this.Signaled=$true;return $true}
            $false
        }
        $observation
    }
    $script:LookupMode='missing';$script:LookupCalls=0;$script:Observation=$null
    function Get-Process([int]$Id) {
        $script:LookupCalls++
        if($script:LookupMode -ceq 'denied'){
            $script:Observation.Signaled=$true
            Write-Error -Message 'Synthetic access denied.' -ErrorId AccessDenied -Category PermissionDenied -ErrorAction Stop
        }
        if($script:LookupMode -ceq 'mismatch'){
            $script:Observation.Signaled=$true
            return Microsoft.PowerShell.Management\Get-Process -Id $PID
        }
        Write-Error -Message 'Synthetic missing PID without an exit proof.' -ErrorId NoProcessFoundForGivenId -Category ObjectNotFound -TargetObject $Id -ErrorAction Stop
    }
    $observation=New-TestOwnedObservation $true
    Assert-IW7BaseIdentity $identity $observation
    Assert-Test ($script:LookupCalls -eq 0 -and $observation.WaitCalls -eq 0) 'Already signaled original handle should not reopen its PID.'
    $observation.Id++
    $refused=$false;try{Assert-IW7BaseIdentity $identity $observation}catch{$refused=$_.Exception.Message -match 'Retained handle and process identity differ'}
    Assert-Test ($refused -and $script:LookupCalls -eq 0) 'Mismatched retained-handle ID accepted because it was signaled.'
    $observation=New-TestOwnedObservation $false
    $refused=$false;try{Assert-IW7BaseIdentity $identity $observation}catch{$refused=$_.FullyQualifiedErrorId -like 'NoProcessFoundForGivenId*'}
    Assert-Test ($refused -and $observation.WaitCalls -eq 1 -and $observation.WaitMilliseconds -eq 1000 -and !$observation.HasExited) 'Unsignaled original handle/missing PID was accepted or not bounded.'
    $observation=New-TestOwnedObservation $false $false $true
    $refused=$false;try{Assert-IW7BaseIdentity $identity $observation}catch{$refused=$_.Exception.Message -match 'Original handle observation unavailable'}
    Assert-Test ($refused -and $observation.WaitCalls -eq 1) 'Unknown original-handle observation was accepted.'
    $refused=$false;try{Assert-IW7BaseIdentity $identity}catch{$refused=$_.FullyQualifiedErrorId -like 'NoProcessFoundForGivenId*'}
    Assert-Test $refused 'Missing PID without a retained original handle was treated as exit.'
    $observation=New-TestOwnedObservation $false $true;$script:Observation=$observation;$script:LookupMode='denied'
    $refused=$false;try{Assert-IW7BaseIdentity $identity $observation}catch{$refused=$_.Exception.Message -match 'Synthetic access denied'}
    Assert-Test ($refused -and $observation.WaitCalls -eq 0) 'Access error was hidden by a later original exit or a wait.'
    $observation=New-TestOwnedObservation $false $true;$script:Observation=$observation;$script:LookupMode='mismatch'
    $wrongImage=$identity.PSObject.Copy();$wrongImage.Image=Join-Path $testRoot 'different-image.exe'
    $refused=$false;try{Assert-IW7BaseIdentity $wrongImage $observation}catch{$refused=$_.Exception.Message -match 'Process identity changed'}
    Assert-Test ($refused -and $observation.WaitCalls -eq 0) 'Observed live image mismatch was hidden after original exit.'
    Remove-Item Function:Get-Process
    # Inject lookup absence while the exact retained kernel handle is still
    # unsignaled. The real child exits shortly afterwards; PID absence alone
    # must never authorize restoration. This models a missing timing boundary,
    # not a measured explanation for any particular game crash.
    $lateReady=Join-Path $testRoot 'late-ready';$script:LateRelease=Join-Path $testRoot 'late-release'
    $lateScript=Join-Path $testRoot 'late-child.ps1'
    [IO.File]::WriteAllText($lateScript,@'
param([string]$Ready,[string]$Release)
[IO.File]::WriteAllText($Ready,'ready')
$deadline=[datetime]::UtcNow.AddSeconds(10)
while(!(Test-Path -LiteralPath $Release)) {
    if([datetime]::UtcNow -gt $deadline){exit 2}
    Start-Sleep -Milliseconds 10
}
Start-Sleep -Milliseconds 250
exit 0
'@)
    $lateArgs='-NoLogo -NoProfile -NonInteractive -File "'+$lateScript+'" -Ready "'+$lateReady+'" -Release "'+$script:LateRelease+'"'
    $script:Owned=[IW7LabProcess]::StartOwned($exe,$lateArgs,$testRoot,(Join-Path $testRoot 'stdout4'),(Join-Path $testRoot 'stderr4'),('IW7ParisLab_'+[guid]::NewGuid().ToString('N')),$false)
    $owned=$script:Owned
    $readyDeadline=[datetime]::UtcNow.AddSeconds(5)
    while(!(Test-Path -LiteralPath $lateReady)){if([datetime]::UtcNow -gt $readyDeadline){throw 'Late-signal test child not ready.'};Start-Sleep -Milliseconds 10}
    $p=Microsoft.PowerShell.Management\Get-Process -Id $owned.Id
    $identity=[pscustomobject]@{PID=$owned.Id;Image=$exe;CreatedUtc=$p.StartTime.ToUniversalTime().ToString('o');SHA256=(Get-FileHash -LiteralPath $exe).Hash};$p.Dispose()
    $transaction=Save-IW7BaseTransaction $plan (Join-Path $testRoot 'late-backup')
    [IO.File]::WriteAllText("$game/iw7-mod/players2/config.cfg",'late-signal temporary profile')
    $context=[pscustomobject]@{Handle=$owned;Client=$owned;Identity=$identity;Plan=$plan;Transaction=$transaction;Lock=$null}
    $script:LateLookupBeforeExit=$false;$script:LateLookupCount=0
    function Get-Process([int]$Id) {
        if($Id -eq $script:Owned.Id){
            $script:LateLookupBeforeExit=!$script:Owned.HasExited;$script:LateLookupCount++
            [IO.File]::WriteAllText($script:LateRelease,'exit')
            Write-Error -Message 'Synthetic PID lookup unavailable before original exit signal.' -ErrorId NoProcessFoundForGivenId -Category ObjectNotFound -TargetObject $Id -ErrorAction Stop
        }
        Microsoft.PowerShell.Management\Get-Process -Id $Id -ErrorAction Stop
    }
    $script:VacancyChecked=$false
    Stop-IW7BaseClient $context
    Assert-Test ($script:LateLookupBeforeExit -and $script:LateLookupCount -eq 1 -and $transaction.Restored -and $script:VacancyChecked -and !$context.Handle) 'Late original signal did not permit verified vacant restoration.'
    Assert-Test ([IO.File]::ReadAllText("$game/iw7-mod/players2/config.cfg") -ceq 'original profile') 'Late-signal cleanup lost the original profile.'
    Remove-Item Function:Get-Process
    $owned=$null
    "PASS base-client exit: $script:ExitChecks checks; real original-handle exit, injected missing lookup before late original signal, exact vacant restore, live/reused identity, unknown/unsignaled/access and occupied refusals; no PID termination."
} finally {
    if ($owned) { if (!$owned.HasExited) { $owned.Terminate(0);$null=$owned.WaitForExit(5000) };$owned.Dispose() }
    $absolute=[IO.Path]::GetFullPath($testRoot)
    if (!$absolute.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $absolute -Leaf) -notlike 'iw7-base-exit-*') { throw 'Test cleanup containment refused.' }
    Remove-Item -LiteralPath $absolute -Recurse -Force
}
