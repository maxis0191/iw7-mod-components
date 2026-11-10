param([string]$TestRoot)
# Shareable Runtime leases, admitted by memory (decision 2026-11-10). Same seam as
# resource_scheduler_test.ps1: dot-source Core, then redefine the registry root,
# memory snapshot and process listing. No real registry, process or game is used.
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../../ops/Resource-Scheduler.Core.ps1"
if (!$TestRoot) { $TestRoot=Join-Path ([IO.Path]::GetTempPath()) ('iw7-shareable-tests-'+[guid]::NewGuid().ToString('N')) }
[IO.Directory]::CreateDirectory($TestRoot) | Out-Null
function Get-IW7ResourceRoot { Join-Path $TestRoot 'registry' }
# Synthetic machine: 32 GB total, settable available memory (30 GB by default).
$script:total=32GB; $script:avail=30GB
function Get-IW7ResourceSnapshot { [pscustomobject]@{PhysicalTotal=[long]$script:total;PhysicalAvailable=[long]$script:avail;CommitLimit=96GB;Committed=12GB} }
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
    $script:total=32GB; $script:avail=30GB
    $root=Get-IW7ResourceRoot
    if (Test-Path -LiteralPath $root) { Get-ChildItem -LiteralPath $root -Filter 'leases.json*' | Remove-Item -Force }
}
function Refused([scriptblock]$Body,[string]$Like) {
    try { & $Body | Out-Null } catch { return ($_.Exception.Message -like $Like) }
    return $false
}
function Bench([string]$Name) { Join-Path $TestRoot ('bench-'+$Name) }
function Enter-Share([string]$Name,[switch]$Plain,[long]$Bytes=12GB) {
    Enter-IW7ResourceLease -Scope (Bench $Name) -Kind Runtime -PhysicalBytes $Bytes -CommitBytes $Bytes -Owner ('owner-'+$Name) -Shareable:(!$Plain)
}
$script:nextPid=40000
function New-Proc([string]$Image,[string]$Name,[switch]$Lab,[long]$WorkingSet=4GB) {
    $script:nextPid++
    $p=[pscustomobject]@{PID=$script:nextPid;ParentPID=$PID;CreatedUtc='2026-11-10T10:00:00.0000000Z';Image=$Image;Name=$Name;
        Lab=[bool]$Lab;BaseClientTest=$false;Heavy=($Name -match '^(?:iw7.*|zonetool.*|MSBuild|cl|link|java)\.exe$');WorkingSet=$WorkingSet;PrivateBytes=5GB}
    $script:fakeProcesses+=$p
    $p
}
function Client([string]$Bench,[long]$WorkingSet=4GB) { New-Proc (Join-Path (Bench $Bench) 'iw7-mod.exe') 'iw7-mod.exe' -Lab -WorkingSet $WorkingSet }
function Remove-FakeProcess($Process) { $script:fakeProcesses=@($script:fakeProcesses | Where-Object PID -NE $Process.PID) }
function Leases { @((Read-IW7ResourceState).Leases) }
function LeaseJson($Token) { @(Leases | Where-Object Token -EQ $Token)[0] | ConvertTo-Json -Depth 10 -Compress }

