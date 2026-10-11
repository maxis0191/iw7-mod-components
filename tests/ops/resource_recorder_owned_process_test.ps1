param([string]$RepoRoot=(Resolve-Path "$PSScriptRoot/../..").Path)
$ErrorActionPreference='Stop'
# Execute the Runtime API with pure native/reflection/syscall doubles. Real
# source streams, hashes and test-local durable publication are retained. No
# compiler, lease admission, process creation, audio or production registry.
$root=Join-Path ([IO.Path]::GetTempPath()) ('iw7-recorder-admission-'+[guid]::NewGuid().ToString('N'))
$ops=Join-Path $root 'ops';$source=Join-Path $ops 'voice-agent/Recorder-Probe.cs';[IO.Directory]::CreateDirectory((Split-Path $source -Parent))|Out-Null
[IO.File]::Copy((Join-Path $RepoRoot 'ops/Resource-RecorderOwnedProcess.Core.ps1'),(Join-Path $ops 'Resource-RecorderOwnedProcess.Core.ps1'))
[IO.File]::WriteAllText($source,'Pure source-loader fixture; never compiled.')
. (Join-Path $ops 'Resource-RecorderOwnedProcess.Core.ps1')
$checks=0;function Check($Value,[string]$Message){$script:checks++;if(!$Value){throw $Message}}
function Refuses([scriptblock]$Body,[string]$Message){$failed=$false;try{&$Body|Out-Null}catch{$failed=$true};Check $failed $Message}
$token=[guid]::NewGuid().ToString('N');$scope=Join-Path $root 'pair';$helperRoot=Join-Path $scope ('voice-pair-helper/'+[guid]::NewGuid().ToString('N'));[IO.Directory]::CreateDirectory($helperRoot)|Out-Null
$image=Join-Path $helperRoot 'receiver-probe.exe';[IO.File]::WriteAllBytes($image,[byte[]](1..16))
$helper=[pscustomobject]@{Scope=$scope;Root=$helperRoot;Image=$image;SHA256=(Get-FileHash $image).Hash;FileId='1234ABCD:0000000000000002';Bytes=16L;Closed=$false;HardLinked=$false}
$hostRow=[pscustomobject]@{PID=$PID;Image='C:\pure-host\pwsh.exe';CreatedUtc='2026-10-07T12:00:00Z'}
$statePath=Join-Path $root 'test-state.json';$script:inventory=@($hostRow);$script:imports=0;$script:saves=0;$script:saveFails=$false;$script:importFails=$false
$assembly=[pscustomobject]@{FullName='pure-reflection-double'};$module=[pscustomobject]@{ModuleVersionId=[guid]::NewGuid()}
$script:native=[pscustomobject]@{FullName='IW7.VoicePairDraft.ProbeAdmission';Assembly=$assembly;Module=$module}
function Invoke-IW7ResourceLock([scriptblock]$Body){&$Body}
function Read-IW7ResourceState {Get-Content -LiteralPath $statePath -Raw|ConvertFrom-Json}
function Save-IW7ResourceState($State){if($script:saveFails){throw 'Uncertain test-local publication.'};[IO.File]::WriteAllText($statePath,($State|ConvertTo-Json -Depth 12));$script:saves++}
function Get-IW7ResourceProcesses {$script:inventory}
function Test-IW7ResourceIdentity($A,$B){$A.PID -eq $B.PID -and $A.Image -ceq $B.Image -and ([datetimeoffset]$A.CreatedUtc).UtcTicks -eq ([datetimeoffset]$B.CreatedUtc).UtcTicks}
function Import-IW7ResourceRecorderSource([string]$Source){$script:imports++;if($script:importFails){throw 'Synthetic compile failure.'};Check ($script:adopted -and $script:adopted.SourceGuard.CanRead) 'Loader ran before guard adoption.';$script:native}
function Assert-IW7ResourceRecorderNativeContract($Type){if(![object]::ReferenceEquals($Type,$script:native)){throw 'Foreign synthetic reflection type.'}}
function Get-IW7ResourceRecorderFileIdentity($Type,[IO.FileStream]$Stream){if(![object]::ReferenceEquals($Type,$script:native) -or !$Stream.CanRead){throw 'Foreign source guard.'};'1234ABCD:0000000000000001'}
function Assert-IW7ResourceRecorderOwner($Owner,$Entry){if(!$Owner -or !$Owner.SyntheticOriginal){throw 'Foreign pure owner.'}}
function Assert-IW7ResourceRecorderOpaqueWitness($Witness,$Owner,$Entry){if(!$Witness -or !$Witness.MatchesOwner($Owner) -or !$Witness.MatchesSourceProvider($Entry.Provider)){throw 'Foreign synthetic witness.'}}
function Assert-IW7ResourceRecorderPermit($Permit,$Owner,$Entry){if(!$Permit -or ![object]::ReferenceEquals($Permit.Owner,$Owner) -or ![object]::ReferenceEquals($Permit.Provider,$Entry.Provider)){throw 'Synthetic permit missing/foreign.'}}
function Reset-State {
    $lease=[pscustomobject]@{Token=$token;Scope=$scope;Kind='Runtime';PhysicalBytes=20GB;CommitBytes=20GB;OwnerIdentity=$hostRow;Phase='Pending';Processes=@()}
    [IO.File]::WriteAllText($statePath,([pscustomobject]@{Leases=@($lease)}|ConvertTo-Json -Depth 12));$script:inventory=@($hostRow)
}
function New-Case {
    Reset-State
    $owner=[pscustomobject]@{SyntheticOriginal=$true;OwnershipResolved=$false;Captures=0;Permits=0;PermitObjects=0;Resumes=0;ThrowPermit=$false;NullPermit=$false;ChangeSecond=$false;
        PID=[uint32]32123;Created=134358659862396973L;Deadline=([Environment]::TickCount64+1000L);Nonce=[guid]::NewGuid().ToString('N');WitnessScope=$scope;WitnessImage=$image;WitnessFileId=$helper.FileId;WitnessSHA=$helper.SHA256}
    $owner|Add-Member ScriptMethod CaptureAdmissionWitness {
        $this.Captures++;if($this.ChangeSecond -and $this.Captures -eq 2){$this.Created++}
        $w=[pscustomobject]@{Owner=$this;Provider=$provider;PID=$this.PID;CreationFileTime=$this.Created;Image=$this.WitnessImage;ImageFileId=$this.WitnessFileId;ImageSHA256=$this.WitnessSHA;ImageBytes=16L;
            PairScope=$this.WitnessScope;HelperRoot=$helper.Root;SourceProviderId=$provider.Id;SourceSHA256=$pin;SourceFileId=$provider.SourceFileId;LeaseToken=$token;
            LaunchNonce=$this.Nonce;SourceSchema='iw7.runtime-recorder-admission/1';Suspended=$true;CapturedTick=[Environment]::TickCount64;RegistrationDeadlineTick=$this.Deadline}
        $w|Add-Member ScriptMethod MatchesOwner {param($o)[object]::ReferenceEquals($this.Owner,$o)}
        $w|Add-Member ScriptMethod MatchesSourceProvider {param($p)[object]::ReferenceEquals($this.Provider,$p)}
        $w|Add-Member ScriptMethod MatchesWitness {param($w)[object]::ReferenceEquals($this.Owner,$w.Owner) -and $this.PID -eq $w.PID -and $this.CreationFileTime -eq $w.CreationFileTime -and $this.LaunchNonce -ceq $w.LaunchNonce}
        $w
    }
    $owner|Add-Member ScriptMethod CreateRegistrationPermit {
        param($Witness,$Token,$Provider)
        $this.Permits++;if($this.ThrowPermit){throw 'Synthetic factory failure after Save.'};if($this.NullPermit){return $null}
        $this.PermitObjects++;[pscustomobject]@{Owner=$this;Provider=$Provider}
    }
    $owner|Add-Member ScriptMethod Resume {param($Permit)$this.Resumes++}
    $child=[pscustomobject]@{PID=32123;Image=$null;CreatedUtc=[datetime]::FromFileTimeUtc($owner.Created).ToString('o')}
    $script:inventory=@($hostRow,$child);$entry=(Get-IW7ResourceRecorderProviders)[$provider.Id];$entry.Owners.Clear();$entry.Owners.Add($owner)
    [pscustomobject]@{Owner=$owner;Child=$child}
}
$providers=Get-IW7ResourceRecorderProviders
try{
    Reset-State;$pin=(Get-FileHash $source).Hash;$script:adopted=$null
    $bad=Initialize-IW7ResourceRecorderProvider -Token $token -SourceSHA256 ('0'*64) -OnAcquired {param($p)$script:adopted=$p}
    Check ([object]::ReferenceEquals($bad,$script:adopted) -and $bad.State -ceq 'Failed' -and $bad.SourceGuard.CanRead -and $script:imports -eq 0) 'Failed digest did not retain guard before loader.'
    Close-IW7ResourceRecorderProvider $bad $token;Check ($bad.State -ceq 'Closed') 'Failed provider guard could not close without child.'
    $script:importFails=$true
    $failed=Initialize-IW7ResourceRecorderProvider -Token $token -SourceSHA256 $pin -OnAcquired {param($p)$script:adopted=$p}
    Check ($failed.State -ceq 'Failed' -and $failed.SourceGuard.CanRead -and [object]::ReferenceEquals($script:adopted,$failed)) 'Compile failure discarded adopted source guard.'
    Close-IW7ResourceRecorderProvider $failed $token;$script:importFails=$false
    $provider=Initialize-IW7ResourceRecorderProvider -Token $token -SourceSHA256 $pin -OnAcquired {param($p)$script:adopted=$p}
    $entry=(Get-IW7ResourceRecorderProviders)[$provider.Id]
    Check ($provider.State -ceq 'Ready' -and $provider.SourceFileId -ceq '1234ABCD:0000000000000001') 'Retained source provider not ready.'
    Refuses {[IO.File]::Open($source,'Open','Write','ReadWrite').Dispose()} 'Source guard allowed writes.'
    $imports=$script:imports;$same=Initialize-IW7ResourceRecorderProvider -Token $token -SourceSHA256 $pin -OnAcquired {param($p)$script:adopted=$p}
    Check ([object]::ReferenceEquals($same,$provider) -and $script:imports -eq $imports) 'Same lease provider recompiled/adopted another type.'
    $case=New-Case;$result=Add-IW7ResourceOwnedRuntimeRecorder -Token $token -Provider $provider -Owner $case.Owner -Helper $helper
    Check ($result.Receipt.EvidenceMode -ceq 'CimImageNullOriginalSuspendedRecorder' -and $null -eq $result.Receipt.PassiveImage) 'Only actual null gets original-handle mode.'
    Check ($case.Owner.Captures -eq 2 -and $case.Owner.Permits -eq 1 -and $case.Owner.Resumes -eq 0) 'API did not bracket one inventory or resumed.'
    $saved=Read-IW7ResourceState;Check ($saved.Leases[0].Processes.Count -eq 1 -and $saved.Leases[0].Phase -ceq 'Running' -and $saved.Leases[0].Processes[0].OwnedAdmission.SourceSHA256 -ceq $pin) 'Evidence not persisted before permit.'
    Refuses {Close-IW7ResourceRecorderProvider $provider $token} 'Source provider closed with unresolved original child.'
    Refuses {Add-IW7ResourceOwnedRuntimeRecorder $token $provider $case.Owner $helper} 'Duplicate child minted permit.'
    Check ($case.Owner.Permits -eq 1) 'Duplicate reached factory again.'
    $case=New-Case;$case.Child.Image=$image;$result=Add-IW7ResourceOwnedRuntimeRecorder $token $provider $case.Owner $helper
    Check ($result.Receipt.EvidenceMode -ceq 'CimAndOriginalSuspendedRecorder') 'Nonempty exact passive image mode lost.'
    foreach($badImage in @('',' ','C:\foreign\receiver-probe.exe',123)){$case=New-Case;$case.Child.Image=$badImage;Refuses {Add-IW7ResourceOwnedRuntimeRecorder $token $provider $case.Owner $helper} 'Invalid passive image accepted.';Check ($case.Owner.Permits -eq 0 -and $case.Owner.Resumes -eq 0) 'Invalid image permitted execution.'}
    $case=New-Case;$case.Child.PSObject.Properties.Remove('Image');Refuses {Add-IW7ResourceOwnedRuntimeRecorder $token $provider $case.Owner $helper} 'Missing image field treated as null.'
    foreach($delta in @(-11,11)){$case=New-Case;$case.Child.CreatedUtc=[datetime]::FromFileTimeUtc($case.Owner.Created+$delta).ToString('o');Refuses {Add-IW7ResourceOwnedRuntimeRecorder $token $provider $case.Owner $helper} 'Creation beyond ten ticks accepted.'}
    $case=New-Case;$case.Child.CreatedUtc=[datetime]::FromFileTimeUtc($case.Owner.Created+10).ToString('o');$result=Add-IW7ResourceOwnedRuntimeRecorder $token $provider $case.Owner $helper;Check ($result.Receipt.PassiveCreationDeltaTicks -eq 10) 'Ten-tick boundary changed.'
    $case=New-Case;$script:inventory+=,$case.Child;Refuses {Add-IW7ResourceOwnedRuntimeRecorder $token $provider $case.Owner $helper} 'Duplicate CIM child accepted.'
    $case=New-Case;$case.Owner.ChangeSecond=$true;Refuses {Add-IW7ResourceOwnedRuntimeRecorder $token $provider $case.Owner $helper} 'Changed second witness accepted.'
    $case=New-Case;$case.Owner.Deadline=[Environment]::TickCount64;Refuses {Add-IW7ResourceOwnedRuntimeRecorder $token $provider $case.Owner $helper} 'Expired witness accepted.'
    foreach($field in @('WitnessScope','WitnessImage','WitnessFileId','WitnessSHA')){$case=New-Case;$case.Owner.$field+='wrong';Refuses {Add-IW7ResourceOwnedRuntimeRecorder $token $provider $case.Owner $helper} 'Foreign helper/source scope tuple accepted.'}
    foreach($kind in @('Build','Extract','Analysis')){$case=New-Case;$s=Read-IW7ResourceState;$s.Leases[0].Kind=$kind;Save-IW7ResourceState $s;Refuses {Add-IW7ResourceOwnedRuntimeRecorder $token $provider $case.Owner $helper} 'Runtime API admitted another lease kind.'}
    foreach($budget in @('PhysicalBytes','CommitBytes')){$case=New-Case;$s=Read-IW7ResourceState;$s.Leases[0].$budget=19GB;Save-IW7ResourceState $s;Refuses {Add-IW7ResourceOwnedRuntimeRecorder $token $provider $case.Owner $helper} 'Reduced pair reservation accepted.'}
    foreach($field in @('Image','Root','FileId','SHA256','Bytes','HardLinked')){
        $case=New-Case;$badHelper=$helper.PSObject.Copy()
        switch($field){'Image'{$badHelper.Image+='wrong'} 'Root'{$badHelper.Root+='wrong'} 'FileId'{$badHelper.FileId='invalid'} 'SHA256'{$badHelper.SHA256='invalid'} 'Bytes'{$badHelper.Bytes=0L} 'HardLinked'{$badHelper.HardLinked=$true}}
        Refuses {Add-IW7ResourceOwnedRuntimeRecorder $token $provider $case.Owner $badHelper} 'Foreign helper ledger accepted.'
        Check ($case.Owner.Captures -eq 0 -and $case.Owner.Permits -eq 0) 'Invalid helper tuple reached original capture/permit.'
    }
    $case=New-Case;$copy=$provider.PSObject.Copy();Refuses {Add-IW7ResourceOwnedRuntimeRecorder $token $copy $case.Owner $helper} 'Copied provider adopted.'
    foreach($field in @('SourceSHA256','SourceFileId','AssemblyName','ModuleVersionId')){
        $case=New-Case;$old=$provider.$field;$provider.$field='invalid';Refuses {Add-IW7ResourceOwnedRuntimeRecorder $token $provider $case.Owner $helper} 'Source/type/assembly provider mutation accepted.';$provider.$field=$old
    }
    $case=New-Case;$case.Owner.SyntheticOriginal=$false;Refuses {Add-IW7ResourceOwnedRuntimeRecorder $token $provider $case.Owner $helper} 'Foreign owner accepted before source-bound capture.'
    Check ($case.Owner.Captures -eq 0) 'Foreign owner was invoked before validation.'
    $case=New-Case;$s=Read-IW7ResourceState;$s.Leases[0].OwnerIdentity.PID=$PID+1;Save-IW7ResourceState $s;Refuses {Add-IW7ResourceOwnedRuntimeRecorder $token $provider $case.Owner $helper} 'Foreign host lease accepted.'
    $case=New-Case;$s=Read-IW7ResourceState;$s.Leases[0].Scope=Join-Path $scope 'other';Save-IW7ResourceState $s;Refuses {Add-IW7ResourceOwnedRuntimeRecorder $token $provider $case.Owner $helper} 'Wrong pair scope accepted.'
    $case=New-Case;$entry.Owners.Clear();Refuses {Add-IW7ResourceOwnedRuntimeRecorder $token $provider $case.Owner $helper} 'Unadopted owner accepted.'
    $case=New-Case;$script:saveFails=$true;Refuses {Add-IW7ResourceOwnedRuntimeRecorder $token $provider $case.Owner $helper} 'Failed Save returned permit.';Check ($case.Owner.Permits -eq 0 -and (Read-IW7ResourceState).Leases[0].Processes.Count -eq 0) 'Failed Save reached factory or altered publication.';$script:saveFails=$false
    foreach($mode in @('ThrowPermit','NullPermit')){
        $case=New-Case;$case.Owner.$mode=$true;$returned=@();$failure=$null
        try{$returned=@(Add-IW7ResourceOwnedRuntimeRecorder $token $provider $case.Owner $helper)}catch{$failure=$_}
        $durable=Read-IW7ResourceState;$beforeHash=(Get-FileHash $statePath).Hash
        Check ($failure -and $returned.Count -eq 0 -and $failure.Exception.Data['RecorderRegistrationReceipt']) 'After-save permit failure returned result or lost durable receipt.'
        Check ($durable.Leases[0].Phase -ceq 'Running' -and $durable.Leases[0].Processes.Count -eq 1 -and $case.Owner.Permits -eq 1 -and $case.Owner.PermitObjects -eq 0 -and $case.Owner.Resumes -eq 0) 'After-save failure lost child/Running evidence or executed.'
        Refuses {Add-IW7ResourceOwnedRuntimeRecorder $token $provider $case.Owner $helper} 'After-save duplicate minted again.'
        Check ($case.Owner.Permits -eq 1 -and (Get-FileHash $statePath).Hash -ceq $beforeHash -and $provider.SourceGuard.CanRead) 'Duplicate altered durable evidence or retained source.'
        Refuses {Close-IW7ResourceRecorderProvider $provider $token} 'After-save unresolved child allowed source closure.'
    }
    $case.Owner.OwnershipResolved=$true;Close-IW7ResourceRecorderProvider $provider $token;Check ($provider.State -ceq 'Closed') 'Source closure after synthetic original disposal failed.'
    "PASS $checks pure Runtime recorder admission checks; native/reflection/CIM doubles, retained source streams and test-local publication; no compiler/child/audio/game/lease."
}finally{
    foreach($entry in @($providers.Values)){if(!$entry.Handle.IsClosed){$entry.Guard.Dispose()}}
    $providers.Clear()
    if(!$root.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase)){throw 'Pure admission fixture root escaped.'}
    Remove-Item -LiteralPath $root -Recurse -Force
}
