param([switch]$Contender,[string]$TestRoot,[string]$ResultPath)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../../ops/Resource-Scheduler.Core.ps1"
function Assert($Value,[string]$Message) { if (!$Value) { throw $Message } }
if (!$TestRoot) { $TestRoot=Join-Path ([IO.Path]::GetTempPath()) ('iw7-resource-tests-'+[guid]::NewGuid().ToString('N')) }
[IO.Directory]::CreateDirectory($TestRoot) | Out-Null
# Tests never change the production global registry or launch a game.
function Get-IW7ResourceRoot { Join-Path $TestRoot 'registry' }
function Get-IW7ResourceSnapshot { [pscustomobject]@{PhysicalTotal=32GB;PhysicalAvailable=28GB;CommitLimit=48GB;Committed=12GB} }
$self=Get-Process -Id $PID
$script:fakeProcesses=@([pscustomobject]@{PID=$PID;ParentPID=0;CreatedUtc=$self.StartTime.ToUniversalTime().ToString('o');Image=$self.Path;Name='pwsh.exe';Lab=$false;Heavy=$false;WorkingSet=100MB;PrivateBytes=100MB})
function Get-IW7ResourceProcesses { $script:fakeProcesses }
if ($Contender) {
    try {
        $lease=Enter-IW7ResourceLease -Scope (Join-Path $TestRoot ('lab-'+$PID)) -Kind Build -PhysicalBytes 4GB -CommitBytes 6GB -Owner "contender-$PID"
        [IO.File]::WriteAllText($ResultPath,'admitted')
        # Keep the winner pending until both launchers have tried admission.
    } catch { [IO.File]::WriteAllText($ResultPath,'refused: '+$_.Exception.Message) }
    return
}
$snapshot=Get-IW7ResourceSnapshot
Assert (Test-IW7ResourceBudget $snapshot 20GB 26.4GB).Allowed 'Exact reserve boundary must pass.'
Assert (!(Test-IW7ResourceBudget $snapshot (20GB+1) 1GB).Allowed) 'Physical reserve boundary must fail.'
Assert (!(Test-IW7ResourceBudget $snapshot 1GB 27GB).Allowed) 'Commit reserve must be independent.'
$bad=[pscustomobject]@{PhysicalTotal=0;PhysicalAvailable=0;CommitLimit=0;Committed=0}
$rejected=$false; try { Test-IW7ResourceBudget $bad 0 0 } catch { $rejected=$true }; Assert $rejected 'Missing telemetry must refuse.'
$scope=Join-Path $TestRoot 'lab-a'
$lease=Enter-IW7ResourceLease -Scope $scope -Kind Runtime -PhysicalBytes 14GB -CommitBytes 16GB -Owner 'test-a'
$rejected=$false; try { Enter-IW7ResourceLease -Scope (Join-Path $TestRoot 'lab-b') -Kind Runtime -PhysicalBytes 1GB -CommitBytes 1GB -Owner 'test-b' } catch { $rejected=$true }
Assert $rejected 'Different worktrees must not double spend RAM.'
$again=Enter-IW7ResourceLease -Scope $scope -Kind Runtime -PhysicalBytes 10GB -CommitBytes 10GB -Owner 'test-a'
Assert ($again.Token -eq $lease.Token -and $again.PhysicalBytes -eq 14GB) 'Reservation must be idempotent and cannot shrink.'
$child=[pscustomobject]@{PID=12345;ParentPID=$PID;CreatedUtc='2026-10-04T10:00:00Z';Image=(Join-Path $scope 'iw7-paris-lab.exe');Name='iw7-paris-lab.exe';Lab=$true;Heavy=$true;WorkingSet=8GB;PrivateBytes=10GB}
$script:fakeProcesses += $child
Add-IW7ResourceProcess -Token $lease.Token -ProcessId 12345
$rejected=$false; try { Exit-IW7ResourceLease -Token $lease.Token } catch { $rejected=$true }; Assert $rejected 'Live child must retain reservation.'
$child.Image=$null
$rejected=$false; try { Exit-IW7ResourceLease -Token $lease.Token } catch { $rejected=$true }; Assert $rejected 'Unreadable child must retain reservation.'
$child.Image='C:\Windows\unrelated.exe'; $child.CreatedUtc='2026-10-04T11:00:00Z'; $child.Lab=$false
Exit-IW7ResourceLease -Token $lease.Token
Assert (@((Get-IW7ResourceStatus).Leases).Count -eq 0) 'Reused PID must not be targeted or retain an old lease.'
$script:fakeProcesses=@($script:fakeProcesses | Where-Object PID -EQ $PID)
# Unmanaged labs and builds must also block admission, without touching them.
$rogue=[pscustomobject]@{PID=22222;ParentPID=0;CreatedUtc='2026-10-04T12:00:00Z';Image='C:\foreign\iw7-paris-lab.exe';Name='iw7-paris-lab.exe';Lab=$true;Heavy=$true;WorkingSet=1GB;PrivateBytes=2GB}
$script:fakeProcesses += $rogue
$rejected=$false; try { Enter-IW7ResourceLease -Scope $scope -Kind Build -PhysicalBytes 4GB -CommitBytes 6GB -Owner 'blocked' } catch { $rejected=$true }
Assert $rejected 'Unregistered foreign lab must block.'
$rogue.Lab=$false; $rogue.Name='MSBuild.exe'; $rogue.Image='C:\tools\MSBuild.exe'
$rejected=$false; try { Enter-IW7ResourceLease -Scope $scope -Kind Runtime -PhysicalBytes 14GB -CommitBytes 16GB -Owner 'blocked' } catch { $rejected=$true }
Assert $rejected 'Unregistered compiler must block.'
$script:fakeProcesses=@($script:fakeProcesses | Where-Object PID -EQ $PID)
$failed=$false
try { Invoke-IW7ResourceJob -Scope $scope -Owner 'intentional error' -Body { throw 'body failure' } } catch { $failed=$true }
Assert $failed 'Workload exception must propagate.'
Assert (@((Get-IW7ResourceStatus).Leases).Count -eq 0) 'Failed synchronous job must release.'
# A real cross-process race on a shared file lock, without heavyweight children.
$shell=(Get-Process -Id $PID).Path
$children=@()
foreach ($i in 1..2) {
    $result=Join-Path $TestRoot "contender-$i.txt"
    $args=@('-NoProfile','-File',('"'+$PSCommandPath+'"'),'-Contender','-TestRoot',('"'+$TestRoot+'"'),'-ResultPath',('"'+$result+'"'))
    $children+=Start-Process -FilePath $shell -ArgumentList $args -WindowStyle Hidden -PassThru
}
foreach ($childProcess in $children) { Assert ($childProcess.WaitForExit(15000)) 'Contender timed out.'; Assert ($childProcess.ExitCode -eq 0) 'Contender failed.' }
$outcomes=@(Get-Content (Join-Path $TestRoot 'contender-1.txt');Get-Content (Join-Path $TestRoot 'contender-2.txt'))
Assert (@($outcomes | Where-Object {$_ -eq 'admitted'}).Count -eq 1) 'Exactly one cross-process contender must win.'
Assert (@($outcomes | Where-Object {$_ -like 'refused:*'}).Count -eq 1) 'Exactly one contender must defer.'
# An orphan build stays visible; explicit release only after no heavy child exists.
$remaining=(Get-IW7ResourceStatus).Leases
Assert (@($remaining).Count -eq 1) 'Orphan build must remain quarantined.'
Exit-IW7ResourceLease -Token $remaining[0].Token
Assert (@((Get-IW7ResourceStatus).Leases).Count -eq 0) 'Proven closed orphan can be released.'
Write-Output 'Resource scheduler passed: memory boundaries, unknown telemetry/identity, idempotency, PID reuse, failure cleanup and cross-process contention.'
Write-Output "Test evidence retained: $TestRoot"
