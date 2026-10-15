$ErrorActionPreference='Stop'
# Synthetic managed owner only: no process creation, native API, production
# registry or real heavy-workload admission. Exercise the production API itself.
$taskTestRoot=Join-Path ([IO.Path]::GetTempPath()) ('iw7-owned-admission-'+[guid]::NewGuid().ToString('N'))
$ops=Join-Path $taskTestRoot 'ops';$source=Join-Path $ops 'doom-source/SkinWriterProcess.cs'
[IO.Directory]::CreateDirectory((Split-Path $source -Parent))|Out-Null
foreach($name in @('Resource-Scheduler.Core.ps1','Resource-Memory.ps1','Resource-OwnedProcess.Core.ps1','Resource-RecorderOwnedProcess.Core.ps1')){
    [IO.File]::Copy((Join-Path $PSScriptRoot ('../../ops/'+$name)),(Join-Path $ops $name))
}
$code=@'
using System;using System.IO;
namespace IW7.DoomSkinBuild {
 public sealed class OwnedProcess {
  public uint ChildId=32123; public long Created=134358659862396973L; public string Image="C:\\tools\\python.exe";
  public bool Suspended=true,ThrowCapture=false,ChangeSecond=false,ThrowPermit=false,NullPermit=false; public int Captures,Permits,PermitObjects,Resumes;
  public string FileId="D088B64A:000D000000092DFB",Hash=new string('A',64);public long Bytes=314368;
  public static string FileIdentity(FileStream s){if(!s.CanRead)throw new Exception("closed");return "D088B64A:000D000000092DF0";}
  public sealed class AdmissionWitness {
   readonly OwnedProcess owner; public uint PID{get;} public string Image{get;} public long CreationFileTime{get;}
   public bool Suspended{get;} public string ImageFileId{get;} public string ImageSHA256{get;}public long ImageBytes{get;}
   public string SourceSchema{get{return "iw7.owned-suspended-admission/1";}}
   private AdmissionWitness(OwnedProcess o){owner=o;PID=o.ChildId;Image=o.Image;CreationFileTime=o.Created;Suspended=o.Suspended;ImageFileId=o.FileId;ImageSHA256=o.Hash;ImageBytes=o.Bytes;}
   internal static AdmissionWitness New(OwnedProcess o){return new AdmissionWitness(o);}
   public bool MatchesOwner(OwnedProcess o){return Object.ReferenceEquals(o,owner);}
  }
  public sealed class RegistrationPermit{private RegistrationPermit(){} internal static RegistrationPermit New(){return new RegistrationPermit();}}
  public AdmissionWitness CaptureAdmissionWitness(){Captures++;if(ThrowCapture)throw new Exception("capture refused");if(ChangeSecond&&Captures%2==0)Created++;return AdmissionWitness.New(this);}
  public RegistrationPermit CreateRegistrationPermit(AdmissionWitness w,string t){Permits++;if(ThrowPermit)throw new Exception("permit failed after successful registry save");if(NullPermit)return null;PermitObjects++;return RegistrationPermit.New();}
  public void Resume(RegistrationPermit p){if(p==null)throw new Exception("permit required");Resumes++;}
 }
}
'@
[IO.File]::WriteAllText($source,$code,[Text.UTF8Encoding]::new($false))
. (Join-Path $ops 'Resource-Scheduler.Core.ps1')
$script:checks=0
function Assert($Value,[string]$Message){$script:checks++;if(!$Value){throw $Message}}
function Refused([scriptblock]$Body,[string]$Message){$failed=$false;try{& $Body|Out-Null}catch{$failed=$true};Assert $failed $Message}
function Get-IW7ResourceRoot {Join-Path $taskTestRoot 'registry'}
function Get-IW7ResourceSnapshot {[pscustomobject]@{PhysicalTotal=32GB;PhysicalAvailable=28GB;CommitLimit=48GB;Committed=12GB}}
$self=Get-Process -Id $PID
$hostRow=[pscustomobject]@{PID=$PID;ParentPID=0;CreatedUtc=$self.StartTime.ToUniversalTime().ToString('o');Image=$self.Path;Name='pwsh.exe';Lab=$false;Heavy=$false;WorkingSet=100MB;PrivateBytes=100MB}
$script:inventory=@($hostRow);$script:inventoryFailure=$false
function Get-IW7ResourceProcesses {if($script:inventoryFailure){throw 'inventory failed'};$script:inventory}
$scope=Join-Path $taskTestRoot 'build'
$lease=Enter-IW7ResourceLease -Scope $scope -Kind Build -PhysicalBytes 2GB -CommitBytes 3GB -Owner 'synthetic owned admission'
$pin=(Get-FileHash -LiteralPath $source).Hash
Refused {Initialize-IW7ResourceOwnedProvider -Token ('0'*32) -SourcePath $source -SourceSHA256 $pin -TypeName 'IW7.DoomSkinBuild.OwnedProcess'} 'No provider before lease.'
Refused {Initialize-IW7ResourceOwnedProvider -Token $lease.Token -SourcePath $source -SourceSHA256 $pin -TypeName 'Unreviewed.Owner'} 'Only reviewed type.'
$failed=Initialize-IW7ResourceOwnedProvider -Token $lease.Token -SourcePath $source -SourceSHA256 ('0'*64) -TypeName 'IW7.DoomSkinBuild.OwnedProcess'
Assert ($failed.State -ceq 'Failed' -and $failed.SourceGuard.CanRead) 'Post-acquisition failure must return retained guard.'
Assert ($null -eq ('IW7.DoomSkinBuild.OwnedProcess' -as [type])) 'Bad source pin must never compile.'
$failed.SourceGuard.Dispose()
$provider=Initialize-IW7ResourceOwnedProvider -Token $lease.Token -SourcePath $source -SourceSHA256 $pin -TypeName 'IW7.DoomSkinBuild.OwnedProcess'
Assert ($provider.State -ceq 'Ready' -and $provider.SourceGuard.CanRead -and $provider.Type.IsSealed) 'Source-bound provider loads under local test lease.'
Refused {Initialize-IW7ResourceOwnedProvider -Token $lease.Token -SourcePath $source -SourceSHA256 $pin -TypeName 'IW7.DoomSkinBuild.OwnedProcess'} 'Preloaded type cannot be adopted again.'
Refused {[IO.File]::Open($source,'Open','Write','ReadWrite').Dispose()} 'Guard excludes source writes while owner active.'
function New-Scenario {
    $owner=[Activator]::CreateInstance($provider.Type)
    $child=[pscustomobject]@{PID=[int]$owner.ChildId;ParentPID=$PID;Image=$null;CreatedUtc=[datetime]::FromFileTimeUtc($owner.Created).ToString('o');Name='python.exe';Lab=$false;Heavy=$false;WorkingSet=0L;PrivateBytes=0L}
    $script:inventory=@($hostRow,$child)
    $state=Read-IW7ResourceState;$state.Leases[0].Kind='Build';$state.Leases[0].Processes=@();$state.Leases[0].Phase='Pending';Save-IW7ResourceState $state
    [pscustomobject]@{Owner=$owner;Child=$child}
}
$case=New-Scenario
$result=Add-IW7ResourceOwnedSuspendedProcess -Token $lease.Token -Provider $provider -Owner $case.Owner
Assert ($result.Receipt.EvidenceMode -ceq 'CimImageNullOwnedSuspended') 'Only exact null CIM image gets original suspended disposition.'
Assert ($case.Owner.Captures -eq 2 -and $case.Owner.Permits -eq 1 -and $case.Owner.Resumes -eq 0) 'Registration brackets inventory and does not resume.'
$saved=Read-IW7ResourceState
Assert ($saved.Leases[0].Processes.Count -eq 1 -and $saved.Leases[0].Processes[0].OwnedAdmission.ImageSHA256 -ceq ('A'*64)) 'Original kernel/image evidence persisted before permit.'
Assert ($saved.Leases[0].Processes[0].Image -ceq $case.Owner.Image) 'Persisted image comes from original witness.'
Assert (([datetimeoffset]$saved.Leases[0].Processes[0].CreatedUtc).UtcDateTime.ToFileTimeUtc() -eq $case.Owner.Created) 'Persisted exact kernel creation.'
Refused {Exit-IW7ResourceLease -Token $lease.Token} 'Null CIM remains ambiguous liveness after registration.'
Refused {Add-IW7ResourceOwnedSuspendedProcess -Token $lease.Token -Provider $provider -Owner $case.Owner} 'No duplicate registration permit.'
$case=New-Scenario;$case.Child.Image=$case.Owner.Image
$result=Add-IW7ResourceOwnedSuspendedProcess -Token $lease.Token -Provider $provider -Owner $case.Owner
Assert ($result.Receipt.EvidenceMode -ceq 'CimAndOriginalOwnedSuspended') 'Exact matching image keeps stronger disposition.'
foreach($bad in @('',' ','C:\foreign\other.exe',123)){
    $case=New-Scenario;$case.Child.Image=$bad
    Refused {Add-IW7ResourceOwnedSuspendedProcess -Token $lease.Token -Provider $provider -Owner $case.Owner} 'Empty/foreign/malformed image refused.'
    Assert ($case.Owner.Permits -eq 0 -and $case.Owner.Resumes -eq 0) 'Refused passive image cannot mint/resume.'
}
$case=New-Scenario;$case.Child.PSObject.Properties.Remove('Image')
Refused {Add-IW7ResourceOwnedSuspendedProcess -Token $lease.Token -Provider $provider -Owner $case.Owner} 'Missing field is not null image.'
foreach($delta in @(-11,11)){
    $case=New-Scenario;$case.Child.CreatedUtc=[datetime]::FromFileTimeUtc($case.Owner.Created+$delta).ToString('o')
    Refused {Add-IW7ResourceOwnedSuspendedProcess -Token $lease.Token -Provider $provider -Owner $case.Owner} 'Creation outside existing ten ticks refused.'
}
$case=New-Scenario;$case.Child.CreatedUtc=[datetime]::FromFileTimeUtc($case.Owner.Created-10).ToString('o')
$result=Add-IW7ResourceOwnedSuspendedProcess -Token $lease.Token -Provider $provider -Owner $case.Owner
Assert ($result.Receipt.PassiveCreationDeltaTicks -eq -10) 'Existing ten-tick boundary retained.'
$case=New-Scenario;$case.Child.CreatedUtc=$null
Refused {Add-IW7ResourceOwnedSuspendedProcess -Token $lease.Token -Provider $provider -Owner $case.Owner} 'Missing creation refused.'
$case=New-Scenario;$case.Child.CreatedUtc='malformed'
Refused {Add-IW7ResourceOwnedSuspendedProcess -Token $lease.Token -Provider $provider -Owner $case.Owner} 'Malformed creation refused.'
$case=New-Scenario;$script:inventory+= $case.Child
Refused {Add-IW7ResourceOwnedSuspendedProcess -Token $lease.Token -Provider $provider -Owner $case.Owner} 'Duplicate passive PID refused.'
$case=New-Scenario;$script:inventoryFailure=$true
Refused {Add-IW7ResourceOwnedSuspendedProcess -Token $lease.Token -Provider $provider -Owner $case.Owner} 'Inventory failure retains suspended child.'
$script:inventoryFailure=$false
$case=New-Scenario;$case.Owner.Suspended=$false
Refused {Add-IW7ResourceOwnedSuspendedProcess -Token $lease.Token -Provider $provider -Owner $case.Owner} 'Resumed witness refused.'
$case=New-Scenario;$case.Owner.ThrowCapture=$true
Refused {Add-IW7ResourceOwnedSuspendedProcess -Token $lease.Token -Provider $provider -Owner $case.Owner} 'Original capture failure refused.'
$case=New-Scenario;$case.Owner.ChangeSecond=$true
Refused {Add-IW7ResourceOwnedSuspendedProcess -Token $lease.Token -Provider $provider -Owner $case.Owner} 'Changed original tuple across inventory refused.'
$case=New-Scenario;$witness=$case.Owner.CaptureAdmissionWitness();$foreign=[Activator]::CreateInstance($provider.Type)
Refused {Assert-IW7ResourceAdmissionWitness $witness $foreign $provider.Type} 'Witness from foreign original refused.'
Refused {Assert-IW7ResourceAdmissionWitness ([pscustomobject]@{PID=32123;Suspended=$true}) $case.Owner $provider.Type} 'Fabricated PSC witness refused.'
Refused {Add-IW7ResourceOwnedSuspendedProcess -Token $lease.Token -Provider $provider -Owner ([pscustomobject]@{PID=32123})} 'Fabricated original owner refused.'
$copy=$provider.PSObject.Copy()
Refused {Add-IW7ResourceOwnedSuspendedProcess -Token $lease.Token -Provider $copy -Owner $case.Owner} 'Copied provider is not original registry reference.'
$oldPin=$provider.SourceSHA256;$provider.SourceSHA256='0'*64
Refused {Add-IW7ResourceOwnedSuspendedProcess -Token $lease.Token -Provider $provider -Owner $case.Owner} 'Provider source pin mutation refused.'
$provider.SourceSHA256=$oldPin
$case=New-Scenario;$state=Read-IW7ResourceState;$state.Leases[0].Kind='Runtime';Save-IW7ResourceState $state
Refused {Add-IW7ResourceOwnedSuspendedProcess -Token $lease.Token -Provider $provider -Owner $case.Owner} 'Runtime remains excluded from tool-only admission.'
$case=New-Scenario;$hostRow.Image='C:\foreign\host.exe'
Refused {Add-IW7ResourceOwnedSuspendedProcess -Token $lease.Token -Provider $provider -Owner $case.Owner} 'Host identity change refused.'
$hostRow.Image=$self.Path
$case=New-Scenario
Refused {Add-IW7ResourceProcess -Token $lease.Token -ProcessId $case.Child.PID} 'Legacy strict PID/CIM API unchanged.'
$oldSave=(Get-Command Save-IW7ResourceState).ScriptBlock
function Save-IW7ResourceState($State){throw 'intentional uncertain registry publication'}
Refused {Add-IW7ResourceOwnedSuspendedProcess -Token $lease.Token -Provider $provider -Owner $case.Owner} 'Failed registry publication cannot produce permit.'
Assert ($case.Owner.Permits -eq 0 -and $case.Owner.Resumes -eq 0) 'Save failure never calls native permit or resume.'
Set-Item -Path Function:Save-IW7ResourceState -Value $oldSave

