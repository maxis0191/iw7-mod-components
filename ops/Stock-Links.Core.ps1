# Functions only: no native provider, stock read, lease or filesystem mutation on import.
. "$PSScriptRoot/Lab-Paths.ps1"
function Initialize-IW7StockLinkNtfs {
    if(!('IW7StockLinksV1.Ntfs' -as [type])){Add-Type -Path "$PSScriptRoot/native/StockLinks.cs" -ErrorAction Stop}
}
function Assert-IW7StockAbsolutePath([string]$Path) {
    if(!$Path -or $Path -cnotmatch '^[A-Za-z]:\\' -or ![IO.Path]::IsPathFullyQualified($Path) -or [IO.Path]::GetFullPath($Path) -cne $Path -or $Path -match '[\x00-\x1f]'){
        throw 'Canonical absolute stock path required.'
    }
    $null=Assert-IW7LabPath $Path ([IO.Path]::GetPathRoot($Path))
}
function ConvertTo-IW7StockRelative([string]$Relative) {
    if(!$Relative -or [IO.Path]::IsPathRooted($Relative) -or $Relative -match '[<>:"|?*\x00-\x1f]'){throw 'Plain relative stock path required.'}
    $parts=@($Relative -split '[\\/]')
    foreach($part in $parts){
        if(!$part -or $part -in @('.','..') -or $part.TrimEnd(' ','.') -cne $part -or
           $part -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)'){throw 'Traversal/device/ambiguous stock path refused.'}
    }
    $parts -join [IO.Path]::DirectorySeparatorChar
}
function Read-IW7StockLinkPlan {
    param([Parameter(Mandatory)][string]$ManifestPath,[Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedManifestSHA256,
        [Parameter(Mandatory)][string]$SourceRoot,[Parameter(Mandatory)][string]$TargetRoot)
    foreach($path in @($ManifestPath,$SourceRoot,$TargetRoot)){Assert-IW7StockAbsolutePath $path}
    if($TargetRoot.StartsWith($SourceRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or
       $SourceRoot.StartsWith($TargetRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or $SourceRoot -ieq $TargetRoot){throw 'Separate source/target stock roots required.'}
    $guard=[IO.FileStream]::new($ManifestPath,'Open','Read','Read')
    try {
        if($guard.Length -le 0 -or $guard.Length -gt 4MB){throw 'Bounded metadata-only stock manifest required.'}
        $hash=[Security.Cryptography.SHA256]::Create()
        try{$actual=[Convert]::ToHexString($hash.ComputeHash($guard)).ToLowerInvariant()}finally{$hash.Dispose()}
        if($actual -ine $ExpectedManifestSHA256){throw 'Reviewed stock manifest hash differs.'}
        $guard.Position=0;$reader=[IO.StreamReader]::new($guard,[Text.Encoding]::UTF8,$true,4096,$true)
        try{$manifest=$reader.ReadToEnd()|ConvertFrom-Json -Depth 20}finally{$reader.Dispose()}
    }finally{$guard.Dispose()}
    if($manifest.schema -cne 'iw7.server-only-link-plan/1' -or $manifest.source -cne $SourceRoot -or $manifest.target -cne $TargetRoot -or
       $manifest.stock_content_read -ne $false -or $manifest.hashes_computed -ne $false -or $manifest.links_created -ne $false -or
       $manifest.stock_bytes_copied -ne 0 -or $manifest.client_clone_created -ne $false){throw 'Server-only immutable stock manifest contract differs.'}
    foreach($flag in @('stock_content_read','hashes_computed','links_created','client_clone_created')){
        if($manifest.$flag -isnot [bool]){throw 'Literal manifest boolean required.'}
    }
    $rows=@($manifest.files);$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);$total=0L
    if(!$rows.Count -or $rows.Count -ne $manifest.planned_files -or $rows.Count -gt 16384){throw 'Complete explicit bounded stock pathset required.'}
    foreach($row in $rows){
        $relative=ConvertTo-IW7StockRelative $row.relative
        if(!$seen.Add($relative) -or $row.bytes -lt 0 -or $row.links -lt 1 -or $row.links -ge 1023 -or
           ([long]$row.attributes -band 32) -eq 0 -or ([long]$row.attributes -band (16+1024)) -ne 0){throw 'Duplicate/non-file/reparse/Archive-missing stock row refused before linking.'}
        foreach($key in @('bytes','links','attributes','volume','file_id','created_ns','modified_ns')){
            if($row.$key.ToString() -cnotmatch '^[0-9]+$'){throw 'Exact integer stock metadata required.'}
        }
        if([Numerics.BigInteger]$total+[Numerics.BigInteger]$row.bytes -gt [long]::MaxValue){throw 'Stock byte total overflow.'}
        $total+=[long]$row.bytes
    }
    if($total -ne $manifest.logical_bytes){throw 'Stock logical-byte total differs.'}
    [pscustomobject]@{Schema='iw7.stock-link-plan/1';ManifestPath=$ManifestPath;ManifestSHA256=$actual;
        SourceRoot=$SourceRoot;TargetRoot=$TargetRoot;Rows=$rows;LogicalBytes=$total;RetailDataBytesCopied=0}
}
function Assert-IW7StockLinkContext($Context) {
    if($Context -isnot [Collections.IDictionary] -or $Context.Schema -cne 'iw7.stock-link-transaction/1' -or
       $Context.HostPID -ne $PID -or ![object]::ReferenceEquals([AppDomain]::CurrentDomain.GetData($Context.RetentionKey),$Context.OwnerRoot) -or
       ![object]::ReferenceEquals($Context.OwnerRoot[$Context.TransactionSlot],$Context)){throw 'Same original retained stock-link context required; no JSON reconstruction.'}
    $null=& $Context.ValidateCaller $Context.LeaseToken $Context.Plan.TargetRoot
}
function Write-IW7StockLinkJournal($Context,$Record) {
    if(!$Context.JournalStream -or $Context.JournalStream.SafeFileHandle.IsClosed){throw 'Original create-only stock journal unavailable.'}
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($Record|ConvertTo-Json -Depth 8 -Compress)+"`n")
    $Context.JournalStream.Write($bytes,0,$bytes.Length);$Context.JournalStream.Flush($true)
}
function Register-IW7StockLastAccessObservation($Context,$Actual,$Expected) {
    if($Actual.LastAccessFileTime -eq $Expected.LastAccessFileTime){return}
    Assert-IW7StockLinkContext $Context
    if(!$Context.Contains('LastAccessObservations')){$Context.LastAccessObservations=[Collections.Generic.List[object]]::new()}
    $seen=@($Context.LastAccessObservations|Where-Object {$_.Identity -ceq $Actual.Identity -and $_.BeforeFileTime -eq $Expected.LastAccessFileTime -and $_.AfterFileTime -eq $Actual.LastAccessFileTime})
    if($seen.Count){return}
    $record=@{Event='SourceLastAccessObserved';Policy='ObservedVolatileNTFS';Identity=$Actual.Identity;
        BeforeFileTime=$Expected.LastAccessFileTime;AfterFileTime=$Actual.LastAccessFileTime;
        DeltaTicks=([long]$Actual.LastAccessFileTime-[long]$Expected.LastAccessFileTime)}
    $Context.LastAccessObservations.Add($record)
    if($Context.JournalStream){Write-IW7StockLinkJournal $Context $record}
}
function Assert-IW7StockStableMetadata($Actual,$Expected,[long]$Links) {
    foreach($key in @('Identity','Volume','FileId128','Bytes','AllocatedBytes','Attributes','CreationFileTime','LastWriteFileTime')){
        if($Actual.$key -cne $Expected.$key){throw "Shared stock invariant differs: $key"}
    }
    if($Actual.Directory -or $Actual.DeletePending -or $Actual.Links -ne $Links){throw 'Shared stock type/link-count differs.'}
    # Existing callers (including a retained older Undo) expose their original
    # Context parameter in the caller scope. Never reconstruct it from JSON.
    $callerContext=Get-Variable -Name Context -Scope 1 -ValueOnly -ErrorAction SilentlyContinue
    if($callerContext -is [Collections.IDictionary] -and $callerContext.Schema -ceq 'iw7.stock-link-transaction/1'){
        Register-IW7StockLastAccessObservation $callerContext $Actual $Expected
    }
}
function Assert-IW7StockManifestRow($Actual,$Row) {
    if($Actual.Directory -or $Actual.Volume -cne $Row.volume.ToString() -or $Actual.FileIdLow -cne $Row.file_id.ToString() -or
       $Actual.Bytes -ne $Row.bytes -or $Actual.Links -ne $Row.links -or $Actual.Attributes -ne $Row.attributes -or
       $Actual.CreatedNs -cne $Row.created_ns.ToString() -or $Actual.ModifiedNs -cne $Row.modified_ns.ToString()){
        throw 'Live NTFS stock metadata differs from reviewed manifest.'
    }
}
function New-IW7StockLinkTransaction {
    param([Parameter(Mandatory)]$Plan,[Parameter(Mandatory)][Collections.IDictionary]$OwnerRoot,
        [Parameter(Mandatory)][string]$RetentionKey,[string]$TransactionSlot='StockLinkTransaction',
        [Parameter(Mandatory)][string]$LeaseToken,[Parameter(Mandatory)][scriptblock]$ValidateCaller,
        [Parameter(Mandatory)][string]$JournalPath)
    if($Plan.Schema -cne 'iw7.stock-link-plan/1' -or ![object]::ReferenceEquals([AppDomain]::CurrentDomain.GetData($RetentionKey),$OwnerRoot) -or
       $OwnerRoot.Contains($TransactionSlot)){throw 'Original caller root and unused transaction slot required before preparation.'}
    Assert-IW7StockAbsolutePath $JournalPath
    foreach($stockRoot in @($Plan.SourceRoot,$Plan.TargetRoot)){
        if($JournalPath -ieq $stockRoot -or $JournalPath.StartsWith($stockRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){
            throw 'Independent stock journal outside source/target roots required.'
        }
    }
    $context=@{Schema='iw7.stock-link-transaction/1';HostPID=$PID;OwnerRoot=$OwnerRoot;RetentionKey=$RetentionKey;TransactionSlot=$TransactionSlot;
        LeaseToken=$LeaseToken;ValidateCaller=$ValidateCaller;Plan=$Plan;Phase='PublishedBeforePreflight';Failure=$null;Closed=$false;
        JournalPath=$JournalPath;JournalStream=$null;JournalMetadata=$null;Sources=[Collections.Generic.List[object]]::new();
        Groups=@{};SourceDirectories=@{};CreatedLinks=[Collections.Generic.List[object]]::new();CreatedDirectories=[Collections.Generic.List[object]]::new();
        Guards=[Collections.Generic.List[object]]::new();LastAccessObservations=[Collections.Generic.List[object]]::new();UnknownCreation=$false;SourcePreserved=$false;Prepared=$false;RollbackClosed=$false;RetailDataBytesCopied=0}
    $OwnerRoot[$TransactionSlot]=$context # Actual objects published before any alias/factory side effect.
    Assert-IW7StockLinkContext $context
    $context
}
function Get-IW7StockLinkMetadata([string]$Path) {
    Assert-IW7StockAbsolutePath $Path;Initialize-IW7StockLinkNtfs
    $handle=[IW7StockLinksV1.Ntfs]::OpenStock($Path)
    try{[IW7StockLinksV1.Ntfs]::Inspect($handle)}finally{$handle.Dispose()}
}
function Invoke-IW7StockLinkPreflight($Context) {
    Assert-IW7StockLinkContext $Context
    if($Context.Phase -cne 'PublishedBeforePreflight'){throw 'Stock transaction preflight may run only once.'}
    Initialize-IW7StockLinkNtfs
    try{
        $plan=$Context.Plan
        # Rebind the immutable small manifest before any stock/path mutation.
        $Context.Plan=Read-IW7StockLinkPlan -ManifestPath $plan.ManifestPath -ExpectedManifestSHA256 $plan.ManifestSHA256 -SourceRoot $plan.SourceRoot -TargetRoot $plan.TargetRoot
        $plan=$Context.Plan
        if(Test-Path -LiteralPath $plan.TargetRoot){throw 'New stock target must be absent; never adopt an existing directory.'}
        if(Test-Path -LiteralPath $Context.JournalPath){throw 'Create-only stock journal path already exists.'}
        $sourceDirectory=[IW7StockLinksV1.Ntfs]::OpenDirectory($plan.SourceRoot);$Context.Guards.Add($sourceDirectory)
        $Context.SourceDirectories[$plan.SourceRoot]=$sourceDirectory
        $parent=[IO.Path]::GetDirectoryName($plan.TargetRoot)
        Assert-IW7StockAbsolutePath $parent
        $targetParent=[IW7StockLinksV1.Ntfs]::OpenDirectory($parent);$Context.Guards.Add($targetParent)
        if([IW7StockLinksV1.Ntfs]::Inspect($sourceDirectory).Volume -cne [IW7StockLinksV1.Ntfs]::Inspect($targetParent).Volume){throw 'Same NTFS volume required; no copy fallback.'}
        foreach($row in $plan.Rows){
            $relative=ConvertTo-IW7StockRelative $row.relative
            $source=Join-Path $plan.SourceRoot $relative;$target=Join-Path $plan.TargetRoot $relative
            $null=Assert-IW7LabPath $source $plan.SourceRoot;$null=Assert-IW7LabPath $target $plan.TargetRoot
            $directory=[IO.Path]::GetDirectoryName($source)
            while(!$Context.SourceDirectories.ContainsKey($directory)){
                $null=Assert-IW7LabPath $directory $plan.SourceRoot
                $directoryGuard=[IW7StockLinksV1.Ntfs]::OpenDirectory($directory);$Context.Guards.Add($directoryGuard)
                $Context.SourceDirectories[$directory]=$directoryGuard;$directory=[IO.Path]::GetDirectoryName($directory)
            }
            $guard=[IW7StockLinksV1.Ntfs]::OpenStock($source);$Context.Guards.Add($guard)
            $metadata=[IW7StockLinksV1.Ntfs]::Inspect($guard);Assert-IW7StockManifestRow $metadata $row
            if(!$Context.Groups.ContainsKey($metadata.Identity)){$Context.Groups[$metadata.Identity]=@{Before=$metadata;Created=0L;Planned=0L}}
            $group=$Context.Groups[$metadata.Identity];Assert-IW7StockStableMetadata $metadata $group.Before $group.Before.Links;$group.Planned++
            if($group.Before.Links+$group.Planned -gt 1023){throw 'NTFS maximum hardlink count would be exceeded.'}
            $Context.Sources.Add(@{Relative=$relative;Path=$source;Target=$target;Guard=$guard;Before=$metadata})
        }
        $Context.Phase='Preflighted'
    }catch{$Context.Phase='Unknown';$Context.Failure=$_.Exception.Message;throw}
}
function New-IW7StockOwnedDirectory($Context,[string]$Path) {
    Assert-IW7StockLinkContext $Context;$null=Assert-IW7LabPath $Path $Context.Plan.TargetRoot
    $known=@($Context.CreatedDirectories|Where-Object Path -CEQ $Path)
    if($known.Count){return}
    if(Test-Path -LiteralPath $Path){throw 'Unowned target directory appeared; preserve it.'}
    Write-IW7StockLinkJournal $Context @{Event='DirectoryIntent';Path=$Path}
    $Context.UnknownCreation=$true
    try{$guard=[IW7StockLinksV1.Ntfs]::CreateDirectoryOwned($Path)}catch{if($_.Exception.InnerException -is [IW7StockLinksV1.CreationRefusedException]){$Context.UnknownCreation=$false};throw}
    $Context.Guards.Add($guard)
    $record=@{Path=$Path;Identity=[IW7StockLinksV1.Ntfs]::Inspect($guard).Identity;Guard=$guard;Removed=$false}
    $Context.CreatedDirectories.Add($record);$Context.UnknownCreation=$false
    Write-IW7StockLinkJournal $Context @{Event='DirectoryCreated';Path=$Path;Identity=$record.Identity}
}
function Close-IW7StockLinkGuards($Context) {
    # Any fallible journal query must complete while all original stock guards
    # are still live. Unknown journal state must not silently close those guards.
    if($Context.JournalStream){$Context.JournalMetadata=[IW7StockLinksV1.Ntfs]::Inspect($Context.JournalStream.SafeFileHandle)}
    foreach($guard in $Context.Guards){if($guard -and !$guard.IsClosed){$guard.Dispose()}}
    $Context.Guards.Clear()
    if($Context.JournalStream){$Context.JournalStream.Dispose();$Context.JournalStream=$null}
}
function Invoke-IW7StockLinkApply($Context) {
    Assert-IW7StockLinkContext $Context
    if($Context.Phase -ceq 'PublishedBeforePreflight'){Invoke-IW7StockLinkPreflight $Context}
    if($Context.Phase -cne 'Preflighted'){throw 'Exact preflighted stock context required for apply.'}
    try{
        Assert-IW7StockAbsolutePath $Context.JournalPath
        $Context.JournalStream=[IO.FileStream]::new($Context.JournalPath,'CreateNew','Write','Read')
        $Context.JournalMetadata=[IW7StockLinksV1.Ntfs]::Inspect($Context.JournalStream.SafeFileHandle)
        Write-IW7StockLinkJournal $Context @{Event='Begin';ManifestSHA256=$Context.Plan.ManifestSHA256;TargetRoot=$Context.Plan.TargetRoot;RetailDataBytesCopied=0}
        New-IW7StockOwnedDirectory $Context $Context.Plan.TargetRoot
        foreach($source in $Context.Sources){
            Assert-IW7StockLinkContext $Context
            $group=$Context.Groups[$source.Before.Identity]
            Assert-IW7StockStableMetadata ([IW7StockLinksV1.Ntfs]::Inspect($source.Guard)) $source.Before ($group.Before.Links+$group.Created)
            $pathMetadata=Get-IW7StockLinkMetadata $source.Path
            Assert-IW7StockStableMetadata $pathMetadata $source.Before ($group.Before.Links+$group.Created)
            $parts=@($source.Relative -split '[\\/]');$directory=$Context.Plan.TargetRoot
            for($i=0;$i -lt $parts.Count-1;$i++){$directory=Join-Path $directory $parts[$i];New-IW7StockOwnedDirectory $Context $directory}
            if(Test-Path -LiteralPath $source.Target){throw 'Unowned target entry appeared; no overwrite.'}
            Write-IW7StockLinkJournal $Context @{Event='LinkIntent';Source=$source.Path;Target=$source.Target;Identity=$source.Before.Identity}
            $Context.UnknownCreation=$true
            try{[IW7StockLinksV1.Ntfs]::CreateLinkNew($source.Target,$source.Path)}catch{if($_.Exception.InnerException -is [IW7StockLinksV1.CreationRefusedException]){$Context.UnknownCreation=$false};throw}
            $targetMetadata=Get-IW7StockLinkMetadata $source.Target
            $record=@{Path=$source.Target;Source=$source.Path;Identity=$targetMetadata.Identity;Before=$source.Before;Removed=$false}
            $Context.CreatedLinks.Add($record);$Context.UnknownCreation=$false;$group.Created++
            Assert-IW7StockStableMetadata $targetMetadata $source.Before ($group.Before.Links+$group.Created)
            Write-IW7StockLinkJournal $Context @{Event='LinkCreated';Path=$record.Path;Identity=$record.Identity;Links=$targetMetadata.Links;ChangeFileTime=$targetMetadata.ChangeFileTime}
        }
        foreach($source in $Context.Sources){$group=$Context.Groups[$source.Before.Identity];Assert-IW7StockStableMetadata (Get-IW7StockLinkMetadata $source.Path) $source.Before ($group.Before.Links+$group.Created)}
        $Context.SourcePreserved=$true;$Context.Prepared=$true;$Context.Phase='Prepared'
        Write-IW7StockLinkJournal $Context @{Event='Prepared';SourcePreserved=$true;CreatedLinks=$Context.CreatedLinks.Count;RetailDataBytesCopied=0;LastAccessPolicy='ObservedVolatileNTFS';LastAccessChanges=$Context.LastAccessObservations.Count}
        Close-IW7StockLinkGuards $Context;$Context.Closed=$true
        [pscustomobject]@{Schema='iw7.stock-links-prepared/1';Prepared=$true;SourcePreserved=$true;TargetRoot=$Context.Plan.TargetRoot;
            CreatedLinks=$Context.CreatedLinks.Count;LogicalBytes=$Context.Plan.LogicalBytes;RetailDataBytesCopied=0;RuntimeValidated=$false;JournalPath=$Context.JournalPath;
            LastAccessPolicy='ObservedVolatileNTFS';LastAccessObservations=@($Context.LastAccessObservations.ToArray())}
    }catch{$Context.Phase='Unknown';$Context.Failure=$_.Exception.Message;$Context.Closed=$false;throw}
}
function Undo-IW7StockLinkTransaction($Context) {
    Assert-IW7StockLinkContext $Context
    if($Context.UnknownCreation){throw 'Creation identity unknown; retain the same context/guards/journal.'}
    try{
        foreach($source in $Context.Sources){
            $group=$Context.Groups[$source.Before.Identity]
            $remaining=@($Context.CreatedLinks|Where-Object { !$_.Removed -and $_.Before.Identity -ceq $source.Before.Identity }).Count
            # Preserve the original source name too, including recovery after a
            # closed successful apply. A missing source cannot become last-link deletion.
            $guard=[IW7StockLinksV1.Ntfs]::OpenStock($source.Path);$Context.Guards.Add($guard)
            Assert-IW7StockStableMetadata ([IW7StockLinksV1.Ntfs]::Inspect($guard)) $source.Before ($group.Before.Links+$remaining)
        }
        if(!$Context.JournalStream -and $Context.JournalMetadata){
            $Context.JournalStream=[IO.FileStream]::new($Context.JournalPath,'Open','ReadWrite','Read')
            $metadata=[IW7StockLinksV1.Ntfs]::Inspect($Context.JournalStream.SafeFileHandle)
            foreach($key in @('Identity','Bytes','CreationFileTime','LastWriteFileTime')){
                if($metadata.$key -cne $Context.JournalMetadata.$key){throw 'Original stock journal identity/metadata changed; no deletion.'}
            }
            $Context.JournalStream.Position=$Context.JournalStream.Length
        }
        foreach($record in $Context.CreatedDirectories){
            if($record.Removed){continue}
            $metadata=Get-IW7StockLinkMetadata $record.Path
            if(!$metadata.Directory -or $metadata.Identity -cne $record.Identity){throw 'Owned stock directory identity changed; no deletion.'}
        }
        foreach($record in $Context.CreatedLinks){
            if($record.Removed){continue}
            $metadata=Get-IW7StockLinkMetadata $record.Path
            if($metadata.Identity -cne $record.Identity -or $record.Identity -cne $record.Before.Identity){throw 'Owned stock alias identity changed; no deletion.'}
        }
        if($Context.JournalStream){Write-IW7StockLinkJournal $Context @{Event='RollbackBegin';CreatedLinks=$Context.CreatedLinks.Count}}
        # Directory guards prevent rename while apply is pending. Close them
        # only after identity preflight; delete handles bind each name and deny
        # concurrent delete/write sharing while allowing held source read guards.
        foreach($directory in $Context.CreatedDirectories){if($directory.Guard -and !$directory.Guard.IsClosed){$directory.Guard.Dispose()}}
        foreach($record in $Context.CreatedLinks){
            if($record.Removed){continue}
            Assert-IW7StockLinkContext $Context
            $handle=[IW7StockLinksV1.Ntfs]::OpenOwnedDelete($record.Path)
            try{
                if([IW7StockLinksV1.Ntfs]::Inspect($handle).Identity -cne $record.Identity){throw 'Owned alias changed before handle-bound unlink.'}
                [IW7StockLinksV1.Ntfs]::UnlinkByHandle($handle);$record.Removed=$true
            }finally{$handle.Dispose()}
            if($Context.JournalStream){Write-IW7StockLinkJournal $Context @{Event='LinkRemoved';Path=$record.Path;Identity=$record.Identity}}
        }
        foreach($source in $Context.Sources){Assert-IW7StockStableMetadata (Get-IW7StockLinkMetadata $source.Path) $source.Before $source.Before.Links}
        $directories=@($Context.CreatedDirectories | Sort-Object @{Expression={$_.Path.Length};Descending=$true})
        foreach($directory in $directories){
            if($directory.Removed){continue}
            Assert-IW7StockLinkContext $Context
            if(@([IO.Directory]::EnumerateFileSystemEntries($directory.Path)).Count){throw 'Unowned/mutable target entries remain; never recursively remove them.'}
            $handle=[IW7StockLinksV1.Ntfs]::OpenOwnedDelete($directory.Path)
            try{
                if([IW7StockLinksV1.Ntfs]::Inspect($handle).Identity -cne $directory.Identity){throw 'Owned directory changed before unlink.'}
                [IW7StockLinksV1.Ntfs]::UnlinkByHandle($handle);$directory.Removed=$true
            }finally{$handle.Dispose()}
        }
        $Context.SourcePreserved=$true;$Context.RollbackClosed=$true;$Context.Phase='RolledBack';$Context.Prepared=$false
        if($Context.JournalStream){Write-IW7StockLinkJournal $Context @{Event='RolledBack';SourcePreserved=$true}}
        Close-IW7StockLinkGuards $Context;$Context.Closed=$true
        [pscustomobject]@{RollbackClosed=$true;SourcePreserved=$true;RetailDataBytesCopied=0;TargetAbsent=!(Test-Path -LiteralPath $Context.Plan.TargetRoot)}
    }catch{$Context.Phase='Unknown';$Context.Failure=$_.Exception.Message;$Context.Closed=$false;throw}
}
