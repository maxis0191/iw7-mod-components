param([switch]$Contender,[string]$TestRoot,[string]$ResultPath)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../../ops/Resource-Scheduler.Core.ps1"
function Assert($Value,[string]$Message) { if (!$Value) { throw $Message } }
if (!$TestRoot) { $TestRoot=Join-Path ([IO.Path]::GetTempPath()) ('iw7-resource-tests-'+[guid]::NewGuid().ToString('N')) }
[IO.Directory]::CreateDirectory($TestRoot) | Out-Null
# Tests never change the production global registry or launch a game.
function Get-IW7ResourceRoot { Join-Path $TestRoot 'registry' }
$script:fakeSnapshot=[pscustomobject]@{PhysicalTotal=32GB;PhysicalAvailable=28GB;CommitLimit=48GB;Committed=12GB}
function Get-IW7ResourceSnapshot { $script:fakeSnapshot }
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
Assert (Test-IW7ResourceBudget $snapshot 96GB 96GB).Allowed 'An estimate above available RAM/commit must not refuse authorized work.'
$observed=Test-IW7ResourceBudget $snapshot 20GB 1GB
Assert ($observed.Policy -eq 'TelemetryOnly' -and $observed.PhysicalReserve -eq 0 -and $observed.CommitReserve -eq 0) 'No fixed RAM or commit reserve may survive.'
Assert ($observed.AdditionalPhysical -eq 20GB -and $observed.AdditionalCommit -eq 1GB) 'Whole-workload estimates remain visible as telemetry.'
$script:fakeSnapshot=[pscustomobject]@{PhysicalTotal=32GB;PhysicalAvailable=0;CommitLimit=48GB;Committed=48GB}
$busyBudget=Test-IW7ResourceBudget (Get-IW7ResourceSnapshot) 96GB 96GB
Assert ($busyBudget.Allowed -and !$busyBudget.HighWater -and $busyBudget.PhysicalUsedPercent -eq 100 -and $busyBudget.CommitUsedPercent -eq 100) 'No use percentage or estimated headroom may refuse or stop work; actual percentages remain visible.'
$bad=[pscustomobject]@{PhysicalTotal=0;PhysicalAvailable=0;CommitLimit=0;Committed=0}
$rejected=$false; try { Test-IW7ResourceBudget $bad 0 0 } catch { $rejected=$true }; Assert $rejected 'Missing telemetry must refuse.'
$scope=Join-Path $TestRoot 'lab-a'
$validSnapshot=$script:fakeSnapshot
$script:fakeSnapshot=$bad
$rejected=$false; try { Enter-IW7ResourceLease -Scope $scope -Kind Runtime -PhysicalBytes 14GB -CommitBytes 16GB -Owner 'invalid telemetry' } catch { $rejected=$true }; Assert $rejected 'Invalid telemetry must still block actual admission.'
Assert (@((Read-IW7ResourceState).Leases).Count -eq 0) 'Failed telemetry must not create a lease.'
$script:fakeSnapshot=$validSnapshot
$lease=Enter-IW7ResourceLease -Scope $scope -Kind Runtime -PhysicalBytes 14GB -CommitBytes 16GB -Owner 'test-a'
Assert ($lease.MemoryObservation.Snapshot.PhysicalAvailable -eq 0 -and $lease.MemoryObservation.Budget.Allowed) 'Real admission must accept low headroom and retain the fresh observation.'
$rejected=$false; try { Enter-IW7ResourceLease -Scope (Join-Path $TestRoot 'lab-b') -Kind Runtime -PhysicalBytes 1GB -CommitBytes 1GB -Owner 'test-b' } catch { $rejected=$true }
Assert $rejected 'A different holder must still block even though memory estimates never refuse.'
$script:fakeSnapshot=[pscustomobject]@{PhysicalTotal=32GB;PhysicalAvailable=1MB;CommitLimit=48GB;Committed=(48GB-1MB)}
$again=Enter-IW7ResourceLease -Scope $scope -Kind Runtime -PhysicalBytes 10GB -CommitBytes 10GB -Owner 'test-a'
Assert ($again.Token -eq $lease.Token -and $again.PhysicalBytes -eq 14GB) 'Reservation must be idempotent and cannot shrink.'
Assert ($again.MemoryObservation.Snapshot.PhysicalAvailable -eq 1MB -and (Read-IW7ResourceState).Leases[0].MemoryObservation.Snapshot.PhysicalAvailable -eq 1MB) 'Re-entry must persist a fresh observation rather than reuse earlier admission telemetry.'
$child=[pscustomobject]@{PID=12345;ParentPID=$PID;CreatedUtc='2026-10-04T10:00:00Z';Image=(Join-Path $scope 'iw7-paris-lab.exe');Name='iw7-paris-lab.exe';Lab=$true;Heavy=$true;WorkingSet=8GB;PrivateBytes=10GB}
$script:fakeProcesses += $child
Add-IW7ResourceProcess -Token $lease.Token -ProcessId 12345
$rejected=$false; try { Exit-IW7ResourceLease -Token $lease.Token } catch { $rejected=$true }; Assert $rejected 'Live child must retain reservation.'
$child.Image=$null
$rejected=$false; try { Exit-IW7ResourceLease -Token $lease.Token } catch { $rejected=$true }; Assert $rejected 'Unreadable child must retain reservation.'
$rejected=$false; try { Enter-IW7ResourceLease -Scope $scope -Kind Runtime -PhysicalBytes 14GB -CommitBytes 16GB -Owner 'test-a' } catch { $rejected=$true }; Assert $rejected 'Unknown attached identity must still block re-entry with low headroom.'
$child.Image='C:\Windows\unrelated.exe'; $child.CreatedUtc='2026-10-04T11:00:00Z'; $child.Lab=$false
Exit-IW7ResourceLease -Token $lease.Token
Assert (@((Get-IW7ResourceStatus).Leases).Count -eq 0) 'Reused PID must not be targeted or retain an old lease.'
$script:fakeProcesses=@($script:fakeProcesses | Where-Object PID -EQ $PID)
$launcherImage=$script:fakeProcesses[0].Image
$script:fakeProcesses[0].Image=$null
$rejected=$false; try { Enter-IW7ResourceLease -Scope $scope -Kind Runtime -PhysicalBytes 14GB -CommitBytes 16GB -Owner 'unknown launcher' } catch { $rejected=$true }; Assert $rejected 'Unknown launcher identity must still block first admission.'
$script:fakeProcesses[0].Image=$launcherImage
# The base client is an explicitly declared executable outside the server lab.
# Only its scoped fixture flags permit attachment; normal owner clients cannot
# be adopted, and the declaration/whole-scenario budget stay immutable.
$baseImage=Join-Path $TestRoot 'base/iw7-paris-voice.exe'
$baseLease=Enter-IW7ResourceLease -Scope $scope -Kind Runtime -PhysicalBytes 12GB -CommitBytes 12GB -Owner 'base-client test' -BaseClientImage $baseImage
$state=Read-IW7ResourceState
$state.Leases[0].BaseClientImage='relative/client.exe'
Save-IW7ResourceState $state
$rejected=$false; try { Get-IW7ResourceStatus } catch { $rejected=$true }; Assert $rejected 'Malformed persisted client declaration must refuse admission.'
$state.Leases[0].BaseClientImage=$baseImage
Save-IW7ResourceState $state
$baseChild=[pscustomobject]@{PID=33333;ParentPID=$PID;CreatedUtc='2026-10-04T12:00:00Z';Image=$baseImage;Name='iw7-paris-voice.exe';Lab=$true;BaseClientTest=$false;Heavy=$true;WorkingSet=4GB;PrivateBytes=5GB}
$script:fakeProcesses += $baseChild
$rejected=$false; try { Add-IW7ResourceProcess -Token $baseLease.Token -ProcessId 33333 } catch { $rejected=$true }; Assert $rejected 'Ordinary owner client cannot be adopted.'
$baseChild.BaseClientTest=$true; $baseChild.Lab=$false
$rejected=$false; try { Add-IW7ResourceProcess -Token $baseLease.Token -ProcessId 33333 } catch { $rejected=$true }; Assert $rejected 'Both private client fixture markers are required.'
$baseChild.Lab=$true
$rejected=$false; try { Exit-IW7ResourceLease -Token $baseLease.Token } catch { $rejected=$true }; Assert $rejected 'Unregistered declared client must retain reservation.'
Add-IW7ResourceProcess -Token $baseLease.Token -ProcessId 33333
$again=Enter-IW7ResourceLease -Scope $scope -Kind Runtime -PhysicalBytes 8GB -CommitBytes 8GB -Owner 'base-client test'
Assert ($again.Token -eq $baseLease.Token -and $again.PhysicalBytes -eq 12GB) 'Declared client re-entry keeps full scenario budget.'
$rejected=$false; try { Enter-IW7ResourceLease -Scope $scope -Kind Runtime -PhysicalBytes 12GB -CommitBytes 12GB -Owner 'base-client test' -BaseClientImage (Join-Path $TestRoot 'other.exe') } catch { $rejected=$true }; Assert $rejected 'Cannot change declared base image after reservation.'
$baseChild.Image=Join-Path $TestRoot 'foreign/iw7-paris-voice.exe'
$rejected=$false; try { Add-IW7ResourceProcess -Token $baseLease.Token -ProcessId 33333 } catch { $rejected=$true }; Assert $rejected 'A different executable remains outside scope.'
$script:fakeProcesses=@($script:fakeProcesses | Where-Object PID -EQ $PID)
Exit-IW7ResourceLease -Token $baseLease.Token
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
Write-Output 'Resource scheduler passed: telemetry-only memory admission, unknown telemetry/identity, idempotency, PID reuse, failure cleanup and real cross-process contention.'
Write-Output "Test evidence retained: $TestRoot"