# Save succeeded, but the original native permit factory failed. Exercise the
# real API and local publication, not a mocked Save or a regex of call order.
# The synthetic child remains suspended/visible with null CIM image throughout
# each refusal. Only the synthetic inventory is changed between scenarios.
foreach($mode in @('ThrowPermit','NullPermit')){
    $case=New-Scenario;$case.Owner.$mode=$true
    $returned=[Collections.Generic.List[object]]::new();$permitFailure=$null
    try{Add-IW7ResourceOwnedSuspendedProcess -Token $lease.Token -Provider $provider -Owner $case.Owner|ForEach-Object{$returned.Add($_)}}catch{$permitFailure=$_}
    Assert ($null -ne $permitFailure -and $returned.Count -eq 0) ($mode+' after Save must not return a usable permit or partial API result.')
    Assert ($case.Owner.Permits -eq 1 -and $case.Owner.PermitObjects -eq 0 -and $case.Owner.Resumes -eq 0 -and $case.Owner.Suspended) ($mode+' must keep its original child suspended without minting/resuming.')
    $durable=Read-IW7ResourceState;$publishedLease=$durable.Leases[0];$published=$publishedLease.Processes[0];$evidence=$published.OwnedAdmission
    Assert (@($durable.Leases).Count -eq 1 -and $publishedLease.Token -ceq $lease.Token -and $publishedLease.Phase -ceq 'Running' -and @($publishedLease.Processes).Count -eq 1) ($mode+' must retain the successful Running/Processes1 publication.')
    Assert ($published.PID -eq $case.Owner.ChildId -and $published.Image -ceq $case.Owner.Image -and
        ([datetimeoffset]$published.CreatedUtc).UtcDateTime.ToFileTimeUtc() -eq $case.Owner.Created -and
        $evidence.Schema -ceq 'iw7.owned-suspended-registration/1' -and $evidence.Token -ceq $lease.Token -and $evidence.HostPID -eq $PID -and
        $evidence.SourceSHA256 -ceq $pin -and $evidence.SourceFileId -ceq $provider.SourceFileId -and $evidence.ProviderId -ceq $provider.Id -and
        $evidence.PID -eq $case.Owner.ChildId -and $evidence.CreationFileTime -eq $case.Owner.Created -and $evidence.Image -ceq $case.Owner.Image -and
        $evidence.ImageFileId -ceq $case.Owner.FileId -and $evidence.ImageSHA256 -ceq $case.Owner.Hash -and $evidence.ImageBytes -eq $case.Owner.Bytes -and
        $evidence.EvidenceMode -ceq 'CimImageNullOwnedSuspended' -and $null -eq $evidence.PassiveImage -and $evidence.Suspended -and !$evidence.PIDHandleOpened -and !$evidence.ResumePerformed) ($mode+' must preserve complete original publication evidence despite permit failure.')
    $publicationPath=Join-Path (Get-IW7ResourceRoot) 'leases.json';$publicationHash=(Get-FileHash -LiteralPath $publicationPath).Hash
    $evidenceJson=$evidence|ConvertTo-Json -Depth 10 -Compress
    Refused {Add-IW7ResourceOwnedSuspendedProcess -Token $lease.Token -Provider $provider -Owner $case.Owner} ($mode+' already registered child cannot mint a second permit.')
    Assert ($case.Owner.Permits -eq 1 -and $case.Owner.PermitObjects -eq 0 -and $case.Owner.Resumes -eq 0 -and
        (Get-FileHash -LiteralPath $publicationPath).Hash -ceq $publicationHash) ($mode+' duplicate registration must neither republish nor call the permit factory again.')
    Refused {Exit-IW7ResourceLease -Token $lease.Token} ($mode+' null-CIM original child must keep its published lease.')
    $retained=Read-IW7ResourceState
    Assert (@($retained.Leases).Count -eq 1 -and $retained.Leases[0].Phase -ceq 'Running' -and @($retained.Leases[0].Processes).Count -eq 1 -and
        ($retained.Leases[0].Processes[0].OwnedAdmission|ConvertTo-Json -Depth 10 -Compress) -ceq $evidenceJson -and
        (Get-FileHash -LiteralPath $publicationPath).Hash -ceq $publicationHash -and $provider.SourceGuard.CanRead) ($mode+' refusal/release failure must not change durable evidence or discard the source guard.')
    $script:inventory=@($hostRow)
    Assert (@(Get-IW7LeaseLiveProcesses $retained.Leases[0] $script:inventory).Count -eq 0) ($mode+' lease can become releasable only after this synthetic original child disappears.')
}
$provider.SourceGuard.Dispose()
Refused {Add-IW7ResourceOwnedSuspendedProcess -Token $lease.Token -Provider $provider -Owner $case.Owner} 'Closed source guard refused.'
$script:inventory=@($hostRow);Exit-IW7ResourceLease -Token $lease.Token
Assert (@((Get-IW7ResourceStatus).Leases).Count -eq 0) 'Local test lease releases only after synthetic child disappears.'
Write-Output ('Owned tool admission pure: '+$script:checks+' checks PASS; synthetic owner only; no native process or production registry.')
