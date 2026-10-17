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
function Add-Type {$effects.Add('native-compile');throw 'No Add-Type in these pure Source tests.'}
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
    @{Text=$wire+$knownFailure.Replace('[Collision player] FAIL','[CoLlIsIoN PlAyEr] fAiL')+$details+"`n";Reason=$null;Group=$null;Stamp=$null},
    @{Text=$wire+$knownFailure.Replace($token,$token.ToUpperInvariant())+$details+"`n";Reason=$null;Group=$null;Stamp=$null},
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
$weaponDetails=' readiness_group=weapon stamp_state=available'
foreach($label in @('undefined','empty','none','not_owned')){
    $diagnosticCases+=@{Text=$wire+$knownFailure+$weaponDetails+' weapon_predicate='+$label+"`n"+$wire;Reason='frozen_anchor_readiness_lost';Group='weapon';Stamp='available';WeaponPredicate=$label}
}
$diagnosticCases+=@(
    @{Text=$wire+$knownFailure+$weaponDetails+"`n";Reason='frozen_anchor_readiness_lost';Group='weapon';Stamp='available'},
    @{Text=$wire+$knownFailure+$weaponDetails+' weapon_predicate=untrusted_private_value'+"`n";Reason=$null;Group=$null;Stamp=$null},
    @{Text=$wire+$knownFailure+$weaponDetails+' weapon_predicate=not_evaluated'+"`n";Reason=$null;Group=$null;Stamp=$null},
    @{Text=$wire+$knownFailure+$weaponDetails+' weapon_predicate=passed'+"`n";Reason=$null;Group=$null;Stamp=$null},
    @{Text=$wire+$knownFailure+$weaponDetails+' weapon_predicate=none weapon_predicate=none'+"`n";Reason=$null;Group=$null;Stamp=$null},
    @{Text=$wire+$knownFailure+$details+' weapon_predicate=none'+"`n";Reason=$null;Group=$null;Stamp=$null},
    @{Text=$wire+$knownFailure.Replace('frozen_anchor_readiness_lost','admission_or_clearance')+$weaponDetails+' weapon_predicate=none'+"`n";Reason=$null;Group=$null;Stamp=$null},
    @{Text=$wire+$knownFailure+' weapon_predicate=none'+"`n";Reason=$null;Group=$null;Stamp=$null},
    @{Text=$wire+$knownFailure+$weaponDetails+' weapon_predicate=NONE'+"`n";Reason=$null;Group=$null;Stamp=$null},
    @{Text=$wire+$knownFailure+$weaponDetails+' weapon_predicate=none;'+"`n";Reason=$null;Group=$null;Stamp=$null},
    @{Text=$wire+$knownFailure+$weaponDetails+' weapon_predicate=none'+(' untrusted_private_value'*40)+"`n";Reason=$null;Group=$null;Stamp=$null},
    @{Text=$wire+$knownFailure.Replace('[Collision player] FAIL','[CoLlIsIoN PlAyEr] fAiL')+$weaponDetails+' weapon_predicate=none'+"`n";Reason=$null;Group=$null;Stamp=$null},
    @{Text=$wire+$knownFailure.Replace($token,$token.ToUpperInvariant())+$weaponDetails+' weapon_predicate=none'+"`n";Reason=$null;Group=$null;Stamp=$null},
    @{Text="[Collision player] FAIL token=$token malformed_private_value`n"+$knownFailure+$weaponDetails+' weapon_predicate=none'+"`n"+$wire;Reason=$null;Group=$null;Stamp=$null}
)
$diagnosticRefusals=0
foreach($case in $diagnosticCases){
    $caught=$null
    try{$null=Read-IW7CollisionPlayerReady $case.Text $token 42 $nonce 1100 1500}catch{$caught=$_.Exception}
    if(!$caught -or $caught.Message -notmatch 'Fixture refused readiness/anchor' -or
       $caught.Message.Length -gt 256 -or $caught.Message -match 'private_value' -or
       $caught.Data['CollisionReason'] -cne $case.Reason -or
       $caught.Data['CollisionReadinessGroup'] -cne $case.Group -or $caught.Data['CollisionStampState'] -cne $case.Stamp -or
       $caught.Data['CollisionWeaponPredicate'] -cne $case['WeaponPredicate']){
        throw 'Owned FAIL diagnostic leaked, changed refusal, or fell back to Ready/later failure.'
    }
    if($case.Reason -and !$caught.Message.Contains('reason='+$case.Reason)){throw 'Known bounded reason was hidden.'}
    if($case['WeaponPredicate'] -and !$caught.Message.Contains('weapon_predicate='+$case['WeaponPredicate'])){throw 'Known weapon predicate was hidden.'}
    $diagnosticRefusals++
}
$partialFailures=@(
    ($knownFailure+$details)
    ($knownFailure+' malformed_private_value')
    ($knownFailure+$weaponDetails+' weapon_predicate=none')
)
if($partialFailures.Count -ne 3){throw 'Three separate partial failure controls required.'}
foreach($partial in $partialFailures){
    if((Read-IW7CollisionPlayerReady ($wire+$partial) $token 42 $nonce 1100 1500).Ready){throw 'Partial own FAIL fell back to earlier Ready.'}
}
if(!(Read-IW7CollisionPlayerReady ($knownFailure.Replace($token,'cccccccccccccccccccccccccccccccc')+$details+"`n"+$wire) $token 42 $nonce 1100 1500).Ready){throw 'Foreign failure invalidated the owned Ready.'}
if(!(Read-IW7CollisionPlayerReady ($knownFailure.Replace($token,'cccccccccccccccccccccccccccccccc')+$weaponDetails+' weapon_predicate=none'+"`n"+$wire) $token 42 $nonce 1100 1500).Ready){throw 'Foreign weapon failure invalidated the owned Ready.'}
# Source ordering checks, not a substitute interpreter or GSC runtime proof.
$gsc=Get-Content -LiteralPath (Join-Path $root 'tests/fixtures/collision_player_contact.gsc') -Raw
$playable=[regex]::Match($gsc,'(?s)\nplayable\(state\)\s*\{(.*?)\n\}\s*\nsample\(state, phase\)').Groups[1].Value
$ordered=@(
    'state.readiness_weapon_predicate = "not_evaluated";',
    'state.readiness_first_failure = "safe";', 'if (!safe(state)) return false;',
    'state.readiness_first_failure = "ground";', 'grounded = state.player isonground();', 'if (!grounded) return false;',
    'player = state.player;', 'weapon = player getcurrentweapon();', 'velocity = player getvelocity();',
    'state.readiness_first_failure = "weapon";',
    'state.readiness_weapon_predicate = "undefined";', 'if (!isdefined(weapon)) return false;',
    'state.readiness_weapon_predicate = "empty";', 'if (!(weapon != "")) return false;',
    'state.readiness_weapon_predicate = "none";', 'if (!(weapon != "none")) return false;',
    'state.readiness_weapon_predicate = "not_owned";', 'owned = player hasweapon(weapon);', 'if (!owned) return false;',
    'state.readiness_weapon_predicate = "passed";',
    'state.readiness_first_failure = "velocity";', 'if (!(isdefined(velocity) && distance(velocity, (0,0,0)) <= 1)) return false;',
    'state.readiness_first_failure = "intro_screen";', 'intro_exists = scripts\engine\utility::flag_exist("introscreen_over");',
    'if (!intro_exists) return false;', 'intro_over = scripts\engine\utility::flag("introscreen_over");', 'if (!intro_over) return false;',
    'state.readiness_first_failure = "intro_gesture";', 'gesture_exists = scripts\engine\utility::flag_exist("intro_gesture_done");',
    'if (!gesture_exists) return false;', 'gesture_done = scripts\engine\utility::flag("intro_gesture_done");', 'if (!gesture_done) return false;',
    'state.readiness_first_failure = "controls";', 'controls_defined = isdefined(player.controlsfrozen);',
    'if (!controls_defined) return false;', 'controls_frozen = player.controlsfrozen;', 'if (controls_frozen) return false;',
    'state.readiness_first_failure = "hostmigration";', 'migration_defined = isdefined(player.hostmigrationcontrolsfrozen);',
    'if (migration_defined)', 'migration_frozen = player.hostmigrationcontrolsfrozen;', 'if (migration_frozen) return false;',
    'state.readiness_first_failure = "ready";', 'return true;'
)
$previous=-1
foreach($statement in $ordered){$offset=$playable.IndexOf($statement,[StringComparison]::Ordinal);if($offset -le $previous){throw 'GSC readiness getter/guard order or per-evaluation reset changed.'};$previous=$offset}
foreach($getter in @('safe(state)','state.player isonground()','player getcurrentweapon()','player getvelocity()',
    'isdefined(weapon)','weapon != ""','weapon != "none"','player hasweapon(weapon)')){
    if([regex]::Matches($playable,[regex]::Escape($getter)).Count -ne 1){throw 'GSC readiness getter was duplicated or removed.'}
}
$contact=[regex]::Match($gsc,'(?s)\ncontact\(\)\s*\{(.*?)\n\}\s*\nfail\(state, reason\)').Groups[1].Value
if([regex]::Matches($contact,'playable\(state\)').Count -ne 1 -or
   [regex]::Matches($contact,'paris_agent_observationstamp\(\)').Count -ne 1 -or
   $contact -notmatch 'stamp = state.player paris_agent_observationstamp\(\);\s+//[^\n]*\n\s+state.diag_stamp = stamp;\s+playable_now = playable\(state\);' -or
   $contact -notmatch 'if \(playable_now && isdefined\(stamp\) && stamp != "" && stamp != "unavailable"\)' -or
   $contact -notmatch '(?s)if \(state.anchor_frozen\)\s*\{\s*//[^\n]*\n\s*fail\(state, "frozen_anchor_readiness_lost"\);\s*if \(!state.diag_none_attempted.*?readiness_diagnostic\(state, "none"\);\s*\}\s*return;'){
    throw 'GSC diagnostics re-evaluated readiness/stamp or changed frozen failure behavior.'
}
$failureBody=[regex]::Match($gsc,'(?s)\nfail\(state, reason\)\s*\{(.*?)\n\}').Groups[1].Value
if($failureBody -notmatch 'if \(state.readiness_first_failure == "weapon"\)\s+line \+= " weapon_predicate=" \+ state.readiness_weapon_predicate;' -or
   $failureBody -match 'getcurrentweapon|getvelocity|hasweapon'){
    throw 'Failure diagnostics must use only the current cached weapon predicate, without re-query.'
}
Write-Output "PASS $diagnosticRefusals production-reader failure diagnostic refusals, $($partialFailures.Count) partial/2 foreign controls; GSC getter/guard source ordering only, no GSC runtime claim."
# Fresh synthetic console frames only; never E4 evidence.
$diagToken='00112233445566778899aabbccddeeff';$diagNonce='102132435465768798a9bacbdcedfe0f';$diagGeneration='ffeeddccbbaa99887766554433221100'
$diagKnownFailure="[Collision player] FAIL token=$diagToken reason=frozen_anchor_readiness_lost"
$diagWeaponDetails=' readiness_group=weapon stamp_state=available'
$diagWire="[Collision player] PLAYER_READY token=$diagToken; server_pid=57; client_nonce=$diagNonce; server_generation=$diagGeneration; slot=0; native_tick_ms=1400; protected=1; anchor_x=10; anchor_y=20; anchor_z=30`t`n"
$freeze="[Collision readiness] token=$diagToken stage=freeze eval=21; server_pid=57; client_nonce=$diagNonce; server_generation=$diagGeneration; slot=0; native_tick_ms=1400; protected=1; gr=1; w=passed; hw=1; is=1; ig=1; cf=0; hm=U; view=cached`t`n"
$none=$freeze.Replace('stage=freeze eval=21','stage=none eval=22').Replace('native_tick_ms=1400','native_tick_ms=1450').
    Replace('w=passed; hw=1; is=1; ig=1; cf=0; hm=U','w=none; hw=N; is=N; ig=N; cf=N; hm=N')
