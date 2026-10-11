$ErrorActionPreference='Stop'
$repo=(Resolve-Path "$PSScriptRoot/../..").Path
. "$repo/ops/Agent-Pair.Core.ps1"
. "$repo/ops/voice-agent/Voice-Source.Core.ps1"
function Check($v,$message){if(!$v){throw $message}}
function Refuses($body){$bad=$false;try{&$body|Out-Null}catch{$bad=$true};Check $bad 'Invalid voice source/options accepted.'}
$root=Join-Path ([IO.Path]::GetTempPath()) ('iw7-voice-options-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root)|Out-Null
try{
    $header=[byte[]]::new(44);[Text.Encoding]::ASCII.GetBytes('RIFF').CopyTo($header,0)
    [BitConverter]::GetBytes([uint32]40).CopyTo($header,4);[Text.Encoding]::ASCII.GetBytes('WAVEfmt ').CopyTo($header,8)
    [BitConverter]::GetBytes([uint32]16).CopyTo($header,16);[BitConverter]::GetBytes([uint16]1).CopyTo($header,20);[BitConverter]::GetBytes([uint16]1).CopyTo($header,22)
    [BitConverter]::GetBytes([uint32]16000).CopyTo($header,24);[BitConverter]::GetBytes([uint32]32000).CopyTo($header,28)
    [BitConverter]::GetBytes([uint16]2).CopyTo($header,32);[BitConverter]::GetBytes([uint16]16).CopyTo($header,34)
    [Text.Encoding]::ASCII.GetBytes('data').CopyTo($header,36);[BitConverter]::GetBytes([uint32]4).CopyTo($header,40)
    $speech=$header+[byte[]]@(1,0,2,0);$silence=$header+[byte[]]@(0,0,0,0)
    Check ((Read-IW7VoiceFixtureWAV $speech speech).PCMBytes -eq 4) 'Speech PCM not parsed.'
    Refuses{Read-IW7VoiceFixtureWAV $silence speech};Refuses{Read-IW7VoiceFixtureWAV $speech silence}
    $truncated=[byte[]]$speech.Clone();$truncated[40]=255;Refuses{Read-IW7VoiceFixtureWAV $truncated speech}
    $plan=[pscustomobject]@{RunPlan=(Get-IW7LabRunPlan Reduced -PlannedClients 2);Roles=@(
        [pscustomobject]@{Name='A';Slot=0;Plan=[pscustomobject]@{RunPlan=$null;MutableFiles=@('prior.cfg');ServerPort=27116;SHA256=('f'*64)}},
        [pscustomobject]@{Name='B';Slot=1;Plan=[pscustomobject]@{RunPlan=$null;MutableFiles=@('prior.cfg');ServerPort=27116;SHA256=('f'*64)}})}
    $srcA=[pscustomobject]@{Path=(Join-Path $root 'speech.wav');Sha256=('a'*64);Bytes=[byte[]]$speech};$srcB=[pscustomobject]@{Path=(Join-Path $root 'silence.wav');Sha256=('b'*64);Bytes=[byte[]]$silence}
    $null=Set-IW7VoicePairPlanOptions $plan $srcA $srcB
    Check ($plan.RunPlan.EnableAudio -and $plan.RunPlan.PhysicalBytes -eq 20GB -and $plan.RunPlan.CommitBytes -eq 20GB) 'Audio changed complete budget.'
    foreach($role in $plan.Roles){
        $args=Get-IW7VoicePairExtraArguments $role.Plan
        Check ($args.Contains('+set snd_enable 1') -and $args.Contains('-paris-fake-capture-slot='+$role.Slot) -and !$args.Contains('native-trace') -and !$args.Contains('probe') -and 'iw7-mod/paris-voice-capture.arm' -in $role.Plan.MutableFiles) 'Voice options omit exact slot/audio/restore or add private probe.'
    }
    $null=Set-IW7VoicePairPlanOptions $plan $srcA $srcB -SenderSlot 1
    Check ($plan.Roles[0].Plan.VoicePairSource.Kind -ceq 'silence' -and $plan.Roles[0].Plan.VoicePairSource.Slot -eq 0 -and
        $plan.Roles[1].Plan.VoicePairSource.Kind -ceq 'speech' -and $plan.Roles[1].Plan.VoicePairSource.Slot -eq 1 -and
        $plan.Roles[1].Plan.VoicePairSource.Path -ceq $srcA.Path) 'Reverse source selection changed physical role/slot identity.'
    Refuses{Set-IW7VoicePairPlanOptions $plan $srcA $srcB -SenderSlot 2}
    $plan.Roles[1].Slot=0;Refuses{Set-IW7VoicePairPlanOptions $plan $srcA $srcB -SenderSlot 1};$plan.Roles[1].Slot=1
    Check (!(Get-IW7VoicePairExtraArguments $plan.Roles[1].Plan).Contains('+set snd_dialogue_volume')) 'Default witness silently changes game mix.'
    $null=Set-IW7VoicePairPlanOptions $plan $srcA $srcB -SenderSlot 0 -QuietGameAudio
    $quiet=Get-IW7VoicePairExtraArguments $plan.Roles[1].Plan
    Check ($quiet.Contains('+set snd_dialogue_volume 0') -and $quiet.Contains('+set snd_music_volume 0') -and
        $quiet.Contains('+set snd_licensed_content_volume 0') -and !$quiet.Contains('+set snd_volume') -and
        !$quiet.Contains('+set snd_effects_volume') -and !$quiet.Contains('winvoice_')) 'Quiet fixture changes master/effects/microphone instead of only background categories.'
    $plan.Roles[0].Plan.VoicePairSource.Path='C:\voice"unsafe.wav';Refuses{Get-IW7VoicePairExtraArguments $plan.Roles[0].Plan}
    'PASS draft speech/silence RIFF/categories/options20/20/audio/slot/arm restitution, no probe flags. No SAPI/audio/game.'
}finally{Remove-Item -LiteralPath $root -Recurse -Force}
