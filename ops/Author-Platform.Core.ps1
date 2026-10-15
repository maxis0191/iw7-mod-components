# Project-specific Source adapter. The unchanged a572 reader owns physics proof.
. "$PSScriptRoot/Collision-Player.Core.ps1"

function Get-IW7AuthorPlatformSDKContract {
    [pscustomobject]@{Product='iw7-creator-sdk';Revision='6dcfc719e0535509f109c593fa4342ce201b5523';
        Script='sdk/modding/examples/original-authoring/platform-contact/sdk_author_platform.gsc';
        Bytes=5404;SHA256='3B6F34FDF6F5176BECEFC5294B992E658751921F5B07931E28A31D05634EFD25';
        DeployedScript='iw7-mod/custom_scripts/cp/sdk_author_platform.gsc'}
}

function Assert-IW7AuthorPlatformSDKSource($Receipt,[string]$Root) {
    $c=Get-IW7AuthorPlatformSDKContract
    if($Receipt.product -isnot [string] -or $Receipt.revisions.($c.Product) -isnot [string] -or
        $Receipt.product -cne $c.Product -or $Receipt.revisions.($c.Product) -cne $c.Revision){throw 'Reviewed Author SDK Source revision required.'}
    $entry=@($Receipt.files|Where-Object path -CEQ $c.Script)
    if($entry.Count -ne 1 -or $entry[0].path -isnot [string] -or
        ($entry[0].bytes -isnot [long] -and $entry[0].bytes -isnot [int]) -or $entry[0].sha256 -isnot [string] -or
        $entry[0].bytes -ne $c.Bytes -or $entry[0].sha256 -ine $c.SHA256){throw 'Author SDK script is missing or differs from the reviewed contract.'}
    $path=Resolve-IW7BasePath $Root $c.Script
    if((Get-Item -LiteralPath $path).Length -ne $c.Bytes -or (Get-FileHash -LiteralPath $path).Hash -cne $c.SHA256){throw 'Author SDK Source bytes changed.'}
}

function New-IW7AuthorPlatformPlan([double[]]$Anchor,[string]$Token,[ValidateSet('Contact','DisplayOnly',IgnoreCase=$false)][string]$Phase='Contact') {
    $p=New-IW7CollisionPlayerPlan $Anchor $Token
    $p.Schema='iw7.author-platform-plan/1'
    $p.Config+="set paris_author_platform_contact 1`nset sdk_author_platform_enable 1`nset fs_game mods/sdk_author_platform`n"
    $p.Config+="set paris_author_platform_display_only $(if($Phase -ceq 'DisplayOnly'){1}else{0})`n"
    $p|Add-Member Phase $Phase
    $p|Add-Member VisualOrigin @($Anchor[0],$Anchor[1],($Anchor[2]+96))
    $p|Add-Member VisualAngles @(0,0,0)
    $p|Add-Member VisualScale 1
    $p|Add-Member ModelLocalMinimum @(-128,-128,0)
    $p|Add-Member ModelLocalMaximum @(128,128,16)
    $p|Add-Member FsGame 'mods/sdk_author_platform'
    $p|Add-Member Model 'sdk_author_platform_model'
    $p|Add-Member SDKScript 'custom_scripts/cp/sdk_author_platform.gsc'
    $p|Add-Member RetailUseCount 1
    $p|Add-Member SDKContract (Get-IW7AuthorPlatformSDKContract)
    $p|Add-Member RendererVerified $false
    $p|Add-Member RenderBoundsQualified $false
    $p
}

