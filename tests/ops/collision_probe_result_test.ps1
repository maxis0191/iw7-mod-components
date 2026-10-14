$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../../ops/Collision-Probe.Core.ps1')
$token='1234567890abcdef1234567890abcdef'
$rows=@(
    "[Collision probe] READY token=$token",
    "[Collision probe] SAFETY token=$token clients=0 cheats=0 inactivity=0",
    "[Collision probe] TRACE token=$token phase=before point=center fraction=1",
    "[Collision probe] TRACE token=$token phase=before point=edge fraction=1",
    '[Collision provider] created world=0 entity=1024 instance=7 original_vertices=8 contents=1 template=default_test',
    "[Collision probe] CREATED token=$token instance=7",
    "[Collision probe] TRACE token=$token phase=inside point=center fraction=0.5",
    "[Collision probe] TRACE token=$token phase=inside point=edge fraction=0.5",
    '[Collision provider] engine_query=point_floor world=0 instance=7 fraction=0.500000000 normal=0.000000,0.000000,1.000000 contents=1 hitType=1 hitId=2046 startsolid=0 allsolid=0',
    '[Collision provider] engine_query=actor_floor world=0 instance=7 fraction=0.733333333 normal=0.000000,0.000000,1.000000 contents=1 hitType=1 hitId=2046 startsolid=0 allsolid=0',
    '[Collision provider] destroyed world=0 entity=1024 instance=7',
    "[Collision probe] TRACE token=$token phase=after point=center fraction=1",
    "[Collision probe] TRACE token=$token phase=after point=edge fraction=1",
    "[Collision probe] DONE token=$token"
)
$text=($rows -join "`n")+"`n"
$result=Read-IW7CollisionProbeResult $text $token
if(!$result.Complete -or $result.Controls.Count -ne 6 -or $result.NativeQueries.Count -ne 2 -or
    $result.Template -cne 'default_test' -or $result.PlayerMovementVerified -or $result.OwnerAccepted){throw 'Valid measured transcript contract failed.'}
$tabs=($rows|ForEach-Object{$_+"`t"}) -join "`r`n"
if(!(Read-IW7CollisionProbeResult ($tabs+"`r`n") $token).Complete){throw 'Actual terminal TAB/CRLF transport refused.'}
if((Read-IW7CollisionProbeResult $text.TrimEnd("`n") $token).Complete){throw 'Partial DONE accepted.'}
if((Read-IW7CollisionProbeResult $text 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa').Complete){throw 'Foreign token accepted.'}
$bad=@(
    ($text.Replace($rows[0],$rows[0]+"`n"+$rows[0])),
    ($text.Replace($rows[2],$rows[2]+"`n"+$rows[2])),
    ($text.Replace('phase=before point=center fraction=1','phase=before point=center fraction=0.9')),
    ($text.Replace('phase=inside point=edge fraction=0.5','phase=inside point=edge fraction=1')),
    ($text.Replace('phase=after point=edge fraction=1','phase=after point=edge fraction=0.5')),
    ($text.Replace('point_floor world=0 instance=7','point_floor world=0 instance=9')),
    ($text.Replace('hitId=2046','hitId=22')),
    ($text.Replace('normal=0.000000','normal=1e999')),
    ($text.Replace($rows[9],$rows[9]+"`n"+$rows[9])),
    ($text.Replace($rows[10]+"`n",'').Replace($rows[12],$rows[12]+"`n"+$rows[10])),
    ($text.Replace($rows[8]+"`n",'').Replace($rows[10],$rows[10]+"`n"+$rows[8])),
    ($text.Replace('destroyed world=0 entity=1024','destroyed world=0 entity=12')),
    ($text.Replace($rows[4]+"`n",'')),
    ($text.Replace($rows[12],"[Collision probe] FAIL token=$token reason=final_safety")),
    ($text.Replace('phase=inside point=center fraction=0.5','phase=inside point=center fraction=NaN')),
    ($text.Replace('startsolid=0','startsolid=1'))
)
foreach($sample in $bad){$refused=$false;try{$null=Read-IW7CollisionProbeResult $sample $token}catch{$refused=$true};if(!$refused){throw 'Malformed or unproven collision transcript accepted.'}}
$errors=$null;$tokens=$null
$null=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../../ops/Run-CollisionProbe.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Collision runner syntax failed.'}
Write-Output 'PASS collision transcript: controls/real native queries/allocation/teardown/order/identity/numeric bounds/terminal transport; no engine, process, admission or file mutation.'
