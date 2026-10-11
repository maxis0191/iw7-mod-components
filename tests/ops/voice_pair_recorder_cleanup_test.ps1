param([string]$RepoRoot=(Resolve-Path "$PSScriptRoot/../..").Path)
$ErrorActionPreference='Stop'
. "$RepoRoot/ops/voice-agent/Recorder.Core.ps1"
. "$RepoRoot/ops/Base-Client.Core.ps1"
$checks=0
function Check($Value,[string]$Message){$script:checks++;if(!$Value){throw $Message}}
function Refuses([scriptblock]$Action,[string]$Message){$refused=$false;try{&$Action|Out-Null}catch{$refused=$true};Check $refused $Message}
function Get-IW7ResourceRecorderProviderEvidence($Provider){[pscustomobject]@{ProviderId=$Provider.Id;State=$Provider.State}}
function Close-IW7ResourceRecorderProvider($Provider,[string]$Token){
    $trace.Add('SourceClose');$Provider.CloseCalls++
    if($Provider.CloseFailures -gt 0){$Provider.CloseFailures--;throw 'Original source guard disposal unconfirmed.'}
    $Provider.State='Closed'
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('iw7-recorder-cleanup-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root)|Out-Null
$trace=[Collections.Generic.List[string]]::new()
$registry=Get-IW7VoiceRecorderRegistry
$previousRegistry=@{};foreach($key in $registry.Keys){$previousRegistry[$key]=$registry[$key]}
$registry.Clear()
$originalRestore=(Get-Command Restore-IW7VoiceRecorderHelperCopy).ScriptBlock
$originalFileId=(Get-Command Get-IW7VoiceRecorderOwnerFileId).ScriptBlock
$originalSleep=(Get-Command Start-Sleep).ScriptBlock
$deleteDependencies=@{};foreach($name in @('Get-IW7VoiceRecorderDeleteIdentity','Get-IW7VoiceRecorderDirectoryIdentity','Open-IW7VoiceRecorderDeleteHandle',
    'New-IW7VoiceRecorderDeleteStream','Set-IW7VoiceRecorderDeleteDisposition','Close-IW7VoiceRecorderDeleteImage')){$deleteDependencies[$name]=(Get-Command $name).ScriptBlock}
$partialLedgers=[Collections.Generic.List[object]]::new()
$nativeInitCommand=Get-Command Initialize-IW7AgentPairNtfs -ErrorAction SilentlyContinue
$nativeInitDefinition=if($nativeInitCommand){$nativeInitCommand.ScriptBlock}else{$null}
function New-TestDeleteLedger([string]$Name){
    $scope=Join-Path $root ('delete-'+$Name);$directory=Join-Path $scope ('voice-pair-helper/'+[guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($directory)|Out-Null;$image=Join-Path $directory 'receiver-probe.exe';[IO.File]::WriteAllBytes($image,[byte[]](1..16))
    $state=[pscustomobject]@{Directory=$directory;Image=$image;DirectoryId='original-directory';ImageId='original-image';
        ImageOpens=0;DirectoryOpens=0;ImageMarks=0;DirectoryMarks=0;ImageCloseFailures=0;DirectoryMarkFailures=0;DirectoryCloseFailures=0}
    $ledger=[pscustomobject]@{Schema='iw7.voice-recorder-helper/1';Scope=$scope;Root=$directory;Image=$image;SHA256=(Get-FileHash $image).Hash;Bytes=16;
        FileId=$state.ImageId;DirectoryId=$state.DirectoryId;Closed=$false;OwnerRequired=$true;OwnerResolved=$true;CleanupPhase='ImagePresent';
        ImageDeleteHandle=$null;ImageDeleteStream=$null;DirectoryDeleteHandle=$null;ImageDispositionProof=$null;ImageDeletionProof=$null;DirectoryDispositionProof=$null}
    $partialLedgers.Add($ledger);return [pscustomobject]@{Ledger=$ledger;State=$state}
}
function New-TestIdentity([string]$Image,[bool]$Exited=$false){
    [pscustomobject]@{PID=123;CreationFileTime=133000000000000001L;Image=$Image;ImageSHA256=('A'*64);Exited=$Exited;
        CapturedTick=1000L;RegistrationDeadlineTick=2000L;OriginalHandleWaitSignaled=$Exited;ExitCode=0;ExitCodeUInt32=[uint32]0;
        ImageEvidenceMode=$(if($Exited){'terminal-kernel-query-and-retained-image-guard'}else{'live-kernel-query'});
        ImageQueryAfterExitSucceeded=$(if($Exited){$true}else{$null});ImageQueryAfterExitWin32Error=$(if($Exited){0}else{$null});RetainedImageGuardVerified=$Exited}
}
function New-TestRecorder([string]$Name){
    $output=Join-Path $root $Name;[IO.Directory]::CreateDirectory($output)|Out-Null
    $image=Join-Path $output 'receiver-probe.exe'
    $owner=[pscustomobject]@{HasProcess=$true;NoProcessCreatedConfirmed=$false;OwnershipResolved=$false;Original=(New-TestIdentity $image);
        Terminal=$null;Result=$null;CloseFailures=0;DisposeFailures=0;IdentityMismatch=$false;EOFRefused=$false;Live=$true;WaitCalls=0;ExitCode=0;
        ImageQueryFails=$false;ImageEvidenceInvalid=$false;ImageGuardMissing=$false;ExitUIntMismatch=$false}
    $owner|Add-Member ScriptMethod CloseOriginal {
        $trace.Add('OriginalClose')
        if($this.CloseFailures -gt 0){$this.CloseFailures--;throw 'Original termination unconfirmed.'}
        if($this.EOFRefused){throw 'Original producer EOF unconfirmed.'}
        $this.Live=$false;$this.Terminal=New-TestIdentity $this.Original.Image $true;$this.Terminal.ExitCode=$this.ExitCode
        $this.Terminal.ExitCodeUInt32=[uint32]([long]$this.ExitCode -band 0xffffffffL)
        if($this.ImageQueryFails){$this.Terminal.ImageEvidenceMode='original-live-kernel-and-retained-image-guard';$this.Terminal.ImageQueryAfterExitSucceeded=$false;$this.Terminal.ImageQueryAfterExitWin32Error=31}
        if($this.ImageEvidenceInvalid){$this.Terminal.ImageQueryAfterExitWin32Error=0}
        if($this.ImageGuardMissing){$this.Terminal.RetainedImageGuardVerified=$false}
        if($this.ExitUIntMismatch){$this.Terminal.ExitCodeUInt32=0}
        if($this.IdentityMismatch){$this.Terminal.CreationFileTime++}
        $this.Result=[pscustomobject]@{PID=123;CreationFileTime=133000000000000001L;ExitCode=$this.ExitCode;ProducerOutputClosed=$true;
            OriginalHandleWaitSignaled=$true;TimedOut=$false;LogBoundExceeded=$false;Failure=$null;
            ExitCodeUInt32=$this.Terminal.ExitCodeUInt32;ImageEvidenceMode=$this.Terminal.ImageEvidenceMode;ImageQueryAfterExitSucceeded=$this.Terminal.ImageQueryAfterExitSucceeded;
            ImageQueryAfterExitWin32Error=$this.Terminal.ImageQueryAfterExitWin32Error;RetainedImageGuardVerified=$this.Terminal.RetainedImageGuardVerified}
        return $this.Result
    }
    $owner|Add-Member ScriptMethod DisposeChecked {
        $trace.Add('CheckedDispose')
        if($this.DisposeFailures -gt 0){$this.DisposeFailures--;throw 'Checked disposal unconfirmed.'}
        if(!$this.NoProcessCreatedConfirmed -and (!$this.Terminal -or !$this.Result.ProducerOutputClosed -or $this.Live)){throw 'No exact closure proof.'}
        $this.OwnershipResolved=$true
    }
    $owner|Add-Member ScriptMethod Wait {param($Milliseconds)$this.WaitCalls++;$trace.Add('OriginalWait');return !$this.Live}
    $owner|Add-Member ScriptMethod CaptureIdentity {return New-TestIdentity $this.Original.Image (!$this.Live)}
    [pscustomobject]@{Owner=$owner;Task=[Threading.Tasks.Task]::FromException([Exception]::new('Synthetic faulted task'));
        OutputRoot=$output;LeaseToken=('b'*32);ProbeIdentity=$owner.Original;HelperLedger=[pscustomobject]@{Image=$image;SHA256=('A'*64);FileId='physical-original';
            Closed=$false;OwnerRequired=$true;OwnerResolved=$false};OutputHandle=$null;WAVHandle=$null;WAVFileHandle=$null;ReceiptIndex=0;InitialReceipt=$null;
        ClosureReceipt=$null;Closure=$null;OwnershipResolved=$false;CleanupError=$null;RecoveryAttempts=0;Finished=$false;Result=$null;ResultReceipt=$null;Failure=$null;
        WAVPath=(Join-Path $output 'receiver.wav');SourceProvider=[pscustomobject]@{Id=[guid]::NewGuid().ToString('N');State='Ready';CloseCalls=0;CloseFailures=0};
        SourceClosed=$false;SourceReceipt=$null;SourceClosureReceipt=$null;RegistrationEvidence=$null;AdmissionReceipt=$null}
}
try{
    # Exercise NewHelperCopy itself on real empty long candidate directories.
    # The supplied probe does not exist: a valid named geometry refusal must
    # happen before source open, NTFS init, helper mkdir or copy writes.
    $script:nativeInitCalls=0
    function Initialize-IW7AgentPairNtfs {$script:nativeInitCalls++;throw 'Forbidden native initialization during pure geometry test.'}
    Assert-IW7VoiceRecorderHelperGeometry ('C:\'+('a'*244)) ('C:\'+('b'*256))
    Check $true 'Exact247/259 path boundaries were refused.'
    Refuses {Assert-IW7VoiceRecorderHelperGeometry ('C:\'+('a'*245)) ('C:\'+('b'*256))} 'Directory248 characters accepted.'
    Refuses {Assert-IW7VoiceRecorderHelperGeometry ('C:\'+('a'*244)) ('C:\'+('b'*257))} 'Image260 characters accepted.'
    foreach($scopeLength in @(190,210)){
        $padding=$scopeLength-$root.Length-1;Check ($padding -gt 0 -and $padding -le 255) 'Pure long-path fixture geometry invalid.'
        $longScope=Join-Path $root ('g'*$padding);[IO.Directory]::CreateDirectory($longScope)|Out-Null
        $expected=if($scopeLength -eq 190){'Recorder helper executable exceeds native path bound:'}else{'Recorder helper directory exceeds native path bound:'}
        $caught=$null
        try{New-IW7VoiceRecorderHelperCopy $longScope (Join-Path $root 'nonexistent-probe.exe') ('A'*64) $root|Out-Null}catch{$caught=$_}
        Check ($caught -and $caught.Exception.Message.StartsWith($expected,[StringComparison]::Ordinal)) 'NewHelperCopy failed for another reason before its geometry guard.'
        Check ($script:nativeInitCalls -eq 0 -and @(Get-ChildItem -LiteralPath $longScope -Force).Count -eq 0 -and !(Test-Path (Join-Path $longScope 'voice-pair-helper'))) 'Overlong helper initialized native code or created/copy-wrote a helper.'
    }
    if($nativeInitDefinition){Set-Item Function:Initialize-IW7AgentPairNtfs $nativeInitDefinition}else{Remove-Item Function:Initialize-IW7AgentPairNtfs}
    # Exercise the real cleanup guard before substituting filesystem deletion.
    Refuses {Restore-IW7VoiceRecorderHelperCopy ([pscustomobject]@{Closed=$false;OwnerRequired=$true;OwnerResolved=$false})} 'Helper deletion accepted an unresolved original owner.'
    # Exercise the REAL helper cleanup state machine. Only NTFS syscall
    # dependencies are replaced; real temporary file/dir presence and SHA bytes
    # are checked. No NTFS compiler, process, game or resource API is invoked.
    function Get-IW7VoiceRecorderDirectoryIdentity([string]$Path){if($Path -ine $fs.Directory -or !(Test-Path -LiteralPath $Path -PathType Container)){throw 'Directory missing/replaced.'};return $fs.DirectoryId}
    function Get-IW7VoiceRecorderDeleteIdentity($Handle){return $Handle.Identity}
    function Open-IW7VoiceRecorderDeleteHandle([string]$Path){
        $kind=if($Path -ieq $fs.Image){$fs.ImageOpens++;'Image'}elseif($Path -ieq $fs.Directory){$fs.DirectoryOpens++;'Directory'}else{throw 'Unexpected delete path.'}
        $handle=[pscustomobject]@{Path=$Path;Kind=$kind;Identity=$(if($kind -ceq 'Image'){$fs.ImageId}else{$fs.DirectoryId});IsClosed=$false;State=$fs}
        $handle|Add-Member ScriptMethod Dispose {
            if($this.Kind -ceq 'Directory' -and $this.State.DirectoryCloseFailures -gt 0){$this.State.DirectoryCloseFailures--;throw 'Directory original handle close failed.'}
            $this.IsClosed=$true
        };return $handle
    }
    function New-IW7VoiceRecorderDeleteStream($Handle){return [IO.MemoryStream]::new([IO.File]::ReadAllBytes($Handle.Path))}
    function Set-IW7VoiceRecorderDeleteDisposition($Handle){
        if($Handle.IsClosed){throw 'Closed original delete handle.'}
        if($Handle.Kind -ceq 'Image'){$Handle.State.ImageMarks++;[IO.File]::Delete($Handle.Path)}
        else{$Handle.State.DirectoryMarks++;if($Handle.State.DirectoryMarkFailures -gt 0){$Handle.State.DirectoryMarkFailures--;throw 'Directory disposition failed.'};[IO.Directory]::Delete($Handle.Path,$false)}
    }
    function Close-IW7VoiceRecorderDeleteImage($Stream,$Handle){
        if($Handle.State.ImageCloseFailures -gt 0){$Handle.State.ImageCloseFailures--;throw 'Image original stream closure failed.'}
        $Stream.Dispose();$Handle.IsClosed=$true
    }
    $partial=New-TestDeleteLedger 'directory-mark';$fs=$partial.State;$fs.DirectoryMarkFailures=1
    Refuses {Restore-IW7VoiceRecorderHelperCopy $partial.Ledger} 'Directory disposition failure accepted.'
    Check ($partial.Ledger.CleanupPhase -ceq 'ImageDeleted' -and $partial.Ledger.ImageDeletionProof.OriginalFileHandleClosed -and
        !(Test-Path $partial.Ledger.Image) -and (Test-Path $partial.Ledger.Root) -and !$partial.Ledger.Closed) 'Partial image deletion proof/phase lost.'
    $dirHandle=$partial.Ledger.DirectoryDeleteHandle;Restore-IW7VoiceRecorderHelperCopy $partial.Ledger
    Check ($partial.Ledger.Closed -and $partial.Ledger.CleanupPhase -ceq 'Closed' -and $dirHandle.IsClosed) 'Directory retry did not finish checked cleanup.'
    Check ($fs.ImageMarks -eq 1 -and $fs.DirectoryMarks -eq 2 -and $fs.ImageOpens -eq 1 -and $fs.DirectoryOpens -eq 1) 'Partial retry reopened/redeleted an absent image or original directory.'
    $partial=New-TestDeleteLedger 'image-close';$fs=$partial.State;$fs.ImageCloseFailures=1
    Refuses {Restore-IW7VoiceRecorderHelperCopy $partial.Ledger} 'Image handle closure failure accepted.'
    $imageHandle=$partial.Ledger.ImageDeleteHandle
    Check ($partial.Ledger.CleanupPhase -ceq 'ImageDeleteMarked' -and !$imageHandle.IsClosed -and $partial.Ledger.ImageDeleteStream -and !(Test-Path $partial.Ledger.Image)) 'Marked original image handle/stream discarded.'
    Restore-IW7VoiceRecorderHelperCopy $partial.Ledger
    Check ($partial.Ledger.Closed -and $imageHandle.IsClosed -and $fs.ImageOpens -eq 1 -and $fs.ImageMarks -eq 1) 'Image closure retry lost original disposition ownership.'
    $partial=New-TestDeleteLedger 'directory-close';$fs=$partial.State;$fs.DirectoryCloseFailures=1
    Refuses {Restore-IW7VoiceRecorderHelperCopy $partial.Ledger} 'Directory handle closure failure accepted.'
    $dirHandle=$partial.Ledger.DirectoryDeleteHandle
    Check ($partial.Ledger.CleanupPhase -ceq 'DirectoryDeleteMarked' -and !$dirHandle.IsClosed -and !(Test-Path $partial.Ledger.Root)) 'Absent marked directory lost original handle proof.'
    Restore-IW7VoiceRecorderHelperCopy $partial.Ledger
    Check ($partial.Ledger.Closed -and $dirHandle.IsClosed -and $fs.DirectoryOpens -eq 1 -and $fs.DirectoryMarks -eq 1) 'Directory closure retry depended on reopening an absent path.'
    $partial=New-TestDeleteLedger 'missing-unproven';$fs=$partial.State;[IO.File]::Delete($partial.Ledger.Image)
    Refuses {Restore-IW7VoiceRecorderHelperCopy $partial.Ledger} 'Unproven image absence accepted as deletion.'
    $partial.Ledger.CleanupPhase='ImageDeleted'
    Refuses {Restore-IW7VoiceRecorderHelperCopy $partial.Ledger} 'Phase string without original deletion proof accepted.'
    Check (!$partial.Ledger.Closed -and $fs.DirectoryMarks -eq 0 -and (Test-Path $partial.Ledger.Root)) 'Unproven absence removed a directory.'
    $partial=New-TestDeleteLedger 'replaced-directory';$fs=$partial.State;$fs.DirectoryMarkFailures=1
    Refuses {Restore-IW7VoiceRecorderHelperCopy $partial.Ledger} 'Partial setup did not inject expected failure.'
    $fs.DirectoryId='replacement-directory'
    Refuses {Restore-IW7VoiceRecorderHelperCopy $partial.Ledger} 'Replacement directory accepted after image deletion.'
    Check (!$partial.Ledger.Closed -and $fs.DirectoryMarks -eq 1 -and (Test-Path $partial.Ledger.Root)) 'Replacement directory deleted via retained original handle.'
    foreach($name in $deleteDependencies.Keys){Set-Item ('Function:'+$name) $deleteDependencies[$name]}
    function Get-IW7VoiceRecorderOwnerFileId {param($Owner,$Kind)return 'physical-original'}
    function Restore-IW7VoiceRecorderHelperCopy {
        param($Ledger)
        Check (!$Ledger.OwnerRequired -or $Ledger.OwnerResolved) 'Cleanup ran before original checked disposal.'
        $trace.Add('HelperRestore');$Ledger.Closed=$true
    }
    function Start-Sleep {param($Seconds,$Milliseconds)$trace.Add('RecoveryDelay')}

    $pending=New-TestRecorder 'task-fault-live';Register-IW7VoiceRecorderOwner $pending
    $pending.Owner.CloseFailures=10
    Check ($pending.Task.IsFaulted -and $pending.Task.IsCompleted) 'Fixture is not a faulted completed task.'
    Check (!(Invoke-IW7VoiceRecorderCleanupAttempt $pending)) 'Faulted task became successful closure.'
    Check (!$pending.OwnershipResolved -and !$pending.Owner.OwnershipResolved -and !$pending.HelperLedger.Closed -and !$pending.HelperLedger.OwnerResolved) 'Unconfirmed owner/guard/helper was released.'
    Check (!$trace.Contains('CheckedDispose') -and !$trace.Contains('HelperRestore')) 'Unconfirmed termination reached disposal/restoration.'
    Check (@(Get-IW7VoiceRecorderOwners $root $pending.LeaseToken).Count -eq 1) 'Start-failure owner vanished from the host registry.'
    Refuses {Complete-IW7VoicePairRecorder $pending} 'Complete returned a WAV result from a live faulted producer.'
    Check (!$pending.Finished -and !$pending.OwnershipResolved) 'Completed/faulted Task released unresolved owner.'
    $receipts=@(Get-ChildItem $pending.OutputRoot -Filter '*pending.local.json')
    Check ($receipts.Count -ge 2) 'Unconfirmed cleanup did not leave durable local receipts.'
    Check ((Get-Content $receipts[-1].FullName -Raw|ConvertFrom-Json).HostMustRemainAlive) 'Pending receipt permits CLI exit.'
    $registry.Clear();$trace.Clear()

    $mismatch=New-TestRecorder 'kernel-mismatch';$mismatch.Owner.IdentityMismatch=$true
    Check (!(Invoke-IW7VoiceRecorderCleanupAttempt $mismatch)) 'Terminal creation mismatch accepted.'
    Check (!$mismatch.Owner.OwnershipResolved -and !$mismatch.HelperLedger.Closed) 'Identity mismatch released authority/files.'
    $mismatch.Owner.IdentityMismatch=$false
    Check (Invoke-IW7VoiceRecorderCleanupAttempt $mismatch) 'Exact original identity recovery failed.'
    Check ($mismatch.Closure.Original.CreationFileTime -eq $mismatch.Closure.Terminal.CreationFileTime) 'Closure receipt tuple differs.'
    Check ($mismatch.Closure.Schema -ceq 'iw7.offline-asr-owned-closure/1' -and $mismatch.Closure.Terminal.OriginalHandleWaitSignaled) 'Original terminal proof schema differs.'
    Check ((Get-FileHash $mismatch.ClosureReceipt.Path).Hash -ceq $mismatch.ClosureReceipt.SHA256) 'Durable closure pin differs.'
    $trace.Clear()

    # Execute the actual SaveClosure/cleanup policy for the measured Win32=31
    # terminal image failure. The last live image is explicit; no successful
    # post-exit query, child execution, WAV or scheduler admission is invented.
    $retained=New-TestRecorder 'terminal-image-retained';$retained.Owner.ExitCode=125;$retained.Owner.ImageQueryFails=$true
    Check (Invoke-IW7VoiceRecorderCleanupAttempt $retained) 'Same original terminal live-image/held-guard evidence could not clean.'
    $proof=Get-Content $retained.ClosureReceipt.Path -Raw|ConvertFrom-Json
    Check ($proof.ImageEvidenceMode -ceq 'original-live-kernel-and-retained-image-guard' -and $proof.ImageQueryAfterExitSucceeded -eq $false -and
        $proof.ImageQueryAfterExitWin32Error -eq 31 -and $proof.RetainedImageGuardVerified -and $proof.Terminal.ExitCodeUInt32 -eq 125 -and $proof.Original.ImageEvidenceMode -ceq 'live-kernel-query') 'Closure fabricated a post-exit image query or lost actual error/uint exit.'
    Check ((Get-FileHash $retained.ClosureReceipt.Path).Hash -ceq $retained.ClosureReceipt.SHA256 -and $retained.Owner.OwnershipResolved -and $retained.HelperLedger.Closed) 'Retained-image closure was not pinned before disposal/helper cleanup.'
    foreach($kind in @('ImageEvidenceInvalid','ImageGuardMissing','ExitUIntMismatch')){
        $invalid=New-TestRecorder ('terminal-proof-'+$kind);$invalid.Owner.ExitCode=125;$invalid.Owner.ImageQueryFails=$true;$invalid.Owner.$kind=$true
        Check (!(Invoke-IW7VoiceRecorderCleanupAttempt $invalid)) ('Invalid terminal '+$kind+' accepted.')
        Check (!$invalid.ClosureReceipt -and !$invalid.Owner.OwnershipResolved -and !$invalid.HelperLedger.Closed) ('Invalid terminal '+$kind+' reached disposal/helper cleanup.')
        $invalid.Owner.$kind=$false
        Check (Invoke-IW7VoiceRecorderCleanupAttempt $invalid) ('Fresh original proof did not recover '+$kind+'.')
    }
    $signedExit=New-TestRecorder 'terminal-uint-status';$signedExit.Owner.ExitCode=-1073741819
    Check (Invoke-IW7VoiceRecorderCleanupAttempt $signedExit) 'Confirmed original NTSTATUS terminal could not clean.'
    Check ($signedExit.Closure.Terminal.ExitCode -eq -1073741819 -and $signedExit.Closure.Terminal.ExitCodeUInt32 -eq 3221225477L) 'Unsigned terminal status was truncated or fabricated as zero.'
    $trace.Clear()

    $disposal=New-TestRecorder 'dispose-failed';$disposal.Owner.DisposeFailures=1
    Check (!(Invoke-IW7VoiceRecorderCleanupAttempt $disposal)) 'Unconfirmed checked disposal accepted.'
    Check ($disposal.ClosureReceipt -and !$disposal.OwnershipResolved -and !$disposal.HelperLedger.Closed) 'Disposal failure lost proof or restored helper.'
    $closurePath=$disposal.ClosureReceipt.Path
    Check (Invoke-IW7VoiceRecorderCleanupAttempt $disposal) 'Checked disposal recovery failed.'
    Check ($disposal.ClosureReceipt.Path -ceq $closurePath -and $disposal.Owner.OwnershipResolved -and $disposal.HelperLedger.Closed) 'Recovery replaced proof or left original ownership pending.'
    $trace.Clear()

    $eof=New-TestRecorder 'producer-eof';$eof.Owner.EOFRefused=$true
    Check (!(Invoke-IW7VoiceRecorderCleanupAttempt $eof)) 'Unconfirmed producer EOF accepted.'
    Check (!$eof.ClosureReceipt -and !$eof.Owner.OwnershipResolved -and !$eof.HelperLedger.Closed) 'EOF failure produced final closure or restored helper.'
    $eof.Owner.EOFRefused=$false
    Check (Invoke-IW7VoiceRecorderCleanupAttempt $eof) 'Original EOF recovery failed.'

    $failed=New-TestRecorder 'nonzero-terminal';$failed.Owner.ExitCode=125
    Check (Invoke-IW7VoiceRecorderCleanupAttempt $failed) 'Confirmed failed child could not be cleaned.'
    Check ($failed.Closure.Terminal.ExitCode -eq 125 -and $failed.Owner.OwnershipResolved) 'Nonzero closure was fabricated as success.'
    $taskError=New-TestRecorder 'task-error-valid-closure'
    Refuses {Complete-IW7VoicePairRecorder $taskError} 'Task error was presented as a completed recording.'
    Check ($taskError.Finished -and !$taskError.Result.Completed -and $null -eq $taskError.Result.WAV -and $null -eq $taskError.Result.WAVSHA256) 'Failed producer setup fabricated a WAV/hash success.'
    Check ($taskError.OwnershipResolved -and (Get-FileHash $taskError.ResultReceipt.Path).Hash -ceq $taskError.ResultReceipt.SHA256) 'Task failure omitted checked closure or durable failed result.'
    $none=New-TestRecorder 'no-child';$none.Owner.NoProcessCreatedConfirmed=$true;$none.Owner.HasProcess=$false
    Check (Invoke-IW7VoiceRecorderCleanupAttempt $none) 'Native no-child proof could not release file-only guards.'
    Check ($none.Closure.Schema -ceq 'iw7.voice-recorder-no-child/1' -and !$none.Closure.OriginalHandleCreated) 'No-child refusal fabricated process/ASR proof.'

    # The provider factory copies functions into dynamic modules. Its failed
    # Start must remain visible to the outer CLI through the shared host store.
    $registry.Clear();$moduleRecord=New-TestRecorder 'dynamic-module'
    $definitions=@{};foreach($command in Get-Command -CommandType Function|Where-Object Name -Like '*-IW7VoiceRecorder*'){$definitions[$command.Name]=$command.ScriptBlock}
    $register={param($r)Register-IW7VoiceRecorderOwner $r}.GetNewClosure()
    & $register.Module {param($d)foreach($name in $d.Keys){Set-Item ('Function:script:'+$name) $d[$name]}} $definitions
    & $register $moduleRecord
    Check (@(Get-IW7VoiceRecorderOwners $root $moduleRecord.LeaseToken).Count -eq 1) 'Dynamic module isolated original owner from CLI cleanup.'
    Refuses {Get-IW7VoiceRecorderOwners $root ('c'*32)} 'Conflicting lease selected original owners.'
    $registry.Clear();$trace.Clear()

    # Execute the ACTUAL Voice-Pair-Lab outer finally AST with ordinary teardown
    # mocked. The gate fails two original closes and one disposal, then recovers.
    # No game, lease API, kernel compiler, endpoint or child process is touched.
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'ops/Voice-Pair-Lab.ps1'),[ref]$tokens,[ref]$errors)
    Check (!$errors.Count) 'Entry CLI parse failed.'
    $finally=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.TryStatementAst] -and $node.Finally -and
        @($node.Finally.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Stop-IW7AgentPair'},$true)).Count -gt 0},$true))
    Check ($finally.Count -eq 1) 'Actual pair teardown finally unavailable/ambiguous.'
    $cli=New-TestRecorder 'actual-finally';$cli.Owner.CloseFailures=2;$cli.Owner.DisposeFailures=1;Register-IW7VoiceRecorderOwner $cli
    $lease=[pscustomobject]@{Token=$cli.LeaseToken};$output=$cli.OutputRoot;$pair=[pscustomobject]@{Owned=$true};$server=$null
    $prepared=$null;$serverBackup=[pscustomobject]@{Owned=$true};$baseBackup=[pscustomobject]@{Owned=$true};$failure=$null;$cleanupError=$null
    $passed=$false;$restored=$false;$GameRoot=$root;$CandidateRoot=$root;$ServerPort=27116;$ClientPort=27117;$PeerPort=27118
    function Assert-TestClosed {Check ($cli.Owner.OwnershipResolved -and $cli.OwnershipResolved -and $cli.HelperLedger.Closed -and $cli.SourceClosed -and $cli.SourceClosureReceipt) 'Actual finally continued before exact recorder/source cleanup.'}
    function Stop-IW7AgentPair {param($Pair)Assert-TestClosed;$trace.Add('StopPair')}
    function Assert-IW7BaseVacant {param($Root)Assert-TestClosed}
    function Assert-IW7AgentCandidateVacant {param($CandidateRoot,$Ports)Assert-TestClosed}
    function Restore-IW7BaseTransaction {param($Backup)Assert-TestClosed;$trace.Add('RestoreBase')}
    function Exit-IW7ResourceLease {param($Token)Assert-TestClosed;Check ($Token -ceq $cli.LeaseToken) 'Actual finally released wrong lease.';$trace.Add('ReleaseLease')}
    $finallyText=$finally[0].Finally.Extent.Text
    & ([scriptblock]::Create($finallyText.Substring(1,$finallyText.Length-2)))
    Check ($cli.RecoveryAttempts -ge 4 -and $trace.Contains('RecoveryDelay')) 'CLI did not retain this host through closure/disposal retries.'
    Check ($trace.IndexOf('StopPair') -gt $trace.IndexOf('HelperRestore') -and $trace.IndexOf('ReleaseLease') -gt $trace.IndexOf('RestoreBase')) 'Actual finally restoration/release ordering changed.'
    Check ((Get-Content (Join-Path $output 'result.local.json') -Raw|ConvertFrom-Json).Restored) 'Actual finally failed restoration after exact closure recovery.'
    Check (@(Get-IW7VoiceRecorderOwners $output $cli.LeaseToken).Count -eq 1) 'Disposed original record was discarded before final proof could be inspected.'
    Check ($trace.IndexOf('SourceClose') -gt $trace.IndexOf('HelperRestore') -and $trace.IndexOf('StopPair') -gt $trace.IndexOf('SourceClose')) 'Source guard closed before original/helper cleanup or after ordinary teardown.'
    $registry.Clear();$sourceCase=New-TestRecorder 'source-retained';Register-IW7VoiceRecorderOwner $sourceCase
    Invoke-IW7VoiceRecorderSourceCleanup @($sourceCase)
    Check (!$sourceCase.SourceClosed -and $sourceCase.SourceProvider.CloseCalls -eq 0) 'Source guard closed while original owner unresolved.'
    Check (Invoke-IW7VoiceRecorderCleanupAttempt $sourceCase) 'Source test original cleanup failed.'
    $sourceCase.HelperLedger.Closed=$false;Invoke-IW7VoiceRecorderSourceCleanup @($sourceCase)
    Check (!$sourceCase.SourceClosed -and $sourceCase.SourceProvider.CloseCalls -eq 0) 'Source guard closed while helper unresolved.'
    $sourceCase.HelperLedger.Closed=$true;$sourceCase.SourceProvider.CloseFailures=1
    $wavePath=Join-Path $sourceCase.OutputRoot 'guard.wav';[IO.File]::WriteAllText($wavePath,'held');$sourceCase.WAVHandle=[IO.File]::Open($wavePath,'Open','Read','Read');$waveGuard=$sourceCase.WAVHandle.SafeFileHandle
    Refuses {Invoke-IW7VoiceRecorderSourceCleanup @($sourceCase)} 'Source disposal failure accepted.'
    Check ($waveGuard.IsClosed -and !$sourceCase.WAVHandle -and !$sourceCase.SourceClosed -and (Test-IW7VoiceRecorderCleanupPending $sourceCase)) 'Source failure discarded pending lifetime state or preceded WAV closure.'
    Check (Invoke-IW7VoiceRecorderCleanupAttempt $sourceCase) 'Source retry did not clear the diagnosed transient cleanup failure.'
    Invoke-IW7VoiceRecorderSourceCleanup @($sourceCase)
    Check ($sourceCase.SourceClosed -and $sourceCase.SourceClosureReceipt -and $sourceCase.SourceProvider.CloseCalls -eq 2) 'Original source retry failed to preserve and resolve same guard.'
    $registry.Clear();$loadFailure=New-TestRecorder 'source-loader-failure';$loadFailure.Owner=$null;$loadFailure.HelperLedger=$null;$loadFailure.OwnershipResolved=$true;$loadFailure.SourceProvider.State='Failed';Register-IW7VoiceRecorderOwner $loadFailure
    Check (Invoke-IW7VoiceRecorderCleanupAttempt $loadFailure) 'No-child provider failure incorrectly required process/helper cleanup.'
    Invoke-IW7VoiceRecorderSourceCleanup @($loadFailure)
    Check ($loadFailure.SourceClosed -and $loadFailure.SourceClosureReceipt -and !$loadFailure.Owner -and !$loadFailure.HelperLedger) 'Failed loader source guard lost before durable same-host closure.'
    $registry.Clear();$sharedA=New-TestRecorder 'shared-source-a';$sharedB=New-TestRecorder 'shared-source-b';$sharedB.SourceProvider=$sharedA.SourceProvider
    Register-IW7VoiceRecorderOwner $sharedA;Register-IW7VoiceRecorderOwner $sharedB
    Check (Invoke-IW7VoiceRecorderCleanupAttempt $sharedA) 'Shared source first owner cleanup failed.'
    Invoke-IW7VoiceRecorderSourceCleanup @($sharedA)
    Check (!$sharedA.SourceClosed -and $sharedA.SourceProvider.CloseCalls -eq 0) 'CaseRoot subset closed source while another original owner remained.'
    Check (Invoke-IW7VoiceRecorderCleanupAttempt $sharedB) 'Shared source second owner cleanup failed.'
    Invoke-IW7VoiceRecorderSourceCleanup @($sharedA,$sharedB)
    Check ($sharedA.SourceClosed -and $sharedB.SourceClosed -and $sharedA.SourceClosureReceipt -and $sharedB.SourceClosureReceipt) 'Shared source guard closure omitted one durable owner receipt.'
    $registry.Clear();$waveRetry=New-TestRecorder 'wav-guard-retry';Register-IW7VoiceRecorderOwner $waveRetry
    Check (Invoke-IW7VoiceRecorderCleanupAttempt $waveRetry) 'WAV retry owner cleanup failed.'
    $retainedWaveGuard=[pscustomobject]@{IsClosed=$false};$retainedWaveStream=[pscustomobject]@{SafeFileHandle=$retainedWaveGuard;Attempts=0}
    $retainedWaveStream|Add-Member ScriptMethod Dispose {$this.Attempts++;if($this.Attempts -eq 1){throw 'WAV original close failed.'};$this.SafeFileHandle.IsClosed=$true}
    $waveRetry.WAVHandle=$retainedWaveStream
    Refuses {Invoke-IW7VoiceRecorderSourceCleanup @($waveRetry)} 'WAV disposal failure accepted.'
    Check ([object]::ReferenceEquals($waveRetry.WAVFileHandle,$retainedWaveGuard) -and [object]::ReferenceEquals($waveRetry.WAVHandle,$retainedWaveStream) -and
        !$waveRetry.SourceClosed -and $waveRetry.SourceProvider.CloseCalls -eq 0) 'Failed WAV disposal lost its original stream/guard or closed source.'
    Check (Invoke-IW7VoiceRecorderCleanupAttempt $waveRetry) 'WAV retry did not clear diagnosed transient failure.'
    Invoke-IW7VoiceRecorderSourceCleanup @($waveRetry)
    Check ($retainedWaveGuard.IsClosed -and $retainedWaveStream.Attempts -eq 2 -and !$waveRetry.WAVHandle -and $waveRetry.SourceClosed) 'WAV retry reopened/discarded original guard or failed final source closure.'
    "PASS $checks pure recorder cleanup checks: exact native path boundaries and overlong NewHelperCopy zero-native/zero-copy refusal, real helper partial-deletion/handle-retry state machine, unproven absence/replaced directory refusal, faulted Task/live original, kernel mismatch, EOF/disposal recovery, pinned closure, no-child/nonzero terminal, dynamic-module retention and actual entry-finally gate before restoration/release. Kernel/NTFS syscall dependencies mocked; no child/audio/game/lease/compiler."
}finally{
    $registry.Clear();foreach($key in $previousRegistry.Keys){$registry[$key]=$previousRegistry[$key]}
    Set-Item Function:Restore-IW7VoiceRecorderHelperCopy $originalRestore
    Set-Item Function:Get-IW7VoiceRecorderOwnerFileId $originalFileId
    if($originalSleep){Set-Item Function:Start-Sleep $originalSleep}else{Remove-Item Function:Start-Sleep -ErrorAction SilentlyContinue}
    foreach($name in $deleteDependencies.Keys){Set-Item ('Function:'+$name) $deleteDependencies[$name]}
    if($nativeInitDefinition){Set-Item Function:Initialize-IW7AgentPairNtfs $nativeInitDefinition}else{Remove-Item Function:Initialize-IW7AgentPairNtfs -ErrorAction SilentlyContinue}
    foreach($ledger in $partialLedgers){if($ledger.ImageDeleteStream){$ledger.ImageDeleteStream.Dispose()}}
    if(!$root.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase)){throw 'Pure test cleanup root escaped.'}
    Remove-Item -LiteralPath $root -Recurse -Force
}