function Read-IW7AuthorDisplayReady {
    param([string]$Text,[string]$Token,[int]$ServerId,[string]$ClientNonce,[long]$NotBeforeTick,[long]$NowTick)
    if($Text.Length -gt 16MB -or $Token -cnotmatch '^[a-f0-9]{32}$' -or $ServerId -le 0 -or
        $ClientNonce -cnotmatch '^[a-f0-9]{32}$' -or $NowTick -lt $NotBeforeTick){throw 'Bounded launch-owned display transcript required.'}
    $raw=$Text
    $last=$Text.LastIndexOf("`n")
    if($last -lt 0){return [pscustomobject]@{Ready=$false}}
    $tail=$Text.Substring($last+1);$text=$Text.Substring(0,$last+1)
    if($tail -cmatch '^\[SDK author platform\] RESTORE_PENDING(?=;|\r?$)' -or
        $tail.StartsWith('[Author display] READY token='+$Token,[StringComparison]::Ordinal) -or
        ($tail.StartsWith('[SDK author platform] ',[StringComparison]::Ordinal) -and $tail.Contains('token='+$Token)) -or
        ($tail.StartsWith('[Author contact] USE_',[StringComparison]::Ordinal) -and $tail.Contains('token='+$Token))){
        return [pscustomobject]@{Ready=$false;Pending='Latest display/SDK publication is not terminated.'}
    }
    if($text -cmatch '(?m)^\[SDK author platform\] RESTORE_PENDING(?=;|\r?$)' -or
        $text -cmatch ('(?m)^\[SDK author platform\] (?:USED|VISUAL_REMOVED); token='+$Token+';') -or
        $text -cmatch ('(?m)^\[Collision player\] (?:AUDIT|PLACED|SAMPLE|F0_CLEAR|CREATED|READY_F1|MOVED|REMOVED|OWNER_DELETED|DONE) token='+$Token+'\b') -or
        $text -cmatch '(?m)^\[Collision provider\] created ' -or
        $text -cmatch ('(?m)^\[Author contact\] USE_(?:ARMED|EDGE|ACK) token='+$Token+'\b')){throw 'Display-only episode ran contact/Use or lost visual ownership.'}
    $pose=Read-IW7CollisionPlayerReady $raw $Token $ServerId $ClientNonce $NotBeforeTick $NowTick
    if(!$pose.Ready){return [pscustomobject]@{Ready=$false}}
    $n='([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)';$culture=[Globalization.CultureInfo]::InvariantCulture
    $prefix='(?m)^\[Author display\] READY token='+$Token
    $rows=[regex]::Matches($text,$prefix+'; server_pid='+$ServerId+'; client_nonce='+$ClientNonce+
        '; server_generation=([a-f0-9]{32}); slot=0; native_tick_ms=(\d+); protected=1; anchor_x='+$n+'; anchor_y='+$n+'; anchor_z='+$n+
        '; entity=(\d+); instance=(\d+); x='+$n+'; y='+$n+'; z='+$n+'; angles=0,0,0; scale=1; uses=0; sdk_armed=0; collision_arm=0[\t ]*\r?$')
    if($rows.Count -ne [regex]::Matches($text,$prefix+'\b[^\r\n]*\r?$').Count){throw 'Malformed/foreign display publication.'}
    if(!$rows.Count){return [pscustomobject]@{Ready=$false}}
    $entity=$null;$instance=$null;$tick=-1L
    foreach($r in $rows){
        $anchor=@(3..5|ForEach-Object{[double]::Parse($r.Groups[$_].Value,$culture)})
        $p=New-IW7AuthorPlatformPlan $anchor $Token 'DisplayOnly'
        $e=[int]::Parse($r.Groups[6].Value,$culture);$i=[long]::Parse($r.Groups[7].Value,$culture);$t=[long]::Parse($r.Groups[2].Value,$culture)
        if($null -eq $entity){$entity=$e;$instance=$i}
        if($r.Groups[1].Value -cne $pose.Generation -or ($anchor -join ',') -cne ($pose.Anchor -join ',') -or
            $e -gt 2047 -or $e -ne $entity -or $i -ne $instance -or $t -le $tick -or $t -gt $NowTick){throw 'Display identity, frozen P or native clock changed.'}
        foreach($axis in 0..2){$v=[double]::Parse($r.Groups[8+$axis].Value,$culture)
            if(![double]::IsFinite($v) -or [math]::Abs($v-$p.VisualOrigin[$axis]) -gt 0.001){throw 'Display visual transform changed.'}}
        $tick=$t
    }
    if($tick -lt $NotBeforeTick -or $NowTick-$tick -gt 500 -or $tick -ne $pose.Tick){return [pscustomobject]@{Ready=$false}}
    if([regex]::Matches($text,'(?m)^\[SDK author platform\] SCENE_READY; token='+$Token+';[^\r\n]*\r?$').Count -ne 1){throw 'One SDK visual instance is required.'}
    $null=Get-IW7CollisionPlayerOne $text ('(?m)^\[SDK author platform\] SCENE_READY; token='+$Token+'; entity='+$entity+'; instance='+$instance+'; uses=0; physics_unverified=1; runtime_ready=0\.[\t ]*\r?$')
    [pscustomobject]@{Ready=$true;Generation=$pose.Generation;Tick=$tick;Anchor=$pose.Anchor;Entity=$entity;Instance=$instance;CollisionArm=0;SDKUses=0}
}

