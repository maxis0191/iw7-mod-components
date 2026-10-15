$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
# Reuse the frozen reader's causal physics fixture; no second physics simulator.
. "$PSScriptRoot/collision_player_result_test.ps1"
. "$PSScriptRoot/../../ops/Author-Platform.Core.ps1"
$plan=New-IW7AuthorPlatformPlan @(0,0,0) $token
function Visual([string]$Phase,[int]$Uses,[int]$Game){"[Author contact] VISUAL token=$token phase=$Phase entity=710 instance=900 uses=$Uses x=0 y=0 z=96 angles=0,0,0 scale=1 game_ms=$Game"}
$sdkScene="[SDK author platform] SCENE_READY; token=$token; entity=710; instance=900; uses=0; physics_unverified=1; runtime_ready=0."
$sdkUse="[SDK author platform] USED; token=$token; entity=710; instance=900; uses=1; retail_trigger=1; runtime_ready=0."
$arm="[Author contact] USE_ARMED token=$token entity=710 instance=900 released=1 stable_ms=300 game_ms=3600"
$edge="[Author contact] USE_EDGE token=$token entity=710 instance=900 sequence=1 from_ms=3600 game_ms=3650"
$ack="[Author contact] USE_ACK token=$token entity=710 instance=900 uses=1 retail_trigger=1 game_ms=3650"
$sdkRemoved="[SDK author platform] VISUAL_REMOVED; token=$token; uses=1; runtime_ready=0."
$removed="[Author contact] VISUAL_REMOVED token=$token uses=1"
$author=$text.Replace("[Collision player] READY token=$token`n","[Collision player] READY token=$token`n$sdkScene`n$(Visual prepared 0 1000)`n")
$author=$author.Replace("[Collision player] PLACED token=$token phase=F0", "$(Visual F0 0 1000)`n[Collision player] PLACED token=$token phase=F0")
$author=$author.Replace("[Collision player] READY_F1 token=$token", "$(Visual F1 0 3000)`n[Collision player] READY_F1 token=$token")
$author=$author.Replace("[Collision player] MOVED token=$token", "$arm`n$edge`n$sdkUse`n$ack`n[Collision player] MOVED token=$token")
$author=$author.Replace("[Collision player] REMOVED token=$token owner_alive=1`n", "[Collision player] REMOVED token=$token owner_alive=1`n$(Visual F2 1 3650)`n")
$author=$author.Replace("[Collision player] DONE token=$token", "$(Visual after_fall 1 4600)`n$sdkRemoved`n$removed`n[Collision player] DONE token=$token")
function Read-Author([string]$Value){Read-IW7AuthorPlatformResult -Text $Value -Plan $plan -ServerId 42 -ClientNonce $nonce -Generation $gen -NotBeforeTick 1000 -NowTick 10000}
$r=Read-Author $author
if(!$r.Complete -or !$r.RetailTriggerObservedVerified -or !$r.VisualEntityStableVerified -or $r.RetailUseCount -ne 1 -or
    !$r.Physics.ServerPlayerContactVerified -or $r.RendererVerified -or $r.RenderBoundsQualified -or $r.ClientPredictionVerified -or $r.OwnerAccepted -or $r.LifecycleClosed){throw 'Author positive or qualification boundary failed.'}
# SDK trigger may run immediately before the fixture observes the same edge.
if(!(Read-Author ($author.Replace("$edge`n$sdkUse", "$sdkUse`n$edge"))).Complete){throw 'Same-frame actual retail trigger order was overconstrained.'}
$pendingCases=@($author.TrimEnd("`n"),($author+"[Author contact] USE_EDGE token=$token"),($author+"[Collision player] FAIL token=$token reason=late"))
foreach($partial in $pendingCases){
    if((Read-Author $partial).Complete){throw 'Partial latest owned publication accepted.'}
}
$bad=@(
    $author.Replace($sdkUse,''),
    $author.Replace($sdkUse,"$sdkUse`n$sdkUse"),
    $author.Replace($edge,"$edge`n$edge"),
    $author.Replace('phase=F1 entity=710','phase=F1 entity=711'),
    $author.Replace('phase=F2 entity=710 instance=900','phase=F2 entity=710 instance=901'),
    $author.Replace('phase=F0 entity=710 instance=900 uses=0','phase=F0 entity=710 instance=900 uses=1'),
    $author.Replace('phase=after_fall entity=710 instance=900 uses=1','phase=after_fall entity=710 instance=900 uses=0'),
    $author.Replace('z=96 angles=0,0,0','z=95 angles=0,0,0'),
    $author.Replace('angles=0,0,0','angles=0,90,0'),
    $author.Replace('scale=1','scale=2'),
    $author.Replace('stable_ms=300','stable_ms=249'),
    $author.Replace('released=1','released=0'),
    $author.Replace('from_ms=3600','from_ms=3599'),
    $author.Replace('from_ms=3600 game_ms=3650','from_ms=3600 game_ms=3900'),
    $author.Replace($ack,$ack.Replace('game_ms=3650','game_ms=3600')),
    $author.Replace($ack,$ack.Replace('game_ms=3650','game_ms=3751')),
    $author.Replace("$arm`n$edge`n$sdkUse`n$ack", "$arm`n$edge`n$ack`n$sdkUse"),
    $author.Replace($sdkRemoved,'').Replace($sdkScene,"$sdkScene`n$sdkRemoved"),
    $author.Replace('entity=710','entity=709'),
    $author.Replace($arm,'').Replace("[Collision player] READY_F1 token=$token","$arm`n[Collision player] READY_F1 token=$token"),
    ($author+"[SDK author platform] USED; token=$token; uses=2`n"),
    ($author+"[SDK author platform] RESTORE_PENDING; reason=ownership_changed; runtime_ready=0.`n")
)
$reject=0
foreach($case in $bad){if($case -ceq $author){throw 'Causal Author mutation changed nothing.'};try{$null=Read-Author $case}catch{$reject++;continue};throw 'Invalid Author lifecycle/trigger transcript accepted.'}
foreach($field in @('VisualOrigin','VisualAngles','ModelLocalMaximum','FsGame','VisualScale','RetailUseCount')){
    $old=$plan.$field
    $plan.$field=switch($field){'VisualOrigin'{@(0,0,95)} 'VisualAngles'{@(0,90,0)} 'ModelLocalMaximum'{@(128,128,17)} 'FsGame'{'mods/other'} default{2}}
    try{$null=Read-Author $author}catch{$reject++;$plan.$field=$old;continue};throw 'Changed canonical Author plan accepted.'
}
Write-Output "PASS Author pure transcript: two causal positives, $reject refusals, three pending tails; no engine/render/Game qualification."
