param([string]$TestRoot,[string]$Only='*')   # -Only 'stall*': run only the cases whose name matches
# Named resources of the resource scheduler (12 Nov 2026). Exclusivity follows what two jobs really share.
# The first three cases rebuild the stalls measured on 11-12 Nov from the admission log (admission-log.jsonl):
# the same holder, the same requests (owner, kind, declared memory, scope) asking in the same order, the same
# free memory. On the core before named resources every request in them is refused by the holder ("Build owned
# by ...", "Runtime owned by soak session"); with named resources the ones that share nothing are admitted.
# Same seam as resource_scheduler_queue_test.ps1: temporary registry, synthetic callers, clock and memory only.
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../../ops/Resource-Scheduler.Core.ps1"
if (!$TestRoot) { $TestRoot=Join-Path ([IO.Path]::GetTempPath()) ('iw7-resources-tests-'+[guid]::NewGuid().ToString('N')) }
[IO.Directory]::CreateDirectory($TestRoot) | Out-Null
function Get-IW7ResourceRoot { Join-Path $TestRoot 'registry' }
if ((Get-IW7ResourceRoot) -eq (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'IW7Paris/ResourceScheduler')) { throw 'Test seam failed: live registry selected.' }
$script:avail=30GB
function Get-IW7ResourceSnapshot { [pscustomobject]@{PhysicalTotal=32GB;PhysicalAvailable=[long]$script:avail;CommitLimit=96GB;Committed=12GB} }
$script:clock=[datetime]::SpecifyKind([datetime]'2026-11-11T20:00:00','Utc')
function Get-IW7SchedulerUtcNow { $script:clock }
function Advance([double]$Seconds) { $script:clock=$script:clock.AddSeconds($Seconds) }
$self=Get-Process -Id $PID
$script:launcher=[pscustomobject]@{PID=$PID;ParentPID=0;CreatedUtc=$self.StartTime.ToUniversalTime().ToString('o');Image=$self.Path;
    Name='pwsh.exe';Lab=$false;BaseClientTest=$false;Heavy=$false;WorkingSet=100MB;PrivateBytes=100MB}
$script:processes=@($script:launcher)
function Get-IW7ResourceProcesses { $script:processes }
$script:caller=$PID
function Get-IW7CallerPid { $script:caller }
$script:cores=16
function Get-IW7ProcessorCount { $script:cores }

