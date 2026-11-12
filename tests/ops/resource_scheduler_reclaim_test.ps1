param([string]$TestRoot)
# Reclaim of finished Runtime leases (12 Nov 2026). Temporary registry, synthetic processes and clock: a lease whose
# owner and children are gone is reclaimed and saved even when the asking request is refused; a lease whose owner
# lives but whose registered children are gone is reclaimed after ChildlessSeconds; live leases are never touched.
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../../ops/Resource-Scheduler.Core.ps1"
if (!$TestRoot) { $TestRoot=Join-Path ([IO.Path]::GetTempPath()) ('iw7-reclaim-tests-'+[guid]::NewGuid().ToString('N')) }
[IO.Directory]::CreateDirectory($TestRoot) | Out-Null
function Get-IW7ResourceRoot { Join-Path $TestRoot 'registry' }
if ((Get-IW7ResourceRoot) -eq (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'IW7Paris/ResourceScheduler')) { throw 'Test seam failed: live registry selected.' }
[IO.Directory]::CreateDirectory((Get-IW7ResourceRoot)) | Out-Null
function Get-IW7ResourceSnapshot { [pscustomobject]@{PhysicalTotal=32GB;PhysicalAvailable=20GB;CommitLimit=96GB;Committed=12GB} }
$script:clock=[datetime]::SpecifyKind([datetime]'2026-11-12T02:00:00','Utc')
function Get-IW7SchedulerUtcNow { $script:clock }
function Advance([double]$Seconds) { $script:clock=$script:clock.AddSeconds($Seconds) }
$self=Get-Process -Id $PID
$script:me=[pscustomobject]@{PID=$PID;ParentPID=0;CreatedUtc=$self.StartTime.ToUniversalTime().ToString('o');Image=$self.Path;
    Name='pwsh.exe';Lab=$false;BaseClientTest=$false;Heavy=$false;WorkingSet=100MB;PrivateBytes=100MB}
$script:processes=@($script:me)
function Get-IW7ResourceProcesses { $script:processes }
$script:checks=0; $script:cases=0
function Assert($Value,[string]$Message) { $script:checks++; if (!$Value) { throw $Message } }
function Case([string]$Name,[scriptblock]$Body) {
    $script:cases++
    $script:processes=@($script:me)
    Get-ChildItem -LiteralPath (Get-IW7ResourceRoot) | Where-Object Name -match '^(?:leases|queue)\.json|^admission-log' | Remove-Item -Force
    try { & $Body } catch { throw "Case '$Name' failed: $($_.Exception.Message)" }
}
function Proc([int]$Id,[string]$Image) {
    [pscustomobject]@{PID=$Id;ParentPID=0;CreatedUtc='2026-11-12T01:50:00.0000000Z';Image=$Image;Name=[IO.Path]::GetFileName($Image);
        Lab=$false;BaseClientTest=$false;Heavy=$false;WorkingSet=500MB;PrivateBytes=500MB}
}
# A shareable Runtime lease as a runner leaves it: owner pwsh, one registered server child in its bench.
function Lease([string]$Name,$Owner,$Child) {
    $scope=(Join-Path $TestRoot "bench-$Name").ToLowerInvariant()
    [pscustomobject]@{Token=([guid]::NewGuid().ToString('N'));Scope=$scope;Kind='Runtime';Owner=$Name;
        OwnerIdentity=[pscustomobject]@{PID=$Owner.PID;CreatedUtc=$Owner.CreatedUtc;Image=$Owner.Image};
        CreatedUtc='2026-11-12T01:53:33.0000000Z';Phase='Running';PhysicalBytes=1.5GB;CommitBytes=2GB;BaseClientImage=$null;Shareable=$true;
        Processes=@([pscustomobject]@{PID=$Child.PID;CreatedUtc=$Child.CreatedUtc;Image=$Child.Image})}
}
function Save([object[]]$Leases) { Save-IW7ResourceState ([pscustomobject]@{Version=1;Leases=@($Leases)}) }
function Owners { @((Read-IW7ResourceState).Leases | ForEach-Object Owner) }
function Reclaims { $p=Get-IW7AdmissionLogPath; if (!(Test-Path $p)) { return @() }; @(Get-Content $p | ConvertFrom-Json | Where-Object Event -eq 'reclaim') }
function Ask([string]$Kind='Build') {
    try { $l=Enter-IW7ResourceLease -Scope (Join-Path $TestRoot "ask-$Kind") -Kind $Kind -PhysicalBytes 1GB -CommitBytes 1GB -Owner "ask $Kind"; Exit-IW7ResourceLease -Token $l.Token; 'granted' }
    catch { $_.Exception.Message }
}

