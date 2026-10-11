# Draft native-log providers; use only the future package with exact STATE and
# talk telemetry. Missing records are failures, never inferred readiness.
function Open-IW7VoiceOwnedLog {
    param([string]$Path)
    # Disable managed read buffering: native stdout/publication can change
    # same-length bytes while this evidence handle remains retained.
    $stream=[IO.FileStream]::new($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite,1,[IO.FileOptions]::None)
    try{[pscustomobject]@{Path=$Path;Stream=$stream;FileId=[IW7AgentPairNtfs]::Identity($stream.SafeFileHandle)}}catch{$stream.Dispose();throw}
}
function Read-IW7VoiceOwnedLog {
    param($Log)
    $current=[IO.File]::Open($Log.Path,'Open','Read','ReadWrite')
    try{if([IW7AgentPairNtfs]::Identity($current.SafeFileHandle) -cne $Log.FileId){throw 'Owned voice log path replaced.'}}finally{$current.Dispose()}
    if($Log.Stream.Length -gt 4MB){throw 'Owned voice log exceeded 4MiB.'}
    $Log.Stream.Position=0;$bytes=[byte[]]::new([int]$Log.Stream.Length);$Log.Stream.ReadExactly($bytes)
    $text=[Text.Encoding]::UTF8.GetString($bytes);$lf=$text.LastIndexOf("`n")
    if($lf -lt 0){return ''};$text.Substring(0,$lf+1)
}
function Read-IW7VoiceFields {
    param([string]$Text,[string]$Prefix)
    # Native STATE logs grow throughout map loading. Avoid a PowerShell pipeline
    # over every historical line on each poll; retain exact line-start matching.
    $start=$Text.LastIndexOf("`n"+$Prefix,[StringComparison]::Ordinal)
    if($start -ge 0){$start++}elseif($Text.StartsWith($Prefix,[StringComparison]::Ordinal)){$start=0}else{return $null}
    $end=$Text.IndexOf("`n",$start);if($end -lt 0){$end=$Text.Length}
    $row=$Text.Substring($start+$Prefix.Length,$end-$start-$Prefix.Length).TrimEnd([char[]]"`r`t .");$fields=@{}
    foreach($token in @($row -split '[; ]+'|Where-Object {$_})){if($token -cnotmatch '^([a-z_][a-z0-9_]*)=([a-zA-Z0-9_-]+)$' -or $fields.ContainsKey($Matches[1])){throw 'Malformed complete native voice field record.'};$fields[$Matches[1]]=$Matches[2]}
    $fields
}
function Get-IW7VoiceStateFields {
    param($Log,$Context,[long]$Now)
    $fields=Read-IW7VoiceFields (Read-IW7VoiceOwnedLog $Log) '[paris-voice-pair] STATE; '
    if(!$fields){return $null}
    $Now=[Environment]::TickCount64
    foreach($key in @('pid','slot','query_tick','tick_ms','relay_gen_low','relay_gen_high','both_ready','ui_ready','talk_valid','talk_key0','talk_key1','talk_active')){
        if(!$fields.ContainsKey($key) -or $fields[$key] -cnotmatch '^(0|[1-9][0-9]*)$'){throw ('Missing/noncanonical voice STATE '+$key)}
    }
    foreach($key in @('both_ready','ui_ready','talk_valid','talk_active')){if($fields[$key] -cnotin @('0','1')){throw 'Nonboolean native STATE.'}}
    # Native main explicitly publishes this tuple before a protected binding.
    # It is an unavailable observation, never a ready or cached safety grant.
    if($fields.nonce -ceq 'none' -and $fields.gen -ceq 'none' -and $fields.query_tick -ceq '0' -and $fields.both_ready -ceq '0'){
        if([int]$fields.pid -ne $Context.Identity.PID -or [int]$fields.slot -notin @(0,1) -or
            [long]$fields.tick_ms -lt $Context.StartedTick -or [long]$fields.tick_ms -gt $Now -or $Now-[long]$fields.tick_ms -gt 500){throw 'Foreign/stale native unavailable STATE.'}
        return $null
    }
    if($fields.nonce -cne $Context.PairNonce -or $fields.gen -cnotmatch '^[a-f0-9]{32}$' -or [int]$fields.pid -ne $Context.Identity.PID -or
        [int]$fields.slot -notin @(0,1) -or [long]$fields.tick_ms -lt $Context.StartedTick -or [long]$fields.tick_ms -gt $Now -or $Now-[long]$fields.tick_ms -gt 500 -or
        [long]$fields.query_tick -lt $Context.StartedTick -or [long]$fields.query_tick -gt $Now -or $Now-[long]$fields.query_tick -gt 500){throw 'Exact native STATE identity/clock missing.'}
    foreach($key in @('both_ready','ui_ready','talk_valid','talk_active')){if($fields[$key] -cnotin @('0','1')){throw 'Nonboolean native STATE.'}}
    $fields
}
function Convert-IW7VoiceRelayGeneration($Fields){([uint64]$Fields.relay_gen_high).ToString('x16')+([uint64]$Fields.relay_gen_low).ToString('x16')}
function New-IW7VoicePairProviders {
    param($Pair,[string]$CaseRoot,[string]$ProbePath,[string]$ProbeSHA256,[string]$RecorderSourceSHA256)
    $ErrorActionPreference='Stop'
    if($RecorderSourceSHA256 -cnotmatch '^[A-F0-9]{64}$'){throw 'Explicit reviewed recorder source pin required for voice providers.'}
    if($Pair.Closed -or $Pair.Sessions.Count -ne 2){throw 'Two started Pair sessions required.'}
    Initialize-IW7AgentPairNtfs
    $a=$Pair.Sessions.A;$b=$Pair.Sessions.B;$logs=@{};$response=Resolve-IW7BasePath $a.Plan.GameRoot 'iw7-mod/paris-agent.response'
    $lease=Get-IW7AgentPairLease $Pair
    if($lease.PhysicalBytes -lt 20GB -or $lease.CommitBytes -lt 20GB){throw 'Whole audio pair reservation missing.'}
    $expected=$null
    try{
        foreach($role in @('A','B')){
            $context=$Pair.Sessions[$role];Assert-IW7BaseIdentity $context.Identity $context.Handle
            if(!$context.Identity.Stdout.StartsWith($CaseRoot+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Owned client stdout must be inside launch case.'}
            $logs[$role]=Open-IW7VoiceOwnedLog $context.Identity.Stdout
        }
        $logs.Server=Open-IW7VoiceOwnedLog $Pair.Server.Stdout
        $until=[Environment]::TickCount64+90000L
        do{
            $states=@();$ready=$true
            foreach($role in @('A','B')){
                $null=Read-IW7AgentPairRoleSafety $Pair $role
                $fields=Get-IW7VoiceStateFields $logs[$role] $Pair.Sessions[$role] ([Environment]::TickCount64)
                $states+=,$fields
                if(!$fields -or $fields.both_ready -cne '1' -or $fields.ui_ready -cne '1' -or $fields.talk_valid -cne '1'){$ready=$false}
            }
            $serverText=Read-IW7VoiceOwnedLog $logs.Server
            if($serverText -match '\[Paris agent voice pair\] FAIL'){throw 'Voice fixture readiness failed.'}
            if(@([regex]::Matches($serverText,'(?m)^\[Paris agent voice pair\] READY;')).Count -ne 2){$ready=$false}
            if($ready){break};Start-Sleep -Milliseconds 20
        }while([Environment]::TickCount64 -lt $until)
        if(!$ready){throw 'VoicePair native both-role v2/UI/STATE readiness expired.'}
        $roles=@()
        foreach($index in @(0,1)){
            $context=$Pair.Sessions[@('A','B')[$index]]
            $roles+=[pscustomobject]@{PID=$context.Identity.PID;Nonce=$context.PairNonce;Slot=$index;StartedTick=$context.StartedTick;
                RelayGeneration=(Convert-IW7VoiceRelayGeneration $states[$index]);SourceSHA256=$context.Plan.VoicePairSource.SHA256;
                Image=$context.Identity.Image;ImageSHA256=$context.Identity.SHA256;CreationFileTime=[uint64]([datetimeoffset]$context.Identity.CreatedUtc).UtcDateTime.ToFileTimeUtc()}
        }
        $expected=[pscustomobject]@{ServerId=$Pair.Server.PID;Generation=$Pair.Generation;Roles=$roles;ReceiverCreationFileTime=$roles[1].CreationFileTime}
        $wire=@{ProposalRoot=$PSScriptRoot;Sequence=0UL;Step=0UL;LastRead=$null;ArmRecord=$null;ServerLog=$logs.Server;Logs=$logs;Pair=$Pair;Expected=$expected;A=$a;B=$b;Response=$response;CaseRoot=$CaseRoot;ProbePath=$ProbePath;ProbeSHA256=$ProbeSHA256;RecorderSourceSHA256=$RecorderSourceSHA256}
        $previous=Read-IW7AgentResponse (Read-IW7AgentWire $response -RequireTerminator) $a.Identity.PID $a.PairNonce
        if($previous){$wire.Sequence=$previous.Sequence;$wire.Step=$previous.Step}
        $io=@{
            Now={[Environment]::TickCount64}
            Sleep={param($ms)Start-Sleep -Milliseconds $ms}
            Snapshot={
                Assert-IW7BaseIdentity $wire.Pair.Server;$null=Get-IW7AgentPairLease $wire.Pair
                # Ownership/CIM/UDP/resource checks can consume the 500ms native
                # publication window. Complete both before reading STATE/SAMPLE;
                # validating an earlier cached transcript creates false staleness.
                foreach($name in @('A','B')){
                    $proof=Update-IW7BaseClient $wire.Pair.Sessions[$name]
                    if(!$proof.Protected){throw 'Pair lost actual protection.'}
                }
                $roles=@()
                foreach($index in @(0,1)){
                    $name=@('A','B')[$index];$context=$wire.Pair.Sessions[$name]
                    $f=Get-IW7VoiceStateFields $wire.Logs[$name] $context ([Environment]::TickCount64)
                    if(!$f -or $f.gen -cne $wire.Expected.Generation -or [int]$f.slot -ne $index){throw 'Owned current STATE binding changed.'}
                    $roles+=[pscustomobject]@{PID=$context.Identity.PID;Nonce=$f.nonce;Generation=$f.gen;Slot=$index;RelayGeneration=(Convert-IW7VoiceRelayGeneration $f);
                        Protected=$true;V2Ready=($f.both_ready -ceq '1');UIReady=($f.ui_ready -ceq '1');Tick=[long]$f.query_tick}
                }
                $text=Read-IW7VoiceOwnedLog $wire.ServerLog
                if($text -match '\[Paris agent voice pair\] FAIL'){throw 'VoicePair fixture failed.'}
                $fixtureReady=$true
                foreach($index in @(0,1)){
                    $pattern='(?m)^\[Paris agent voice pair\] SAMPLE; server_pid='+$wire.Pair.Server.PID+'; client_nonce='+$wire.Expected.Roles[$index].Nonce+'; server_generation='+$wire.Expected.Generation+'; slot='+$index+'; native_tick_ms=(\d+); protected=1; sample_id=\d+; down_fixture=0; ready=1\.[ \t]*\r?$'
                    $samples=[regex]::Matches($text,$pattern)
                    if(!$samples.Count){$fixtureReady=$false;continue}
                    $tick=[long]$samples[-1].Groups[1].Value;$now=[Environment]::TickCount64
                    if($tick -gt $now -or $now-$tick -gt 500){throw 'Voice fixture SAMPLE stale.'}
                }
                [pscustomobject]@{OwnershipValidated=$true;ServerId=$wire.Pair.Server.PID;Generation=$wire.Expected.Generation;FixtureReady=$fixtureReady;Roles=$roles;
                    EnableAudio=$wire.Pair.Plan.RunPlan.EnableAudio;PhysicalBytes=$wire.Pair.Plan.RunPlan.PhysicalBytes;CommitBytes=$wire.Pair.Plan.RunPlan.CommitBytes}
            }
            StartRecorder={param($receiver,$output,$seconds)Start-IW7VoicePairRecorder $receiver $wire.ProbePath $wire.ProbeSHA256 $output $seconds $wire.Pair.LeaseToken $wire.Pair.Plan.ServerRoot $wire.RecorderSourceSHA256}
            RecorderState={param($recorder)Get-IW7VoicePairRecorderState $recorder}
            FinishRecorder={param($recorder)Complete-IW7VoicePairRecorder $recorder}
            AnalyzeWAV={param($path)
                $output=Join-Path (Split-Path $path) 'envelope.local.json'
                if(!('IW7.VoicePairDraft.WaveAnalysis' -as [type])){Add-Type -Path (Join-Path $wire.ProposalRoot 'Analyze-WAV.cs')}
                $result=[IW7.VoicePairDraft.WaveAnalysis]::Analyze($wire.A.Plan.VoicePairSource.Path,$path,$wire.A.Plan.VoicePairSource.SHA256)
                $file=[IO.File]::Open($output,'CreateNew','Write','Read')
                try{$bytes=[Text.Encoding]::UTF8.GetBytes(($result|ConvertTo-Json -Depth 8));$file.Write($bytes,0,$bytes.Length)}finally{$file.Dispose()}
                $result
            }
            PublishCaptureArm={param($record,$Deadline)
                Assert-IW7BaseIdentity $wire.A.Identity $wire.A.Handle
                Write-IW7VoiceCaptureArmRecord (Resolve-IW7BasePath $wire.A.Plan.GameRoot 'iw7-mod/paris-voice-capture.arm') $record $Deadline
                $wire.ArmRecord=$record
            }
            CaptureState={
                $reports=@();foreach($role in @('A','B')){$f=Read-IW7VoiceFields (Read-IW7VoiceOwnedLog $wire.Logs[$role]) '[paris-fake-capture] Observed ';if(!$f -or [int]$f.pid -ne $wire.Pair.Sessions[$role].Identity.PID){throw 'Missing owned COM descriptor.'};$reports+=,$f}
                $descriptor=$true;foreach($f in $reports){if($f.bits -ne '16' -or [int]$f.rate -lt 8000 -or [int]$f.rate -gt 48000 -or [int]$f.channels -notin @(1,2) -or [int]$f.buffer_bytes -lt 4096 -or [int]$f.buffer_bytes -gt 131072 -or $f.failed -ne '0' -or $f.buffer_started -ne '1'){$descriptor=$false}}
                $armed=Read-IW7VoiceFields (Read-IW7VoiceOwnedLog $wire.Logs.A) '[paris-fake-capture] Armed relayv2 '
                $bound=$armed -and [int]$armed.pid -eq $wire.A.Identity.PID -and $armed.nonce -ceq $wire.A.PairNonce -and $armed.gen -ceq $wire.Expected.Generation -and $armed.slot -ceq '0' -and [int]$armed.port -eq $wire.A.Plan.ServerPort
                [pscustomobject]@{BothPrepared=($reports[0].prepared -ceq '1' -and $reports[1].prepared -ceq '1');DescriptorsValidated=$descriptor;
                    SourceLockNonzeroBytes=[long]$reports[0].lock_nonzero_bytes;SenderArmed=[bool]$bound;ReceiverPrepared=($reports[1].prepared -ceq '1');Failed=(!$descriptor);
                    BindingValidated=[bool]$bound;Tick=$(if($armed){[long]$armed.tick_ms}else{0});RecorderChallenge=$(if($armed){$armed.recorder_challenge});SourceA='speech';SourceB='silence'}
            }
            PTTState={
                $f=Get-IW7VoiceStateFields $wire.Logs.A $wire.A ([Environment]::TickCount64)
                if(!$f -or $f.talk_valid -cne '1'){throw 'Native talk getter unavailable.'}
                [pscustomobject]@{PID=[int]$f.pid;Nonce=$f.nonce;Tick=[long]$f.tick_ms;Active=($f.talk_active -ceq '1');Key0=[int]$f.talk_key0;Key1=[int]$f.talk_key1}
            }
            SendInput={param($action,$button,$duration,$deadline)
                Assert-IW7BaseIdentity $wire.A.Identity $wire.A.Handle;$wire.Sequence++;$wire.Step++;$sent=[Environment]::TickCount64
                Write-IW7AgentRequest $wire.A $wire.A.PairNonce $wire.Sequence $wire.Step $action $button $duration -NotAfterTick $deadline
                [pscustomobject]@{PID=$wire.A.Identity.PID;Nonce=$wire.A.PairNonce;Sequence=$wire.Sequence;Step=$wire.Step;SentTick=$sent}
            }
            InputReply={param($receipt)
                $r=Read-IW7AgentResponse (Read-IW7AgentWire $wire.Response -RequireTerminator) $wire.A.Identity.PID $wire.A.PairNonce
                if($r -and $r.Sequence -gt $receipt.Sequence){throw 'Concurrent voice mailbox writer.'}
                if($r -and $r.Sequence -eq $receipt.Sequence){[pscustomobject]@{PID=$wire.A.Identity.PID;Nonce=$wire.A.PairNonce;Sequence=$r.Sequence;Step=$r.Step;Tick=$r.Tick;Status=$r.Status}}
            }
            Counters={
                $relay=@{};foreach($role in @('A','B','Server')){$f=Read-IW7VoiceFields (Read-IW7VoiceOwnedLog $wire.Logs[$role]) '[voice-relay] ';if(!$f -or $f.version -ne '2'){throw 'Native v2 counters missing.'};$relay[$role]=$f}
                $capture=Read-IW7VoiceFields (Read-IW7VoiceOwnedLog $wire.Logs.A) '[paris-fake-capture] Observed '
                @{SourceLockNonzeroBytes=[uint64]$capture.lock_nonzero_bytes;EncodedFrames=[uint64]$relay.A.encoded;SentAudioFrames=[uint64]$relay.A.sent;
                    ServerRelayedFrames=[uint64]$relay.Server.relayed;AcceptedNativePlaybackCalls=[uint64]$relay.B.playback_calls;DiagnosticPacketsReceived=[uint64]$relay.B.packets_received}
            }
            AbortInput={
                $wire.Sequence++;$wire.Step++;$sent=[Environment]::TickCount64
                Write-IW7AgentRequest $wire.A $wire.A.PairNonce $wire.Sequence $wire.Step 'abort'
                $receipt=[pscustomobject]@{PID=$wire.A.Identity.PID;Nonce=$wire.A.PairNonce;Sequence=$wire.Sequence;Step=$wire.Step;SentTick=$sent};$reply=$null
                do{$r=Read-IW7AgentResponse (Read-IW7AgentWire $wire.Response -RequireTerminator) $wire.A.Identity.PID $wire.A.PairNonce
                    if($r -and $r.Sequence -gt $wire.Sequence){throw 'Concurrent voice abort writer.'}
                    if($r -and $r.Sequence -eq $wire.Sequence){$reply=[pscustomobject]@{PID=$wire.A.Identity.PID;Nonce=$wire.A.PairNonce;Sequence=$r.Sequence;Step=$r.Step;Tick=$r.Tick;Status=$r.Status};if($reply.Status -ceq 'aborted'){break}}
                    Start-Sleep -Milliseconds 10
                }while([Environment]::TickCount64-$sent -lt 1000)
                [pscustomobject]@{Receipt=$receipt;Reply=$reply}
            }
            CancelCapture={
                if(!$wire.ArmRecord){return}
                Assert-IW7BaseIdentity $wire.A.Identity $wire.A.Handle
                $sent=[Environment]::TickCount64;$original=$wire.ArmRecord
                $record=[pscustomobject]@{Tick=$sent;Wire="capturecancel1 $($original.PID) $($original.Nonce) $($original.Generation) 0 $($wire.Expected.Roles[0].SourceSHA256) $($original.RecorderChallenge) $sent`n"}
                Write-IW7VoiceCaptureArmRecord (Resolve-IW7BasePath $wire.A.Plan.GameRoot 'iw7-mod/paris-voice-capture.arm') $record ($sent+500)
                do{
                    $f=Read-IW7VoiceFields (Read-IW7VoiceOwnedLog $wire.Logs.A) '[paris-fake-capture] Cancelled request '
                    if($f -and [int]$f.pid -eq $wire.A.Identity.PID -and $f.nonce -ceq $wire.A.PairNonce -and $f.gen -ceq $wire.Expected.Generation -and $f.slot -ceq '0' -and $f.recorder_challenge -ceq $original.RecorderChallenge -and [long]$f.tick_ms -ge $sent -and [long]$f.tick_ms -le [Environment]::TickCount64){return [pscustomobject]@{Cancelled=$true;Tick=[long]$f.tick_ms}}
                    Start-Sleep -Milliseconds 10
                }while([Environment]::TickCount64-$sent -lt 1000)
                throw 'Exact native capturecancel ACK unavailable; retain cleanup diagnostics.'
            }
        }
        # GetNewClosure creates a dynamic module. Retain the reviewed function
        # definitions explicitly; script-local helpers otherwise disappear once
        # this factory returns (and would incorrectly resolve future globals).
        $functions=@{};foreach($command in @(Get-Command -CommandType Function|Where-Object Name -Like '*-IW7*')){$functions[$command.Name]=$command.ScriptBlock}
        foreach($key in @($io.Keys)){
            $io[$key]=$io[$key].GetNewClosure()
            & $io[$key].Module {param($definitions)foreach($name in $definitions.Keys){Set-Item -Path ('Function:script:'+ $name) -Value $definitions[$name]}} $functions
        }
        $frames=@()
        foreach($name in @('A','B')){
            $frameRoot=Join-Path $CaseRoot ('voice-pre-action-'+$name);$null=New-Item -ItemType Directory -Path $frameRoot
            $frames+=Save-IW7AgentPreActionFrame $Pair.Sessions[$name] $frameRoot
        }
        [pscustomobject]@{Expected=$expected;IO=$io;Logs=$logs;Frames=$frames;Dispose={foreach($log in $logs.Values){$log.Stream.Dispose()}}.GetNewClosure()}
    }catch{foreach($log in $logs.Values){$log.Stream.Dispose()};throw}
}
