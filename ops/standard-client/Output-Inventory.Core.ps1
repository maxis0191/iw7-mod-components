# Output observations only: this helper never starts, closes or releases an owner.
function New-IW7StandardOutputHistory {
    [pscustomobject]@{Samples=0L;IncompleteSamples=0L;MissingTempCount=0L;CounterSaturated=$false;LastSample=$null}
}

function Test-IW7StandardOutputNotFound([Exception]$Exception) {
    if($Exception -is [Management.Automation.MethodInvocationException]){$Exception=$Exception.InnerException}
    return ($Exception -is [IO.FileNotFoundException] -or $Exception -is [IO.DirectoryNotFoundException])
}

function Measure-IW7StandardBuildOutputs {
    param([string[]]$Roots,[string]$RunRoot,[long]$MaximumBytes,[int]$MaximumEntries,[object]$History,
        [long]$AdditionalBytes=0,[int]$AdditionalEntries=0,[object]$WaitingStage=$null)
    if(!$Roots -or $Roots.Count -gt 4 -or $MaximumBytes -le 0 -or $MaximumEntries -le 0 -or
        $AdditionalBytes -lt 0 -or $AdditionalEntries -lt 0){throw 'Invalid finite output inventory inputs.'}
    foreach($name in @('Samples','IncompleteSamples','MissingTempCount')){
        if($null -eq $History -or $null -eq $History.PSObject.Properties[$name] -or
            $History.$name -isnot [long] -or $History.$name -lt 0){throw 'Original output history required.'}
    }
    if($History.CounterSaturated -isnot [bool] -or $null -eq $History.PSObject.Properties['LastSample']){throw 'Output history shape differs.'}
    if(![IO.Path]::IsPathFullyQualified($RunRoot)){throw 'Absolute owned RunRoot required.'}
    $run=[IO.Path]::GetFullPath($RunRoot)
    if([string]::Equals($run,[IO.Path]::GetPathRoot($run),[StringComparison]::OrdinalIgnoreCase)){throw 'Owned RunRoot cannot be a volume root.'}
    $run=$run.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    if(![IO.Path]::IsPathFullyQualified($run)){throw 'Canonical RunRoot became relative.'}
    $canonical=@(foreach($rootPath in $Roots){
        if(![IO.Path]::IsPathFullyQualified($rootPath)){throw 'Absolute output roots required.'}
        $full=[IO.Path]::GetFullPath($rootPath)
        if([string]::Equals($full,[IO.Path]::GetPathRoot($full),[StringComparison]::OrdinalIgnoreCase)){throw 'Output root cannot be a volume root.'}
        $full=$full.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
        if(![IO.Path]::IsPathFullyQualified($full)){throw 'Canonical output root became relative.'}
        $full
    })
    $tempPrefix=$null
    if($null -ne $WaitingStage){
        if($WaitingStage.Stage -isnot [string] -or $WaitingStage.Stage -cnotin @('Premake','MSBuild') -or
            $WaitingStage.StartAttempted -isnot [bool] -or !$WaitingStage.StartAttempted -or
            $null -eq $WaitingStage.Owner -or $WaitingStage.StartInfo -isnot [Diagnostics.ProcessStartInfo]){throw 'Original waiting stage required.'}
        $temp=[IO.Path]::Combine($run,($WaitingStage.Stage+'-temp'))
        foreach($name in @('TEMP','TMP')){
            $value=$WaitingStage.StartInfo.Environment[$name]
            if($value -isnot [string] -or ![string]::Equals($value,$temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Original stage TEMP/TMP differs.'}
        }
        $tempPrefix=$temp+[IO.Path]::DirectorySeparatorChar
    }
    $sample=[pscustomobject]@{ObservedBytes=$AdditionalBytes;VisitedEntries=[long]$AdditionalEntries
        MaximumBytes=$MaximumBytes;MaximumEntries=$MaximumEntries;Complete=$false;TraversalFinished=$false
        MissingTempCount=0L;AbsentRoots=0;BudgetExceeded=$false;AtomicSnapshot=$false}
    $History.LastSample=$sample # Retain partial observations before any filesystem call.
    try {
        if($sample.ObservedBytes -gt $MaximumBytes -or $sample.VisitedEntries -gt $MaximumEntries){$sample.BudgetExceeded=$true;throw 'Observed output budget exceeded.'}
        $queue=[Collections.Generic.Queue[string]]::new()
        foreach($rootPath in $canonical){
            try{$null=[IO.File]::GetAttributes($rootPath)}
            catch{if(Test-IW7StandardOutputNotFound $_.Exception){$sample.AbsentRoots++;continue};throw}
            if([long]$queue.Count+$sample.VisitedEntries -ge $MaximumEntries){$sample.BudgetExceeded=$true;throw 'Output inventory work bound exceeded.'}
            $queue.Enqueue($rootPath)
        }
        while($queue.Count){
            $path=$queue.Dequeue()
            # Count every attempted entry, including a vanished TEMP, before the catch.
            $sample.VisitedEntries++
            if($sample.VisitedEntries -gt $MaximumEntries){$sample.BudgetExceeded=$true;throw 'Output inventory work bound exceeded.'}
            try{$attributes=[IO.File]::GetAttributes($path)}
            catch{
                if($null -ne $tempPrefix -and $path.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase) -and
                    (Test-IW7StandardOutputNotFound $_.Exception)){$sample.MissingTempCount++;continue}
                throw
            }
            if(($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Redirected owned output refused.'}
            if(($attributes -band [IO.FileAttributes]::Directory) -ne 0){
                foreach($child in [IO.Directory]::EnumerateFileSystemEntries($path)){
                    $child=[IO.Path]::GetFullPath($child)
                    if(!$child.StartsWith($path+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Output child escaped its enumerated directory.'}
                    if([long]$queue.Count+$sample.VisitedEntries -ge $MaximumEntries){$sample.BudgetExceeded=$true;throw 'Output inventory work bound exceeded.'}
                    $queue.Enqueue($child)
                }
            }else{
                $length=[IO.FileInfo]::new($path).Length
                if($length -lt 0 -or $length -gt ([long]::MaxValue - $sample.ObservedBytes)){$sample.BudgetExceeded=$true;throw 'Output byte count overflow.'}
                $sample.ObservedBytes+=$length
            }
            if($sample.ObservedBytes -gt $MaximumBytes){$sample.BudgetExceeded=$true;throw 'Observed output byte budget exceeded.'}
        }
        $sample.TraversalFinished=$true;$sample.Complete=$sample.MissingTempCount -eq 0
        return ,$sample
    } finally {
        # These are observation counters, never a cumulative/peak budget PASS.
        $increments=@{Samples=1L;IncompleteSamples=[long](!$sample.Complete);MissingTempCount=$sample.MissingTempCount}
        foreach($name in $increments.Keys){
            if($History.$name -gt ([long]::MaxValue - $increments[$name])){$History.$name=[long]::MaxValue;$History.CounterSaturated=$true}
            else{$History.$name+=$increments[$name]}
        }
    }
}

function Wait-IW7StandardBuildOutputOwner {
    param([object]$Stage,[Diagnostics.Stopwatch]$Clock,[double]$GroupSeconds,[double]$StageSeconds,
        [string[]]$Roots,[string]$RunRoot,[long]$MaximumBytes,[int]$MaximumEntries,[object]$History)
    $owner=$Stage.Owner;$startInfo=$Stage.StartInfo
    $startedProperty=$Stage.PSObject.Properties['Started']
    if($startedProperty -isnot [Management.Automation.PSNoteProperty]){throw 'Original Started value required.'}
    $started=$startedProperty.Value
    if($null -eq $owner -or $null -eq $Clock -or !$Clock.IsRunning -or
        $started -isnot [double] -or ![double]::IsFinite($started) -or $started -lt 0 -or $started -gt $Clock.Elapsed.TotalSeconds -or
        ![double]::IsFinite($GroupSeconds) -or ![double]::IsFinite($StageSeconds) -or
        $GroupSeconds -le 0 -or $StageSeconds -le 0){throw 'Original owner, Started value and running group clock required.'}
    while($true){
        if(![object]::ReferenceEquals($Stage.Owner,$owner) -or ![object]::ReferenceEquals($Stage.StartInfo,$startInfo) -or
            ![object]::ReferenceEquals($Stage.PSObject.Properties['Started'],$startedProperty) -or
            $startedProperty.Value -isnot [double] -or !$started.Equals($startedProperty.Value)){throw 'Original waiting owner or Started value changed.'}
        $exited=$owner.TreeExited()
        if($exited -isnot [bool] -or ![object]::ReferenceEquals($Stage.Owner,$owner) -or
            ![object]::ReferenceEquals($Stage.StartInfo,$startInfo) -or !$Clock.IsRunning -or
            ![object]::ReferenceEquals($Stage.PSObject.Properties['Started'],$startedProperty) -or
            $startedProperty.Value -isnot [double] -or !$started.Equals($startedProperty.Value)){throw 'Original waiting owner, Started value or clock changed.'}
        if($exited){return}
        $now=$Clock.Elapsed.TotalSeconds
        if($now -ge $GroupSeconds -or $now-$started -ge $StageSeconds){throw 'Original owned-tree deadline expired.'}
        $null=Measure-IW7StandardBuildOutputs -Roots $Roots -RunRoot $RunRoot -MaximumBytes $MaximumBytes -MaximumEntries $MaximumEntries -History $History -WaitingStage $Stage
        [Threading.Thread]::Sleep(100)
    }
}
