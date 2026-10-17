# Pure plan/transcript checks. No process, scheduler, engine or image reads.
function New-IW7CollisionPlayerPlan([double[]]$Anchor,[string]$Token) {
    if($Anchor.Count -ne 3 -or @($Anchor|Where-Object{![double]::IsFinite($_) -or [math]::Abs($_) -gt 30000}).Count -or
        $Token -cnotmatch '^[a-f0-9]{32}$'){throw 'Finite reviewed anchor and unique 32-hex token required.'}
    $config="set paris_collision_player_test 1`nset paris_collision_player_anchor_current 1`nset paris_collision_probe_arm 0`nset paris_collision_probe_token `"$Token`"`n"
    [pscustomobject]@{Schema='iw7.collision-player-plan/1';Anchor=@($Anchor);Token=$Token;PlannedClients=1;World=0;ServerPort=27116;
        Minimum=@(($Anchor[0]-128),($Anchor[1]-128),($Anchor[2]+96));Maximum=@(($Anchor[0]+128),($Anchor[1]+128),($Anchor[2]+112));
        Start=@($Anchor[0],$Anchor[1],($Anchor[2]+208));MeasuredDeadlineMs=25000;NativeArmDeadlineMs=30000;
        Config=$config;ClearanceQualified=$false;ClientCollider=$false;ClientPredictionVerified=$false;MainDeployed=$false;OwnerAccepted=$false}
}

function Get-IW7CollisionPlayerOne([string]$Text,[string]$Pattern) {
    $m=[regex]::Matches($Text,$Pattern)
    if($m.Count -ne 1){throw 'Missing, repeated or malformed collision-player evidence.'}
    $m[0]
}

function Get-IW7CollisionPlayerStableStart($Rows,[scriptblock]$Predicate) {
    $start=$null
    foreach($row in $Rows){if(& $Predicate $row){if($null -eq $start){$start=$row.Tick}}else{$start=$null}}
    $start
}

function Assert-IW7CollisionPlayerOwnership($Session,$Identity,$Kernel,$Lease,$CurrentHost,[int]$CallerPid) {
    $expected='012E6CDDCD6A91ADC2F041035C86417064998127044A11341895C55F8BD4FC53'
    if(!$Session -or !$Identity -or !$Kernel -or !$Lease -or !$CurrentHost -or $CallerPid -le 0 -or
        $Session.PairOwnership -or $Session.Failed -or $Session.Plan.ServerPort -ne 27116 -or
        $Session.Server.PID -ne $Identity.PID -or $Session.Server.Image -ine $Identity.Image -or $Identity.SHA256 -cne $expected -or
        $Kernel.PID -ne $Identity.PID -or $Kernel.Image -ine $Identity.Image -or $Kernel.CreationFileTime -ne $Identity.CreationFileTime -or
        ([datetimeoffset]$Session.Server.CreatedUtc).UtcDateTime.ToFileTimeUtc() -ne $Kernel.CreationFileTime -or
        $Lease.Kind -cne 'Runtime' -or $Lease.Token -cne $Session.LeaseToken -or $Lease.OwnerIdentity.PID -ne $CallerPid -or
        $CurrentHost.PID -ne $CallerPid -or $Lease.OwnerIdentity.Image -ine $CurrentHost.Image -or
        ([datetimeoffset]$Lease.OwnerIdentity.CreatedUtc).UtcTicks -ne ([datetimeoffset]$CurrentHost.CreatedUtc).UtcTicks){throw 'Original protected collision group identity/ownership differs.'}
}

function New-IW7CollisionReadinessBindings($Session,$ServerIdentity,[string]$Token,[string]$ClientNonce) {
    # Call only after the existing owned-session and wire validation. No IO/clock.
    if(!$Session -or !$Session.Identity -or !$ServerIdentity -or $Session.Identity.PID -le 0 -or
       $ServerIdentity.PID -le 0 -or $Session.StartedTick -lt 0 -or $Token -cnotmatch '^[a-f0-9]{32}$' -or
       $ClientNonce -cnotmatch '^[a-f0-9]{32}$'){throw 'Validated original collision references required.'}
    if($Session.PSObject.Properties['CollisionReadinessBindings']){throw 'Existing collision bindings must not be replaced or adopted.'}
    $bindings=@{Schema='iw7.collision-readiness-bindings/1';Session=$Session;ClientIdentity=$Session.Identity;
        ServerIdentity=$ServerIdentity;Token=$Token;ClientNonce=$ClientNonce;NotBeforeTick=$Session.StartedTick;
        Generation=$null;CanonicalReady=$null;Status='UNKNOWN';FirstErrorRecord=$null;FirstException=$null;MetadataError=$null}
    Add-Member -InputObject $Session -MemberType NoteProperty -Name CollisionReadinessBindings -Value $bindings
    $bindings
}

