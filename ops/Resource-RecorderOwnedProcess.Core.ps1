# Exact Runtime recorder admission. The legacy PID/CIM and Tool APIs are unchanged.
function Get-IW7ResourceRecorderProviders {
    $key='IW7.ResourceScheduler.RecorderProviders.v1';$registry=[AppDomain]::CurrentDomain.GetData($key)
    if($null -eq $registry){$registry=@{};[AppDomain]::CurrentDomain.SetData($key,$registry)}
    $registry
}
function Get-IW7ResourceRecorderDigest([IO.FileStream]$Stream){
    if($null -eq $Stream -or $Stream.SafeFileHandle.IsClosed -or !$Stream.CanRead -or !$Stream.CanSeek){throw 'Retained recorder source guard unavailable.'}
    $position=$Stream.Position
    try{$Stream.Position=0;[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Stream))}finally{$Stream.Position=$position}
}
function Assert-IW7ResourceRecorderPath([string]$Path){
    if(![IO.Path]::IsPathFullyQualified($Path) -or [IO.Path]::GetFullPath($Path) -cne $Path){throw 'Canonical absolute recorder path required.'}
    $cursor=$Path
    while($cursor){if((Get-Item -LiteralPath $cursor -Force -ErrorAction Stop).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)){throw 'Recorder reparse ancestry refused.'};$cursor=Split-Path $cursor -Parent}
}
function Assert-IW7ResourceRecorderHost($Lease,$Processes){
    if($Lease.Kind -cne 'Runtime' -or $Lease.PhysicalBytes -ne 20GB -or $Lease.CommitBytes -ne 20GB -or $Lease.OwnerIdentity.PID -ne $PID){throw 'Current original host Runtime20/20 reservation required.'}
    $hosts=@($Processes|Where-Object PID -EQ $PID)
    if($hosts.Count -ne 1 -or !(Test-IW7ResourceIdentity $Lease.OwnerIdentity $hosts[0])){throw 'Original recorder host identity differs; retain reservation.'}
}
function Get-IW7ResourceRecorderFileIdentity($Type,[IO.FileStream]$Stream){
    $method=$Type.GetMethod('FileIdentity',[Reflection.BindingFlags]'Public,Static',$null,[type[]]@([IO.FileStream]),$null)
    if(!$method -or $method.ReturnType -ne [string]){throw 'Source-bound recorder file identity method missing.'}
    [string]$method.Invoke($null,[object[]]@($Stream))
}
function Import-IW7ResourceRecorderSource([string]$Source){@(Add-Type -TypeDefinition $Source -PassThru -ErrorAction Stop)}
function Assert-IW7ResourceRecorderNativeContract($Type){
    if($Type -isnot [type] -or $Type.FullName -cne 'IW7.VoicePairDraft.ProbeAdmission' -or !$Type.IsSealed -or @($Type.GetConstructors()).Count){throw 'Exact sealed recorder owner with private construction required.'}
    foreach($name in @('AdmissionWitness','RegistrationPermit')){
        $nested=$Type.GetNestedType($name,[Reflection.BindingFlags]'Public')
        if(!$nested -or !$nested.IsSealed -or $nested.Assembly -ne $Type.Assembly -or @($nested.GetConstructors()).Count -or
            @($nested.GetFields([Reflection.BindingFlags]'Instance,NonPublic,Public')|Where-Object {!$_.IsInitOnly}).Count){throw 'Opaque readonly recorder witness/permit required.'}
    }
    $witness=$Type.GetNestedType('AdmissionWitness',[Reflection.BindingFlags]'Public');$permit=$Type.GetNestedType('RegistrationPermit',[Reflection.BindingFlags]'Public')
    $capture=$Type.GetMethod('CaptureAdmissionWitness',[type[]]@());$factory=$Type.GetMethod('CreateRegistrationPermit',[type[]]@($witness,[string],[object]))
    $admit=$Type.GetMethod('Admit',[type[]]@($permit,[string],[string]))
    if(!$capture -or $capture.ReturnType -ne $witness -or !$factory -or $factory.ReturnType -ne $permit -or !$admit -or $admit.ReturnType -ne [void] -or
        @($Type.GetMethods()|Where-Object {$_.Name -ceq 'Admit'}).Count -ne 1){throw 'Exact witness factory and permit-only native admission required.'}
    foreach($name in @('PID','Image','CreationFileTime','Suspended','ImageFileId','ImageSHA256','ImageBytes','SourceSchema','PairScope','HelperRoot',
        'SourceProviderId','SourceSHA256','SourceFileId','LeaseToken','LaunchNonce','CapturedTick','RegistrationDeadlineTick')){
        $property=$witness.GetProperty($name)
        if(!$property -or !$property.GetGetMethod() -or $property.GetSetMethod($true)){throw 'Immutable native recorder witness properties required.'}
    }
    if($Type.GetField('ProviderSchema').GetRawConstantValue() -cne 'iw7.runtime-recorder-source/1'){throw 'Exact recorder source schema required.'}
}
function Initialize-IW7ResourceRecorderProvider {
    param([Parameter(Mandatory)][string]$Token,[Parameter(Mandatory)][string]$SourceSHA256,[Parameter(Mandatory)][scriptblock]$OnAcquired)
    if($Token -cnotmatch '^[a-f0-9]{32}$' -or $SourceSHA256 -cnotmatch '^[A-F0-9]{64}$'){throw 'Explicit reviewed recorder source pin and lease token required.'}
    $path=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'voice-agent/Recorder-Probe.cs'));Assert-IW7ResourceRecorderPath $path
    Invoke-IW7ResourceLock {
        $state=Read-IW7ResourceState;$leases=@($state.Leases|Where-Object Token -CEQ $Token)
        if($leases.Count -ne 1){throw 'Exact Runtime recorder lease missing.'}
        Assert-IW7ResourceRecorderHost $leases[0] @(Get-IW7ResourceProcesses)
        $registry=Get-IW7ResourceRecorderProviders
        $existing=@($registry.Values|Where-Object {$_.Token -ceq $Token -and $_.Path -ceq $path -and !$_.Closed})
        if($existing.Count){
            if($existing.Count -ne 1){throw 'Ambiguous original recorder source provider.'}
            & $OnAcquired $existing[0].Provider|Out-Null
            $null=Assert-IW7ResourceRecorderProvider $existing[0].Provider $Token
            if($existing[0].SHA256 -cne $SourceSHA256){throw 'Recorder source pin differs from original provider.'}
            return $existing[0].Provider
        }
        if('IW7.VoicePairDraft.ProbeAdmission' -as [type]){throw 'Preloaded recorder owner cannot establish source provenance.'}
        $guard=[IO.File]::Open($path,'Open','Read','Read')
        $provider=[pscustomobject]@{Id=[guid]::NewGuid().ToString('N');Type=$null;SourceGuard=$guard;SourcePath=$path;
            SourceSHA256=$SourceSHA256;SourceFileId=$null;SourceBytes=$guard.Length;AssemblyName=$null;ModuleVersionId=$null;State='Loading';Failure=$null}
        $entry=[pscustomobject]@{Provider=$provider;Token=$Token;Type=$null;Guard=$guard;Handle=$guard.SafeFileHandle;Path=$path;SHA256=$SourceSHA256;
            FileId=$null;Bytes=$guard.Length;Assembly=$null;ModuleVersionId=$null;Ready=$false;Closed=$false;Owners=[Collections.Generic.List[object]]::new()}
        $registry[$provider.Id]=$entry
        # The original CLI record adopts the guard BEFORE reading or compiling.
        try{
            & $OnAcquired $provider|Out-Null
            if($guard.Length -lt 1 -or $guard.Length -gt 128KB -or (Get-IW7ResourceRecorderDigest $guard) -cne $SourceSHA256){throw 'Recorder provider source bytes or bound differ.'}
            $guard.Position=0;$reader=[IO.StreamReader]::new($guard,[Text.UTF8Encoding]::new($false,$true),$true,1024,$true)
            try{$source=$reader.ReadToEnd()}finally{$reader.Dispose()}
            $compiled=@(Import-IW7ResourceRecorderSource $source);$types=@($compiled|Where-Object FullName -CEQ 'IW7.VoicePairDraft.ProbeAdmission')
            if($types.Count -ne 1){throw 'Exact compiled recorder owner missing.'}
            $native=$types[0];Assert-IW7ResourceRecorderNativeContract $native
            $id=Get-IW7ResourceRecorderFileIdentity $native $guard
            if($id -cnotmatch '^[A-F0-9]{8}:[A-F0-9]{16}$' -or (Get-IW7ResourceRecorderDigest $guard) -cne $SourceSHA256){throw 'Retained recorder source identity differs after load.'}
            $provider.Type=$native;$provider.SourceFileId=$id;$provider.AssemblyName=$native.Assembly.FullName;$provider.ModuleVersionId=$native.Module.ModuleVersionId.ToString('D');$provider.State='Ready'
            $entry.Type=$native;$entry.FileId=$id;$entry.Assembly=$native.Assembly;$entry.ModuleVersionId=$native.Module.ModuleVersionId;$entry.Ready=$true
        }catch{$provider.State='Failed';$provider.Failure=$_.Exception.Message}
        $provider
    }
}
function Assert-IW7ResourceRecorderProvider($Provider,[string]$Token){
    if(!$Provider -or !$Provider.PSObject.Properties['Id']){throw 'Original recorder source provider missing.'}
    $registry=Get-IW7ResourceRecorderProviders
    if(!$registry.ContainsKey([string]$Provider.Id)){throw 'Unknown recorder provider.'}
    $entry=$registry[[string]$Provider.Id]
    if(![object]::ReferenceEquals($entry.Provider,$Provider) -or $entry.Token -cne $Token -or $entry.Closed -or !$entry.Ready -or $Provider.State -cne 'Ready' -or
        ![object]::ReferenceEquals($entry.Type,$Provider.Type) -or ![object]::ReferenceEquals($entry.Guard,$Provider.SourceGuard) -or
        $Provider.SourcePath -cne $entry.Path -or $Provider.SourceSHA256 -cne $entry.SHA256 -or $Provider.SourceFileId -cne $entry.FileId -or $Provider.SourceBytes -ne $entry.Bytes -or
        ![object]::ReferenceEquals($entry.Type.Assembly,$entry.Assembly) -or $entry.Type.Module.ModuleVersionId -ne $entry.ModuleVersionId -or
        $Provider.AssemblyName -cne $entry.Assembly.FullName -or $Provider.ModuleVersionId -cne $entry.ModuleVersionId.ToString('D')){throw 'Original source/type/assembly recorder provider changed.'}
    Assert-IW7ResourceRecorderNativeContract $entry.Type
    if($entry.Guard.Length -ne $entry.Bytes -or (Get-IW7ResourceRecorderDigest $entry.Guard) -cne $entry.SHA256 -or
        (Get-IW7ResourceRecorderFileIdentity $entry.Type $entry.Guard) -cne $entry.FileId){throw 'Retained recorder source bytes or physical identity changed.'}
    $entry
}
function Get-IW7ResourceRecorderProviderEvidence($Provider){
    [pscustomobject]@{Schema='iw7.runtime-recorder-source/1';ProviderId=$Provider.Id;SourceSHA256=$Provider.SourceSHA256;
        SourceFileId=$Provider.SourceFileId;SourceBytes=$Provider.SourceBytes;ProviderType=$(if($Provider.Type){$Provider.Type.FullName});
        AssemblyName=$Provider.AssemblyName;ModuleVersionId=$Provider.ModuleVersionId;State=$Provider.State;Failure=$Provider.Failure}
}
function New-IW7ResourceRecorderOriginal {
    param($Provider,[string]$Token,[string]$PairScope,$Helper,[string[]]$Arguments,[string]$Stdout,[string]$Stderr,[int]$TimeoutSeconds)
    $entry=Assert-IW7ResourceRecorderProvider $Provider $Token
    Assert-IW7ResourceRecorderHelper $PairScope $Helper
    $owner=$entry.Type::Prepare($PairScope,$Helper.Image,$Helper.SHA256,$Arguments,$Stdout,$Stderr,$TimeoutSeconds,
        $Provider,$Provider.Id,$entry.SHA256,$entry.FileId,$entry.Guard,$Token)
    Assert-IW7ResourceRecorderOwner $owner $entry
    $entry.Owners.Add($owner)
    $owner
}
function Assert-IW7ResourceRecorderOwner($Owner,$Entry){if($null -eq $Owner -or $Owner.GetType() -ne $Entry.Type){throw 'Exact original source-bound recorder owner required.'}}
function Assert-IW7ResourceRecorderHelper([string]$PairScope,$Helper){
    $scope=[IO.Path]::GetFullPath($PairScope).TrimEnd('\','/')
    $parent=Join-Path $scope 'voice-pair-helper'
    if($Helper.Scope -ine $scope -or $Helper.Root -isnot [string] -or $Helper.Image -isnot [string] -or
        [IO.Path]::GetDirectoryName($Helper.Root) -ine $parent -or [IO.Path]::GetFileName($Helper.Root) -cnotmatch '^[a-f0-9]{32}$' -or
        $Helper.Image -cne (Join-Path $Helper.Root 'receiver-probe.exe') -or $Helper.Closed -or $Helper.HardLinked -isnot [bool] -or $Helper.HardLinked -or
        $Helper.SHA256 -cnotmatch '^[A-F0-9]{64}$' -or $Helper.FileId -cnotmatch '^[A-F0-9]{8}:[A-F0-9]{16}$' -or $Helper.Bytes -isnot [long] -or $Helper.Bytes -le 0 -or $Helper.Bytes -gt 16MB){throw 'Exact independent pair helper tuple required.'}
    if($Helper.Root.Length -gt 247 -or $Helper.Image.Length -gt 259){throw 'Native recorder helper geometry refused.'}
    Assert-IW7ResourceRecorderPath $Helper.Image
}
function Assert-IW7ResourceRecorderOpaqueWitness($Witness,$Owner,$Entry){
    $type=$Entry.Type;$expected=$type.GetNestedType('AdmissionWitness',[Reflection.BindingFlags]'Public')
    if(!$expected -or $null -eq $Witness -or $Witness.GetType() -ne $expected -or !$Witness.MatchesOwner($Owner) -or
        $Owner.GetType() -ne $type -or !$Witness.MatchesSourceProvider($Entry.Provider)){throw 'Exact opaque original recorder witness required.'}
}
function Assert-IW7ResourceRecorderWitness($Witness,$Owner,$Entry,$Helper,[string]$PairScope){
    Assert-IW7ResourceRecorderOpaqueWitness $Witness $Owner $Entry
    if(
        $Witness.PID -isnot [uint32] -or $Witness.PID -eq 0 -or $Witness.PID -gt [int]::MaxValue -or $Witness.CreationFileTime -isnot [long] -or $Witness.CreationFileTime -le 0 -or
        $Witness.Suspended -isnot [bool] -or !$Witness.Suspended -or $Witness.SourceSchema -cne 'iw7.runtime-recorder-admission/1' -or
        $Witness.LeaseToken -cne $Entry.Token -or $Witness.SourceProviderId -cne $Entry.Provider.Id -or $Witness.SourceSHA256 -cne $Entry.SHA256 -or $Witness.SourceFileId -cne $Entry.FileId -or
        $Witness.PairScope -ine $PairScope -or $Witness.HelperRoot -cne $Helper.Root -or $Witness.Image -cne $Helper.Image -or
        $Witness.ImageFileId -cne $Helper.FileId -or $Witness.ImageSHA256 -cne $Helper.SHA256 -or $Witness.ImageBytes -ne $Helper.Bytes -or
        $Witness.LaunchNonce -cnotmatch '^[a-f0-9]{32}$' -or $Witness.CapturedTick -gt [Environment]::TickCount64 -or
        $Witness.RegistrationDeadlineTick -le $Witness.CapturedTick -or $Witness.RegistrationDeadlineTick-$Witness.CapturedTick -gt 1000 -or
        [Environment]::TickCount64 -ge $Witness.RegistrationDeadlineTick){throw 'Original source-bound suspended recorder witness differs or expired.'}
}
function Assert-IW7ResourceRecorderPermit($Permit,$Owner,$Entry){
    $type=$Entry.Type.GetNestedType('RegistrationPermit',[Reflection.BindingFlags]'Public')
    if(!$type -or $null -eq $Permit -or $Permit.GetType() -ne $type -or !$Permit.MatchesOwnerAndProvider($Owner,$Entry.Provider,$Entry.Token)){throw 'Exact original recorder private permit unavailable; retain registered child.'}
}
function Add-IW7ResourceOwnedRuntimeRecorder {
    param([Parameter(Mandatory)][string]$Token,[Parameter(Mandatory)]$Provider,[Parameter(Mandatory)]$Owner,[Parameter(Mandatory)]$Helper)
    Invoke-IW7ResourceLock {
        $entry=Assert-IW7ResourceRecorderProvider $Provider $Token
        Assert-IW7ResourceRecorderOwner $Owner $entry
        if(!$entry.Owners.Contains($Owner)){throw 'Original recorder owner was not adopted before creation.'}
        $state=Read-IW7ResourceState;$leases=@($state.Leases|Where-Object Token -CEQ $Token)
        if($leases.Count -ne 1){throw 'Exact Runtime recorder reservation missing.'}
        $lease=$leases[0];Assert-IW7ResourceRecorderHelper $lease.Scope $Helper
        # One passive inventory bracketed by same-original opaque witnesses.
        $before=$Owner.CaptureAdmissionWitness();Assert-IW7ResourceRecorderWitness $before $Owner $entry $Helper $lease.Scope
        $processes=@(Get-IW7ResourceProcesses);Assert-IW7ResourceRecorderHost $lease $processes
        $current=@($processes|Where-Object PID -EQ $before.PID)
        $after=$Owner.CaptureAdmissionWitness();Assert-IW7ResourceRecorderWitness $after $Owner $entry $Helper $lease.Scope
        if(!$before.MatchesWitness($after) -or $current.Count -ne 1){throw 'Original recorder witness changed or passive PID is not unique.'}
        $passive=$current[0]
        if(!$passive.PSObject.Properties['Image'] -or !$passive.PSObject.Properties['CreatedUtc'] -or $passive.CreatedUtc -isnot [string] -or [string]::IsNullOrWhiteSpace($passive.CreatedUtc)){throw 'Passive recorder image field and creation metadata required.'}
        $delta=[datetimeoffset]::Parse($passive.CreatedUtc,[Globalization.CultureInfo]::InvariantCulture).UtcDateTime.ToFileTimeUtc()-$before.CreationFileTime
        if([math]::Abs($delta) -gt 10){throw 'Passive recorder creation differs from original handle.'}
        if($null -eq $passive.Image){$mode='CimImageNullOriginalSuspendedRecorder'}
        elseif($passive.Image -is [string] -and ![string]::IsNullOrWhiteSpace($passive.Image) -and $passive.Image -ieq $before.Image){$mode='CimAndOriginalSuspendedRecorder'}
        else{throw 'Empty, malformed or foreign passive recorder image refused.'}
        if(@($lease.Processes|Where-Object PID -EQ $before.PID).Count){throw 'Original Runtime recorder already registered; never mint a second permit.'}
        $receipt=[pscustomobject]@{Schema='iw7.runtime-recorder-registration/1';Token=$Token;Kind='Runtime';PhysicalBytes=$lease.PhysicalBytes;CommitBytes=$lease.CommitBytes;
            HostPID=$PID;PairScope=$lease.Scope;HelperRoot=$before.HelperRoot;LaunchNonce=$before.LaunchNonce;ProviderId=$Provider.Id;ProviderType=$entry.Type.FullName;
            SourceSHA256=$entry.SHA256;SourceFileId=$entry.FileId;SourceBytes=$entry.Bytes;AssemblyName=$Provider.AssemblyName;ModuleVersionId=$Provider.ModuleVersionId;
            PID=$before.PID;Image=$before.Image;CreationFileTime=$before.CreationFileTime;ImageFileId=$before.ImageFileId;ImageSHA256=$before.ImageSHA256;ImageBytes=$before.ImageBytes;
            Suspended=$true;EvidenceMode=$mode;PassiveImage=$passive.Image;PassiveCreatedUtc=$passive.CreatedUtc;PassiveCreationDeltaTicks=$delta;
            RegistrationDeadlineTick=$before.RegistrationDeadlineTick;CapturedTick=$after.CapturedTick;PIDHandleOpened=$false;ResumePerformed=$false}
        $identity=[pscustomobject]@{PID=[int]$before.PID;CreatedUtc=[datetime]::FromFileTimeUtc($before.CreationFileTime).ToString('o');Image=$before.Image;
            ParentPID=$PID;Name='receiver-probe.exe';Lab=$false;Heavy=$true;WorkingSet=0L;PrivateBytes=0L;OwnedAdmission=$receipt}
        $lease.Processes=@($lease.Processes)+$identity;$lease.Phase='Running'
        Save-IW7ResourceState $state
        try{$permit=$Owner.CreateRegistrationPermit($after,$Token,$Provider);Assert-IW7ResourceRecorderPermit $permit $Owner $entry}
        catch{$_.Exception.Data['RecorderRegistrationReceipt']=$receipt;throw}
        [pscustomobject]@{Permit=$permit;Receipt=$receipt}
    }
}
function Close-IW7ResourceRecorderProvider($Provider,[string]$Token){
    $registry=Get-IW7ResourceRecorderProviders
    if(!$Provider -or !$registry.ContainsKey([string]$Provider.Id)){throw 'Original recorder source owner unknown at closure.'}
    $entry=$registry[[string]$Provider.Id]
    if(![object]::ReferenceEquals($entry.Provider,$Provider) -or $entry.Token -cne $Token -or ![object]::ReferenceEquals($entry.Guard,$Provider.SourceGuard)){throw 'Recorder source owner changed at closure.'}
    if(@($entry.Owners|Where-Object {!$_.OwnershipResolved}).Count){throw 'Original recorder owner remains unresolved; source guard/host/lease retained.'}
    if($entry.Closed){if($Provider.State -cne 'Closed' -or !$entry.Handle.IsClosed){throw 'Recorder source closure proof differs.'};return}
    if(!$entry.Handle.IsClosed){$entry.Guard.Dispose()}
    if(!$entry.Handle.IsClosed){throw 'Original source guard disposal unconfirmed; retain provider/host/lease.'}
    $entry.Closed=$true;$Provider.State='Closed'
}