Case 'a dead lease is reclaimed and saved even when the request is refused for another lease' {
    $deadOwner=Proc 70001 'C:\fake\pwsh.exe'; $deadChild=Proc 70002 (Join-Path $TestRoot 'bench-vc\server\iw7.exe')
    $liveOwner=Proc 70011 'C:\fake\pwsh.exe'; $liveChild=Proc 70012 (Join-Path $TestRoot 'bench-glh\server\iw7.exe')
    Save @((Lease 'vc' $deadOwner $deadChild),(Lease 'glh' $liveOwner $liveChild))
    $script:processes=@($script:me,$liveOwner,$liveChild)
    $r=Ask
    Assert ($r -like 'Resource busy: Runtime owned by glh*') "Wrong refusal: $r"
    Assert ((Owners) -join ',' -eq 'glh') "Dead lease not saved as reclaimed: $((Owners) -join ',')"
    $rows=@(Reclaims)
    Assert ($rows.Count -eq 1 -and $rows[0].Owner -eq 'vc' -and $rows[0].Why -like '*owner process and every registered child are gone*') 'Reclaim not logged.'
}
Case 'a lease whose owner lives and whose child runs is never reclaimed' {
    $o=Proc 70021 'C:\fake\pwsh.exe'; $c=Proc 70022 (Join-Path $TestRoot 'bench-a\server\iw7.exe')
    Save @(Lease 'a' $o $c); $script:processes=@($script:me,$o,$c)
    foreach ($i in 1..3) { $null=Ask; Advance 900 }
    Assert ((Owners) -join ',' -eq 'a') 'A live session was reclaimed.'
    Assert (!(Read-IW7ResourceState).Leases[0].PSObject.Properties['ChildlessSinceUtc']) 'A live session was marked childless.'
}
Case 'owner alive, child gone: marked, kept for 600 s, then reclaimed and the build is granted' {
    $o=Proc 70031 'C:\fake\pwsh.exe'; $c=Proc 70032 (Join-Path $TestRoot 'bench-b\server\iw7.exe')
    Save @(Lease 'b' $o $c); $script:processes=@($script:me,$o)
    $r=Ask
    Assert ($r -like 'Resource busy: Runtime owned by b*') "Childless lease released at once: $r"
    Assert ((Read-IW7ResourceState).Leases[0].ChildlessSinceUtc) 'Childless time not saved on refusal.'
    Advance 599; $r=Ask
    Assert ($r -like 'Resource busy: Runtime owned by b*') "Released before 600 s: $r"
    Advance 2; $r=Ask
    Assert ($r -eq 'granted') "Not reclaimed after 600 s: $r"
    $rows=@(Reclaims)
    Assert ($rows.Count -eq 1 -and $rows[0].Owner -eq 'b' -and $rows[0].Why -like '*owner is alive*10m01s*') "Reclaim not logged: $($rows.Why)"
}
Case 'a child back within the grace clears the mark' {
    $o=Proc 70041 'C:\fake\pwsh.exe'; $c=Proc 70042 (Join-Path $TestRoot 'bench-c\server\iw7.exe')
    Save @(Lease 'c' $o $c); $script:processes=@($script:me,$o)
    $null=Ask; Advance 300
    $script:processes=@($script:me,$o,(Proc 70043 (Join-Path $TestRoot 'bench-c\server\iw7.exe')))
    $null=Ask
    Assert (!(Read-IW7ResourceState).Leases[0].PSObject.Properties['ChildlessSinceUtc']) 'A process in scope did not clear the mark.'
    $script:processes=@($script:me,$o); Advance 400; $r=Ask
    Assert ($r -like 'Resource busy: Runtime owned by c*') "Grace not restarted: $r"
}
Case 'a pending lease (no child yet) is never reclaimed while its owner lives' {
    $o=Proc 70051 'C:\fake\pwsh.exe'; $c=Proc 70052 (Join-Path $TestRoot 'bench-d\server\iw7.exe')
    $l=Lease 'd' $o $c; $l.Phase='Pending'; $l.Processes=@()
    Save @($l); $script:processes=@($script:me,$o)
    foreach ($i in 1..3) { $null=Ask; Advance 900 }
    Assert ((Owners) -join ',' -eq 'd') 'A pending lease was reclaimed.'
}
Case 'a build lease is never reclaimed by these rules' {
    $o=Proc 70061 'C:\fake\pwsh.exe'
    $l=[pscustomobject]@{Token=([guid]::NewGuid().ToString('N'));Scope=(Join-Path $TestRoot 'bench-e').ToLowerInvariant();Kind='Build';Owner='e';
        OwnerIdentity=[pscustomobject]@{PID=$o.PID;CreatedUtc=$o.CreatedUtc;Image=$o.Image};CreatedUtc='2026-11-12T01:53:33.0000000Z';Phase='Pending';
        PhysicalBytes=4GB;CommitBytes=6GB;BaseClientImage=$null;Shareable=$false;Processes=@()}
    Save @($l); $script:processes=@($script:me)
    $null=Ask Runtime; Advance 900; $null=Ask Runtime
    Assert ((Owners) -join ',' -eq 'e') 'A build lease was reclaimed.'
}
Write-Output ("PASS $script:cases reclaim cases / $script:checks assertions; temporary registry, synthetic processes and clock.")
Remove-Item -LiteralPath $TestRoot -Recurse -Force -ErrorAction SilentlyContinue
