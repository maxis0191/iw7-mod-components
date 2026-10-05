$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../../ops/Lab-RunPlan.ps1"
. "$PSScriptRoot/../../ops/Lab-Evidence.ps1"
foreach ($mode in @('Native','Relay','Player')) {
    $arguments = Get-IW7LabVoiceArguments $mode
    if (($arguments.Contains('-iw7-voice-relay')) -ne ($mode -ne 'Native') -or
        ($arguments.Contains('-paris-voice-native-trace')) -ne ($mode -ne 'Player') -or
        !$arguments.Contains('-paris-voice-audio-lab')) { throw 'Voice profile selection changed its audio path.' }
}
foreach ($expected in @(@('Full',0,4,0),@('Reduced',0,4,2),@('Full',1,16,0),@('Reduced',1,12,2),@('Full',2,28,0),@('Reduced',2,20,2))) {
    $plan = Get-IW7LabRunPlan $expected[0] $expected[1]
    if ($plan.PhysicalBytes -ne ($expected[2] * 1GB) -or $plan.CommitBytes -ne ($expected[2] * 1GB) -or
        $plan.Picmip -ne $expected[3] -or $plan.PlannedClients -ne $expected[1]) { throw 'Whole-session reservation differs from the explicit plan.' }
    foreach ($name in @('r_picmip','r_picmip_bump','r_picmip_spec')) {
        if (!$plan.GraphicsArguments.Contains("+set $name $($expected[3])")) { throw 'Graphics plan does not explicitly set every changed texture dvar.' }
    }
    if ($plan.EnableAudio) { throw 'Functional runs must stay silent by default.' }
    $audioPlan = Get-IW7LabRunPlan $expected[0] $expected[1] -EnableAudio
    if (!$audioPlan.EnableAudio -or $audioPlan.PhysicalBytes -ne $plan.PhysicalBytes) { throw 'Game audio selection corrupted the run reservation.' }
}
foreach ($case in @(@(0,'A',$false),@(0,'B',$false),@(1,'A',$true),@(1,'B',$false),@(2,'A',$true),@(2,'B',$true))) {
    $accepted = $true
    try { Assert-IW7LabClientPlan (Get-IW7LabRunPlan Reduced $case[0]) $case[1] } catch { $accepted = $false }
    if ($accepted -ne $case[2]) { throw 'Unreserved client admission differs from the complete plan.' }
}
$sample = '[Paris lab graphics] picmip=0; bump=0; spec=0; tick_ms=100000'
foreach ($case in @(@('Modules','StartupOnly',0,$true),@('Modules','StartupOnly',1,$false),@('Modules','StartupOnly',2,$false),@('Modules','CrossMap',1,$true),@('VoiceNative','CrossMap',2,$true))) {
    $accepted = $true
    try { Assert-IW7LabFixturePlan $case[0] $case[1] $case[2] } catch { $accepted = $false }
    if ($accepted -ne $case[3]) { throw 'Startup-only witness admitted an unprotected player plan.' }
}
Assert-IW7LabGraphics $sample 0 99999 100001
foreach ($case in @(@($sample,2,99999),@($sample,0,100001),@($sample.Replace('bump=0','bump=2'),0,99999),@($sample.Replace('picmip=0','picmip=-1'),0,99999))) {
    $refused = $false
    try { Assert-IW7LabGraphics $case[0] $case[1] $case[2] 100001 } catch { $refused = $true }
    if (!$refused) { throw 'Mismatched or stale graphics were accepted.' }
}
Write-Output 'PASS: explicit client count, full/reduced reservations, complete setting restoration and observed capture quality.'
