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
Case 'an old-core Runtime lease (no Shareable, no Resources: holds machine) is reclaimed by both rules' {
    $o=Proc 70071 'C:\fake\pwsh.exe'; $c=Proc 70072 (Join-Path $TestRoot 'bench-f\server\iw7.exe')
    $l=Lease 'f' $o $c; $l.PSObject.Properties.Remove('Shareable'); $l.PSObject.Properties.Remove('BaseClientImage')
    Assert ((Get-IW7HeldResources $l) -join ',' -eq 'machine') 'The old-core lease does not hold machine.'
    Save @($l); $script:processes=@($script:me,$o)
    $r=Ask
    Assert ($r -like 'Resource busy:*') "An old-core machine lease with its owner alive was released at once: $r"
    Advance 601; $r=Ask
    Assert ($r -eq 'granted') "Old-core childless machine lease not reclaimed after 600 s: $r"
    $o2=Proc 70073 'C:\fake\pwsh.exe'; $c2=Proc 70074 (Join-Path $TestRoot 'bench-g\server\iw7.exe')
    $l2=Lease 'g' $o2 $c2; $l2.PSObject.Properties.Remove('Shareable'); $l2.PSObject.Properties.Remove('BaseClientImage')
    Save @($l2); $script:processes=@($script:me)
    $r=Ask
    Assert ($r -eq 'granted') "Old-core machine lease with owner and child gone not reclaimed at once: $r"
}
# A Build lease as the real orphan of 18 Nov 2026 was: pending, no processes, 4 GB, exclusive, one named resource.
function BuildLease([string]$Name,$Owner) {
    [pscustomobject]@{Token=([guid]::NewGuid().ToString('N'));Scope=(Join-Path $TestRoot "bench-$Name").ToLowerInvariant();Kind='Build';Owner='IW7 native build and checks';
        OwnerIdentity=[pscustomobject]@{PID=$Owner.PID;CreatedUtc=$Owner.CreatedUtc;Image=$Owner.Image};CreatedUtc='2026-11-12T01:53:33.0000000Z';Phase='Pending';
        PhysicalBytes=4GB;CommitBytes=6GB;BaseClientImage=$null;Shareable=$false;Resources=@("work:$Name");Processes=@()}
}
function Stamp { $l=@((Read-IW7ResourceState).Leases); if ($l.Count -and $l[0].PSObject.Properties['OwnerGoneSinceUtc']) { $l[0].OwnerGoneSinceUtc } else { $null } }
Case 'a build lease whose owner is gone is kept for OrphanSeconds, then reclaimed and logged' {
    $o=Proc 70061 'C:\fake\pwsh.exe'
    Save @(BuildLease 'e' $o); $script:processes=@($script:me)
    $null=Ask Runtime
    Assert ((Owners).Count -eq 1) 'Reclaimed at once.'
    Assert (Stamp) 'OwnerGoneSinceUtc not saved.'
    Advance 599; $null=Ask Runtime
    Assert ((Owners).Count -eq 1) 'Reclaimed before 600 s.'
    $plan=Get-IW7ShareableMemoryPlan (Get-IW7ResourceSnapshot) @((Read-IW7ResourceState).Leases) $script:processes
    Assert ($plan.Declared -eq 4GB) "Declared is not 4 GB before the reclaim: $($plan.Declared)"
    Advance 2; $r=Ask Runtime
    Assert ($r -eq 'granted') "Runtime not granted after the reclaim: $r"
    Assert ((Owners).Count -eq 0) 'Dead build lease still in the state.'
    $rows=@(Reclaims)
    Assert ($rows.Count -eq 1 -and $rows[0].Kind -eq 'Build' -and $rows[0].Why -like '*owner process is gone*no detached builder*10m01s*') "Reclaim not logged: $($rows.Why)"
}
Case 'a build lease with a process running in its scope is never reclaimed' {
    $o=Proc 70071 'C:\fake\pwsh.exe'; $c=Proc 70072 (Join-Path $TestRoot 'bench-f\tool\x.exe')
    Save @(BuildLease 'f' $o); $script:processes=@($script:me,$c)
    $null=Ask Runtime; Advance 601; $null=Ask Runtime; Advance 3600; $null=Ask Runtime
    Assert ((Owners).Count -eq 1) 'A build lease with a process in its scope was reclaimed.'
    Assert (!(Stamp)) 'A stamp was left on a lease with a process in its scope.'
}
Case 'a detached builder keeps the lease; the stamp restarts when it is gone' {
    $o=Proc 70081 'C:\fake\pwsh.exe'
    $cl=Proc 70082 'C:\fake\cl.exe'; $cl.CreatedUtc='2026-11-12T01:56:00.0000000Z'
    Save @(BuildLease 'g' $o); $script:processes=@($script:me,$cl)
    $null=Ask Runtime; Advance 601; $null=Ask Runtime; Advance 3600; $null=Ask Runtime
    Assert ((Owners).Count -eq 1) 'A build lease with a detached compiler left was reclaimed.'
    Assert (!(Stamp)) 'A stamp was left while a detached compiler runs.'
    $script:processes=@($script:me); $null=Ask Runtime
    Assert ((Owners).Count -eq 1 -and (Stamp)) 'The stamp did not start when the compiler went.'
    Advance 599; $null=Ask Runtime
    Assert ((Owners).Count -eq 1) 'Reclaimed before a full OrphanSeconds after the compiler went.'
    Advance 2; $null=Ask Runtime
    Assert ((Owners).Count -eq 0) 'Not reclaimed OrphanSeconds after the compiler went.'
}
Case 'a compiler older than the lease does not keep it' {
    $o=Proc 70091 'C:\fake\pwsh.exe'; $oldCl=Proc 70092 'C:\fake\cl.exe'
    Save @(BuildLease 'h' $o); $script:processes=@($script:me,$oldCl)
    $null=Ask Runtime; Advance 601; $null=Ask Runtime
    Assert ((Owners).Count -eq 0) 'A compiler created before the lease kept it.'
}
Case 'a build lease whose owner is alive is never reclaimed' {
    $o=Proc 70101 'C:\fake\pwsh.exe'
    Save @(BuildLease 'i' $o); $script:processes=@($script:me,$o)
    $null=Ask Runtime; Advance 3600; $null=Ask Runtime
    Assert ((Owners).Count -eq 1 -and !(Stamp)) 'A build lease of a live owner was reclaimed or stamped.'
}
Case 'a build lease whose owner identity cannot be read is never reclaimed' {
    $o=Proc 70111 'C:\fake\pwsh.exe'; $unknown=Proc 70111 'C:\fake\pwsh.exe'; $unknown.Image=$null
    Save @(BuildLease 'j' $o); $script:processes=@($script:me,$unknown)
    $null=Ask Runtime; Advance 3600; $null=Ask Runtime
    Assert ((Owners).Count -eq 1 -and !(Stamp)) 'A build lease with an unreadable owner was reclaimed or stamped.'
}
Write-Output ("PASS $script:cases reclaim cases / $script:checks assertions; temporary registry, synthetic processes and clock.")
Remove-Item -LiteralPath $TestRoot -Recurse -Force -ErrorAction SilentlyContinue
