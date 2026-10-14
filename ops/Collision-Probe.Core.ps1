# Pure parsing of one fresh launch-owned transcript. No engine or OS actions.
function Send-IW7CollisionProbeCommand($Handle,$Identity,[string]$Command) {
    if($Command -cnotin @('set paris_collision_probe_arm 1','quit')){throw 'Only the two fixed collision commands are accepted.'}
    if(!$Handle -or !$Identity -or $Handle.Id -ne $Identity.PID -or !$Handle.CollisionProbeConsoleEnabled -or $Handle.HasExited){throw 'Exact original collision dedicated handle required.'}
    $kernel=$Handle.ReadIdentity()
    if($kernel.PID -ne $Identity.PID -or $kernel.Image -ine $Identity.Image -or $kernel.CreationFileTime -ne $Identity.CreationFileTime){throw 'Collision console kernel identity differs.'}
    $bytes=$Handle.WriteCollisionProbeCommand($Command,$Identity.Image,[long]$Identity.CreationFileTime)
    [pscustomobject]@{Command=$Command;BytesWritten=$bytes;PID=$kernel.PID;CreationFileTime=$kernel.CreationFileTime;
        Transport='original-owned-stdin-wincon';EngineConsumed=$false}
}
function Read-IW7CollisionProbeResult([string]$Text,[string]$Token) {
    if($Token -cnotmatch '^[a-f0-9]{32}$'){throw 'Collision run token required.'}
    $last=$Text.LastIndexOf("`n");if($last -lt 0){return [pscustomobject]@{Ready=$false;Complete=$false}}
    $text=$Text.Substring(0,$last+1)
    $prefix='(?m)^\[Collision probe\] '
    if($text -match ($prefix+'FAIL token='+$Token+' ')){throw 'Collision fixture refused the run.'}
    $ready=[regex]::Matches($text,$prefix+'READY token='+$Token+'[\t ]*\r?$')
    $done=[regex]::Matches($text,$prefix+'DONE token='+$Token+'[\t ]*\r?$')
    if($ready.Count -gt 1 -or $done.Count -gt 1){throw 'Repeated collision fixture token.'}
    if(!$done.Count){return [pscustomobject]@{Ready=($ready.Count -eq 1);Complete=$false}}
    $created=[regex]::Matches($text,$prefix+'CREATED token='+$Token+' instance=(\d+)[\t ]*\r?$')
    $safety=[regex]::Matches($text,$prefix+'SAFETY token='+$Token+' clients=0 cheats=0 inactivity=0[\t ]*\r?$')
    if($ready.Count -ne 1 -or $created.Count -ne 1 -or $safety.Count -ne 1 -or
        $ready[0].Index -ge $safety[0].Index -or $safety[0].Index -ge $created[0].Index -or
        $created[0].Index -ge $done[0].Index){throw 'Collision fixture sequence is incomplete.'}
    $id=[uint32]::Parse($created[0].Groups[1].Value,[Globalization.CultureInfo]::InvariantCulture)
    $allocation=[regex]::Matches($text,'(?m)^\[Collision provider\] created world=0 entity=(\d+) instance='+$id+' original_vertices=8 contents=1 template=([^\r\n]+)[\t ]*\r?$')
    if($allocation.Count -ne 1 -or $allocation[0].Index -le $safety[0].Index -or $allocation[0].Index -ge $created[0].Index){throw 'Actual original body allocation was not observed.'}
    $entity=$allocation[0].Groups[1].Value
    $number='([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)'
    $traces=@();$previous=$safety[0].Index;$afterFirst=$null
    foreach($phase in @('before','inside','after')){
        foreach($point in @('center','edge')){
            $matches=[regex]::Matches($text,$prefix+'TRACE token='+$Token+' phase='+$phase+' point='+$point+' fraction='+$number+'[\t ]*\r?$')
            if($matches.Count -ne 1 -or $matches[0].Index -le $previous -or $matches[0].Index -ge $done[0].Index){throw 'Collision control trace missing, repeated or reordered.'}
            $value=[double]::Parse($matches[0].Groups[1].Value,[Globalization.CultureInfo]::InvariantCulture)
            if(![double]::IsFinite($value) -or $value -lt 0 -or $value -gt 1){throw 'Invalid engine trace fraction.'}
            if($phase -eq 'inside'){
                if([math]::Abs($value-0.5) -gt 0.001 -or $matches[0].Index -le $created[0].Index){throw 'Original floor plane was not hit at both measured points.'}
            }elseif([math]::Abs($value-1) -gt 0.000001){throw 'Baseline or post-removal trace is obstructed.'}
            if($phase -eq 'before' -and $matches[0].Index -ge $created[0].Index){throw 'Baseline followed body creation.'}
            $traces+=[pscustomobject]@{Phase=$phase;Point=$point;Fraction=$value}
            if($phase -eq 'after' -and $point -eq 'center'){$afterFirst=$matches[0].Index}
            $previous=$matches[0].Index
        }
    }
    $native=@()
    $nativeOffsets=@()
    foreach($kind in @('point_floor','actor_floor')){
        $pattern='(?m)^\[Collision provider\] engine_query='+$kind+' world=0 instance='+$id+' fraction='+$number+
            ' normal='+$number+','+$number+','+$number+' contents=(\d+) hitType=(\d+) hitId=(\d+) startsolid=(\d+) allsolid=(\d+)[\t ]*\r?$'
        $m=[regex]::Matches($text,$pattern)
        if($m.Count -ne 1 -or $m[0].Index -le $created[0].Index -or $m[0].Index -ge $done[0].Index){throw 'Actual native query missing or repeated.'}
        $fraction=[double]::Parse($m[0].Groups[1].Value,[Globalization.CultureInfo]::InvariantCulture)
        $normal=@(2..4|ForEach-Object{[double]::Parse($m[0].Groups[$_].Value,[Globalization.CultureInfo]::InvariantCulture)})
        $nz=$normal[2]
        if(![double]::IsFinite($fraction) -or $fraction -le 0 -or $fraction -ge 1 -or
            @($normal|Where-Object{![double]::IsFinite($_)}).Count -or [math]::Abs($normal[0]) -gt 0.01 -or
            [math]::Abs($normal[1]) -gt 0.01 -or [math]::Abs($nz-1) -gt 0.01 -or $m[0].Groups[5].Value -ne '1' -or
            $m[0].Groups[7].Value -ne '2046' -or $m[0].Groups[8].Value -ne '0' -or $m[0].Groups[9].Value -ne '0'){
            throw 'Native query does not establish an unobstructed solid world-floor hit.'
        }
        if($kind -eq 'point_floor' -and [math]::Abs($fraction-0.5) -gt 0.001){throw 'Native point query misses the original top plane.'}
        $nativeOffsets+=$m[0].Index
        $native+=[pscustomobject]@{Kind=$kind;Fraction=$fraction;Normal=$normal;Contents=1;HitType=[int]$m[0].Groups[6].Value;HitId=2046;Raw=$m[0].Value}
    }
    $destroy=[regex]::Matches($text,'(?m)^\[Collision provider\] destroyed world=0 entity='+$entity+' instance='+$id+'[\t ]*\r?$')
    if($destroy.Count -ne 1 -or $destroy[0].Index -le $created[0].Index -or $destroy[0].Index -ge $afterFirst -or
        @($nativeOffsets|Where-Object{$_ -ge $destroy[0].Index}).Count){throw 'Explicit owned body removal was not observed before the clear controls.'}
    [pscustomobject]@{Ready=$true;Complete=$true;Instance=$id;Entity=[int]$entity;Template=$allocation[0].Groups[2].Value.Trim();Controls=$traces;NativeQueries=$native;
        PointPlaneVerified=$true;PostRemovalPointQueriesClear=$true;PostRemovalActorQueryVerified=$false;
        ActorShapeQualified=$false;StaticSensorBehaviorQualified=$false;TemplateUsageRestoredVerified=$false;
        PhysicsWorldResetVerified=$false;PlayerMovementVerified=$false;OwnerAccepted=$false}
}