Case 'two shareable admitted' {
    $a=Enter-Share a; $b=Enter-Share b
    Assert ($a.Token -ne $b.Token) 'Two distinct leases expected.'
    $all=Leases
    Assert ($all.Count -eq 2 -and @($all | Where-Object { $_.Shareable -is [bool] -and $_.Shareable }).Count -eq 2) 'Both leases must persist Shareable=true.'
    $status=Get-IW7ResourceStatus
    Assert ($status.ShareableRuntimeLimit -eq 24 -and @($status.Leases | Where-Object Shareable).Count -eq 2) 'Status must show the flag and limit.'
}
Case 'third 12 GB shareable refused by the declared budget' {
    Enter-Share a | Out-Null; Enter-Share b | Out-Null
    Assert (Refused { Enter-Share c } 'Resource busy: shareable declared memory budget exceeded*') 'Third 12 GB session exceeds 32 - 8 = 24 GB.'
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
Case 'a shareable lease may hold several game processes' {
    $a=Enter-Share a
    $first=Client a; $second=Client a; $third=Client a
    Add-IW7ResourceProcess -Token $a.Token -ProcessId $first.PID
    Add-IW7ResourceProcess -Token $a.Token -ProcessId $second.PID
    Add-IW7ResourceProcess -Token $a.Token -ProcessId $third.PID
    Add-IW7ResourceProcess -Token $a.Token -ProcessId $first.PID
    $lease=@(Leases)[0]
    Assert (@($lease.Processes).Count -eq 3 -and $lease.Phase -eq 'Running') 'Server plus clients: all three registered, re-adding one is idempotent.'
    Assert (Refused { Add-IW7ResourceProcess -Token $a.Token -ProcessId (New-Proc 'C:\elsewhere\iw7-mod.exe' 'iw7-mod.exe').PID } 'Runtime child is outside its reserved lab.') 'Other Runtime checks of Add-IW7ResourceProcess remain.'
    Assert (Refused { Add-IW7ResourceProcess -Token $a.Token -ProcessId 999999 } 'Child identity unavailable*') 'Unknown PID still refused.'
}Case 'exclusive Runtime may still hold two clients' {
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
function Set-Reserve($Value) { [Environment]::SetEnvironmentVariable('IW7_SHAREABLE_RESERVE_GB',$Value) }
$script:savedReserve=[Environment]::GetEnvironmentVariable('IW7_SHAREABLE_RESERVE_GB')
try {
Case 'three 2.5 GB sessions admitted where the old rule allowed two' {
    $s=@('a','b','c' | ForEach-Object { Enter-Share $_ -Bytes 2.5GB })
    Assert ($s.Count -eq 3 -and (Leases).Count -eq 3) 'Three small sessions fit.'
    Assert ((Enter-Share d -Bytes 2.5GB).Shareable) 'A fourth fits as well.'
}
Case 'two 10 GB admitted and a third refused by the declared budget' {
    Enter-Share a -Bytes 10GB | Out-Null; Enter-Share b -Bytes 10GB | Out-Null
    $msg=''
    try { Enter-Share c -Bytes 10GB | Out-Null } catch { $msg=$_.Exception.Message }
    Assert ($msg -like 'Resource busy: shareable declared memory budget exceeded: existing shareable leases declare 20.0 GB and this request needs 10.0 GB, above the budget of 24.0 GB (32.0 GB total minus a 8.0 GB reserve).*') "Budget message names the numbers: $msg"
    Assert ((Leases).Count -eq 2) 'Refusal must not add a lease.'
    Assert (Refused { Enter-Share c -Bytes 25GB } 'Resource busy: shareable declared memory budget exceeded*') 'A single session above the budget is refused too.'
}
Case 'measured memory refuses although the declared budget has room' {
    $script:avail=6GB
    $msg=''
    try { Enter-Share a -Bytes 10GB | Out-Null } catch { $msg=$_.Exception.Message }
    Assert ($msg -like 'Resource busy: not enough measured free memory: 6.0 GB available minus 0.0 GB still to be taken by existing shareable sessions leaves 6.0 GB, and this request needs 10.0 GB.*') "Measured message: $msg"
    Assert ((Leases).Count -eq 0) 'Refusal must not add a lease.'
    $script:avail=12GB
    Assert ((Enter-Share a -Bytes 10GB).Shareable) 'Admitted once available memory rises.'
}
Case 'declared but not yet taken memory is reserved' {
    $script:avail=21GB
    Enter-Share a -Bytes 10GB | Out-Null
    Enter-Share b -Bytes 10GB | Out-Null            # 21 - 10 >= 10
    Assert (Refused { Enter-Share c -Bytes 10GB } 'Resource busy: shareable declared memory budget exceeded*') 'Third 10 GB refused (budget).'
    $msg=''
    try { Enter-Share c -Bytes 2.5GB | Out-Null } catch { $msg=$_.Exception.Message }
    Assert ($msg -like 'Resource busy: not enough measured free memory: 21.0 GB available minus 20.0 GB still to be taken by existing shareable sessions leaves 1.0 GB, and this request needs 2.5 GB.*') "Third refused by the not-yet-taken part: $msg"
    Assert ((Leases).Count -eq 2) 'No lease added.'
}
Case 'live processes shrink the reservation of their lease' {
    $script:avail=21GB
    $a=Enter-Share a -Bytes 10GB
    Add-IW7ResourceProcess -Token $a.Token -ProcessId (Client a -WorkingSet 9GB).PID
    Enter-Share b -Bytes 10GB | Out-Null
    $s=Get-IW7ResourceStatus
    Assert ($s.ShareableUnloadedBytes -eq 11GB) 'Reserved but untaken: 1 GB of A (10 declared - 9 taken) + 10 GB of B.'
    Assert ((Enter-Share c -Bytes 2.5GB).Shareable) '21 - 11 = 10 >= 2.5: admitted because A has taken 9 of its 10 GB.'
    # A working set above the declaration never gives a negative reservation.
    $script:fakeProcesses | Where-Object Name -EQ 'iw7-mod.exe' | ForEach-Object { $_.WorkingSet=15GB }
    Assert ((Get-IW7ResourceStatus).ShareableUnloadedBytes -eq 12.5GB) 'Over-taking leaves the lease at zero, not below.'
}
Case 'reserve override by environment variable' {
    Assert ((Get-IW7ShareableReserveBytes) -eq 8GB) 'Default reserve is 8 GB.'
    foreach ($ok in @(@('16',16GB),@('2',2GB),@('64',64GB),@(' 12 ',12GB),@('12.5',12.5GB))) {
        Set-Reserve $ok[0]; Assert ((Get-IW7ShareableReserveBytes) -eq $ok[1]) "Valid value '$($ok[0])' used."
    }
    foreach ($bad in @('1','1.9','65','0','-4','abc','','8,5','NaN','Infinity','1e1','8GB')) {
        Set-Reserve $bad; Assert ((Get-IW7ShareableReserveBytes) -eq 8GB) "Invalid value '$bad' ignored."
    }
    Set-Reserve '16'
    Enter-Share a -Bytes 8GB | Out-Null              # budget 32 - 16 = 16
    Assert (Refused { Enter-Share b -Bytes 8.5GB } 'Resource busy: shareable declared memory budget exceeded*above the budget of 16.0 GB (32.0 GB total minus a 16.0 GB reserve).*') 'Larger reserve shrinks the budget.'
    Assert ((Enter-Share b -Bytes 8GB).Shareable) 'Exactly the budget is admitted.'
    Set-Reserve '2'
    Assert ((Enter-Share c -Bytes 10GB).Shareable) 'Smaller reserve widens it (8+8+10 = 26 <= 30).'
    Set-Reserve $null
    Assert ((Get-IW7ShareableReserveBytes) -eq 8GB) 'Removing the variable restores the default.'
}
Case 'hard cap of 24 leases' {
    Assert ((Get-IW7ShareableRuntimeLeaseLimit) -eq 24) 'Cap is 24.'
    1..24 | ForEach-Object { Enter-Share ('t'+$_) -Bytes 64MB | Out-Null }
    Assert ((Leases).Count -eq 24) 'Twenty-four tiny sessions admitted.'
    $msg=''
    try { Enter-Share t25 -Bytes 64MB | Out-Null } catch { $msg=$_.Exception.Message }
    Assert ($msg -like 'Resource busy: shareable Runtime cap of 24 leases reached; owned by owner-t1, owner-t2, owner-t3, owner-t4, owner-t5 and 19 more.*') "Cap message: $msg"
    Assert ((Enter-Share t7 -Bytes 64MB).Shareable) 'Re-entry of an existing lease at the cap is not refused.'
    Assert ((Leases).Count -eq 24) 'Still 24.'
}
Case 're-entry that would break the budget is refused and leaves the lease unchanged' {
    $a=Enter-Share a -Bytes 10GB; Enter-Share b -Bytes 10GB | Out-Null
    $file=Join-Path (Get-IW7ResourceRoot) 'leases.json'
    $before=(Get-FileHash -LiteralPath $file).Hash; $aBefore=LeaseJson $a.Token
    Assert (Refused { Enter-Share a -Bytes 15GB } 'Resource busy: shareable declared memory budget exceeded*') 'Growth to 15 GB: 10 + 15 > 24.'
    Assert ((Get-FileHash -LiteralPath $file).Hash -eq $before -and (LeaseJson $a.Token) -eq $aBefore) 'Registry file and lease unchanged after refusal.'
    $script:avail=15GB
    Assert (Refused { Enter-Share a -Bytes 12GB } 'Resource busy: not enough measured free memory*') 'Growth refused by measured memory: 15 - 10 (B untaken) < 12.'
    Assert ((Get-FileHash -LiteralPath $file).Hash -eq $before) 'Unchanged after the measured refusal.'
    Assert ((Enter-Share a -Bytes 10GB).Token -eq $a.Token) 'Same size is not refused even with little free memory (the lease already holds it).'
    Assert ((Enter-Share a -Bytes 1GB).PhysicalBytes -eq 10GB) 'A smaller declaration keeps the larger value.'
    $script:avail=30GB
    $grown=Enter-Share a -Bytes 14GB
    Assert ($grown.Token -eq $a.Token -and $grown.PhysicalBytes -eq 14GB -and @(Leases | Where-Object Token -EQ $a.Token)[0].PhysicalBytes -eq 14GB) 'Growth that fits (10 + 14 = 24) is admitted and saved.'
}
Case 're-entry growth counts what the lease has already taken' {
    $script:avail=12GB
    $a=Enter-Share a -Bytes 10GB
    Add-IW7ResourceProcess -Token $a.Token -ProcessId (Client a -WorkingSet 9GB).PID
    Assert ((Enter-Share a -Bytes 14GB).PhysicalBytes -eq 14GB) 'Need is 14 - 9 = 5 GB <= 12 GB available (nothing else reserved).'
}
Case 'another lease whose process is missing from the list is conservative, not an error' {
    $a=Enter-Share a -Bytes 10GB
    $ca=Client a -WorkingSet 9GB
    Add-IW7ResourceProcess -Token $a.Token -ProcessId $ca.PID
    Remove-FakeProcess $ca                      # just exited: registered, not in the list
    $b=Enter-Share b -Bytes 2.5GB
    Assert ($b.Shareable -and (Leases).Count -eq 2) 'Fits conservatively (30 - 10 >= 2.5): admitted, no exception.'
    $script:avail=11GB
    Assert (Refused { Enter-Share c -Bytes 2.5GB } 'Resource busy: not enough measured free memory: 11.0 GB available minus 12.5 GB still to be taken*') 'Does not fit with A and B counted as untaken: Resource busy.'
}
# An unreadable process also has an unreadable command line, so it is not classified as a lab.
function Blind-Process($Process,[string]$Field) { $Process.$Field=$null; $Process.Lab=$false }
foreach ($field in @('Image','CreatedUtc')) {
    Case "another lease whose process identity is unreadable ($field) is conservative, not an error" {
        $a=Enter-Share a -Bytes 10GB
        $ca=Client a -WorkingSet 9GB
        Add-IW7ResourceProcess -Token $a.Token -ProcessId $ca.PID
        Blind-Process $ca $field
        $aBefore=LeaseJson $a.Token
        $b=Enter-Share b -Bytes 2.5GB
        Assert ($b.Shareable -and (Leases).Count -eq 2) 'Fits conservatively (30 - 10 >= 2.5): admitted, no exception.'
        Assert ((LeaseJson $a.Token) -eq $aBefore) 'The unidentifiable lease is retained unchanged.'
        $script:avail=11GB
        Assert (Refused { Enter-Share c -Bytes 2.5GB } 'Resource busy: not enough measured free memory: 11.0 GB available minus 12.5 GB*') 'Does not fit with A and B counted as fully untaken: Resource busy.'
        Assert ((Leases).Count -eq 2) 'Refusal adds nothing.'
        $script:avail=30GB
        # The identity check keeps its force everywhere else.
        Assert (Refused { Enter-Share a -Bytes 10GB } 'Reserved process identity unavailable*') 'Re-entry of the SAME lease still refuses.'
        Assert (Refused { Exit-IW7ResourceLease -Token $a.Token } 'Reserved process identity unavailable*') 'Release still refuses.'
        Assert (Refused { Enter-Share x -Plain -Bytes 1GB } 'Reserved process identity unavailable*') 'An exclusive request keeps the hard identity refusal (strict path unchanged).'
        $status=Get-IW7ResourceStatus
        Assert ($status.ShareableUnloadedBytes -eq 12.5GB) 'Status counts the unreadable lease as fully untaken (conservative), no exception.'
    }
}Case 'exclusive callers ignore the memory rule' {
    $script:avail=1GB
    $x=Enter-Share x -Plain -Bytes 40GB
    Assert ($x.PhysicalBytes -eq 40GB -and !$x.Shareable) 'An exclusive request is admitted as before, whatever the numbers.'
}
Case 'exclusive and shareable still exclude each other' {
    Enter-Share a -Bytes 2GB | Out-Null
    Assert (Refused { Enter-Share x -Plain -Bytes 1GB } 'Resource busy: Runtime owned by owner-a. Continue light work; retry when released.') 'Exclusive refused beside a shareable lease.'
    $s=Read-IW7ResourceState; $s.Leases=@(); Save-IW7ResourceState $s
    Enter-Share x -Plain -Bytes 1GB | Out-Null
    Assert (Refused { Enter-Share a -Bytes 2GB } 'Resource busy: Runtime owned by owner-x.*') 'Shareable refused beside an exclusive lease.'
}
Case 'status reports the shareable numbers' {
    $a=Enter-Share a -Bytes 10GB
    Add-IW7ResourceProcess -Token $a.Token -ProcessId (Client a -WorkingSet 4GB).PID
    Enter-Share b -Bytes 6GB | Out-Null
    $script:avail=17GB
    $s=Get-IW7ResourceStatus
    Assert ($s.ShareableReserveBytes -eq 8GB -and $s.ShareableDeclaredBytes -eq 16GB) 'Reserve and declared total.'
    Assert ($s.ShareableRemainingDeclaredBytes -eq 8GB) 'Remaining declared budget: 24 - 16.'
    Assert ($s.ShareableAvailableBytes -eq 17GB -and $s.ShareableUnloadedBytes -eq 12GB) 'Available 17 GB; untaken 6 (A) + 6 (B).'
    Set-Reserve '30'
    Assert ((Get-IW7ResourceStatus).ShareableRemainingDeclaredBytes -eq 0) 'Remaining never negative.'
    Set-Reserve $null
    $empty=Get-IW7ResourceStatus
    Assert ($empty.Leases.Count -eq 2) 'Status still lists leases.'
}
Case 'status without shareable leases' {
    $s=Get-IW7ResourceStatus
    Assert ($s.ShareableDeclaredBytes -eq 0 -and $s.ShareableRemainingDeclaredBytes -eq 24GB -and $s.ShareableUnloadedBytes -eq 0) 'Empty registry: nothing declared, full budget.'
}
Case 'a Build lease stays exclusive' {
    $build=Enter-IW7ResourceLease -Scope (Bench build) -Kind Build -PhysicalBytes 4GB -CommitBytes 6GB -Owner 'builder'
    Assert (Refused { Enter-Share a -Bytes 1GB } 'Resource busy: Build owned by builder.*') 'Shareable refused beside a Build.'
    Assert (Refused { Enter-IW7ResourceLease -Scope (Bench build2) -Kind Build -PhysicalBytes 4GB -CommitBytes 6GB -Owner 'b2' } 'Resource busy: Build owned by builder.*') 'Second Build refused.'
}
Case 'a legacy lease without the flag stays exclusive' {
    $a=Enter-Share a -Bytes 1GB
    $state=Read-IW7ResourceState
    $state.Leases[0].PSObject.Properties.Remove('Shareable'); $state.Leases[0].Owner='legacy'
    Save-IW7ResourceState $state
    Assert (Refused { Enter-Share b -Bytes 1GB } 'Resource busy: Runtime owned by legacy.*') 'Legacy lease blocks a shareable request.'
    $s=Get-IW7ResourceStatus
    Assert ($s.ShareableDeclaredBytes -eq 0) 'A legacy lease is not counted as shareable.'
}
} finally { Set-Reserve $script:savedReserve }Reset-Registry
Write-Output ("PASS $script:cases shareable-runtime cases / $script:checks assertions; temporary registry and synthetic process list only.")
Write-Output "Test evidence retained: $TestRoot"
