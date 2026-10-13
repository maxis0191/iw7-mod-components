param([Parameter(Mandatory)][string]$OutputRoot,[string]$VoiceTokenId)
# SAPI writes directly to a fresh local file. Never opens/records a microphone
# or plays to an endpoint; no system defaults, volume or driver calls.
$ErrorActionPreference='Stop'
. "$PSScriptRoot/Voice-Source.Core.ps1"
$repo=(Resolve-Path "$PSScriptRoot/../..").Path;$runtime=Join-Path $repo 'runtime';$root=[IO.Path]::GetFullPath($OutputRoot)
if(Test-Path -LiteralPath $root){throw 'Fresh source output root required.'}
if(!$root.StartsWith($runtime+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Generated sources stay in ignored runtime.'}
[IO.Directory]::CreateDirectory($root)|Out-Null
$voice=$null;$stream=$null;$tokens=$null;$selected=$null
function Release($object){if($object -and [Runtime.InteropServices.Marshal]::IsComObject($object)){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($object)}}
try{
    $voice=New-Object -ComObject SAPI.SpVoice;$tokens=$voice.GetVoices()
    for($i=0;$i -lt $tokens.Count;$i++){
        $token=$tokens.Item($i)
        if(($VoiceTokenId -and $token.Id -ceq $VoiceTokenId) -or (!$VoiceTokenId -and $token.GetAttribute('Language') -match '(?i)(^|;)409(;|$)')){$selected=$token;break}
        Release $token
    }
    if(!$selected){throw 'One installed English SAPI token required; no download/fallback.'}
    $voice.Voice=$selected;$voice.Rate=1
    $raw=Join-Path $root 'speech-original.wav';$stream=New-Object -ComObject SAPI.SpFileStream
    $format=$stream.Format;try{$format.Type=18}finally{Release $format}
    $stream.Open($raw,3,$false);$voice.AudioOutputStream=$stream
    $text='Alpha seven. Blue lantern.'
    [void]$voice.Speak($text,0);$stream.Close();Release $stream;$stream=$null
    $bytes=[IO.File]::ReadAllBytes($raw);$parsed=Read-IW7VoiceFixtureWAV $bytes speech
    if($parsed.Seconds -gt 3){throw 'Original phrase exceeds 3s; retain raw file, never trim spoken words.'}
    $pcm=[byte[]]::new(128000);[Array]::Copy($bytes,$parsed.PCMOffset,$pcm,16000,$parsed.PCMBytes)
    $header=[byte[]]::new(44);[Text.Encoding]::ASCII.GetBytes('RIFF').CopyTo($header,0)
    [BitConverter]::GetBytes([uint32](36+$pcm.Length)).CopyTo($header,4);[Text.Encoding]::ASCII.GetBytes('WAVEfmt ').CopyTo($header,8)
    [BitConverter]::GetBytes([uint32]16).CopyTo($header,16);[BitConverter]::GetBytes([uint16]1).CopyTo($header,20);[BitConverter]::GetBytes([uint16]1).CopyTo($header,22)
    [BitConverter]::GetBytes([uint32]16000).CopyTo($header,24);[BitConverter]::GetBytes([uint32]32000).CopyTo($header,28)
    [BitConverter]::GetBytes([uint16]2).CopyTo($header,32);[BitConverter]::GetBytes([uint16]16).CopyTo($header,34)
    [Text.Encoding]::ASCII.GetBytes('data').CopyTo($header,36);[BitConverter]::GetBytes([uint32]$pcm.Length).CopyTo($header,40)
    $files=@();foreach($kind in @('speech','silence')){
        $path=Join-Path $root ($kind+'.wav');$data=if($kind -eq 'speech'){$pcm}else{[byte[]]::new($pcm.Length)}
        $output=[IO.File]::Open($path,'CreateNew','Write','Read');try{$output.Write($header,0,$header.Length);$output.Write([byte[]]$data,0,$data.Length)}finally{$output.Dispose()}
        $files+=[pscustomobject]@{Kind=$kind;Path=$path;SHA256=(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant();DurationMs=4000;Bytes=44+$pcm.Length}
    }
    $manifest=[pscustomobject]@{OriginalText=$text;VoiceToken=$selected.Id;VoiceName=$selected.GetDescription();Rate=1;Format='PCM16 mono16000';OriginalSpeechMs=$parsed.Seconds*1000;
        InitialSilenceMs=500;FinalSilenceMs=3500-$parsed.Seconds*1000;Files=$files;GeneratorSHA256=(Get-FileHash $PSCommandPath).Hash;
        RawOriginalSHA256=(Get-FileHash $raw).Hash;SpeechTrimmed=$false;EndpointRenderRequested=$false;MicrophoneRecorded=$false;HumanConversation=$false}
    $manifest|ConvertTo-Json -Depth 6|Set-Content (Join-Path $root 'sources.local.json');$manifest
}finally{Release $stream;Release $selected;Release $tokens;Release $voice}