$canonical=$diagKnownFailure+$diagWeaponDetails+" weapon_predicate=none`t`n"
$pair=$freeze+$canonical+$none
function Read-TestDiagnostic([string]$Value){Read-IW7CollisionReadinessDiagnostic $Value $diagToken 57 $diagNonce $diagGeneration 1100 1500}
foreach($goodPair in @($pair,$pair.Replace('hm=U','hm=0'),$pair.Replace("`n","`r`n"),
    $pair.Replace('eval=21','eval=999998').Replace('eval=22','eval=999999'))){
    $d=Read-TestDiagnostic $goodPair
    if(!$d.Correlated -or $d.Status -cne 'CORRELATED' -or !$d.DiagnosticOnly -or $d.CauseVerified -or
       $d.Events.Count -ne 2 -or $d.PSObject.Properties.Name -ccontains 'Ready'){throw 'Optional diagnostics overclaim or reject a valid cached pair.'}
    foreach($event in @($d.Events)+@($d.CanonicalFAIL)){
        if($goodPair.Substring($event.Offset,$event.RawLine.Length) -cne $event.RawLine -or
           [Text.Encoding]::UTF8.GetByteCount($event.RawLine) -ne $event.WireByteCount){throw 'Raw console bytes/offsets were normalized.'}
    }
}
if(!(Read-IW7CollisionReadinessDiagnostic $pair $diagToken 57 $diagNonce $diagGeneration 1100 1000000).Correlated){throw 'Optional diagnostics acquired an unauthorized maximum age.'}
$largestProducerRow=$freeze.Replace('server_pid=57','server_pid=5794967295').Replace('eval=21','eval=999999').
    Replace('native_tick_ms=1400','native_tick_ms=18446744073709551615').TrimEnd("`n")
