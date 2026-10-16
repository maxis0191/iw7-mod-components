param([string]$GscToolPath)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
foreach($file in @('ops/Collision-Player.Core.ps1','ops/Invoke-CollisionPlayerContact.ps1')){
    $tokens=$null;$errors=$null;$null=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root $file),[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'Player operation PowerShell grammar failed.'}
}
$effects=[Collections.Generic.List[string]]::new()
function Enter-IW7ResourceLease {$effects.Add('lease');throw 'No reservation in this source test.'}
function Start-IW7BaseClient {$effects.Add('client');throw 'No client in this source test.'}
function Send-IW7CollisionProbeCommand {$effects.Add('engine');throw 'No engine in this source test.'}
function Get-CimInstance {$effects.Add('process');throw 'No process inspection in default Plan.'}
$token='1234567890abcdef1234567890abcdef'
$plan=& (Join-Path $root 'ops/Invoke-CollisionPlayerContact.ps1') -Anchor @(10,20,30) -Token $token|ConvertFrom-Json
if($plan.PlannedClients -ne 1 -or $plan.ClientCollider -or $plan.ClearanceQualified -or $plan.OwnerAccepted -or
    $plan.Minimum[2] -ne 126 -or $plan.Maximum[2] -ne 142 -or $plan.Start[2] -ne 238){throw 'Source Plan overclaims or changes reviewed geometry.'}
