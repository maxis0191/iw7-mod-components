param([string]$TestRoot)
# Waiting order of the resource scheduler (queue.json, 2026-11-11). Same seam as the other scheduler suites:
# dot-source Core, then redefine the registry root, memory snapshot, process listing, clock and caller.
# Every caller is synthetic (a fake process with its own PID and parent); no real registry, process or game.
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../../ops/Resource-Scheduler.Core.ps1"
if (!$TestRoot) { $TestRoot=Join-Path ([IO.Path]::GetTempPath()) ('iw7-queue-tests-'+[guid]::NewGuid().ToString('N')) }
[IO.Directory]::CreateDirectory($TestRoot) | Out-Null
function Get-IW7ResourceRoot { Join-Path $TestRoot 'registry' }
if ((Get-IW7ResourceRoot) -eq (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'IW7Paris/ResourceScheduler')) { throw 'Test seam failed: live registry selected.' }
$script:avail=30GB
function Get-IW7ResourceSnapshot { [pscustomobject]@{PhysicalTotal=32GB;PhysicalAvailable=[long]$script:avail;CommitLimit=96GB;Committed=12GB} }
$script:clock=[datetime]::SpecifyKind([datetime]'2026-11-11T08:00:00','Utc')
function Get-IW7SchedulerUtcNow { $script:clock }
function Advance([double]$Seconds) { $script:clock=$script:clock.AddSeconds($Seconds) }
$self=Get-Process -Id $PID
$script:launcher=[pscustomobject]@{PID=$PID;ParentPID=0;CreatedUtc=$self.StartTime.ToUniversalTime().ToString('o');Image=$self.Path;
    Name='pwsh.exe';Lab=$false;BaseClientTest=$false;Heavy=$false;WorkingSet=100MB;PrivateBytes=100MB}
$script:processes=@($script:launcher)
function Get-IW7ResourceProcesses { $script:processes }
$script:caller=$PID
function Get-IW7CallerPid { $script:caller }

$script:checks=0; $script:cases=0
function Assert($Value,[string]$Message) { $script:checks++; if (!$Value) { throw $Message } }
function Case([string]$Name,[scriptblock]$Body) {
    $script:cases++
    $script:processes=@($script:launcher); $script:avail=30GB; $script:callers=@{}; $script:leases=@{}; $script:nextPid=60000
    $root=Get-IW7ResourceRoot
    if (Test-Path -LiteralPath $root) { Get-ChildItem -LiteralPath $root | Where-Object Name -match '^(?:leases|queue)\.json|^admission-log' | Remove-Item -Force }
    try { & $Body } catch { throw "Case '$Name' failed: $($_.Exception.Message)" }
}
# A caller is one fake process (and its parent), alive until Remove-Caller.
function New-Caller([string]$Name) {
    $script:nextPid+=2
    $parent=[pscustomobject]@{PID=$script:nextPid-1;ParentPID=0;CreatedUtc='2026-11-11T07:00:00.0000000Z';Image='C:\fake\runner.exe';
        Name='runner.exe';Lab=$false;BaseClientTest=$false;Heavy=$false;WorkingSet=50MB;PrivateBytes=50MB}
    $p=[pscustomobject]@{PID=$script:nextPid;ParentPID=$parent.PID;CreatedUtc='2026-11-11T07:30:00.0000000Z';Image='C:\fake\pwsh.exe';
        Name='pwsh.exe';Lab=$false;BaseClientTest=$false;Heavy=$false;WorkingSet=100MB;PrivateBytes=100MB}
    $script:processes+=@($parent,$p)
    $script:callers[$Name]=[pscustomobject]@{Process=$p;Parent=$parent}
}
function Remove-Caller([string]$Name,[switch]$Parent) {
    $c=$script:callers[$Name]
    $script:processes=@($script:processes | Where-Object { $_.PID -ne $c.Process.PID -and (!$Parent -or $_.PID -ne $c.Parent.PID) })
}
function Bench([string]$Name) { Join-Path $TestRoot ('bench-'+$Name) }
# Ask once as caller $Name. Returns 'granted' or the refusal text.
function Ask([string]$Name,[string]$Kind='Runtime',[long]$Bytes=2GB,[switch]$Plain,[int]$Short=0) {
    if (!$script:callers.ContainsKey($Name)) { New-Caller $Name }
    $script:caller=$script:callers[$Name].Process.PID
    $shareable=($Kind -eq 'Runtime' -and !$Plain)
    $arguments=@{Scope=(Bench $Name);Kind=$Kind;PhysicalBytes=$Bytes;CommitBytes=$Bytes;Owner=$Name}
    if ($shareable) { $arguments.Shareable=$true }
    if ($Short) { $arguments.ShortSeconds=$Short }
    try { $lease=Enter-IW7ResourceLease @arguments; $script:leases[$Name]=$lease; 'granted' }
    catch { $_.Exception.Message }
    finally { $script:caller=$PID }
}
function Release([string]$Name) { Exit-IW7ResourceLease -Token $script:leases[$Name].Token; $script:leases.Remove($Name) }
function Queue { @((Read-IW7ResourceQueue).Tickets | Sort-Object { [long]$_.FirstMs },{ [long]$_.Seq }) }
function Log { @([IO.File]::ReadAllLines((Get-IW7AdmissionLogPath)) | ForEach-Object { $_ | ConvertFrom-Json }) }

