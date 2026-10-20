$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. "$root/ops/agent-capacity/Standard-Client.Core.ps1"
foreach($profile in @('Full','Reduced')){
    $mip=if($profile -ceq 'Full'){0}else{2}
    $plan=[pscustomobject]@{GraphicsProfile=$profile;RunPlan=[pscustomobject]@{Picmip=$mip};ClientPort=27947;ServerPort=27946}
    $line=Get-IW7CapacityStandardArguments $plan ('a'*32)
    foreach($name in @('r_picmip','r_picmip_bump','r_picmip_spec')){
        if($line -notmatch ('(?:^|\s)\+set '+$name+' '+$mip+'(?:\s|$)')){throw 'Actual launch arguments do not honor full/reduced texture quality.'}
    }
    if($line -notmatch 'paris_capacity_peer_port 27946' -or $line -notmatch '-paris-capacity-client-probe'){throw 'Private-loopback client identity lost.'}
    if($line -match '-paris-capacity-client-(capture|fire)'){throw 'Unrequested input/capture enabled.'}
    $plan|Add-Member NoteProperty CaptureClientFrame $true
    $plan|Add-Member NoteProperty ExerciseClientFire $true
    $requested=Get-IW7CapacityStandardArguments $plan ('a'*32)
    if($requested -notmatch '-paris-capacity-client-capture' -or $requested -notmatch '-paris-capacity-client-fire'){throw 'Explicit native probe actions missing.'}
    $plan.ExerciseClientFire='true'
    try {Get-IW7CapacityStandardArguments $plan ('a'*32);throw 'String probe action accepted.'}
    catch {if($_.Exception.Message -cne 'Explicit boolean capacity probe actions required.'){throw}}
    $plan.ExerciseClientFire=$false
    $plan.RunPlan.Picmip=1
    try {Get-IW7CapacityStandardArguments $plan ('a'*32);throw 'Mismatched quality plan accepted.'}
    catch {if($_.Exception.Message -cne 'Standard client quality differs from its reserved plan.'){throw}}
}
'Distributed-client actual arguments honor Full/Reduced quality and reject a mismatched plan. No game launched.'
