# Exact-process-tree recorder draft. Import never records audio.
function New-IW7VoiceRecorderHelperCopy {
    param([string]$CandidateRoot,[string]$ProbePath,[string]$ProbeSHA256,[string]$OutputRoot)
    Initialize-IW7AgentPairNtfs
    $scope=(Resolve-Path -LiteralPath $CandidateRoot).Path.TrimEnd('\','/')
    $relative='voice-pair-helper/'+[guid]::NewGuid().ToString('N')
    $root=Resolve-IW7BasePath $scope $relative;$image=Resolve-IW7BasePath $scope ($relative+'/receiver-probe.exe')
    if(Test-Path -LiteralPath $root){throw 'Fresh recorder helper directory required.'}
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
                FileId=[IW7AgentPairNtfs]::Identity($copy.SafeFileHandle);DirectoryId=[IW7AgentPairNtfs]::DirectoryIdentity($root);HardLinked=$false;Closed=$false}
        }finally{$copy.Dispose()}
        $ledger|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $OutputRoot 'recorder-helper.local.json')
        $ledger
    }finally{$source.Dispose()}
}
function Restore-IW7VoiceRecorderHelperCopy {
    param($Ledger)
    if($Ledger.Closed){return}
    if($Ledger.Schema -cne 'iw7.voice-recorder-helper/1' -or !$Ledger.Root.StartsWith($Ledger.Scope+'\voice-pair-helper\',[StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetDirectoryName($Ledger.Image) -ine $Ledger.Root -or [IO.Path]::GetFileName($Ledger.Image) -cne 'receiver-probe.exe' -or
        [IW7AgentPairNtfs]::DirectoryIdentity($Ledger.Root) -cne $Ledger.DirectoryId){throw 'Recorder helper cleanup identity conflict; retain it.'}
    $entries=@(Get-ChildItem -LiteralPath $Ledger.Root -Force)
    if($entries.Count -ne 1 -or $entries[0].FullName -ine $Ledger.Image -or $entries[0].Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Unknown recorder helper content; retain it.'}
    $deleteHandle=[IW7AgentPairNtfs]::OpenForDelete($Ledger.Image)
    $copy=[IO.FileStream]::new($deleteHandle,[IO.FileAccess]::Read)
    try{
        if([IW7AgentPairNtfs]::Identity($copy.SafeFileHandle) -cne $Ledger.FileId -or $copy.Length -ne $Ledger.Bytes){throw 'Recorder helper image identity differs.'}
        $sha=[Security.Cryptography.SHA256]::Create()
        try{$hash=[Convert]::ToHexString($sha.ComputeHash($copy))}finally{$sha.Dispose()}
        if($hash -cne $Ledger.SHA256){throw 'Recorder helper image hash differs; retain it.'}
        [IW7AgentPairNtfs]::DeleteByHandle($deleteHandle)
    }finally{$copy.Dispose()}
    $directory=[IW7AgentPairNtfs]::OpenForDelete($Ledger.Root)
    try{
        if([IW7AgentPairNtfs]::Identity($directory) -cne $Ledger.DirectoryId){throw 'Recorder helper directory identity differs; retain it.'}
        [IW7AgentPairNtfs]::DeleteByHandle($directory)
    }finally{$directory.Dispose()}
    $Ledger.Closed=$true
}
function Start-IW7VoicePairRecorder {
    param($Receiver,[string]$ProbePath,[string]$ProbeSHA256,[string]$OutputRoot,[ValidateRange(1,15)][int]$Seconds=12,[string]$LeaseToken,[string]$CandidateRoot)
    if(!$LeaseToken){throw 'Whole-pair helper reservation required.'}
    $leases=@((Get-IW7ResourceStatus).Leases|Where-Object Token -CEQ $LeaseToken)
    if($leases.Count -ne 1 -or $leases[0].Kind -cne 'Runtime' -or $leases[0].PhysicalBytes -ne 20GB -or $leases[0].CommitBytes -ne 20GB -or
        [IO.Path]::GetFullPath($CandidateRoot).TrimEnd('\','/') -ine $leases[0].Scope){throw 'Exact whole audio-pair20/20 scope required.'}
    if($ProbeSHA256 -cnotmatch '^[a-fA-F0-9]{64}$' -or $Receiver.ImageSHA256 -cnotmatch '^[a-fA-F0-9]{64}$'){throw 'Pinned probe/receiver hashes required.'}
    $receiverHandle=Get-Process -Id $Receiver.PID
    try{if($receiverHandle.HasExited -or $receiverHandle.Path -ine $Receiver.Image -or [uint64]$receiverHandle.StartTime.ToFileTimeUtc() -ne $Receiver.CreationFileTime){throw 'Receiver exact process identity changed.'}}finally{$receiverHandle.Dispose()}
    if((Get-FileHash -LiteralPath $Receiver.Image).Hash -ine $Receiver.ImageSHA256){throw 'Receiver image changed.'}
    if(!('IW7.VoicePairDraft.OwnedProbe' -as [type])){Add-Type -Path "$PSScriptRoot/Recorder-Probe.cs"}
    $stdout=Join-Path $OutputRoot 'receiver-probe.stdout.log';$stderr=Join-Path $OutputRoot 'receiver-probe.stderr.log';$wav=Join-Path $OutputRoot 'receiver.wav'
    foreach($file in @($stdout,$stderr,$wav)){if(Test-Path -LiteralPath $file){throw 'Fresh recorder outputs required.'}}
    $helper=New-IW7VoiceRecorderHelperCopy $CandidateRoot $ProbePath $ProbeSHA256 $OutputRoot
    $started=[Environment]::TickCount64
    $admission=$null
    try{
        $admission=[IW7.VoicePairDraft.OwnedProbe]::StartOwned($helper.Image,$helper.SHA256,
            [string[]]@('--record',"$Seconds","$($Receiver.PID)","$($Receiver.CreationFileTime)",$Receiver.Image,$Receiver.ImageSHA256,$wav),$stdout,$stderr,$Seconds+15)
        if(!$admission.Started.Task.Wait(1000)){throw 'Exact recorder launch identity timeout.'}
        $identity=$admission.Started.Task.GetAwaiter().GetResult()
        $registration=$admission.CaptureIdentity()
        if($identity.Exited -or $identity.Image -ine $helper.Image -or $registration.Exited -or $registration.PID -ne $identity.PID -or
            $registration.Image -ine $helper.Image -or $registration.CreationFileTime -ne $identity.CreationFileTime -or
            [Environment]::TickCount64 -ge $identity.RegistrationDeadlineTick){
            throw ('Recorder registration identity changed or expired: '+([pscustomobject]@{Expected=$identity;Actual=$registration;ExpectedImage=$helper.Image}|ConvertTo-Json -Compress -Depth 4))
        }
        Add-IW7ResourceProcess -Token $LeaseToken -ProcessId $identity.PID
        $registered=$admission.CaptureIdentity()
        if($registered.Exited -or $registered.PID -ne $identity.PID -or $registered.Image -ine $helper.Image -or
            $registered.CreationFileTime -ne $identity.CreationFileTime -or [Environment]::TickCount64 -ge $identity.RegistrationDeadlineTick){
            throw ('Recorder post-registration identity changed or expired: '+([pscustomobject]@{Expected=$identity;Actual=$registered}|ConvertTo-Json -Compress -Depth 4))
        }
        $admission.Admit()
    }catch{
        $launchFailure=$_
        if($admission){$admission.Refuse();try{$null=$admission.Completion.GetAwaiter().GetResult()}catch{}}
        try{Restore-IW7VoiceRecorderHelperCopy $helper}catch{$launchFailure.Exception.Data['RecorderHelperCleanup']=$_.Exception.Message}
        throw $launchFailure
    }
    [pscustomobject]@{Task=$admission.Completion;Receiver=$Receiver;Stdout=$stdout;Stderr=$stderr;WAVPath=$wav;Seconds=$Seconds;StartedTick=$started;OutputHandle=$null;OutputFileId=$null;Finished=$false;Result=$null;LeaseRegistered=$true;ProbeIdentity=$identity;HelperLedger=$helper}
}
function Get-IW7VoicePairRecorderState {
    param($Recorder)
    if($Recorder.Task.IsFaulted){throw $Recorder.Task.Exception}
    $text=''
    if(Test-Path -LiteralPath $Recorder.Stdout){
        if(!$Recorder.OutputHandle){$Recorder.OutputHandle=[IO.FileStream]::new($Recorder.Stdout,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite,1,[IO.FileOptions]::None);$Recorder.OutputFileId=[IW7AgentPairNtfs]::Identity($Recorder.OutputHandle.SafeFileHandle)}
        $check=[IO.File]::Open($Recorder.Stdout,'Open','Read','ReadWrite')
        try{if([IW7AgentPairNtfs]::Identity($check.SafeFileHandle) -cne $Recorder.OutputFileId){throw 'Recorder stdout identity changed.'}}finally{$check.Dispose()}
        if($Recorder.OutputHandle.Length -gt 4MB){throw 'Recorder stdout grew beyond bound.'}
        $Recorder.OutputHandle.Position=0;$bytes=[byte[]]::new([int]$Recorder.OutputHandle.Length);$Recorder.OutputHandle.ReadExactly($bytes);$text=[Text.Encoding]::UTF8.GetString($bytes)
    }
    [pscustomobject]@{OwnedIdentityValidated=$true;Exited=$Recorder.Task.IsCompleted;Stdout=$text}
}
function Complete-IW7VoicePairRecorder {
    param($Recorder)
    if($Recorder.Finished){return $Recorder.Result}
    try{
        # OwnedProbe retains the immutable helper image and original process
        # kernel handle; its watchdog kills only that helper, never IW7/tree.
        $result=$Recorder.Task.GetAwaiter().GetResult()
        if($result.ExitCode -ne 0 -or $result.TimedOut -or $result.LogBoundExceeded){throw 'Owned process-tree recorder failed; retain raw diagnostics.'}
        $wave=Assert-IW7ReceiverWAV $Recorder.WAVPath $Recorder.Seconds
        $Recorder.Result=[pscustomobject]@{Completed=$true;ExitCode=$result.ExitCode;TimedOut=$result.TimedOut;WAVPath=$Recorder.WAVPath;WAV=$wave;Probe=$result;Scope='INCLUDE_TARGET_PROCESS_TREE; snapshot/race/orphan limits retained'}
        $Recorder.Finished=$true;$Recorder.Result
    }finally{
        if($Recorder.OutputHandle){$Recorder.OutputHandle.Dispose();$Recorder.OutputHandle=$null}
        if($Recorder.Task.IsCompleted){Restore-IW7VoiceRecorderHelperCopy $Recorder.HelperLedger}
    }
}
