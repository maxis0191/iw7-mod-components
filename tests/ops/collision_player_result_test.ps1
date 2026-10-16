$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. "$PSScriptRoot/../../ops/Collision-Player.Core.ps1"
$token='1234567890abcdef1234567890abcdef';$nonce='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';$gen='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
$plan=New-IW7CollisionPlayerPlan @(0,0,0) $token
$lines=[Collections.Generic.List[string]]::new();$state=@{Seq=0;Tick=1000}
function Add-Row([string]$Line){$lines.Add($Line)}
function Sample([string]$Phase,[double]$X,[double]$Z,[double]$Vx,[double]$Vz,[int]$Ground){
    $state.Seq++;$state.Tick+=100
    Add-Row "[Collision player] SAMPLE token=$token phase=$Phase sample=$($state.Seq); server_pid=42; client_nonce=$nonce; server_generation=$gen; slot=0; native_tick_ms=$($state.Tick); protected=1; game_ms=$($state.Tick); x=$X; y=0; z=$Z; vx=$Vx; vy=0; vz=$Vz; ground=$Ground"
}
function Usage([string]$Phase,[int]$Count){$id=if($Phase -ceq 'before_create'){'4294967295'}else{'7'};Add-Row "[Collision provider] template_usage phase=$Phase world=0 entity=709 instance=$id epoch=1 server=$Count client=0 dyn=0"}
function Query([string]$Phase,[string]$Kind){
    $label=if($Phase -ceq 'before'){'4294967295'}else{'7'};$suffix=if($Phase -ceq 'inside'){''}else{'_'+$Phase}
    $fraction=if($Phase -ceq 'inside'){if($Kind -ceq 'point'){'0.5'}else{'0.731249869'}}else{'1'}
    $normal=if($Phase -ceq 'inside'){'0,0,1'}else{'0,0,0'};$contents=if($Phase -ceq 'inside'){'1'}else{'0'}
    Add-Row "[Collision provider] engine_query=$($Kind)_floor$suffix world=0 instance=$label fraction=$fraction normal=$normal contents=$contents hitType=1 hitId=2046 startsolid=0 allsolid=0"
}
Add-Row "[Collision player] READY token=$token"
Add-Row "[Collision player] AUDIT token=$token x=0 y=0 z=0 ground_points=5 vertical_clear=5"
Add-Row "[Collision player] PLACED token=$token phase=F0 x=0 y=0 z=208"
Sample F0 0 208 0 0 0
foreach($z in @(168,128,88,48,8)){Sample F0 0 $z 0 -400 0}
foreach($i in 1..4){Sample F0 0 0 0 0 1}
Add-Row "[Collision player] F0_CLEAR token=$token"
Usage before_create 0
Query before point;Query before actor
Usage after_native_create 0;Usage after_manual_increment 1
Add-Row '[Collision provider] created world=0 entity=709 instance=7 original_vertices=8 contents=1 template=physicsvolumedummy'
Add-Row "[Collision player] CREATED token=$token instance=7"
Query inside point;Query inside actor
Add-Row "[Collision player] PLACED token=$token phase=F1 x=0 y=0 z=208"
Sample F1 0 208 0 0 0;Sample F1 0 168 0 -400 0;Sample F1 0 128 0 -400 0
foreach($i in 1..7){Sample F1 0 112 0 0 1}
Add-Row "[Collision player] READY_F1 token=$token"
Sample F1 5 112 50 0 1;Sample F1 10 112 50 0 1
foreach($i in 1..4){Sample F1 10 112 0 0 1}
Add-Row "[Collision player] MOVED token=$token"
Usage before_native_destroy 1;Usage after_native_destroy 1;Usage after_manual_decrement 0
Add-Row '[Collision provider] template_usage_result world=0 entity=709 instance=7 epoch=1 restored=1'
Add-Row '[Collision provider] destroyed world=0 entity=709 instance=7'
Query removed point;Query removed actor
Add-Row "[Collision player] REMOVED token=$token owner_alive=1"
Sample F2 10 112 0 0 0
foreach($z in @(92,72,52,32,12)){Sample F2 10 $z 0 -200 0}
foreach($i in 1..4){Sample F2 10 0 0 0 1}
Add-Row "[Collision player] OWNER_DELETED token=$token"
Add-Row "[Collision player] DONE token=$token"
$text=($lines -join "`n")+"`n"
function Read-Case([string]$Value){Read-IW7CollisionPlayerResult -Text $Value -Plan $plan -ServerId 42 -ClientNonce $nonce -Generation $gen -NotBeforeTick 1000 -NowTick 10000}
$r=Read-Case $text
if(!$r.Complete -or !$r.ServerPlayerContactVerified -or !$r.PostRemovalPlayerFallVerified -or $r.ClientPredictionVerified -or $r.PhysicsWorldResetVerified -or $r.ActorShapeQualified -or $r.OwnerAccepted){throw 'Narrow valid movement case failed.'}
if((Read-Case $text.TrimEnd("`n")).Complete -or (Read-Case ($text.Replace("DONE token=$token","DONE token=cccccccccccccccccccccccccccccccc"))).Complete){throw 'Partial/foreign completion accepted.'}
# Native point/actor controls and a DONE marker cannot replace real player data.
$nativeOnly=[regex]::Replace($text,'(?m)^\[Collision player\] SAMPLE [^\r\n]*\r?\n','')
$retained='(?m)^\[(?:Collision provider|Collision player)\] (?!SAMPLE )[^\r\n]*\r?$'
if($nativeOnly -ceq $text -or $nativeOnly -match '(?m)^\[Collision player\] SAMPLE ' -or
    [regex]::Matches($nativeOnly,'(?m)^\[Collision provider\] engine_query=').Count -ne 6 -or
    [regex]::Matches($nativeOnly,'(?m)^\[Collision provider\] template_usage phase=').Count -ne 6 -or
    ([regex]::Matches($nativeOnly,$retained).Value -join "`n") -cne ([regex]::Matches($text,$retained).Value -join "`n")){
    throw 'Native-only causal case must remove only SAMPLE rows and preserve all native controls/counts/phase markers.'
}
$nativeOnlyRefused=$false
try{$nativeOnlyResult=Read-Case $nativeOnly}catch{
    if($_.Exception.Message -cne 'Insufficient real player observations.'){throw}
    $nativeOnlyRefused=$true
}
if(!$nativeOnlyRefused){throw 'Native point/actor success without player SAMPLE rows qualified contact.'}
$bad=@(
    $text.Replace("AUDIT token=$token x=0","AUDIT token=$token x=1"),
    $text.Replace("client_nonce=$nonce","client_nonce=cccccccccccccccccccccccccccccccc"),
    $text.Replace('protected=1; game_ms=','protected=0; game_ms='),
    $text.Replace('native_tick_ms=1100','native_tick_ms=999'),
    $text.Replace('sample=2;','sample=1;'),
    $text.Replace('x=10; y=0; z=112','x=90; y=0; z=112'),
    $text.Replace('vx=50; vy=0; vz=0','vx=0; vy=0; vz=0').Replace('x=5; y=0; z=112','x=0; y=0; z=112').Replace('x=10; y=0; z=112','x=0; y=0; z=112'),
    $text.Replace('phase=F2','phase=F1'),
    $text.Replace('engine_query=actor_floor_removed world=0 instance=7 fraction=1','engine_query=actor_floor_removed world=0 instance=7 fraction=0.9'),
    $text.Replace('after_manual_decrement world=0 entity=709 instance=7 epoch=1 server=0','after_manual_decrement world=0 entity=709 instance=7 epoch=1 server=1'),
    $text.Replace('epoch=1 server=1','epoch=2 server=1'),
    $text.Replace("owner_alive=1","owner_alive=0"),
    $text.Replace("[Collision player] REMOVED token=$token owner_alive=1","[Collision player] PLACED token=$token phase=F2 x=0 y=0 z=208`n[Collision player] REMOVED token=$token owner_alive=1"),
    $text.Replace("[Collision player] READY_F1 token=$token","[Collision player] READY_F1 token=$token`n[Collision player] READY_F1 token=$token"),
    $text.Replace('game_ms=3500; x=10; y=0; z=112; vx=0; vy=0; vz=0; ground=1','game_ms=3500; x=10; y=0; z=112; vx=0; vy=0; vz=0; ground=0'),
    $text.Replace('game_ms=3500; x=10; y=0; z=112; vx=0; vy=0; vz=0; ground=1','game_ms=3500; x=10; y=0; z=112; vx=2; vy=0; vz=0; ground=1'),
    $text.Replace('game_ms=1900; x=0; y=0; z=0; vx=0; vy=0; vz=0; ground=1','game_ms=1900; x=0; y=0; z=0; vx=0; vy=0; vz=0; ground=0'),
    $text.Replace('fraction=0.5 normal=0,0,1 contents=1 hitType=1','fraction=0.5 normal=0,0,1 contents=1 hitType=2'),
    $text.Replace('[Collision provider] created world=0 entity=709 instance=7 original_vertices=8 contents=1 template=physicsvolumedummy','').Replace('[Collision player] F0_CLEAR token='+$token, '[Collision provider] created world=0 entity=709 instance=7 original_vertices=8 contents=1 template=physicsvolumedummy'+"`n"+'[Collision player] F0_CLEAR token='+$token)
)
$rejected=0
foreach($case in $bad){if($case -ceq $text){throw 'Negative fixture did not change its causal input.'};try{$null=Read-Case $case}catch{$rejected++;continue};throw 'Invalid movement transcript accepted.'}
foreach($anchor in @(@([double]::NaN,0,0),@(0,0,30001),@(0,0))){try{$null=New-IW7CollisionPlayerPlan $anchor $token}catch{$rejected++;continue};throw 'Invalid geometry plan accepted.'}
Write-Output "PASS collision player pure transcript: valid narrow case, native-only contact refusal and $rejected other causal refusals; no engine/gameplay qualification."
