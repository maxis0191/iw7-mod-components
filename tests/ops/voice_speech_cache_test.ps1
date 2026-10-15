$ErrorActionPreference='Stop'
. "$PSScriptRoot/../../ops/voice-agent/Speech-Cache.Core.ps1"
$root=Join-Path ([IO.Path]::GetTempPath()) ('iw7-speech-cache-'+[guid]::NewGuid().ToString('N'))
$counter=[pscustomobject]@{Calls=0}
$phrases=[ordered]@{ptt='Original ptt text';reconnect='Original reconnect text'}
$checks=0
function Check($Condition,$Message){if(!$Condition){throw $Message};$script:checks++}
$synthesize={
    param($path,$text)
    $counter.Calls++
    $stream=[IO.FileStream]::new($path,'CreateNew','Write','None');$writer=[IO.BinaryWriter]::new($stream)
    try{
        $writer.Write([Text.Encoding]::ASCII.GetBytes('RIFF'));$writer.Write([uint32]32038)
        $writer.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt '));$writer.Write([uint32]16)
        $writer.Write([uint16]1);$writer.Write([uint16]1);$writer.Write([uint32]16000);$writer.Write([uint32]32000)
        $writer.Write([uint16]2);$writer.Write([uint16]16);$writer.Write([Text.Encoding]::ASCII.GetBytes('data'));$writer.Write([uint32]32002)
        for($i=0;$i -lt 16001;$i++){$writer.Write([int16]($counter.Calls*500))}
    }finally{$writer.Dispose();$stream.Dispose()}
}
try{
    $first=Get-IW7FrozenSpeechFixture $root ('A'*64) 'synthetic-voice' $phrases $synthesize
    Check ($first.Created -and $counter.Calls -eq 2) 'First descriptor must synthesize both original stimuli.'
    $again=Get-IW7FrozenSpeechFixture $root ('A'*64) 'synthetic-voice' $phrases $synthesize
    Check (!$again.Created -and $counter.Calls -eq 2) 'A repeated descriptor resynthesized nondeterministic bytes.'
    foreach($name in $phrases.Keys){
        Check ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($first.Payloads[$name])) -ceq
            [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($again.Payloads[$name]))) 'Repeated frozen payload bytes differ.'
    }
    Check ($first.Files[0].SHA256 -cne $first.Files[1].SHA256) 'Distinct original stimuli lost their own identity.'
    $other=Get-IW7FrozenSpeechFixture $root ('B'*64) 'synthetic-voice' $phrases $synthesize
    Check ($other.Created -and $counter.Calls -eq 4 -and $other.Files[0].SHA256 -cne $first.Files[0].SHA256) 'A new descriptor reused the previous synthesis.'
    $path=Join-Path $first.Cache 'ptt.wav';$bytes=[IO.File]::ReadAllBytes($path);$bytes[50]=$bytes[50] -bxor 1;[IO.File]::WriteAllBytes($path,$bytes)
    $refused=$false
    try{Get-IW7FrozenSpeechFixture $root ('A'*64) 'synthetic-voice' $phrases $synthesize|Out-Null}catch{$refused=$_.Exception.Message -match 'hash differs'}
    Check ($refused -and $counter.Calls -eq 4) 'Corrupted cache was reused or silently resynthesized.'
    $refused=$false
    try{Get-IW7FrozenSpeechFixture $root ('B'*64) 'other-voice' $phrases $synthesize|Out-Null}catch{$refused=$true}
    Check ($refused -and $counter.Calls -eq 4) 'Voice metadata mismatch was accepted.'
    $changed=[ordered]@{ptt='Changed text';reconnect=$phrases.reconnect};$refused=$false
    try{Get-IW7FrozenSpeechFixture $root ('B'*64) 'synthetic-voice' $changed $synthesize|Out-Null}catch{$refused=$true}
    Check ($refused -and $counter.Calls -eq 4) 'Text metadata mismatch was accepted.'
    "PASS frozen speech: $checks controls, first synthesis, byte-identical reuse, changed descriptors and fail-closed tamper/voice/text checks. No microphone or playback."
}finally{
    $resolved=[IO.Path]::GetFullPath($root)
    if(!$resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -or
       (Split-Path $resolved -Leaf) -notlike 'iw7-speech-cache-*'){throw 'Synthetic cache cleanup containment failed.'}
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