Case 'empty queue: admission as before, no ticket written' {
    Assert ((Ask s1) -eq 'granted') 'A fitting session on an empty queue is admitted at once.'
    Assert ((Ask s2) -eq 'granted') 'A second fitting session too.'
    Assert (!(Test-Path -LiteralPath (Get-IW7QueuePath))) 'Nobody waited: no queue file.'
    $grants=@(Log | Where-Object Event -EQ 'grant')
    Assert ($grants.Count -eq 2 -and @($grants | Where-Object WaitSeconds -EQ 0).Count -eq 2) 'Two grants without wait in the log.'
}
Case 'arrival order between two builds' {
    Ask s0 | Out-Null
    Assert ((Ask b1 Build 4GB) -like 'Resource busy: Runtime owned by s0.*Queue: place 1 of 1*') 'First build refused by the session, place 1.'
    Advance 5
    $m=Ask b2 Build 4GB
    Assert ($m -like "*Queue: place 2 of 2*ahead: 'b1' (Build, waiting 5s)*") "Second build is told its place and who is ahead: $m"
    Advance 5; Release s0
    $m=Ask b2 Build 4GB
    Assert ($m -like "Resource busy: waiting in turn: 1 earlier request(s) go first: 'b1' (Build*") "Newer build may not take the free slot before the older: $m"
    Assert ((Ask b1 Build 4GB) -eq 'granted') 'The older build is admitted.'
    Advance 60; Release b1
    Assert ((Ask b2 Build 4GB) -eq 'granted') 'Then the second.'
    Assert (!(Queue).Count) 'Granted tickets leave the queue.'
    $g=@(Log | Where-Object Event -EQ 'grant')
    Assert ($g[-2].Owner -eq 'b1' -and $g[-1].Owner -eq 'b2' -and $g[-1].WaitSeconds -eq 65) 'The log has the order and the wait of b2 (65 s).'
}
Case 'a build is not starved by a stream of sessions' {
    Ask s1 | Out-Null
    Ask b Build 4GB | Out-Null                       # the build waits behind s1
    Advance 10
    $m=Ask s2
    Assert ($m -like "Resource busy: waiting in turn: 1 earlier request(s) go first: 'b' (Build, waiting 10s)*") "A new session waits behind the older build: $m"
    Advance 10
    Assert ((Ask s3) -like 'Resource busy: waiting in turn*') 'Every new session does.'
    Release s1
    Assert ((Ask b Build 4GB) -eq 'granted') 'The running session drained; the build goes in.'
    Assert ((Ask s2) -like 'Resource busy: Build owned by b.*') 'Sessions wait for the build itself.'
}
Case 'sessions are not starved by a chain of builds' {
    Ask b1 Build 4GB | Out-Null
    Advance 1; Ask s1 | Out-Null; Advance 1; Ask s2 | Out-Null    # two sessions wait behind b1
    Advance 1; Ask b2 Build 4GB | Out-Null                          # then a newer build
    Advance 1; Release b1
    $m=Ask b2 Build 4GB
    Assert ($m -like "Resource busy: waiting in turn: 2 earlier request(s) go first: 's1'*'s2'*") "The newer build waits for the sessions that waited behind b1: $m"
    Assert ((Ask s1) -eq 'granted' -and (Ask s2) -eq 'granted') 'Both waiting sessions go in.'
    Advance 1
    Assert ((Ask s3) -like "Resource busy: waiting in turn: 1 earlier request(s) go first: 'b2'*") 'A session newer than b2 waits behind b2.'
    Release s1; Release s2
    Assert ((Ask b2 Build 4GB) -eq 'granted') 'b2 goes in when its older sessions are done.'
}
Case 'a fitting session passes an older session that does not fit' {
    Ask big Runtime 14GB | Out-Null                  # admitted: 14 GB of a 24 GB budget
    Assert ((Ask big2 Runtime 12GB) -like 'Resource busy: shareable declared memory budget exceeded*Queue: place 1*') 'A second big one does not fit and is queued.'
    Advance 30
    Assert ((Ask small Runtime 2GB) -eq 'granted') 'A small session that fits and has no older exclusive ticket is admitted at once.'
}
Case 'an old shareable ticket stops newer sessions after the aging time' {
    Ask big Runtime 14GB | Out-Null
    Ask big2 Runtime 12GB | Out-Null
    foreach ($i in 1..10) { Advance 60; Ask big2 Runtime 12GB | Out-Null }   # 600 s, still asking every minute
    $m=Ask small Runtime 2GB
    Assert ($m -like "Resource busy: waiting in turn: 1 earlier request(s) go first: 'big2' (Runtime shareable, waiting 10m00s)*") "After 600 s the waiting session goes first: $m"
    Release big
    Assert ((Ask big2 Runtime 12GB) -eq 'granted') 'It gets the memory.'
}
Case 'memory is still respected at the head of the queue' {
    $script:avail=3GB
    Ask s0 Runtime 2GB | Out-Null                    # running: 1 GB free, 2 GB held
    $m=Ask s1 Runtime 2GB
    Assert ($m -like 'Resource busy: not enough measured free memory*Queue: place 1 of 1*') "The first in line is still refused by measured memory: $m"
    Advance 5
    Assert ((Ask s1 Runtime 2GB) -like 'Resource busy: not enough measured free memory*Queue: place 1 of 1, asked first 5s ago*') 'No admission without memory, place kept.'
    Release s0
    Assert ((Ask s1 Runtime 2GB) -eq 'granted') 'Admitted once the memory is there.'
    $script:avail=1GB
    $m=Ask s2 Runtime 2GB
    Assert ($m -like 'Resource busy: not enough measured free memory*') "With 2 GB held by s1 it can come free: s2 waits: $m"
    Release s1
    $m=Ask s2 Runtime 2GB
    Assert ($m -like 'Refused: this session can never fit*needs 2.0 GB*free memory is 1.0 GB*hold 0.0 GB*at most 1.0 GB*') "Nothing left to wait for: a refusal, not a wait: $m"
    Assert (!(Queue).Count) 'And its ticket left the queue.'
}
Case 'a ticket asked once expires after 90 s' {
    Ask s1 | Out-Null
    Ask b Build 4GB | Out-Null
    Advance 91
    Assert ((Ask s2) -eq 'granted') 'The build never asked again: its ticket is gone after 90 s.'
    $e=@(Log | Where-Object Event -EQ 'expire')
    Assert ($e.Count -eq 1 -and $e[0].Owner -eq 'b' -and $e[0].Why -like 'not asked again*') 'The expiry is logged with its reason.'
}
Case 'a caller whose pauses grow keeps its place' {
    Ask s1 | Out-Null
    Ask b Build 4GB | Out-Null
    foreach ($pause in @(30,60,120,240,300,300)) { Advance $pause; Assert ((Ask b Build 4GB) -like '*Queue: place 1 of 1*') "Place lost after a $pause s pause." }
    Assert ((Ask s2) -like 'Resource busy: waiting in turn*') 'Still ahead of new sessions.'
    Advance 661
    Assert ((Ask s2) -eq 'granted') 'Silent for longer than twice its last pause plus 30 s (and 660 s): expired.'
}
Case 'a caller that dies while waiting' {
    Ask s1 | Out-Null
    Ask b Build 4GB | Out-Null
    Remove-Caller b
    Advance 1
    Assert ((Ask s2) -like 'Resource busy: waiting in turn*') 'Its parent (the runner that asks again in a new process) still lives: place kept.'
    Remove-Caller b -Parent
    Assert ((Ask s2) -eq 'granted') 'Caller and parent gone: the ticket expires at once.'
    Assert (@(Log | Where-Object { $_.Event -eq 'expire' -and $_.Why -eq 'caller gone' }).Count -eq 1) 'Logged as caller gone.'
}
Case 'a new process asking for the same scope keeps the place' {
    Ask s1 | Out-Null
    Ask b Build 4GB | Out-Null
    $first=(Queue)[0].FirstMs
    Remove-Caller b; $parent=$script:callers['b'].Parent
    $script:nextPid+=1
    $p=[pscustomobject]@{PID=$script:nextPid;ParentPID=$parent.PID;CreatedUtc='2026-11-11T07:45:00.0000000Z';Image='C:\fake\pwsh.exe';
        Name='pwsh.exe';Lab=$false;BaseClientTest=$false;Heavy=$false;WorkingSet=100MB;PrivateBytes=100MB}
    $script:processes+=$p; $script:callers['b'].Process=$p
    Advance 15
    Ask b Build 4GB | Out-Null
    $t=(Queue)[0]
    Assert ($t.FirstMs -eq $first -and $t.Polls -eq 2 -and $t.OwnerIdentity.PID -eq $p.PID) 'Same scope and kind: same ticket, identity of the newest caller.'
}
Case 'a short exclusive request goes ahead between sessions, within a bound' {
    Ask s1 | Out-Null
    Ask b Build 4GB | Out-Null
    Release s1
    Assert ((Ask t1 Build 256MB -Short 60) -eq 'granted') 'A 60 s check goes ahead of the waiting build when the slot is free.'
    Assert ((Queue)[0].OvertakenSeconds -eq 60) 'The build records 60 s overtaken.'
    Advance 20; Release t1
    $rel=@(Log | Where-Object Event -EQ 'release')[-1]
    Assert ($rel.Owner -eq 't1' -and $rel.HeldSeconds -eq 20 -and !$rel.Overran) 'Release logged with its holding time.'
    foreach ($n in 2..5) { Ask "t$n" Build 256MB -Short 60 | Out-Null; Release "t$n" }   # 5 x 60 = 300 s overtaken
    $m=Ask t6 Build 256MB -Short 60
    Assert ($m -like "Resource busy: waiting in turn: 1 earlier request(s) go first: 'b'*") "No more than 300 s of overtaking per waiting ticket: $m"
    Assert ((Ask b Build 4GB) -eq 'granted') 'The build goes in.'
    Assert ((Ask t7 Build 256MB -Short 60) -like 'Resource busy: Build owned by b.*') 'A short request never shares the slot.'
}
Case 'a short request waits like any exclusive one while sessions hold' {
    Ask s1 | Out-Null
    Assert ((Ask t Build 256MB -Short 30) -like 'Resource busy: Runtime owned by s1.*') 'Sessions hold: the check waits.'
    Assert ((Ask s2) -like "Resource busy: waiting in turn: 1 earlier request(s) go first: 't'*") 'And new sessions wait behind it.'
    Release s1
    Assert ((Ask t Build 256MB -Short 30) -eq 'granted') 'It goes in when the sessions are done.'
    Advance 45; Release t
    Assert (@(Log | Where-Object Event -EQ 'release')[-1].Overran) 'Holding longer than declared is logged as an overrun.'
    Assert ((Ask s3 Runtime 2GB) -eq 'granted') 'Nothing waits any more.'
}
Case 'invalid ShortSeconds' {
    Assert ((Ask s Runtime 2GB -Short 10) -like 'ShortSeconds is only valid on an exclusive reservation.') 'Shareable short refused.'
    $bad=$false; try { Enter-IW7ResourceLease -Scope (Bench x) -Kind Build -PhysicalBytes 1GB -CommitBytes 1GB -Owner x -ShortSeconds 121 } catch { $bad=$true }
    Assert $bad 'More than 120 s is not short.'
}
Case 're-entry is never queued' {
    Ask s1 | Out-Null
    Ask b Build 4GB | Out-Null
    Assert ((Ask s1) -eq 'granted') 'The holder re-enters its lease although a build waits.'
    Assert ((Queue).Count -eq 1) 'No ticket for the re-entry.'
}
Case 'a session larger than the whole budget is refused, not queued' {
    $m=Ask huge Runtime 30GB
    Assert ($m -like 'Refused: this session can never fit on this machine as it stands: it needs 30.0 GB*at most 24.0 GB*') "Refused at once with the numbers: $m"
    Assert ($m -notmatch '(?i)busy|occupied|lease|already reserved|laboratory is running|identity unavailable') "No word the runners retry on: $m"
    Assert (!(Queue).Count) 'Never queued: it could never fit and would block others.'
}
Case 'a session larger than the whole budget is refused at once while a build holds the machine' {
    Assert ((Ask b Build 8GB) -eq 'granted') 'The build holds the machine.'
    $m=Ask huge Runtime 30GB
    Assert ($m -like 'Refused: this session can never fit on this machine as it stands: it needs 30.0 GB*') "Refused at once, not queued behind the build: $m"
    Assert (!(Queue).Count) 'Never queued behind the build.'
    $m=Ask h Runtime 1.5GB
    Assert ($m -like 'Resource busy: Build owned by b*') "A session that fits still waits for the build: $m"
    Assert ((Queue).Count -eq 1) 'Only the session that fits is queued.'
    Release b
    Assert ((Ask h Runtime 1.5GB) -eq 'granted') 'Granted once the build ends.'
    Release h
}
# Deadlock of 2026-11-11, from the admission log and Status of 15:38: no lease, 5.48 GB available, an 8 GB client
# first in line for 29 min, then 1.5 GB headless sessions, a 6.5 GB network lab, more 8 GB clients and a build.
# The old rule made the aged 8 GB ticket hold back every later request: 9 requests, 0 leases for 28 minutes.
Case 'deadlock of 2026-11-11: an aged ticket that cannot fit no longer holds back the queue' {
    # Recreate the logged queue as the old core left it: tickets exist although the requests do not fit now.
    $q=[pscustomobject]@{Version=1;Seq=0L;Tickets=@()}
    $now=Get-IW7NowMs
    foreach ($t in @(@('c1',8GB,1739,'Runtime'),@('h1',1.5GB,1641,'Runtime'),@('net',6.5GB,1157,'Runtime'),@('h2',1.5GB,940,'Runtime'),
            @('c2',8GB,573,'Runtime'),@('b',6GB,551,'Build'))) {
        New-Caller $t[0]; $c=$script:callers[$t[0]]
        $q.Seq++
        $q.Tickets+=[pscustomobject]@{Seq=$q.Seq;Scope=(Get-IW7CanonicalScope (Bench $t[0]));Kind=$t[3];Shareable=($t[3] -eq 'Runtime');PhysicalBytes=[long]$t[1];
            ShortSeconds=0;Owner=$t[0];OwnerIdentity=[pscustomobject]@{PID=$c.Process.PID;CreatedUtc=$c.Process.CreatedUtc;Image=$c.Process.Image};
            ParentIdentity=[pscustomobject]@{PID=$c.Parent.PID;CreatedUtc=$c.Parent.CreatedUtc;Image=$c.Parent.Image};
            FirstMs=$now-1000*[long]$t[2];LastMs=$now-1000;Polls=20;LastIntervalSeconds=60;OvertakenSeconds=0}
    }
    [IO.Directory]::CreateDirectory((Get-IW7ResourceRoot)) | Out-Null
    Save-IW7ResourceQueue $q
    $script:avail=[long](5.48*1GB)
    $s=Get-IW7ResourceStatus
    Assert ($s.Why -like "Head of queue: 'c1' (Runtime shareable, waiting 28m59s) needs 8.0 GB, free 5.5 GB*held 0.0 GB by 0 running*cannot fit as things stand*") "Status says why the head waits: $($s.Why)"
    Assert (!$s.Queue[0].CanFit -and $s.Queue[1].CanFit) 'Status marks which tickets can fit.'
    $m=Ask h2 Runtime 1.5GB
    Assert ($m -like "Resource busy: waiting in turn: 1 earlier request(s) go first: 'h1'*(2 earlier request(s) that cannot fit now are passed)*") "Only the older headless session that fits goes first; the 8 GB client and the 6.5 GB lab are passed: $m"
    Assert ((Ask h1 Runtime 1.5GB) -eq 'granted') 'The first headless session is granted with 5.5 GB free (it was held back 27 min by the old rule).'
    $m=Ask net Runtime 6.5GB
    Assert ($m -like 'Refused: this session can never fit*needs 6.5 GB*free memory is 4.0 GB*hold 1.5 GB*at most 5.5 GB*') "The 6.5 GB lab can never fit beside 5.5 GB: refused at once: $m"
    Assert ((Ask h2 Runtime 1.5GB) -eq 'granted') 'The second headless session goes in (4.0 GB free).'
    $m=Ask c1 Runtime 8GB
    Assert ($m -like 'Refused: this session can never fit*needs 8.0 GB*') "The 8 GB client is refused at once when it asks again: $m"
    Assert (!@(Queue | Where-Object Owner -In @('c1','net')).Count) 'Refused tickets leave the queue.'
    Assert (@(Log | Where-Object { $_.Event -eq 'refuse' -and $_.NeverFits }).Count -eq 2) 'Never-fit refusals are logged.'
    $m=Ask b Build 6GB
    Assert ($m -like 'Resource busy: Runtime owned by h1*') "The build waits for the running sessions only: $m"
    Release h1; Release h2
    Assert ((Ask b Build 6GB) -eq 'granted') 'The build is not held back by the 8 GB client ticket c2 that cannot fit.'
    Assert (@(Queue | Where-Object Owner -EQ 'c2').Count -eq 1) 'c2 keeps its place in the queue until it asks again.'
}
Case 'an aged ticket that could fit by waiting still holds back later sessions; it stops when it no longer could' {
    $script:avail=9GB
    Ask s6 Runtime 6GB | Out-Null                    # running, declares 6 GB, nothing taken yet: 3 GB free
    $m=Ask c Runtime 8GB
    Assert ($m -like 'Resource busy: not enough measured free memory*Queue: place 1 of 1*') "8 GB can come free when s6 ends (3 + 6 = 9 GB): queued: $m"
    foreach ($i in 1..10) { Advance 60; Ask c Runtime 8GB | Out-Null }
    $m=Ask small Runtime 1.5GB
    Assert ($m -like "Resource busy: waiting in turn: 1 earlier request(s) go first: 'c'*") "Aged and satisfiable: later sessions wait: $m"
    $script:avail=[long](7.5*1GB)                    # memory taken outside the scheduler: 1.5 GB free + 6 GB held = 7.5 GB
    Assert ((Ask small Runtime 1.5GB) -eq 'granted') 'The aged 8 GB ticket can no longer be satisfied: the fitting session goes first.'
    Assert ((Queue)[0].Owner -eq 'c') 'The 8 GB ticket keeps its place.'
    $s=Get-IW7ResourceStatus
    Assert ($s.Why -like "Head of queue: 'c'*needs 8.0 GB*held 7.5 GB by 2 running shareable session(s)*") "Status gives need, free and held: $($s.Why)"
}
Case 'a build is not held back by an older session ticket that cannot fit' {
    $script:avail=9GB
    Ask s6 Runtime 6GB | Out-Null
    Ask c Runtime 8GB | Out-Null                     # queued: 3 + 6 = 9 GB could come free
    Advance 5
    Assert ((Ask b Build 4GB) -like 'Resource busy: Runtime owned by s6*Queue: place 2 of 2*') 'The build queues behind the client.'
    Release s6
    $script:avail=6GB                                # after s6, only 6 GB free: the client cannot fit
    Assert ((Ask b Build 4GB) -eq 'granted') 'The build goes in; under the old rule it waited for the client forever.'
    Release b; $script:avail=9GB
    Assert ((Ask c Runtime 8GB) -eq 'granted') 'The client still had its place and goes in when memory is there.'
}
Case 'unreadable queue file is ignored, never refuses' {
    [IO.Directory]::CreateDirectory((Get-IW7ResourceRoot)) | Out-Null
    [IO.File]::WriteAllText((Get-IW7QueuePath),'{ not json')
    Assert ((Ask s1) -eq 'granted') 'A broken queue file reads as empty.'
    [IO.File]::WriteAllText((Get-IW7QueuePath),'{"Version":7,"Tickets":[]}')
    Assert ((Ask s2) -eq 'granted') 'A queue of an unknown version reads as empty.'
    Assert (@((Read-IW7ResourceState).Leases).Count -eq 2) 'Both leases saved.'
}
Case 'leases written by an older core (no ticket, no flag) still work' {
    $old=[pscustomobject]@{Token=('a'*32);Scope=(Get-IW7CanonicalScope (Bench old));Kind='Runtime';Owner='older core';
        OwnerIdentity=$script:launcher;CreatedUtc='2026-11-11T07:59:00.0000000Z';Phase='Pending';PhysicalBytes=12GB;CommitBytes=12GB;Processes=@()}
    Save-IW7ResourceState ([pscustomobject]@{Version=1;Leases=@($old)})
    Assert ((Ask b Build 4GB) -like 'Resource busy: Runtime owned by older core.*Queue: place 1 of 1*') 'An older exclusive lease blocks and the build queues.'
    Assert ((Ask s1) -like 'Resource busy: Runtime owned by older core.*') 'A lease without the flag stays exclusive.'
    Exit-IW7ResourceLease -Token $old.Token
    Assert ((Ask s1) -like "Resource busy: waiting in turn: 1 earlier request(s) go first: 'b'*") 'The build that asked first goes first.'
    Assert ((Ask b Build 4GB) -eq 'granted') 'Granted.'
}
Case 'status lists holders and the queue with ages' {
    Ask s1 | Out-Null
    Advance 30
    Ask b Build 4GB | Out-Null
    Advance 12
    Ask s2 | Out-Null
    Advance 3
    $s=Get-IW7ResourceStatus
    Assert ($s.Leases.Count -eq 1 -and $s.Leases[0].Owner -eq 's1' -and $s.Leases[0].HeldSeconds -eq 45) 'Holder with its age.'
    Assert ($s.Queue.Count -eq 2 -and $s.Queue[0].Owner -eq 'b' -and $s.Queue[0].Place -eq 1 -and $s.Queue[0].WaitingSeconds -eq 15 -and
        $s.Queue[1].Owner -eq 's2' -and $s.Queue[1].WaitingSeconds -eq 3 -and $s.Queue[1].LastAskedSecondsAgo -eq 3) 'Queue in order with ages.'
    $before=[IO.File]::ReadAllText((Get-IW7QueuePath))
    Advance 600; Get-IW7ResourceStatus | Out-Null
    Assert ([IO.File]::ReadAllText((Get-IW7QueuePath)) -ceq $before) 'Status never writes the queue.'
}
Case 'the wait report reads order, waits per owner and the longest' {
    Ask s1 | Out-Null
    Ask b1 Build 4GB | Out-Null
    Advance 40; Ask s2 | Out-Null
    Advance 20; Release s1
    Ask s2 | Out-Null                                # still behind b1, asks again
    Ask b1 Build 4GB | Out-Null                      # granted after 60 s
    Advance 50; Ask s2 | Out-Null; Advance 50; Release b1
    Ask s2 | Out-Null                                # granted after 120 s
    $r=Get-IW7ResourceWaitReport
    Assert (($r.Grants | ForEach-Object Owner) -join ',' -eq 's1,b1,s2') 'Grants in order.'
    Assert ($r.Longest.Owner -eq 's2' -and $r.Longest.WaitSeconds -eq 120) ("Longest wait: s2, 120 s: "+($r.Grants|ConvertTo-Json -Compress))
    Assert (@($r.PerOwner | Where-Object Owner -EQ 'b1')[0].MaxWaitSeconds -eq 60) 'Per owner.'
    Assert ($r.Refusals -ge 3 -and @($r.Releases).Count -eq 2) 'Refusals and releases counted.'
    $text=& "$PSScriptRoot/../../ops/Resource-Scheduler.ps1" -Action Waits -LogPath (Get-IW7AdmissionLogPath) -Since '2026-11-11T00:00:00Z' | Out-String
    Assert ($text -match 'Longest wait: 2m00s \(s2, Runtime\)') "The command prints the longest wait: $text"
}
Case 'A busy admission lock is retryable' {
    Assert (Test-IW7RetryableRefusal 'Resource admission lock busy; retry later.') 'A busy admission lock is waited out like a busy slot.'
    Assert (!(Test-IW7RetryableRefusal 'Reserved launcher unknown.')) 'An unrelated refusal stays fatal.'
}
Write-Output ("PASS $script:cases waiting-order cases / $script:checks assertions; temporary registry, synthetic callers, clock and memory only.")
Write-Output "Test evidence retained: $TestRoot"
