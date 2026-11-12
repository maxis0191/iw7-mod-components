# Shared by every worktree on this Windows account. No process is stopped here.
# Keep admission + reservation atomic; a snapshot alone is not a reservation.
. "$PSScriptRoot/Resource-Memory.ps1"
. "$PSScriptRoot/Resource-OwnedProcess.Core.ps1"
. "$PSScriptRoot/Resource-RecorderOwnedProcess.Core.ps1"
function Get-IW7ResourceRoot {
    Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'IW7Paris/ResourceScheduler'
}
function Get-IW7ResourceSnapshot {
    Get-IW7NativeMemorySnapshot
}
function Test-IW7ResourceBudget($Snapshot, [long]$PhysicalBytes, [long]$CommitBytes) {
    if (!$Snapshot -or $Snapshot.PhysicalTotal -le 0 -or $Snapshot.CommitLimit -le 0 -or
        $Snapshot.PhysicalAvailable -lt 0 -or $Snapshot.PhysicalAvailable -gt $Snapshot.PhysicalTotal -or
        $Snapshot.Committed -lt 0 -or $Snapshot.Committed -gt $Snapshot.CommitLimit -or
        $PhysicalBytes -lt 0 -or $CommitBytes -lt 0) { throw 'Invalid resource snapshot or reservation.' }
    # Owner decision 2026-10-13: memory is fresh telemetry, not numeric admission.
    # Keep these compatibility fields for existing launchers/watchdogs. Ownership
    # and lifecycle checks below still serialize the complete heavy-workload group.
    [pscustomobject]@{
        Policy = 'TelemetryOnly'
        Allowed = $true
        PhysicalUsedPercent = [math]::Round(100 * (1 - $Snapshot.PhysicalAvailable / $Snapshot.PhysicalTotal), 2)
        CommitUsedPercent = [math]::Round(100 * $Snapshot.Committed / $Snapshot.CommitLimit, 2)
        PhysicalReserve = 0L
        CommitReserve = 0L
        AdditionalPhysical = $PhysicalBytes
        AdditionalCommit = $CommitBytes
        HighWater = $false
    }
}
function Get-IW7ResourceProcesses {
    # Do not persist command lines: lab commands contain passwords.
    @(Get-CimInstance Win32_Process -OperationTimeoutSec 5 -ErrorAction Stop | ForEach-Object {
        $normalCapacityProbe=Test-IW7NormalCapacityClientProbe $_.CommandLine
        [pscustomobject]@{
            PID = [int]$_.ProcessId
            ParentPID = [int]$_.ParentProcessId
            CreatedUtc = if ($_.CreationDate) { $_.CreationDate.ToUniversalTime().ToString('o') } else { $null }
            Image = $_.ExecutablePath
            Name = $_.Name
            Lab = [bool]($normalCapacityProbe -or $_.CommandLine -match '(?:^|\s)-paris-isolated-lab(?:\s|$)')
            BaseClientTest = [bool]($normalCapacityProbe -or ($_.CommandLine -match '(?:^|\s)-paris-server-client-test(?:\s|$)' -and $_.CommandLine -notmatch '(?:^|\s)-dedicated(?:\s|$)'))
            Heavy = [bool]($_.Name -match '^(?:iw7.*|zonetool.*|MSBuild|cl|link|java)\.exe$')
            WorkingSet = [long]$_.WorkingSetSize
            PrivateBytes = [long]$_.PrivatePageCount
        }
    })
}
function Test-IW7NormalCapacityClientProbe([string]$CommandLine) {
    # Classification only; admission still requires this exact declared image,
    # one complete Runtime reservation and registration of its real identity.
    if(!$CommandLine -or $CommandLine -match '(?:^|\s)-(?:dedicated|paris-isolated-lab|paris-debugger|paris-server-test|paris-server-client-test)(?:\s|$)'){return $false}
    foreach($flag in @('cpMode','paris-capacity-64','paris-capacity-production','paris-capacity-client-probe')){
        if($CommandLine -notmatch ('(?:^|\s)-'+$flag+'(?:\s|$)')){return $false}
    }
    $CommandLine -match '(?:^|\s)\+set\s+net_ip\s+127\.0\.0\.1(?:\s|$)' -and
        $CommandLine -match '(?:^|\s)\+set\s+net_port\s+27[1-9][0-9]{2}(?:\s|$)'
}
function Test-IW7ResourceIdentity($Record, $Process) {
    $Record -and $Process -and $Record.PID -eq $Process.PID -and $Record.CreatedUtc -and
        $Process.CreatedUtc -and
        [math]::Abs((([datetimeoffset]$Record.CreatedUtc).UtcDateTime - ([datetimeoffset]$Process.CreatedUtc).UtcDateTime).Ticks) -le 10 -and
        $Record.Image -and $Record.Image -eq $Process.Image
}
function Get-IW7CanonicalScope([string]$Scope) {
    if (![IO.Path]::IsPathRooted($Scope)) { throw 'Resource scope must be an absolute path.' }
    [IO.Path]::GetFullPath($Scope).TrimEnd('\', '/').ToLowerInvariant()
}
function Test-IW7ProcessInScope($Process, [string]$Scope) {
    $Process.Image -and $Process.Image.StartsWith($Scope + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}
function Test-IW7ReservedProcess($Process, $Lease) {
    if (Test-IW7ProcessInScope $Process $Lease.Scope) { return $true }
    $declared=$Lease.PSObject.Properties['BaseClientImage']
    $fixture=$Process.PSObject.Properties['BaseClientTest']
    return $declared -and $declared.Value -and $fixture -and $fixture.Value -and $Process.Lab -and
        $Process.Image -and [IO.Path]::GetFullPath($Process.Image) -eq $declared.Value
}
function Get-IW7ShareableRuntimeLeaseLimit {
    # Decision 2026-11-10 (admission by memory): a guard against runaway requests,
    # not the real limit. The real limit is memory (Get-IW7ShareableMemoryPlan).
    24
}
function Get-IW7ShareableReserveBytes {
    # Memory kept free for the owner's desktop and own game. IW7_SHAREABLE_RESERVE_GB
    # overrides it when it is a number from 2 to 64; anything else is ignored.
    $raw=[Environment]::GetEnvironmentVariable('IW7_SHAREABLE_RESERVE_GB')
    $gb=0.0
    if ($raw -and [double]::TryParse($raw.Trim(),[Globalization.NumberStyles]::AllowDecimalPoint,[Globalization.CultureInfo]::InvariantCulture,[ref]$gb) -and
        $gb -ge 2 -and $gb -le 64) { return [long]($gb*1GB) }
    [long]8GB
}
function Format-IW7Gb([long]$Bytes) {
    ($Bytes/1GB).ToString('0.0',[Globalization.CultureInfo]::InvariantCulture)+' GB'
}
function Get-IW7ShareableMemoryPlan($Snapshot, $Leases, $Processes) {
    # $Leases: the shareable leases already held. Declared = what their sessions need
    # in total. Unloaded = the part of that their registered live processes have not
    # taken yet (declared minus working set, never below zero, per lease): free memory
    # that is already promised. A lease without live processes counts all of it.
    $declared=0L; $unloaded=0L
    foreach ($l in @($Leases | Where-Object { Test-IW7ShareableRuntimeLease $_ })) {
        $declared += [long]$l.PhysicalBytes
        $taken=0L
        # Identities of ANOTHER lease that cannot be read right now (a server just
        # starting or exiting): count nothing as taken, so all its memory stays reserved.
        try { foreach ($p in @(Get-IW7LeaseLiveProcesses $l $Processes)) { $taken += [long]$p.WorkingSet } }
        catch { if ($_.Exception.Message -like 'Reserved process identity unavailable*') { $taken=0L } else { throw } }
        $unloaded += [math]::Max(0L,[long]$l.PhysicalBytes-$taken)
    }
    $reserve=Get-IW7ShareableReserveBytes
    [pscustomobject]@{Reserve=$reserve;Total=[long]$Snapshot.PhysicalTotal;Budget=([long]$Snapshot.PhysicalTotal-$reserve);
        Declared=$declared;Unloaded=$unloaded;Available=[long]$Snapshot.PhysicalAvailable}
}
function Assert-IW7ShareableMemoryAdmission($Plan, [long]$RequestBytes, [long]$NeedBytes) {
    # RequestBytes: the lease's whole declared session memory. NeedBytes: the part
    # not yet taken by its own live processes (the whole request for a new lease).
    if ($Plan.Declared + $RequestBytes -gt $Plan.Budget) {
        throw ("Resource busy: shareable declared memory budget exceeded: existing shareable leases declare $(Format-IW7Gb $Plan.Declared) " +
            "and this request needs $(Format-IW7Gb $RequestBytes), above the budget of $(Format-IW7Gb $Plan.Budget) " +
            "($(Format-IW7Gb $Plan.Total) total minus a $(Format-IW7Gb $Plan.Reserve) reserve). Continue light work; retry when released.")
    }
    $free=$Plan.Available-$Plan.Unloaded
    if ($free -lt $NeedBytes) {
        throw ("Resource busy: not enough measured free memory: $(Format-IW7Gb $Plan.Available) available minus $(Format-IW7Gb $Plan.Unloaded) " +
            "still to be taken by existing shareable sessions leaves $(Format-IW7Gb ([math]::Max(0L,$free))), and this request needs $(Format-IW7Gb $NeedBytes). " +
            "Continue light work; retry when memory is free.")
    }
}
function Get-IW7ShareableReachBytes($Plan) {
    # The most memory a shareable request can get by waiting in the queue: what is free now (available minus
    # what running sessions have still to take) plus what running shareable sessions declare (it comes back
    # when they end), never above the declared budget. Memory held outside the scheduler (kernel pools, the
    # public server, other programs) is not counted: waiting in the queue does not give it back.
    [math]::Min([long]$Plan.Budget,[math]::Max(0L,[long]$Plan.Available-[long]$Plan.Unloaded)+[long]$Plan.Declared)
}
function Assert-IW7ShareableCanFit($Plan, [long]$RequestBytes) {
    # A new shareable request that cannot fit even when every running shareable session has ended is refused
    # at once and never queued (deadlock of 2026-11-11). The text avoids the words runners retry on.
    $reach=Get-IW7ShareableReachBytes $Plan
    if ($RequestBytes -le $reach) { return }
    $free=[math]::Max(0L,[long]$Plan.Available-[long]$Plan.Unloaded)
    throw ("Refused: this session can never fit on this machine as it stands: it needs $(Format-IW7Gb $RequestBytes), " +
        "measured free memory is $(Format-IW7Gb $free) and running shareable sessions hold $(Format-IW7Gb $Plan.Declared), " +
        "so waiting can give at most $(Format-IW7Gb $reach) (declared budget $(Format-IW7Gb $Plan.Budget): " +
        "$(Format-IW7Gb $Plan.Total) total minus a $(Format-IW7Gb $Plan.Reserve) reserve). Not queued. " +
        'Ask for less (a headless plan needs about 1.5 GB) or free memory outside the scheduler first.')
}
function Test-IW7ShareableRuntimeLease($Lease) {
    # Fail safe: a missing, non-Boolean or inconsistent flag is exclusive.
    $flag=$Lease.PSObject.Properties['Shareable']
    $base=$Lease.PSObject.Properties['BaseClientImage']
    [bool]($flag -and $flag.Value -is [bool] -and $flag.Value -and $Lease.Kind -eq 'Runtime' -and !($base -and $base.Value))
}
function Test-IW7ScopeOverlap([string]$Left, [string]$Right) {
    $sep=[string][IO.Path]::DirectorySeparatorChar
    $Left -eq $Right -or $Left.StartsWith($Right+$sep, [StringComparison]::OrdinalIgnoreCase) -or
        $Right.StartsWith($Left+$sep, [StringComparison]::OrdinalIgnoreCase)
}
function Invoke-IW7ResourceLock([scriptblock]$Body) {
    $root = Get-IW7ResourceRoot
    [IO.Directory]::CreateDirectory($root) | Out-Null
    $deadline = [datetime]::UtcNow.AddSeconds(10)
    $handle = $null
    do {
        try { $handle = [IO.File]::Open((Join-Path $root 'admission.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
        catch [IO.IOException] {
            if ([datetime]::UtcNow -ge $deadline) { throw 'Resource admission lock busy; retry later.' }
            Start-Sleep -Milliseconds 100
        }
    } until ($handle)
    try { & $Body } finally { $handle.Dispose() }
}
function Read-IW7ResourceState {
    $path = Join-Path (Get-IW7ResourceRoot) 'leases.json'
    if (!(Test-Path -LiteralPath $path)) { return [pscustomobject]@{Version=1; Leases=@()} }
    $state = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($state.Version -ne 1 -or $null -eq $state.Leases) { throw 'Unknown resource registry; preserve it and investigate.' }
    foreach ($lease in @($state.Leases)) {
        if (!$lease.Token -or !$lease.Scope -or !$lease.OwnerIdentity -or $lease.PhysicalBytes -le 0 -or
            $lease.CommitBytes -le 0 -or $lease.Phase -notin @('Pending','Running') -or
            $lease.Kind -notin @('Runtime','Build','Extract','Analysis')) { throw 'Invalid resource lease; admission refused.' }
        if ($lease.PSObject.Properties.Name -contains 'BaseClientImage' -and $lease.BaseClientImage) {
            if ($lease.Kind -ne 'Runtime' -or $lease.BaseClientImage -isnot [string] -or
                ![IO.Path]::IsPathRooted($lease.BaseClientImage) -or [IO.Path]::GetExtension($lease.BaseClientImage) -ne '.exe' -or
                [IO.Path]::GetFullPath($lease.BaseClientImage) -ne $lease.BaseClientImage) { throw 'Invalid base client declaration; reservation retained.' }
        }
    }
    $state
}
function Save-IW7ResourceState($State) {
    $path = Join-Path (Get-IW7ResourceRoot) 'leases.json'
    $temporary = $path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    [IO.File]::WriteAllText($temporary, ($State | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
    if ([IO.File]::Exists($path)) { [IO.File]::Replace($temporary, $path, ($path+'.previous')) }
    else { [IO.File]::Move($temporary, $path) }
}
function Get-IW7LeaseLiveProcesses($Lease, $Processes) {
    # PID reuse is never liveness. Inaccessible matching PID is ambiguous, not dead.
    foreach ($record in @($Lease.Processes)) {
        $current = @($Processes | Where-Object PID -EQ $record.PID)
        if ($current.Count -and (!$current[0].Image -or !$current[0].CreatedUtc)) {
            throw 'Reserved process identity unavailable; reservation retained.'
        }
        if ($current.Count -and (Test-IW7ResourceIdentity $record $current[0])) { $current[0] }
    }
}
function Remove-IW7FinishedRuntimeLeases($State, $Processes, [switch]$TolerateOtherAmbiguity, [string]$ExceptScope, [string]$ExceptKind) {
    $State.Leases = @($State.Leases | Where-Object {
        $lease = $_
        # Shareable admission only: a lease other than the requested one whose process
        # identity is unreadable is retained (not finished) instead of failing the request.
        $lenient = $TolerateOtherAmbiguity -and !($lease.Scope -eq $ExceptScope -and $lease.Kind -eq $ExceptKind)
        try {
        $owner = @($Processes | Where-Object PID -EQ $lease.OwnerIdentity.PID)
        $ownerAlive = $owner.Count -and (Test-IW7ResourceIdentity $lease.OwnerIdentity $owner[0])
        $ownerUnknown = $owner.Count -and (!$owner[0].Image -or !$owner[0].CreatedUtc)
        $live = @(Get-IW7LeaseLiveProcesses $lease $Processes)
        $inScope = @($Processes | Where-Object { Test-IW7ReservedProcess $_ $lease })
        # A crashed builder might have detached children outside its root. Keep it
        # quarantined until explicit release; runtime children must be inside scope.
        !($lease.Kind -eq 'Runtime' -and !$ownerAlive -and !$ownerUnknown -and !$live.Count -and !$inScope.Count)
        } catch {
            if ($lenient -and $_.Exception.Message -like 'Reserved process identity unavailable*') { $true } else { throw }
        }
    })
}
# ---------------------------------------------------------------------------------------------------------------
# Waiting order (2026-11-11). A refused request that will ask again keeps a ticket in queue.json, next to
# leases.json and under the same admission lock. The queue is advisory state: it can only add the refusal
# "Resource busy: waiting in turn ..."; a missing, unreadable or foreign queue file is read as empty, and no
# queue error ever refuses, grants or removes a reservation. Older cores never read or write queue.json.
# Rules (docs/RESOURCE-WORKFLOW.md, "Waiting order"):
#  - a ticket is one intended lease: canonical scope + kind. Asking again refreshes it and keeps its place;
#  - a ticket expires when neither its caller nor the caller's parent process is alive, or when it is not
#    refreshed in time (90 s after a single ask; then twice the last interval between asks plus 30 s,
#    within 90..660 s, so a runner whose pauses grow to 300 s keeps its place);
#  - an older shareable ticket counts as a blocker only while it could be satisfied by waiting: its request is
#    no more than measured free memory plus the memory declared by running shareable leases (fix of the
#    deadlock of 2026-11-11: an 8 GB client on a machine with 5.5 GB free held 8 requests for 28 minutes);
#    otherwise later requests that fit go first and the ticket keeps its place;
#  - an exclusive request (Build, Extract, Analysis, non-shareable Runtime) waits for every older such ticket;
#  - a shareable request waits only for an older exclusive ticket, or for an older shareable ticket that has
#    waited AgingSeconds (600 s) without fitting: then it goes first and newer sessions stop taking memory;
#  - a short exclusive request (-ShortSeconds 1..120) may go ahead of older tickets when it is admissible now,
#    as long as no older ticket has been overtaken for more than MaxOvertakeSeconds (300 s) in total;
#  - re-entry of an existing lease is never queued; a new shareable request that can never fit (above free
#    memory plus what running shareable leases declare, or above the declared budget) is refused at once with
#    "Refused: this session can never fit ..." and its ticket leaves the queue.
# Every grant, refusal, expiry and release is one line in admission-log.jsonl (Get-IW7ResourceWaitReport).
function Get-IW7SchedulerUtcNow { [datetime]::UtcNow }
function Get-IW7CallerPid { $PID }
function Get-IW7QueuePolicy {
    [pscustomobject]@{FirstGraceSeconds=90;MinGraceSeconds=90;MaxGraceSeconds=660;AgingSeconds=600;MaxOvertakeSeconds=300;MaxShortSeconds=120;LogRotateBytes=8MB}
}
function Get-IW7NowMs { [DateTimeOffset]::new([datetime]::SpecifyKind((Get-IW7SchedulerUtcNow),'Utc')).ToUnixTimeMilliseconds() }
function Get-IW7QueuePath { Join-Path (Get-IW7ResourceRoot) 'queue.json' }
function Get-IW7AdmissionLogPath { Join-Path (Get-IW7ResourceRoot) 'admission-log.jsonl' }
function Format-IW7Age([double]$Seconds) {
    $s=[long][math]::Max(0,[math]::Round($Seconds))
    if ($s -lt 60) { return "${s}s" }
    if ($s -lt 3600) { return ('{0}m{1:00}s' -f [math]::Floor($s/60),($s%60)) }
    '{0}h{1:00}m' -f [math]::Floor($s/3600),[math]::Floor(($s%3600)/60)
}
function Test-IW7RetryableRefusal([string]$Message) {
    foreach ($p in @('Resource busy:*','Resource admission lock busy*','Heavy job already reserved*','An existing compiler/extractor/Java analysis is running*',
        'An unreserved or foreign laboratory is running*','Existing lab has no reservation*','Reserved process identity unavailable*')) {
        if ($Message -like $p) { return $true }
    }
    $false
}
function Read-IW7ResourceQueue {
    $empty=[pscustomobject]@{Version=1;Seq=0L;Tickets=@()}
    $path=Get-IW7QueuePath
    try {
        if (![IO.File]::Exists($path)) { return $empty }
        $q=[IO.File]::ReadAllText($path) | ConvertFrom-Json -ErrorAction Stop
        if ($q.Version -ne 1 -or !$q.PSObject.Properties['Tickets']) { return $empty }
        $tickets=@($q.Tickets | Where-Object { $_ -and $_.Scope -is [string] -and $_.Kind -in @('Runtime','Build','Extract','Analysis') -and
            $null -ne $_.FirstMs -and $null -ne $_.LastMs -and $null -ne $_.Seq })
        [pscustomobject]@{Version=1;Seq=[long]$(if ($q.PSObject.Properties['Seq']) { $q.Seq } else { 0 });Tickets=$tickets}
    } catch { $empty }
}
function Save-IW7ResourceQueue($Queue) {
    $path=Get-IW7QueuePath
    $temporary=$path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    [IO.File]::WriteAllText($temporary,($Queue | ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
    if ([IO.File]::Exists($path)) { [IO.File]::Replace($temporary,$path,($path+'.previous')) } else { [IO.File]::Move($temporary,$path) }
}
function Add-IW7AdmissionLog($Record) {
    # Best effort, inside the admission lock: a log failure never changes an admission.
    try {
        $path=Get-IW7AdmissionLogPath
        $policy=Get-IW7QueuePolicy
        if ([IO.File]::Exists($path) -and ([IO.FileInfo]::new($path)).Length -gt $policy.LogRotateBytes) {
            $old=[IO.Path]::ChangeExtension($path,'.1.jsonl')
            if ([IO.File]::Exists($old)) { [IO.File]::Delete($old) }
            [IO.File]::Move($path,$old)
        }
        $Record | Add-Member -NotePropertyName Utc -NotePropertyValue ((Get-IW7SchedulerUtcNow).ToString('o')) -Force
        [IO.File]::AppendAllText($path,(($Record | ConvertTo-Json -Depth 4 -Compress)+"`n"),[Text.UTF8Encoding]::new($false))
    } catch { }
}
function Test-IW7TicketCallerAlive($Ticket, $Processes) {
    foreach ($name in @('OwnerIdentity','ParentIdentity')) {
        $property=$Ticket.PSObject.Properties[$name]
        if (!$property -or !$property.Value) { continue }
        $id=$property.Value
        $p=@($Processes | Where-Object PID -EQ $id.PID)
        if (!$p.Count) { continue }
        if (!$p[0].Image -or !$p[0].CreatedUtc) { return $true }    # unreadable right now: not proven gone
        if (Test-IW7ResourceIdentity $id $p[0]) { return $true }
    }
    $false
}
function Get-IW7TicketGraceSeconds($Ticket) {
    $policy=Get-IW7QueuePolicy
    if ([int]$Ticket.Polls -le 1) { return $policy.FirstGraceSeconds }
    [math]::Min($policy.MaxGraceSeconds,[math]::Max($policy.MinGraceSeconds,2*[double]$Ticket.LastIntervalSeconds+30))
}
function Open-IW7ResourceQueue($Processes, [switch]$ReadOnly) {
    # Reads the queue and drops expired tickets (logged and saved unless ReadOnly). Never throws.
    $context=[pscustomobject]@{Queue=$null;NowMs=0L;Processes=$Processes;Ticket=$null;Overtook=@()}
    try {
        $context.NowMs=Get-IW7NowMs
        $queue=Read-IW7ResourceQueue
        $keep=@(); $expired=@()
        foreach ($t in @($queue.Tickets)) {
            $idle=($context.NowMs-[long]$t.LastMs)/1000
            $why=$null
            if ($null -ne $Processes -and !(Test-IW7TicketCallerAlive $t $Processes)) { $why='caller gone' }
            elseif ($idle -gt (Get-IW7TicketGraceSeconds $t)) { $why='not asked again for '+(Format-IW7Age $idle) }
            if ($why) { $expired+=[pscustomobject]@{Ticket=$t;Why=$why} } else { $keep+=$t }
        }
        $queue.Tickets=@($keep | Sort-Object { [long]$_.FirstMs },{ [long]$_.Seq })
        $context.Queue=$queue
        if ($expired.Count -and !$ReadOnly) {
            foreach ($e in $expired) {
                Add-IW7AdmissionLog ([pscustomobject]@{Event='expire';Kind=$e.Ticket.Kind;Shareable=[bool]$e.Ticket.Shareable;Owner=$e.Ticket.Owner;
                    Scope=$e.Ticket.Scope;WaitSeconds=[math]::Round(($context.NowMs-[long]$e.Ticket.FirstMs)/1000,1);Why=$e.Why})
            }
            Save-IW7ResourceQueue $queue
        }
    } catch { $context.Queue=$null }
    $context
}
function Get-IW7QueueTicket($Context, [string]$Scope, [string]$Kind) {
    if (!$Context -or !$Context.Queue) { return $null }
    @($Context.Queue.Tickets | Where-Object { $_.Scope -eq $Scope -and $_.Kind -eq $Kind })[0]
}
function Get-IW7TicketsAhead($Context, $Mine) {
    if (!$Context -or !$Context.Queue) { return @() }
    @($Context.Queue.Tickets | Where-Object { !$Mine -or ([long]$_.FirstMs -lt [long]$Mine.FirstMs -or
        ([long]$_.FirstMs -eq [long]$Mine.FirstMs -and [long]$_.Seq -lt [long]$Mine.Seq)) } |
        Where-Object { !$Mine -or !($_.Scope -eq $Mine.Scope -and $_.Kind -eq $Mine.Kind) })
}
function Format-IW7Tickets($Context, $Tickets, [int]$Max=3) {
    $shown=@($Tickets | Select-Object -First $Max | ForEach-Object {
        $kind=if ($_.Shareable) { 'Runtime shareable' } else { $_.Kind }
        "'$($_.Owner)' ($kind, waiting $(Format-IW7Age (($Context.NowMs-[long]$_.FirstMs)/1000)))" })
    $text=$shown -join ', '
    if (@($Tickets).Count -gt $Max) { $text+=" and $(@($Tickets).Count-$Max) more" }
    $text
}
function Test-IW7TicketCanFit($Ticket, $Plan) {
    # An older shareable ticket only holds back later requests while it could be satisfied by waiting:
    # its request is no more than measured free memory plus what running shareable sessions declare.
    # Otherwise later requests that fit go first and the ticket keeps its place (deadlock of 2026-11-11).
    if (!$Ticket.Shareable -or !$Plan) { return $true }
    [long]$Ticket.PhysicalBytes -le (Get-IW7ShareableReachBytes $Plan)
}
function Assert-IW7QueueTurn($Context, [string]$Scope, [string]$Kind, [bool]$Shareable, [int]$ShortSeconds, $Plan=$null) {
    # Called only when everything else admits a NEW lease. Throws the queue refusal, or returns.
    # Plan: the shareable memory plan of this moment (Get-IW7ShareableMemoryPlan over every held lease).
    if (!$Context -or !$Context.Queue) { return }
    $policy=Get-IW7QueuePolicy
    $mine=Get-IW7QueueTicket $Context $Scope $Kind
    $ahead=@(Get-IW7TicketsAhead $Context $mine)
    if (!$ahead.Count) { return }
    $possible=@($ahead | Where-Object { Test-IW7TicketCanFit $_ $Plan })
    $passed=$ahead.Count-$possible.Count
    if ($Shareable) {
        $blockers=@($possible | Where-Object { !$_.Shareable -or (($Context.NowMs-[long]$_.FirstMs)/1000) -ge $policy.AgingSeconds })
    } else {
        $blockers=$possible
        if ($blockers.Count -and $ShortSeconds -gt 0 -and !@($blockers | Where-Object { [double]$_.OvertakenSeconds+$ShortSeconds -gt $policy.MaxOvertakeSeconds }).Count) {
            $Context.Overtook=$blockers
            return
        }
    }
    if (!$blockers.Count) { return }
    $note=if ($passed) { " ($passed earlier request(s) that cannot fit now are passed)" } else { '' }
    throw ("Resource busy: waiting in turn: $($blockers.Count) earlier request(s) go first: $(Format-IW7Tickets $Context $blockers)$note. " +
        'Continue light work; retry when released.')
}
function Remove-IW7NeverFitTicket($Context, [string]$Message, [string]$Scope, [string]$Kind, [string]$Owner, [long]$PhysicalBytes) {
    # A request refused as never fitting leaves the queue at once and the refusal is logged. Never throws.
    try {
        if ($Context -and $Context.Queue) {
            $mine=Get-IW7QueueTicket $Context $Scope $Kind
            if ($mine) {
                $Context.Queue.Tickets=@($Context.Queue.Tickets | Where-Object { !([object]::ReferenceEquals($_,$mine)) })
                Save-IW7ResourceQueue $Context.Queue
            }
        }
        Add-IW7AdmissionLog ([pscustomobject]@{Event='refuse';Kind=$Kind;Shareable=$true;Short=0;Owner=$Owner;Scope=$Scope;
            Pid=(Get-IW7CallerPid);Place=0;Of=$(if ($Context -and $Context.Queue) { @($Context.Queue.Tickets).Count } else { 0 });
            WaitSeconds=0;NeverFits=$true;PhysicalBytes=$PhysicalBytes;Reason=$Message.Substring(0,[math]::Min(300,$Message.Length))})
    } catch { }
}
function Register-IW7QueueRefusal($Context, [string]$Message, [string]$Scope, [string]$Kind, [bool]$Shareable,
    [long]$PhysicalBytes, [int]$ShortSeconds, [string]$Owner, [bool]$Queueable=$true) {
    # Refresh or create this request's ticket; return the refusal text with its place. Never throws.
    try {
        if (!$Context -or !$Context.Queue -or !(Test-IW7RetryableRefusal $Message)) { return $Message }
        $queue=$Context.Queue
        $mine=Get-IW7QueueTicket $Context $Scope $Kind
        $callerPid=Get-IW7CallerPid
        $self=@($Context.Processes | Where-Object PID -EQ $callerPid)[0]
        if ($Queueable -and $self -and $self.Image -and $self.CreatedUtc) {
            $parent=@($Context.Processes | Where-Object { $_.PID -eq $self.ParentPID -and $_.Image -and $_.CreatedUtc -and
                ([datetimeoffset]$_.CreatedUtc) -le ([datetimeoffset]$self.CreatedUtc) })[0]
            $own=[pscustomobject]@{PID=$self.PID;CreatedUtc=$self.CreatedUtc;Image=$self.Image}
            $par=if ($parent) { [pscustomobject]@{PID=$parent.PID;CreatedUtc=$parent.CreatedUtc;Image=$parent.Image} } else { $null }
            if ($mine) {
                $mine.LastIntervalSeconds=[math]::Round(($Context.NowMs-[long]$mine.LastMs)/1000,1)
                $mine.LastMs=$Context.NowMs; $mine.Polls=[int]$mine.Polls+1
                $mine.Owner=$Owner; $mine.Shareable=$Shareable; $mine.PhysicalBytes=$PhysicalBytes; $mine.ShortSeconds=$ShortSeconds
                $mine.OwnerIdentity=$own; $mine.ParentIdentity=$par
            } else {
                $queue.Seq=[long]$queue.Seq+1
                $mine=[pscustomobject]@{Seq=$queue.Seq;Scope=$Scope;Kind=$Kind;Shareable=$Shareable;PhysicalBytes=$PhysicalBytes;
                    ShortSeconds=$ShortSeconds;Owner=$Owner;OwnerIdentity=$own;ParentIdentity=$par;FirstMs=$Context.NowMs;LastMs=$Context.NowMs;
                    Polls=1;LastIntervalSeconds=0;OvertakenSeconds=0}
                $queue.Tickets=@($queue.Tickets)+$mine
            }
            Save-IW7ResourceQueue $queue
        }
        $suffix=''; $place=0; $of=@($queue.Tickets).Count; $waited=0
        if ($mine -and @($queue.Tickets | Where-Object { [object]::ReferenceEquals($_,$mine) }).Count) {
            $ahead=@(Get-IW7TicketsAhead $Context $mine)
            $place=$ahead.Count+1; $waited=($Context.NowMs-[long]$mine.FirstMs)/1000
            $suffix=" Queue: place $place of $of, asked first $(Format-IW7Age $waited) ago"
            if ($ahead.Count -and $Message -notlike 'Resource busy: waiting in turn:*') { $suffix+="; ahead: $(Format-IW7Tickets $Context $ahead)" }
            $suffix+='.'
        }
        Add-IW7AdmissionLog ([pscustomobject]@{Event='refuse';Kind=$Kind;Shareable=$Shareable;Short=$ShortSeconds;Owner=$Owner;Scope=$Scope;
            Pid=(Get-IW7CallerPid);Place=$place;Of=$of;WaitSeconds=[math]::Round($waited,1);Reason=$Message.Substring(0,[math]::Min(200,$Message.Length))})
        $Message+$suffix
    } catch { $Message }
}
function Complete-IW7QueueGrant($Context, [string]$Scope, [string]$Kind, [bool]$Shareable, [int]$ShortSeconds, [string]$Owner) {
    # After the lease is saved: drop this request's ticket and log the grant. Never throws.
    try {
        $wait=0.0; $polls=0; $ahead=0
        if ($Context -and $Context.Queue) {
            $mine=Get-IW7QueueTicket $Context $Scope $Kind
            $ahead=@(Get-IW7TicketsAhead $Context $mine).Count
            foreach ($t in @($Context.Overtook)) { $t.OvertakenSeconds=[double]$t.OvertakenSeconds+$ShortSeconds }
            if ($mine) {
                $wait=($Context.NowMs-[long]$mine.FirstMs)/1000; $polls=[int]$mine.Polls
                $Context.Queue.Tickets=@($Context.Queue.Tickets | Where-Object { !([object]::ReferenceEquals($_,$mine)) })
            }
            if ($mine -or @($Context.Overtook).Count) { Save-IW7ResourceQueue $Context.Queue }
        }
        Add-IW7AdmissionLog ([pscustomobject]@{Event='grant';Kind=$Kind;Shareable=$Shareable;Short=$ShortSeconds;Owner=$Owner;Scope=$Scope;
            Pid=(Get-IW7CallerPid);WaitSeconds=[math]::Round($wait,1);Asks=$polls;StillWaiting=$(if ($Context -and $Context.Queue) { @($Context.Queue.Tickets).Count } else { $null });
            Overtook=@($Context.Overtook).Count})
    } catch { }
}
function Get-IW7ResourceWaitReport {
    # Reads the admission log: grants in order, waits per owner, the longest wait. Read-only.
    param([string]$Path=(Get-IW7AdmissionLogPath), [datetime]$Since=[datetime]::MinValue, [datetime]$Until=[datetime]::MaxValue)
    $rows=@()
    foreach ($p in @(([IO.Path]::ChangeExtension($Path,'.1.jsonl')),$Path)) {
        if (![IO.File]::Exists($p)) { continue }
        foreach ($line in [IO.File]::ReadAllLines($p)) {
            if (!$line.Trim()) { continue }
            try { $r=$line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
            $t=([datetimeoffset]$r.Utc).UtcDateTime
            if ($t -lt $Since.ToUniversalTime() -or $t -gt $Until.ToUniversalTime()) { continue }
            $r | Add-Member -NotePropertyName Time -NotePropertyValue $t -Force
            $rows+=$r
        }
    }
    $grants=@($rows | Where-Object Event -EQ 'grant')
    $perOwner=@($grants | Group-Object Owner | ForEach-Object {
        $w=@($_.Group | ForEach-Object { [double]$_.WaitSeconds })
        [pscustomobject]@{Owner=$_.Name;Grants=$_.Count;Waited=@($w | Where-Object { $_ -gt 0 }).Count;
            MeanWaitSeconds=[math]::Round(($w | Measure-Object -Average).Average,1);MaxWaitSeconds=($w | Measure-Object -Maximum).Maximum}
    } | Sort-Object MaxWaitSeconds -Descending)
    [pscustomobject]@{Grants=$grants;PerOwner=$perOwner;
        Longest=@($grants | Sort-Object { [double]$_.WaitSeconds } -Descending)[0];
        Refusals=@($rows | Where-Object Event -EQ 'refuse').Count;Expired=@($rows | Where-Object Event -EQ 'expire');
        Releases=@($rows | Where-Object Event -EQ 'release')}
}
function Enter-IW7ResourceLease {
    param([Parameter(Mandatory)][string]$Scope,
        [ValidateSet('Runtime','Build','Extract','Analysis')][string]$Kind,
        [Parameter(Mandatory)][long]$PhysicalBytes, [Parameter(Mandatory)][long]$CommitBytes,
        [Parameter(Mandatory)][ValidateLength(1,100)][string]$Owner,
        [string]$BaseClientImage, [switch]$RequireNewLease, [switch]$Shareable,
        [ValidateRange(0,120)][int]$ShortSeconds=0)
    $canonical = Get-IW7CanonicalScope $Scope
    if ($PhysicalBytes -le 0 -or $CommitBytes -le 0) { throw 'A positive full-workload reservation is required.' }
    if ($Shareable -and ($Kind -ne 'Runtime' -or $BaseClientImage)) {
        throw 'Shareable is only valid on a Runtime reservation without BaseClientImage.'
    }
    if ($Shareable -and $ShortSeconds) { throw 'ShortSeconds is only valid on an exclusive reservation.' }
    if ($BaseClientImage) {
        if ($Kind -ne 'Runtime' -or ![IO.Path]::IsPathRooted($BaseClientImage) -or
            [IO.Path]::GetExtension($BaseClientImage) -ne '.exe') { throw 'A base client needs one absolute executable declared on a runtime reservation.' }
        $BaseClientImage=[IO.Path]::GetFullPath($BaseClientImage)
    }
    Invoke-IW7ResourceLock {
        $state = Read-IW7ResourceState
        if ($RequireNewLease -and @($state.Leases).Count) {
            throw 'A new resource lease was required; an existing reservation is retained. Do not retry without RequireNewLease.'
        }
        $processes = @(Get-IW7ResourceProcesses)
        $queue = Open-IW7ResourceQueue $processes
        $same = @()
        try {
        $reclaim = @{}
        if ($Shareable) { $reclaim = @{TolerateOtherAmbiguity=$true; ExceptScope=$canonical; ExceptKind=$Kind} }
        Remove-IW7FinishedRuntimeLeases $state $processes @reclaim
        $same = @($state.Leases | Where-Object { $_.Scope -eq $canonical -and $_.Kind -eq $Kind })
        $other = @($state.Leases | Where-Object { $_.Scope -ne $canonical -or $_.Kind -ne $Kind })
        if ($same.Count) {
            $sameFlag = $same[0].PSObject.Properties['Shareable']
            if ($Shareable -or ($sameFlag -and $sameFlag.Value)) {
                if ([bool]$Shareable -ne (Test-IW7ShareableRuntimeLease $same[0])) { throw 'Shareable declaration cannot change after reservation.' }
            }
        }
        # Only shareable Runtime requests may coexist, and only with shareable Runtime leases.
        $otherShareable = @()
        if ($other.Count) {
            if ($Shareable) { $otherShareable = @($other | Where-Object { Test-IW7ShareableRuntimeLease $_ }) }
            if (!$Shareable -or $otherShareable.Count -ne $other.Count) {
                $blocker = @($other | Where-Object { !$Shareable -or !(Test-IW7ShareableRuntimeLease $_) })[0]
                throw "Resource busy: $($blocker.Kind) owned by $($blocker.Owner). Continue light work; retry when released."
            }
            $limit = Get-IW7ShareableRuntimeLeaseLimit
            if ($other.Count -ge $limit) {
                $names=@($other | ForEach-Object Owner)
                $shown=($names | Select-Object -First 5) -join ', '
                if ($names.Count -gt 5) { $shown += " and $($names.Count-5) more" }
                throw "Resource busy: shareable Runtime cap of $limit leases reached; owned by $shown. Continue light work; retry when released."
            }
            $overlap = @($other | Where-Object { Test-IW7ScopeOverlap $_.Scope $canonical })
            if ($overlap.Count) {
                throw "Resource busy: shareable Runtime scope overlaps the lease owned by $($overlap[0].Owner). Use a separate bench root."
            }
        }
        if ($same.Count -gt 1) { throw 'Duplicate lease; registry requires investigation.' }
        # Runtime re-entry is a lab transaction; builds must never nest/share a lease.
        if ($same.Count -and $Kind -ne 'Runtime') { throw 'Heavy job already reserved, including this worktree.' }
        if ($same.Count -and $BaseClientImage -and $same[0].BaseClientImage -ne $BaseClientImage) { throw 'Base client declaration cannot change after reservation.' }
        # A lab of another shareable lease is reserved, not foreign, for a shareable request.
        $sharedLab = { param($p) foreach ($l in $otherShareable) {
            if ((Test-IW7ReservedProcess $p $l) -or @($l.Processes | Where-Object { Test-IW7ResourceIdentity $_ $p }).Count) { return $true } }
            return $false }
        $foreignLabs = @($processes | Where-Object { ($_.Lab -or $_.Name -eq 'iw7-paris-lab.exe') -and
            !(Test-IW7ProcessInScope $_ $canonical) -and !($same.Count -and (Test-IW7ReservedProcess $_ $same[0])) -and
            !($otherShareable.Count -and (& $sharedLab $_)) })
        if ($foreignLabs.Count) { throw 'An unreserved or foreign laboratory is running; wait for its owner to close it.' }
        if (!$same.Count -and @($processes | Where-Object { ($_.Lab -or $_.Name -eq 'iw7-paris-lab.exe' -or ($BaseClientImage -and $_.Image -eq $BaseClientImage)) -and
            !($otherShareable.Count -and (& $sharedLab $_)) }).Count) {
            throw 'Existing lab has no reservation. Close it through its owner before first admission.'
        }
        $builders = @($processes | Where-Object { $_.Name -match '^(?:zonetool.*|MSBuild|cl|link|java)\.exe$' })
        if ($builders.Count) { throw 'An existing compiler/extractor/Java analysis is running; wait before heavy admission.' }
        $resident = 0L; $committed = 0L
        if ($same.Count) {
            $lease = $same[0]
            $PhysicalBytes = [math]::Max($PhysicalBytes, [long]$lease.PhysicalBytes)
            $CommitBytes = [math]::Max($CommitBytes, [long]$lease.CommitBytes)
            foreach ($p in @(Get-IW7LeaseLiveProcesses $lease $processes)) {
                $resident += $p.WorkingSet; $committed += $p.PrivateBytes
            }
        }
        $snapshot = Get-IW7ResourceSnapshot
        $budget = Test-IW7ResourceBudget $snapshot ([math]::Max(0L,$PhysicalBytes-$resident)) ([math]::Max(0L,$CommitBytes-$committed))
        # Admission by memory (decision 2026-11-10). A re-entry that does not grow the
        # declaration adds no demand and is never refused here; nothing is saved on refusal.
        $queuePlan = $null
        if ($Shareable -and (!$same.Count -or $PhysicalBytes -gt [long]$same[0].PhysicalBytes)) {
            $plan = Get-IW7ShareableMemoryPlan $snapshot $otherShareable $processes
            $queuePlan = $plan
            # A new request that cannot fit even after every running shareable session ends: refused now.
            if (!$same.Count) { Assert-IW7ShareableCanFit $plan $PhysicalBytes }
            Assert-IW7ShareableMemoryAdmission $plan $PhysicalBytes ([math]::Max(0L,$PhysicalBytes-$resident))
        }
        # Waiting order: a new lease that would be admitted still waits for its turn; older shareable
        # tickets that cannot fit now (free + held below their request) do not hold it back.
        if (!$same.Count) {
            if (!$queuePlan) { $queuePlan = Get-IW7ShareableMemoryPlan $snapshot @($other) $processes }
            Assert-IW7QueueTurn $queue $canonical $Kind ([bool]$Shareable) $ShortSeconds $queuePlan
        }
        } catch {
            $message = $_.Exception.Message
            # A request that can never fit is refused at once: its ticket leaves the queue.
            if ($message -like 'Refused: this session can never fit*') {
                Remove-IW7NeverFitTicket $queue $message $canonical $Kind $Owner $PhysicalBytes
                throw
            }
            # Re-entry of an existing lease (or a duplicate of it) holds already: never queued.
            $queueable = !@($same).Count
            $augmented = Register-IW7QueueRefusal $queue $message $canonical $Kind ([bool]$Shareable) $PhysicalBytes $ShortSeconds $Owner $queueable
            if ($augmented -ceq $message) { throw }
            throw $augmented
        }
        if (!$same.Count) {
            $identity = @($processes | Where-Object PID -EQ $PID)[0]
            if (!$identity.Image -or !$identity.CreatedUtc) { throw 'Launcher identity unavailable.' }
            $lease = [pscustomobject]@{Token=[guid]::NewGuid().ToString('N');Scope=$canonical;Kind=$Kind;Owner=$Owner;
                OwnerIdentity=$identity;CreatedUtc=(Get-IW7SchedulerUtcNow).ToString('o');Phase='Pending';
                PhysicalBytes=$PhysicalBytes;CommitBytes=$CommitBytes;BaseClientImage=$BaseClientImage;Shareable=[bool]$Shareable;Processes=@()}
            if ($ShortSeconds) { Add-Member -InputObject $lease -NotePropertyName ShortSeconds -NotePropertyValue $ShortSeconds }
            $state.Leases = @($state.Leases) + $lease
        }
        $lease.PhysicalBytes=$PhysicalBytes; $lease.CommitBytes=$CommitBytes
        Add-Member -InputObject $lease -NotePropertyName MemoryObservation -NotePropertyValue (
            [pscustomobject]@{Snapshot=$snapshot;Budget=$budget}) -Force
        Save-IW7ResourceState $state
        if (!$same.Count) { Complete-IW7QueueGrant $queue $canonical $Kind ([bool]$Shareable) $ShortSeconds $Owner }
        $lease
    }
}
function Add-IW7ResourceProcess {
    param([Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)][int]$ProcessId)
    Invoke-IW7ResourceLock {
        $state=Read-IW7ResourceState
        $lease=@($state.Leases | Where-Object Token -EQ $Token)
        if ($lease.Count -ne 1) { throw 'Resource lease not found.' }
        $processes=@(Get-IW7ResourceProcesses)
        $identity=@($processes | Where-Object PID -EQ $ProcessId)
        if ($identity.Count -ne 1 -or !$identity[0].Image -or !$identity[0].CreatedUtc) { throw 'Child identity unavailable; reservation retained.' }
        if ($lease[0].Kind -eq 'Runtime' -and !(Test-IW7ReservedProcess $identity[0] $lease[0])) {
            throw 'Runtime child is outside its reserved lab.'
        }

        $lease[0].Processes=@($lease[0].Processes | Where-Object PID -NE $ProcessId) + $identity[0]
        $lease[0].Phase='Running'
        Save-IW7ResourceState $state
    }
}
function Exit-IW7ResourceLease {
    param([Parameter(Mandatory)][string]$Token)
    Invoke-IW7ResourceLock {
        $state=Read-IW7ResourceState
        $lease=@($state.Leases | Where-Object Token -EQ $Token)
        if (!$lease.Count) { return }
        $processes=@(Get-IW7ResourceProcesses)
        if (@(Get-IW7LeaseLiveProcesses $lease[0] $processes).Count) { throw 'Reserved child is still alive; lease retained.' }
        if ($lease[0].Kind -eq 'Runtime') {
            if (@($processes | Where-Object { Test-IW7ReservedProcess $_ $lease[0] }).Count) { throw 'Unattached lab process is alive; lease retained.' }
        } else {
            $owner=@($processes | Where-Object PID -EQ $lease[0].OwnerIdentity.PID)
            if ($owner.Count -and (!$owner[0].Image -or !$owner[0].CreatedUtc)) { throw 'Heavy job owner identity unavailable; lease retained.' }
            if ($owner.Count -and $PID -ne $owner[0].PID -and (Test-IW7ResourceIdentity $lease[0].OwnerIdentity $owner[0])) { throw 'Heavy job owner is still alive.' }
            if (@($processes | Where-Object { $_.Name -match '^(?:zonetool.*|MSBuild|cl|link|java)\.exe$' }).Count) { throw 'Heavy child may still be alive; lease retained.' }
        }
        $state.Leases=@($state.Leases | Where-Object Token -NE $Token)
        Save-IW7ResourceState $state
        try {
            $held=((Get-IW7SchedulerUtcNow)-([datetimeoffset]$lease[0].CreatedUtc).UtcDateTime).TotalSeconds
            $short=$lease[0].PSObject.Properties['ShortSeconds']
            $shortValue=if ($short) { [int]$short.Value } else { 0 }
            Add-IW7AdmissionLog ([pscustomobject]@{Event='release';Kind=$lease[0].Kind;Shareable=(Test-IW7ShareableRuntimeLease $lease[0]);
                Short=$shortValue;Owner=$lease[0].Owner;Scope=$lease[0].Scope;HeldSeconds=[math]::Round($held,1);
                Overran=[bool]($shortValue -and $held -gt $shortValue)})
        } catch { }
    }
}
function Get-IW7TicketWhy($Ticket, $Plan, $Leases, [long]$NowMs) {
    # One line: why this ticket waits, with the numbers (Status, display only).
    $policy=Get-IW7QueuePolicy
    $wait=($NowMs-[long]$Ticket.FirstMs)/1000
    $kind=if ($Ticket.Shareable) { 'Runtime shareable' } else { $Ticket.Kind }
    $head="'$($Ticket.Owner)' ($kind, waiting $(Format-IW7Age $wait))"
    $exclusive=@($Leases | Where-Object { !(Test-IW7ShareableRuntimeLease $_) })
    $shared=@($Leases | Where-Object { Test-IW7ShareableRuntimeLease $_ })
    $holders=if (@($Leases).Count) { (@($Leases | Select-Object -First 3 | ForEach-Object { "'$($_.Owner)'" }) -join ', ') } else { 'none' }
    if (!$Ticket.Shareable) {
        if (@($Leases).Count) { return "$head needs the machine alone; held by $(@($Leases).Count) reservation(s): $holders." }
        return "$head needs the machine alone; nothing is held: its next ask is granted unless an older request that can fit is waiting."
    }
    if ($exclusive.Count) { return "$head waits for the exclusive $($exclusive[0].Kind) of '$($exclusive[0].Owner)'." }
    $need=[long]$Ticket.PhysicalBytes
    $free=[math]::Max(0L,[long]$Plan.Available-[long]$Plan.Unloaded)
    $reach=Get-IW7ShareableReachBytes $Plan
    $numbers="needs $(Format-IW7Gb $need), free $(Format-IW7Gb $free) ($(Format-IW7Gb $Plan.Available) available minus $(Format-IW7Gb $Plan.Unloaded) still to be taken), held $(Format-IW7Gb $Plan.Declared) by $($shared.Count) running shareable session(s)"
    if ($need -gt $reach) {
        return "$head $numbers. It cannot fit as things stand (at most $(Format-IW7Gb $reach) can come free by waiting): later requests that fit go first; asked again, it is refused."
    }
    if ($need -le $free -and $Plan.Declared+$need -le $Plan.Budget) { return "$head $numbers. It fits now: its next ask is granted unless an older request goes first." }
    $aged=$wait -ge $policy.AgingSeconds
    $rule=if ($aged) { 'it has waited over the aging time: later sessions wait behind it' } else { "later sessions that fit may pass it for another $(Format-IW7Age ($policy.AgingSeconds-$wait))" }
    "$head $numbers. It fits once running sessions end; $rule."
}
function Get-IW7ResourceStatus {
    Invoke-IW7ResourceLock {
        $state=Read-IW7ResourceState
        $snapshot=Get-IW7ResourceSnapshot
        # Display only (never saved): a lease without the flag is exclusive.
        foreach ($lease in @($state.Leases)) {
            if (!$lease.PSObject.Properties['Shareable']) { Add-Member -InputObject $lease -NotePropertyName Shareable -NotePropertyValue $false }
        }
        # Why a shareable caller waits: reserve, declared total, remaining declared
        # budget, measured available memory and the promised-but-untaken part.
        $plan=$null; $unloaded=$null; $processes=$null
        try { $processes=@(Get-IW7ResourceProcesses); $plan=Get-IW7ShareableMemoryPlan $snapshot @($state.Leases) $processes; $unloaded=$plan.Unloaded }
        catch { $plan=Get-IW7ShareableMemoryPlan $snapshot @($state.Leases) @() }
        # Waiting order, display only: nothing is saved by Status.
        $queue=Open-IW7ResourceQueue $processes -ReadOnly
        $nowUtc=Get-IW7SchedulerUtcNow
        foreach ($lease in @($state.Leases)) {
            $age=$null; try { $age=[math]::Round(($nowUtc-([datetimeoffset]$lease.CreatedUtc).UtcDateTime).TotalSeconds) } catch { }
            Add-Member -InputObject $lease -NotePropertyName HeldSeconds -NotePropertyValue $age -Force
        }
        $place=0
        $waiting=@(if ($queue.Queue) { foreach ($t in @($queue.Queue.Tickets)) { $place++
            [pscustomobject]@{Place=$place;Owner=$t.Owner;Kind=$t.Kind;Shareable=[bool]$t.Shareable;ShortSeconds=[int]$t.ShortSeconds;
                Scope=$t.Scope;PhysicalBytes=[long]$t.PhysicalBytes;WaitingSeconds=[math]::Round(($queue.NowMs-[long]$t.FirstMs)/1000);
                LastAskedSecondsAgo=[math]::Round(($queue.NowMs-[long]$t.LastMs)/1000);Asks=[int]$t.Polls;CallerPid=$t.OwnerIdentity.PID;
                CanFit=[bool](Test-IW7TicketCanFit $t $plan);Why=(Get-IW7TicketWhy $t $plan @($state.Leases) $queue.NowMs)} } })
        $why=if ($waiting.Count) { "Head of queue: $($waiting[0].Why)" } else { 'Queue empty.' }
        [pscustomobject]@{Why=$why;Snapshot=$snapshot;Budget=(Test-IW7ResourceBudget $snapshot 0 0);Leases=@($state.Leases);Queue=$waiting;
            ShareableReachBytes=(Get-IW7ShareableReachBytes $plan);
            ShareableRuntimeLimit=(Get-IW7ShareableRuntimeLeaseLimit);
            ShareableReserveBytes=$plan.Reserve;ShareableDeclaredBytes=$plan.Declared;
            ShareableRemainingDeclaredBytes=[math]::Max(0L,$plan.Budget-$plan.Declared);
            ShareableAvailableBytes=$plan.Available;ShareableUnloadedBytes=$unloaded}
    }
}
# Windows 11 power-throttles (EcoQoS: efficiency cores, low clock) hidden processes it judges to be background
# work, BelowNormal ones most of all, even on an idle machine, and the opt-out of a parent is not inherited by
# its children. While a job body runs, this guard opts the host and every process it starts out of
# execution-speed throttling. BelowNormal is kept, so the owner's game still wins any CPU contention, and while
# the owner's game (iw7-cb-aurora.exe) runs the guard hands the choice back to Windows, which throttles our jobs
# again so the game keeps the fast cores. Ten times a second it lists process ids (EnumProcesses, about
# 0.2 ms); only a new id is opened, once, for its parent, start time and image name. A descendant is a process
# whose parent is the host or a known descendant started before it, so a grandchild whose parent exited within
# one tick is missed. A job object cannot do this here: the agent shells run inside a job that lets children
# break away silently. It never throws: on failure the job only runs as before, slower.
function Start-IW7ResourceJobQos {
    param([string[]]$GameImages=@('iw7-cb-aurora.exe'),[int]$PeriodMs=100)
    try {
        if (!('IW7Scheduler.JobQos' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
namespace IW7Scheduler {
public sealed class JobQos : IDisposable {
    [StructLayout(LayoutKind.Sequential)] struct Throttle { public uint Version, ControlMask, StateMask; }
    [StructLayout(LayoutKind.Sequential)] struct BasicInfo { public IntPtr ExitStatus, Peb, Affinity, BasePriority, Pid, ParentPid; }
    sealed class Seen { public long Created; public bool Member, Game; public long Mode = -1; }
    [DllImport("psapi.dll", SetLastError = true)] static extern bool EnumProcesses([Out] uint[] pids, int bytes, out int needed);
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetProcessTimes(IntPtr h, out long c, out long e, out long k, out long u);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool QueryFullProcessImageNameW(IntPtr h, int flags, StringBuilder name, ref int size);
    [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr h, int cls, ref BasicInfo info, int size, IntPtr returned);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetProcessInformation(IntPtr h, int cls, ref Throttle t, int size);
    readonly uint self; readonly HashSet<string> games; readonly object gate = new object(); readonly Timer timer;
    readonly Dictionary<uint, Seen> seen = new Dictionary<uint, Seen>(); uint[] pids = new uint[4096]; bool disposed;
    public int Ticks, Changes, Failures, Processes; public bool Fast, GameSeen; public string LastError;
    public JobQos(int selfPid, string[] gameImages, int periodMs) {
        self = (uint)selfPid; games = new HashSet<string>(gameImages, StringComparer.OrdinalIgnoreCase);
        Tick(); timer = new Timer(_ => Tick(), null, periodMs, periodMs);
    }
    static long Created(uint pid) {
        IntPtr h = OpenProcess(0x1000, false, pid); if (h == IntPtr.Zero) return 0;
        try { long c, e, k, u; return GetProcessTimes(h, out c, out e, out k, out u) ? c : 0; } finally { CloseHandle(h); }
    }
    static bool Apply(uint pid, bool fast) {
        IntPtr h = OpenProcess(0x0200, false, pid); if (h == IntPtr.Zero) return false;
        try { var t = new Throttle { Version = 1, ControlMask = fast ? 1u : 0u, StateMask = 0 }; return SetProcessInformation(h, 4, ref t, 12); }
        finally { CloseHandle(h); }
    }
    // Start time, parent id and image name of a process seen for the first time; null when it cannot be read.
    Seen Read(uint pid, out uint parent) {
        parent = 0; IntPtr h = OpenProcess(0x1000, false, pid); if (h == IntPtr.Zero) return null;
        try {
            long c, e, k, u; if (!GetProcessTimes(h, out c, out e, out k, out u)) return null;
            var s = new Seen { Created = c }; var b = new BasicInfo();
            if (NtQueryInformationProcess(h, 0, ref b, Marshal.SizeOf(typeof(BasicInfo)), IntPtr.Zero) == 0) parent = (uint)b.ParentPid.ToInt64();
            var name = new StringBuilder(1024); int size = name.Capacity;
            if (QueryFullProcessImageNameW(h, 0, name, ref size)) s.Game = games.Contains(Path.GetFileName(name.ToString()));
            return s;
        } finally { CloseHandle(h); }
    }
    void Tick() {
        lock (gate) {
            if (disposed) return;
            try { TickCore(); } catch (Exception ex) { Failures++; LastError = ex.Message; }
        }
    }
    void TickCore() {
        Ticks++; int needed;
        while (true) {
            if (!EnumProcesses(pids, pids.Length * 4, out needed)) throw new InvalidOperationException("EnumProcesses " + Marshal.GetLastWin32Error());
            if (needed < pids.Length * 4) break; pids = new uint[pids.Length * 2];
        }
        int n = needed / 4; var live = new HashSet<uint>(); var fresh = new List<KeyValuePair<uint, uint>>(); var freshSeen = new Dictionary<uint, Seen>();
        for (int i = 0; i < n; i++) {
            uint pid = pids[i]; if (pid == 0) continue; live.Add(pid);
            if (seen.ContainsKey(pid)) continue;
            uint parent; Seen s = Read(pid, out parent); if (s == null) continue;
            freshSeen[pid] = s; fresh.Add(new KeyValuePair<uint, uint>(pid, parent));
        }
        foreach (var pid in new List<uint>(seen.Keys)) if (!live.Contains(pid)) seen.Remove(pid);
        // Parents before children: classify the new processes in start-time order.
        fresh.Sort((a, b) => freshSeen[a.Key].Created.CompareTo(freshSeen[b.Key].Created));
        foreach (var f in fresh) {
            Seen s = freshSeen[f.Key], p;
            s.Member = f.Key == self || (seen.TryGetValue(f.Value, out p) && p.Member && p.Created <= s.Created);
            seen[f.Key] = s;
        }
        bool game = false; foreach (var s in seen.Values) if (s.Game) { game = true; break; }
        Fast = !game; if (game) GameSeen = true; long mode = Fast ? 1 : 0; int members = 0;
        foreach (var m in seen) {
            if (!m.Value.Member) continue; members++;
            if (m.Value.Mode == mode) continue;
            if (Apply(m.Key, Fast)) { m.Value.Mode = mode; Changes++; } else Failures++;
        }
        Processes = members;
    }
    public void Dispose() {
        lock (gate) {
            if (disposed) return; disposed = true; timer.Dispose();
            foreach (var m in seen) if (m.Value.Member && m.Value.Mode == 1 && Created(m.Key) == m.Value.Created) Apply(m.Key, false);
            seen.Clear();
        }
    }
}
}
'@
        }
        return [IW7Scheduler.JobQos]::new($PID,[string[]]$GameImages,$PeriodMs)
    } catch {
        Write-Warning ("Resource job runs without the power-throttling opt-out: " + $_.Exception.Message)
        return $null
    }
}
function Stop-IW7ResourceJobQos($Qos) {
    if ($null -eq $Qos) { return }
    try { $Qos.Dispose() } catch { Write-Warning ("Power-throttling opt-out stop failed: " + $_.Exception.Message) }
}
function Invoke-IW7ResourceJob {
    param([Parameter(Mandatory)][scriptblock]$Body,[Parameter(Mandatory)][string]$Scope,
        [ValidateSet('Build','Extract','Analysis')][string]$Kind='Build',
        [long]$PhysicalBytes=4GB,[long]$CommitBytes=6GB,[string]$Owner='native build',
        [scriptblock]$BeforeReleaseCheck=$null,[object]$OriginalContext=$null,[object]$RetentionRoot=$null)
    if ($PSBoundParameters.ContainsKey('BeforeReleaseCheck') -or $PSBoundParameters.ContainsKey('OriginalContext') -or
        $PSBoundParameters.ContainsKey('RetentionRoot')) {
        foreach ($private:jobArgument in @('BeforeReleaseCheck','OriginalContext','RetentionRoot')) {
            if (!$PSBoundParameters.ContainsKey($private:jobArgument) -or $null -eq $PSBoundParameters[$private:jobArgument]) {
                throw 'BeforeReleaseCheck, OriginalContext and RetentionRoot must be supplied together and non-null.'
            }
        }
        $private:jobNames=@('ResourceJobLease','ResourceJobFirstErrorRecord','ResourceJobFirstException',
            'ResourceJobSecondaryErrors','ResourceJobReleaseAttempted','ResourceJobReleaseReturned')
        if ($OriginalContext -isnot [Management.Automation.PSCustomObject] -or
            @($OriginalContext.PSObject.Properties).Count -ne 6) { throw 'OriginalContext requires the fresh six-slot data view.' }
        $private:jobSlots=@{}
        foreach ($private:jobName in $private:jobNames) {
            $private:jobSlot=$OriginalContext.PSObject.Properties[$private:jobName]
            if ($null -eq $private:jobSlot -or $private:jobSlot.Name -cne $private:jobName -or
                $private:jobSlot.GetType() -ne [Management.Automation.PSNoteProperty] -or
                !$private:jobSlot.IsGettable -or !$private:jobSlot.IsSettable) { throw 'Only mutable original note-property view slots are accepted.' }
            $private:jobSlots[$private:jobName]=$private:jobSlot
        }
        foreach ($private:jobName in $private:jobNames[0..3]) {
            if ($null -ne $private:jobSlots[$private:jobName].Value) { throw 'OriginalContext view is already used or malformed.' }
        }
        foreach ($private:jobName in $private:jobNames[4..5]) {
            if ($private:jobSlots[$private:jobName].Value -isnot [bool] -or $private:jobSlots[$private:jobName].Value) {
                throw 'Fresh Boolean release mirrors are required.'
            }
        }
        # Standard CLR property access bypasses any added PowerShell accessor.
        $private:jobTypeMethod=[object].GetMethod('GetType')
        if ($private:jobTypeMethod.Invoke($RetentionRoot,$null) -ne [Management.Automation.PSVariable]) { throw 'The actual caller PSVariable is required.' }
        $private:jobRoot=$RetentionRoot
        $private:jobRootValue=[Management.Automation.PSVariable].GetProperty('Value')
        $private:jobRootOptions=[Management.Automation.PSVariable].GetProperty('Options')
        $private:jobRootName=[Management.Automation.PSVariable].GetProperty('Name').GetValue($private:jobRoot)
        $private:jobInitialOptions=$private:jobRootOptions.GetValue($private:jobRoot)
        if ($private:jobRootName -cnotmatch '\A[A-Za-z_][A-Za-z0-9_]{0,63}\z' -or
            $null -ne $private:jobRootValue.GetValue($private:jobRoot) -or
            [Management.Automation.PSVariable].GetProperty('Attributes').GetValue($private:jobRoot).Count -ne 0 -or
            ($private:jobInitialOptions -band ([Management.Automation.ScopedItemOptions]::ReadOnly -bor
                [Management.Automation.ScopedItemOptions]::Constant)) -ne 0) { throw 'A fresh mutable empty caller root is required.' }
        $private:jobDomainKey='IW7.ResourceJob.RetainedRelease.'+$private:jobRootName
        if (![object]::ReferenceEquals((Get-Variable -Name $private:jobRootName -ErrorAction SilentlyContinue),$private:jobRoot) -or
            ![object]::ReferenceEquals([AppDomain]::CurrentDomain.GetData($private:jobDomainKey),$private:jobRoot)) {
            throw 'The same registered caller variable and AppDomain witness are required before admission.'
        }
        # Only private writers can mutate these containers. The hook gets a view.
        $private:jobContext=$OriginalContext
        $private:jobJournal=[Collections.Generic.List[object]]::new(4)
        $private:jobSecondary=[Collections.Generic.List[Management.Automation.ErrorRecord]]::new(4)
        $private:jobJournalView=$private:jobJournal.AsReadOnly()
        $private:jobSecondaryView=$private:jobSecondary.AsReadOnly()
        $private:jobEvidence=[object[]]::new(4)
        $private:jobJournalCount=0
        $private:jobStore=[Collections.Generic.Dictionary[string,object]]::new(16,[StringComparer]::Ordinal)
        foreach ($private:jobKey in @('Lease','Token','TokenSlot','FirstErrorRecord','FirstException','OverflowErrorRecord','OverflowException')) {
            $private:jobStore[$private:jobKey]=$null
        }
        foreach ($private:jobKey in @('ReleaseAttempted','ReleaseReturned','ViewContradiction','JournalOverflow')) { $private:jobStore[$private:jobKey]=$false }
        $private:jobStore['OriginalContext']=$private:jobContext
        $private:jobSlotArray=[Management.Automation.PSNoteProperty[]]::new(6)
        for ($private:jobIndex=0;$private:jobIndex-lt6;$private:jobIndex++) { $private:jobSlotArray[$private:jobIndex]=$private:jobSlots[$private:jobNames[$private:jobIndex]] }
        $private:jobStore['OriginalSlots']=[array]::AsReadOnly($private:jobSlotArray)
        $private:jobStore['Journal']=$private:jobJournalView
        $private:jobStore['SecondaryErrors']=$private:jobSecondaryView
        $private:jobOwner=[Collections.ObjectModel.ReadOnlyDictionary[string,object]]::new($private:jobStore)
        $private:jobExpected=@{}
        foreach ($private:jobName in $private:jobNames) { $private:jobExpected[$private:jobName]=$private:jobSlots[$private:jobName].Value }
        $private:jobProjection=@{ResourceJobLease='Lease';ResourceJobFirstErrorRecord='FirstErrorRecord';ResourceJobFirstException='FirstException';
            ResourceJobSecondaryErrors='SecondaryErrors';ResourceJobReleaseAttempted='ReleaseAttempted';ResourceJobReleaseReturned='ReleaseReturned'}
        $private:jobRootValue.SetValue($private:jobRoot,$private:jobOwner)
        $private:jobBoundOptions=$private:jobInitialOptions -bor [Management.Automation.ScopedItemOptions]::ReadOnly
        $private:jobRootOptions.SetValue($private:jobRoot,$private:jobBoundOptions)
        if (![object]::ReferenceEquals($private:jobRootValue.GetValue($private:jobRoot),$private:jobOwner) -or
            $private:jobRootOptions.GetValue($private:jobRoot) -ne $private:jobBoundOptions -or
            ![object]::ReferenceEquals([AppDomain]::CurrentDomain.GetData($private:jobDomainKey),$private:jobRoot)) { throw 'Durable caller binding failed before admission.' }

        # Dot-invoked private helpers run here; external Body/hook child scopes
        # cannot resolve the private writers by ordinary variable resolution.
        $private:jobProject={
            foreach ($private:jobName in $private:jobNames) {
                $private:jobSlot=$private:jobSlots[$private:jobName]
                $private:jobOld=$private:jobExpected[$private:jobName]
                $private:jobSame=[object]::ReferenceEquals($private:jobContext.PSObject.Properties[$private:jobName],$private:jobSlot)
                if ($private:jobSame) {
                    if ($private:jobName -cin $private:jobNames[4..5]) {
                        $private:jobSame=$private:jobSlot.Value -is [bool] -and $private:jobSlot.Value -eq $private:jobOld
                    } else { $private:jobSame=[object]::ReferenceEquals($private:jobSlot.Value,$private:jobOld) }
                }
                if (!$private:jobSame) { $private:jobStore['ViewContradiction']=$true;continue }
                $private:jobNew=$private:jobStore[$private:jobProjection[$private:jobName]]
                $private:jobSlot.Value=$private:jobNew
                $private:jobExpected[$private:jobName]=$private:jobNew
            }
        }
        $private:jobRecordError={
            param([Management.Automation.ErrorRecord]$jobCapturedRecord,[string]$jobCapturedFrontier)
            # Capture authority before any fallible projection to caller mirrors.
            if ($null -eq $private:jobStore['FirstErrorRecord']) {
                $private:jobStore['FirstErrorRecord']=$jobCapturedRecord
                $private:jobStore['FirstException']=$jobCapturedRecord.Exception
            }
            if ($private:jobJournalCount -ge 4) {
                $private:jobStore['JournalOverflow']=$true
                if ($null -eq $private:jobStore['OverflowErrorRecord']) {
                    $private:jobStore['OverflowErrorRecord']=$jobCapturedRecord;$private:jobStore['OverflowException']=$jobCapturedRecord.Exception
                }
                return
            }
            $private:jobRow=[Collections.Generic.Dictionary[string,object]]::new(4,[StringComparer]::Ordinal)
            $private:jobRow['Ordinal']=$private:jobJournalCount
            $private:jobRow['Frontier']=$jobCapturedFrontier
            $private:jobRow['ErrorRecord']=$jobCapturedRecord
            $private:jobRow['Exception']=$jobCapturedRecord.Exception
            $private:jobEntry=[Collections.ObjectModel.ReadOnlyDictionary[string,object]]::new($private:jobRow)
            $private:jobJournal.Add($private:jobEntry)
            $private:jobEvidence[$private:jobJournalCount]=[object[]]@($private:jobEntry,$jobCapturedRecord,$jobCapturedRecord.Exception,$jobCapturedFrontier)
            if ($private:jobJournalCount -gt 0) { $private:jobSecondary.Add($jobCapturedRecord) }
            $private:jobJournalCount++
            . $private:jobProject
        }
        $private:jobAssert={
            param([switch]$jobCheckToken)
            if (![object]::ReferenceEquals($RetentionRoot,$private:jobRoot) -or
                ![object]::ReferenceEquals($private:jobRootValue.GetValue($private:jobRoot),$private:jobOwner) -or
                $private:jobRootOptions.GetValue($private:jobRoot) -ne $private:jobBoundOptions -or
                ![object]::ReferenceEquals([AppDomain]::CurrentDomain.GetData($private:jobDomainKey),$private:jobRoot)) { throw 'Original durable owner/root binding changed.' }
            if ($private:jobStore['JournalOverflow'] -or $private:jobStore['ViewContradiction'] -or
                ![object]::ReferenceEquals($OriginalContext,$private:jobContext) -or
                ![object]::ReferenceEquals($private:jobStore['Journal'],$private:jobJournalView) -or
                ![object]::ReferenceEquals($private:jobStore['SecondaryErrors'],$private:jobSecondaryView) -or
                $private:jobJournal.Count -ne $private:jobJournalCount -or
                $private:jobSecondary.Count -ne [Math]::Max(0,$private:jobJournalCount-1)) { throw 'Original error journal/view state changed.' }
            for ($private:jobIndex=0;$private:jobIndex-lt$private:jobJournalCount;$private:jobIndex++) {
                $private:jobSeen=$private:jobJournal[$private:jobIndex];$private:jobSaved=$private:jobEvidence[$private:jobIndex]
                if (![object]::ReferenceEquals($private:jobSeen,$private:jobSaved[0]) -or $private:jobSeen.Count-ne4 -or
                    $private:jobSeen['Ordinal'] -isnot [int] -or $private:jobSeen['Ordinal'] -ne $private:jobIndex -or
                    $private:jobSeen['Frontier'] -isnot [string] -or ![string]::Equals($private:jobSeen['Frontier'],$private:jobSaved[3],[StringComparison]::Ordinal) -or
                    ![object]::ReferenceEquals($private:jobSeen['ErrorRecord'],$private:jobSaved[1]) -or
                    ![object]::ReferenceEquals($private:jobSeen['Exception'],$private:jobSaved[2]) -or
                    ($private:jobIndex-gt0-and![object]::ReferenceEquals($private:jobSecondary[$private:jobIndex-1],$private:jobSaved[1]))) { throw 'Committed original error-journal prefix differs.' }
            }
            if ($private:jobJournalCount-gt0-and
                (![object]::ReferenceEquals($private:jobStore['FirstErrorRecord'],$private:jobEvidence[0][1]) -or
                 ![object]::ReferenceEquals($private:jobStore['FirstException'],$private:jobEvidence[0][2]))) { throw 'First original ErrorRecord/Exception changed.' }
            foreach ($private:jobName in $private:jobNames) {
                if (![object]::ReferenceEquals($private:jobContext.PSObject.Properties[$private:jobName],$private:jobSlots[$private:jobName])) { throw 'Original view property removed or replaced.' }
                $private:jobValue=$private:jobSlots[$private:jobName].Value
                if ($private:jobName -cin $private:jobNames[4..5]) {
                    if ($private:jobValue -isnot [bool] -or $private:jobValue -ne $private:jobExpected[$private:jobName]) { throw 'Original Boolean view mirror changed.' }
                } elseif (![object]::ReferenceEquals($private:jobValue,$private:jobExpected[$private:jobName])) { throw 'Original view reference changed.' }
            }
            if ($jobCheckToken) {
                $private:jobLease=$private:jobStore['Lease']
                if ($null-eq$private:jobLease-or![object]::ReferenceEquals($private:jobLease.PSObject.Properties['Token'],$private:jobStore['TokenSlot'])) { throw 'Original lease/token property changed.' }
                $private:jobLiveToken=$private:jobStore['TokenSlot'].Value
                if ($private:jobLiveToken -isnot [string] -or $private:jobLiveToken -cnotmatch '\A[0-9a-f]{32}\z' -or
                    ![string]::Equals($private:jobLiveToken,$private:jobStore['Token'],[StringComparison]::Ordinal)) { throw 'The live original lease token must remain one exact scalar string.' }
            }
        }
        . $private:jobProject
        . $private:jobAssert
        $private:jobProcess=$null;$private:jobPriority=$null;$private:jobQos=$null
        $private:jobPriorityCaptured=$false;$private:jobPriorityRestored=$false;$private:jobHookApproved=$false
        try {
            $private:jobStore['Lease']=Enter-IW7ResourceLease -Scope $Scope -Kind $Kind -PhysicalBytes $PhysicalBytes -CommitBytes $CommitBytes -Owner $Owner
            # The caller's root already owns this actual lease, before mirrors/getters.
            $private:jobLease=$private:jobStore['Lease']
            if ($null-eq$private:jobLease) { throw 'Actual returned lease required.' }
            $private:jobTokenSlot=$private:jobLease.PSObject.Properties['Token']
            if ($null-eq$private:jobTokenSlot-or$private:jobTokenSlot.GetType()-ne[Management.Automation.PSNoteProperty]) { throw 'Original scalar lease-token data property required.' }
            $private:jobStore['TokenSlot']=$private:jobTokenSlot
            $private:jobLiveToken=$private:jobTokenSlot.Value
            if ($private:jobLiveToken -isnot [string] -or $private:jobLiveToken -cnotmatch '\A[0-9a-f]{32}\z') { throw 'One original32hex scalar token required.' }
            $private:jobStore['Token']=$private:jobLiveToken
            . $private:jobProject
            . $private:jobAssert -jobCheckToken
            $private:jobProcess=Get-Process -Id $PID
            $private:jobPriority=$private:jobProcess.PriorityClass
            if ($private:jobPriority -isnot [Diagnostics.ProcessPriorityClass]) { throw 'Original host priority is unknown.' }
            $private:jobPriorityCaptured=$true
            $private:jobProcess.PriorityClass='BelowNormal'
            $private:jobQos=Start-IW7ResourceJobQos
            . $private:jobAssert -jobCheckToken
            & $Body
            . $private:jobAssert -jobCheckToken
        } catch { . $private:jobRecordError -jobCapturedRecord $_ -jobCapturedFrontier 'SetupBody' }
        finally {
            if ($null-ne$private:jobStore['Lease']) {
                Stop-IW7ResourceJobQos $private:jobQos
                if ($private:jobPriorityCaptured) {
                    try {
                        $private:jobProcess.PriorityClass=$private:jobPriority
                        if ($private:jobProcess.PriorityClass-ne$private:jobPriority) { throw 'Original priority restoration readback differs.' }
                        $private:jobPriorityRestored=$true
                    } catch { . $private:jobRecordError -jobCapturedRecord $_ -jobCapturedFrontier 'Priority' }
                }
                try {
                    . $private:jobAssert -jobCheckToken
                    $private:jobHookResult=& $BeforeReleaseCheck $private:jobContext
                    if ($private:jobHookResult -isnot [bool] -or !$private:jobHookResult) { throw 'BeforeReleaseCheck must return exactly Boolean true.' }
                    . $private:jobAssert -jobCheckToken
                    $private:jobHookApproved=$true
                } catch { . $private:jobRecordError -jobCapturedRecord $_ -jobCapturedFrontier 'Check' }
                if ($private:jobPriorityRestored-and$private:jobHookApproved) {
                    try {
                        . $private:jobAssert -jobCheckToken
                        $private:jobStore['ReleaseAttempted']=$true
                        Exit-IW7ResourceLease -Token $private:jobLiveToken
                        $private:jobStore['ReleaseReturned']=$true
                        . $private:jobProject
                        . $private:jobAssert -jobCheckToken
                    } catch { . $private:jobRecordError -jobCapturedRecord $_ -jobCapturedFrontier 'Release' }
                }
            }
        }
        if ($null-ne$private:jobStore['FirstErrorRecord']) { throw $private:jobStore['FirstErrorRecord'] }
        return
    }
    $lease=Enter-IW7ResourceLease -Scope $Scope -Kind $Kind -PhysicalBytes $PhysicalBytes -CommitBytes $CommitBytes -Owner $Owner
    $process=Get-Process -Id $PID
    $priority=$process.PriorityClass
    $qos=$null
    try {
        $process.PriorityClass='BelowNormal'
        $qos=Start-IW7ResourceJobQos
        & $Body
    } finally {
        Stop-IW7ResourceJobQos $qos
        $process.PriorityClass=$priority
        Exit-IW7ResourceLease -Token $lease.Token
    }
}
# The same plain job as Invoke-IW7ResourceJob, queued: while the slot is held by a temporary holder the
# admission is asked again every five seconds, up to WaitForSlotSeconds. Only a refusal that names such a
# holder is waited for; every other refusal (identity, telemetry, an unreserved laboratory, a duplicate
# lease) is thrown at once, and so is the last refusal at the bound. Invoke-IW7ResourceJob is unchanged.
function Invoke-IW7QueuedResourceJob {
    param([Parameter(Mandatory)][scriptblock]$Body,[Parameter(Mandatory)][string]$Scope,
        [ValidateSet('Build','Extract','Analysis')][string]$Kind='Build',
        [long]$PhysicalBytes=4GB,[long]$CommitBytes=6GB,[string]$Owner='native build',
        [Parameter(Mandatory)][ValidateRange(1,86400)][int]$WaitForSlotSeconds,
        [ValidateRange(0,120)][int]$ShortSeconds=0)
    $waited=[Diagnostics.Stopwatch]::StartNew()
    $said=-60
    $short=@{}; if ($ShortSeconds) { $short.ShortSeconds=$ShortSeconds }
    while ($true) {
        try {
            $lease=Enter-IW7ResourceLease -Scope $Scope -Kind $Kind -PhysicalBytes $PhysicalBytes -CommitBytes $CommitBytes -Owner $Owner @short
            break
        } catch {
            $busy=$_.Exception.Message -like 'Resource busy:*' -or $_.Exception.Message -like 'Resource admission lock busy*' -or
                $_.Exception.Message -like 'An existing compiler/extractor/Java analysis is running;*'
            if (!$busy -or $waited.Elapsed.TotalSeconds -ge $WaitForSlotSeconds) { throw }
            # One line a minute while waiting, with the place in the queue.
            if ($waited.Elapsed.TotalSeconds -ge $said+60) { $said=$waited.Elapsed.TotalSeconds; Write-Host ("waiting {0:N0} s for the {1} reservation: {2}" -f $said,$Kind,$_.Exception.Message) }
            Start-Sleep -Seconds 5
        }
    }
    $process=Get-Process -Id $PID
    $priority=$process.PriorityClass
    $qos=$null
    try {
        $process.PriorityClass='BelowNormal'
        $qos=Start-IW7ResourceJobQos
        & $Body
    } finally {
        Stop-IW7ResourceJobQos $qos
        $process.PriorityClass=$priority
        Exit-IW7ResourceLease -Token $lease.Token
    }
}
