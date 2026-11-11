param([string]$TestRoot)
# The admission lock (11 Nov 2026): a busy lock is part of waiting in the queue, never a fatal refusal, and
# the process list (0.4-0.8 s of WMI) is taken outside it. Temporary registry; holders are child pwsh processes
# that take the lock file (as an old core does) or the turnstile mutex. No real registry, game or build.
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../../ops/Resource-Scheduler.Core.ps1"
if (!$TestRoot) { $TestRoot=Join-Path ([IO.Path]::GetTempPath()) ('iw7-lock-tests-'+[guid]::NewGuid().ToString('N')) }
[IO.Directory]::CreateDirectory($TestRoot) | Out-Null
$script:registry=Join-Path $TestRoot 'registry'
function Get-IW7ResourceRoot { $script:registry }
if ((Get-IW7ResourceRoot) -eq (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'IW7Paris/ResourceScheduler')) { throw 'Test seam failed: live registry selected.' }
[IO.Directory]::CreateDirectory($script:registry) | Out-Null
$lockPath=Join-Path $script:registry 'admission.lock'
function Get-IW7ResourceSnapshot { [pscustomobject]@{PhysicalTotal=32GB;PhysicalAvailable=20GB;CommitLimit=96GB;Committed=12GB} }
$self=Get-Process -Id $PID
$script:me=[pscustomobject]@{PID=$PID;ParentPID=0;CreatedUtc=$self.StartTime.ToUniversalTime().ToString('o');Image=$self.Path;
    Name='pwsh.exe';Lab=$false;BaseClientTest=$false;Heavy=$false;WorkingSet=100MB;PrivateBytes=100MB}
# The process list must never be taken while this process holds the lock (sharing None: our own open fails too).
$script:listedUnderLock=0; $script:listings=0
function Test-LockHeldHere { try { $h=[IO.File]::Open($lockPath,'OpenOrCreate','ReadWrite','None'); $h.Dispose(); $false } catch [IO.IOException] { $true } }
$script:held=@()
function Get-IW7ResourceProcesses { $script:listings++; $h=Test-LockHeldHere; $script:held+=$h; if ($h) { $script:listedUnderLock++ }; @($script:me) }

$script:checks=0; $script:cases=0
function Assert($Value,[string]$Message) { $script:checks++; if (!$Value) { throw $Message } }
function Case([string]$Name,[scriptblock]$Body) {
    $script:cases++
    Get-ChildItem -LiteralPath $script:registry | Where-Object Name -match '^(?:leases|queue)\.json|^admission-log' | Remove-Item -Force
    $script:listedUnderLock=0; $script:listings=0
    try { & $Body } catch { throw "Case '$Name' failed: $($_.Exception.Message)" }
}
# A child pwsh that holds the lock file like an old core (no turnstile) or the turnstile mutex, for N seconds.
function Start-Holder([ValidateSet('File','Mutex','AbandonMutex')][string]$What,[double]$Seconds) {
    $ready=Join-Path $TestRoot ('ready-'+[guid]::NewGuid().ToString('N'))
    $name=Get-IW7AdmissionTurnstileName $script:registry
    $code=switch ($What) {
        'File' { "`$h=[IO.File]::Open('$lockPath','OpenOrCreate','ReadWrite','None'); [IO.File]::WriteAllText('$ready','1'); Start-Sleep -Milliseconds $([int]($Seconds*1000)); `$h.Dispose()" }
        'Mutex' { "`$m=[Threading.Mutex]::new(`$false,'$name'); `$null=`$m.WaitOne(); [IO.File]::WriteAllText('$ready','1'); Start-Sleep -Milliseconds $([int]($Seconds*1000)); `$m.ReleaseMutex()" }
        'AbandonMutex' { "`$m=[Threading.Mutex]::new(`$false,'$name'); `$null=`$m.WaitOne(); [IO.File]::WriteAllText('$ready','1'); Start-Sleep -Milliseconds $([int]($Seconds*1000)); [Environment]::Exit(0)" }
    }
    $p=Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-Command',$code) -PassThru -WindowStyle Hidden
    $sw=[Diagnostics.Stopwatch]::StartNew()
    while (![IO.File]::Exists($ready)) { if ($sw.Elapsed.TotalSeconds -gt 30 -or $p.HasExited) { throw "Holder $What did not start." }; Start-Sleep -Milliseconds 50 }
    $p
}

