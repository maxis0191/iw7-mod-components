param([Parameter(Mandatory)][string]$WorkerPath,[string]$RecorderSourceSHA256)
$ErrorActionPreference='Stop'
$repo=(Resolve-Path "$PSScriptRoot/../..").Path
. "$repo/ops/Resource-Scheduler.Core.ps1"
. "$repo/ops/Agent-Pair.Core.ps1"
. "$repo/ops/voice-agent/Recording.Core.ps1"
. "$repo/ops/voice-agent/Voice-Pair.Core.ps1"
. "$repo/ops/voice-agent/Recorder.Core.ps1"
. "$repo/ops/Resource-RecorderOwnedProcess.Core.ps1"
& "$repo/tests/ops/voice_pair_recorder_cleanup_test.ps1" -RepoRoot $repo
function Check($v,$message){if(!$v){throw $message}}
function Refuses($body){$failed=$false;try{&$body|Out-Null}catch{$failed=$true};Check $failed 'Invalid recorder helper operation accepted.'}
function Test-TerminalEvidencePolicy($Initial){
    # Pure factory: no native call or owner mutation. The input is the real
    # initial snapshot retained by the disposed test owner, never a PID reopen.
    $pidValue=$Initial.PID;$creation=$Initial.CreationFileTime;$image=$Initial.Image
    $resolve=[IW7.VoicePairDraft.ProbeTerminalEvidence].GetMethod('Resolve',[Reflection.BindingFlags]'Public,Static')
    function Invoke-TerminalResolve($Start,[int]$ChildId,[long]$Created,[bool]$Signaled,[uint32]$Code,[object]$QueriedImage,[int]$QueryError,[bool]$Guard,[long]$Tick){
        # PowerShell's direct string-parameter binder changes $null to "".
        # An explicit Object[] slot preserves the literal CLR null used by the
        # native C# caller; the production factory's strict rule stays intact.
        $values=[object[]]::new(9)
        $values[0]=$Start;$values[1]=$ChildId;$values[2]=$Created;$values[3]=$Signaled;$values[4]=$Code
        $values[5]=$QueriedImage;$values[6]=$QueryError;$values[7]=$Guard;$values[8]=$Tick
        if($null -eq $QueriedImage -and ![object]::ReferenceEquals($values[5],$null)){throw 'Literal CLR-null policy observation lost before reflection.'}
        return $resolve.Invoke($null,$values)
    }
    $query=Invoke-TerminalResolve $Initial $pidValue $creation $true ([uint32]0) $image 0 $true 1L
    Check ($query.ImageEvidenceMode -ceq 'terminal-kernel-query-and-retained-image-guard' -and $query.ImageQueryAfterExitSucceeded -eq $true -and $query.ImageQueryAfterExitWin32Error -eq 0) 'Successful query evidence mode differs.'
    $held=Invoke-TerminalResolve $Initial $pidValue $creation $true ([uint32]125) $null 31 $true 2L
    Check ($held.ImageEvidenceMode -ceq 'original-live-kernel-and-retained-image-guard' -and $held.ImageQueryAfterExitSucceeded -eq $false -and $held.ImageQueryAfterExitWin32Error -eq 31 -and $held.ExitCodeUInt32 -eq 125 -and $held.Image -ceq $image) 'Measured terminal image failure was fabricated as a successful query.'
    $status=Invoke-TerminalResolve $Initial $pidValue $creation $true ([uint32]3221225477) $null 31 $true 3L
    Check ($status.ExitCode -eq -1073741819 -and $status.ExitCodeUInt32 -eq 3221225477L) 'Terminal uint NTSTATUS representation differs.'
    Refuses {Invoke-TerminalResolve $null $pidValue $creation $true ([uint32]125) $null 31 $true 1L}
    Refuses {Invoke-TerminalResolve $Initial ($pidValue+1) $creation $true ([uint32]125) $null 31 $true 1L}
    Refuses {Invoke-TerminalResolve $Initial $pidValue ($creation+1) $true ([uint32]125) $null 31 $true 1L}
    Refuses {Invoke-TerminalResolve $Initial $pidValue $creation $false ([uint32]125) $null 31 $true 1L}
    Refuses {Invoke-TerminalResolve $Initial $pidValue $creation $true ([uint32]125) $null 31 $false 1L}
    Refuses {Invoke-TerminalResolve $Initial $pidValue $creation $true ([uint32]125) ($image+'.wrong') 0 $true 1L}
    Refuses {Invoke-TerminalResolve $Initial $pidValue $creation $true ([uint32]125) $null 0 $true 1L}
    Refuses {Invoke-TerminalResolve $Initial $pidValue $creation $true ([uint32]125) $null -1 $true 1L}
    Refuses {Invoke-TerminalResolve $Initial $pidValue $creation $true ([uint32]125) $image 31 $true 1L}
    Refuses {Invoke-TerminalResolve $Initial $pidValue $creation $true ([uint32]125) '' 31 $true 1L}
    $copy=[IW7.VoicePairDraft.ProbeIdentity]::new()
    foreach($property in $Initial.GetType().GetProperties()){$setter=$property.GetSetMethod($true);if($setter){$null=$setter.Invoke($copy,[object[]]@($property.GetValue($Initial)))}}
    $setter=$copy.GetType().GetProperty('ImageEvidenceMode').GetSetMethod($true);$null=$setter.Invoke($copy,[object[]]@('terminal-kernel-query'))
    Refuses {Invoke-TerminalResolve $copy $pidValue $creation $true ([uint32]125) $null 31 $true 1L}
    $null=$setter.Invoke($copy,[object[]]@('live-kernel-query'));$hashSetter=$copy.GetType().GetProperty('ImageSHA256').GetSetMethod($true);$null=$hashSetter.Invoke($copy,[object[]]@('G'*64))
    Refuses {Invoke-TerminalResolve $copy $pidValue $creation $true ([uint32]125) $null 31 $true 1L}
}
function Test-RecorderAdmissionTypePolicy([IO.FileStream]$SourceGuard,[string]$SourceSHA256){
    # Run only after an admitted source compilation. Prepare and rejected
    # pre-start methods allocate no process, pipe, native handle or image file.
    $type=[IW7.VoicePairDraft.ProbeAdmission];$count=[ref]0
    function Verify-TypePolicy($Value,[string]$Message){$count.Value++;if(!$Value){throw $Message}}
    function Refuse-TypePolicy([scriptblock]$Action,[string]$Message){$failed=$false;try{&$Action|Out-Null}catch{$failed=$true};Verify-TypePolicy $failed $Message}
    Verify-TypePolicy ($type.IsSealed -and @($type.GetConstructors()).Count -eq 0) 'Original recorder constructor became public.'
    foreach($name in @('AdmissionWitness','RegistrationPermit')){
        $nested=$type.GetNestedType($name,[Reflection.BindingFlags]'Public')
        Verify-TypePolicy ($nested.IsSealed -and @($nested.GetConstructors()).Count -eq 0 -and @($nested.GetFields([Reflection.BindingFlags]'Instance,NonPublic,Public')|Where-Object {!$_.IsInitOnly}).Count -eq 0) 'Opaque recorder witness/permit is not readonly.'
    }
    Verify-TypePolicy (@($type.GetMethods()|Where-Object {$_.Name -ceq 'Admit' -and $_.GetParameters().Count -ne 3}).Count -eq 0) 'Parameterless/unpinned recorder admission remains available.'
    $scope=Join-Path ([IO.Path]::GetTempPath()) 'pure-recorder-constructor';$image=Join-Path $scope ('voice-pair-helper/'+('a'*32)+'/receiver-probe.exe')
    $stdout=Join-Path $scope 'stdout.log';$stderr=Join-Path $scope 'stderr.log';$provider=[pscustomobject]@{TestOnly=$true}
    $arguments=[string[]]@('--record','1','1','1','C:\pure-receiver.exe',('B'*64),'C:\pure-receiver.wav')
    $prepare=$type.GetMethod('Prepare',[Reflection.BindingFlags]'Public,Static')
    # MethodInfo.Invoke does not unwrap PowerShell pipeline PSObjects inside
    # Object[]. Cast every CLR value explicitly, including Join-Path outputs;
    # the direct production static-method binder performs this conversion.
    $values=[object[]]@([string]$scope,[string]$image,[string]('A'*64),[string[]]$arguments,[string]$stdout,[string]$stderr,[int]16,
        $provider,[string]('b'*32),[string]$SourceSHA256,[string]'1234ABCD:0000000000000001',$SourceGuard,[string]('c'*32))
    $owner=$prepare.Invoke($null,$values)
    Verify-TypePolicy (!$owner.HasProcess -and $owner.NoProcessCreatedConfirmed -and !$owner.ResumeAttempted -and !$owner.Accepted) 'Pure construction created/admitted a child.'
    Refuse-TypePolicy {$owner.CaptureAdmissionWitness()} 'Unstarted owner minted an original witness.'
    Refuse-TypePolicy {$owner.CreateRegistrationPermit($null,('c'*32),$provider)} 'Missing original witness minted permit.'
    Refuse-TypePolicy {$owner.Admit($null,$null,$null)} 'No-child/null permit admitted execution.'
    foreach($index in @(0,1,2,7,8,9,10,11,12)){
        $bad=[object[]]$values.Clone()
        switch($index){0{$bad[0]=[string]'relative'} 1{$bad[1]=[string](Join-Path $scope 'foreign.exe')} 2{$bad[2]=[string]'invalid'} 7{$bad[7]=$null} 8{$bad[8]=[string]'invalid'} 9{$bad[9]=[string]'invalid'} 10{$bad[10]=[string]'invalid'} 11{$bad[11]=$null} 12{$bad[12]=[string]'invalid'}}
        Refuse-TypePolicy {$prepare.Invoke($null,$bad)} 'Foreign source/helper/provider/token construction accepted.'
    }
    $owner.DisposeChecked()
    Verify-TypePolicy ($owner.OwnershipResolved -and $SourceGuard.CanRead) 'Pure no-child disposal discarded the separately owned source guard.'
    [pscustomobject]@{Passed=$true;Checks=$count.Value;NativeProcessCreated=$false;SourceGuardRetained=$true;OwnershipVersion=3}
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('iw7-voice-recorder-helper-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root)|Out-Null
$scope=Join-Path $root 'scope';[IO.Directory]::CreateDirectory($scope)|Out-Null
$hash=(Get-FileHash -LiteralPath $WorkerPath).Hash;$self=Get-Process -Id $PID
try{$receiver=[pscustomobject]@{PID=$PID;Image=$self.Path;ImageSHA256=(Get-FileHash $self.Path).Hash;CreationFileTime=[uint64]$self.StartTime.ToFileTimeUtc()};$hostIdentity=[pscustomobject]@{PID=$PID;Image=$self.Path;CreatedUtc=$self.StartTime.ToUniversalTime().ToString('o')}}finally{$self.Dispose()}
# Only this explicit test fixture may derive its local source pin. Production
# callers and the genuine20/20 harness supply a separately reviewed exact pin.
if(!$RecorderSourceSHA256){$RecorderSourceSHA256=(Get-FileHash "$repo/ops/voice-agent/Recorder-Probe.cs").Hash}
$mock=@{Token=('a'*32);Scope=$scope;Kind='Runtime';PhysicalBytes=20GB;CommitBytes=20GB;OwnerIdentity=$hostIdentity;Processes=@();Phase='Pending';Registered=@();RegistrationSamples=@();Refuse=$false;DelayMs=0}
# Mock only account-wide scheduling. Real worker PID/FILETIME/image, NTFS copy,
# watchdog handles, stdout identity and WAV validation remain exercised.
function Get-IW7ResourceStatus {[pscustomobject]@{Leases=@([pscustomobject]$mock)}}
function Invoke-IW7ResourceLock([scriptblock]$Body){&$Body}
function Read-IW7ResourceState {[pscustomobject]@{Leases=@([pscustomobject]$mock)}}
function Get-IW7ResourceProcesses {
    # Passive inventory only. No child PID is reopened as an owned handle.
    $rows=@(Get-CimInstance Win32_Process -Filter "ProcessId=$PID OR Name='receiver-probe.exe'" -OperationTimeoutSec 5 -ErrorAction Stop|ForEach-Object{
        [pscustomobject]@{PID=[int]$_.ProcessId;Image=$_.ExecutablePath;CreatedUtc=$(if($_.CreationDate){$_.CreationDate.ToUniversalTime().ToString('o')})}
    })
    if(@($rows|Where-Object PID -NE $PID).Count){
        if($mock.Refuse){throw 'Synthetic exact-registration refusal.'}
        if($mock.DelayMs){Start-Sleep -Milliseconds $mock.DelayMs}
    }
    $rows
}
function Save-IW7ResourceState($State){
    $mock.Processes=@($State.Leases[0].Processes);$mock.Phase=$State.Leases[0].Phase
    $mock.Registered=@($mock.Processes|ForEach-Object PID)
    $mock.RegistrationSamples=@($mock.Processes|ForEach-Object{$r=$_.OwnedAdmission;[pscustomobject]@{PID=$r.PID;Image=$r.Image;CreationFileTime=$r.CreationFileTime;CapturedTick=$r.CapturedTick;Exited=$false}})
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
    foreach($seconds in @(1,2,4)){
        $out=Join-Path $root ('run'+$seconds);[IO.Directory]::CreateDirectory($out)|Out-Null
        $record=Start-IW7VoicePairRecorder $receiver $WorkerPath $hash $out $seconds $mock.Token $scope $RecorderSourceSHA256
        Check ($record.Owner.Accepted -and !$record.Owner.OwnershipResolved -and $record.InitialReceipt -and
            (Get-FileHash $record.InitialReceipt.Path).Hash -ceq $record.InitialReceipt.SHA256) 'Original suspended/admission receipt missing or altered.'
        Check ($record.LeaseRegistered -and $record.ProbeIdentity.PID -in $mock.Registered) 'Registration missing before provider return.'
        $registered=@($mock.RegistrationSamples|Where-Object PID -EQ $record.ProbeIdentity.PID)[0]
        Check ($record.ProbeIdentity.Image -ceq $record.HelperLedger.Image -and $registered.Image -ceq $record.ProbeIdentity.Image -and
            $registered.CreationFileTime -eq $record.ProbeIdentity.CreationFileTime -and !$registered.Exited -and
            $registered.CapturedTick -le $record.ProbeIdentity.RegistrationDeadlineTick) 'Kernel handle identity differs before registration.'
        if($seconds -eq 4){
            Check ($record.Owner.Wait(5000)) 'Immediate worker did not exit.'
            $state=Get-IW7VoicePairRecorderState $record
            Check ($state.Exited -and $state.OwnedIdentityValidated -and $state.Original.RetainedImageGuardVerified) 'Exited original recorder cannot be polled with terminal evidence.'
        }else{
            $deadline=[Environment]::TickCount64+3000L;$ready=$null
            do{$state=Get-IW7VoicePairRecorderState $record;$ready=Read-IW7VoiceRecorderReady $state.Stdout $receiver $record.StartedTick ([Environment]::TickCount64);if(!$ready){Start-Sleep -Milliseconds 10}}while(!$ready -and [Environment]::TickCount64 -lt $deadline)
            Check ($null -ne $ready -and !$state.Exited) 'Real mock helper live readiness was not observed.'
            if($seconds -eq 1){$policy=Test-RecorderAdmissionTypePolicy $record.SourceProvider.SourceGuard $RecorderSourceSHA256;Check $policy.Passed 'Actual compiled recorder source type policy failed.'}
            [IO.File]::WriteAllText((Join-Path $out 'receiver.wav.release'),'release')
        }
        if($seconds -in @(1,4)){
            $result=Complete-IW7VoicePairRecorder $record;Check ($result.Completed -and $result.WAV.Frames -eq 1) 'Real valid PCM worker failed.'
            Check ($record.OwnershipResolved -and $record.Owner.OwnershipResolved -and $record.Closure.Terminal.Exited -and
                $record.Closure.Terminal.OriginalHandleWaitSignaled -and $record.Closure.Terminal.ExitCode -eq 0 -and
                $record.Closure.Original.PID -eq $result.Probe.PID -and $record.Closure.Terminal.CreationFileTime -eq $result.Probe.CreationFileTime -and
                $record.Closure.Terminal.ImageSHA256 -ceq $hash -and $result.ProducerOutputClosed -and
                (Get-FileHash $record.ClosureReceipt.Path).Hash -ceq $record.ClosureReceipt.SHA256 -and
                (Get-FileHash $record.ResultReceipt.Path).Hash -ceq $record.ResultReceipt.SHA256 -and
                (Get-FileHash $result.WAVPath).Hash -ceq $result.WAVSHA256) 'Real recorder result/WAV not pinned to original terminal/EOF closure.'
            Refuses {$writer=[IO.File]::Open($result.WAVPath,'Open','Write','ReadWrite');$writer.Dispose()} # retained WAV is immutable through analysis
            Check ($record.Closure.RetainedImageGuardVerified -and $result.Probe.ImageEvidenceMode -ceq $record.Closure.ImageEvidenceMode -and
                $result.Probe.ExitCodeUInt32 -eq $record.Closure.Terminal.ExitCodeUInt32) 'Actual result omitted or differs from explicit original terminal image/uint evidence.'
            Test-TerminalEvidencePolicy $record.Owner.Original
        }
        else{Refuses{Complete-IW7VoicePairRecorder $record}}
        Check ($record.HelperLedger.OwnerResolved -and $record.Owner.OwnershipResolved -and $record.SourceProvider.SourceGuard.CanRead -and !$record.SourceClosed) 'Original cleanup closed shared source before all test cases/WAV readers.'
        Check ($record.HelperLedger.Closed -and !(Test-Path $record.HelperLedger.Root) -and !(Get-Process -Id $record.ProbeIdentity.PID -ErrorAction SilentlyContinue)) 'Owned helper process/copy leaked.'
    }
    $mock.Refuse=$true;$out=Join-Path $root 'refused';[IO.Directory]::CreateDirectory($out)|Out-Null
    Refuses{Start-IW7VoicePairRecorder $receiver $WorkerPath $hash $out 3 $mock.Token $scope $RecorderSourceSHA256}
    Check (@(Get-ChildItem (Join-Path $scope 'voice-pair-helper') -Directory).Count -eq 0 -and (Get-Process -Id $PID)) 'Refused admission leaked helper or affected parent.'
    $mock.Refuse=$false;$mock.DelayMs=1100;$out=Join-Path $root 'expired-registration';[IO.Directory]::CreateDirectory($out)|Out-Null
    Refuses{Start-IW7VoicePairRecorder $receiver $WorkerPath $hash $out 3 $mock.Token $scope $RecorderSourceSHA256}
    Check (@(Get-ChildItem (Join-Path $scope 'voice-pair-helper') -Directory).Count -eq 0 -and
        (Get-Process -Id $PID)) 'Expired registration leaked helper or affected parent.'
    $mock.DelayMs=0;$mock.CommitBytes=19GB;$out=Join-Path $root 'bad-lease';[IO.Directory]::CreateDirectory($out)|Out-Null
    Refuses{Start-IW7VoicePairRecorder $receiver $WorkerPath $hash $out 1 $mock.Token $scope $RecorderSourceSHA256}
    Check (@(Get-ChildItem $out).Count -eq 0) 'Incomplete group reservation staged a helper.'
    $mock.CommitBytes=20GB
    Wait-IW7VoiceRecorderCleanup -CaseRoot $root -LeaseToken $mock.Token
    foreach($closed in @(Get-IW7VoiceRecorderOwners $root $mock.Token)){Check ($closed.SourceClosed -and $closed.SourceClosureReceipt -and !$closed.WAVHandle) 'Final parent gate omitted source/WAV closure.'}
    'PASS recorder: two-phase original owner, suspended kernel tuple, independent NTFS image, registration before execution within1000ms, pinned Original+Terminal+EOF closure/result/WAV, explicit readiness/release handshake, normal exit before state polling, valid/truncated WAV, refused/expired registration checked cleanup, fault/disposal recovery gate, parent preserved, unknown-content and19GiB group refusal. Scheduler mocked; no audio/game.'
}finally{
    Wait-IW7VoiceRecorderCleanup -CaseRoot $root -LeaseToken $mock.Token
    if(!$root.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase)){throw 'Test cleanup root escaped.'}
    Remove-Item -LiteralPath $root -Recurse -Force
}