function Read-IW7CollisionPlayerReady([string]$Text,[string]$Token,[int]$ServerId,[string]$ClientNonce,[long]$NotBeforeTick,[long]$NowTick,
    [Collections.IDictionary]$Bindings=$null) {
    $ownsBindings={
            if($Bindings -isnot [hashtable] -or $Bindings['Schema'] -cne 'iw7.collision-readiness-bindings/1'){return $false}
            $owner=$Bindings['Session'];if(!$owner){return $false}
            $property=$owner.PSObject.Properties['CollisionReadinessBindings']
            $property -and [object]::ReferenceEquals($property.Value,$Bindings) -and
                [object]::ReferenceEquals($Bindings['ClientIdentity'],$owner.Identity) -and
                $Bindings['ServerIdentity'].PID -eq $ServerId -and $Bindings['Token'] -ceq $Token -and
                $Bindings['ClientNonce'] -ceq $ClientNonce -and $Bindings['NotBeforeTick'] -eq $NotBeforeTick -and
                $owner.StartedTick -eq $NotBeforeTick
    }
    if($Bindings){
        try{if(& $ownsBindings){$Bindings['Generation']=$null;$Bindings['CanonicalReady']=$null;$Bindings['Status']='UNKNOWN';$Bindings['MetadataError']=$null}}catch{}
    }
    if($Text.Length -gt 16MB -or $Token -cnotmatch '^[a-f0-9]{32}$' -or $ServerId -le 0 -or
        $ClientNonce -cnotmatch '^[a-f0-9]{32}$' -or $NowTick -lt $NotBeforeTick){throw 'Bounded launch-owned readiness input required.'}
    $last=$Text.LastIndexOf("`n")
    if($last -ge 0){
        $complete=$Text.Substring(0,$last+1)
        $tail=$Text.Substring($last+1)
        $ownPrefix='[Collision player] PLAYER_READY token='+$Token
        $failurePrefix='[Collision player] FAIL token='+$Token
        # One canonical validation path. Metadata sees the FULL transcript too.
        $selectCanonical={param([bool]$MetadataOnly)
            if($tail.StartsWith($ownPrefix,[StringComparison]::Ordinal) -or $tail.StartsWith($failurePrefix,[StringComparison]::Ordinal) -or
               ($MetadataOnly -and ($tail.IndexOf($ownPrefix,[StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                $tail.IndexOf($failurePrefix,[StringComparison]::OrdinalIgnoreCase) -ge 0))){
                return @{Publication=[pscustomobject]@{Ready=$false;Pending='Latest own pose publication is not terminated; no predecessor fallback.'};Offset=-1}
            }
            $n='([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)'
            $rows=[regex]::Matches($complete,'(?m)^\[Collision player\] PLAYER_READY token='+$Token+'; server_pid='+$ServerId+'; client_nonce='+$ClientNonce+'; server_generation=([a-f0-9]{32}); slot=0; native_tick_ms=(\d+); protected=1; anchor_x='+$n+'; anchor_y='+$n+'; anchor_z='+$n+'[\t ]*\r?$')
            $ownRows=[regex]::Matches($complete,'(?m)^\[Collision player\] PLAYER_READY token='+$Token+';[^\r\n]*\r?$')
            # LF alone delimits physical lines; a bare CR must stay visible to strict validation.
            if($MetadataOnly -and [regex]::Matches($complete,'(?m)^[^\n]*\[Collision player\] PLAYER_READY token='+$Token+'[^\n]*$',
                [Text.RegularExpressions.RegexOptions]::IgnoreCase).Count -ne $ownRows.Count){throw 'Noncanonical own readiness metadata.'}
            if($ownRows.Count -ne $rows.Count){throw 'Malformed/foreign own pose publication; do not fall back to earlier readiness.'}
            if($rows.Count){$r=$rows[-1];$tick=[long]$r.Groups[2].Value
                if($tick -ge $NotBeforeTick -and $tick -le $NowTick -and $NowTick-$tick -le 500){
                    $anchor=@(3..5|ForEach-Object{[double]::Parse($r.Groups[$_].Value,[Globalization.CultureInfo]::InvariantCulture)})
                    $null=New-IW7CollisionPlayerPlan $anchor $Token
                    return @{Publication=[pscustomobject]@{Ready=$true;Generation=$r.Groups[1].Value;Tick=$tick;Anchor=$anchor;Meaning='Fresh real-pose publication; source tests do not simulate retail intro/terrain state.'};Offset=$r.Index}
                }
            }
            @{Publication=[pscustomobject]@{Ready=$false};Offset=-1}
        }
        $failure=[regex]::Match($complete,'(?m)^\[Collision player\] FAIL token='+$Token+' ',[Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if($failure.Success){
            # Preserve the original -match case-insensitive refusal semantics.
            # Any complete owned FAIL still wins over every ready publication.
            # Parse only a short, allowlisted diagnostic from that first failure.
            $reason=$null;$group=$null;$stampState=$null;$weaponPredicate=$null
            $end=$complete.IndexOf("`n",$failure.Index)
            if($end-$failure.Index -le 384){
                $line=$complete.Substring($failure.Index,$end-$failure.Index)
                $detail=[regex]::Match($line,'^\[Collision player\] FAIL token='+$Token+' reason=(anchor_player_changed|anchor_pose_changed_before_arm|frozen_anchor_readiness_lost|frozen_anchor_player_lost|admission_or_clearance)(?: readiness_group=(safe|ground|weapon|velocity|intro_screen|intro_gesture|controls|hostmigration|ready) stamp_state=(undefined|empty|unavailable|available)(?: weapon_predicate=(undefined|empty|none|not_owned))?)?[\t ]*\r?$')
                if($detail.Success -and (!$detail.Groups[2].Success -or $detail.Groups[1].Value -ceq 'frozen_anchor_readiness_lost') -and
                   (!$detail.Groups[4].Success -or $detail.Groups[2].Value -ceq 'weapon')){
                    $reason=$detail.Groups[1].Value
                    if($detail.Groups[2].Success){$group=$detail.Groups[2].Value;$stampState=$detail.Groups[3].Value}
                    if($detail.Groups[4].Success){$weaponPredicate=$detail.Groups[4].Value}
                }
            }
            $message='Fixture refused readiness/anchor; do not arm.'
            if($reason){
                $diagnostic='reason='+$reason
                if($group){$diagnostic+='; readiness_group='+$group+'; stamp_state='+$stampState}
                if($weaponPredicate){$diagnostic+='; weapon_predicate='+$weaponPredicate}
                $message='Fixture refused readiness/anchor ('+$diagnostic+'); do not arm.'
            }
            $readinessError=[InvalidOperationException]::new($message)
            if($reason){$readinessError.Data['CollisionReason']=$reason}
            if($group){$readinessError.Data['CollisionReadinessGroup']=$group;$readinessError.Data['CollisionStampState']=$stampState}
            if($weaponPredicate){$readinessError.Data['CollisionWeaponPredicate']=$weaponPredicate}
            try{throw $readinessError}catch{
                # Capture the FIRST record/exception before any secondary parsing.
                $firstRecord=$_;$firstException=$firstRecord.Exception;$owned=$false
                try{
                    $owned=& $ownsBindings
                    if($owned){
                        if($null -eq $Bindings['FirstErrorRecord']){$Bindings['FirstErrorRecord']=$firstRecord;$Bindings['FirstException']=$firstException}
                        $firstException.Data['CollisionReadinessBindings']=$Bindings
                        $Bindings['Generation']=$null;$Bindings['CanonicalReady']=$null;$Bindings['Status']='UNKNOWN';$Bindings['MetadataError']=$null
                        $selected=& $selectCanonical $true
                        if($selected.Publication.Ready -and $selected.Offset -lt $failure.Index){
                            $Bindings['CanonicalReady']=$selected.Publication;$Bindings['Generation']=$selected.Publication.Generation
                            $Bindings['Status']='VALIDATED_CANONICAL'
                        }
                    }
                }catch{
                    if($owned){
                        $Bindings['Generation']=$null;$Bindings['CanonicalReady']=$null;$Bindings['Status']='UNKNOWN'
                        $Bindings['MetadataError']='Canonical metadata unavailable; original failure retained.'
                    }
                }
                throw
            }
        }
        $selected=& $selectCanonical $false
        if($Bindings){
            try{
                if(& $ownsBindings){
                    $Bindings['Generation']=$null;$Bindings['CanonicalReady']=$null;$Bindings['Status']='UNKNOWN'
                    if($selected.Publication.Ready){$Bindings['CanonicalReady']=$selected.Publication;$Bindings['Generation']=$selected.Publication.Generation;$Bindings['Status']='VALIDATED_CANONICAL'}
                }
            }catch{
                # Optional publication never alters the existing readiness result.
            }
        }
        return $selected.Publication
    }
    if($Bindings){try{if(& $ownsBindings){$Bindings['Generation']=$null;$Bindings['CanonicalReady']=$null;$Bindings['Status']='UNKNOWN'}}catch{}}
    [pscustomobject]@{Ready=$false}
}

function Assert-IW7CollisionPlayerFrozenReady($First,$Current) {
    if(!$First.Ready -or !$Current.Ready -or $Current.Generation -cne $First.Generation -or
        ($Current.Anchor -join ',') -cne ($First.Anchor -join ',')){throw 'Frozen stock-pose readiness changed/expired before arm.'}
}

function Read-IW7CollisionReadinessDiagnostic([string]$Text,[string]$Token,[int]$ServerId,[string]$ClientNonce,
    [string]$Generation,[long]$NotBeforeTick,[long]$NowTick) {
    # Optional pure evidence. Never called by the readiness/arm decision.
    function Inconclusive([string]$Reason) {
        [pscustomobject]@{Status='INCONCLUSIVE';Correlated=$false;Reason=$Reason;DiagnosticOnly=$true;CauseVerified=$false}
    }
    if($Text.Length -gt 16MB -or $Token -cnotmatch '^[a-f0-9]{32}$' -or $ServerId -le 0 -or
       $ClientNonce -cnotmatch '^[a-f0-9]{32}$' -or $Generation -cnotmatch '^[a-f0-9]{32}$' -or
       $NotBeforeTick -lt 0 -or $NowTick -lt $NotBeforeTick){return (Inconclusive 'Invalid bounded owned input.')}
    if(!$Text.EndsWith("`n",[StringComparison]::Ordinal)){return (Inconclusive 'Unterminated transcript; no predecessor fallback.')}
    $rows=[regex]::Matches($Text,'(?m)^[^\n]*\[Collision readiness[^\n]*\n',[Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if($rows.Count -ne 2){return (Inconclusive 'Exactly two complete diagnostic events required.')}
    $pattern='^\[Collision readiness\] token='+$Token+' stage=(freeze|none) eval=([1-9][0-9]{0,5}); server_pid='+$ServerId+
        '; client_nonce='+$ClientNonce+'; server_generation='+$Generation+'; slot=0; native_tick_ms=(0|[1-9][0-9]{0,19}); protected=1'+
        '; gr=([01UN]); w=(passed|none); hw=([01UN]); is=([01UN]); ig=([01UN]); cf=([01UN]); hm=([01UN]); view=cached$'
    $events=@()
    foreach($row in $rows){
        $line=$row.Value.Substring(0,$row.Value.Length-1)
        if($line.EndsWith("`r",[StringComparison]::Ordinal)){$line=$line.Substring(0,$line.Length-1)}
        if($line.Length -gt 384 -or !$line.EndsWith("`t",[StringComparison]::Ordinal)){return (Inconclusive 'Exact single terminal TAB envelope within 384 characters required.')}
        $body=$line.Substring(0,$line.Length-1)
        if($body -cmatch '[^\x20-\x7E]'){return (Inconclusive 'Non-ASCII body or leading/interior/double TAB.')}
        $m=[regex]::Match($body,$pattern)
        if(!$m.Success){return (Inconclusive 'Malformed, duplicate-field or foreign diagnostic row.')}
        $tick=0L
        if(![long]::TryParse($m.Groups[3].Value,[Globalization.NumberStyles]::None,[Globalization.CultureInfo]::InvariantCulture,[ref]$tick) -or
           $tick -lt $NotBeforeTick -or $tick -gt $NowTick){return (Inconclusive 'Stale, future or out-of-domain diagnostic tick.')}
        $events+=,[pscustomobject]@{Stage=$m.Groups[1].Value;Eval=[int]$m.Groups[2].Value;Tick=$tick;Offset=$row.Index;
            RawLine=$row.Value;WireByteCount=$row.Value.Length;BodyByteCount=$body.Length;
            Ground=$m.Groups[4].Value;Weapon=$m.Groups[5].Value;HasWeapon=$m.Groups[6].Value;Intro=$m.Groups[7].Value;
            Gesture=$m.Groups[8].Value;Controls=$m.Groups[9].Value;Migration=$m.Groups[10].Value}
    }
    $freeze=$events[0];$none=$events[1]
    if($freeze.Stage -cne 'freeze' -or $none.Stage -cne 'none' -or $none.Eval -le $freeze.Eval -or $none.Tick -le $freeze.Tick -or
       $freeze.Ground -cne '1' -or $freeze.Weapon -cne 'passed' -or $freeze.HasWeapon -cne '1' -or
       $freeze.Intro -cne '1' -or $freeze.Gesture -cne '1' -or $freeze.Controls -cne '0' -or $freeze.Migration -cnotin @('0','U') -or
       $none.Ground -cne '1' -or $none.Weapon -cne 'none' -or $none.HasWeapon -cne 'N' -or $none.Intro -cne 'N' -or
       $none.Gesture -cne 'N' -or $none.Controls -cne 'N' -or $none.Migration -cne 'N'){
        return (Inconclusive 'Event order, monotonic correlation or cached predicate semantics differ.')
    }
    # The first complete owned failure stays authoritative, even if a later row looks valid.
    # Count malformed owned candidates too, even without the required token separator.
    $failures=[regex]::Matches($Text,'(?m)^[^\n]*\[Collision player\] FAIL token='+$Token+'[^\n]*\n',
        [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if($failures.Count -ne 1 -or $failures[0].Index -le $freeze.Offset -or $failures[0].Index -ge $none.Offset -or
       $failures[0].Value -cnotmatch ('^\[Collision player\] FAIL token='+$Token+
        ' reason=frozen_anchor_readiness_lost readiness_group=weapon stamp_state=available weapon_predicate=none\t\r?\n$') -or
       $failures[0].Value.Length-1-([int]$failures[0].Value.EndsWith("`r`n",[StringComparison]::Ordinal)) -gt 384){
        return (Inconclusive 'Canonical first refusal must precede terminal diagnostics; no readiness fallback.')
    }
    $canonical=$failures[0]
    [pscustomobject]@{Status='CORRELATED';Correlated=$true;DiagnosticOnly=$true;CauseVerified=$false;Events=$events;
        CanonicalFAIL=[pscustomobject]@{RawLine=$canonical.Value;Offset=$canonical.Index;WireByteCount=$canonical.Value.Length;
            BodyByteCount=$canonical.Value.Length-2-([int]$canonical.Value.EndsWith("`r`n",[StringComparison]::Ordinal))};
        Meaning='Cached transition only; no inventory, cleanup, readiness, contact or owner acceptance inferred.'}
}

function Read-IW7CollisionPlayerNative([string]$Text,[uint32]$Instance,[int]$BeforeCreateOffset,[int]$CreatedOffset,[int]$BeforeRemovalOffset,[int]$RemovedOffset) {
    $n='([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)';$culture=[Globalization.CultureInfo]::InvariantCulture
    $created=Get-IW7CollisionPlayerOne $Text ('(?m)^\[Collision provider\] created world=0 entity=(\d+) instance='+$Instance+' original_vertices=8 contents=1 template=([^\r\n]+)[\t ]*\r?$')
    $entity=$created.Groups[1].Value
    $destroyed=Get-IW7CollisionPlayerOne $Text ('(?m)^\[Collision provider\] destroyed world=0 entity='+$entity+' instance='+$Instance+'[\t ]*\r?$')
    if($created.Index -le $BeforeCreateOffset -or $created.Index -ge $CreatedOffset -or $destroyed.Index -le $BeforeRemovalOffset -or $destroyed.Index -ge $RemovedOffset){throw 'Original native allocation/removal ordering changed.'}
    $queries=@();$lastInside=0
    foreach($phase in @('before','inside','removed')){foreach($kind in @('point','actor')){
        $suffix=if($phase -ceq 'inside'){''}else{'_'+$phase};$label=if($phase -ceq 'before'){'4294967295'}else{[string]$Instance}
        $m=Get-IW7CollisionPlayerOne $Text ('(?m)^\[Collision provider\] engine_query='+$kind+'_floor'+$suffix+' world=0 instance='+$label+' fraction='+$n+
            ' normal='+$n+','+$n+','+$n+' contents=(\d+) hitType=(\d+) hitId=(\d+) startsolid=(\d+) allsolid=(\d+)[\t ]*\r?$')
        $v=@(1..4|ForEach-Object{[double]::Parse($m.Groups[$_].Value,$culture)})
        if(@($v|Where-Object{![double]::IsFinite($_)}).Count -or $m.Groups[8].Value -cne '0' -or $m.Groups[9].Value -cne '0'){throw 'Invalid/solid-start native query.'}
        if($phase -ceq 'inside'){
            if($m.Index -le $CreatedOffset -or $m.Index -ge $destroyed.Index -or $v[0] -le 0 -or $v[0] -ge 1 -or
                [math]::Abs($v[1]) -gt 0.01 -or [math]::Abs($v[2]) -gt 0.01 -or [math]::Abs($v[3]-1) -gt 0.01 -or
                $m.Groups[5].Value -cne '1' -or $m.Groups[6].Value -cne '1' -or $m.Groups[7].Value -cne '2046' -or
                ($kind -ceq 'point' -and [math]::Abs($v[0]-0.5) -gt 0.001)){throw 'Native inside world-floor control failed.'}
            $lastInside=[math]::Max($lastInside,$m.Index)
        }elseif([math]::Abs($v[0]-1) -gt 0.000001 -or
            ($phase -ceq 'before' -and ($m.Index -le $BeforeCreateOffset -or $m.Index -ge $created.Index)) -or
            ($phase -ceq 'removed' -and ($m.Index -le $destroyed.Index -or $m.Index -ge $RemovedOffset))){throw 'Native baseline/removal control failed.'}
        $queries+=[pscustomobject]@{Phase=$phase;Kind=$kind;Fraction=$v[0]}
    }}
    $usage=@();$epoch=$null;$last=-1
    foreach($phase in @('before_create','after_native_create','after_manual_increment','before_native_destroy','after_native_destroy','after_manual_decrement')){
        $label=if($phase -ceq 'before_create'){'4294967295'}else{[string]$Instance}
        $m=Get-IW7CollisionPlayerOne $Text ('(?m)^\[Collision provider\] template_usage phase='+$phase+' world=0 entity='+$entity+' instance='+$label+' epoch=(\d+) server=(\d+) client=(\d+) dyn=(\d+)[\t ]*\r?$')
        $e=[uint64]::Parse($m.Groups[1].Value,$culture)
        if(!$e -or ($null -ne $epoch -and $e -ne $epoch) -or $m.Index -le $last -or $m.Index -le $BeforeCreateOffset -or $m.Index -ge $destroyed.Index -or
            ($usage.Count -lt 3 -and $m.Index -ge $created.Index) -or ($usage.Count -ge 3 -and ($m.Index -le $lastInside -or $m.Index -le $BeforeRemovalOffset))){throw 'Shared usage episode/order changed.'}
        $epoch=$e;$last=$m.Index;$counts=@(2..4|ForEach-Object{[int]::Parse($m.Groups[$_].Value,$culture)})
        $usage+=[pscustomobject]@{Phase=$phase;Epoch=$epoch;Counts=$counts}
    }
    $baseline=$usage[0].Counts
    if($baseline[0] -eq [int]::MaxValue){throw 'Template contribution overflow.'}
    $contributed=@(($baseline[0]+1),$baseline[1],$baseline[2])
    foreach($i in 1..5){$expected=if($i -in @(1,5)){$baseline}else{$contributed};if(($usage[$i].Counts -join ',') -cne ($expected -join ',')){throw 'Shared counter interference/restoration failure.'}}
    $report=Get-IW7CollisionPlayerOne $Text ('(?m)^\[Collision provider\] template_usage_result world=0 entity='+$entity+' instance='+$Instance+' epoch='+$epoch+' restored=1[\t ]*\r?$')
    if($report.Index -le $last -or $report.Index -ge $destroyed.Index){throw 'Template restoration report reordered.'}
    [pscustomobject]@{Instance=$Instance;Entity=[int]$entity;Queries=$queries;Usage=$usage;PostRemovalActorQueryVerified=$true;TemplateUsageRestoredVerified=$true}
}

function Read-IW7CollisionPlayerResult {
    param([string]$Text,$Plan,[int]$ServerId,[string]$ClientNonce,[string]$Generation,[long]$NotBeforeTick,[long]$NowTick)
    if($Text.Length -gt 16MB -or $ServerId -le 0 -or $ClientNonce -cnotmatch '^[a-f0-9]{32}$' -or $Generation -cnotmatch '^[a-f0-9]{32}$') {throw 'Bounded launch-owned player transcript required.'}
    $canonical=New-IW7CollisionPlayerPlan $Plan.Anchor $Plan.Token
    foreach($field in @('Start','Minimum','Maximum')){if(($Plan.$field -join ',') -cne ($canonical.$field -join ',')){throw 'Contact plan geometry differs from its canonical anchor.'}}
    $Plan=$canonical
    $last=$Text.LastIndexOf("`n");if($last -lt 0){return [pscustomobject]@{Complete=$false}}
    $text=$Text.Substring(0,$last+1);$prefix='(?m)^\[Collision player\] ';$token=$Plan.Token
    if($text -match ($prefix+'FAIL token='+$token+' ')){throw 'Player fixture refused its control.'}
    $done=[regex]::Matches($text,$prefix+'DONE token='+$token+'[\t ]*\r?$')
    if(!$done.Count){return [pscustomobject]@{Complete=$false}}
    $n='([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)';$culture=[Globalization.CultureInfo]::InvariantCulture
    $events=@();$previous=-1
    foreach($event in @('READY','AUDIT','F0_CLEAR','CREATED','READY_F1','MOVED','REMOVED','OWNER_DELETED','DONE')){
        $tail=switch($event){'AUDIT' {' x='+$n+' y='+$n+' z='+$n+' ground_points=5 vertical_clear=5'} 'CREATED' {' instance=(\d+)'} 'REMOVED' {' owner_alive=1'} default {''}}
        $m=Get-IW7CollisionPlayerOne $text ($prefix+$event+' token='+$token+$tail+'[\t ]*\r?$')
        if($m.Index -le $previous){throw 'Player phase reordered.'};$previous=$m.Index;$events+=,$m
    }
    foreach($i in 0..2){if([math]::Abs([double]::Parse($events[1].Groups[$i+1].Value,$culture)-$Plan.Anchor[$i]) -gt 0.001){throw 'Audited anchor differs from reviewed plan.'}}
    $placements=@();foreach($phase in @('F0','F1')){
        $m=Get-IW7CollisionPlayerOne $text ($prefix+'PLACED token='+$token+' phase='+$phase+' x='+$n+' y='+$n+' z='+$n+'[\t ]*\r?$')
        foreach($i in 0..2){if([math]::Abs([double]::Parse($m.Groups[$i+1].Value,$culture)-$Plan.Start[$i]) -gt 0.001){throw 'Initial placement differs from plan.'}}
        $placements+=,$m
    }
    if([regex]::Matches($text,$prefix+'PLACED token='+$token+' ').Count -ne 2 -or $placements[0].Index -le $events[1].Index -or
        $placements[0].Index -ge $events[2].Index -or $placements[1].Index -le $events[3].Index -or $placements[1].Index -ge $events[4].Index){throw 'Placement occurred inside a measured interval.'}
    $pattern=$prefix+'SAMPLE token='+$token+' phase=(F[012]) sample=(\d+); server_pid='+$ServerId+'; client_nonce='+$ClientNonce+'; server_generation='+$Generation+
        '; slot=0; native_tick_ms=(\d+); protected=1; game_ms=(\d+); x='+$n+'; y='+$n+'; z='+$n+'; vx='+$n+'; vy='+$n+'; vz='+$n+'; ground=([01])[\t ]*\r?$'
    $matches=[regex]::Matches($text,$pattern)
    if($matches.Count -ne [regex]::Matches($text,$prefix+'SAMPLE token='+$token+' ').Count){throw 'Malformed/foreign player sample identity or protection.'}
    $samples=@();$seq=0L;$tick=$NotBeforeTick-1;$game=-1L;$lastSample=$null
    foreach($m in $matches){
        $id=[long]::Parse($m.Groups[2].Value,$culture);$t=[long]::Parse($m.Groups[3].Value,$culture);$g=[long]::Parse($m.Groups[4].Value,$culture)
        $v=@(5..10|ForEach-Object{[double]::Parse($m.Groups[$_].Value,$culture)})
        if($id -ne $seq+1 -or $t -le $tick -or $t -lt $NotBeforeTick -or $t -gt $NowTick -or $g -le $game -or @($v|Where-Object{![double]::IsFinite($_)}).Count){throw 'Invalid sample sequence/clock/numeric value.'}
        $phase=$m.Groups[1].Value;$begin=switch($phase){'F0'{$placements[0].Index}'F1'{$placements[1].Index}'F2'{$events[6].Index}}
        $end=switch($phase){'F0'{$events[2].Index}'F1'{$events[5].Index}'F2'{$events[7].Index}}
        if($m.Index -le $begin -or $m.Index -ge $end -or [math]::Abs($v[0]-$Plan.Anchor[0]) -gt 64 -or [math]::Abs($v[1]-$Plan.Anchor[1]) -gt 64){throw 'Sample escaped its contact interval/patch.'}
        $row=[pscustomobject]@{Phase=$phase;Id=$id;Tick=$t;Game=$g;Position=@($v[0..2]);Velocity=@($v[3..5]);Ground=($m.Groups[11].Value -ceq '1');Offset=$m.Index}
        if($lastSample -and $lastSample.Phase -ceq $phase){
            $dt=($t-$lastSample.Tick)/1000.0;if($dt -gt 0.25){throw 'Movement observation gap.'}
            foreach($axis in 0..2){$limit=[math]::Max([math]::Abs($row.Velocity[$axis]),[math]::Abs($lastSample.Velocity[$axis]))*$dt+8
                if([math]::Abs($row.Position[$axis]-$lastSample.Position[$axis]) -gt $limit){throw 'Unexplained position jump inside measurement.'}}
        }
        $seq=$id;$tick=$t;$game=$g;$lastSample=$row;$samples+=,$row
    }
    $top=$Plan.Maximum[2];$groundZ=$Plan.Anchor[2];$phases=@{}
    foreach($phase in @('F0','F1','F2')){$rows=@($samples|Where-Object Phase -CEQ $phase);if($rows.Count -lt 6){throw 'Insufficient real player observations.'};$phases[$phase]=$rows}
    if(($samples[-1].Game-$samples[0].Game) -gt 25000){throw 'Measured player deadline exceeded.'}
    foreach($phase in @('F0','F2')){
        $rows=$phases[$phase];$stable=Get-IW7CollisionPlayerStableStart $rows {param($r) $r.Ground -and [math]::Abs($r.Position[2]-$groundZ) -le 4 -and [math]::Abs($r.Velocity[2]) -le 1}
        if(!@($rows|Where-Object{$_.Position[2] -lt $top-8 -and $_.Velocity[2] -lt -8}).Count -or $null -eq $stable -or
            $rows[-1].Tick-$stable -lt 250 -or
            ($phase -ceq 'F0' -and $rows[0].Position[2] -le $top+16) -or ($phase -ceq 'F2' -and $rows[0].Position[2] -lt $top-4)){throw 'Absent/removed ordinary fall and stable lower landing not proven.'}
    }
    $contact=@($phases.F1|Where-Object Offset -LT $events[4].Index)
    $stable=Get-IW7CollisionPlayerStableStart $contact {param($r) $r.Ground -and [math]::Abs($r.Position[2]-$top) -le 4 -and [math]::Abs($r.Velocity[2]) -le 1}
    $walking=@($phases.F1|Where-Object Offset -GT $events[4].Index)
    if(!@($phases.F1|Where-Object{$_.Velocity[2] -lt -8}).Count -or $contact.Count -lt 2 -or $null -eq $stable -or $contact[-1].Tick-$stable -lt 600 -or $walking.Count -lt 2){throw 'Present landing/standing not proven.'}
    $base=$contact[-1].Position;$moved=$false
    foreach($row in $walking){$d=[math]::Sqrt([math]::Pow($row.Position[0]-$base[0],2)+[math]::Pow($row.Position[1]-$base[1],2))
        if(!$row.Ground -or [math]::Abs($row.Position[2]-$top) -gt 4 -or $d -gt 64){throw 'Standing contact lost during movement.'};if($d -ge 4){$moved=$true}}
    $stable=Get-IW7CollisionPlayerStableStart $walking {param($r) @($r.Velocity|Where-Object{[math]::Abs($_) -gt 1}).Count -eq 0}
    if(!$moved -or $null -eq $stable -or $walking[-1].Tick-$stable -lt 250){throw 'Real bounded movement and released-input stability not proven.'}
    $native=Read-IW7CollisionPlayerNative $text ([uint32]$events[3].Groups[1].Value) $events[2].Index $events[3].Index $events[5].Index $events[6].Index
    [pscustomobject]@{Complete=$true;ServerPlayerContactVerified=$true;PostRemovalPlayerFallVerified=$true;Samples=$samples;Native=$native;
        ClientPredictionVerified=$false;ActorShapeQualified=$false;StaticSensorBehaviorQualified=$false;PhysicsWorldResetVerified=$false;OwnerAccepted=$false}
}