function New-IW7AuthorDisplayResult($Before,$After,$CaptureInput,$CaptureRows,[long]$CaptureStartedTick,[long]$CaptureCompletedTick) {
    Assert-IW7CollisionPlayerFrozenReady $Before $After
    if($Before.Entity -ne $After.Entity -or $Before.Instance -ne $After.Instance -or $Before.Tick -gt $CaptureStartedTick -or
        $CaptureCompletedTick -lt $CaptureStartedTick -or $After.Tick -lt $CaptureCompletedTick -or
        $Before.CollisionArm -ne 0 -or $After.CollisionArm -ne 0 -or $Before.SDKUses -ne 0 -or $After.SDKUses -ne 0 -or
        $CaptureInput.Passed -isnot [bool] -or !$CaptureInput.Passed -or $CaptureInput.Name -cne 'author-platform-display' -or $CaptureInput.GameplayAssertions -ne 0){throw 'Display capture is not bracketed by the same unarmed protected visual.'}
    $captures=@($CaptureRows|Where-Object type -CEQ 'capture')
    $done=@($CaptureRows|Where-Object type -CEQ 'complete')
    $starts=@($CaptureRows|Where-Object type -CEQ 'step_start');$steps=@($CaptureRows|Where-Object type -CEQ 'step_complete')
    $types=@($CaptureRows|ForEach-Object {$_.type}|Where-Object {$_ -cne 'scenario'})
    if(($types -join ',') -cne 'step_start,capture,step_complete,released,complete' -or
        $captures.Count -ne 1 -or $captures[0].id -cne 'display-original-frame' -or $captures[0].sha256 -cnotmatch '^[a-fA-F0-9]{64}$' -or
        ![IO.Path]::IsPathFullyQualified($captures[0].path) -or [IO.Path]::GetExtension($captures[0].path) -cne '.bmp' -or
        $starts.Count -ne 1 -or $starts[0].id -cne 'display-original-frame' -or $starts[0].action -cne 'capture' -or
        $steps.Count -ne 1 -or $steps[0].id -cne 'display-original-frame' -or $steps[0].action -cne 'capture' -or $steps[0].witness -cne 'native_frame' -or
        @($CaptureRows|Where-Object type -CEQ 'released').Count -ne 1 -or
        $done.Count -ne 1 -or $done[0].passed -isnot [bool] -or !$done[0].passed -or
        @($CaptureRows|Where-Object{$_.type -cin @('failure','cleanup_gap')}).Count){throw 'One fresh original native capture and normal input release are required.'}
    [pscustomobject]@{Schema='iw7.author-platform-display/1';Phase='DisplayOnly';DisplayEpisodeExecuted=$true;ContactNotRun=$true;
        Before=$Before;After=$After;OriginalCapture=$captures[0];Input=$CaptureInput;PixelsVerified=$false;RenderedBoundsVerified=$false;
        ClientPredictionVerified=$false;LifecycleClosed=$false;LeaseReleased=$false;OriginalHostExitObserved=$false;OwnerAccepted=$false;MainDeployed=$false;
        Meaning='Original native frame recorded; pixels require inspection. Contact was not run. Original caller still owns normal close/restore.'}
}

