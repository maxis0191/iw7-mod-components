# Draft definitions only. No import-time launch, capture, admission or mutation.
function Get-IW7VoicePairSenderSlot($Expected) {
    $property=$Expected.PSObject.Properties['SenderSlot']
    if(!$property){return 0}
    if($property.Value -isnot [int] -or $property.Value -notin @(0,1)){throw 'Exact sender slot0 or1 required.'}
    $property.Value
}
function Assert-IW7VoicePairSnapshot {
    param($Snapshot,[long]$NowTick,$Expected)
    if(!$Snapshot -or $Snapshot.OwnershipValidated -isnot [bool] -or !$Snapshot.OwnershipValidated -or
        $Snapshot.ServerId -ne $Expected.ServerId -or $Snapshot.Generation -cne $Expected.Generation -or
        $Snapshot.Roles.Count -ne 2 -or $Snapshot.FixtureReady -isnot [bool] -or !$Snapshot.FixtureReady -or $Snapshot.EnableAudio -isnot [bool] -or $Snapshot.EnableAudio -ne $true -or
        $Snapshot.PhysicalBytes -ne 20GB -or $Snapshot.CommitBytes -ne 20GB){throw 'Exact audio-enabled 20/20 owned pair and no-down fixture required.'}
    foreach($index in @(0,1)){
        $role=$Snapshot.Roles[$index];$owned=$Expected.Roles[$index]
        if($role.PID -ne $owned.PID -or $role.Nonce -cne $owned.Nonce -or $role.Slot -ne $index -or
            $role.Nonce -cnotmatch '^[a-f0-9]{32}$' -or $role.Generation -cne $Expected.Generation -or
            $role.RelayGeneration -cne $owned.RelayGeneration -or $role.RelayGeneration -cnotmatch '^[a-f0-9]{32}$' -or
            $role.Protected -isnot [bool] -or $role.Protected -ne $true -or $role.V2Ready -isnot [bool] -or $role.V2Ready -ne $true -or $role.UIReady -isnot [bool] -or $role.UIReady -ne $true -or
            $role.Tick -lt $owned.StartedTick -or $role.Tick -gt $NowTick -or $NowTick-$role.Tick -gt 500){throw 'Pair identity, v2 incarnation, UI or protection changed/stale.'}
    }
    if($Snapshot.Roles[0].Nonce -ceq $Snapshot.Roles[1].Nonce -or $Snapshot.Roles[0].PID -eq $Snapshot.Roles[1].PID){throw 'Distinct owned pair identities required.'}
}
function Read-IW7VoiceRecorderReady {
    param([string]$Text,$Receiver,[long]$StartedTick,[long]$NowTick)
    if($Text.Length -gt 4MB){throw 'Recorder readiness log exceeded bound.'}
    $lf=$Text.LastIndexOf("`n");if($lf -lt 0){return $null};$Text=$Text.Substring(0,$lf+1)
    $lines=[regex]::Matches($Text,'(?m)^WASAPI recording ready: scope=process_tree pid=(\d+) creation=(\d+) format=pcm16 rate=48000 channels=2 tick_ms=(\d+) fallback=0\r?$')
    if($lines.Count -gt 1){throw 'Recorder emitted repeated readiness.'}
    if(!$lines.Count){return $null}
    $row=$lines[0];$tick=[long]$row.Groups[3].Value
    if([int]$row.Groups[1].Value -ne $Receiver.PID -or [uint64]$row.Groups[2].Value -ne $Receiver.CreationFileTime -or
        $tick -lt $StartedTick -or $tick -gt $NowTick -or $NowTick-$tick -gt 500){throw 'Foreign or stale exact-process-tree recorder readiness.'}
    [pscustomobject]@{PID=$Receiver.PID;CreationFileTime=$Receiver.CreationFileTime;Tick=$tick;ProcessTree=$true;Fallback=$false}
}
function New-IW7VoicePairArmRecord {
    param($Snapshot,$Expected,$Recorder,[long]$NowTick,[string]$RecorderChallenge)
    Assert-IW7VoicePairSnapshot $Snapshot $NowTick $Expected
    $receiverSlot=1-(Get-IW7VoicePairSenderSlot $Expected)
    if(!$Recorder -or $Recorder.PID -ne $Expected.Roles[$receiverSlot].PID -or $Recorder.CreationFileTime -ne $Expected.ReceiverCreationFileTime -or
        $Recorder.Tick -gt $NowTick -or $NowTick-$Recorder.Tick -gt 500 -or $RecorderChallenge -cnotmatch '^[a-f0-9]{32}$'){throw 'Owned receiver stream must be fresh and ready before COM ARM.'}
    foreach($role in $Expected.Roles){
        if($role.SourceSHA256 -cnotmatch '^[a-f0-9]{64}$'){throw 'Pinned role source hash required.'}
        [pscustomobject]@{PID=$role.PID;Nonce=$role.Nonce;Generation=$Expected.Generation;Slot=$role.Slot;RecorderChallenge=$RecorderChallenge;Tick=$NowTick;
            Wire="capturearm1 $($role.PID) $($role.Nonce) $($Expected.Generation) $($role.Slot) $($role.SourceSHA256) $RecorderChallenge $NowTick`n"}
    }
}
function Write-IW7VoiceCaptureArmRecord {
    param([string]$Path,$Record,[long]$Deadline)
    if($Record.Wire.Length -gt 256 -or !$Record.Wire.EndsWith("`n") -or $Deadline -ne $Record.Tick+500){throw 'Invalid bounded capturearm publication.'}
    $temporary=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try{
        [IO.File]::WriteAllText($temporary,$Record.Wire,[Text.Encoding]::ASCII)
        do{
            if([Environment]::TickCount64 -ge $Deadline){throw 'Capturearm expired before publication.'}
            try{[IO.File]::Move($temporary,$Path,$true);break}
            catch [IO.IOException]{
                # Native opens the immutable old mailbox briefly without delete
                # sharing. Retry only that OS contention with the same bytes,
                # original monotonic TTL and retained temporary file.
                if(($_.Exception.HResult -band 0xffff) -notin @(5,32,33)){throw}
                Start-Sleep -Milliseconds 5
            }
        }while($true)
    }finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary}}
}
function Assert-IW7VoicePTTState {
    param($State,$Owned,[long]$NowTick,[int]$PhysicalKey=224)
    if(!$State -or $State.PID -ne $Owned.PID -or $State.Nonce -cne $Owned.Nonce -or
        $State.Tick -lt $Owned.StartedTick -or $State.Tick -gt $NowTick -or $NowTick-$State.Tick -gt 500 -or
        $State.Active -isnot [bool] -or $State.Key0 -notin @(0,$PhysicalKey) -or $State.Key1 -notin @(0,$PhysicalKey) -or
        ($State.Active -and $State.Key0 -ne $PhysicalKey -and $State.Key1 -ne $PhysicalKey)){throw 'Foreign/stale native PTT getter/key state.'}
}
function Confirm-IW7VoicePTTAck {
    param($Receipt,$Reply,[string]$Status,[long]$NowTick)
    if(!$Reply -or $Reply.PID -ne $Receipt.PID -or $Reply.Nonce -cne $Receipt.Nonce -or
        $Reply.Sequence -ne $Receipt.Sequence -or $Reply.Step -ne $Receipt.Step -or
        $Reply.Tick -lt $Receipt.SentTick -or $Reply.Tick -gt $NowTick){throw 'PTT ACK identity/sequence/clock mismatch.'}
    if($Reply.Status -ceq $Status){return $true}
    if($Reply.Status -cne 'dispatched'){throw ('Ordinary PTT refused: '+$Reply.Status)}
    $false
}
function Assert-IW7VoiceInputReceipt {
    param($Receipt,$Owned,[long]$NowTick)
    if(!$Receipt -or $Receipt.PID -ne $Owned.PID -or $Receipt.Nonce -cne $Owned.Nonce -or $Receipt.Sequence -lt 1 -or $Receipt.Step -lt 1 -or
        $Receipt.SentTick -lt $Owned.StartedTick -or $Receipt.SentTick -gt $NowTick){throw 'Foreign native voice input receipt.'}
}
function Confirm-IW7VoicePathCounters {
    param($Before,$After)
    foreach($stage in @('SourceLockNonzeroBytes','EncodedFrames','SentAudioFrames','ServerRelayedFrames','AcceptedNativePlaybackCalls')){
        if(!$Before.Contains($stage) -or !$After.Contains($stage) -or $Before[$stage] -lt 0 -or $After[$stage] -le $Before[$stage]){throw "No independently observed progress at $stage."}
    }
    # Mechanical stage evidence does not certify words or human conversation.
    [pscustomobject]@{StagesObserved=$true;DecodeSucceeded=$false;IntelligibilityAccepted=$false;HumanConversationAccepted=$false}
}
function Invoke-IW7VoicePairWitness {
    param([Parameter(Mandatory)]$Expected,[Parameter(Mandatory)][hashtable]$IO,
        [Parameter(Mandatory)][string]$OutputRoot,[ValidateRange(200,5000)][int]$SpeechHoldMs=4000)
    $required=@('Now','Snapshot','StartRecorder','RecorderState','PublishCaptureArm','CaptureState','SendInput','InputReply','PTTState','Counters','FinishRecorder','AnalyzeWAV','CancelCapture','AbortInput','Sleep')
    foreach($name in $required){if($IO[$name] -isnot [scriptblock]){throw "Missing bounded owned provider $name."}}
    $senderSlot=Get-IW7VoicePairSenderSlot $Expected;$receiverSlot=1-$senderSlot
    $sender=$Expected.Roles[$senderSlot];$receiver=$Expected.Roles[$receiverSlot]
    if(Test-Path -LiteralPath $OutputRoot){throw 'Fresh evidence directory required.'}
    $null=[IO.Directory]::CreateDirectory($OutputRoot)
    $journal=[IO.StreamWriter]::new([IO.File]::Open((Join-Path $OutputRoot 'witness.local.jsonl'),'CreateNew','Write','Read'))
    $state=@{Recorder=$null;RecorderFinished=$false;ArmRequested=$false;InputsStarted=$false;Started=(& $IO.Now);PTTObserved=$false};$failure=$null;$result=$null
    $write={param($row)$journal.WriteLine(($row|ConvertTo-Json -Depth 8 -Compress));$journal.Flush()}
    $refresh={
        $snapshot=& $IO.Snapshot;$now=& $IO.Now
        if($now-$state.Started -ge 29000){throw 'VoicePair bounded 29s witness expired.'}
        Assert-IW7VoicePairSnapshot $snapshot $now $Expected
        $snapshot
    }
    try{
        $snapshot=& $refresh
        $baseline=& $IO.Counters
        # Descriptor/source preflight may parse both lengthy startup logs. Do it
        # before the one-shot WASAPI-ready publication starts its 500ms ARM TTL.
        $prepared=& $IO.CaptureState
        if(!$prepared.BothPrepared -or !$prepared.DescriptorsValidated -or $prepared.SourceLockNonzeroBytes -ne 0){throw 'Both actual Prepared/silent COM descriptors required before ARM.'}
        $state.Recorder=& $IO.StartRecorder $receiver $OutputRoot 12
        do{
            $snapshot=& $refresh;$recorderState=& $IO.RecorderState $state.Recorder
            if(!$recorderState.OwnedIdentityValidated -or $recorderState.Exited){throw 'Owned recorder exited/identity lost before readiness.'}
            $ready=Read-IW7VoiceRecorderReady $recorderState.Stdout $receiver $state.Started (& $IO.Now)
            if(!$ready){& $IO.Sleep 10}
        }while(!$ready)
        $challenge=[guid]::NewGuid().ToString('N')
        $records=@(New-IW7VoicePairArmRecord $snapshot $Expected $ready (& $IO.Now) $challenge)
        $state.ArmRequested=$true
        & $IO.PublishCaptureArm $records[$senderSlot] -Deadline ($records[$senderSlot].Tick+500)|Out-Null
        & $write @{type='capture_arm_requested';record=$records[$senderSlot];receiver_stays_prepared=$true;recorder_ready=$ready}
        do{
            $null=& $refresh;$capture=& $IO.CaptureState
            if($capture.Failed){throw 'Capture failed before PTT.'}
            if(!$capture.SenderArmed){& $IO.Sleep 10}
        }while(!$capture.SenderArmed)
        $sourceKinds=@($capture.SourceA,$capture.SourceB)
        if(!$capture.BindingValidated -or !$capture.ReceiverPrepared -or $capture.Tick -lt $records[$senderSlot].Tick -or $capture.Tick -gt (& $IO.Now) -or
            (& $IO.Now)-$capture.Tick -gt 500 -or $capture.RecorderChallenge -cne $challenge -or $sourceKinds[$senderSlot] -cne 'speech' -or $sourceKinds[$receiverSlot] -cne 'silence'){throw 'Capture ARM/source ownership mismatch.'}
        $state.InputsStarted=$true
        $armReceipt=& $IO.SendInput 'arm' 'none' 0 ($state.Started+29000)
        Assert-IW7VoiceInputReceipt $armReceipt $sender (& $IO.Now)
        do{
            $snapshot=& $refresh;$armReply=& $IO.InputReply $armReceipt
            if($armReply -and (Confirm-IW7VoicePTTAck $armReceipt $armReply 'armed' (& $IO.Now))){break}
            if((& $IO.Now)-$armReceipt.SentTick -ge 1000){throw 'Native voice input ARM ACK timed out.'}
            & $IO.Sleep 10
        }while($true)
        $snapshot=& $refresh
        $before=& $IO.PTTState
        Assert-IW7VoicePTTState $before $sender (& $IO.Now)
        if($before.Active -or $before.Key0 -ne 0 -or $before.Key1 -ne 0){throw 'Foreign or already held PTT input.'}
        $receipt=& $IO.SendInput 'hold' 'talk' $SpeechHoldMs ([math]::Min($state.Started+29000,$snapshot.Roles[$senderSlot].Tick+500))
        Assert-IW7VoiceInputReceipt $receipt $sender (& $IO.Now)
        do{
            $null=& $refresh
            $ptt=& $IO.PTTState
            Assert-IW7VoicePTTState $ptt $sender (& $IO.Now)
            if($ptt.Active){$state.PTTObserved=$true}
            $reply=& $IO.InputReply $receipt
            if($reply -and (Confirm-IW7VoicePTTAck $receipt $reply 'step_complete' (& $IO.Now))){break}
            if((& $IO.Now)-$receipt.SentTick -ge $SpeechHoldMs+1000){throw 'PTT exact release ACK timed out.'}
            & $IO.Sleep 10
        }while($true)
        do{
            $null=& $refresh;$released=& $IO.PTTState
            Assert-IW7VoicePTTState $released $sender (& $IO.Now)
            if($released.Tick -ge $reply.Tick -and !$released.Active -and $released.Key0 -eq 0 -and $released.Key1 -eq 0){break}
            & $IO.Sleep 10
        }while($true)
        if(!$state.PTTObserved -or $released.Active -or $released.Key0 -ne 0 -or $released.Key1 -ne 0){throw 'Actual ordinary PTT 0->1->0 not observed.'}
        & $write @{type='ptt_released';receipt=$receipt;ack=$reply;actual_state_transition=$true}
        do{
            $null=& $refresh;$after=& $IO.Counters;$progress=$true
            foreach($key in @('SourceLockNonzeroBytes','EncodedFrames','SentAudioFrames','ServerRelayedFrames','AcceptedNativePlaybackCalls')){if(!$after.Contains($key) -or $after[$key] -le $baseline[$key]){$progress=$false}}
            if(!$progress){& $IO.Sleep 20}
        }while(!$progress)
        $pathProof=Confirm-IW7VoicePathCounters $baseline $after
        do{$null=& $refresh;$recordState=& $IO.RecorderState $state.Recorder;if(!$recordState.OwnedIdentityValidated){throw 'Recorder identity lost.'};if(!$recordState.Exited){& $IO.Sleep 20}}while(!$recordState.Exited)
        $recording=& $IO.FinishRecorder $state.Recorder
        $state.RecorderFinished=$true
        if(!$recording.Completed -or $recording.ExitCode -ne 0 -or $recording.TimedOut){throw 'Owned recorder did not complete.'}
        $wav=Assert-IW7ReceiverWAV $recording.WAVPath 12
        $signal=& $IO.AnalyzeWAV $recording.WAVPath
        $result=[pscustomobject]@{Source='synthetic_file_backed_COM';SenderSlot=$senderSlot;ReceiverSlot=$receiverSlot;MechanicalPathObserved=$pathProof.StagesObserved;PTTInputObserved=$true;
            WAV=$wav;WAVSHA256=(Get-FileHash -LiteralPath $recording.WAVPath).Hash;CounterEvidence=$after;
            SignalComparison=$signal;NativeDecodeSucceeded=$false;IntelligibilityAccepted=$false;HumanConversationAccepted=$false}
        & $write @{type='mechanical_result';result=$result}
    }catch{$failure=$_;& $write @{type='failure';message=$_.Exception.Message}}
    finally{
        if($state.InputsStarted){try{
            $abort=& $IO.AbortInput
            Assert-IW7VoiceInputReceipt $abort.Receipt $sender (& $IO.Now)
            if(!(Confirm-IW7VoicePTTAck $abort.Receipt $abort.Reply 'aborted' (& $IO.Now))){throw 'Voice final abort ACK missing.'}
            $finalPTT=& $IO.PTTState;Assert-IW7VoicePTTState $finalPTT $sender (& $IO.Now)
            if($finalPTT.Active -or $finalPTT.Key0 -ne 0 -or $finalPTT.Key1 -ne 0){throw 'Voice final PTT release not observed.'}
        }catch{if($failure){$failure.Exception.Data['PTTReleaseError']=$_.Exception.Message}else{$failure=$_}}}
        if($state.ArmRequested){try{$cancel=& $IO.CancelCapture;if(!$cancel -or $cancel.Cancelled -isnot [bool] -or !$cancel.Cancelled){throw 'Native capture cancel was not acknowledged.'}}catch{if($failure){$failure.Exception.Data['CaptureCancelError']=$_.Exception.Message}else{$failure=$_}}}
        if($state.Recorder -and !$state.RecorderFinished){try{& $IO.FinishRecorder $state.Recorder|Out-Null}catch{if($failure){$failure.Exception.Data['RecorderCleanupError']=$_.Exception.Message}else{$failure=$_}}}
        $journal.Dispose()
    }
    if($failure){throw $failure};$result
}