if($largestProducerRow.Length -ne 325 -or !$largestProducerRow.EndsWith("`t") -or $largestProducerRow.Substring(0,324) -cmatch '[^\x20-\x7E]'){throw 'Static ASCII character budget differs.'}
$badPairs=@(
    '',$freeze,$none,($freeze+$freeze+$canonical+$none),($none+$canonical+$freeze),
    ($freeze+$none),($freeze+$none+$canonical),($freeze+$canonical.Replace('readiness_group=weapon','readiness_group=controls')+$none),
    ($freeze+"[Collision player] FAIL token=$diagToken reason=unknown`n"+$canonical+$none),
    $pair.TrimEnd("`n"),($pair+'[Collision readiness] token='+$diagToken),
    ($freeze+$canonical+$none.Replace('; view=cached',(' '*384)+'; view=cached')),
    $pair.Replace('view=cached','view=cach'+[char]0xE9+'d'),$pair.Replace('[Collision readiness]','[Collision Readiness]'),
    ($freeze+$canonical+$none.Replace('eval=22','eval=21')),($freeze+$canonical+$none.Replace('eval=22','eval=20')),
    $pair.Replace('eval=22','eval=1000000'),$pair.Replace('eval=22','eval=022'),$pair.Replace('eval=22','eval=0'),
    ($freeze+$canonical+$none.Replace('native_tick_ms=1450','native_tick_ms=1400')),
    ($freeze+$canonical+$none.Replace('native_tick_ms=1450','native_tick_ms=1399')),
    $pair.Replace('native_tick_ms=1400','native_tick_ms=1099'),$pair.Replace('native_tick_ms=1450','native_tick_ms=1501'),
    $pair.Replace('native_tick_ms=1450','native_tick_ms=18446744073709551615'),
    $pair.Replace('native_tick_ms=1450','native_tick_ms=01450'),$pair.Replace('server_pid=57','server_pid=58'),
    $pair.Replace('client_nonce='+$diagNonce,'client_nonce='+('c'*32)),
    $pair.Replace('server_generation='+$diagGeneration,'server_generation='+('c'*32)),
    $pair.Replace('slot=0','slot=1'),$pair.Replace('protected=1','protected=0'),
    $pair.Replace('token='+$diagToken,'token='+('c'*32)),$pair.Replace('; gr=1',''),$pair.Replace('; gr=1','; gr=1; gr=1'),
    ($freeze+$canonical+$none.Replace('hw=N','hw=U')),($freeze+$canonical+$none.Replace('cf=N','cf=0')),
    ($freeze.Replace('hw=1','hw=N')+$canonical+$none),($freeze.Replace('cf=0','cf=1')+$canonical+$none),
    ($freeze.Replace('hm=U','hm=N')+$canonical+$none),($freeze+$canonical+$none.Replace('w=none','w=passed')),
    $pair.Replace('view=cached','view=post_decision'),$pair.Replace('; view=cached','; weapon_name=private; view=cached'),
    ($pair+"[Collision readiness malformed`n"),($pair+$canonical),
    $pair.Replace("`t",''),("`t"+$pair),$pair.Replace(' stage=',"`tstage="),$pair.Replace("`t","`t`t"),
    $pair.Replace("`t","`t "),($freeze+$canonical.Replace("`t",'')+$none),
    ($freeze+$canonical.Replace("`t","`t`t")+$none),($freeze+"`t"+$canonical+$none),$pair.Replace("`n",''),
    ($pair+"`t"+$none),($freeze+$canonical+"`t"+$canonical+$none)
)
if($badPairs.Count -ne 54 -or @($badPairs|Where-Object {$_ -isnot [string]}).Count){throw 'Diagnostic negative controls were grouped or skipped.'}
$diagnosticPairRefusals=0
foreach($badPair in $badPairs){
    $d=Read-TestDiagnostic $badPair
    if($d.Correlated -or $d.Status -cne 'INCONCLUSIVE' -or $d.CauseVerified){throw 'Malformed/stale/foreign cached pair produced positive diagnostic evidence.'}
    $diagnosticPairRefusals++
}
# A valid diagnostic pair can never override the real readiness refusal.
try{$null=Read-IW7CollisionPlayerReady ($diagWire+$pair) $diagToken 57 $diagNonce 1100 1500;throw 'Diagnostic pair created a readiness fallback.'}
catch{if($_.Exception.Data['CollisionWeaponPredicate'] -cne 'none'){throw}}

