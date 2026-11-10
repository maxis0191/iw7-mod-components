param([string]$TestRoot)
# Shareable Runtime leases (decision 2026-11-10). Same seam as
# resource_scheduler_test.ps1: dot-source Core, then redefine the registry root,
# memory snapshot and process listing. No real registry, process or game is used.
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../../ops/Resource-Scheduler.Core.ps1"
if (!$TestRoot) { $TestRoot=Join-Path ([IO.Path]::GetTempPath()) ('iw7-shareable-tests-'+[guid]::NewGuid().ToString('N')) }
[IO.Directory]::CreateDirectory($TestRoot) | Out-Null
function Get-IW7ResourceRoot { Join-Path $TestRoot 'registry' }
function Get-IW7ResourceSnapshot { [pscustomobject]@{PhysicalTotal=32GB;PhysicalAvailable=20GB;CommitLimit=48GB;Committed=12GB} }
$self=Get-Process -Id $PID
$script:launcher=[pscustomobject]@{PID=$PID;ParentPID=0;CreatedUtc=$self.StartTime.ToUniversalTime().ToString('o');Image=$self.Path;
    Name='pwsh.exe';Lab=$false;BaseClientTest=$false;Heavy=$false;WorkingSet=100MB;PrivateBytes=100MB}
$script:fakeProcesses=@($script:launcher)
function Get-IW7ResourceProcesses { $script:fakeProcesses }
if ((Get-IW7ResourceRoot) -eq (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'IW7Paris/ResourceScheduler')) { throw 'Test seam failed: live registry selected.' }

$script:checks=0; $script:cases=0
function Assert($Value,[string]$Message) { $script:checks++; if (!$Value) { throw $Message } }
function Case([string]$Name,[scriptblock]$Body) {
    $script:cases++
    Reset-Registry
    try { & $Body } catch { throw "Case '$Name' failed: $($_.Exception.Message)" }
}
function Reset-Registry {
    $script:fakeProcesses=@($script:launcher)
    $root=Get-IW7ResourceRoot
    if (Test-Path -LiteralPath $root) { Get-ChildItem -LiteralPath $root -Filter 'leases.json*' | Remove-Item -Force }
}
function Refused([scriptblock]$Body,[string]$Like) {
    try { & $Body | Out-Null } catch { return ($_.Exception.Message -like $Like) }
    return $false
}
function Bench([string]$Name) { Join-Path $TestRoot ('bench-'+$Name) }
function Enter-Share([string]$Name,[switch]$Plain) {
    Enter-IW7ResourceLease -Scope (Bench $Name) -Kind Runtime -PhysicalBytes 12GB -CommitBytes 12GB -Owner ('owner-'+$Name) -Shareable:(!$Plain)
}
$script:nextPid=40000
function New-Proc([string]$Image,[string]$Name,[switch]$Lab) {
    $script:nextPid++
    $p=[pscustomobject]@{PID=$script:nextPid;ParentPID=$PID;CreatedUtc='2026-11-10T10:00:00.0000000Z';Image=$Image;Name=$Name;
        Lab=[bool]$Lab;BaseClientTest=$false;Heavy=($Name -match '^(?:iw7.*|zonetool.*|MSBuild|cl|link|java)\.exe$');WorkingSet=4GB;PrivateBytes=5GB}
    $script:fakeProcesses+=$p
    $p
}
function Client([string]$Bench) { New-Proc (Join-Path (Bench $Bench) 'iw7-mod.exe') 'iw7-mod.exe' -Lab }
function Remove-FakeProcess($Process) { $script:fakeProcesses=@($script:fakeProcesses | Where-Object PID -NE $Process.PID) }
function Leases { @((Read-IW7ResourceState).Leases) }
function LeaseJson($Token) { @(Leases | Where-Object Token -EQ $Token)[0] | ConvertTo-Json -Depth 10 -Compress }

