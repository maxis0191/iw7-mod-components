param([Parameter(Mandatory)][string]$WorkerPath)
$ErrorActionPreference='Stop'
$repo=(Resolve-Path "$PSScriptRoot/../..").Path
. "$repo/ops/Agent-Pair.Core.ps1"
. "$repo/ops/voice-agent/Recording.Core.ps1"
. "$repo/ops/voice-agent/Voice-Pair.Core.ps1"
. "$repo/ops/voice-agent/Recorder.Core.ps1"
function Check($v,$message){if(!$v){throw $message}}
function Refuses($body){$failed=$false;try{&$body|Out-Null}catch{$failed=$true};Check $failed 'Invalid recorder helper operation accepted.'}
$root=Join-Path ([IO.Path]::GetTempPath()) ('iw7-voice-recorder-helper-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root)|Out-Null
$scope=Join-Path $root 'scope';[IO.Directory]::CreateDirectory($scope)|Out-Null
$hash=(Get-FileHash -LiteralPath $WorkerPath).Hash;$self=Get-Process -Id $PID
try{$receiver=[pscustomobject]@{PID=$PID;Image=$self.Path;ImageSHA256=(Get-FileHash $self.Path).Hash;CreationFileTime=[uint64]$self.StartTime.ToFileTimeUtc()}}finally{$self.Dispose()}
$mock=@{Token=('a'*32);Scope=$scope;Kind='Runtime';PhysicalBytes=20GB;CommitBytes=20GB;Registered=@();RegistrationSamples=@();Refuse=$false;DelayMs=0}
# Mock only account-wide scheduling. Real worker PID/FILETIME/image, NTFS copy,
# watchdog handles, stdout identity and WAV validation remain exercised.
function Get-IW7ResourceStatus {[pscustomobject]@{Leases=@([pscustomobject]$mock)}}
function Add-IW7ResourceProcess {
    param($Token,$ProcessId)
    Check ($Token -ceq $mock.Token) 'Wrong runtime lease token.'
    $p=Get-Process -Id $ProcessId
    try{
        $identity=[IW7.VoicePairDraft.OwnedProbe]::CaptureIdentity($p.SafeHandle)
        Check ($identity.PID -eq $ProcessId -and $identity.Image.StartsWith($scope+'\',[StringComparison]::OrdinalIgnoreCase) -and !$identity.Exited) 'Global/out-of-scope recorder launched.'
        $mock.RegistrationSamples+=,$identity
    }finally{$p.Dispose()}
    if($mock.Refuse){throw 'Synthetic exact-registration refusal.'}
    if($mock.DelayMs){Start-Sleep -Milliseconds $mock.DelayMs}
    $mock.Registered+=,$ProcessId
}
try{
    Initialize-IW7AgentPairNtfs
    $out=Join-Path $root 'copy';[IO.Directory]::CreateDirectory($out)|Out-Null
    $helper=New-IW7VoiceRecorderHelperCopy $scope $WorkerPath $hash $out
    $source=[IO.File]::Open($WorkerPath,'Open','Read','Read');try{Check ([IW7AgentPairNtfs]::Identity($source.SafeFileHandle) -cne $helper.FileId) 'Recorder copy shares source NTFS identity.'}finally{$source.Dispose()}
    Check (!$helper.HardLinked -and (Get-FileHash $helper.Image).Hash -ceq $hash) 'Recorder source copy/hash mismatch.'
    $unknown=Join-Path $helper.Root 'foreign.txt';[IO.File]::WriteAllText($unknown,'preserve')
    Refuses{Restore-IW7VoiceRecorderHelperCopy $helper};Check (Test-Path $helper.Image) 'Unknown directory content caused partial cleanup.'
    [IO.File]::Delete($unknown);Restore-IW7VoiceRecorderHelperCopy $helper
    Check ($helper.Closed -and !(Test-Path $helper.Root)) 'Exact helper cleanup failed.'
    foreach($seconds in @(1,2)){
        $out=Join-Path $root ('run'+$seconds);[IO.Directory]::CreateDirectory($out)|Out-Null
        $record=Start-IW7VoicePairRecorder $receiver $WorkerPath $hash $out $seconds $mock.Token $scope
        Check ($record.LeaseRegistered -and $record.ProbeIdentity.PID -in $mock.Registered -and !$record.Task.IsCompleted) 'Registration missing before provider return.'
        $registered=@($mock.RegistrationSamples|Where-Object PID -EQ $record.ProbeIdentity.PID)[0]
        Check ($record.ProbeIdentity.Image -ceq $record.HelperLedger.Image -and $registered.Image -ceq $record.ProbeIdentity.Image -and
            $registered.CreationFileTime -eq $record.ProbeIdentity.CreationFileTime -and !$registered.Exited -and
            $registered.CapturedTick -le $record.ProbeIdentity.RegistrationDeadlineTick) 'Kernel handle identity differs before registration.'
        $deadline=[Environment]::TickCount64+3000L;$ready=$null
        do{$state=Get-IW7VoicePairRecorderState $record;$ready=Read-IW7VoiceRecorderReady $state.Stdout $receiver $record.StartedTick ([Environment]::TickCount64);if(!$ready){Start-Sleep -Milliseconds 10}}while(!$ready -and [Environment]::TickCount64 -lt $deadline)
        Check ($null -ne $ready) 'Real mock helper readiness was not observed.'
        if($seconds -eq 1){$result=Complete-IW7VoicePairRecorder $record;Check ($result.Completed -and $result.WAV.Frames -eq 1) 'Real valid PCM worker failed.'}
        else{Refuses{Complete-IW7VoicePairRecorder $record}}
        Check ($record.HelperLedger.Closed -and !(Test-Path $record.HelperLedger.Root) -and !(Get-Process -Id $record.ProbeIdentity.PID -ErrorAction SilentlyContinue)) 'Owned helper process/copy leaked.'
    }
    $mock.Refuse=$true;$out=Join-Path $root 'refused';[IO.Directory]::CreateDirectory($out)|Out-Null
    Refuses{Start-IW7VoicePairRecorder $receiver $WorkerPath $hash $out 3 $mock.Token $scope}
    Check (@(Get-ChildItem (Join-Path $scope 'voice-pair-helper') -Directory).Count -eq 0 -and (Get-Process -Id $PID)) 'Refused admission leaked helper or affected parent.'
    $mock.Refuse=$false;$mock.DelayMs=1100;$out=Join-Path $root 'expired-registration';[IO.Directory]::CreateDirectory($out)|Out-Null
    Refuses{Start-IW7VoicePairRecorder $receiver $WorkerPath $hash $out 3 $mock.Token $scope}
    Check (@(Get-ChildItem (Join-Path $scope 'voice-pair-helper') -Directory).Count -eq 0 -and
        !(Get-Process -Id $mock.RegistrationSamples[-1].PID -ErrorAction SilentlyContinue) -and (Get-Process -Id $PID)) 'Expired registration leaked helper or affected parent.'
    $mock.DelayMs=0;$mock.CommitBytes=19GB;$out=Join-Path $root 'bad-lease';[IO.Directory]::CreateDirectory($out)|Out-Null
    Refuses{Start-IW7VoicePairRecorder $receiver $WorkerPath $hash $out 1 $mock.Token $scope}
    Check (@(Get-ChildItem $out).Count -eq 0) 'Incomplete group reservation staged a helper.'
    'PASS recorder: real independent NTFS copy/hash/ledger, original kernel PID/image/creation/live identity and registration before ready within1000ms, valid/truncated WAV, refused/expired registration owned-handle closure, parent preserved, unknown-content and19GiB group refusal. Scheduler mocked; no audio/game.'
}finally{
    if(!$root.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase)){throw 'Test cleanup root escaped.'}
    Remove-Item -LiteralPath $root -Recurse -Force
}