# Fresh managed originals: no process, wire or serialized evidence is adopted.
function New-TestBinding {
    $client=[pscustomobject]@{PID=73;Image='C:\synthetic\client.exe'}
    $owner=[pscustomobject]@{Identity=$client;StartedTick=1100}
    $identity=[pscustomobject]@{PID=57;Image='C:\synthetic\server.exe'}
    New-IW7CollisionReadinessBindings $owner $identity $diagToken $diagNonce
}
$binding=New-TestBinding
$publication=Read-IW7CollisionPlayerReady $diagWire $diagToken 57 $diagNonce 1100 1500 -Bindings $binding
if(![object]::ReferenceEquals($binding,$binding.Session.CollisionReadinessBindings) -or
   ![object]::ReferenceEquals($binding.ClientIdentity,$binding.Session.Identity) -or
   ![object]::ReferenceEquals($binding.CanonicalReady,$publication) -or
   ![object]::ReferenceEquals($binding.Generation,$publication.Generation)){throw 'Validated canonical references were copied or lost.'}
$caughtRecord=$null
try{Read-IW7CollisionPlayerReady ($diagWire+$canonical) $diagToken 57 $diagNonce 1100 1500 -Bindings $binding;throw 'Owned FAIL returned readiness.'}catch{$caughtRecord=$_}
if($caughtRecord.Exception.Data['CollisionWeaponPredicate'] -cne 'none' -or $binding.Status -cne 'VALIDATED_CANONICAL' -or
   $binding.Generation -cne $diagGeneration -or ![object]::ReferenceEquals($caughtRecord.Exception,$binding.FirstException) -or
   ![object]::ReferenceEquals($binding.FirstErrorRecord.Exception,$binding.FirstException) -or
   ![object]::ReferenceEquals($caughtRecord.Exception.Data['CollisionReadinessBindings'],$binding)){
    throw 'Canonical first failure or SAME binding/exception identity was replaced.'
}
$modelContext=@{RuntimeRefs=@{Session=$binding.Session;Temporary='old dictionary'}}
$modelContext.RuntimeRefs=@{Session=$binding.Session}
if(![object]::ReferenceEquals($modelContext.RuntimeRefs.Session.CollisionReadinessBindings,
    $caughtRecord.Exception.Data['CollisionReadinessBindings'])){throw 'Replacing RuntimeRefs lost the Session-owned record.'}