function Read-IW7AuthorPlatformResult {
    param([string]$Text,$Plan,[int]$ServerId,[string]$ClientNonce,[string]$Generation,[long]$NotBeforeTick,[long]$NowTick)
    if($Text.Length -gt 16MB){throw 'Bounded Author transcript required.'}
    $canonical=New-IW7AuthorPlatformPlan $Plan.Anchor $Plan.Token
    foreach($field in @('VisualOrigin','VisualAngles','ModelLocalMinimum','ModelLocalMaximum')){
        if(($Plan.$field -join ',') -cne ($canonical.$field -join ',')){throw 'Author geometry differs from the frozen P contract.'}
    }
    if($Plan.FsGame -cne $canonical.FsGame -or $Plan.Model -cne $canonical.Model -or $Plan.VisualScale -ne 1 -or $Plan.RetailUseCount -ne 1){throw 'Author scope changed.'}
    $physics=Read-IW7CollisionPlayerResult @PSBoundParameters
    if(!$physics.Complete){return [pscustomobject]@{Complete=$false}}
    $last=$Text.LastIndexOf("`n");$tail=$Text.Substring($last+1);$token=$Plan.Token
    # SDK's ownership-loss row intentionally has no token. Never reuse a prior
    # completion while that latest restoration status is still being written.
    if($tail -cmatch '^\[SDK author platform\] RESTORE_PENDING(?=;|\r?$)'){
        return [pscustomobject]@{Complete=$false;Pending='Unterminated SDK restoration status.'}
    }
    foreach($prefix in @('[Author contact] ','[SDK author platform] ','[Collision player] ')){
        if($tail.StartsWith($prefix,[StringComparison]::Ordinal) -and $tail.Contains('token='+$token)){
            return [pscustomobject]@{Complete=$false;Pending='Unterminated latest owned row.'}
        }
    }
    $text=$Text.Substring(0,$last+1)
    if($text -cmatch '(?m)^\[SDK author platform\] RESTORE_PENDING(?=;|\r?$)'){throw 'SDK visual ownership/restoration is pending.'}
    $n='([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)'
    $culture=[Globalization.CultureInfo]::InvariantCulture
    $visual=@();$entity=$null;$instance=$null;$previous=-1;$previousGame=-1L
    foreach($phase in @('prepared','F0','F1','F2','after_fall')){
        $m=Get-IW7CollisionPlayerOne $text ('(?m)^\[Author contact\] VISUAL token='+$token+' phase='+$phase+
            ' entity=(\d+) instance=(\d+) uses=([01]) x='+$n+' y='+$n+' z='+$n+' angles=0,0,0 scale=1 game_ms=(\d+)[\t ]*\r?$')
        $e=[int]::Parse($m.Groups[1].Value,$culture);$i=[long]::Parse($m.Groups[2].Value,$culture);$g=[long]::Parse($m.Groups[7].Value,$culture)
        if($null -eq $entity){$entity=$e;$instance=$i}
        $expectedCount=if($phase -in @('F2','after_fall')){'1'}else{'0'}
        if($e -ne $entity -or $i -ne $instance -or $m.Groups[3].Value -cne $expectedCount -or $m.Index -le $previous -or $g -lt $previousGame){throw 'Visual identity, count or chronology changed.'}
        foreach($axis in 0..2){$v=[double]::Parse($m.Groups[4+$axis].Value,$culture)
            if(![double]::IsFinite($v) -or [math]::Abs($v-$canonical.VisualOrigin[$axis]) -gt 0.001){throw 'Visual entity transform changed.'}}
        $visual+=,$m;$previous=$m.Index;$previousGame=$g
    }
    $id=' entity='+$entity+' instance='+$instance
    $arm=Get-IW7CollisionPlayerOne $text ('(?m)^\[Author contact\] USE_ARMED token='+$token+$id+' released=1 stable_ms=(\d+) game_ms=(\d+)[\t ]*\r?$')
    $edge=Get-IW7CollisionPlayerOne $text ('(?m)^\[Author contact\] USE_EDGE token='+$token+$id+' sequence=1 from_ms=(\d+) game_ms=(\d+)[\t ]*\r?$')
    $ack=Get-IW7CollisionPlayerOne $text ('(?m)^\[Author contact\] USE_ACK token='+$token+$id+' uses=1 retail_trigger=1 game_ms=(\d+)[\t ]*\r?$')
    $scene=Get-IW7CollisionPlayerOne $text ('(?m)^\[SDK author platform\] SCENE_READY; token='+$token+'; entity='+$entity+'; instance='+$instance+'; uses=0; physics_unverified=1; runtime_ready=0\.[\t ]*\r?$')
    $used=Get-IW7CollisionPlayerOne $text ('(?m)^\[SDK author platform\] USED; token='+$token+'; entity='+$entity+'; instance='+$instance+'; uses=1; retail_trigger=1; runtime_ready=0\.[\t ]*\r?$')
    $sdkRemoved=Get-IW7CollisionPlayerOne $text ('(?m)^\[SDK author platform\] VISUAL_REMOVED; token='+$token+'; uses=1; runtime_ready=0\.[\t ]*\r?$')
    $removed=Get-IW7CollisionPlayerOne $text ('(?m)^\[Author contact\] VISUAL_REMOVED token='+$token+' uses=1[\t ]*\r?$')
    $ownAuthor=[regex]::Matches($text,'(?m)^\[Author contact\] [^\r\n]*\btoken='+$token+'\b[^\r\n]*\r?$')
    $ownSdk=[regex]::Matches($text,'(?m)^\[SDK author platform\] [^\r\n]*\btoken='+$token+'\b[^\r\n]*\r?$')
    if($ownAuthor.Count -ne 9 -or $ownSdk.Count -ne 3){throw 'Additional, repeated or malformed owned Author/SDK row.'}
    $armGame=[long]$arm.Groups[2].Value;$edgeFrom=[long]$edge.Groups[1].Value;$edgeGame=[long]$edge.Groups[2].Value;$useGame=[long]$ack.Groups[1].Value
    if([long]$arm.Groups[1].Value -lt 250 -or $edgeFrom -lt $armGame -or $edgeGame -lt $edgeFrom -or $edgeGame-$edgeFrom -gt 250 -or
        $useGame -le $armGame -or $useGame -lt $edgeFrom -or $useGame -gt $edgeGame+100){throw 'Retail trigger is outside the one observed Use edge.'}
    $f0Place=Get-IW7CollisionPlayerOne $text ('(?m)^\[Collision player\] PLACED token='+$token+' phase=F0 [^\r\n]*\r?$')
    $f1Ready=Get-IW7CollisionPlayerOne $text ('(?m)^\[Collision player\] READY_F1 token='+$token+'[\t ]*\r?$')
    $moved=Get-IW7CollisionPlayerOne $text ('(?m)^\[Collision player\] MOVED token='+$token+'[\t ]*\r?$')
    $bodyRemoved=Get-IW7CollisionPlayerOne $text ('(?m)^\[Collision player\] REMOVED token='+$token+' owner_alive=1[\t ]*\r?$')
    $ownerDeleted=Get-IW7CollisionPlayerOne $text ('(?m)^\[Collision player\] OWNER_DELETED token='+$token+'[\t ]*\r?$')
    $done=Get-IW7CollisionPlayerOne $text ('(?m)^\[Collision player\] DONE token='+$token+'[\t ]*\r?$')
    if($entity -eq $physics.Native.Entity -or $scene.Index -ge $visual[0].Index -or $visual[1].Index -ge $f0Place.Index -or
        $visual[2].Index -ge $f1Ready.Index -or $arm.Index -le $f1Ready.Index -or $edge.Index -le $arm.Index -or
        $used.Index -le $arm.Index -or $used.Index -ge $ack.Index -or $ack.Index -le $edge.Index -or $ack.Index -ge $moved.Index -or
        $visual[3].Index -le $bodyRemoved.Index -or $visual[4].Index -le $ownerDeleted.Index -or
        $sdkRemoved.Index -le $visual[4].Index -or $removed.Index -le $sdkRemoved.Index -or $removed.Index -ge $done.Index){throw 'Author lifecycle/physics/retail Use ordering differs.'}
    # Require the frozen movement proof before the SDK is armed, not afterwards.
    $beforeArm=@($physics.Samples|Where-Object{$_.Phase -ceq 'F1' -and $_.Offset -gt $f1Ready.Index -and $_.Offset -lt $arm.Index})
    $contact=@($physics.Samples|Where-Object{$_.Phase -ceq 'F1' -and $_.Offset -lt $f1Ready.Index})
    $base=$contact[-1].Position
    $movedBeforeArm=@($beforeArm|Where-Object{
        [math]::Sqrt([math]::Pow($_.Position[0]-$base[0],2)+[math]::Pow($_.Position[1]-$base[1],2)) -ge 4
    }).Count -gt 0
    $stable=Get-IW7CollisionPlayerStableStart $beforeArm {param($r) @($r.Velocity|Where-Object{[math]::Abs($_) -gt 1}).Count -eq 0}
    if(!$movedBeforeArm -or $beforeArm.Count -lt 2 -or $null -eq $stable -or $beforeArm[-1].Tick-$stable -lt 250 -or
        $armGame -lt $beforeArm[-1].Game -or $edgeGame -lt $visual[2].Groups[7].Value -or $useGame -gt [long]$visual[3].Groups[7].Value){throw 'SDK Use arm preceded released stable movement.'}
    [pscustomobject]@{Complete=$true;Physics=$physics;VisualEntity=$entity;VisualInstance=$instance;VisualEntityStableVerified=$true;
        RetailTriggerObservedVerified=$true;ObservedUseEdges=1;RetailUseCount=1;RendererVerified=$false;RenderBoundsQualified=$false;
        ClientPredictionVerified=$false;OwnerAccepted=$false;LifecycleClosed=$false}
}
