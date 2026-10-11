$ErrorActionPreference='Stop'
$repo=(Resolve-Path "$PSScriptRoot/../..").Path
. "$repo/ops/Agent-Pair.Core.ps1"
. "$repo/ops/Agent-Scenario.Core.ps1"
. "$repo/ops/voice-agent/Providers.Core.ps1"
function Check($value,$message){if(!$value){throw $message}}
function Refuses($action){$failed=$false;try{& $action|Out-Null}catch{$failed=$true};Check $failed 'Foreign/malformed draft provider accepted.'}
$root=Join-Path ([IO.Path]::GetTempPath()) ('iw7-voice-provider-test-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root)|Out-Null
$providers=$null
try{
    Initialize-IW7AgentPairNtfs
    # Real NTFS stdout records, exact ID retention and parser boundaries. Process
    # ownership/protection helpers alone are mocked: no native/audio/game calls.
    function Assert-IW7BaseIdentity {}
    function Get-IW7AgentPairLease {[pscustomobject]@{PhysicalBytes=20GB;CommitBytes=20GB}}
    function Update-IW7BaseClient($Context){
        if($Context.PSObject.Properties['TestOwnershipDelayMs']){
            Start-Sleep -Milliseconds $Context.TestOwnershipDelayMs
            foreach($path in $Context.TestPublishingLogs){
                $updated=[regex]::Replace([IO.File]::ReadAllText($path),'\b(query_tick|native_tick_ms|tick_ms)=\d+',
                    {param($match)$match.Groups[1].Value+'='+[Environment]::TickCount64})
                [IO.File]::WriteAllText($path,$updated)
            }
        }
        [pscustomobject]@{Protected=$true}
    }
    function Read-IW7AgentPairRoleSafety {}
    function Save-IW7AgentPreActionFrame {[pscustomobject]@{ReducedProfileValidated=$true;SyntheticTestOnly=$true}}
    function Read-IW7AgentResponse {$null}
    function Read-IW7AgentWire {''}
    $now=[Environment]::TickCount64;$generation='c'*32;$pair=[pscustomobject]@{Closed=$false;Generation=$generation;Sessions=@{};Server=[pscustomobject]@{PID=99;Stdout=(Join-Path $root 'server.stdout')};Plan=[pscustomobject]@{RunPlan=(Get-IW7LabRunPlan Reduced -PlannedClients 2 -EnableAudio)}}
    $serverText=''
    foreach($index in @(0,1)){
        $name=@('A','B')[$index];$pidValue=11+$index;$nonce=@(('a'*32),('b'*32))[$index];$gameRoot=Join-Path $root $name;[IO.Directory]::CreateDirectory("$gameRoot/iw7-mod")|Out-Null
        $stdout=Join-Path $root ($name+'.stdout')
        $pair.Sessions[$name]=[pscustomobject]@{Identity=[pscustomobject]@{PID=$pidValue;Image='C:\owned\iw7.exe';SHA256=('3'*64);CreatedUtc='2026-10-07T00:00:00Z';Stdout=$stdout};Handle=[pscustomobject]@{};PairNonce=$nonce;StartedTick=$now-1000;Plan=[pscustomobject]@{GameRoot=$gameRoot;ServerPort=27116;VoicePairSource=[pscustomobject]@{SHA256=('1'*64)}}}
        $state="[paris-voice-pair] STATE; pid=$pidValue; nonce=$nonce; gen=$generation; slot=$index; query_tick=$now; tick_ms=$now; relay_gen_low=5; relay_gen_high=7; both_ready=1; ui_ready=1; talk_valid=1; talk_key0=0; talk_key1=0; talk_active=0.`n"
        $descriptor="[paris-fake-capture] Observed pid=$pidValue tick_ms=$now prepared=1 armed=0 failed=0 buffer_started=1 locked=0 rate=16000 channels=1 bits=16 align=2 buffer_bytes=8192 source_frames=32000 published_frames=0 source_output_frames=0 nonzero_frames=0 lock_calls=2 lock_bytes=0 lock_nonzero_bytes=0 prepared_lock_bytes=320 unlock_calls=2 unlock_bytes=320`n"
        $relay="[voice-relay] version=2 installed=1 dedicated=0 ready=1 slot=$index encoded=0 sent=0 relayed=0 playback_calls=0 rejected=0 muted=0 accepted_joins=0 registrations=1 registration_attempts=1 registration_failures=0 roster_mask=3 native_mask=3 gate=ready voice_enabled=1 packets_received=20 hellos_sent=1 confirms_sent=1 server_running=0 eligible_mask=0 voice_peers_mask=0`n"
        [IO.File]::WriteAllText($stdout,$state+$descriptor+$relay)
        $serverText+="[Paris agent voice pair] READY; server_pid=99; client_nonce=$nonce; server_generation=$generation; slot=$index; native_tick_ms=$now; protected=1; down_fixture=0; ready=1.`n"
        $serverText+="[Paris agent voice pair] SAMPLE; server_pid=99; client_nonce=$nonce; server_generation=$generation; slot=$index; native_tick_ms=$now; protected=1; sample_id=$index; down_fixture=0; ready=1.`t`r`n"
    }
    [IO.File]::WriteAllText($pair.Server.Stdout,$serverText+"[voice-relay] version=2 installed=1 dedicated=1 ready=0 slot=-1 encoded=0 sent=0 relayed=0 playback_calls=0 rejected=0 muted=0 accepted_joins=2 registrations=0 registration_attempts=0 registration_failures=0 roster_mask=0 native_mask=0 gate=server voice_enabled=0 packets_received=10 hellos_sent=0 confirms_sent=0 server_running=1 eligible_mask=3 voice_peers_mask=3`n")
    $providers=New-IW7VoicePairProviders $pair $root 'C:\not-launched-probe.exe' ('5'*64) ('6'*64)
    # Provider construction/definition snapshots can take >500ms. Native main
    # continues publishing; emulate that real update with fresh same-file bytes.
    $fresh=[Environment]::TickCount64
    foreach($path in @($pair.Server.Stdout,$pair.Sessions.A.Identity.Stdout,$pair.Sessions.B.Identity.Stdout)){
        [IO.File]::WriteAllText($path,[IO.File]::ReadAllText($path).Replace([string]$now,[string]$fresh))
    }
    $now=$fresh
    $snapshot=& $providers.IO.Snapshot
    Check ($snapshot.FixtureReady -and $snapshot.Roles.Count -eq 2 -and $snapshot.Roles[1].V2Ready) 'Real STATE/SAMPLE parser did not bind both roles.'
    $ptt=& $providers.IO.PTTState;Check (!$ptt.Active -and $ptt.PID -eq 11) 'PTT exact getter state missing.'
    $capture=& $providers.IO.CaptureState;Check ($capture.BothPrepared -and $capture.DescriptorsValidated -and !$capture.SenderArmed) 'Native Prepared format was inferred incorrectly.'
    $counter=& $providers.IO.Counters;Check ($counter.DiagnosticPacketsReceived -eq 20 -and $counter.AcceptedNativePlaybackCalls -eq 0) 'Control packets mislabeled audio playback.'
    $before=[IO.File]::ReadAllText($pair.Sessions.A.Identity.Stdout)
    $unavailable=$before.Replace('nonce='+('a'*32),'nonce=none').Replace('gen='+$generation,'gen=none').Replace('query_tick='+$now,'query_tick=0').Replace('both_ready=1','both_ready=0')
    [IO.File]::WriteAllText($pair.Sessions.A.Identity.Stdout,$unavailable)
    $heldLog=Open-IW7VoiceOwnedLog $pair.Sessions.A.Identity.Stdout
    try{
        Check ($null -eq (Get-IW7VoiceStateFields $heldLog $pair.Sessions.A $now)) 'Explicit unavailable STATE must wait without granting readiness.'
        [IO.File]::WriteAllText($pair.Sessions.A.Identity.Stdout,$unavailable.Replace('pid=11','pid=99'))
        Refuses{Get-IW7VoiceStateFields $heldLog $pair.Sessions.A $now}
        [IO.File]::WriteAllText($pair.Sessions.A.Identity.Stdout,$unavailable.Replace('gen=none','gen='+$generation))
        Refuses{Get-IW7VoiceStateFields $heldLog $pair.Sessions.A $now}
        [IO.File]::WriteAllText($pair.Sessions.A.Identity.Stdout,$unavailable.Replace('tick_ms='+$now,'tick_ms=1'))
        Refuses{Get-IW7VoiceStateFields $heldLog $pair.Sessions.A $now}
    }finally{$heldLog.Stream.Dispose()}
    [IO.File]::WriteAllText($pair.Sessions.A.Identity.Stdout,$before.Replace('talk_valid=1','talk_valid=0'))
    Refuses{& $providers.IO.PTTState}
    [IO.File]::WriteAllText($pair.Sessions.A.Identity.Stdout,$before.Replace('query_tick='+$now,'query_tick=1'))
    Refuses{& $providers.IO.Snapshot}
    [IO.File]::WriteAllText($pair.Sessions.A.Identity.Stdout,$before.Replace('pid=11','pid=999'))
    Refuses{& $providers.IO.PTTState}
    [IO.File]::WriteAllText($pair.Sessions.A.Identity.Stdout,$before)
    Refuses{Read-IW7VoiceFields "[paris-voice-pair] STATE; pid=11; pid=12.`n" '[paris-voice-pair] STATE; '}
    $prefix='[paris-voice-pair] STATE; '
    Check ((Read-IW7VoiceFields ($prefix+"pid=11.`nconsole embedded "+$prefix+"pid=99.`n") $prefix).pid -ceq '11') 'Embedded prefix inside a console line treated as a native publication.'
    $largeLog=("ordinary loading line`n"*10000)+$prefix+"pid=11.`r`n"+$prefix+"pid=12.`t`r`n"
    Check ((Read-IW7VoiceFields $largeLog $prefix).pid -ceq '12') 'Latest exact publication after a long startup log lost.'
    # Log handle denies ordinary unlink/replacement; preserve evidence identity.
    Refuses{[IO.File]::Delete($pair.Sessions.A.Identity.Stdout)}
    # Reproduce actual blocking ownership audits while native main continues
    # publishing. The provider must reread both roles and the server afterward,
    # never relax freshness or reuse the transcript captured before the audits.
    foreach($name in @('A','B')){
        $pair.Sessions[$name]|Add-Member TestOwnershipDelayMs 300
        $pair.Sessions[$name]|Add-Member TestPublishingLogs @($pair.Server.Stdout,$pair.Sessions.A.Identity.Stdout,$pair.Sessions.B.Identity.Stdout)
    }
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $snapshot=& $providers.IO.Snapshot
    Check ($watch.ElapsedMilliseconds -ge 600 -and $snapshot.FixtureReady -and $snapshot.Roles.Count -eq 2) 'Fresh STATE/SAMPLE publication after blocking ownership audits rejected.'
    . "$repo/ops/voice-agent/Voice-Pair.Core.ps1"
    Assert-IW7VoicePairSnapshot $snapshot ([Environment]::TickCount64) $providers.Expected
    'PASS real retained native stdout parsers and closures: two-role ready, Prepared descriptor, PTT validity, stale/foreign binding and control-packet distinction. No game/audio.'
}finally{if($providers){& $providers.Dispose};Remove-Item -LiteralPath $root -Recurse -Force}