$script:checks=0; $script:cases=0
function Assert($Value,[string]$Message) { $script:checks++; if (!$Value) { throw $Message } }
function Case([string]$Name,[scriptblock]$Body) {
    if ($Name -notlike $Only) { return }
    $script:cases++
    $script:processes=@($script:launcher); $script:avail=30GB; $script:cores=16; $script:callers=@{}; $script:leases=@{}; $script:nextPid=70000
    $root=Get-IW7ResourceRoot
    if (Test-Path -LiteralPath $root) { Get-ChildItem -LiteralPath $root | Where-Object Name -match '^(?:leases|queue)\.json|^admission-log' | Remove-Item -Force }
    try { & $Body } catch { throw "Case '$Name' failed: $($_.Exception.Message)" }
}
function New-Caller([string]$Name) {
    $script:nextPid+=2
    $parent=[pscustomobject]@{PID=$script:nextPid-1;ParentPID=0;CreatedUtc='2026-11-11T07:00:00.0000000Z';Image='C:\fake\runner.exe';
        Name='runner.exe';Lab=$false;BaseClientTest=$false;Heavy=$false;WorkingSet=50MB;PrivateBytes=50MB}
    $p=[pscustomobject]@{PID=$script:nextPid;ParentPID=$parent.PID;CreatedUtc='2026-11-11T07:30:00.0000000Z';Image='C:\fake\pwsh.exe';
        Name='pwsh.exe';Lab=$false;BaseClientTest=$false;Heavy=$false;WorkingSet=100MB;PrivateBytes=100MB}
    $script:processes+=@($parent,$p)
    $script:callers[$Name]=[pscustomobject]@{Process=$p;Parent=$parent}
}
# A child process (compiler, ZoneTool, Java) started by a caller after it was admitted.
function New-Child([string]$Name,[string]$Image,[long]$WorkingSet,[object]$Parent=$null) {
    $script:nextPid+=1
    $parentPid=if ($Parent) { $Parent.PID } else { 0 }
    $c=[pscustomobject]@{PID=$script:nextPid;ParentPID=$parentPid;CreatedUtc='2026-11-11T08:00:00.0000000Z';Image=$Image;Name=$Image.Split('\')[-1];
        Lab=$false;BaseClientTest=$false;Heavy=$true;WorkingSet=$WorkingSet;PrivateBytes=$WorkingSet}
    $script:processes+=$c; $c
}
function Scope([string]$Path) { Join-Path $TestRoot $Path }
# Ask once as caller $Name. Returns 'granted' or the refusal text. -Res: the named resources it declares.
function Ask([string]$Name,[string]$Kind='Runtime',[long]$Bytes=1.5GB,[string]$Path=$null,[switch]$Plain,[int]$Short=0,[string[]]$Res=$null,[switch]$Long,[int]$Cores=0) {
    if (!$script:callers.ContainsKey($Name)) { New-Caller $Name }
    $script:caller=$script:callers[$Name].Process.PID
    if (!$Path) { $Path='w-'+$Name }
    $arguments=@{Scope=(Scope $Path);Kind=$Kind;PhysicalBytes=$Bytes;CommitBytes=$Bytes;Owner=$Name}
    if ($Kind -eq 'Runtime' -and !$Plain) { $arguments.Shareable=$true }
    if ($Short) { $arguments.ShortSeconds=$Short }
    if ($null -ne $Res) { $arguments.Resources=$Res }
    if ($Long) { $arguments.Long=$true }
    if ($Cores) { $arguments.Cores=$Cores }
    try { $lease=Enter-IW7ResourceLease @arguments; $script:leases[$Name]=$lease; 'granted' }
    catch { $_.Exception.Message }
    finally { $script:caller=$PID }
}
function Release([string]$Name) {
    $script:caller=$script:callers[$Name].Process.PID
    try { Exit-IW7ResourceLease -Token $script:leases[$Name].Token; $script:leases.Remove($Name) } finally { $script:caller=$PID }
}
function TryRelease([string]$Name) { try { Release $Name; 'released' } catch { $_.Exception.Message } }
function Queue { @((Read-IW7ResourceQueue).Tickets | Sort-Object { [long]$_.FirstMs },{ [long]$_.Seq }) }
function Log { @([IO.File]::ReadAllLines((Get-IW7AdmissionLogPath)) | ForEach-Object { $_ | ConvertFrom-Json }) }
# Replays requests in arrival order (one second apart), each asking once. Returns name -> answer.
function Replay($Requests) {
    $answers=[ordered]@{}
    foreach ($r in $Requests) {
        Advance 1
        $a=@{Name=$r[0];Kind=$r[1];Bytes=[long]$r[2];Path=$r[3]}
        if ($r.Count -gt 4 -and $r[4]) { $a.Short=[int]$r[4] }
        $answers[$r[0]]=Ask @a
    }
    $answers
}

# --- Stall 1, 11 Nov 21:45 (20:45 UTC): a 1.5 GB headless soak session held a lease; 12 builds and 10 sessions waited
# up to 55 minutes with 12.8 GB free, every build refused with "Resource busy: Runtime owned by soak session".
Case 'stall 1 (21:45): a headless soak session no longer holds back builds and dumps' {
    $script:avail=[long](12.8*1GB)
    Assert ((Ask 'soak session' Runtime 1.5GB -Path 'bench\soak-1') -eq 'granted') 'The soak session holds its bench.'
    $server=New-Child 'server' (Join-Path (Scope 'bench\soak-1') 'iw7-mod.exe') 1.1GB $script:callers['soak session'].Process
    $server.Lab=$true
    Add-IW7ResourceProcess -Token $script:leases['soak session'].Token -ProcessId $server.PID   # its headless server: 1.1 of 1.5 GB taken
    $answers=Replay @(
        @('W2 Station Zero dressed zones build','Build',6GB,'iw7-runtime\iwz-stage2\level\w2\ztwork-w2'),
        @('Owner cheats policy and Windows CNG tests','Build',256MB,'comp-alw\runtime\alw-w1',120),
        @('phone gesture: zonetool playeranim build','Build',6GB,'worktrees\x64-zt-playeranim'),
        @('gamelab headless session a','Runtime',1.5GB,'phone\gesture\bench\glh-9ae695a2'),
        @('Q1/T1 zonetool build','Build',6GB,'worktrees\x64-zt-broadphase'),
        @('IW7 native build and checks a','Build',4GB,'menu-move\runtime\el-7f864413cd'),
        @('chars58 dump shared zone lists','Build',6GB,'iw7-runtime\chars58\ztwork'),
        @('Cutscene policy tests','Build',256MB,'srv-pin\runtime\wspin3',120))
    Assert ($answers['W2 Station Zero dressed zones build'] -eq 'granted') "The oldest waiting zone build goes in beside the soak session: $($answers['W2 Station Zero dressed zones build'])"
    Assert ($answers['Owner cheats policy and Windows CNG tests'] -eq 'granted') 'The 256 MB policy tests go in.'
    Assert ($answers['phone gesture: zonetool playeranim build'] -eq 'granted') 'A second zone build in another work folder goes in (12.8 - 6 - 0.25 - 6 = 0.55 GB left).'
    $refused=@($answers.GetEnumerator() | Where-Object { $_.Value -ne 'granted' })
    Assert (!@($refused | Where-Object { $_.Value -like '*soak session*' }).Count) "Nothing waits for the soak session any more: $(($refused | ForEach-Object { $_.Value }) -join ' | ')"
    Assert (!@($refused | Where-Object { $_.Value -notlike 'Resource busy: not enough measured free memory*' -and $_.Value -notlike 'Resource busy: declared memory budget exceeded*' -and $_.Value -notlike 'Resource busy: waiting in turn*' }).Count) 'What still waits, waits for memory (or behind an older request waiting for memory).'
    Release 'W2 Station Zero dressed zones build'
    Assert ((Ask 'gamelab headless session a' Runtime 1.5GB -Path 'phone\gesture\bench\glh-9ae695a2') -eq 'granted') 'When a zone build ends, the waiting headless session gets its memory.'
}
# --- Stall 2, 11 Nov 23:30 (22:30 UTC): a native C++ build (MSBuild, link) held "the" build reservation for about
# 90 minutes; 21 requests waited, nearly all ZoneTool builds and dumps that share nothing with a compile; 10.8 GB free.
Case 'stall 2 (23:30): a native compile no longer holds back ZoneTool builds, dumps and sessions' {
    $script:avail=[long](10.8*1GB)
    Assert ((Ask 'IW7 native build and checks' Build 4GB -Path 'comp-capacity\runtime\el-75bf0fb69d') -eq 'granted') 'The native build holds its tree.'
    $owner=$script:callers['IW7 native build and checks'].Process
    $msb=New-Child 'MSBuild' 'C:\VS\MSBuild.exe' 1.2GB $owner
    New-Child 'cl' 'C:\VS\cl.exe' 1.6GB $msb | Out-Null
    New-Child 'link' 'C:\VS\link.exe' 0.9GB $msb | Out-Null      # 3.7 GB of its 4 GB taken: 0.3 GB still promised
    $answers=Replay @(
        @('IWZ P1 language dump','Build',6GB,'iw7-runtime\iwz-stage2\level\ztwork-p1'),
        @('chars58 dump cp_disco vfx','Build',6GB,'iw7-runtime\chars58\ztwork'),
        @('x64-zt procedural bones zonetool build','Build',4GB,'worktrees\x64-zt-procbones'),
        @('gamelab headless session b','Runtime',1.5GB,'bench\glh-61b3cd60'),
        @('Cutscene policy tests','Build',256MB,'server-sharedfiles\runtime\sfw2',120),
        @('IW7 native build and checks (same tree)','Build',4GB,'comp-capacity\runtime\el-75bf0fb69d'))
    Assert ($answers['IWZ P1 language dump'] -eq 'granted') "The oldest dump goes in beside the compile (its compilers are the compile's own, not strangers): $($answers['IWZ P1 language dump'])"
    Assert ($answers['x64-zt procedural bones zonetool build'] -eq 'granted' -or $answers['x64-zt procedural bones zonetool build'] -like '*memory*') 'A ZoneTool compile in its own tree waits for memory at most.'
    Assert ($answers['Cutscene policy tests'] -eq 'granted') "The short policy tests go in: $($answers['Cutscene policy tests'])"
    Assert ($answers['IW7 native build and checks (same tree)'] -like 'Heavy job already reserved*') "A second compile of the same tree still waits for the first (a retryable refusal, as before): $($answers['IW7 native build and checks (same tree)'])"
    Assert (!@($answers.GetEnumerator() | Where-Object { $_.Key -ne 'IW7 native build and checks (same tree)' -and $_.Value -like '*owned by IW7 native build*' }).Count) 'Only the same tree waits for the compile.'
    Assert ((TryRelease 'IWZ P1 language dump') -eq 'released') "The dump releases although the compile's MSBuild is still running."
    Assert ((TryRelease 'IW7 native build and checks') -like 'Heavy child may still be alive*') 'The compile itself is kept while its own compilers run.'
}
# --- Stall 3, 12 Nov 01:30 (00:30 UTC): an 'engine database analyze' reservation (kind Analysis, Ghidra for hours,
# 10 GB declared) held the machine 40+ minutes; 17 builds waited, one for 87 minutes.
Case 'stall 3 (01:30): a long Ghidra analysis no longer holds back builds and checks' {
    $script:avail=12GB
    Assert ((Ask 'engine database analyze' Analysis 10GB -Path 'worktrees\comp-engine-os') -eq 'granted') 'The analysis holds its worktree.'
    New-Child 'java' 'C:\jdk\bin\java.exe' 7GB $script:callers['engine database analyze'].Process | Out-Null   # 3 GB still promised
    $answers=Replay @(
        @('IWZ Station Zero P1 perks build p2','Build',6GB,'iw7-runtime\iwz-stage2\level\ztwork-p1'),
        @('Cutscene policy tests a','Build',256MB,'comp-sharedfiles\runtime\sfw2',120),
        @('Cutscene policy tests b','Build',256MB,'srv-alw\runtime\srvalw-w1',120),
        @('IW7 native build and checks','Build',4GB,'menu-move\runtime\el-5b23ad2bbe'),
        @('character pack: build mod','Build',6GB,'iw7-runtime\chars58\ztwork'),
        @('gamelab headless session c','Runtime',1.5GB,'bench\cap\glh-6de42a85'))
    Assert ($answers['IWZ Station Zero P1 perks build p2'] -eq 'granted') "The oldest zone build goes in beside the analysis: $($answers['IWZ Station Zero P1 perks build p2'])"
    Assert ($answers['Cutscene policy tests a'] -eq 'granted' -and $answers['Cutscene policy tests b'] -eq 'granted') 'Both policy test runs go in.'
    Assert (!@($answers.GetEnumerator() | Where-Object { $_.Value -like '*engine database analyze*' }).Count) "Nothing waits for the analysis: $(($answers.Values) -join ' | ')"
    Assert ((Ask 'second analysis' Analysis 2GB -Path 'worktrees\comp-other') -like "Resource busy: Analysis owned by engine database analyze. It holds 'analysis'*") 'Two undeclared analyses still take turns (default resource analysis).'
    Assert ((Ask 'declared analysis' Analysis 1GB -Path 'worktrees\comp-third' -Res @('ghidra:C:\ghidra\other.gpr')) -eq 'granted') 'An analysis that names its own Ghidra project does not wait for the other (memory permitting).'
}
Case 'the same work folder, nested folders and declared names conflict; nothing else does' {
    Assert ((Ask z1 Build 2GB -Path 'zt\a') -eq 'granted') 'First build.'
    Assert ((Ask z2 Build 2GB -Path 'zt\a\sub') -like "Resource busy: Build owned by z1. It holds 'work:*zt\a', which this request needs too ('work:*zt\a\sub')*") 'A nested work folder conflicts.'
    Assert ((Ask z3 Extract 2GB -Path 'zt\b') -eq 'granted') 'Another folder does not.'
    Assert ((Ask t1 Build 1GB -Path 'tool1' -Res @("zonetool:$(Scope 'shared-zt')")) -eq 'granted') 'A declared shared ZoneTool folder.'
    Assert ((Ask t2 Build 1GB -Path 'tool2' -Res @("zonetool:$(Scope 'shared-zt')\")) -like "Resource busy: Build owned by t1. It holds 'zonetool:*shared-zt'*") 'Two jobs naming the same ZoneTool folder wait for each other, whatever their scopes.'
    Assert ((Ask t3 Build 1GB -Path 'tool3' -Res @('zonetool:*')) -like 'Resource busy: Build owned by t1.*') "A wildcard value conflicts with every value of the class."
    Assert ((Ask c1 Runtime 2GB -Path 'bench\c1' -Plain -Res @('gpu')) -eq 'granted') 'A client that names the GPU runs beside builds.'
    Assert ((Ask c2 Runtime 2GB -Path 'bench\c2' -Plain -Res @('gpu')) -like "Resource busy: Runtime owned by c1. It holds 'gpu'*") 'A second client waits for the GPU.'
    Assert ((Ask h1 Runtime 1.5GB -Path 'bench\h1') -eq 'granted') 'A headless session runs beside the client.'
    Assert ((Ask m Build 1GB -Path 'perf' -Res @('machine')) -like 'Resource busy: * owned by *') "A request for the machine alone waits for everything."
    $bad=Ask x Build 1GB -Path 'bad' -Res @('no spaces allowed:1')
    Assert ($bad -like "Invalid resource name*") "Names are checked: $bad"
}
Case 'an old exclusive Runtime (no names) still needs the machine alone' {
    Assert ((Ask h Runtime 1.5GB -Path 'bench\h') -eq 'granted') 'A session runs.'
    Assert ((Ask client Runtime 8GB -Path 'bench\client' -Plain) -like "Resource busy: Runtime owned by h. It holds 'runtime:*', which this request needs too ('machine')*") 'The default of an exclusive Runtime is the machine.'
    Assert ((Ask b Build 2GB -Path 'b') -like "Resource busy: waiting in turn: 1 earlier request(s) go first: 'client'*") 'And arrival order holds builds behind it: the machine conflicts with every name.'
    Release h
    Assert ((Ask client Runtime 8GB -Path 'bench\client' -Plain) -eq 'granted') 'It goes in alone.'
}
Case 'a renewing owner does not overtake an older request that conflicts with it' {
    Assert ((Ask holder Analysis 2GB -Path 'ghidra-a' -Res @('ghidra:C:\ghidra\iw7.gpr') -Long) -eq 'granted') 'A long holder of a Ghidra project.'
    Advance 5
    Assert ((Ask waiter Analysis 2GB -Path 'ghidra-b' -Res @('ghidra:C:\ghidra\iw7.gpr')) -like 'Resource busy: Analysis owned by holder.*Queue: place 1 of 1*') 'An analysis of the same project waits.'
    Advance 5; Release holder
    $m=Ask holder Analysis 2GB -Path 'ghidra-a' -Res @('ghidra:C:\ghidra\iw7.gpr') -Long
    Assert ($m -like "Resource busy: waiting in turn: 1 earlier request(s) go first: 'waiter'*") "Asking again right after its release, the holder waits behind the older request: $m"
    Assert ((Ask waiter Analysis 2GB -Path 'ghidra-b' -Res @('ghidra:C:\ghidra\iw7.gpr')) -eq 'granted') 'The older request goes in.'
    Assert ((Ask other Build 2GB -Path 'unrelated') -eq 'granted') 'Something that shares nothing was never delayed.'
}
Case 'a long holder never delays requests it does not conflict with; a long ticket never stops others for memory' {
    $script:avail=10GB
    Assert ((Ask soak Runtime 1.5GB -Path 'bench\soak' -Long) -eq 'granted') 'A long soak session.'
    Assert ((Ask zb Build 6GB -Path 'zt') -eq 'granted') 'A zone build beside it.'
    Assert ((Ask big Analysis 8GB -Path 'ana' -Long) -like 'Resource busy: not enough measured free memory*') 'A long 8 GB analysis waits for memory.'
    foreach ($i in 1..11) { Advance 60; Ask big Analysis 8GB -Path 'ana' -Long | Out-Null }
    Assert ((Ask h Runtime 1.5GB -Path 'bench\h') -eq 'granted') 'Eleven minutes later a session still goes in: a long ticket does not drain the machine.'
    $s=Get-IW7ResourceStatus
    Assert ($s.Queue[0].Long -and $s.Queue[0].Why -like "*(declared long)*waits for memory*") "Status says it is long and waits for memory: $($s.Queue[0].Why)"
}
Case 'a build that waits for memory drains the machine after the aging time' {
    $script:avail=9GB
    Assert ((Ask s1 Runtime 1.5GB -Path 'bench\s1') -eq 'granted') 'A session.'
    Assert ((Ask s2 Runtime 1.5GB -Path 'bench\s2') -eq 'granted') 'Another.'
    Assert ((Ask zb Build 8GB -Path 'zt') -like 'Resource busy: not enough measured free memory*Queue: place 1 of 1*') 'An 8 GB zone build waits for memory.'
    Advance 30
    Assert ((Ask s3 Runtime 1.5GB -Path 'bench\s3') -eq 'granted') 'Before the aging time a session that fits passes it.'
    foreach ($i in 1..10) { Advance 60; Ask zb Build 8GB -Path 'zt' | Out-Null }
    $m=Ask s4 Runtime 1.5GB -Path 'bench\s4'
    Assert ($m -like "Resource busy: waiting in turn: 1 earlier request(s) go first: 'zb' (Build, waiting 10m30s)*") "After 600 s new sessions stop taking memory: $m"
    Assert ((Ask t Build 256MB -Path 'tiny' -Short 60) -like "Resource busy: waiting in turn*'zb'*") 'Also short checks: memory waiters are never overtaken once aged.'
    Release s1; Release s2; Release s3
    Assert ((Ask zb Build 8GB -Path 'zt') -eq 'granted') 'Drained: the build goes in.'
}
Case 'compilers belong to the lease that started them' {
    Assert ((Ask a Build 2GB -Path 'tree-a') -eq 'granted') 'Build A.'
    $msbA=New-Child 'MSBuild' 'C:\VS\MSBuild.exe' 1GB $script:callers['a'].Process
    Assert ((Ask b Build 2GB -Path 'tree-b') -eq 'granted') "Build B is admitted while A's MSBuild runs."
    $msbB=New-Child 'MSBuild' 'C:\VS\MSBuild.exe' 1GB $script:callers['b'].Process
    Assert ((TryRelease a) -like 'Heavy child may still be alive*') "A is kept while its own MSBuild runs."
    $script:processes=@($script:processes | Where-Object PID -NE $msbA.PID)
    Assert ((TryRelease a) -eq 'released') "A releases while B's MSBuild still runs."
    $rogue=New-Child 'cl' 'C:\VS\cl.exe' 1GB $null
    Assert ((Ask c Runtime 1.5GB -Path 'bench\c') -like 'An existing compiler/extractor/Java analysis is running*') 'A compiler that no lease started still stops every admission.'
    $reused=New-Child 'cl' 'C:\VS\cl.exe' 1GB $script:callers['b'].Process; $reused.CreatedUtc='2026-11-11T07:00:00.0000000Z'
    $script:processes=@($script:processes | Where-Object PID -NE $rogue.PID)
    Assert ((Ask c Runtime 1.5GB -Path 'bench\c') -like 'An existing compiler/extractor/Java analysis is running*') 'A process older than the caller it names as parent is not adopted (PID reuse).'
    $script:processes=@($script:processes | Where-Object PID -NE $reused.PID)
    Assert ((Ask c Runtime 1.5GB -Path 'bench\c') -eq 'granted') "With only B's own compiler running, a session goes in."
}
Case 'memory: a build counts what its compilers have not taken yet' {
    $script:avail=8GB
    Assert ((Ask a Build 4GB -Path 'tree-a') -eq 'granted') 'A 4 GB build.'
    Assert ((Ask s Runtime 4.5GB -Path 'bench\s') -like 'Resource busy: not enough measured free memory: 8.0 GB available minus 3.9 GB still to be taken*') 'Before its compilers start, all 4 GB but its own shell (0.1 GB) are promised.'
    New-Child 'cl' 'C:\VS\cl.exe' 3GB $script:callers['a'].Process | Out-Null
    $script:avail=5GB
    Assert ((Ask s Runtime 4.5GB -Path 'bench\s') -like 'Resource busy: not enough measured free memory: 5.0 GB available minus 0.9 GB still to be taken*') 'Once they run, only the untaken part is promised.'
    Assert ((Ask s2 Runtime 4GB -Path 'bench\s2') -eq 'granted') 'A 4 GB session fits (5 - 0.9 = 4.1 GB).'
}
Case 'declared processor cores are shared too' {
    Assert ((Ask n1 Build 2GB -Path 'n1' -Cores 12) -eq 'granted') 'A compile declaring 12 of 16 cores.'
    Assert ((Ask n2 Build 2GB -Path 'n2' -Cores 8) -like 'Resource busy: not enough processor cores: running reservations declare 12 of 16 and this request needs 8.*') 'A second one declaring 8 waits.'
    Assert ((Ask n3 Build 2GB -Path 'n3' -Cores 4) -eq 'granted') 'One declaring 4 fits.'
    Assert ((Ask n4 Build 2GB -Path 'n4') -eq 'granted') 'A request that declares no cores is not counted.'
}
Case 'leases and tickets of an older core hold the machine' {
    $old=[pscustomobject]@{Token=('b'*32);Scope=(Get-IW7CanonicalScope (Scope 'old'));Kind='Build';Owner='older core build';
        OwnerIdentity=$script:launcher;CreatedUtc='2026-11-11T19:59:00.0000000Z';Phase='Pending';PhysicalBytes=4GB;CommitBytes=4GB;Shareable=$false;Processes=@()}
    [IO.Directory]::CreateDirectory((Get-IW7ResourceRoot)) | Out-Null
    Save-IW7ResourceState ([pscustomobject]@{Version=1;Leases=@($old)})
    Assert ((Ask s Runtime 1.5GB -Path 'bench\s') -like "Resource busy: Build owned by older core build. It holds 'machine'*") 'An older core assumed it was alone: its lease holds the machine.'
    Exit-IW7ResourceLease -Token $old.Token
    # A ticket written by an older core (no Resources field): passed until the aging time, then it drains the machine.
    New-Caller oldt; $c=$script:callers['oldt']
    $now=Get-IW7NowMs
    $q=[pscustomobject]@{Version=1;Seq=1L;Tickets=@([pscustomobject]@{Seq=1;Scope=(Get-IW7CanonicalScope (Scope 'oldt'));Kind='Build';Shareable=$false;
        PhysicalBytes=4GB;ShortSeconds=0;Owner='oldt';OwnerIdentity=[pscustomobject]@{PID=$c.Process.PID;CreatedUtc=$c.Process.CreatedUtc;Image=$c.Process.Image};
        ParentIdentity=$null;FirstMs=$now-1000;LastMs=$now;Polls=2;LastIntervalSeconds=5;OvertakenSeconds=0})}
    Save-IW7ResourceQueue $q
    Assert ((Ask s Runtime 1.5GB -Path 'bench\s') -eq 'granted') 'A young old-core ticket does not stop a session that shares nothing.'
    $q=Read-IW7ResourceQueue; $q.Tickets[0].FirstMs=$now-700000; Save-IW7ResourceQueue $q
    Assert ((Ask s5 Runtime 1.5GB -Path 'bench\s5') -like "Resource busy: waiting in turn: 1 earlier request(s) go first: 'oldt'*") 'After the aging time it stops new requests until the machine is free for it.'
}
Case 'status says what a waiting request needs and who holds it' {
    Ask z1 Build 2GB -Path 'zt\a' | Out-Null
    Advance 3
    Ask z2 Build 2GB -Path 'zt\a\sub' | Out-Null
    $s=Get-IW7ResourceStatus
    Assert ($s.Queue[0].Why -like "'z2' (Build, waiting 0s) needs 'work:*zt\a\sub', held by 'z1' (Build, holds 'work:*zt\a').") "Why names the shared resource: $($s.Queue[0].Why)"
    Assert ($s.Leases[0].Holds -contains ('work:'+(Get-IW7CanonicalScope (Scope 'zt\a')))) 'Status lists what each lease holds.'
    $g=@(Log | Where-Object Event -EQ 'grant')[0]
    Assert ($g.Resources -contains ('work:'+(Get-IW7CanonicalScope (Scope 'zt\a'))) -and $g.PhysicalBytes -eq 2GB) 'The admission log keeps the names and the memory of each grant.'
}
Write-Output ("PASS $script:cases named-resource cases / $script:checks assertions; three logged stalls replayed; temporary registry, synthetic callers, clock and memory only.")
Write-Output "Test evidence retained: $TestRoot"
