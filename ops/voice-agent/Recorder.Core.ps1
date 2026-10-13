# Import never records audio. The host registry retains original owners across
# provider dynamic modules and failed Start calls. It is not an OS broker:
# callers must keep this host alive until Wait-IW7VoiceRecorderCleanup returns.
function Get-IW7VoiceRecorderRegistry {
    $key='IW7.VoicePair.OriginalRecorderOwners.v2'
    $registry=[AppDomain]::CurrentDomain.GetData($key)
    if($null -eq $registry){$registry=[Collections.Hashtable]::Synchronized(@{});[AppDomain]::CurrentDomain.SetData($key,$registry)}
    return $registry
}
function Register-IW7VoiceRecorderOwner {
    param($Recorder)
    $registry=Get-IW7VoiceRecorderRegistry
    $key=[IO.Path]::GetFullPath($Recorder.OutputRoot).TrimEnd('\','/')
    if($registry.ContainsKey($key)){throw 'Recorder output already has an original owner; retain it.'}
    $registry[$key]=$Recorder
}
function Get-IW7VoiceRecorderOwners {
    param([string]$CaseRoot,[string]$LeaseToken)
    $root=[IO.Path]::GetFullPath($CaseRoot).TrimEnd('\','/')
    foreach($record in @((Get-IW7VoiceRecorderRegistry).Values)){
        if($record.OutputRoot -ieq $root -or $record.OutputRoot.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)){
            if($record.LeaseToken -cne $LeaseToken){throw 'Recorder registry lease conflict; preserve this host and all owners.'}
            $record
        }
    }
}
function Write-IW7VoiceRecorderReceipt {
    param($Recorder,[string]$Phase,$Value)
    if($Phase -cnotmatch '^[a-z][a-z0-9-]{0,40}$'){throw 'Recorder receipt phase invalid.'}
    $Recorder.ReceiptIndex++
    $path=Join-Path $Recorder.OutputRoot ('recorder-{0:D4}-{1}.local.json' -f $Recorder.ReceiptIndex,$Phase)
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($Value|ConvertTo-Json -Depth 14))
    if($bytes.Length -gt 2MB){throw 'Recorder receipt exceeded bound; retain owner.'}
    $stream=[IO.File]::Open($path,'CreateNew','ReadWrite','Read')
    try{
        $stream.Write($bytes,0,$bytes.Length);$stream.Flush($true);$stream.Position=0
        $sha=[Security.Cryptography.SHA256]::Create()
        try{$hash=[Convert]::ToHexString($sha.ComputeHash($stream))}finally{$sha.Dispose()}
        [pscustomobject]@{Path=$path;SHA256=$hash}
    }finally{$stream.Dispose()}
}
function ConvertTo-IW7VoiceRecorderIdentity {
    param($Identity)
    if($null -eq $Identity){throw 'Original recorder identity missing; retain owner.'}
    [pscustomobject]@{PID=[int]$Identity.PID;Image=[string]$Identity.Image;ImageSHA256=[string]$Identity.ImageSHA256;
        CreationFileTime=[long]$Identity.CreationFileTime;Exited=[bool]$Identity.Exited;
        OriginalHandleWaitSignaled=[bool]$Identity.OriginalHandleWaitSignaled;ExitCode=[int]$Identity.ExitCode;
        ExitCodeUInt32=[uint32]$Identity.ExitCodeUInt32;ImageEvidenceMode=[string]$Identity.ImageEvidenceMode;
        ImageQueryAfterExitSucceeded=$Identity.ImageQueryAfterExitSucceeded;ImageQueryAfterExitWin32Error=$Identity.ImageQueryAfterExitWin32Error;
        RetainedImageGuardVerified=[bool]$Identity.RetainedImageGuardVerified;
        CapturedTick=[long]$Identity.CapturedTick;RegistrationDeadlineTick=[long]$Identity.RegistrationDeadlineTick}
}
function Assert-IW7VoiceRecorderIdentity {
    param($Recorder,$Identity,[switch]$Terminal)
    $initial=$Recorder.ProbeIdentity
    if(!$initial -or $Identity.PID -le 0 -or $Identity.CreationFileTime -le 0 -or $Identity.PID -ne $initial.PID -or
        $Identity.CreationFileTime -ne $initial.CreationFileTime -or $Identity.Image -ine $Recorder.HelperLedger.Image -or
        $Identity.Image -ine $initial.Image -or $Identity.ImageSHA256 -ine $Recorder.HelperLedger.SHA256 -or
        $Identity.ImageSHA256 -ine $initial.ImageSHA256){throw 'Original recorder kernel PID/image/creation/hash tuple differs; retain owner.'}
    if($Terminal -and ($Identity.Exited -isnot [bool] -or !$Identity.Exited -or
        $Identity.OriginalHandleWaitSignaled -isnot [bool] -or !$Identity.OriginalHandleWaitSignaled)){
        throw 'Original recorder terminal wait not proven; retain owner.'
    }
    if($Terminal){
        if($initial.ImageEvidenceMode -cne 'live-kernel-query' -or $Identity.RetainedImageGuardVerified -isnot [bool] -or !$Identity.RetainedImageGuardVerified -or
            [long]$Identity.ExitCodeUInt32 -ne ([long]$Identity.ExitCode -band 0xffffffffL)){
            throw 'Original terminal live-image/retained-guard/uint-exit evidence differs; retain owner.'
        }
        if($Identity.ImageEvidenceMode -ceq 'terminal-kernel-query-and-retained-image-guard'){
            if($Identity.ImageQueryAfterExitSucceeded -isnot [bool] -or !$Identity.ImageQueryAfterExitSucceeded -or $null -eq $Identity.ImageQueryAfterExitWin32Error -or $Identity.ImageQueryAfterExitWin32Error -ne 0){throw 'Original terminal successful image query evidence differs; retain owner.'}
        }elseif($Identity.ImageEvidenceMode -ceq 'original-live-kernel-and-retained-image-guard'){
            if($Identity.ImageQueryAfterExitSucceeded -isnot [bool] -or $Identity.ImageQueryAfterExitSucceeded -or $null -eq $Identity.ImageQueryAfterExitWin32Error -or $Identity.ImageQueryAfterExitWin32Error -le 0){throw 'Original terminal failed image query evidence differs; retain owner.'}
        }else{throw 'Original terminal image evidence mode unavailable; retain owner.'}
    }elseif($Identity.ImageEvidenceMode -cne 'live-kernel-query'){
        throw 'Original live recorder kernel image query evidence missing; retain owner.'
    }
}
function Get-IW7VoiceRecorderOwnerFileId {
    param($Owner,[ValidateSet('Image','Stdout')][string]$Kind)
    $handle=if($Kind -ceq 'Image'){$Owner.ImageFileHandle}else{$Owner.StdoutFileHandle}
    [IW7AgentPairNtfs]::Identity($handle)
}
# These small filesystem dependencies keep the cleanup state machine testable
# without compiling NTFS interop. Production always uses the exact NTFS handle.
function Get-IW7VoiceRecorderDeleteIdentity($Handle){[IW7AgentPairNtfs]::Identity($Handle)}
function Get-IW7VoiceRecorderDirectoryIdentity([string]$Path){[IW7AgentPairNtfs]::DirectoryIdentity($Path)}
function Open-IW7VoiceRecorderDeleteHandle([string]$Path){[IW7AgentPairNtfs]::OpenForDelete($Path)}
function New-IW7VoiceRecorderDeleteStream($Handle){[IO.FileStream]::new($Handle,[IO.FileAccess]::Read)}
function Set-IW7VoiceRecorderDeleteDisposition($Handle){[IW7AgentPairNtfs]::DeleteByHandle($Handle)}
function Close-IW7VoiceRecorderDeleteImage($Stream,$Handle){$Stream.Dispose()}
function Assert-IW7VoiceRecorderHelperGeometry {
    param([string]$Root,[string]$Image)
    # The ordinary CreateProcessW and NTFS cleanup paths are deliberately plain
    # absolute paths. Refuse before native initialization or creating a helper.
    if($Root.Length -gt 247){throw ('Recorder helper directory exceeds native path bound: root_chars='+$Root.Length+'; maximum=247.')}
    if($Image.Length -gt 259){throw ('Recorder helper executable exceeds native path bound: image_chars='+$Image.Length+'; maximum=259.')}
}
function New-IW7VoiceRecorderHelperCopy {
    param([string]$CandidateRoot,[string]$ProbePath,[string]$ProbeSHA256,[string]$OutputRoot)
    $scope=(Resolve-Path -LiteralPath $CandidateRoot).Path.TrimEnd('\','/')
    $relative='voice-pair-helper/'+[guid]::NewGuid().ToString('N')
    $root=Resolve-IW7BasePath $scope $relative;$image=Resolve-IW7BasePath $scope ($relative+'/receiver-probe.exe')
    Assert-IW7VoiceRecorderHelperGeometry $root $image
    if(Test-Path -LiteralPath $root){throw 'Fresh recorder helper directory required.'}
    Initialize-IW7AgentPairNtfs
    $source=[IO.File]::Open([IO.Path]::GetFullPath($ProbePath),'Open','Read','Read')
    try{
        if($source.Length -lt 1 -or $source.Length -gt 16MB){throw 'Bounded recorder helper image required.'}
        $sha=[Security.Cryptography.SHA256]::Create()
        try{$hash=[Convert]::ToHexString($sha.ComputeHash($source))}finally{$sha.Dispose()}
        if($hash -ine $ProbeSHA256){throw 'Recorder helper source hash changed.'}
        $source.Position=0;[IO.Directory]::CreateDirectory($root)|Out-Null
        $target=[IO.File]::Open($image,'CreateNew','Write','Read')
        try{$source.CopyTo($target);$target.Flush()}finally{$target.Dispose()}
        $copy=[IO.File]::Open($image,'Open','Read','Read')
        try{
            $sha=[Security.Cryptography.SHA256]::Create()
            try{$actual=[Convert]::ToHexString($sha.ComputeHash($copy))}finally{$sha.Dispose()}
            if($actual -cne $hash -or $copy.Length -ne $source.Length){throw 'Independent recorder image copy differs.'}
            $ledger=[pscustomobject]@{Schema='iw7.voice-recorder-helper/1';Scope=$scope;Root=$root;Image=$image;SHA256=$hash;Bytes=$copy.Length;
                FileId=[IW7AgentPairNtfs]::Identity($copy.SafeFileHandle);DirectoryId=[IW7AgentPairNtfs]::DirectoryIdentity($root);HardLinked=$false;Closed=$false;OwnerRequired=$false;OwnerResolved=$false;
                CleanupPhase='ImagePresent';ImageDeleteHandle=$null;ImageDeleteStream=$null;DirectoryDeleteHandle=$null;
                ImageDispositionProof=$null;ImageDeletionProof=$null;DirectoryDispositionProof=$null}
        }finally{$copy.Dispose()}
        $ledger|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $OutputRoot 'recorder-helper.local.json')
        $ledger
    }finally{$source.Dispose()}
}
function Restore-IW7VoiceRecorderHelperCopy {
    param($Ledger)
    if($Ledger.Closed){if($Ledger.CleanupPhase -cne 'Closed'){throw 'Recorder helper closed phase conflicts; retain it.'};return}
    if($Ledger.OwnerRequired -and !$Ledger.OwnerResolved){throw 'Original recorder ownership unresolved; retain helper image and reservation.'}
    if($Ledger.Schema -cne 'iw7.voice-recorder-helper/1' -or !$Ledger.Root.StartsWith($Ledger.Scope+'\voice-pair-helper\',[StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetDirectoryName($Ledger.Image) -ine $Ledger.Root -or [IO.Path]::GetFileName($Ledger.Image) -cne 'receiver-probe.exe' -or
        $Ledger.CleanupPhase -cnotin @('ImagePresent','ImageDeleteMarked','ImageDeleted','DirectoryDeleteMarked')){throw 'Recorder helper cleanup identity/phase conflict; retain it.'}
    if($Ledger.CleanupPhase -cne 'DirectoryDeleteMarked' -and
        (Get-IW7VoiceRecorderDirectoryIdentity $Ledger.Root) -cne $Ledger.DirectoryId){throw 'Recorder helper directory identity differs; retain it.'}
    if($Ledger.CleanupPhase -cin @('ImageDeleted','DirectoryDeleteMarked')){
        $proof=$Ledger.ImageDeletionProof
        if(!$proof -or $proof.FileId -cne $Ledger.FileId -or $proof.DirectoryId -cne $Ledger.DirectoryId -or
            $proof.SHA256 -cne $Ledger.SHA256 -or $proof.Bytes -ne $Ledger.Bytes -or
            $proof.DispositionConfirmed -isnot [bool] -or !$proof.DispositionConfirmed -or
            $proof.OriginalFileHandleClosed -isnot [bool] -or !$proof.OriginalFileHandleClosed){throw 'Proven original image deletion missing; absence is not cleanup proof.'}
    }
    if($Ledger.CleanupPhase -ceq 'ImagePresent'){
        $entries=@(Get-ChildItem -LiteralPath $Ledger.Root -Force)
        if($entries.Count -ne 1 -or $entries[0].FullName -ine $Ledger.Image -or $entries[0].Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Unknown recorder helper content; retain it.'}
        # Store each handle before an operation that can throw. Delete marking
        # uses POSIX disposition and may remove the alias before handle close.
        if(!$Ledger.ImageDeleteHandle){$Ledger.ImageDeleteHandle=Open-IW7VoiceRecorderDeleteHandle $Ledger.Image}
        if($Ledger.ImageDeleteHandle.IsClosed){throw 'Original helper delete handle closed before disposition proof; retain it.'}
        if(!$Ledger.ImageDeleteStream){$Ledger.ImageDeleteStream=New-IW7VoiceRecorderDeleteStream $Ledger.ImageDeleteHandle}
        $copy=$Ledger.ImageDeleteStream
        if((Get-IW7VoiceRecorderDeleteIdentity $Ledger.ImageDeleteHandle) -cne $Ledger.FileId -or $copy.Length -ne $Ledger.Bytes){throw 'Recorder helper image identity differs.'}
        $copy.Position=0;$sha=[Security.Cryptography.SHA256]::Create()
        try{$hash=[Convert]::ToHexString($sha.ComputeHash($copy))}finally{$sha.Dispose()}
        if($hash -cne $Ledger.SHA256){throw 'Recorder helper image hash differs; retain it.'}
        Set-IW7VoiceRecorderDeleteDisposition $Ledger.ImageDeleteHandle
        $Ledger.ImageDispositionProof=[pscustomobject]@{FileId=$Ledger.FileId;DirectoryId=$Ledger.DirectoryId;SHA256=$hash;Bytes=$copy.Length;DispositionConfirmed=$true}
        $Ledger.CleanupPhase='ImageDeleteMarked'
    }
    if($Ledger.CleanupPhase -ceq 'ImageDeleteMarked'){
        $proof=$Ledger.ImageDispositionProof
        if(!$Ledger.ImageDeleteHandle -or !$Ledger.ImageDeleteStream -or !$proof -or $proof.FileId -cne $Ledger.FileId -or
            $proof.DirectoryId -cne $Ledger.DirectoryId -or $proof.SHA256 -cne $Ledger.SHA256 -or $proof.Bytes -ne $Ledger.Bytes -or
            $proof.DispositionConfirmed -isnot [bool] -or !$proof.DispositionConfirmed){throw 'Original marked helper handles/proof missing; absence is not cleanup proof.'}
        if(!$Ledger.ImageDeleteHandle.IsClosed){Close-IW7VoiceRecorderDeleteImage $Ledger.ImageDeleteStream $Ledger.ImageDeleteHandle}
        if(!$Ledger.ImageDeleteHandle.IsClosed){throw 'Original marked helper handle closure unconfirmed; retain it.'}
        if((Get-IW7VoiceRecorderDirectoryIdentity $Ledger.Root) -cne $Ledger.DirectoryId -or
            @(Get-ChildItem -LiteralPath $Ledger.Root -Force).Count -ne 0){throw 'Marked helper alias or unknown content remains; retain it.'}
        $Ledger.ImageDeletionProof=[pscustomobject]@{FileId=$proof.FileId;DirectoryId=$proof.DirectoryId;SHA256=$proof.SHA256;Bytes=$proof.Bytes;
            DispositionConfirmed=$true;OriginalFileHandleClosed=$true}
        $Ledger.CleanupPhase='ImageDeleted';$Ledger.ImageDeleteStream=$null;$Ledger.ImageDeleteHandle=$null
    }
    if($Ledger.CleanupPhase -ceq 'ImageDeleted'){
        if(@(Get-ChildItem -LiteralPath $Ledger.Root -Force).Count -ne 0){throw 'Unknown recorder helper content after proven image deletion; retain it.'}
        if(!$Ledger.DirectoryDeleteHandle){$Ledger.DirectoryDeleteHandle=Open-IW7VoiceRecorderDeleteHandle $Ledger.Root}
        if($Ledger.DirectoryDeleteHandle.IsClosed -or (Get-IW7VoiceRecorderDeleteIdentity $Ledger.DirectoryDeleteHandle) -cne $Ledger.DirectoryId){throw 'Original helper directory delete handle differs; retain it.'}
        Set-IW7VoiceRecorderDeleteDisposition $Ledger.DirectoryDeleteHandle
        $Ledger.DirectoryDispositionProof=[pscustomobject]@{DirectoryId=$Ledger.DirectoryId;DispositionConfirmed=$true}
        $Ledger.CleanupPhase='DirectoryDeleteMarked'
    }
    if($Ledger.CleanupPhase -ceq 'DirectoryDeleteMarked'){
        $proof=$Ledger.DirectoryDispositionProof
        if(!$Ledger.DirectoryDeleteHandle -or !$proof -or $proof.DirectoryId -cne $Ledger.DirectoryId -or
            $proof.DispositionConfirmed -isnot [bool] -or !$proof.DispositionConfirmed){throw 'Original marked directory handle/proof missing; absence is not cleanup proof.'}
        if(!$Ledger.DirectoryDeleteHandle.IsClosed){$Ledger.DirectoryDeleteHandle.Dispose()}
        if(!$Ledger.DirectoryDeleteHandle.IsClosed -or (Test-Path -LiteralPath $Ledger.Root) -or (Test-Path -LiteralPath $Ledger.Image)){
            throw 'Original marked directory closure/absence unconfirmed; retain it.'
        }
        $Ledger.CleanupPhase='Closed';$Ledger.Closed=$true;$Ledger.DirectoryDeleteHandle=$null
    }
}
function Start-IW7VoicePairRecorder {
    param($Receiver,[string]$ProbePath,[string]$ProbeSHA256,[string]$OutputRoot,[ValidateRange(1,15)][int]$Seconds=12,[string]$LeaseToken,[string]$CandidateRoot,[string]$RecorderSourceSHA256)
    if(!$LeaseToken){throw 'Whole-pair helper reservation required.'}
    $leases=@((Get-IW7ResourceStatus).Leases|Where-Object Token -CEQ $LeaseToken)
    if($leases.Count -ne 1 -or $leases[0].Kind -cne 'Runtime' -or $leases[0].PhysicalBytes -ne 20GB -or $leases[0].CommitBytes -ne 20GB -or
        [IO.Path]::GetFullPath($CandidateRoot).TrimEnd('\','/') -ine $leases[0].Scope){throw 'Exact whole audio-pair20/20 scope required.'}
    if($ProbeSHA256 -cnotmatch '^[a-fA-F0-9]{64}$' -or $Receiver.ImageSHA256 -cnotmatch '^[a-fA-F0-9]{64}$'){throw 'Pinned probe/receiver hashes required.'}
    if($RecorderSourceSHA256 -cnotmatch '^[A-F0-9]{64}$'){throw 'Explicit reviewed Recorder-Probe.cs source pin required.'}
    if(!(Get-Command Initialize-IW7ResourceRecorderProvider -ErrorAction SilentlyContinue)){throw 'Reviewed Runtime recorder admission API must be imported by the scheduler.'}
    $stdout=Join-Path $OutputRoot 'receiver-probe.stdout.log';$stderr=Join-Path $OutputRoot 'receiver-probe.stderr.log';$wav=Join-Path $OutputRoot 'receiver.wav'
    foreach($file in @($stdout,$stderr,$wav)){if(Test-Path -LiteralPath $file){throw 'Fresh recorder outputs required.'}}
    $started=[Environment]::TickCount64
    $owner=$null;$helper=$null
    $record=[pscustomobject]@{Owner=$null;Task=$null;Receiver=$Receiver;Stdout=$stdout;Stderr=$stderr;WAVPath=$wav;Seconds=$Seconds;StartedTick=$started;
        OutputRoot=[IO.Path]::GetFullPath($OutputRoot).TrimEnd('\','/');LeaseToken=$LeaseToken;OutputHandle=$null;OutputFileId=$null;WAVHandle=$null;WAVFileHandle=$null;
        Finished=$false;Result=$null;ResultReceipt=$null;Failure=$null;LeaseRegistered=$false;ProbeIdentity=$null;HelperLedger=$null;
        SourceProvider=$null;SourceClosed=$false;SourceReceipt=$null;SourceClosureReceipt=$null;RegistrationEvidence=$null;AdmissionReceipt=$null;
        ReceiptIndex=0;InitialReceipt=$null;ClosureReceipt=$null;Closure=$null;OwnershipResolved=$true;CleanupError=$null;RecoveryAttempts=0;AddAttempted=$false;LaunchFailureReceipt=$null}
    # Adopt the source-provider before its loader can throw, then the pure owner
    # before StartSuspended. The same CLI retains both through any failed Start.
    Register-IW7VoiceRecorderOwner $record
    try{
        $provider=Initialize-IW7ResourceRecorderProvider -Token $LeaseToken -SourceSHA256 $RecorderSourceSHA256 -OnAcquired {param($p)$record.SourceProvider=$p}
        $record.SourceReceipt=Write-IW7VoiceRecorderReceipt $record 'source' (Get-IW7ResourceRecorderProviderEvidence $provider)
        $null=Assert-IW7ResourceRecorderProvider $provider $LeaseToken
        $borrowType=$provider.Type.Assembly.GetType('IW7.VoicePairDraft.OwnedProbe',$true,$false)
        if($borrowType.GetField('OwnershipVersion').GetRawConstantValue() -ne 3){throw 'Source-bound recorder ownership version3 required.'}
        $receiverHandle=Get-Process -Id $Receiver.PID
        try{
            # This borrowed receiver handle validates only the pair tuple. It
            # is never recorder ownership or termination authority.
            $receiverIdentity=$borrowType.GetMethod('CaptureIdentity').Invoke($null,[object[]]@($receiverHandle.SafeHandle))
            if($receiverIdentity.Exited -or $receiverIdentity.PID -ne $Receiver.PID -or $receiverIdentity.Image -ine $Receiver.Image -or
                $receiverIdentity.CreationFileTime -ne $Receiver.CreationFileTime){throw 'Receiver exact kernel process identity changed.'}
        }finally{$receiverHandle.Dispose()}
        if((Get-FileHash -LiteralPath $Receiver.Image).Hash -ine $Receiver.ImageSHA256){throw 'Receiver image changed.'}
        $helper=New-IW7VoiceRecorderHelperCopy $CandidateRoot $ProbePath $ProbeSHA256 $OutputRoot;$record.HelperLedger=$helper
        $owner=New-IW7ResourceRecorderOriginal -Provider $provider -Token $LeaseToken -PairScope $CandidateRoot -Helper $helper -Arguments ([string[]]@('--record',"$Seconds","$($Receiver.PID)","$($Receiver.CreationFileTime)",$Receiver.Image,$Receiver.ImageSHA256,$wav)) -Stdout $stdout -Stderr $stderr -TimeoutSeconds ($Seconds+15)
        $record.Owner=$owner;$record.OwnershipResolved=$false;$helper.OwnerRequired=$true
        $identity=$owner.StartSuspended();$record.ProbeIdentity=ConvertTo-IW7VoiceRecorderIdentity $identity
        Assert-IW7VoiceRecorderIdentity $record $identity
        if((Get-IW7VoiceRecorderOwnerFileId $owner Image) -cne $helper.FileId){throw 'Retained original helper physical identity differs.'}
        $record.OutputFileId=Get-IW7VoiceRecorderOwnerFileId $owner Stdout
        $record.InitialReceipt=Write-IW7VoiceRecorderReceipt $record 'original' ([pscustomobject]@{Schema='iw7.voice-recorder-original/1';
            Original=$record.ProbeIdentity;HelperFileId=$helper.FileId;StdoutFileId=$record.OutputFileId;Source=$record.SourceReceipt;LeaseToken=$LeaseToken;Suspended=$true;ExecutionAllowed=$false})
        $record.AddAttempted=$true
        $registration=Add-IW7ResourceOwnedRuntimeRecorder -Token $LeaseToken -Provider $provider -Owner $owner -Helper $helper
        $record.LeaseRegistered=$true;$record.RegistrationEvidence=$registration.Receipt
        $record.AdmissionReceipt=Write-IW7VoiceRecorderReceipt $record 'admission' $registration.Receipt
        $null=Assert-IW7ResourceRecorderProvider $provider $LeaseToken
        $owner.Admit($registration.Permit,$record.AdmissionReceipt.Path,$record.AdmissionReceipt.SHA256);$record.Task=$owner.Completion
        if(!$record.Task -or !$owner.Accepted){throw 'Original recorder execution was not admitted.'}
    }catch{
        $launchFailure=$_
        $record.Failure=$launchFailure.Exception.Message
        if($launchFailure.Exception.Data['RecorderRegistrationReceipt']){$record.LeaseRegistered=$true;$record.RegistrationEvidence=$launchFailure.Exception.Data['RecorderRegistrationReceipt']}
        try{
            $kernel=$null;$metadata=@();$diagnosticError=$null
            try{
                if($owner -and $owner.HasProcess){$kernel=ConvertTo-IW7VoiceRecorderIdentity $owner.CaptureIdentity()}
                if($record.AddAttempted -and (Get-Command Get-IW7ResourceProcesses -ErrorAction SilentlyContinue)){
                    $metadata=@(Get-IW7ResourceProcesses|Where-Object PID -EQ $record.ProbeIdentity.PID|Select-Object PID,Image,CreatedUtc)
                }
            }catch{$diagnosticError=$_.Exception.Message}
            $record.LaunchFailureReceipt=Write-IW7VoiceRecorderReceipt $record 'launch-failure' ([pscustomobject]@{
                Schema='iw7.voice-recorder-launch-failure/1';Error=$record.Failure;Kernel=$kernel;Metadata=$metadata;MetadataCount=$metadata.Count;
                AddAttempted=$record.AddAttempted;LeaseRegistered=$record.LeaseRegistered;Registration=$record.RegistrationEvidence;Source=$record.SourceReceipt;
                ExecutionAdmitted=[bool]$(if($owner){$owner.Accepted}else{$false});ResumeAttempted=[bool]$(if($owner){$owner.ResumeAttempted}else{$false});DiagnosticError=$diagnosticError})
        }catch{$launchFailure.Exception.Data['RecorderFailureReceipt']=$_.Exception.Message}
        $null=Invoke-IW7VoiceRecorderCleanupAttempt $record
        $launchFailure.Exception.Data['RecorderOwner']=$record
        $launchFailure.Exception.Data['RecorderCleanup']=$record.CleanupError
        throw $launchFailure
    }
    $record
}
function Get-IW7VoicePairRecorderState {
    param($Recorder)
    if($Recorder.OwnershipResolved){throw 'Original recorder already closed; no live readiness authority.'}
    $identity=$Recorder.Owner.CaptureObservation();Assert-IW7VoiceRecorderIdentity $Recorder $identity -Terminal:$identity.Exited
    if($Recorder.Task.IsFaulted){throw $Recorder.Task.Exception}
    $text=''
    if(Test-Path -LiteralPath $Recorder.Stdout){
        if(!$Recorder.OutputHandle){$Recorder.OutputHandle=[IO.FileStream]::new($Recorder.Stdout,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite,1,[IO.FileOptions]::None)}
        if([IW7AgentPairNtfs]::Identity($Recorder.OutputHandle.SafeFileHandle) -cne $Recorder.OutputFileId -or
            (Get-IW7VoiceRecorderOwnerFileId $Recorder.Owner Stdout) -cne $Recorder.OutputFileId){throw 'Original recorder stdout physical identity changed.'}
        $check=[IO.File]::Open($Recorder.Stdout,'Open','Read','ReadWrite')
        try{if([IW7AgentPairNtfs]::Identity($check.SafeFileHandle) -cne $Recorder.OutputFileId){throw 'Recorder stdout identity changed.'}}finally{$check.Dispose()}
        if($Recorder.OutputHandle.Length -gt 4MB){throw 'Recorder stdout grew beyond bound.'}
        $Recorder.OutputHandle.Position=0;$bytes=[byte[]]::new([int]$Recorder.OutputHandle.Length);$Recorder.OutputHandle.ReadExactly($bytes);$text=[Text.Encoding]::UTF8.GetString($bytes)
    }
    [pscustomobject]@{OwnedIdentityValidated=$true;Exited=$identity.OriginalHandleWaitSignaled;Stdout=$text;Original=$identity}
}
function Save-IW7VoiceRecorderClosure {
    param($Recorder)
    if($Recorder.ClosureReceipt){return}
    if($Recorder.Owner.NoProcessCreatedConfirmed){
        $Recorder.Closure=[pscustomobject]@{Schema='iw7.voice-recorder-no-child/1';NativeNoChildConfirmed=$true;OriginalHandleCreated=$false;Failure=$Recorder.Failure}
    }else{
        if(!$Recorder.ProbeIdentity){$Recorder.ProbeIdentity=ConvertTo-IW7VoiceRecorderIdentity $Recorder.Owner.Original}
        $terminal=ConvertTo-IW7VoiceRecorderIdentity $Recorder.Owner.Terminal
        Assert-IW7VoiceRecorderIdentity $Recorder $terminal -Terminal
        $producer=$Recorder.Owner.Result
        if(!$producer -or !$producer.ProducerOutputClosed -or !$producer.OriginalHandleWaitSignaled -or $producer.PID -ne $terminal.PID -or
            $producer.CreationFileTime -ne $terminal.CreationFileTime -or $producer.ExitCode -ne $terminal.ExitCode -or
            $producer.ExitCodeUInt32 -ne $terminal.ExitCodeUInt32 -or $producer.ImageEvidenceMode -cne $terminal.ImageEvidenceMode -or
            $producer.ImageQueryAfterExitSucceeded -ne $terminal.ImageQueryAfterExitSucceeded -or $producer.ImageQueryAfterExitWin32Error -ne $terminal.ImageQueryAfterExitWin32Error -or
            $producer.RetainedImageGuardVerified -isnot [bool] -or !$producer.RetainedImageGuardVerified){throw 'Original recorder producer EOF/terminal evidence differs; retain owner.'}
        if((Get-IW7VoiceRecorderOwnerFileId $Recorder.Owner Image) -cne $Recorder.HelperLedger.FileId){throw 'Retained terminal helper physical identity differs.'}
        $Recorder.Closure=[pscustomobject]@{Schema='iw7.offline-asr-owned-closure/1';Original=$Recorder.ProbeIdentity;Terminal=$terminal;
            HelperFileId=$Recorder.HelperLedger.FileId;ProducerOutputClosed=$true;InitialReceipt=$Recorder.InitialReceipt;LeaseRegistered=$Recorder.LeaseRegistered;Failure=$Recorder.Failure;
            Source=$Recorder.SourceReceipt;Registration=$Recorder.RegistrationEvidence;AdmissionReceipt=$Recorder.AdmissionReceipt;
            NativeAdmissionReceiptPath=$Recorder.Owner.AdmissionReceiptPath;NativeAdmissionReceiptSHA256=$Recorder.Owner.AdmissionReceiptSHA256;NativeAdmissionReceiptFileId=$Recorder.Owner.AdmissionReceiptFileId;
            ImageEvidenceMode=$terminal.ImageEvidenceMode;ImageQueryAfterExitSucceeded=$terminal.ImageQueryAfterExitSucceeded;
            ImageQueryAfterExitWin32Error=$terminal.ImageQueryAfterExitWin32Error;RetainedImageGuardVerified=$terminal.RetainedImageGuardVerified}
    }
    # Serialize the actual kernel snapshots while the original handle and file
    # guard are retained. Successful scoring also requires Terminal.ExitCode=0.
    $Recorder.ClosureReceipt=Write-IW7VoiceRecorderReceipt $Recorder 'closure' $Recorder.Closure
}
function Invoke-IW7VoiceRecorderCleanupAttempt {
    param($Recorder)
    $Recorder.RecoveryAttempts++
    try{
        if(!$Recorder.OwnershipResolved){
            # A faulted/completed Task is never closure authority. CloseOriginal
            # uses only the retained creation handle and bounded producer pipes.
            $null=$Recorder.Owner.CloseOriginal()
            Save-IW7VoiceRecorderClosure $Recorder
            $Recorder.Owner.DisposeChecked()
            if(!$Recorder.Owner.OwnershipResolved){throw 'Original recorder checked disposal unconfirmed; retain owner.'}
            $Recorder.OwnershipResolved=$true;$Recorder.HelperLedger.OwnerResolved=$true
        }
        if($Recorder.OutputHandle){$Recorder.OutputHandle.Dispose();$Recorder.OutputHandle=$null}
        if($Recorder.HelperLedger){Restore-IW7VoiceRecorderHelperCopy $Recorder.HelperLedger}
        $Recorder.CleanupError=$null
        $null=Write-IW7VoiceRecorderReceipt $Recorder 'cleanup' ([pscustomobject]@{Schema='iw7.voice-recorder-cleanup/1';
            OwnershipResolved=$true;HelperClosed=[bool]$(!$Recorder.HelperLedger -or $Recorder.HelperLedger.Closed);HelperCleanupPhase=$(if($Recorder.HelperLedger){$Recorder.HelperLedger.CleanupPhase});
            ImageDeletionProof=$(if($Recorder.HelperLedger){$Recorder.HelperLedger.ImageDeletionProof});DirectoryDispositionProof=$(if($Recorder.HelperLedger){$Recorder.HelperLedger.DirectoryDispositionProof});
            Closure=$Recorder.ClosureReceipt;Attempt=$Recorder.RecoveryAttempts})
        return $true
    }catch{
        $Recorder.CleanupError=$_.Exception.Message
        try{$null=Write-IW7VoiceRecorderReceipt $Recorder 'pending' ([pscustomobject]@{Schema='iw7.voice-recorder-pending/1';
            OwnershipResolved=$Recorder.OwnershipResolved;HelperClosed=[bool]$(!$Recorder.HelperLedger -or $Recorder.HelperLedger.Closed);HelperCleanupPhase=$(if($Recorder.HelperLedger){$Recorder.HelperLedger.CleanupPhase});Attempt=$Recorder.RecoveryAttempts;
            Error=$Recorder.CleanupError;LeaseToken=$Recorder.LeaseToken;HostPID=$PID;HostMustRemainAlive=$true})}catch{
            $Recorder.CleanupError+='; pending receipt: '+$_.Exception.Message
        }
        return $false
    }
}
function Complete-IW7VoicePairRecorder {
    param($Recorder)
    if($Recorder.Finished){if(!$Recorder.Result.Completed){throw $Recorder.Failure};return $Recorder.Result}
    $failure=$null;$probe=$null
    try{
        if(!$Recorder.Task){throw 'Original recorder task unavailable.'}
        # RunBounded owns the <=75-second deadline; no external process wait or
        # PID-based termination can replace its original creation handle.
        $probe=$Recorder.Task.GetAwaiter().GetResult()
        if($probe.ExitCode -ne 0 -or $probe.TimedOut -or $probe.LogBoundExceeded -or $probe.Failure -or
            !$probe.OriginalHandleWaitSignaled -or !$probe.ProducerOutputClosed){throw 'Owned recorder failed; retain raw diagnostics.'}
    }catch{$failure=$_;$Recorder.Failure=$_.Exception.Message}
    $clean=Invoke-IW7VoiceRecorderCleanupAttempt $Recorder
    if(!$clean){
        $exception=[InvalidOperationException]::new('Recorder cleanup pending: '+$Recorder.CleanupError+'. Keep this host, helper and lease alive.')
        $exception.Data['RecorderOwner']=$Recorder;throw $exception
    }
    try{
        if($failure){throw $failure}
        $terminal=$Recorder.Closure.Terminal
        if($terminal.ExitCode -ne 0 -or $probe.PID -ne $terminal.PID -or $probe.CreationFileTime -ne $terminal.CreationFileTime){throw 'Recorder result differs from original terminal closure.'}
        # The WAV cannot be analyzed/scored until producer closure is proven.
        # Keep this read-only file object through the witness's AnalyzeWAV call;
        # the CLI cleanup gate releases it only after the witness returns.
        $Recorder.WAVHandle=[IO.File]::Open($Recorder.WAVPath,'Open','Read','Read')
        $Recorder.WAVFileHandle=$Recorder.WAVHandle.SafeFileHandle
        $wavIdentity=[IW7AgentPairNtfs]::Identity($Recorder.WAVHandle.SafeFileHandle)
        if($Recorder.WAVHandle.Length -lt 48 -or $Recorder.WAVHandle.Length -gt 44+$Recorder.Seconds*192000){throw 'Receiver WAV exceeded retained bound.'}
        $sha=[Security.Cryptography.SHA256]::Create()
        try{$wavHash=[Convert]::ToHexString($sha.ComputeHash($Recorder.WAVHandle))}finally{$sha.Dispose()}
        $wave=Assert-IW7ReceiverWAV $Recorder.WAVPath $Recorder.Seconds
        $check=[IO.File]::Open($Recorder.WAVPath,'Open','Read','Read')
        try{if([IW7AgentPairNtfs]::Identity($check.SafeFileHandle) -cne $wavIdentity){throw 'Retained receiver WAV physical identity changed.'}}finally{$check.Dispose()}
        $Recorder.Result=[pscustomobject]@{Completed=$true;ExitCode=$probe.ExitCode;TimedOut=$probe.TimedOut;WAVPath=$Recorder.WAVPath;WAV=$wave;
            WAVSHA256=$wavHash;WAVFileIdentity=$wavIdentity;Probe=$probe;RecorderClosure=$Recorder.ClosureReceipt;
            Source=$Recorder.SourceReceipt;Registration=$Recorder.RegistrationEvidence;AdmissionReceipt=$Recorder.AdmissionReceipt;
            ProducerOutputClosed=$true;OwnershipResolved=$true;Scope='INCLUDE_TARGET_PROCESS_TREE; snapshot/race/orphan limits retained'}
    }catch{
        $failure=$_;$Recorder.Failure=$_.Exception.Message
        $Recorder.Result=[pscustomobject]@{Completed=$false;ExitCode=$(if($probe){$probe.ExitCode}else{$null});TimedOut=$(if($probe){$probe.TimedOut}else{$null});
            WAVPath=$Recorder.WAVPath;WAV=$null;WAVSHA256=$null;Probe=$probe;RecorderClosure=$Recorder.ClosureReceipt;Failure=$Recorder.Failure;
            Source=$Recorder.SourceReceipt;Registration=$Recorder.RegistrationEvidence;AdmissionReceipt=$Recorder.AdmissionReceipt;
            ProducerOutputClosed=$true;OwnershipResolved=$true}
    }
    $Recorder.ResultReceipt=Write-IW7VoiceRecorderReceipt $Recorder 'result' $Recorder.Result
    $Recorder.Finished=$true
    if($failure){$failure.Exception.Data['RecorderOwner']=$Recorder;throw $failure}
    return $Recorder.Result
}
function Test-IW7VoiceRecorderCleanupPending($Record){
    !$Record.OwnershipResolved -or ($Record.HelperLedger -and !$Record.HelperLedger.Closed) -or $Record.CleanupError -or !$Record.SourceClosed -or !$Record.SourceClosureReceipt
}
function Close-IW7VoiceRecorderWAVGuard($Record){
    if(!$Record.WAVHandle){return}
    if(!$Record.WAVFileHandle){$Record.WAVFileHandle=$Record.WAVHandle.SafeFileHandle}
    if(!$Record.WAVFileHandle.IsClosed){$Record.WAVHandle.Dispose()}
    if(!$Record.WAVFileHandle.IsClosed){throw 'Retained WAV guard disposal unconfirmed; source/host/lease retained.'}
    $Record.WAVHandle=$null;$Record.WAVFileHandle=$null
}
function Invoke-IW7VoiceRecorderSourceCleanup {
    param($Records)
    # The source guard outlives every producer, helper and retained WAV reader.
    # Include all same-provider records in the host, not merely this CaseRoot.
    foreach($record in $Records){
        if(!$record.OwnershipResolved -or ($record.HelperLedger -and !$record.HelperLedger.Closed) -or $record.OutputHandle -or $record.CleanupError){continue}
        try{Close-IW7VoiceRecorderWAVGuard $record}catch{
            $record.CleanupError=$_.Exception.Message
            $null=Write-IW7VoiceRecorderReceipt $record 'pending' ([pscustomobject]@{Schema='iw7.runtime-recorder-source-pending/1';
                SourceClosed=$record.SourceClosed;WAVGuardClosed=$false;Error=$record.CleanupError;LeaseToken=$record.LeaseToken;HostMustRemainAlive=$true})
            throw
        }
    }
    foreach($record in $Records){
        if($record.SourceClosed -and $record.SourceClosureReceipt){continue}
        if(!$record.SourceProvider){
            if($record.Owner -or $record.HelperLedger){throw 'Original recorder source provider missing; retain resources.'}
            $record.SourceClosed=$true
        }else{
            $sharing=@((Get-IW7VoiceRecorderRegistry).Values|Where-Object {[object]::ReferenceEquals($_.SourceProvider,$record.SourceProvider)})
            if(@($sharing|Where-Object {$_.LeaseToken -cne $record.LeaseToken -or !$_.OwnershipResolved -or ($_.HelperLedger -and !$_.HelperLedger.Closed) -or $_.OutputHandle -or $_.WAVHandle -or $_.CleanupError}).Count){continue}
            try{Close-IW7ResourceRecorderProvider $record.SourceProvider $record.LeaseToken}catch{
                $record.CleanupError=$_.Exception.Message
                $null=Write-IW7VoiceRecorderReceipt $record 'pending' ([pscustomobject]@{Schema='iw7.runtime-recorder-source-pending/1';
                    SourceClosed=$false;WAVGuardClosed=(!$record.WAVHandle);Error=$record.CleanupError;LeaseToken=$record.LeaseToken;HostMustRemainAlive=$true})
                throw
            }
            foreach($shared in $sharing){$shared.SourceClosed=$true}
        }
        $record.SourceClosureReceipt=Write-IW7VoiceRecorderReceipt $record 'source-closure' ([pscustomobject]@{Schema='iw7.runtime-recorder-source-closure/1';
            Source=$(if($record.SourceProvider){Get-IW7ResourceRecorderProviderEvidence $record.SourceProvider});SourceGuardClosed=$true;
            OwnershipResolved=$record.OwnershipResolved;HelperClosed=[bool]$(!$record.HelperLedger -or $record.HelperLedger.Closed);WAVGuardClosed=(!$record.WAVHandle);LeaseToken=$record.LeaseToken})
    }
}
function Wait-IW7VoiceRecorderCleanup {
    param([string]$CaseRoot,[string]$LeaseToken)
    # This is the entry-CLI lifetime boundary. Do not wrap it in a catch that
    # exits pwsh -File: unresolved original owners must outlive every refusal.
    $nonce=[guid]::NewGuid().ToString('N');$requestPath=Join-Path $CaseRoot 'recorder-recovery-request.local.json'
    $automatic=0;$lastRequestHash='';$pendingPrinted=$false;$lastHeartbeat=0L;$nextSeries=0L
    while($true){
        try{
            $records=@(Get-IW7VoiceRecorderOwners $CaseRoot $LeaseToken)
            Invoke-IW7VoiceRecorderSourceCleanup $records
            $pending=@($records|Where-Object{Test-IW7VoiceRecorderCleanupPending $_})
            if(!$pending.Count){
                return
            }
            if($automatic -ge 3 -and [Environment]::TickCount64 -ge $nextSeries){$automatic=0}
            $retry=$automatic -lt 3
            if($retry){$automatic++}
            elseif(Test-Path -LiteralPath $requestPath){
                $stream=[IO.File]::Open($requestPath,'Open','Read','Read')
                try{
                    if($stream.Length -gt 4096){throw 'Recovery request exceeds bound.'}
                    $sha=[Security.Cryptography.SHA256]::Create()
                    try{$requestHash=[Convert]::ToHexString($sha.ComputeHash($stream))}finally{$sha.Dispose()}
                    $stream.Position=0;$reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8,$true,1024,$true)
                    try{$request=$reader.ReadToEnd()|ConvertFrom-Json}finally{$reader.Dispose()}
                }finally{$stream.Dispose()}
                if($requestHash -cne $lastRequestHash){
                    $lastRequestHash=$requestHash
                    if($request.Schema -cne 'iw7.voice-recorder-recovery-request/1' -or $request.Nonce -cne $nonce -or
                        $request.Action -cne 'RetryOriginal' -or @($request.PSObject.Properties).Count -ne 3){throw 'Exact nonce/RetryOriginal request required; owner retained.'}
                    $retry=$true
                }
            }
            if(!$retry){
                # Passive wait on the retained handle can notice a later exit.
                # It confers no authority to target another PID or IW7 process.
                foreach($record in $pending){
                    if(!$record.OwnershipResolved -and $record.Owner.HasProcess -and $record.Owner.Wait(0)){$retry=$true}
                }
            }
            if($retry){
                foreach($record in $pending){$null=Invoke-IW7VoiceRecorderCleanupAttempt $record}
                Invoke-IW7VoiceRecorderSourceCleanup $records
                if($automatic -eq 3){$nextSeries=[Environment]::TickCount64+30000L}
            }
            $pending=@($records|Where-Object{Test-IW7VoiceRecorderCleanupPending $_})
            if(!$pending.Count){continue}
            if(!$pendingPrinted){
                foreach($record in $pending){$null=Write-IW7VoiceRecorderReceipt $record 'awaiting-recovery' ([pscustomobject]@{
                    Schema='iw7.voice-recorder-recovery/1';Nonce=$nonce;RequestPath=$requestPath;Action='RetryOriginal';HostPID=$PID;
                    LeaseToken=$LeaseToken;AutomaticAttemptLimit=3;RetrySeriesDelayMs=30000;OwnerRetained=$true;HostMustRemainAlive=$true;Error=$record.CleanupError})}
                Write-Warning "Recorder awaiting recovery in this host PID $PID. Keep this CLI alive. Nonce=$nonce Request=$requestPath"
                $pendingPrinted=$true
            }
        }catch{
            # Receipt/read/identity errors cannot make the entry CLI terminal.
            # There is deliberately no abandon, PID-reopen or lease release.
            Write-Warning ('Recorder recovery refused; host/owners/lease retained: '+$_.Exception.Message)
        }
        if([Environment]::TickCount64-$lastHeartbeat -ge 60000){Write-Information "Recorder cleanup pending; host PID $PID remains active; original owners and lease retained." -InformationAction Continue;$lastHeartbeat=[Environment]::TickCount64}
        Start-Sleep -Seconds 15
    }
}
