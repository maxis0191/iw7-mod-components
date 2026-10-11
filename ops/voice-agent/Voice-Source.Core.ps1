# File-only validation. No COM/device/capture activation.
function Read-IW7VoiceFixtureWAV {
    param([byte[]]$Bytes,[ValidateSet('speech','silence')][string]$Kind)
    $a=[Text.Encoding]::ASCII
    if($Bytes.Length -lt 44 -or $Bytes.Length -gt 480102 -or $a.GetString($Bytes,0,4) -cne 'RIFF' -or
        $a.GetString($Bytes,8,4) -cne 'WAVE' -or [BitConverter]::ToUInt32($Bytes,4) -ne $Bytes.Length-8){throw 'Bounded RIFF fixture required.'}
    $fmt=$false;$data=$false;$nonzero=$false;$pcmBytes=0;$pcmOffset=0
    for($offset=12;$offset -lt $Bytes.Length;){
        if($offset+8 -gt $Bytes.Length){throw 'Truncated RIFF chunk header.'}
        $size=[long][BitConverter]::ToUInt32($Bytes,$offset+4);$start=$offset+8;$tag=$a.GetString($Bytes,$offset,4)
        if($start+$size+($size%2) -gt $Bytes.Length){throw 'Truncated RIFF chunk.'}
        if($tag -ceq 'fmt '){
            if($fmt -or $size -notin @(16,18) -or [BitConverter]::ToUInt16($Bytes,$start) -ne 1 -or
                [BitConverter]::ToUInt16($Bytes,$start+2) -ne 1 -or [BitConverter]::ToUInt32($Bytes,$start+4) -ne 16000 -or
                [BitConverter]::ToUInt32($Bytes,$start+8) -ne 32000 -or [BitConverter]::ToUInt16($Bytes,$start+12) -ne 2 -or
                [BitConverter]::ToUInt16($Bytes,$start+14) -ne 16 -or ($size -eq 18 -and [BitConverter]::ToUInt16($Bytes,$start+16) -ne 0)){throw 'PCM16 mono16k fmt required.'}
            $fmt=$true
        }elseif($tag -ceq 'data'){
            if(!$fmt -or $data -or !$size -or $size%2 -or $size -gt 480000){throw 'Bounded unique PCM data required.'}
            $data=$true;$pcmBytes=$size;$pcmOffset=$start
            for($i=$start;$i -lt $start+$size;$i++){if($Bytes[$i] -ne 0){$nonzero=$true;break}}
        }
        $offset=$start+$size+($size%2)
    }
    if(!$fmt -or !$data -or ($Kind -ceq 'speech' -and !$nonzero) -or ($Kind -ceq 'silence' -and $nonzero)){throw 'Missing chunks or source speech/silence category mismatch.'}
    [pscustomobject]@{Kind=$Kind;PCMBytes=$pcmBytes;PCMOffset=$pcmOffset;Seconds=$pcmBytes/32000.0;SourceIsSynthetic=$true;HumanAcceptance=$false}
}
function Set-IW7VoicePairPlanOptions {
    param($PairPlan,$Speech,$Silence,[ValidateRange(0,1)][int]$SenderSlot=0,[switch]$QuietGameAudio)
    if($PairPlan.RunPlan.Debugger){throw 'This minimal VoicePair proposal requires explicit no-debugger20/20.'}
    $run=Get-IW7LabRunPlan Reduced -PlannedClients 2 -EnableAudio
    foreach($role in $PairPlan.Roles){
        if($role.Slot -notin @(0,1) -or $role.Name -cne @('A','B')[$role.Slot]){throw 'Voice source role/slot identity differs.'}
        $speaking=$role.Slot -eq $SenderSlot
        $source=if($speaking){$Speech}else{$Silence}
        $proof=Read-IW7VoiceFixtureWAV $source.Bytes $(if($speaking){'speech'}else{'silence'})
        if($speaking -and $proof.Seconds -gt 4){throw 'Speech source must fit one <=5s ordinary PTT hold; prepare a shorter original phrase.'}
        if($source.Sha256 -cnotmatch '^[a-f0-9]{64}$' -or ![IO.Path]::IsPathFullyQualified($source.Path) -or $source.Path -match '["\r\n]'){throw 'Pinned absolute WAV source identity required.'}
        $role.Plan.RunPlan=$run
        $role.Plan.MutableFiles=@(@($role.Plan.MutableFiles)+@('iw7-mod/paris-voice-capture.arm')|Select-Object -Unique)
        $role.Plan|Add-Member VoicePairSource ([pscustomobject]@{Path=$source.Path;SHA256=$source.Sha256;Kind=$proof.Kind;Slot=$role.Slot;QuietGameAudio=[bool]$QuietGameAudio}) -Force
    }
    $PairPlan.RunPlan=$run;$PairPlan
}
function Get-IW7VoicePairExtraArguments {
    param($Plan)
    $voice=$Plan.VoicePairSource
    if(!$Plan.RunPlan.EnableAudio -or $Plan.RunPlan.PlannedClients -ne 2 -or $Plan.RunPlan.Debugger -or
        $Plan.RunPlan.PhysicalBytes -ne 20GB -or $Plan.RunPlan.CommitBytes -ne 20GB -or !$voice -or
        $voice.Slot -notin @(0,1) -or $voice.SHA256 -cnotmatch '^[a-f0-9]{64}$' -or $Plan.SHA256 -cnotmatch '^[a-fA-F0-9]{64}$' -or
        ![IO.Path]::IsPathFullyQualified($voice.Path) -or $voice.Path -match '["\r\n]'){throw 'Explicit pinned isolated VoicePair options required.'}
    $background=if($voice.PSObject.Properties['QuietGameAudio'] -and $voice.QuietGameAudio){' +set snd_dialogue_volume 0 +set snd_music_volume 0 +set snd_licensed_content_volume 0'}else{''}
    ' +set snd_enable 1 '+$background+' '+(Get-IW7LabVoiceArguments Player)+' -paris-voice-fake-capture -paris-fake-capture-wav="'+$voice.Path+'"'+
        ' -paris-fake-capture-sha256='+$voice.SHA256+' -paris-fake-capture-image-sha256='+$Plan.SHA256.ToLowerInvariant()+
        ' -paris-fake-capture-port='+$Plan.ServerPort+' -paris-fake-capture-slot='+$voice.Slot
}
