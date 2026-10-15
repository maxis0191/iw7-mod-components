# Admission for reviewed tools created suspended through their original handles.
# The existing PID/CIM registration and Runtime rules remain unchanged.
function Get-IW7ResourceOwnedProviders {
    $key='IW7.ResourceScheduler.OwnedProviders.v1'
    $registry=[AppDomain]::CurrentDomain.GetData($key)
    if($null -eq $registry){$registry=@{};[AppDomain]::CurrentDomain.SetData($key,$registry)}
    $registry
}
function Get-IW7ResourceOwnedDigest([IO.FileStream]$Stream){
    if($null -eq $Stream -or $Stream.SafeFileHandle.IsClosed -or !$Stream.CanRead -or !$Stream.CanSeek){throw 'Original source guard unavailable; retain reservation.'}
    $position=$Stream.Position
    try{$Stream.Position=0;[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Stream))}
    finally{$Stream.Position=$position}
}
function Assert-IW7ResourceOwnedHost($Lease,$Processes){
    if($Lease.Kind -cnotin @('Build','Extract','Analysis') -or $Lease.OwnerIdentity.PID -ne $PID){throw 'Owned suspended tools require their current host Build, Extract or Analysis lease.'}
    $hostRows=@($Processes|Where-Object PID -EQ $PID)
    if($hostRows.Count -ne 1 -or !(Test-IW7ResourceIdentity $Lease.OwnerIdentity $hostRows[0])){throw 'Original admitted host identity differs; reservation retained.'}
}
function Initialize-IW7ResourceOwnedProvider {
    param([Parameter(Mandatory)][string]$Token,[Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$SourceSHA256,[Parameter(Mandatory)][string]$TypeName)
    if($Token -cnotmatch '^[a-f0-9]{32}$' -or $SourceSHA256 -cnotmatch '^[A-F0-9]{64}$' -or
       $TypeName -cne 'IW7.DoomSkinBuild.OwnedProcess' -or ![IO.Path]::IsPathFullyQualified($SourcePath)){
        throw 'Exact reviewed owned-tool source, type and lease token required.'
    }
    $path=[IO.Path]::GetFullPath($SourcePath)
    $expected=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'doom-source/SkinWriterProcess.cs'))
    if($path -ine $expected){throw 'Provider source must be the reviewed local SkinWriterProcess.cs.'}
    $cursor=$path
    while($cursor){if((Get-Item -LiteralPath $cursor -Force -ErrorAction Stop).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)){throw 'Provider reparse ancestry refused.'};$cursor=Split-Path $cursor -Parent}
    $provider=$null
    Invoke-IW7ResourceLock {
        $state=Read-IW7ResourceState;$leases=@($state.Leases|Where-Object Token -CEQ $Token)
        if($leases.Count -ne 1){throw 'Exact provider resource lease not found.'}
        Assert-IW7ResourceOwnedHost $leases[0] @(Get-IW7ResourceProcesses)
        $registry=Get-IW7ResourceOwnedProviders
        if($TypeName -as [type]){throw 'Preloaded native type cannot establish a new verified source provider.'}
        # Acquire only after admission. Any later failure returns the guard to the
        # caller's original finalizer, rather than silently disposing it here.
        $guard=[IO.File]::Open($path,'Open','Read','Read')
        $provider=[pscustomobject]@{Id=[guid]::NewGuid().ToString('N');Type=$null;SourceGuard=$guard;
            SourcePath=$path;SourceSHA256=$SourceSHA256;SourceFileId=$null;SourceBytes=$guard.Length;State='Loading';Failure=$null}
        $entry=[pscustomobject]@{Provider=$provider;Token=$Token;Type=$null;Guard=$guard;Path=$path;
            SHA256=$SourceSHA256;FileId=$null;Bytes=$guard.Length;Ready=$false}
        $registry[$provider.Id]=$entry
        try{
            if($guard.Length -lt 1 -or $guard.Length -gt 128KB -or (Get-IW7ResourceOwnedDigest $guard) -cne $SourceSHA256){throw 'Reviewed provider source digest or bound differs.'}
            $guard.Position=0;$reader=[IO.StreamReader]::new($guard,[Text.UTF8Encoding]::new($false,$true),$true,1024,$true)
            try{$source=$reader.ReadToEnd()}finally{$reader.Dispose()}
            $compiled=@(Add-Type -TypeDefinition $source -PassThru -ErrorAction Stop)
            $types=@($compiled|Where-Object FullName -CEQ $TypeName)
            if($types.Count -ne 1 -or !$types[0].IsSealed){throw 'Exact sealed reviewed native provider type missing.'}
            $nativeType=$types[0]
            $identityMethod=$nativeType.GetMethod('FileIdentity',[Reflection.BindingFlags]'Public,Static',$null,[type[]]@([IO.FileStream]),$null)
            if(!$identityMethod -or $identityMethod.ReturnType -ne [string]){throw 'Reviewed provider retained-file identity method missing.'}
            $fileId=[string]$identityMethod.Invoke($null,[object[]]@($guard))
            if($fileId -cnotmatch '^[A-F0-9]{8}:[A-F0-9]{16}$' -or (Get-IW7ResourceOwnedDigest $guard) -cne $SourceSHA256){throw 'Original provider source identity differs after load.'}
            $provider.Type=$nativeType;$provider.SourceFileId=$fileId;$provider.State='Ready'
            $entry.Type=$nativeType;$entry.FileId=$fileId;$entry.Ready=$true
        }catch{$provider.State='Failed';$provider.Failure=$_.Exception.Message}
        $provider
    }
}
function Assert-IW7ResourceOwnedProvider($Provider,[string]$Token){
    if(!$Provider -or !$Provider.PSObject.Properties['Id']){throw 'Original source provider missing.'}
    $registry=Get-IW7ResourceOwnedProviders
    if(!$registry.ContainsKey([string]$Provider.Id)){throw 'Unknown source provider; reservation retained.'}
    $entry=$registry[[string]$Provider.Id]
    if(![object]::ReferenceEquals($entry.Provider,$Provider) -or $entry.Token -cne $Token -or !$entry.Ready -or
       $Provider.State -cne 'Ready' -or ![object]::ReferenceEquals($entry.Type,$Provider.Type) -or
       ![object]::ReferenceEquals($entry.Guard,$Provider.SourceGuard) -or $Provider.SourcePath -cne $entry.Path -or
       $Provider.SourceSHA256 -cne $entry.SHA256 -or $Provider.SourceFileId -cne $entry.FileId -or $Provider.SourceBytes -ne $entry.Bytes){
        throw 'Original source-bound provider changed; reservation retained.'
    }
    if($entry.Guard.Length -ne $entry.Bytes -or (Get-IW7ResourceOwnedDigest $entry.Guard) -cne $entry.SHA256 -or
       $entry.Type::FileIdentity($entry.Guard) -cne $entry.FileId){throw 'Retained provider source bytes or NTFS identity differ.'}
    $entry
}
function Assert-IW7ResourceAdmissionWitness($Witness,$Owner,[type]$NativeType){
    $witnessType=$NativeType.GetNestedType('AdmissionWitness',[Reflection.BindingFlags]'Public')
    if(!$witnessType -or !$witnessType.IsSealed -or $null -eq $Witness -or $Witness.GetType() -ne $witnessType -or
       $witnessType.Assembly -ne $NativeType.Assembly -or @($witnessType.GetConstructors()).Count -ne 0){throw 'Exact opaque native admission witness required.'}
    if(@($witnessType.GetFields([Reflection.BindingFlags]'Instance,NonPublic,Public')|Where-Object {!$_.IsInitOnly}).Count){throw 'Readonly original native witness fields required.'}
    $capture=$NativeType.GetMethod('CaptureAdmissionWitness',[type[]]@())
    if(!$capture -or $capture.ReturnType -ne $witnessType){throw 'Exact original native witness capture method required.'}
    foreach($name in @('PID','Image','CreationFileTime','Suspended','ImageFileId','ImageSHA256','ImageBytes','SourceSchema')){
        $property=$witnessType.GetProperty($name)
        if(!$property -or $property.GetSetMethod($true)){throw 'Immutable native admission witness required.'}
    }
    if(!$Witness.MatchesOwner($Owner) -or $Witness.PID -isnot [uint32] -or $Witness.PID -eq 0 -or
       $Witness.CreationFileTime -isnot [long] -or $Witness.CreationFileTime -le 0 -or
       $Witness.Suspended -isnot [bool] -or !$Witness.Suspended -or
       $Witness.Image -isnot [string] -or ![IO.Path]::IsPathFullyQualified($Witness.Image) -or
       $Witness.ImageFileId -cnotmatch '^[A-F0-9]{8}:[A-F0-9]{16}$' -or $Witness.ImageSHA256 -cnotmatch '^[A-F0-9]{64}$' -or
       $Witness.ImageBytes -isnot [long] -or $Witness.ImageBytes -le 0 -or
       $Witness.SourceSchema -cne 'iw7.owned-suspended-admission/1'){throw 'Original suspended native tuple, guard and schema required.'}
}
function Add-IW7ResourceOwnedSuspendedProcess {
    param([Parameter(Mandatory)][string]$Token,[Parameter(Mandatory)]$Provider,[Parameter(Mandatory)]$Owner)
    Invoke-IW7ResourceLock {
        $entry=Assert-IW7ResourceOwnedProvider $Provider $Token
        $nativeType=$entry.Type
        if($Owner.GetType() -ne $nativeType -or !$nativeType.IsSealed){throw 'Exact source-bound original native owner required.'}
        $state=Read-IW7ResourceState;$leases=@($state.Leases|Where-Object Token -CEQ $Token)
        if($leases.Count -ne 1){throw 'Exact original owned-tool lease not found.'}
        $lease=$leases[0]
        # The native witness brackets one fresh passive inventory while the
        # original child is still suspended. This API never opens a PID handle.
        $before=$Owner.CaptureAdmissionWitness()
        Assert-IW7ResourceAdmissionWitness $before $Owner $nativeType
        $processes=@(Get-IW7ResourceProcesses)
        Assert-IW7ResourceOwnedHost $lease $processes
        $current=@($processes|Where-Object PID -EQ $before.PID)
        $after=$Owner.CaptureAdmissionWitness()
        Assert-IW7ResourceAdmissionWitness $after $Owner $nativeType
        foreach($name in @('PID','CreationFileTime','ImageFileId','ImageSHA256','ImageBytes','Suspended','SourceSchema')){
            if($before.$name -cne $after.$name){throw 'Original suspended witness changed during passive inventory.'}
        }
        if($before.Image -ine $after.Image -or $current.Count -ne 1){throw 'Original image or unique passive process identity differs.'}
        $passive=$current[0]
        if(!$passive.PSObject.Properties['Image'] -or !$passive.PSObject.Properties['CreatedUtc'] -or
           $passive.CreatedUtc -isnot [string] -or [string]::IsNullOrWhiteSpace($passive.CreatedUtc)){
            throw 'Passive image field and creation metadata required.'
        }
        $passiveTime=[datetimeoffset]::Parse($passive.CreatedUtc,[Globalization.CultureInfo]::InvariantCulture).UtcDateTime.ToFileTimeUtc()
        $delta=$passiveTime-$before.CreationFileTime
        if([math]::Abs($delta) -gt 10){throw 'Passive creation time differs from original suspended handle.'}
        if($null -eq $passive.Image){$mode='CimImageNullOwnedSuspended'}
        elseif($passive.Image -is [string] -and ![string]::IsNullOrWhiteSpace($passive.Image) -and $passive.Image -ieq $before.Image){$mode='CimAndOriginalOwnedSuspended'}
        else{throw 'Empty, malformed or foreign passive image refused.'}
        if(@($lease.Processes|Where-Object PID -EQ $before.PID).Count){throw 'Original suspended child already registered; do not mint another permit.'}
        $receipt=[pscustomobject]@{Schema='iw7.owned-suspended-registration/1';Token=$Token;Kind=$lease.Kind;
            HostPID=$PID;ProviderId=$Provider.Id;ProviderType=$nativeType.FullName;SourceSHA256=$entry.SHA256;SourceFileId=$entry.FileId;
            PID=$before.PID;Image=$before.Image;CreationFileTime=$before.CreationFileTime;ImageFileId=$before.ImageFileId;
            ImageSHA256=$before.ImageSHA256;ImageBytes=$before.ImageBytes;Suspended=$true;EvidenceMode=$mode;
            PassiveCreatedUtc=$passive.CreatedUtc;PassiveCreationDeltaTicks=$delta;PassiveImage=$passive.Image;
            CapturedTick=[Environment]::TickCount64;PIDHandleOpened=$false;ResumePerformed=$false}
        $identity=[pscustomobject]@{PID=[int]$before.PID;CreatedUtc=[datetime]::FromFileTimeUtc($before.CreationFileTime).ToString('o');
            Image=$before.Image;ParentPID=$PID;Name=[IO.Path]::GetFileName($before.Image);Lab=$false;Heavy=$true;
            WorkingSet=0L;PrivateBytes=0L;OwnedAdmission=$receipt}
        $lease.Processes=@($lease.Processes)+$identity;$lease.Phase='Running'
        # Save is the commit point. Failed/uncertain saves do not return a permit.
        Save-IW7ResourceState $state
        $permit=$Owner.CreateRegistrationPermit($after,$Token)
        $permitType=$nativeType.GetNestedType('RegistrationPermit',[Reflection.BindingFlags]'Public')
        if(!$permitType -or !$permitType.IsSealed -or $null -eq $permit -or $permit.GetType() -ne $permitType -or @($permitType.GetConstructors()).Count){throw 'Original native registration permit unavailable; preserve registered suspended child.'}
        [pscustomobject]@{Permit=$permit;Receipt=$receipt}
    }
}