$duplicateCarrierRefused=$false
try{New-IW7CollisionReadinessBindings $binding.Session $binding.ServerIdentity $diagToken $diagNonce}catch{$duplicateCarrierRefused=$true}
if(!$duplicateCarrierRefused -or ![object]::ReferenceEquals($binding.Session.CollisionReadinessBindings,$binding)){throw 'Foreign/existing carrier was overwritten.'}

$metadataUnknownCases=@(
    $canonical,($canonical+$diagWire),($diagWire+$canonical+$diagWire),
    ($diagWire+$diagWire.Replace('anchor_x=10','anchor_x=NaN')+$canonical),
    ($diagWire+$canonical+$diagWire.Replace('client_nonce='+$diagNonce,'client_nonce='+('d'*32))),
    ($diagWire+$canonical+$diagWire.TrimEnd("`n")),
    ($diagWire+$canonical+$diagWire.Replace('PLAYER_READY','pLaYeR_rEaDy').TrimEnd("`n")),
    ($diagWire+$canonical+$diagWire.Replace('native_tick_ms=1400','native_tick_ms=999999999999999999999')),
    ($diagWire+$canonical+$diagWire.Replace('server_pid=57','server_pid=58')),
    ($diagWire+$canonical+'[Collision player] FAIL token='+$diagToken+' reason=partial'),
    ($freeze+$canonical+$none),
    ($diagWire+$canonical+$diagWire.Replace('anchor_x=10','anchor_x=30001')),
    ($diagWire+$canonical+$diagWire.Replace('anchor_x=10','anchor_x=1e309')),
    ($diagWire+$canonical+"`t"+$diagWire),($diagWire+$canonical+"`t"+$diagWire.TrimEnd("`n")),
    ($diagWire+$canonical+"[Collision player] PLAYER_READY token=$diagToken`n"),
    ($diagWire+"[Collision player] pLaYeR_rEaDy token=$diagToken`n"+$canonical)
)
if($metadataUnknownCases.Count -ne 17){throw 'Metadata causal cases grouped or skipped.'}
$metadataRefusals=0
foreach($inputText in $metadataUnknownCases){
    $b=New-TestBinding
    $null=Read-IW7CollisionPlayerReady $diagWire $diagToken 57 $diagNonce 1100 1500 -Bindings $b
    try{Read-IW7CollisionPlayerReady $inputText $diagToken 57 $diagNonce 1100 1500 -Bindings $b;throw 'First FAIL returned readiness.'}catch{
        if($_.Exception.Data['CollisionWeaponPredicate'] -cne 'none' -or
           ![object]::ReferenceEquals($_.Exception,$b.FirstException) -or
           ![object]::ReferenceEquals($_.Exception.Data['CollisionReadinessBindings'],$b)){throw}
    }
    if($b.Status -cne 'UNKNOWN' -or $null -ne $b.Generation -or $null -ne $b.CanonicalReady){throw 'Older or post-FAIL canonical publication became an expected generation.'}
    $metadataRefusals++
}
$partialOnlyBinding=New-TestBinding
$null=Read-IW7CollisionPlayerReady $diagWire $diagToken 57 $diagNonce 1100 1500 -Bindings $partialOnlyBinding
if((Read-IW7CollisionPlayerReady $diagWire.TrimEnd("`n") $diagToken 57 $diagNonce 1100 1500 -Bindings $partialOnlyBinding).Ready -or
   $partialOnlyBinding.Generation -or $partialOnlyBinding.Status -cne 'UNKNOWN'){throw 'Unterminated input retained an older expected generation.'}
