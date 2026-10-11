$ErrorActionPreference='Stop'
$repo=(Resolve-Path "$PSScriptRoot/../..").Path
. "$repo/ops/voice-agent/Recording.Core.ps1"
. "$repo/ops/voice-agent/Voice-Pair.Core.ps1"
function Check($value,$message){if(!$value){throw $message}}
function Refuses($work){$failed=$false;try{& $work|Out-Null}catch{$failed=$true};Check $failed 'Invalid draft witness accepted.'}
$root=Join-Path ([IO.Path]::GetTempPath()) ('iw7-voice-pair-test-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root)|Out-Null
try{
    $expected=[pscustomobject]@{ServerId=99;Generation=('c'*32);ReceiverCreationFileTime=999UL;Roles=@(
        [pscustomobject]@{PID=11;Nonce=('a'*32);Slot=0;StartedTick=100L;RelayGeneration=('d'*32);SourceSHA256=('1'*64);CreationFileTime=888UL},
        [pscustomobject]@{PID=12;Nonce=('b'*32);Slot=1;StartedTick=100L;RelayGeneration=('e'*32);SourceSHA256=('2'*64);CreationFileTime=999UL})}
    function Snapshot($tick){[pscustomobject]@{OwnershipValidated=$true;ServerId=99;Generation=('c'*32);FixtureReady=$true;FixtureTicks=@($tick,$tick);EnableAudio=$true;PhysicalBytes=20GB;CommitBytes=20GB;Roles=@(
        [pscustomobject]@{PID=11;Nonce=('a'*32);Slot=0;Generation=('c'*32);RelayGeneration=('d'*32);Protected=$true;V2Ready=$true;UIReady=$true;Tick=$tick},
        [pscustomobject]@{PID=12;Nonce=('b'*32);Slot=1;Generation=('c'*32);RelayGeneration=('e'*32);Protected=$true;V2Ready=$true;UIReady=$true;Tick=$tick})}}
    $snapshot=Snapshot 1000;Assert-IW7VoicePairSnapshot $snapshot 1000 $expected
    $snapshot.Roles[1].Protected=$false;Refuses{Assert-IW7VoicePairSnapshot $snapshot 1000 $expected}
    $snapshot=Snapshot 499;Refuses{Assert-IW7VoicePairSnapshot $snapshot 1000 $expected}
    $snapshot=Snapshot 1001;Refuses{Assert-IW7VoicePairSnapshot $snapshot 1000 $expected}
    $snapshot=Snapshot 1000;$snapshot.FixtureTicks[1]=499;Refuses{Assert-IW7VoicePairSnapshot $snapshot 1000 $expected}
    $snapshot=Snapshot 1000;$snapshot.Roles[1].RelayGeneration='f'*32;Refuses{Assert-IW7VoicePairSnapshot $snapshot 1000 $expected}
    $snapshot=Snapshot 1000;$snapshot.Roles[1].V2Ready=1;Refuses{Assert-IW7VoicePairSnapshot $snapshot 1000 $expected}
    $readyText="WASAPI recording ready: scope=process_tree pid=12 creation=999 format=pcm16 rate=48000 channels=2 tick_ms=1000 fallback=0`n"
    $ready=Read-IW7VoiceRecorderReady $readyText $expected.Roles[1] 900 1000
    Check ($ready.ProcessTree) 'Recorder scope lost.'
    Check (!(Read-IW7VoiceRecorderReady $readyText.TrimEnd("`n") $expected.Roles[1] 900 1000)) 'Unterminated recorder record accepted.'
    Refuses{Read-IW7VoiceRecorderReady $readyText.Replace('pid=12','pid=11') $expected.Roles[1] 900 1000}
    Refuses{Read-IW7VoiceRecorderReady ($readyText+$readyText) $expected.Roles[1] 900 1000}
    Refuses{Read-IW7VoiceRecorderReady $readyText $expected.Roles[1] 900 1501}
    Refuses{New-IW7VoicePairArmRecord (Snapshot 1000) $expected $null 1000 ('f'*32)}
    $realTick=[Environment]::TickCount64;$realReady=$ready.PSObject.Copy();$realReady.Tick=$realTick
    $record=@(New-IW7VoicePairArmRecord (Snapshot $realTick) $expected $realReady $realTick ('f'*32))[0]
    Check ($record.Wire.StartsWith('capturearm1 11 ') -and $record.Wire.Contains(' '+('1'*64)+' ')) 'ARM source/PID not bound.'
    $armPath=Join-Path $root 'capture.arm';Write-IW7VoiceCaptureArmRecord $armPath $record ($realTick+500)
    Check ([IO.File]::ReadAllText($armPath) -ceq $record.Wire) 'ARM publication changed bytes.'
    $expired=$record.PSObject.Copy();$expired.Tick=$realTick-1000
    Refuses{Write-IW7VoiceCaptureArmRecord $armPath $expired ($expired.Tick+500)}
    Refuses{Write-IW7VoiceCaptureArmRecord $armPath $record ($realTick+500) -NotAfterTick ($realTick-1)}
    $snapshot=Snapshot $realTick;$snapshot.FixtureTicks[1]=$realTick-400
    $bounded=@(New-IW7VoicePairArmRecord $snapshot $expected $realReady $realTick ('f'*32))[0]
    Check ($bounded.FreshDeadline -eq $realTick+100 -and $bounded.RecorderReadyTick -eq $realReady.Tick) 'ARM deadline renewed an original fixture/recorder timestamp.'
    Check ([IO.File]::ReadAllText($armPath) -ceq $record.Wire -and @(Get-ChildItem $root -Filter '*.tmp').Count -eq 0) 'Expired ARM replaced original record or leaked temp.'
    # Real PCM file validation; counters never substitute for output bytes.
    $wav=Join-Path $root 'synthetic-receiver.wav';$header=[byte[]]::new(44)
    [Text.Encoding]::ASCII.GetBytes('RIFF').CopyTo($header,0);[BitConverter]::GetBytes([uint32]40).CopyTo($header,4)
    [Text.Encoding]::ASCII.GetBytes('WAVEfmt ').CopyTo($header,8);[BitConverter]::GetBytes([uint32]16).CopyTo($header,16)
    [BitConverter]::GetBytes([uint16]1).CopyTo($header,20);[BitConverter]::GetBytes([uint16]2).CopyTo($header,22)
    [BitConverter]::GetBytes([uint32]48000).CopyTo($header,24);[BitConverter]::GetBytes([uint32]192000).CopyTo($header,28)
    [BitConverter]::GetBytes([uint16]4).CopyTo($header,32);[BitConverter]::GetBytes([uint16]16).CopyTo($header,34)
    [Text.Encoding]::ASCII.GetBytes('data').CopyTo($header,36);[BitConverter]::GetBytes([uint32]4).CopyTo($header,40)
    [IO.File]::WriteAllBytes($wav,($header+[byte[]]@(1,0,1,0)));$null=Assert-IW7ReceiverWAV $wav 12
    foreach($failureCase in @('none','slow_preflight','slow_audit','stale_ready','protection','foreign_ack','missing_ptt','malformed_wav','abort_bad','reverse','reverse_foreign_recorder')){
        $selectedSlot=if($failureCase.StartsWith('reverse')){1}else{0}
        $expected|Add-Member SenderSlot $selectedSlot -Force
        $expected.ReceiverCreationFileTime=$expected.Roles[1-$selectedSlot].CreationFileTime
        $clock=@{Tick=1000L;Events=[Collections.Generic.List[string]]::new();Sequence=0UL;Challenge=$null;Input=$null;CaptureArmed=$false;PTT=$false;Completed=$false;Mode=$failureCase;ArmCount=0;RecorderStarted=$false;ReadyTick=0L;Sender=$expected.Roles[$selectedSlot];Receiver=$expected.Roles[1-$selectedSlot];SenderSlot=$selectedSlot}
        $io=@{
            Now={$clock.Tick}
            Sleep={param($ms)$clock.Tick+=$ms}
            Snapshot={
                if($clock.Mode -ceq 'slow_audit'){
                    if($clock.RecorderStarted -and !$clock.CaptureArmed){throw 'Full audit ran inside recorder ARM window.'}
                    $clock.Tick+=600
                }
                $s=Snapshot $clock.Tick
                if($clock.Mode -eq 'protection' -and $clock.Input -and $clock.Input.Action -eq 'hold'){$s.Roles[1].Protected=$false}
                $s
            }
            ArmSnapshot={Check $clock.RecorderStarted 'Fast ARM read before recorder';$clock.Events.Add('fast_arm_read');Snapshot $clock.Tick}
            StartRecorder={param($receiver,$output,$seconds)Check ($receiver.PID -eq $clock.Receiver.PID) 'Recorder targets sender';$clock.Events.Add('recorder_start');$clock.RecorderStarted=$true;$clock.ReadyTick=$clock.Tick;[pscustomobject]@{Started=$true}}
            RecorderState={param($recorder)$clock.Events.Add('recorder_ready');if($clock.Mode -ceq 'stale_ready'){$clock.Tick+=501};$pidValue=if($clock.Mode -ceq 'reverse_foreign_recorder'){$clock.Sender.PID}else{$clock.Receiver.PID};[pscustomobject]@{OwnedIdentityValidated=$true;Exited=$clock.Completed;Stdout="WASAPI recording ready: scope=process_tree pid=$pidValue creation=$($clock.Receiver.CreationFileTime) format=pcm16 rate=48000 channels=2 tick_ms=$($clock.ReadyTick) fallback=0`n"}}
            PublishCaptureArm={param($record,$Deadline)Check $clock.RecorderStarted 'ARM before recorder';Check ($record.Slot -eq $clock.SenderSlot -and $record.PID -eq $clock.Sender.PID -and $Deadline -eq $record.Tick+500) 'Receiver armed or ARM TTL wrong';$clock.Events.Add('capture_arm');$clock.Challenge=$record.RecorderChallenge;$clock.CaptureArmed=$true;$clock.ArmCount++}
            CaptureState={
                if(!$clock.CaptureArmed){$clock.Events.Add('prepared');if($clock.Mode -ceq 'slow_preflight'){$clock.Tick+=600}}
                [pscustomobject]@{BothPrepared=(!$clock.CaptureArmed);DescriptorsValidated=$true;SourceLockNonzeroBytes=0;SenderArmed=$clock.CaptureArmed;ReceiverPrepared=$true;Failed=$false;BindingValidated=$true;Tick=$clock.Tick;RecorderChallenge=$clock.Challenge;SourceA=$(if($clock.SenderSlot -eq 0){'speech'}else{'silence'});SourceB=$(if($clock.SenderSlot -eq 1){'speech'}else{'silence'})}
            }
            SendInput={param($action,$button,$duration,$deadline)
                Check ($deadline -gt $clock.Tick) 'Input publication deadline already expired'
                $clock.Events.Add($action);$clock.Sequence++;$clock.Input=[pscustomobject]@{PID=$clock.Sender.PID;Nonce=$clock.Sender.Nonce;Sequence=$clock.Sequence;Step=$clock.Sequence;SentTick=$clock.Tick;Action=$action;Duration=$duration}
                if($action -eq 'hold'){$clock.PTT=$true};$clock.Input
            }
            InputReply={param($receipt)
                $status=if($receipt.Action -eq 'arm'){'armed'}elseif($clock.Tick-$receipt.SentTick -ge $receipt.Duration){$clock.PTT=$false;$clock.Completed=$true;'step_complete'}else{'dispatched'}
                [pscustomobject]@{PID=$(if($clock.Mode -eq 'foreign_ack' -and $receipt.Action -eq 'hold'){999}else{$clock.Sender.PID});Nonce=$clock.Sender.Nonce;Sequence=$receipt.Sequence;Step=$receipt.Step;Tick=$clock.Tick;Status=$status}
            }
            PTTState={[pscustomobject]@{PID=$clock.Sender.PID;Nonce=$clock.Sender.Nonce;Tick=$clock.Tick;Active=($clock.PTT -and $clock.Mode -ne 'missing_ptt');Key0=$(if($clock.PTT -and $clock.Mode -ne 'missing_ptt'){224}else{0});Key1=0}}
            Counters={
                $n=if($clock.Completed){1}else{0};@{SourceLockNonzeroBytes=$n;EncodedFrames=$n;SentAudioFrames=$n;ServerRelayedFrames=$n;AcceptedNativePlaybackCalls=$n}
            }
            FinishRecorder={param($recorder)$clock.Events.Add('recorder_finish');if($clock.Mode -eq 'malformed_wav'){[IO.File]::WriteAllBytes($wav,[byte[]]@(1,2,3))};[pscustomobject]@{Completed=$true;ExitCode=0;TimedOut=$false;WAVPath=$wav}}
            AnalyzeWAV={param($path)[pscustomobject]@{SyntheticTestOnly=$true;IntelligibilityAccepted=$false}}
            CancelCapture={$clock.Events.Add('capture_cancel');$clock.CaptureArmed=$false;[pscustomobject]@{Cancelled=$true}}
            AbortInput={
                $clock.Events.Add('abort');$clock.PTT=$false;$clock.Sequence++
                $receipt=[pscustomobject]@{PID=$clock.Sender.PID;Nonce=$clock.Sender.Nonce;Sequence=$clock.Sequence;Step=$clock.Sequence;SentTick=$clock.Tick}
                [pscustomobject]@{Receipt=$receipt;Reply=[pscustomobject]@{PID=$clock.Sender.PID;Nonce=$clock.Sender.Nonce;Sequence=$clock.Sequence;Step=$clock.Sequence;Tick=$clock.Tick;Status=$(if($clock.Mode -eq 'abort_bad'){'dispatched'}else{'aborted'})}}
            }
        }
        [IO.File]::WriteAllBytes($wav,($header+[byte[]]@(1,0,1,0)))
        $case=Join-Path $root $failureCase
        if($failureCase -in @('none','slow_preflight','slow_audit','reverse')){
            $result=Invoke-IW7VoicePairWitness $expected $io $case -SpeechHoldMs 200
            Check ($result.MechanicalPathObserved -and !$result.IntelligibilityAccepted -and !$result.HumanConversationAccepted) 'Synthetic orchestration claimed words/human acceptance.'
            Check ($result.SenderSlot -eq $clock.SenderSlot -and $result.ReceiverSlot -eq 1-$clock.SenderSlot) 'Result direction differs from actual input/recorder.'
        }else{Refuses{Invoke-IW7VoicePairWitness $expected $io $case -SpeechHoldMs 200}}
        if($failureCase -in @('reverse_foreign_recorder','stale_ready')){Check ($clock.ArmCount -eq 0 -and !$clock.Events.Contains('hold') -and $clock.Events.Contains('recorder_finish')) 'Foreign/stale recorder allowed speech or leaked recorder';continue}
        Check ($clock.ArmCount -eq 1 -and $clock.Events.IndexOf('recorder_ready') -lt $clock.Events.IndexOf('capture_arm') -and $clock.Events.Contains('abort') -and $clock.Events.Contains('capture_cancel') -and $clock.Events.Contains('recorder_finish')) 'Release/cancel/recorder ordering or cleanup missing.'
        Check ($clock.Events.IndexOf('prepared') -lt $clock.Events.IndexOf('recorder_start')) 'Descriptor preflight consumes the recorder-ready ARM freshness window.'
    }
    'PASS draft VoicePair pure clock orchestration, actual atomic arm file, real WAV validation, stale/foreign/protection/release failures. No audio/game activated.'
}finally{Remove-Item -LiteralPath $root -Recurse -Force}