Case 'a lock held past the wait is a retryable Resource busy refusal' {
    $h=Start-Holder File 4
    $sw=[Diagnostics.Stopwatch]::StartNew()
    $message=$null
    try { Invoke-IW7ResourceLock -WaitSeconds 1 { 'ran' } | Out-Null } catch { $message=$_.Exception.Message }
    Assert ($message -like 'Resource busy: the scheduler admission lock is held by other callers*') "Wrong refusal: $message"
    Assert (Test-IW7RetryableRefusal $message) 'Busy lock not retryable.'
    Assert (Test-IW7RetryableRefusal 'Resource admission lock busy; retry later.') 'Old cores'' busy text not retryable.'
    Assert ($sw.Elapsed.TotalSeconds -ge 0.9 -and $sw.Elapsed.TotalSeconds -lt 3) "Wait bound not kept: $($sw.Elapsed.TotalSeconds) s"
    $h.WaitForExit()
}
Case 'a lock held by an old core (file only) for 3 s is waited for, not refused' {
    $h=Start-Holder File 3
    $sw=[Diagnostics.Stopwatch]::StartNew()
    $r=Invoke-IW7ResourceLock -WaitSeconds 20 { 'ran' }
    Assert ($r -eq 'ran' -and $sw.Elapsed.TotalSeconds -ge 2) "Old-core holder not waited for: $r after $($sw.Elapsed.TotalSeconds) s"
    $h.WaitForExit()
}
Case 'a turnstile held by another new core is waited for, then the body runs' {
    $h=Start-Holder Mutex 2
    $sw=[Diagnostics.Stopwatch]::StartNew()
    $r=Invoke-IW7ResourceLock -WaitSeconds 20 { 'ran' }
    Assert ($r -eq 'ran' -and $sw.Elapsed.TotalSeconds -ge 1.5) "Turnstile holder not waited for after $($sw.Elapsed.TotalSeconds) s"
    $h.WaitForExit()
}
Case 'an abandoned turnstile (holder died) is taken over' {
    $h=Start-Holder AbandonMutex 0.5
    $h.WaitForExit()
    $r=Invoke-IW7ResourceLock -WaitSeconds 5 { 'ran' }
    Assert ($r -eq 'ran') 'Abandoned turnstile not taken over.'
    $r=Invoke-IW7ResourceLock -WaitSeconds 5 { 'again' }
    Assert ($r -eq 'again') 'Turnstile not released after an abandoned take-over.'
}
Case 'a queued job survives a busy lock: it waits and runs (the 1,718 s engine-loop failure)' {
    function Get-IW7AdmissionLockWaitSeconds { 1 }
    $h=Start-Holder File 7
    $sw=[Diagnostics.Stopwatch]::StartNew()
    $out=@(Invoke-IW7QueuedResourceJob -Scope (Join-Path $TestRoot 'bench-job') -Kind Build -PhysicalBytes 1GB -CommitBytes 1GB -Owner 'lock test job' -WaitForSlotSeconds 60 -Body { 'body ran' } 6>&1)
    Assert (@($out | Where-Object { "$_" -eq 'body ran' }).Count -eq 1) "Queued job did not run: $($out -join ' | ')"
    Assert (@($out | Where-Object { "$_" -like 'waiting * the Build reservation: Resource busy: the scheduler admission lock*' }).Count -ge 1) 'The wait was not reported as a queue wait.'
    Assert ($sw.Elapsed.TotalSeconds -ge 6) "Ran before the holder released: $($sw.Elapsed.TotalSeconds) s"
    $state=Read-IW7ResourceState
    Assert (@($state.Leases).Count -eq 0) 'Lease not released after the job.'
    $h.WaitForExit()
}
Case 'a new lease and Status list processes outside the lock' {
    $lease=Enter-IW7ResourceLease -Scope (Join-Path $TestRoot 'bench-a') -Kind Runtime -PhysicalBytes 1GB -CommitBytes 1GB -Owner 'lock test a' -Shareable
    Assert ($script:listings -ge 1 -and $script:listedUnderLock -eq 0) "Enter listed processes under the lock ($script:listedUnderLock of $script:listings)."
    $script:listings=0
    $status=Get-IW7ResourceStatus
    Assert (@($status.Leases).Count -eq 1 -and $script:listings -ge 1 -and $script:listedUnderLock -eq 0) "Status listed processes under the lock ($script:listedUnderLock of $script:listings)."
    Exit-IW7ResourceLease -Token $lease.Token
    Assert (@((Read-IW7ResourceState).Leases).Count -eq 0) 'Lease not released.'
}
Case 'a list that aged while waiting for the lock is taken again outside it' {
    $h=Start-Holder File 4
    $script:held=@()
    $lease=Enter-IW7ResourceLease -Scope (Join-Path $TestRoot 'bench-b') -Kind Runtime -PhysicalBytes 1GB -CommitBytes 1GB -Owner 'lock test b' -Shareable
    # The first list is taken while the child holds the lock (not ours); the second once it aged, after ours was let go.
    Assert ($script:listings -eq 2 -and $script:held[0] -and !$script:held[1]) "Aged list not retaken outside the lock (listings $script:listings, held $($script:held -join ','))."
    Exit-IW7ResourceLease -Token $lease.Token
    $h.WaitForExit()
}
Case 'a stale list never finishes a lease created after it' {
    $listed=[datetime]::SpecifyKind([datetime]'2026-11-11T08:00:00','Utc')
    $lease=[pscustomobject]@{Token='a'*32;Scope='c:\x\late';Kind='Runtime';Owner='late';Phase='Pending';PhysicalBytes=1GB;CommitBytes=1GB;Processes=@();
        OwnerIdentity=[pscustomobject]@{PID=999991;Image='C:\fake\late.exe';CreatedUtc='2026-11-11T08:00:01.0000000Z'};CreatedUtc='2026-11-11T08:00:02.0000000Z'}
    $state=[pscustomobject]@{Version=1;Leases=@($lease)}
    Remove-IW7FinishedRuntimeLeases $state @() -ListedUtc $listed
    Assert (@($state.Leases).Count -eq 1) 'A lease created after the list was reclaimed by it.'
    Remove-IW7FinishedRuntimeLeases $state @() -ListedUtc $listed.AddSeconds(5)
    Assert (@($state.Leases).Count -eq 0) 'A lease created before the list, with its owner gone, was not reclaimed.'
}
Case 'a stale list never expires a ticket asked after it' {
    $now=Get-IW7NowMs
    $ticket=[pscustomobject]@{Seq=1;Scope='c:\x\late';Kind='Runtime';Shareable=$true;PhysicalBytes=1GB;ShortSeconds=0;Owner='late';
        OwnerIdentity=[pscustomobject]@{PID=999993;Image='C:\fake\late.exe';CreatedUtc='2026-11-11T08:00:01.0000000Z'};ParentIdentity=$null;
        FirstMs=$now;LastMs=$now;Polls=1;LastIntervalSeconds=0;OvertakenSeconds=0}
    Save-IW7ResourceQueue ([pscustomobject]@{Version=1;Seq=1;Tickets=@($ticket)})
    $q=Open-IW7ResourceQueue @() -ListedMs ($now-1000)
    Assert (@($q.Queue.Tickets).Count -eq 1) 'A ticket asked after the list was expired as caller gone.'
    $q=Open-IW7ResourceQueue @() -ListedMs ($now+1)
    Assert (@($q.Queue.Tickets).Count -eq 0) 'A ticket asked before the list, its caller gone, was kept.'
}
Write-Output ("PASS $script:cases admission-lock cases / $script:checks assertions; temporary registry, child pwsh lock holders, synthetic process list.")
Remove-Item -LiteralPath $TestRoot -Recurse -Force -ErrorAction SilentlyContinue