$malformedOnlyBinding=New-TestBinding
$null=Read-IW7CollisionPlayerReady $diagWire $diagToken 57 $diagNonce 1100 1500 -Bindings $malformedOnlyBinding
try{Read-IW7CollisionPlayerReady $diagWire.Replace('anchor_x=10','anchor_x=NaN') $diagToken 57 $diagNonce 1100 1500 -Bindings $malformedOnlyBinding;throw 'Malformed ready accepted.'}catch{
    if($_.Exception.Message -cne 'Malformed/foreign own pose publication; do not fall back to earlier readiness.'){throw}
}
if($malformedOnlyBinding.Generation -or $malformedOnlyBinding.Status -cne 'UNKNOWN'){throw 'Malformed input retained an older generation.'}
$expiredBinding=New-TestBinding
try{Read-IW7CollisionPlayerReady ($diagWire+$canonical) $diagToken 57 $diagNonce 1100 1901 -Bindings $expiredBinding}catch{
    if($_.Exception.Data['CollisionWeaponPredicate'] -cne 'none'){throw}
}
if($expiredBinding.Generation -or $expiredBinding.Status -cne 'UNKNOWN'){throw 'Metadata relaxed the canonical 500ms freshness rule.'}
$independent=New-TestBinding
try{Read-IW7CollisionPlayerReady ($diagWire+$freeze.Replace($diagGeneration,('d'*32))+$canonical) $diagToken 57 $diagNonce 1100 1500 -Bindings $independent}catch{
    if($_.Exception.Data['CollisionWeaponPredicate'] -cne 'none'){throw}
}
if($independent.Generation -cne $diagGeneration){throw 'B supplied an expected generation.'}
$foreign=New-TestBinding;$foreign.ClientIdentity=[pscustomobject]@{PID=73}
try{Read-IW7CollisionPlayerReady ($diagWire+$canonical) $diagToken 57 $diagNonce 1100 1500 -Bindings $foreign}catch{
    if($_.Exception.Data.Contains('CollisionReadinessBindings') -or $_.Exception.Data['CollisionWeaponPredicate'] -cne 'none'){throw}
}
if($foreign.Generation -or $foreign.FirstException){throw 'Foreign carrier acquired validated expectations.'}

# Execute the actual operation catch with synthetic originals, never its Run body.
$opTokens=$null;$opErrors=$null
$operationAST=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'ops/Invoke-CollisionPlayerContact.ps1'),[ref]$opTokens,[ref]$opErrors)
$operationTry=@($operationAST.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]})
if($opErrors.Count -or $operationTry.Count -ne 1){throw 'Operation first-error boundary changed.'}
$actualCatch=$operationTry[0].CatchClauses[0].Extent.Text
$syntheticOperation=[scriptblock]::Create('try { throw $sourceException } '+$actualCatch)
$collisionBindings=$binding;$Session=$binding.Session;$sourceException=$binding.FirstException;$savedFirstRecord=$binding.FirstErrorRecord
try{& $syntheticOperation}catch{
    if(![object]::ReferenceEquals($_.Exception,$sourceException) -or
       ![object]::ReferenceEquals($collisionBindings.FirstErrorRecord,$savedFirstRecord)){throw 'Outer unwind replaced the retained FIRST ErrorRecord.'}
}
$collisionBindings=New-TestBinding;$Session=$collisionBindings.Session
$sourceException=[InvalidOperationException]::new('fresh synthetic operation refusal')
try{& $syntheticOperation;throw 'Operation catch swallowed the first failure.'}catch{
    if(![object]::ReferenceEquals($_.Exception,$sourceException) -or
       ![object]::ReferenceEquals($_.Exception.Data['CollisionReadinessBindings'],$collisionBindings) -or
       ![object]::ReferenceEquals($collisionBindings.FirstException,$sourceException)){throw}
}
foreach($command in @('Read-IW7AgentWire','Read-IW7BaseLog')){
    $calls=@($operationAST.FindAll({param($a) $a -is [Management.Automation.Language.CommandAst]},$true)|Where-Object {$_.GetCommandName() -ceq $command})
    if($calls.Count -ne $(if($command -ceq 'Read-IW7AgentWire'){1}else{3})){throw 'Operation introduced wire/log IO.'}
}
if([regex]::Matches($operationAST.Extent.Text,'\[Environment\]::TickCount64').Count -ne 6 -or
   $operationAST.Extent.Text -match 'Read-IW7CollisionReadinessDiagnostic' -or
   $operationAST.Extent.Text.IndexOf('Assert-IW7CollisionPlayerFrozenReady') -ge $operationAST.Extent.Text.IndexOf("'set paris_collision_probe_arm 1'")){
    throw 'Operation added a clock/diagnostic arm hook or changed the frozen-readiness gate.'
}
Write-Output "PASS SAME carrier/Session/Exception references, $metadataRefusals missing/latest/post-FAIL metadata controls, freshness/foreign/B isolation and actual operation catch; IO/clock counts unchanged."

