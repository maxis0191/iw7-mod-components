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
function Remove-IW7FinishedRuntimeLeases($State, $Processes) {
    $State.Leases = @($State.Leases | Where-Object {
        $lease = $_
        $owner = @($Processes | Where-Object PID -EQ $lease.OwnerIdentity.PID)
        $ownerAlive = $owner.Count -and (Test-IW7ResourceIdentity $lease.OwnerIdentity $owner[0])
        $ownerUnknown = $owner.Count -and (!$owner[0].Image -or !$owner[0].CreatedUtc)
        $live = @(Get-IW7LeaseLiveProcesses $lease $Processes)
        $inScope = @($Processes | Where-Object { Test-IW7ReservedProcess $_ $lease })
        # A crashed builder might have detached children outside its root. Keep it
        # quarantined until explicit release; runtime children must be inside scope.
        !($lease.Kind -eq 'Runtime' -and !$ownerAlive -and !$ownerUnknown -and !$live.Count -and !$inScope.Count)
    })
}
function Enter-IW7ResourceLease {
    param([Parameter(Mandatory)][string]$Scope,
        [ValidateSet('Runtime','Build','Extract','Analysis')][string]$Kind,
        [Parameter(Mandatory)][long]$PhysicalBytes, [Parameter(Mandatory)][long]$CommitBytes,
        [Parameter(Mandatory)][ValidateLength(1,100)][string]$Owner,
        [string]$BaseClientImage, [switch]$RequireNewLease)
    $canonical = Get-IW7CanonicalScope $Scope
    if ($PhysicalBytes -le 0 -or $CommitBytes -le 0) { throw 'A positive full-workload reservation is required.' }
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
        Remove-IW7FinishedRuntimeLeases $state $processes
        $same = @($state.Leases | Where-Object { $_.Scope -eq $canonical -and $_.Kind -eq $Kind })
        $other = @($state.Leases | Where-Object { $_.Scope -ne $canonical -or $_.Kind -ne $Kind })
        if ($other.Count) { throw "Resource busy: $($other[0].Kind) owned by $($other[0].Owner). Continue light work; retry when released." }
        if ($same.Count -gt 1) { throw 'Duplicate lease; registry requires investigation.' }
        # Runtime re-entry is a lab transaction; builds must never nest/share a lease.
        if ($same.Count -and $Kind -ne 'Runtime') { throw 'Heavy job already reserved, including this worktree.' }
        if ($same.Count -and $BaseClientImage -and $same[0].BaseClientImage -ne $BaseClientImage) { throw 'Base client declaration cannot change after reservation.' }
        $foreignLabs = @($processes | Where-Object { ($_.Lab -or $_.Name -eq 'iw7-paris-lab.exe') -and
            !(Test-IW7ProcessInScope $_ $canonical) -and !($same.Count -and (Test-IW7ReservedProcess $_ $same[0])) })
        if ($foreignLabs.Count) { throw 'An unreserved or foreign laboratory is running; wait for its owner to close it.' }
        if (!$same.Count -and @($processes | Where-Object { $_.Lab -or $_.Name -eq 'iw7-paris-lab.exe' -or ($BaseClientImage -and $_.Image -eq $BaseClientImage) }).Count) {
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
        if (!$same.Count) {
            $identity = @($processes | Where-Object PID -EQ $PID)[0]
            if (!$identity.Image -or !$identity.CreatedUtc) { throw 'Launcher identity unavailable.' }
            $lease = [pscustomobject]@{Token=[guid]::NewGuid().ToString('N');Scope=$canonical;Kind=$Kind;Owner=$Owner;
                OwnerIdentity=$identity;CreatedUtc=[datetime]::UtcNow.ToString('o');Phase='Pending';
                PhysicalBytes=$PhysicalBytes;CommitBytes=$CommitBytes;BaseClientImage=$BaseClientImage;Processes=@()}
            $state.Leases = @($state.Leases) + $lease
        }
        $lease.PhysicalBytes=$PhysicalBytes; $lease.CommitBytes=$CommitBytes
        Add-Member -InputObject $lease -NotePropertyName MemoryObservation -NotePropertyValue (
            [pscustomobject]@{Snapshot=$snapshot;Budget=$budget}) -Force
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
        [long]$PhysicalBytes=4GB,[long]$CommitBytes=6GB,[string]$Owner='native build',
        [scriptblock]$BeforeReleaseCheck=$null,[object]$OriginalContext=$null,[object]$RetentionRoot=$null,
        [switch]$RequireNewLease)
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
        $private:jobProcess=$null;$private:jobPriority=$null
        $private:jobPriorityCaptured=$false;$private:jobPriorityRestored=$false;$private:jobHookApproved=$false
        try {
            if ($RequireNewLease) {
                $private:jobStore['Lease']=Enter-IW7ResourceLease -Scope $Scope -Kind $Kind -PhysicalBytes $PhysicalBytes -CommitBytes $CommitBytes -Owner $Owner -RequireNewLease
            } else {
                $private:jobStore['Lease']=Enter-IW7ResourceLease -Scope $Scope -Kind $Kind -PhysicalBytes $PhysicalBytes -CommitBytes $CommitBytes -Owner $Owner
            }
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
            . $private:jobAssert -jobCheckToken
            & $Body
            . $private:jobAssert -jobCheckToken
        } catch { . $private:jobRecordError -jobCapturedRecord $_ -jobCapturedFrontier 'SetupBody' }
        finally {
            if ($null-ne$private:jobStore['Lease']) {
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
    if ($RequireNewLease) {
        $lease=Enter-IW7ResourceLease -Scope $Scope -Kind $Kind -PhysicalBytes $PhysicalBytes -CommitBytes $CommitBytes -Owner $Owner -RequireNewLease
    } else {
        $lease=Enter-IW7ResourceLease -Scope $Scope -Kind $Kind -PhysicalBytes $PhysicalBytes -CommitBytes $CommitBytes -Owner $Owner
    }
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
