$ErrorActionPreference='Stop'
$repo=(Resolve-Path "$PSScriptRoot/../..").Path
. "$repo/ops/Agent-Pair.Core.ps1"
. "$repo/ops/voice-agent/Providers.Core.ps1"
Initialize-IW7AgentPairNtfs
function Check($v,$message){if(!$v){throw $message}}
function Refuses($action){$bad=$false;try{& $action|Out-Null}catch{$bad=$true};Check $bad 'Invalid native PCM receipt accepted.'}
$root=Join-Path ([IO.Path]::GetTempPath()) ('iw7-native-pcm-test-'+[guid]::NewGuid().ToString('N'))
$stem=Join-Path $root 'voice-witness/native-receiver'
[IO.Directory]::CreateDirectory((Split-Path $stem))|Out-Null
try{
    $arm=[pscustomobject]@{PID=12;Nonce=('a'*32);Generation=('b'*32);RecorderChallenge=('c'*32);Tick=100;FreshDeadline=600}
    $wire=[pscustomobject]@{CaseRoot=$root;Receiver=[pscustomobject]@{Plan=[pscustomobject]@{VoicePairSource=[pscustomobject]@{ReceivedPCMOutputStem=$stem}}};ReceivedArmRecord=$arm;ReceiverSlot=1;SenderSlot=0;Expected=[pscustomobject]@{Roles=@($null,[pscustomobject]@{PID=12})}}
    $receipt=[ordered]@{Schema='iw7.received-native-pcm/1';PID=12;Nonce=$arm.Nonce;Generation=$arm.Generation;RecorderChallenge=$arm.RecorderChallenge;ReceiverSlot=1;SenderSlot=0;AdmittedTick=120;DeadlineTick=15120;Failed=$false;Frames=1;DecodedBytes=4;EnqueuedBytes=2;TruncatedFrames=1;FormatRate=8192;FrequencyMin=8192;FrequencyMax=8192;SpeakerUser=7;SpeakerEpochLow=8;SpeakerEpochHigh=9;InputSourceRead=$false;OriginalCallsForwarded=$true}
    function SaveReceipt{$receipt|ConvertTo-Json|Set-Content -LiteralPath ($stem+'.json')}
    function Wave([int]$bytes){
        $h=[byte[]]::new(44+$bytes);[Text.Encoding]::ASCII.GetBytes('RIFF').CopyTo($h,0);[BitConverter]::GetBytes([uint32](36+$bytes)).CopyTo($h,4)
        [Text.Encoding]::ASCII.GetBytes('WAVEfmt ').CopyTo($h,8);[BitConverter]::GetBytes([uint32]16).CopyTo($h,16)
        [BitConverter]::GetBytes([uint16]1).CopyTo($h,20);[BitConverter]::GetBytes([uint16]1).CopyTo($h,22)
        [BitConverter]::GetBytes([uint32]8192).CopyTo($h,24);[BitConverter]::GetBytes([uint32]16384).CopyTo($h,28)
        [BitConverter]::GetBytes([uint16]2).CopyTo($h,32);[BitConverter]::GetBytes([uint16]16).CopyTo($h,34)
        [Text.Encoding]::ASCII.GetBytes('data').CopyTo($h,36);[BitConverter]::GetBytes([uint32]$bytes).CopyTo($h,40)
        return ,$h
    }
    [IO.File]::WriteAllBytes($stem+'-decoded.wav',(Wave 4));[IO.File]::WriteAllBytes($stem+'-submitted.wav',(Wave 2));SaveReceipt
    Complete-IW7VoiceReceivedPCM $wire
    $proof=Get-Content ($stem+'-proof.local.json') -Raw|ConvertFrom-Json
    Check ($proof.Waves.Count -eq 2 -and !$proof.IntelligibilityAccepted -and !$proof.HumanConversationAccepted -and $proof.Waves[0].FileIdentity) 'Native PCM proof loses actual files or overclaims words.'
    foreach($change in @(@('PID',13),@('RecorderChallenge',('d'*32)),@('AdmittedTick',601),@('DeadlineTick',15121),@('Failed',$true),@('InputSourceRead',$true),@('OriginalCallsForwarded',$false),@('EnqueuedBytes',6),@('FormatRate',7999),@('SpeakerUser',0))){
        $old=$receipt[$change[0]];$receipt[$change[0]]=$change[1];SaveReceipt;try{Refuses{Complete-IW7VoiceReceivedPCM $wire}}catch{throw ('Rejected boundary test failed for '+$change[0]+': '+$_.Exception.Message)};$receipt[$change[0]]=$old
    }
    SaveReceipt
    $wave=Wave 2;$wave[25]=0;[IO.File]::WriteAllBytes($stem+'-submitted.wav',$wave);Refuses{Complete-IW7VoiceReceivedPCM $wire}
    $wire.Receiver.Plan.VoicePairSource.ReceivedPCMOutputStem=Join-Path $root 'outside';Refuses{Complete-IW7VoiceReceivedPCM $wire}
    'PASS actual NTFS PCM receipt/WAV binding, truncation, fresh scope and foreign/source/format rejection. Synthetic files only; no game/audio.'
}finally{
    $checked=[IO.Path]::GetFullPath($root)
    if(!$checked.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase)){throw 'Temporary cleanup escaped.'}
    Remove-Item -LiteralPath $checked -Recurse -Force
}