function Assert-CachedDiagnosticSource([string]$Source){
    $Source=$Source.Replace("`r`n","`n")
    $functions=@{}
    foreach($m in [regex]::Matches($Source,'(?ms)^([a-z_]+)\([^\n]*\)\n\{.*?^\}')){$functions[$m.Groups[1].Value]=$m.Value}
    # All nine unmodified functions include canonical FAIL and the actual controls.
    $fixed=@{
        main='927B7FD98B7DD209BB6872571D1CD75A18C2F952272B8F899674DD217E8C8711'
        quiet_arena='FAD1883E6C85DF3ACE182492E442F5687AA0B984D31E720FF69B971C1B8F97A5'
        arena_clear='7C624F445F8692A0E5E999A58F28C8A199A877C0897C1DE652BDDD6E008792BF'
        safe='2588C2B56F1CB47532B676F7C9DCAAE738907A786C23FADD2527C14059C45750'
        sample='D89D9471C78A2456F76C9D1EF4761137CC9EECCF7206219DF65FEF8661F5CB3B'
        fall='E2E7326B92AEF2C9ECBA5E9B6024B549BF1DDF932EFB31246CC03E7CE1ECD8FC'
        place='9B3C0416B61DC4662A1278133E22A9AA38A0BF5D3150E3A8EC36836D7E116559'
        audit='8DEFCD359773CAC7802FFA2E47D5F528EF7C3A6170323E6D2523C788CF6BCD2E'
        fail='6CFFE52098EE3239052670A20FC80A5F012DEECD8D05C981FB1609384368BB6D'
    }
    foreach($name in $fixed.Keys){
        if(!$functions.ContainsKey($name) -or [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
            [Text.Encoding]::UTF8.GetBytes($functions[$name]))) -cne $fixed[$name]){throw 'Original controller or canonical failure/cleanup changed.'}
    }
    $p=$functions['playable'];$c=$functions['contact'];$emitter=$functions['readiness_diagnostic'];$alphabet=$functions['diagnostic_alphabet']
    foreach($call in @('safe(state)','state.player isonground()','player getcurrentweapon()','player getvelocity()',
        'player hasweapon(weapon)','isdefined(weapon)','weapon != ""','weapon != "none"',
        'flag_exist("introscreen_over")','flag("introscreen_over")','flag_exist("intro_gesture_done")','flag("intro_gesture_done")',
        'isdefined(player.controlsfrozen)','isdefined(player.hostmigrationcontrolsfrozen)')){
        if([regex]::Matches($p,[regex]::Escape($call)).Count -ne 1){throw 'Original readiness call count differs.'}
    }
    foreach($field in @('gr','hw','is','ig','cf','hm')){
        $reset=$p.IndexOf('state.diag_'+$field+' = "N";',[StringComparison]::Ordinal)
        if($reset -lt 0 -or $reset -gt $p.IndexOf('if (!safe(state))')){throw 'Per-evaluation cache reset missing.'}
    }
    foreach($field in @('player.controlsfrozen','player.hostmigrationcontrolsfrozen')){
        if([regex]::Matches($p,[regex]::Escape($field)).Count -ne 2){throw 'Controls-field evaluation was added or removed.'}
    }
    if($p -notmatch 'if \(state.diag_eval >= 999999\) state.diag_enabled = false;\s+else state.diag_eval\+\+;' -or
       [regex]::Matches($p,'state.diag_eval\+\+;').Count -ne 1 -or $p -match 'state.diag_eval = 0;'){
        throw 'Diagnostic counter can wrap/reuse or exceed its bound.'
    }
    if([regex]::Matches($c,'paris_agent_observationstamp\(\)').Count -ne 1 -or
       $c -notmatch 'stamp = state.player paris_agent_observationstamp\(\);\s+//[^\n]*\n\s+state.diag_stamp = stamp;\s+playable_now = playable\(state\);'){
        throw 'Original stamp ingress re-observed, moved or reconstructed.'
    }
    foreach($stage in @('freeze','none')){
        if([regex]::Matches($c,[regex]::Escape('readiness_diagnostic(state, "'+$stage+'");')).Count -ne 1 -or
           $c -notmatch ('state.diag_'+$stage+'_attempted = true;\s+readiness_diagnostic\(state, "'+$stage+'"\);')){throw 'Diagnostic attempt is repeated or unguarded.'}
    }
    if($c.IndexOf('readiness_diagnostic(state, "freeze");') -lt $c.IndexOf('print("[Collision player] PLAYER_READY') -or
       $c.IndexOf('readiness_diagnostic(state, "freeze");') -gt $c.IndexOf('if (getdvarint("paris_collision_probe_arm"))') -or
       $c.IndexOf('readiness_diagnostic(state, "none");') -lt $c.IndexOf('fail(state, "frozen_anchor_readiness_lost");')){
        throw 'Diagnostic emission precedes READY or canonical FAIL/cleanup normal return.'
    }
    foreach($call in [regex]::Matches(($emitter+$alphabet),'\b([a-z_]+)\s*\(')){
        if($call.Groups[1].Value -cnotin @('readiness_diagnostic','diagnostic_alphabet','if','for','isdefined','issubstr','getsubstr','print')){
            throw 'Optional output contains a new unreviewed call.'
        }
    }
    if(($emitter+$alphabet) -match 'getcurrentweapon|getvelocity|isonground|hasweapon|paris_|getdvar|gettime\(|\bwait\b|\bnotify\(|state\.player|level\.' -or
       $emitter -notmatch 'if \(line.size > 384\) return;\s+print\(line\);' -or
       [regex]::Matches($emitter,'print\(').Count -ne 1 -or
       $emitter -notmatch 'diagnostic_alphabet\(state.token, "0123456789abcdef", 32\)' -or
       $emitter -notmatch 'diagnostic_alphabet\(state.diag_stamp, "0123456789abcdefghijklmnopqrstuvwxyz_ ;=", 178\)' -or
       $emitter -notmatch 'state.diag_hw != "N" \|\| state.diag_is != "N"' -or
       $alphabet -notmatch 'i < value.size' -or $alphabet -notmatch 'issubstr\(alphabet, getsubstr\(value, i, i \+ 1\)\)'){
        throw 'Optional output reads new state, loses ASCII/bounds, or confuses unevaluated fields.'
    }
}
Assert-CachedDiagnosticSource $gsc
$sourceMutations=@(
    $gsc.Replace('velocity = player getvelocity();','velocity = player getvelocity(); velocity = player getvelocity();'),
    $gsc.Replace('state.diag_stamp = stamp;','state.diag_stamp = state.player paris_agent_observationstamp();'),
    $gsc.Replace('state.diag_hw = "N";','state.diag_hw = "U";'),
    $gsc.Replace('state.diag_eval >= 999999','state.diag_eval >= 1000000'),
    $gsc.Replace('if (line.size > 384)','if (line.size > 385)'),
    $gsc.Replace('state.owner collision_clearboxes();','state.owner delete();'),
    $gsc.Replace('readiness_diagnostic(state, "none");','').Replace('fail(state, "frozen_anchor_readiness_lost");','readiness_diagnostic(state, "none"); fail(state, "frozen_anchor_readiness_lost");'),
    $gsc.Replace('readiness_diagnostic(state, "freeze");','').Replace('print("[Collision player] PLAYER_READY','readiness_diagnostic(state, "freeze"); print("[Collision player] PLAYER_READY'),
    $gsc.Replace('if (line.size > 384) return;','state.player getcurrentweapon(); if (line.size > 384) return;')
)
$sourceCausalRefusals=0
foreach($mutation in $sourceMutations){
    try{Assert-CachedDiagnosticSource $mutation}catch{$sourceCausalRefusals++;continue}
    throw 'Source causal control failed to detect changed evaluation or cleanup placement.'
}
if($sourceCausalRefusals -ne 9){throw 'Source causal controls were grouped or skipped.'}
Write-Output "PASS 5 optional cached pairs, $diagnosticPairRefusals INCONCLUSIVE controls, 9 Source causal refusals, 9 original functions exact; no engine execution."
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
if($effects.Count){throw 'Pure Source/diagnostic checks performed an external effect.'}
Write-Output "PASS collision player Source ordering, pending/preview Plan, missing-original, $rejected identity, $readyRefusals readiness and $poseRefusals pose refusals; live effects=0; no fake retail intro/terrain state."