$refused=$false
try{& (Join-Path $root 'ops/Invoke-CollisionPlayerContact.ps1') -Action Run -Token $token}catch{
    if($_.Exception.Message -notmatch 'retained original server/client session'){throw};$refused=$true
}
if(!$refused -or $effects.Count){throw 'Missing-owned-context Run or default Plan performed a live effect.'}
$pending=& (Join-Path $root 'ops/Invoke-CollisionPlayerContact.ps1') -Token $token|ConvertFrom-Json
if(!$pending.CoordinatesPending -or $null -ne $pending.Anchor -or $pending.ClearanceQualified){throw 'Pure selector Plan fabricated a live anchor.'}
$previewRefused=$false
try{& (Join-Path $root 'ops/Invoke-CollisionPlayerContact.ps1') -Action Run -Anchor @(10,20,30) -Token $token}catch{
    if($_.Exception.Message -notmatch 'preview only'){throw};$previewRefused=$true
}
if(!$previewRefused -or $effects.Count){throw 'Preview coordinate entered a live Run.'}
foreach($badPreview in @(@(0),@())){
    $rejectedPreview=$false
    try{& (Join-Path $root 'ops/Invoke-CollisionPlayerContact.ps1') -Action Run -Anchor $badPreview -Token $token}catch{
        if($_.Exception.Message -notmatch 'preview only'){throw};$rejectedPreview=$true
    }
    if(!$rejectedPreview){throw 'Explicit zero/empty preview bypassed live selector refusal.'}
}
. (Join-Path $root 'ops/Collision-Player.Core.ps1')
$nonce='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';$generation='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
$wire="[Collision player] PLAYER_READY token=$token; server_pid=42; client_nonce=$nonce; server_generation=$generation; slot=0; native_tick_ms=1400; protected=1; anchor_x=10; anchor_y=20; anchor_z=30`n"
$ready=Read-IW7CollisionPlayerReady $wire $token 42 $nonce 1100 1500
if(!$ready.Ready -or $ready.Generation -cne $generation -or ($ready.Anchor -join ',') -cne '10,20,30'){throw 'Fresh bound real-pose publication rejected.'}
$readyRefusals=0
foreach($case in @($wire.TrimEnd("`n"),$wire.Replace('native_tick_ms=1400','native_tick_ms=1099'),$wire.Replace('native_tick_ms=1400','native_tick_ms=1501'),
    $wire.Replace('client_nonce='+$nonce,'client_nonce=cccccccccccccccccccccccccccccccc'),$wire.Replace('slot=0','slot=1'),$wire.Replace('protected=1','protected=0'))){
    try{$r=Read-IW7CollisionPlayerReady $case $token 42 $nonce 1100 1500}catch{$readyRefusals++;continue}
    if($r.Ready){throw 'Partial/stale/future/foreign/unprotected readiness accepted.'};$readyRefusals++
}
if((Read-IW7CollisionPlayerReady $wire $token 42 $nonce 1100 1901).Ready){throw 'Expired readiness accepted.'};$readyRefusals++
$poseRefusals=0
foreach($case in @($wire.Replace('; anchor_x=10; anchor_y=20; anchor_z=30',''),$wire.Replace('anchor_x=10','anchor_x=NaN'))){
    try{$r=Read-IW7CollisionPlayerReady $case $token 42 $nonce 1100 1500}catch{$poseRefusals++;continue}
    if($r.Ready){throw 'Missing/nonfinite anchor accepted.'};$poseRefusals++
}
foreach($value in @('30001','1e309')){
    try{$null=Read-IW7CollisionPlayerReady ($wire.Replace('anchor_x=10','anchor_x='+$value)) $token 42 $nonce 1100 1500}catch{$poseRefusals++;continue};throw 'Out-of-range/nonfinite pose accepted.'
}
try{$null=Read-IW7CollisionPlayerReady ($wire+"[Collision player] FAIL token=$token reason=anchor_pose_changed_before_arm`n") $token 42 $nonce 1100 1500}catch{$poseRefusals++}
if($poseRefusals -ne 5){throw 'Fixture failure did not invalidate the earlier ready publication.'}
Assert-IW7CollisionPlayerFrozenReady $ready $ready
foreach($change in @('expired','generation','pose')){
    $current=$ready.PSObject.Copy()
    switch($change){'expired'{$current.Ready=$false}'generation'{$current.Generation='cccccccccccccccccccccccccccccccc'}'pose'{$current.Anchor=@(11,20,30)}}
    try{Assert-IW7CollisionPlayerFrozenReady $ready $current}catch{$poseRefusals++;continue};throw 'Frozen pose/generation/readiness changed before arm.'
}
foreach($badLast in @($wire.Replace('anchor_x=10','anchor_x=NaN'),$wire.Replace('client_nonce='+$nonce,'client_nonce=cccccccccccccccccccccccccccccccc'))){
    try{$null=Read-IW7CollisionPlayerReady ($wire+$badLast) $token 42 $nonce 1100 1500}catch{$poseRefusals++;continue};throw 'Earlier good publication hid a malformed/foreign later pose.'
}
foreach($partialLast in @($wire.Replace('anchor_x=10','anchor_x=NaN').TrimEnd("`n"),$wire.Replace('slot=0','slot=1').TrimEnd("`n"),"[Collision player] FAIL token=$token reason=anchor_pose_changed_before_arm")){
    if((Read-IW7CollisionPlayerReady ($wire+$partialLast) $token 42 $nonce 1100 1500).Ready){throw 'Valid predecessor hid a partial malformed/foreign latest own pose.'};$poseRefusals++
}
foreach($noise in @('[unrelated] partial diagnostic',$wire.Replace('token='+$token,'token=cccccccccccccccccccccccccccccccc').TrimEnd("`n"))){
    if(!(Read-IW7CollisionPlayerReady ($wire+$noise) $token 42 $nonce 1100 1500).Ready){throw 'Unrelated partial noise blocked the fresh owned pose.'}
}
# Exercise the production reader, including failures preceding a valid Ready.
$knownFailure="[Collision player] FAIL token=$token reason=frozen_anchor_readiness_lost"
$details=' readiness_group=controls stamp_state=available'
$diagnosticCases=@(
    @{Text=$wire+$knownFailure+"`n";Reason='frozen_anchor_readiness_lost';Group=$null;Stamp=$null},
    @{Text=$knownFailure+$details+"`n"+$wire;Reason='frozen_anchor_readiness_lost';Group='controls';Stamp='available'},
    @{Text=$wire+$knownFailure+' readiness_group=ready stamp_state=unavailable'+"`n";Reason='frozen_anchor_readiness_lost';Group='ready';Stamp='unavailable'},
    @{Text=$wire+"[Collision player] FAIL token=$token reason=anchor_pose_changed_before_arm`n";Reason='anchor_pose_changed_before_arm';Group=$null;Stamp=$null},
    @{Text=$wire+"[Collision player] FAIL token=$token reason=unknown_private_value`n";Reason=$null;Group=$null;Stamp=$null},
    @{Text=$wire+$knownFailure+' readiness_group=untrusted_private_value stamp_state=available'+"`n";Reason=$null;Group=$null;Stamp=$null},
    @{Text=$wire+$knownFailure+' readiness_group=controls stamp_state=untrusted_private_value'+"`n";Reason=$null;Group=$null;Stamp=$null},
    @{Text=$wire+$knownFailure+' readiness_group=controls'+"`n";Reason=$null;Group=$null;Stamp=$null},
    @{Text=$wire+"[Collision player] FAIL token=$token malformed_private_value`n";Reason=$null;Group=$null;Stamp=$null},
    @{Text=$wire+$knownFailure+(' untrusted_private_value'*40)+"`n";Reason=$null;Group=$null;Stamp=$null},
    @{Text=$wire+$knownFailure.Replace('frozen_anchor_readiness_lost','admission_or_clearance')+$details+"`n";Reason=$null;Group=$null;Stamp=$null},
    @{Text="[Collision player] FAIL token=$token reason=unknown_private_value`n"+$knownFailure+$details+"`n"+$wire;Reason=$null;Group=$null;Stamp=$null}
)
$diagnosticRefusals=0
foreach($case in $diagnosticCases){
    $caught=$null
    try{$null=Read-IW7CollisionPlayerReady $case.Text $token 42 $nonce 1100 1500}catch{$caught=$_.Exception}
    if(!$caught -or $caught.Message -notmatch 'Fixture refused readiness/anchor' -or
       $caught.Message.Length -gt 256 -or $caught.Message -match 'private_value' -or
       $caught.Data['CollisionReason'] -cne $case.Reason -or
       $caught.Data['CollisionReadinessGroup'] -cne $case.Group -or $caught.Data['CollisionStampState'] -cne $case.Stamp){
        throw 'Owned FAIL diagnostic leaked, changed refusal, or fell back to Ready/later failure.'
    }
    if($case.Reason -and !$caught.Message.Contains('reason='+$case.Reason)){throw 'Known bounded reason was hidden.'}
    $diagnosticRefusals++
}
foreach($partial in @($knownFailure+$details,$knownFailure+' malformed_private_value')){
    if((Read-IW7CollisionPlayerReady ($wire+$partial) $token 42 $nonce 1100 1500).Ready){throw 'Partial own FAIL fell back to earlier Ready.'}
}
if(!(Read-IW7CollisionPlayerReady ($knownFailure.Replace($token,'cccccccccccccccccccccccccccccccc')+$details+"`n"+$wire) $token 42 $nonce 1100 1500).Ready){throw 'Foreign failure invalidated the owned Ready.'}
# Source ordering checks, not a substitute interpreter or GSC runtime proof.
$gsc=Get-Content -LiteralPath (Join-Path $root 'tests/fixtures/collision_player_contact.gsc') -Raw
$playable=[regex]::Match($gsc,'(?s)\nplayable\(state\)\s*\{(.*?)\n\}\s*\nsample\(state, phase\)').Groups[1].Value
$ordered=@(
    'state.readiness_first_failure = "safe";', 'if (!safe(state)) return false;',
    'state.readiness_first_failure = "ground";', 'if (!state.player isonground()) return false;',
    'player = state.player;', 'weapon = player getcurrentweapon();', 'velocity = player getvelocity();',
    'state.readiness_first_failure = "weapon";', 'if (!(isdefined(weapon) && weapon != "" && weapon != "none" && player hasweapon(weapon))) return false;',
    'state.readiness_first_failure = "velocity";', 'if (!(isdefined(velocity) && distance(velocity, (0,0,0)) <= 1)) return false;',
    'state.readiness_first_failure = "intro_screen";', 'if (!(scripts\engine\utility::flag_exist("introscreen_over") && scripts\engine\utility::flag("introscreen_over"))) return false;',
    'state.readiness_first_failure = "intro_gesture";', 'if (!(scripts\engine\utility::flag_exist("intro_gesture_done") && scripts\engine\utility::flag("intro_gesture_done"))) return false;',
    'state.readiness_first_failure = "controls";', 'if (!(isdefined(player.controlsfrozen) && !player.controlsfrozen)) return false;',
    'state.readiness_first_failure = "hostmigration";', 'if (!(!isdefined(player.hostmigrationcontrolsfrozen) || !player.hostmigrationcontrolsfrozen)) return false;',
    'state.readiness_first_failure = "ready";', 'return true;'
)
$previous=-1
foreach($statement in $ordered){$offset=$playable.IndexOf($statement,[StringComparison]::Ordinal);if($offset -le $previous){throw 'GSC readiness getter/guard order or per-evaluation reset changed.'};$previous=$offset}
foreach($getter in @('safe(state)','state.player isonground()','player getcurrentweapon()','player getvelocity()','player hasweapon(weapon)')){
    if([regex]::Matches($playable,[regex]::Escape($getter)).Count -ne 1){throw 'GSC readiness getter was duplicated or removed.'}
}
$contact=[regex]::Match($gsc,'(?s)\ncontact\(\)\s*\{(.*?)\n\}\s*\nfail\(state, reason\)').Groups[1].Value
if([regex]::Matches($contact,'playable\(state\)').Count -ne 1 -or
   [regex]::Matches($contact,'paris_agent_observationstamp\(\)').Count -ne 1 -or
   $contact -notmatch 'stamp = state.player paris_agent_observationstamp\(\);\s+playable_now = playable\(state\);' -or
   $contact -notmatch 'if \(playable_now && isdefined\(stamp\) && stamp != "" && stamp != "unavailable"\)' -or
   $contact -notmatch 'if \(state.anchor_frozen\) \{ fail\(state, "frozen_anchor_readiness_lost"\); return; \}'){
    throw 'GSC diagnostics re-evaluated readiness/stamp or changed frozen failure behavior.'
}
Write-Output "PASS $diagnosticRefusals production-reader failure diagnostic refusals, 2 partial/1 foreign controls; GSC getter/guard source ordering only, no GSC runtime claim."
# Only the real GSC fixture reads retail intro/control state. These fixtures
# verify the publication transport/freshness; they never fabricate that state.
$created=[datetime]::Parse('2026-10-14T13:00:00Z').ToUniversalTime();$filetime=$created.ToFileTimeUtc()
$server=[pscustomobject]@{PID=42;Image='C:\candidate\native.exe';CreatedUtc=$created.ToString('o');CreationFileTime=$filetime;SHA256='012E6CDDCD6A91ADC2F041035C86417064998127044A11341895C55F8BD4FC53'}
$kernel=[pscustomobject]@{PID=42;Image=$server.Image;CreationFileTime=$filetime}
$hostRecord=[pscustomobject]@{PID=43;Image='C:\tools\pwsh.exe';CreatedUtc=$created.ToString('o')}
$session=[pscustomobject]@{PairOwnership=$null;Failed=$false;Plan=[pscustomobject]@{ServerPort=27116};Server=$server;LeaseToken=$token}
$lease=[pscustomobject]@{Kind='Runtime';Token=$token;OwnerIdentity=$hostRecord}
Assert-IW7CollisionPlayerOwnership $session $server $kernel $lease $hostRecord 43
$rejected=0
foreach($change in @('reused-server','reused-host','foreign-owner','wrong-lease','main-port','failed-session','retired-native23')){
    $s=$session|ConvertTo-Json -Depth 6|ConvertFrom-Json;$i=$server.PSObject.Copy();$k=$kernel.PSObject.Copy();$l=$lease|ConvertTo-Json -Depth 6|ConvertFrom-Json;$h=$hostRecord.PSObject.Copy()
    switch($change){
        'reused-server' {$k.CreationFileTime++}
        'reused-host' {$h.CreatedUtc=$created.AddSeconds(1).ToString('o')}
        'foreign-owner' {$l.OwnerIdentity.PID=99}
        'wrong-lease' {$l.Token='cccccccccccccccccccccccccccccccc'}
        'main-port' {$s.Plan.ServerPort=27016}
        'failed-session' {$s.Failed=$true}
        'retired-native23' {$i.SHA256='5F1BF0569FF109A46CF23997E2A2EDF551FE6FD525B1F2B341BC8BEB91287006'}
    }
    try{Assert-IW7CollisionPlayerOwnership $s $i $k $l $h 43}catch{$rejected++;continue};throw 'Ambiguous/reused ownership accepted.'
}
if($GscToolPath){
    if((Get-FileHash -LiteralPath $GscToolPath).Hash -cne '1ADFD67414A9B886CBAD57EE0378F622EED485BCEF7711322AEE478E298FADCB'){throw 'Official pinned GSC parser differs.'}
    $output=@(& $GscToolPath -m parse -g iw7 -s pc -y (Join-Path $root 'tests/fixtures/collision_player_contact.gsc') 2>&1)
    if($LASTEXITCODE -ne 0 -or ($output -join "`n") -match '\[ERROR\]|failed|exception' -or
        @($output|Where-Object{"$_" -match '^parsed iw7/collision_player_contact.gsc$'}).Count -ne 1){throw 'GSC source grammar failed.'}
    Write-Output 'PASS pinned GSC grammar; Aurora/runtime compilation remains untested.'
}
Write-Output "PASS collision player source grammar, pending/preview Plan, missing-original, $rejected identity, $readyRefusals readiness and $poseRefusals pose refusals; live effects=0; no fake retail intro/terrain state."
