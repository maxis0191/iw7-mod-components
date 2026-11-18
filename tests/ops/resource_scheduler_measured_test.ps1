param([string]$TestRoot)
# Measured budgets (18 Nov 2026): a lease that has run past its load phase is counted at its measured peak plus a margin,
# not at what it declared. Same seam as resource_scheduler_shareable_test.ps1: dot-source Core, redefine the registry root,
# the memory snapshot and the process list. No real registry, process or game.
$ErrorActionPreference='Stop'
$env:IW7_SHAREABLE_FLOOR_GB='2'
Remove-Item Env:IW7_SCHEDULER_MEASURED -ErrorAction SilentlyContinue
. "$PSScriptRoot/../../ops/Resource-Scheduler.Core.ps1"
if (!$TestRoot) { $TestRoot=Join-Path ([IO.Path]::GetTempPath()) ('iw7-measured-tests-'+[guid]::NewGuid().ToString('N')) }
[IO.Directory]::CreateDirectory($TestRoot) | Out-Null
function Get-IW7ResourceRoot { Join-Path $TestRoot 'registry' }
$script:total=32GB; $script:avail=30GB
function Get-IW7ResourceSnapshot { [pscustomobject]@{PhysicalTotal=[long]$script:total;PhysicalAvailable=[long]$script:avail;CommitLimit=96GB;Committed=12GB} }
$self=Get-Process -Id $PID
$script:launcher=[pscustomobject]@{PID=$PID;ParentPID=0;CreatedUtc=$self.StartTime.ToUniversalTime().ToString('o');Image=$self.Path;Name='pwsh.exe';Lab=$false;BaseClientTest=$false;Heavy=$false;WorkingSet=100MB;PrivateBytes=100MB}
$script:fakeProcesses=@($script:launcher)
function Get-IW7ResourceProcesses { $script:fakeProcesses }
if ((Get-IW7ResourceRoot) -eq (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'IW7Paris/ResourceScheduler')) { throw 'Test seam failed: live registry selected.' }
$script:checks=0
function Assert($Value,[string]$Message) { $script:checks++; if (!$Value) { throw $Message } }
function Refused([scriptblock]$Body,[string]$Like) { try { & $Body | Out-Null } catch { return ($_.Exception.Message -like $Like) }; $false }
function Reset { $script:fakeProcesses=@($script:launcher); $r=Get-IW7ResourceRoot; if (Test-Path $r) { Get-ChildItem $r | Remove-Item -Force -Recurse } }
function Bench([string]$N) { Join-Path $TestRoot ('bench-'+$N) }
$script:nextPid=50000
function New-Proc([string]$Image,[long]$WorkingSet) {
    $script:nextPid++
    $p=[pscustomobject]@{PID=$script:nextPid;ParentPID=$PID;CreatedUtc='2026-11-10T10:00:00.0000000Z';Image=$Image;Name='iw7-mod.exe';Lab=$true;BaseClientTest=$false;Heavy=$true;WorkingSet=$WorkingSet;PrivateBytes=5GB}
    $script:fakeProcesses+=$p; $p
}
function Age-Lease([string]$Token,[int]$Seconds) {
    $s=Read-IW7ResourceState
    foreach ($l in @($s.Leases)) { if ($l.Token -eq $Token) { $l.CreatedUtc=([datetime]::UtcNow.AddSeconds(-$Seconds)).ToString('o') } }
    Save-IW7ResourceState $s
}
function Plan { $s=Read-IW7ResourceState; Get-IW7ShareableMemoryPlan (Get-IW7ResourceSnapshot) @($s.Leases) $script:fakeProcesses -RecordPeaks }

# 1. A session that declared 8 GB and took 5 GB, in its load phase: the 3 GB it has not taken stay promised.
Reset
$a=Enter-IW7ResourceLease -Scope (Bench a) -Kind Runtime -PhysicalBytes 8GB -CommitBytes 8GB -Owner 'client session' -Shareable
$p=New-Proc (Join-Path (Bench a) 'iw7-mod.exe') 5GB
Add-IW7ResourceProcess -Token $a.Token -ProcessId $p.PID
$script:avail=8.5GB   # the machine as the build of 18 Nov saw it
$plan=Plan
Assert ($plan.Unloaded -eq 3GB -and $plan.Declared -eq 8GB) "load phase: unloaded $($plan.Unloaded), declared $($plan.Declared)"
Assert (Refused { Enter-IW7ResourceLease -Scope (Bench b) -Kind Runtime -PhysicalBytes 4GB -CommitBytes 4GB -Owner 'headless' -Shareable } 'Resource busy: not enough measured free memory*') 'a 4 GB request must wait while 3 GB are promised'

# 2. The same session after its load phase, flat at 5 GB: counted at 5 * 1.15 + 0.25 = 6.0 GB, so 1 GB is promised.
Age-Lease $a.Token 600
$plan=Plan
$expect=[long](5GB*1.15)+256MB
Assert ($plan.Declared -eq $expect -and $plan.Unloaded -eq ($expect-5GB)) "settled: declared $($plan.Declared) unloaded $($plan.Unloaded) expected $expect"
$b=Enter-IW7ResourceLease -Scope (Bench b) -Kind Runtime -PhysicalBytes 4GB -CommitBytes 4GB -Owner 'headless' -Shareable
Assert ($b.Token) 'the 4 GB request must be admitted once the session has settled'

# 3. The session grows to 7.5 GB: counted at its new peak, never above its declaration.
$p.WorkingSet=[long]7.5GB
$plan=Plan
Assert ($plan.Declared -le (8GB+4GB)) 'declared stays within the declarations'
$peaks=Read-IW7LeasePeaks
Assert ($peaks[[string]$a.Token] -eq [long]7.5GB) ("the peak of the lease is recorded: $($peaks | ConvertTo-Json -Compress) wanted $([long]7.5GB); plan $($plan | ConvertTo-Json -Compress)")
$p.WorkingSet=3GB
$plan=Plan
$peaks=Read-IW7LeasePeaks
Assert ($peaks[[string]$a.Token] -eq [long]7.5GB) 'a peak never goes down while the lease lives'

# 4. The release line carries the measured peak next to the declaration.
$script:fakeProcesses=@($script:launcher)
Exit-IW7ResourceLease -Token $a.Token
$last=@(Get-Content (Get-IW7AdmissionLogPath) | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.Event -eq 'release' -and $_.Owner -eq 'client session' })[-1]
Assert ($last.PeakWorkingSet -eq [long]7.5GB -and $last.Declared -eq 8GB) "release line: peak $($last.PeakWorkingSet) declared $($last.Declared)"
Assert (!(Read-IW7LeasePeaks).ContainsKey([string]$a.Token)) 'the peak of a released lease is forgotten'

# 5. IW7_SCHEDULER_MEASURED=0 is the old rule.
$env:IW7_SCHEDULER_MEASURED='0'
$s=Read-IW7ResourceState
$plan=Get-IW7ShareableMemoryPlan (Get-IW7ResourceSnapshot) @($s.Leases) $script:fakeProcesses
Assert ($plan.Declared -eq 4GB) 'switched off: every lease counts what it declared'
Remove-Item Env:IW7_SCHEDULER_MEASURED
Write-Output "PASS measured budgets: $($script:checks) assertions; temporary registry and synthetic processes only."
