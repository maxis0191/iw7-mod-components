# Pure gate; no process, listener, reservation or capture on import.
function Assert-IW7CapacityPageAdmission($Plan,$Identity,$Lease,$Process) {
    if ($Plan.Schema -cne 'iw7.agent-lab/1' -or !$Plan.Debugger -or $Plan.PhysicalBytes -lt 14GB -or $Plan.CommitBytes -lt 15GB -or
        $Plan.ServerPort -lt 27100 -or $Plan.ServerPort -gt 27999 -or $Plan.MainDeployed -or
        $Identity.Image -ine $Plan.ServerImage -or ($Plan.BaseClientImage -and $Identity.Image -ieq $Plan.BaseClientImage) -or $Identity.SHA256 -cne $Plan.NativeSHA256 -or
        $Lease.Kind -cne 'Runtime' -or $Lease.Scope -ine (Get-IW7CanonicalScope $Plan.CandidateRoot) -or
        $Lease.PhysicalBytes -lt $Plan.PhysicalBytes -or $Lease.CommitBytes -lt $Plan.CommitBytes) { throw 'Exact debugger-enabled 14/15 owned test-dedicated reservation required.' }
    $entries=@($Lease.Processes | Where-Object PID -EQ $Identity.PID)
    if ($entries.Count -ne 1 -or $entries[0].Image -ine $Identity.Image -or
        [math]::Abs((([datetimeoffset]$entries[0].CreatedUtc)-([datetimeoffset]$Identity.CreatedUtc)).TotalMilliseconds) -gt 1 -or
        !$Process -or $Process.ProcessId -ne $Identity.PID -or $Process.ExecutablePath -ine $Identity.Image) { throw 'Registered dedicated identity mismatch.' }
    foreach ($flag in @('-dedicated','-paris-isolated-lab','-paris-server-test','-paris-debugger')) {
        if ($Process.CommandLine -notmatch ('(?:^|\s)'+[regex]::Escape($flag)+'(?:\s|$)')) { throw 'Dedicated diagnostic launch flags absent.' }
    }
}

function Save-IW7CapacityNativeText($Reader,[string]$Output,$Identity,$ParentProof) {
    if(Test-Path -LiteralPath $Output){throw 'Fresh executable-text output required.'}
    $cursor=Split-Path $Output -Parent
    while($cursor){
        if((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Redirected text output refused.'}
        $cursor=Split-Path $cursor -Parent
    }
    $null=[IO.Directory]::CreateDirectory($Output)
    $record=[ordered]@{schema='iw7.capacity-native-text/1';identity=$Identity;parent_proof=$ParentProof;
        complete=$false;all_pages_stable=$true;sections=@();target_written=$false;target_suspended=$false;global_snapshot_coherent=$false;
        data_sections_captured=$false;pristine=$false;read_calls_before=$Reader.ReadCalls;read_bytes_before=$Reader.ReadBytes}
    try{
        foreach($index in @(0,1)){
            $Reader.AssertAlive()
            $first=$Reader.ReadTextSection($index);$second=$Reader.ReadTextSection($index)
            $changed=@([IW7CapacityPages]::ChangedTextPages($index,$first,$second))
            if($changed.Count -gt 128){throw 'More than 128 changed executable pages; refuse unbounded second-page retention.'}
            if($changed.Count){$record.all_pages_stable=$false}
            $name='native-text-'+$index+'.bin'
            $stream=[IO.File]::Open((Join-Path $Output $name),'CreateNew','Write','None')
            try{$stream.Write($first,0,$first.Length)}finally{$stream.Dispose()}
            $changedRows=@(foreach($offset in $changed){
                $secondName='native-text-'+$index+'-changed-'+$offset.ToString('X')+'.bin'
                $size=[math]::Min(4096,$second.Length-$offset)
                $stream=[IO.File]::Open((Join-Path $Output $secondName),'CreateNew','Write','None')
                try{$stream.Write($second,$offset,$size)}finally{$stream.Dispose()}
                [ordered]@{offset=$offset;bytes=$size;second_path=$secondName;address=('0x'+([IW7CapacityPages]::TextSectionAddress($index)+$offset).ToString('X'))}
            })
            $record.sections+=@([ordered]@{index=$index;address=('0x'+[IW7CapacityPages]::TextSectionAddress($index).ToString('X'));
                bytes=$first.Length;path=$name;stable_double_read=($changed.Count -eq 0);changed_pages=$changedRows;
                second_sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([byte[]]$second));
                sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([byte[]]$first))})
        }
        $Reader.AssertAlive();$record.complete=$true
    }catch{$record.failure=$_.Exception.Message;throw}
    finally{
        $record.read_calls=$Reader.ReadCalls-$record.read_calls_before;$record.read_bytes=$Reader.ReadBytes-$record.read_bytes_before
        $stream=[IO.File]::Open((Join-Path $Output 'manifest.local.json'),'CreateNew','Write','None')
        try{$bytes=[Text.Encoding]::UTF8.GetBytes(($record|ConvertTo-Json -Depth 9));$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}
    }
}

