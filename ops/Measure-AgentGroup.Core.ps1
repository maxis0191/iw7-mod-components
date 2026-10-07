function Assert-IW7GroupIdentities {
    param([Parameter(Mandatory)][object[]]$Identities,[Parameter(Mandatory)][int[]]$LeasePid)
    if(!$Identities.Count -or $Identities.Count -gt 16 -or !$LeasePid.Count -or $LeasePid.Count -gt 16){throw 'Bounded exact lease identities required.'}
    $seen=@{}
    foreach($id in $Identities){
        if([int]$id.PID -le 0 -or $seen.ContainsKey([int]$id.PID) -or !$id.Image -or ![IO.Path]::IsPathFullyQualified($id.Image) -or $id.SHA256 -notmatch '^[a-fA-F0-9]{64}$' -or !$id.CreatedUtc){throw 'Incomplete/duplicate process identity.'}
        $null=[datetimeoffset]::Parse($id.CreatedUtc);$seen[[int]$id.PID]=$true
    }
    if(@($LeasePid|Select-Object -Unique).Count -ne $LeasePid.Count -or $LeasePid.Count -ne $seen.Count){throw 'Lease process list must match identities exactly.'}
    foreach($processId in $LeasePid){if(!$seen.ContainsKey($processId)){throw 'Lease process identity missing.'}}
}
function New-IW7GroupSample {
    param([Parameter(Mandatory)][object[]]$Rows,[Parameter(Mandatory)][int[]]$LeasePid,[long]$Tick,[string]$Utc)
    $seen=@{};$complete=$true;$rss=0L;$commit=0L
    foreach($row in $Rows){
        if($seen.ContainsKey([int]$row.PID) -or $row.PID -notin $LeasePid){throw 'Duplicate/foreign sample member.'};$seen[[int]$row.PID]=$true
        if(!$row.Valid){$complete=$false;continue}
        foreach($value in @($row.WorkingSetBytes,$row.PrivateBytes)){
            if($null -eq $value -or $value.GetType() -notin @([byte],[uint16],[uint32],[uint64],[sbyte],[int16],[int32],[int64]) -or [decimal]$value -lt 0 -or [decimal]$value -gt [long]::MaxValue){throw 'Valid memory measurement must contain nonnegative bounded integer bytes.'}
        }
        if([decimal]$rss+[decimal]$row.WorkingSetBytes -gt [long]::MaxValue -or [decimal]$commit+[decimal]$row.PrivateBytes -gt [long]::MaxValue){throw 'Group memory sum exceeds bounded integer bytes.'}
        $rss+=[long]$row.WorkingSetBytes;$commit+=[long]$row.PrivateBytes
    }
    if($seen.Count -ne $LeasePid.Count){$complete=$false}
    [pscustomobject]@{Type='sample';Utc=$Utc;TickMs=$Tick;Complete=$complete;WorkingSetBytes=$(if($complete){$rss}else{$null});PrivateBytes=$(if($complete){$commit}else{$null});Processes=@($Rows)}
}
function Get-IW7GroupSummary {
    param([Parameter(Mandatory)][object[]]$Samples,[bool]$PartialStartup)
    $valid=@($Samples|Where-Object Complete);$rss=$null;$commit=$null
    foreach($sample in $valid){if($null -eq $rss -or $sample.WorkingSetBytes -gt $rss){$rss=$sample.WorkingSetBytes};if($null -eq $commit -or $sample.PrivateBytes -gt $commit){$commit=$sample.PrivateBytes}}
    [pscustomobject]@{Type='summary';Schema='iw7.agent-group-memory/1';PartialStartup=$PartialStartup;SampleCount=$Samples.Count;CompleteSamples=$valid.Count;GapSamples=$Samples.Count-$valid.Count;SampledPeakGroupWorkingSetBytes=$rss;SampledPeakGroupPrivateBytes=$commit;Meaning='Same-sample process group sums, not individual lifetime peak sums. Shared resident pages may be counted twice. Private bytes exclude other machine/GPU allocations. One-second samples can miss shorter peaks.'}
}

function Read-IW7GroupProcessMemory {
    param([int]$ProcessId,[Parameter(Mandatory)][scriptblock]$HasExited,[Parameter(Mandatory)][scriptblock]$ReadCounters)
    $row=@{PID=$ProcessId;Valid=$false;WorkingSetBytes=$null;PrivateBytes=$null;ReadTickMs=[Environment]::TickCount64;Gap=$null}
    try{
        if(& $HasExited){throw 'Owned process exited before memory read.'}
        $memory=& $ReadCounters
        # The retained handle may become signaled while its last counters are
        # queried successfully. Never count that concurrent exit as a live member.
        if(& $HasExited){throw 'Owned process exited during memory read.'}
        $row.WorkingSetBytes=$memory.WorkingSetBytes;$row.PrivateBytes=$memory.PrivateBytes
        $row.Valid=$true
    }catch{$row.Valid=$false;$row.WorkingSetBytes=$null;$row.PrivateBytes=$null;$row.Gap=$_.Exception.Message}
    [pscustomobject]$row
}