Case 'two shareable admitted' {
    $a=Enter-Share a; $b=Enter-Share b
    Assert ($a.Token -ne $b.Token) 'Two distinct leases expected.'
    $all=Leases
    Assert ($all.Count -eq 2 -and @($all | Where-Object { $_.Shareable -is [bool] -and $_.Shareable }).Count -eq 2) 'Both leases must persist Shareable=true.'
    $status=Get-IW7ResourceStatus
    Assert ($status.ShareableRuntimeLimit -eq 2 -and @($status.Leases | Where-Object Shareable).Count -eq 2) 'Status must show the flag and limit.'
}
Case 'third shareable refused at the limit' {
    Enter-Share a | Out-Null; Enter-Share b | Out-Null
    Assert (Refused { Enter-Share c } 'Resource busy: shareable Runtime limit of 2 reached; owned by owner-a, owner-b*') 'Third shareable must hit the limit message naming owners.'
    Assert ((Leases).Count -eq 2) 'Refusal must not add a lease.'
}
Case 'shareable refused beside exclusive Runtime' {
    Enter-Share x -Plain | Out-Null
    Assert (Refused { Enter-Share a } 'Resource busy: Runtime owned by owner-x.*') 'Shareable must not join an exclusive Runtime lease.'
}
Case 'exclusive Runtime refused beside shareable' {
    Enter-Share a | Out-Null
    Assert (Refused { Enter-Share x -Plain } 'Resource busy: Runtime owned by owner-a. Continue light work; retry when released.') 'Exclusive request keeps the old message shape.'
}
Case 'Build and shareable exclude each other' {
    $build=Enter-IW7ResourceLease -Scope (Bench build) -Kind Build -PhysicalBytes 4GB -CommitBytes 6GB -Owner 'builder'
    Assert (Refused { Enter-Share a } 'Resource busy: Build owned by builder.*') 'Shareable refused while a Build lease exists.'
    Exit-IW7ResourceLease -Token $build.Token
    Enter-Share a | Out-Null
    Assert (Refused { Enter-IW7ResourceLease -Scope (Bench build) -Kind Build -PhysicalBytes 4GB -CommitBytes 6GB -Owner 'builder' } 'Resource busy: Runtime owned by owner-a.*') 'Build refused while a shareable lease exists.'
}
Case 'invalid Shareable declarations' {
    Assert (Refused { Enter-IW7ResourceLease -Scope (Bench a) -Kind Build -PhysicalBytes 4GB -CommitBytes 6GB -Owner 'b' -Shareable } 'Shareable is only valid*') 'Shareable Build refused.'
    Assert (Refused { Enter-IW7ResourceLease -Scope (Bench a) -Kind Runtime -PhysicalBytes 4GB -CommitBytes 6GB -Owner 'b' -Shareable -BaseClientImage (Join-Path $TestRoot 'base/iw7-mod.exe') } 'Shareable is only valid*') 'Shareable base client refused.'
    Assert ((Leases).Count -eq 0) 'No lease from an invalid declaration.'
}
Case 're-entry cannot change the flag' {
    $a=Enter-Share a
    Assert (Refused { Enter-Share a -Plain } 'Shareable declaration cannot change*') 'Shareable lease re-entered as exclusive.'
    $again=Enter-Share a
    Assert ($again.Token -eq $a.Token -and $again.Shareable) 'Shareable re-entry keeps its token and flag.'
    Exit-IW7ResourceLease -Token $a.Token
    $x=Enter-Share x -Plain
    Assert (Refused { Enter-Share x } 'Shareable declaration cannot change*') 'Exclusive lease re-entered as shareable.'
    Assert ((Enter-Share x -Plain).Token -eq $x.Token) 'Exclusive re-entry unchanged.'
}
Case 're-entry beside another shareable lease' {
    $a=Enter-Share a; Enter-Share b | Out-Null
    Assert ((Enter-Share a).Token -eq $a.Token) 'Re-entry of one of two shareable leases must be admitted.'
}
Case 'overlapping bench scopes refused' {
    Enter-Share a | Out-Null
    Assert (Refused { Enter-IW7ResourceLease -Scope (Join-Path (Bench a) 'sub') -Kind Runtime -PhysicalBytes 1GB -CommitBytes 1GB -Owner 'nested' -Shareable } 'Resource busy: shareable Runtime scope overlaps*') 'Nested scope refused.'
}
Case 'lab of another shareable lease is not foreign' {
    $a=Enter-Share a
    $client=Client a
    Add-IW7ResourceProcess -Token $a.Token -ProcessId $client.PID
    $b=Enter-Share b
    Assert ($b.Shareable) 'Shareable request admitted beside a running shareable lab.'
    Exit-IW7ResourceLease -Token $b.Token
    Assert (Refused { Enter-Share x -Plain } 'Resource busy:*') 'Exclusive request still refused.'
    # Without any lease, the same running lab is unreserved for everyone.
    $state=Read-IW7ResourceState; $state.Leases=@(); Save-IW7ResourceState $state
    Assert (Refused { Enter-Share b } 'An unreserved or foreign laboratory*') 'Uncovered lab must be foreign for a shareable request.'
    Assert (Refused { Enter-Share x -Plain } 'An unreserved or foreign laboratory*') 'Uncovered lab must be foreign for an exclusive request.'
}
Case 'uncovered lab still refuses shareable admission' {
    $a=Enter-Share a
    Add-IW7ResourceProcess -Token $a.Token -ProcessId (Client a).PID
    New-Proc 'C:\foreign\iw7-paris-lab.exe' 'iw7-paris-lab.exe' -Lab | Out-Null
    Assert (Refused { Enter-Share b } 'An unreserved or foreign laboratory*') 'Foreign lab outside every scope refuses.'
}
Case 'unreserved lab in the requested bench still refuses' {
    Enter-Share a | Out-Null
    Client b | Out-Null
    Assert (Refused { Enter-Share b } 'Existing lab has no reservation*') 'An unreserved lab in the new bench must refuse first admission.'
}
Case 'builders refuse shareable requests' {
    Enter-Share a | Out-Null
    New-Proc 'C:\tools\MSBuild.exe' 'MSBuild.exe' | Out-Null
    Assert (Refused { Enter-Share b } 'An existing compiler/extractor/Java analysis is running*') 'Running builder refuses shareable.'
}
Case 'one game client per shareable lease' {
    $a=Enter-Share a
    $first=Client a; $second=Client a
    Add-IW7ResourceProcess -Token $a.Token -ProcessId $first.PID
    Assert (Refused { Add-IW7ResourceProcess -Token $a.Token -ProcessId $second.PID } 'A shareable Runtime lease holds one game client*') 'Second live client refused.'
    $lease=@(Leases)[0]
    Assert (@($lease.Processes).Count -eq 1 -and $lease.Processes[0].PID -eq $first.PID) 'First client stays registered.'
    Add-IW7ResourceProcess -Token $a.Token -ProcessId $first.PID
    Remove-FakeProcess $first
    Add-IW7ResourceProcess -Token $a.Token -ProcessId $second.PID
    Assert (@(@(Leases)[0].Processes | Where-Object PID -EQ $second.PID).Count -eq 1) 'Client allowed after the first died.'
}
Case 'exclusive Runtime may still hold two clients' {
    $x=Enter-Share x -Plain
    Add-IW7ResourceProcess -Token $x.Token -ProcessId (Client x).PID
    Add-IW7ResourceProcess -Token $x.Token -ProcessId (Client x).PID
    Assert (@(@(Leases)[0].Processes).Count -eq 2) 'Exclusive lease unchanged.'
}
Case 'releasing one lease leaves the other intact' {
    $a=Enter-Share a; $b=Enter-Share b
    $ca=Client a; $cb=Client b
    Add-IW7ResourceProcess -Token $a.Token -ProcessId $ca.PID
    Add-IW7ResourceProcess -Token $b.Token -ProcessId $cb.PID
    $bBefore=LeaseJson $b.Token
    Assert (Refused { Exit-IW7ResourceLease -Token $a.Token } 'Reserved child is still alive*') 'Live client retains A.'
    Remove-FakeProcess $ca
    Exit-IW7ResourceLease -Token $a.Token
    Assert ((Leases).Count -eq 1 -and (LeaseJson $b.Token) -eq $bBefore) 'B unchanged while its client lives and A is released.'
    $a=Enter-Share a
    $ca=Client a
    Add-IW7ResourceProcess -Token $a.Token -ProcessId $ca.PID
    $aBefore=LeaseJson $a.Token
    Remove-FakeProcess $cb
    Exit-IW7ResourceLease -Token $b.Token
    Assert ((Leases).Count -eq 1 -and (LeaseJson $a.Token) -eq $aBefore) 'A unchanged while its client lives and B is released.'
}
Case 'finished cleanup removes only the finished lease' {
    $a=Enter-Share a; $b=Enter-Share b
    Add-IW7ResourceProcess -Token $b.Token -ProcessId (Client b).PID
    $state=Read-IW7ResourceState
    $dead=@($state.Leases | Where-Object Token -EQ $a.Token)[0]
    $dead.OwnerIdentity=[pscustomobject]@{PID=999999;Image='C:\gone\pwsh.exe';CreatedUtc='2026-11-01T00:00:00.0000000Z'}
    $live=@($state.Leases | Where-Object Token -EQ $b.Token)[0]
    $live.OwnerIdentity=[pscustomobject]@{PID=999998;Image='C:\gone\pwsh.exe';CreatedUtc='2026-11-01T00:00:00.0000000Z'}
    Save-IW7ResourceState $state
    $bBefore=LeaseJson $b.Token
    $state=Read-IW7ResourceState
    Remove-IW7FinishedRuntimeLeases $state $script:fakeProcesses
    Assert (@($state.Leases).Count -eq 1 -and $state.Leases[0].Token -eq $b.Token) 'Only A (no owner, no process) is finished; B keeps a live client.'
    $c=Enter-Share c
    $tokens=@(Leases | ForEach-Object Token)
    Assert ($tokens.Count -eq 2 -and $tokens -contains $b.Token -and $tokens -contains $c.Token -and (LeaseJson $b.Token) -eq $bBefore) 'Admission reclaims only A and leaves B intact.'
}
Case 'legacy and malformed flags are exclusive' {
    $a=Enter-Share a
    $state=Read-IW7ResourceState
    $state.Leases[0].PSObject.Properties.Remove('Shareable')
    $state.Leases[0].Owner='legacy'
    Save-IW7ResourceState $state
    Assert (Refused { Enter-Share b } 'Resource busy: Runtime owned by legacy.*') 'Lease without the property is exclusive.'
    Assert ((Get-IW7ResourceStatus).Leases[0].Shareable -eq $false) 'Status shows a legacy lease as not shareable.'
    Assert (!(Read-IW7ResourceState).Leases[0].PSObject.Properties['Shareable']) 'Status must not write the display flag.'
    $state=Read-IW7ResourceState
    Add-Member -InputObject $state.Leases[0] -NotePropertyName Shareable -NotePropertyValue 'true'
    Save-IW7ResourceState $state
    Assert (Refused { Enter-Share b } 'Resource busy:*') 'A string flag is exclusive.'
    $state=Read-IW7ResourceState
    $state.Leases[0].Shareable=$true; $state.Leases[0].Kind='Analysis'
    Save-IW7ResourceState $state
    Assert (Refused { Enter-Share b } 'Resource busy: Analysis owned by legacy.*') 'A flag on a non-Runtime lease is exclusive.'
}
Case 'older read-modify-write keeps the flag' {
    $a=Enter-Share a
    # The reader/writer pair is unchanged from older copies: ConvertFrom-Json, then ConvertTo-Json -Depth 10.
    $state=Read-IW7ResourceState
    $state.Leases[0].Phase='Running'
    Save-IW7ResourceState $state
    $raw=Get-Content -LiteralPath (Join-Path (Get-IW7ResourceRoot) 'leases.json') -Raw | ConvertFrom-Json
    Assert ($raw.Leases[0].Shareable -is [bool] -and $raw.Leases[0].Shareable) 'Unknown property survives a read-modify-write.'
}
Case 'exclusive callers unchanged when alone' {
    $x=Enter-Share x -Plain
    Assert ($x.Shareable -is [bool] -and !$x.Shareable) 'New exclusive lease records Shareable=false.'
    Assert (Refused { Enter-IW7ResourceLease -Scope (Bench y) -Kind Runtime -PhysicalBytes 1GB -CommitBytes 1GB -Owner 'y' } 'Resource busy: Runtime owned by owner-x.*') 'Second exclusive refused as before.'
}
Reset-Registry
Write-Output ("PASS $script:cases shareable-runtime cases / $script:checks assertions; temporary registry and synthetic process list only.")
Write-Output "Test evidence retained: $TestRoot"