function Save-IW7CapacityCodePages($Reader,[string]$Output,$Identity,
    [ValidateSet("reset-callers","reset-entry-targets","writer-sites-20261019","writer-path-20261019","binding-continuation-20261019")][string]$PagePlan="reset-callers",$ParentProof=$null) {
    if (Test-Path -LiteralPath $Output) { throw 'Fresh page output required.' }
    $cursor=Split-Path $Output -Parent
    while ($cursor) {
        if ((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Redirected page output refused.' }
        $cursor=Split-Path $cursor -Parent
    }
    $null=[IO.Directory]::CreateDirectory($Output)
    $record=[ordered]@{schema='iw7.capacity-code-pages/1';identity=$Identity;started_utc=[datetime]::UtcNow.ToString('o');
        page_plan=$PagePlan;parent_proof=$ParentProof;pages=@();complete=$false;target_suspended=$false;target_written=$false;child_processes=0;
        pristine=$false;patch_ready=$false;global_snapshot_coherent=$false;read_calls=0;read_bytes=0}
    try {
        $index=0
        foreach ($address in [IW7CapacityPages]::GetPlanPages($PagePlan)) {
            $Reader.AssertAlive()
            $region=$Reader.QueryPage($address)
            $first=$Reader.ReadPage($address);$second=$Reader.ReadPage($address)
            $record.read_calls=$Reader.ReadCalls;$record.read_bytes=$Reader.ReadBytes
            if ($first.Length -ne 4096 -or $second.Length -ne 4096) { throw 'Partial page read.' }
            $owner=if ($PagePlan -eq 'writer-sites-20261019') { 'observed-writer-site' }
                elseif ($PagePlan -eq 'writer-path-20261019') { 'selected-writer-path' }
                elseif ($PagePlan -eq 'binding-continuation-20261019') { 'selected-binding-continuation' }
                elseif (($PagePlan -eq 'reset-callers' -and $index -lt 4) -or ($PagePlan -eq 'reset-entry-targets' -and $index -eq 0)) { '140488520' } else { '140B20760' }
            $name=$owner+'-'+$address.ToString('X16')+'.bin'
            $stream=[IO.File]::Open((Join-Path $Output $name),'CreateNew','Write','None')
            try { $stream.Write($first,0,4096) } finally { $stream.Dispose() }
            $stable=[IW7CapacityPages]::SamePage($first,$second)
            $record.pages+=@([ordered]@{owner=$owner;address=('0x'+$address.ToString('X'));bytes=4096;path=$name;
                sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([byte[]]$first));
                region=$region;stable_double_read=$stable;code_origin='unclassified; mapping/permissions do not prove retail/Arxan'})
            $after=$Reader.QueryPage($address)
            if (!$stable -or ($region | ConvertTo-Json -Compress) -cne ($after | ConvertTo-Json -Compress)) { throw 'Page content/protection changed; partial capture retained.' }
            $index++
        }
        $Reader.AssertAlive()
        $record.completed_utc=[datetime]::UtcNow.ToString('o');$record.complete=$true
    } catch {
        $record.failure=$_.Exception.Message
        throw
    } finally {
        $stream=[IO.File]::Open((Join-Path $Output 'manifest.local.json'),'CreateNew','Write','None')
        try { $bytes=[Text.Encoding]::UTF8.GetBytes(($record | ConvertTo-Json -Depth 9));$stream.Write($bytes,0,$bytes.Length) } finally {$stream.Dispose()}
    }
}
