# Shared by every worktree on this Windows account. No process is stopped here.
# Keep admission + reservation atomic; a snapshot alone is not a reservation.
. "$PSScriptRoot/Resource-Memory.ps1"
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
    $physicalReserve = [math]::Max(4GB, $Snapshot.PhysicalTotal * 0.25)
    $commitReserve = [math]::Max(4GB, $Snapshot.CommitLimit * 0.20)
    [pscustomobject]@{
        Allowed = (($Snapshot.PhysicalAvailable - $PhysicalBytes) -ge $physicalReserve -and
            ($Snapshot.CommitLimit - $Snapshot.Committed - $CommitBytes) -ge $commitReserve)
        PhysicalUsedPercent = [math]::Round(100 * (1 - $Snapshot.PhysicalAvailable / $Snapshot.PhysicalTotal), 2)
        CommitUsedPercent = [math]::Round(100 * $Snapshot.Committed / $Snapshot.CommitLimit, 2)
        PhysicalReserve = [long]$physicalReserve
        CommitReserve = [long]$commitReserve
        AdditionalPhysical = $PhysicalBytes
        AdditionalCommit = $CommitBytes
        HighWater = ($Snapshot.PhysicalAvailable -lt $Snapshot.PhysicalTotal * 0.20 -or
            $Snapshot.Committed -gt $Snapshot.CommitLimit * 0.85)
    }
}
function Get-IW7ResourceProcesses {
    # Do not persist command lines: lab commands contain passwords.
    @(Get-CimInstance Win32_Process -OperationTimeoutSec 5 -ErrorAction Stop | ForEach-Object {
        [pscustomobject]@{
            PID = [int]$_.ProcessId
            ParentPID = [int]$_.ParentProcessId
            CreatedUtc = if ($_.CreationDate) { $_.CreationDate.ToUniversalTime().ToString('o') } else { $null }
            Image = $_.ExecutablePath
            Name = $_.Name
            Lab = [bool]($_.CommandLine -match '(?:^|\s)-paris-isolated-lab(?:\s|$)')
            Heavy = [bool]($_.Name -match '^(?:iw7.*|zonetool.*|MSBuild|cl|link|java)\.exe$')
            WorkingSet = [long]$_.WorkingSetSize
            PrivateBytes = [long]$_.PrivatePageCount
        }
    })
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
function Remove-IW7FinishedRuntimeLeases($State, $Processes) {
    $State.Leases = @($State.Leases | Where-Object {
        $lease = $_
        $owner = @($Processes | Where-Object PID -EQ $lease.OwnerIdentity.PID)
        $ownerAlive = $owner.Count -and (Test-IW7ResourceIdentity $lease.OwnerIdentity $owner[0])
        $ownerUnknown = $owner.Count -and (!$owner[0].Image -or !$owner[0].CreatedUtc)
        $live = @(Get-IW7LeaseLiveProcesses $lease $Processes)
        $inScope = @($Processes | Where-Object { Test-IW7ProcessInScope $_ $lease.Scope })
        # A crashed builder might have detached children outside its root. Keep it
        # quarantined until explicit release; runtime children must be inside scope.
        !($lease.Kind -eq 'Runtime' -and !$ownerAlive -and !$ownerUnknown -and !$live.Count -and !$inScope.Count)
    })
}
function Enter-IW7ResourceLease {
    param([Parameter(Mandatory)][string]$Scope,
        [ValidateSet('Runtime','Build','Extract','Analysis')][string]$Kind,
        [Parameter(Mandatory)][long]$PhysicalBytes, [Parameter(Mandatory)][long]$CommitBytes,
        [Parameter(Mandatory)][ValidateLength(1,100)][string]$Owner)
    $canonical = Get-IW7CanonicalScope $Scope
    if ($PhysicalBytes -le 0 -or $CommitBytes -le 0) { throw 'A positive full-workload reservation is required.' }
    Invoke-IW7ResourceLock {
        $state = Read-IW7ResourceState
        $processes = @(Get-IW7ResourceProcesses)
        Remove-IW7FinishedRuntimeLeases $state $processes
        $same = @($state.Leases | Where-Object { $_.Scope -eq $canonical -and $_.Kind -eq $Kind })
        $other = @($state.Leases | Where-Object { $_.Scope -ne $canonical -or $_.Kind -ne $Kind })
        if ($other.Count) { throw "Resource busy: $($other[0].Kind) owned by $($other[0].Owner). Continue light work; retry when released." }
        if ($same.Count -gt 1) { throw 'Duplicate lease; registry requires investigation.' }
        # Runtime re-entry is a lab transaction; builds must never nest/share a lease.
        if ($same.Count -and $Kind -ne 'Runtime') { throw 'Heavy job already reserved, including this worktree.' }
        $foreignLabs = @($processes | Where-Object { ($_.Lab -or $_.Name -eq 'iw7-paris-lab.exe') -and
            !(Test-IW7ProcessInScope $_ $canonical) })
        if ($foreignLabs.Count) { throw 'An unreserved or foreign laboratory is running; wait for its owner to close it.' }
        if (!$same.Count -and @($processes | Where-Object { $_.Lab -or $_.Name -eq 'iw7-paris-lab.exe' }).Count) {
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
        $budget = Test-IW7ResourceBudget (Get-IW7ResourceSnapshot) ([math]::Max(0L,$PhysicalBytes-$resident)) ([math]::Max(0L,$CommitBytes-$committed))
        if (!$budget.Allowed -or $budget.HighWater) {
            throw "Resource budget refuses admission: physical=$($budget.PhysicalUsedPercent)%, commit=$($budget.CommitUsedPercent)%; full workload must leave 25% RAM and 20% commit headroom."
        }
        if (!$same.Count) {
            $identity = @($processes | Where-Object PID -EQ $PID)[0]
            if (!$identity.Image -or !$identity.CreatedUtc) { throw 'Launcher identity unavailable.' }
            $lease = [pscustomobject]@{Token=[guid]::NewGuid().ToString('N');Scope=$canonical;Kind=$Kind;Owner=$Owner;
                OwnerIdentity=$identity;CreatedUtc=[datetime]::UtcNow.ToString('o');Phase='Pending';
                PhysicalBytes=$PhysicalBytes;CommitBytes=$CommitBytes;Processes=@()}
            $state.Leases = @($state.Leases) + $lease
        }
        $lease.PhysicalBytes=$PhysicalBytes; $lease.CommitBytes=$CommitBytes
        Save-IW7ResourceState $state
        $lease
    }
}
function Add-IW7ResourceProcess {
    param([Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)][int]$ProcessId)
    Invoke-IW7ResourceLock {
        $state=Read-IW7ResourceState
        $lease=@($state.Leases | Where-Object Token -EQ $Token)
        if ($lease.Count -ne 1) { throw 'Resource lease not found.' }
        $identity=@(Get-IW7ResourceProcesses | Where-Object PID -EQ $ProcessId)
        if ($identity.Count -ne 1 -or !$identity[0].Image -or !$identity[0].CreatedUtc) { throw 'Child identity unavailable; reservation retained.' }
        if ($lease[0].Kind -eq 'Runtime' -and !(Test-IW7ProcessInScope $identity[0] $lease[0].Scope)) {
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
            if (@($processes | Where-Object { Test-IW7ProcessInScope $_ $lease[0].Scope }).Count) { throw 'Unattached lab process is alive; lease retained.' }
        } else {
            $owner=@($processes | Where-Object PID -EQ $lease[0].OwnerIdentity.PID)
            if ($owner.Count -and (!$owner[0].Image -or !$owner[0].CreatedUtc)) { throw 'Heavy job owner identity unavailable; lease retained.' }
            if ($owner.Count -and $PID -ne $owner[0].PID -and (Test-IW7ResourceIdentity $lease[0].OwnerIdentity $owner[0])) { throw 'Heavy job owner is still alive.' }
            if (@($processes | Where-Object { $_.Name -match '^(?:zonetool.*|MSBuild|cl|link|java)\.exe$' }).Count) { throw 'Heavy child may still be alive; lease retained.' }
        }
        $state.Leases=@($state.Leases | Where-Object Token -NE $Token)
        Save-IW7ResourceState $state
    }
}
function Get-IW7ResourceStatus {
    Invoke-IW7ResourceLock {
        $state=Read-IW7ResourceState
        $snapshot=Get-IW7ResourceSnapshot
        [pscustomobject]@{Snapshot=$snapshot;Budget=(Test-IW7ResourceBudget $snapshot 0 0);Leases=@($state.Leases)}
    }
}
function Invoke-IW7ResourceJob {
    param([Parameter(Mandatory)][scriptblock]$Body,[Parameter(Mandatory)][string]$Scope,
        [ValidateSet('Build','Extract','Analysis')][string]$Kind='Build',
        [long]$PhysicalBytes=4GB,[long]$CommitBytes=6GB,[string]$Owner='native build')
    $lease=Enter-IW7ResourceLease -Scope $Scope -Kind $Kind -PhysicalBytes $PhysicalBytes -CommitBytes $CommitBytes -Owner $Owner
    $process=Get-Process -Id $PID
    $priority=$process.PriorityClass
    try {
        $process.PriorityClass='BelowNormal'
        & $Body
    } finally {
        $process.PriorityClass=$priority
        Exit-IW7ResourceLease -Token $lease.Token
    }
}
