$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
. "$PSScriptRoot/../../ops/Stock-Links.Core.ps1"
$script:checks=0
function Check($Value,$Message){if(!$Value){throw $Message};$script:checks++}
function Refuse([scriptblock]$Body,[string]$Match){$caught=$null;try{& $Body|Out-Null}catch{$caught=$_};Check ($caught -and $caught.Exception.Message -match $Match) ('Expected refusal '+$Match+'; got '+$caught)}
Check (!('IW7StockLinksV1.Ntfs' -as [type])) 'Import loaded the native metadata provider'
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('iw7-stock-links-fixture-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot)|Out-Null
$script:contexts=[Collections.Generic.List[object]]::new();$script:keys=[Collections.Generic.List[string]]::new()
function New-Case([string]$Name,[switch]$MissingArchive,[switch]$ArchiveOnly,[switch]$SourceAliases) {
    $root=Join-Path $testRoot $Name;$source=Join-Path $root 'source';$target=Join-Path $root 'target'
    [IO.Directory]::CreateDirectory((Join-Path $source 'english'))|Out-Null
    $paths=@('assetfile1.pak','english/cp_zmb.ff')
    foreach($relative in $paths){$path=Join-Path $source $relative;[IO.File]::WriteAllText($path,'owned synthetic '+$relative);[IO.File]::SetAttributes($path,$(if($MissingArchive){[IO.FileAttributes]::ReadOnly}elseif($ArchiveOnly){[IO.FileAttributes]::Archive}else{[IO.FileAttributes]'ReadOnly,Archive'}))}
    Initialize-IW7StockLinkNtfs
    if($SourceAliases){[IW7StockLinksV1.Ntfs]::CreateLinkNew((Join-Path $source 'assetfile2.pak'),(Join-Path $source 'assetfile1.pak'));$paths+=@('assetfile2.pak');[IW7StockLinksV1.Ntfs]::CreateLinkNew((Join-Path $root 'outside-pathset.pak'),(Join-Path $source 'assetfile1.pak'))}
    $rows=@();$total=0L
    foreach($relative in $paths){$m=Get-IW7StockLinkMetadata (Join-Path $source $relative);$total+=$m.Bytes;$rows+=@{relative=$relative;bytes=$m.Bytes;volume=$m.Volume;file_id=$m.FileIdLow;links=$m.Links;attributes=$m.Attributes;created_ns=$m.CreatedNs;modified_ns=$m.ModifiedNs}}
    $manifest=@{schema='iw7.server-only-link-plan/1';source=$source;target=$target;planned_files=$paths.Count;logical_bytes=$total;
        stock_content_read=$false;hashes_computed=$false;links_created=$false;stock_bytes_copied=0;client_clone_created=$false;files=$rows}
    $manifestPath=Join-Path $root 'plan.json';[IO.File]::WriteAllText($manifestPath,($manifest|ConvertTo-Json -Depth 8))
    $hash=(Get-FileHash -LiteralPath $manifestPath).Hash.ToLowerInvariant();$key='IW7.StockLinks.Fixture.'+[guid]::NewGuid().ToString('N')
    $owner=@{ExpectedToken='synthetic-no-production-lease';Calls=0;FailAfterLinks=-1};[AppDomain]::CurrentDomain.SetData($key,$owner);$script:keys.Add($key)
    [pscustomobject]@{Root=$root;Source=$source;Target=$target;Manifest=$manifestPath;Hash=$hash;Owner=$owner;Key=$key;Rows=$rows;Context=$null}
}
function New-Transaction($Case) {
    $plan=Read-IW7StockLinkPlan -ManifestPath $Case.Manifest -ExpectedManifestSHA256 $Case.Hash -SourceRoot $Case.Source -TargetRoot $Case.Target
    $owner=$Case.Owner
    $validator={param($token,$target) $owner.Calls++;if($token -cne $owner.ExpectedToken){throw 'Synthetic caller lease differs.'};if($owner.Contains('StockLinkTransaction') -and $owner.FailAfterLinks -ge 0 -and $owner.StockLinkTransaction.CreatedLinks.Count -ge $owner.FailAfterLinks){throw 'Injected caller failure.'}}.GetNewClosure()
    $context=New-IW7StockLinkTransaction -Plan $plan -OwnerRoot $owner -RetentionKey $Case.Key -LeaseToken $owner.ExpectedToken -ValidateCaller $validator -JournalPath (Join-Path $Case.Root 'journal.jsonl')
    $script:contexts.Add($context);$Case.Context=$context;$context
}
try{
    $case=New-Case 'success';$context=New-Transaction $case
    Check ([object]::ReferenceEquals($case.Owner.StockLinkTransaction,$context) -and !(Test-Path -LiteralPath $case.Target)) 'Context was not published before target creation'
    $prepared=Invoke-IW7StockLinkApply $context
    Check ($prepared.Prepared -and $prepared.SourcePreserved -and $prepared.CreatedLinks -eq 2 -and $prepared.RetailDataBytesCopied -eq 0 -and !$prepared.RuntimeValidated) 'Prepared result overclaims or lost stock invariants'
    foreach($source in $context.Sources){$target=Get-IW7StockLinkMetadata $source.Target;Check ($target.Identity -ceq $source.Before.Identity -and $target.Links -eq $source.Before.Links+1 -and $target.Attributes -eq 33) 'Created link differs or readonly/archive attributes changed'}
    Check ($context.Closed -and $context.Guards.Count -eq 0 -and !$context.JournalStream) 'Known success retained unnecessary guards'
    $undo=Undo-IW7StockLinkTransaction $context
    Check ($undo.RollbackClosed -and $undo.SourcePreserved -and $undo.TargetAbsent) 'Owned link/directory rollback did not close'
    $events=@(Get-Content -LiteralPath $context.JournalPath|ConvertFrom-Json)
    Check ($events[-1].Event -ceq 'RolledBack' -and @($events|Where-Object Event -CEQ 'LinkRemoved').Count -eq 2) 'Successful apply rollback was not journaled'
    foreach($source in $context.Sources){$m=Get-IW7StockLinkMetadata $source.Path;Check ($m.Identity -ceq $source.Before.Identity -and $m.Links -eq $source.Before.Links -and $m.Attributes -eq 33) 'Rollback altered shared source or link count'}
    $case=New-Case 'archive-only' -ArchiveOnly;$context=New-Transaction $case;$null=Invoke-IW7StockLinkApply $context
    Check ((Get-IW7StockLinkMetadata $context.Sources[0].Target).Attributes -eq 32) 'Archive-only stock attributes were modified'
    Check ((Undo-IW7StockLinkTransaction $context).SourcePreserved) 'Archive-only stock rollback failed'
    $case=New-Case 'source-aliases' -SourceAliases;$context=New-Transaction $case;$null=Invoke-IW7StockLinkApply $context
    Check ($context.Groups.Count -eq 2 -and (Get-IW7StockLinkMetadata $context.Sources[0].Target).Links -eq 5) 'Repeated source identity was not grouped correctly'
    Check ((Undo-IW7StockLinkTransaction $context).SourcePreserved -and (Get-IW7StockLinkMetadata (Join-Path $case.Root 'outside-pathset.pak')).Links -eq 3) 'Aliases outside the reviewed pathset were changed'
    $case=New-Case 'preflight-guards' -ArchiveOnly;$context=New-Transaction $case;Invoke-IW7StockLinkPreflight $context
    Refuse {[IO.Directory]::Move((Join-Path $case.Source 'english'),(Join-Path $case.Source 'renamed'))} 'used|denied'
    Refuse {[IO.File]::Open((Join-Path $case.Source 'assetfile1.pak'),'Open','Write','ReadWrite').Dispose()} 'used|denied'
    Check (!(Test-Path -LiteralPath $case.Target) -and [object]::ReferenceEquals($case.Owner.StockLinkTransaction,$context)) 'Preflight created aliases or lost retained context'
    $null=Undo-IW7StockLinkTransaction $context
    $case=New-Case 'stale-manifest';$context=New-Transaction $case
    [IO.File]::AppendAllText($case.Manifest,' ')
    Refuse {Invoke-IW7StockLinkApply $context} 'manifest hash differs'
    Check (!(Test-Path -LiteralPath $case.Target)) 'Changed manifest created target'
    $case=New-Case 'archive-missing' -MissingArchive
    Refuse {New-Transaction $case} 'Archive-missing'
    Check (!(Test-Path -LiteralPath $case.Target)) 'Archive refusal created target'
    $case=New-Case 'existing-target';$context=New-Transaction $case;[IO.Directory]::CreateDirectory($case.Target)|Out-Null
    Refuse {Invoke-IW7StockLinkApply $context} 'must be absent'
    Check ($context.CreatedLinks.Count -eq 0) 'Existing target was adopted'
    $case=New-Case 'partial';$context=New-Transaction $case;$case.Owner.FailAfterLinks=1
    Refuse {Invoke-IW7StockLinkApply $context} 'Injected caller failure'
    Check ($context.Phase -ceq 'Unknown' -and !$context.Closed -and $context.CreatedLinks.Count -eq 1 -and $context.Guards.Count -gt 0 -and $context.JournalStream) 'Failed apply lost original recovery objects'
    Refuse {[IO.Directory]::Move($case.Target,(Join-Path $case.Root 'unowned-moved'))} 'used|denied'
    $case.Owner.FailAfterLinks=-1
    $undo=Undo-IW7StockLinkTransaction $context
    Check ($undo.RollbackClosed -and $undo.SourcePreserved -and $undo.TargetAbsent) 'Partial apply could not recover exact owned links'
    $case=New-Case 'journal-close-failure';$context=New-Transaction $case;$case.Owner.FailAfterLinks=1
    Refuse {Invoke-IW7StockLinkApply $context} 'Injected caller failure'
    $count=$context.Guards.Count;$context.JournalStream.Dispose() # Owned-fixture fault injection only.
    try{
        Refuse {Close-IW7StockLinkGuards $context} 'closed|unavailable'
        Check ($context.Guards.Count -eq $count -and @($context.Guards|Where-Object IsClosed).Count -eq 0) 'Journal query failure closed original recovery guards'
    }finally{$context.JournalStream=$null} # Fixture alone owns this deliberately invalidated writer.
    $case=New-Case 'source-missing';$context=New-Transaction $case;$null=Invoke-IW7StockLinkApply $context
    $path=$context.Sources[0].Path;$h=[IW7StockLinksV1.Ntfs]::OpenOwnedDelete($path);try{[IW7StockLinksV1.Ntfs]::UnlinkByHandle($h)}finally{$h.Dispose()}
    Refuse {Undo-IW7StockLinkTransaction $context} 'Open stock metadata'
    Check ((Test-Path -LiteralPath $context.CreatedLinks[0].Path) -and !$context.CreatedLinks[0].Removed) 'Missing source caused last-link deletion'
    $case=New-Case 'journal-replaced';$context=New-Transaction $case;$null=Invoke-IW7StockLinkApply $context
    [IO.File]::Delete($context.JournalPath);[IO.File]::WriteAllText($context.JournalPath,'foreign journal')
    Refuse {Undo-IW7StockLinkTransaction $context} 'journal identity/metadata changed'
    Check ((Test-Path -LiteralPath $context.CreatedLinks[0].Path) -and !$context.CreatedLinks[0].Removed) 'Replaced journal caused deletion'
    $case=New-Case 'wrong-identity';$context=New-Transaction $case;$null=Invoke-IW7StockLinkApply $context
    $path=$context.CreatedLinks[0].Path;$h=[IW7StockLinksV1.Ntfs]::OpenOwnedDelete($path);try{[IW7StockLinksV1.Ntfs]::UnlinkByHandle($h)}finally{$h.Dispose()}
    [IO.File]::WriteAllText($path,'foreign replacement')
    Refuse {Undo-IW7StockLinkTransaction $context} 'alias identity changed|type/link-count differs'
    Check ([IO.File]::ReadAllText($path) -ceq 'foreign replacement') 'Rollback deleted an unowned replacement'
    Refuse {Undo-IW7StockLinkTransaction (@{Schema=$context.Schema;HostPID=$PID;RetentionKey=$context.RetentionKey}|ConvertTo-Json|ConvertFrom-Json)} 'Same original retained'
    $case=New-Case 'unknown-entry';$context=New-Transaction $case;$null=Invoke-IW7StockLinkApply $context
    [IO.File]::WriteAllText((Join-Path $case.Target 'caller-owned.cfg'),'preserve')
    Refuse {Undo-IW7StockLinkTransaction $context} 'Unowned/mutable'
    Check ([IO.File]::ReadAllText((Join-Path $case.Target 'caller-owned.cfg')) -ceq 'preserve') 'Rollback recursively deleted caller-owned content'
    foreach($relative in @('../escape.pak','folder/../escape.ff','bad:stream.pak','CON.ff','tail.')){Refuse {ConvertTo-IW7StockRelative $relative} 'Traversal|Plain relative'}
    $case=New-Case 'reparse';$context=New-Transaction $case
    $outside=Join-Path $case.Root 'outside';[IO.Directory]::CreateDirectory($outside)|Out-Null
    $junction=Join-Path $case.Source 'junction';New-Item -ItemType Junction -Path $junction -Target $outside|Out-Null
    try{Refuse {Assert-IW7StockAbsolutePath (Join-Path $junction 'new.ff')} 'reparse'}finally{[IO.Directory]::Delete($junction,$false)}
    [pscustomobject]@{Passed=$true;Checks=$script:checks;RealOwnedTempHardlinks=$true;RetailDataTouched=$false;ProductionLeaseAcquired=$false;GameLaunched=$false}|ConvertTo-Json
}finally{
    foreach($context in $script:contexts){Close-IW7StockLinkGuards $context}
    foreach($key in $script:keys){[AppDomain]::CurrentDomain.SetData($key,$null)}
    # Only this verified test-created root. RO files unlink by original handles;
    # never clear shared attributes or recursively follow a junction.
    $resolved=[IO.Path]::GetFullPath($testRoot);$boundary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(!$resolved.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^iw7-stock-links-fixture-[0-9a-f]{32}$'){throw 'Fixture cleanup escaped owned temp root.'}
    if(Test-Path -LiteralPath $resolved){
        $options=[IO.EnumerationOptions]::new();$options.RecurseSubdirectories=$true;$options.AttributesToSkip=[IO.FileAttributes]::ReparsePoint
        foreach($file in [IO.Directory]::EnumerateFiles($resolved,'*',$options)){
            $h=[IW7StockLinksV1.Ntfs]::OpenOwnedDelete($file);try{[IW7StockLinksV1.Ntfs]::UnlinkByHandle($h)}finally{$h.Dispose()}
        }
        $directories=@([IO.Directory]::EnumerateDirectories($resolved,'*',$options)|Sort-Object Length -Descending)+@($resolved)
        foreach($directory in $directories){[IO.Directory]::Delete($directory,$false)}
    }
}
