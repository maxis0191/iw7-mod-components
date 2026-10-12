# Source preparation only until separately reviewed and admitted. Plan is read-only.
[CmdletBinding()]
param(
    [ValidateSet('Plan','Run')][string]$Action='Plan',
    [string]$NativeSource,[string]$OutputRoot,[string]$PythonExe,[string]$ProviderRoot,
    [string]$VCPath,[string]$WindowsSdkRoot,[string]$WindowsSdkVersion,
    [string]$JobAssembly,[string]$JobAssemblySHA256,[string]$JobAssemblySourceSHA256,[string]$JobWitnessReceipt,
    [string]$PlanPath,[string]$ApprovedPlanSHA256
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
function Hash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Assert-FreshOutput([string]$Path) {
    $full=[IO.Path]::GetFullPath($Path)
    $runtime=[IO.Path]::GetFullPath((Join-Path $repo 'runtime'))+[IO.Path]::DirectorySeparatorChar
    if(!$full.StartsWith($runtime,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $full)){throw 'Fresh output beneath this worktree runtime required.'}
    for($node=[IO.DirectoryInfo]$full;$node;$node=$node.Parent){
        if($node.Exists -and ($node.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Reparse output ancestry refused.'}
    }
    $full
}
function Assert-Hash([string]$Path,[string]$Expected) {
    if($Expected -notmatch '^[a-fA-F0-9]{64}$' -or (Hash $Path) -cne $Expected.ToLowerInvariant()){throw "Planned input changed: $Path"}
}
function Open-DownloadReadGuard([string]$Path,[string]$Expected) {
    $full=[IO.Path]::GetFullPath($Path)
    for($node=Get-Item -LiteralPath $full;$node;$node=$(if($node -is [IO.FileInfo]){$node.Directory}else{$node.Parent})){
        if($node.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Reparse input refused.'}
    }
    $stream=[IO.File]::Open($full,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        $digest=[Security.Cryptography.SHA256]::Create()
        try {$actual=[Convert]::ToHexString($digest.ComputeHash($stream)).ToLowerInvariant()} finally {$digest.Dispose()}
        if($Expected -notmatch '^[a-fA-F0-9]{64}$' -or $actual -cne $Expected.ToLowerInvariant()){throw "Guarded input hash differs: $full"}
        $stream.Position=0
        return $stream
    } catch {$stream.Dispose();throw}
}
$sourceNames=@('Harness.ps1','Harness.Core.ps1','Harness.Profile.ps1','h1-source.json','tests/expected-cases.json','run_tests.py','verify_archive.py','Download-NativeJob.cs','job-source.json','manifest.json',
    'overlay/src/client/component/download.cpp','patches/0001-contained-errors-and-verified-publication.patch',
    'tests/native_stubs.hpp','tests/test_download.cpp','LICENSE.upstream')
$resourceNames=@('ops/Resource-Scheduler.Core.ps1','ops/Resource-Memory.ps1','ops/Resource-RecorderOwnedProcess.Core.ps1','ops/native/ResourceMemory.cs')
function Assert-DownloadJobBinding($Binding,[string]$Assembly,[string]$AssemblyHash,[string]$SourceHash,[string]$Receipt) {
    if($Binding.Schema -cne 'iw7.community-download-job-source/2' -or $Binding.Type -cne 'IW7.AnimationProbe.NativeJob' -or
        $AssemblyHash -ine $Binding.AssemblySHA256 -or $SourceHash -ine $Binding.SourceSHA256){throw 'Exact existing witnessed helper binding required.'}
    Assert-Hash $Assembly $Binding.AssemblySHA256
    Assert-Hash (Join-Path $repo $Binding.Source) $Binding.SourceSHA256
    Assert-Hash $Receipt $Binding.WitnessSHA256
    $witness=Get-Content -LiteralPath $Receipt -Raw | ConvertFrom-Json
    if($witness.Status -cne 'OwnedJobWitnessPassed' -or !$witness.AllOwnedTreesClosed -or !$witness.LeaseReleased -or
        $witness.SourceCommit -cne $Binding.SourceCommit -or $witness.HelperAssemblySHA256 -ine $Binding.AssemblySHA256 -or
        $witness.SourceSHA256.'Probe-NativeJob.cs' -ine $Binding.SourceSHA256){throw 'Existing helper witness differs from the source/assembly binding.'}
}

if($Action -eq 'Plan'){
    foreach($value in @($NativeSource,$OutputRoot,$PythonExe,$VCPath,$WindowsSdkRoot,$WindowsSdkVersion,$ProviderRoot)){
        if([string]::IsNullOrWhiteSpace($value)){throw 'Plan requires source, fresh output, Python, VC/SDK and reviewed ProviderRoot paths.'}
    }
    $manifest=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'manifest.json') -Raw | ConvertFrom-Json
    $sourceHashes=[ordered]@{}
    foreach($relative in $sourceNames){
        $sourceHashes[$relative]=Hash (Join-Path $PSScriptRoot $relative)
    }
    $resourceHashes=[ordered]@{}
    foreach($relative in $resourceNames){$resourceHashes[$relative]=Hash (Join-Path $repo $relative)}
    Assert-Hash (Join-Path $PSScriptRoot 'overlay/src/client/component/download.cpp') $manifest.overlay_sha256
    Assert-Hash (Join-Path $PSScriptRoot $manifest.patch) $manifest.patch_sha256
    $vc=[IO.Path]::GetFullPath($VCPath);$sdk=[IO.Path]::GetFullPath($WindowsSdkRoot)
    $compiler=Join-Path $vc 'bin/Hostx64/x64/cl.exe';$linker=Join-Path $vc 'bin/Hostx64/x64/link.exe'
    $python=[IO.Path]::GetFullPath($PythonExe)
    $includes=@((Join-Path $vc 'include'))+@('ucrt','shared','um','winrt' | ForEach-Object {Join-Path $sdk "Include/$WindowsSdkVersion/$_"})
    $libs=@((Join-Path $vc 'lib/x64'),(Join-Path $sdk "Lib/$WindowsSdkVersion/ucrt/x64"),(Join-Path $sdk "Lib/$WindowsSdkVersion/um/x64"))
    foreach($directory in @($includes)+@($libs)){if(!(Test-Path -LiteralPath $directory -PathType Container)){throw "Installed toolchain directory missing: $directory"}}
    $binding=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'job-source.json') -Raw | ConvertFrom-Json
    $assemblyBound=$false;$assemblyPath=$null;$receiptPath=$null
    if($JobAssembly){
        $assemblyPath=[IO.Path]::GetFullPath($JobAssembly)
        if(!$JobWitnessReceipt){throw 'Existing helper witness receipt required.'}
        $receiptPath=[IO.Path]::GetFullPath($JobWitnessReceipt)
        Assert-DownloadJobBinding $binding $assemblyPath $JobAssemblySHA256 $JobAssemblySourceSHA256 $receiptPath
        $assemblyBound=$true
    }
    $providers=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'h1-source.json') -Raw|ConvertFrom-Json
    $providerPins=@(foreach($entry in $providers.Providers.PSObject.Properties){
        $path=[IO.Path]::GetFullPath((Join-Path $ProviderRoot $entry.Name));Assert-Hash $path $entry.Value
        [ordered]@{Relative=$entry.Name;Path=$path;SHA256=$entry.Value;Bytes=(Get-Item -LiteralPath $path).Length}
    })
    $telemetry=Join-Path (Split-Path $compiler -Parent) 'vctip.exe'
    Assert-Hash $compiler 'fe251ef50a1545b1b0835ee17b1e785459712b38d79e45b5c1d3d28970a36619'
    Assert-Hash $telemetry 'd591358c6aee4b673562ca3b3a15c250e612708394fe3b44a7a7eda2470570a5'
    if((Get-Item -LiteralPath $telemetry).Length -ne 335288){throw 'Exact reviewed VCTIP bytes required.'}
    . (Join-Path $PSScriptRoot 'Harness.Profile.ps1') # Function declarations only; no native import.
    $plannedOutput=Assert-FreshOutput $OutputRoot
    [ordered]@{
        schema='iw7.community-download-plan/3';prepared_only=$true;native_started=$false;admitted=$false;ready=$false
        source_hashes=$sourceHashes;upstream_commit=$manifest.upstream_commit;overlay_sha256=$manifest.overlay_sha256
        native_source=[IO.Path]::GetFullPath($NativeSource);output_root=$plannedOutput
        python_path=$python;python_sha256=(Hash $python);compiler_path=$compiler;compiler_sha256=(Hash $compiler)
        compiler_file_version=(Get-Item -LiteralPath $compiler).VersionInfo.FileVersion
        linker_path=$linker;linker_sha256=(Hash $linker);include_paths=$includes;lib_paths=$libs
        telemetry_path=$telemetry;telemetry_sha256=(Hash $telemetry);provider_pins=$providerPins
        stages=@('Prepare','Compile','Tests');stage_seconds=@(45,90,30);group_deadline_seconds=180
        compiler_arguments=@(Get-DownloadCompileArguments $PSScriptRoot $plannedOutput)
        resource_helper_sha256=(Hash (Join-Path $repo 'ops/Resource-Scheduler.Core.ps1'))
        resource_source_hashes=$resourceHashes
        physical_bytes=4GB;commit_bytes=6GB;artifact_limit_bytes=32MB;metadata_reserve_bytes=1MB
        expected_test_count=46;worker_timeout_seconds=180;root_exit_grace_seconds=2
        job_assembly=$assemblyPath;job_assembly_sha256=$binding.AssemblySHA256;job_source_sha256=$binding.SourceSHA256
        job_type=$binding.Type;job_source=$binding.Source;job_source_commit=$binding.SourceCommit
        job_witness_receipt=$receiptPath;job_witness_sha256=$binding.WitnessSHA256
        reviewed_prebuilt_job_assembly_bound=$assemblyBound
        original_job_contract='Atomic job-at-create; no breakaway; retain original handle through root exit, member capture, stop if required and ActiveProcesses=0'
        member_observation_contract='Unchanged H1 bounded complete job captures; compiler-only exact direct VCTIP child; tests require natural closure'
        helper_binding_limit='Reuses existing job DLL and H1 observer source; observer loads only in admitted Run; Plan C is source-only and unexecuted'
    } | ConvertTo-Json -Depth 8
    return
}

# Plan never imports native telemetry. Run may initialize the guarded admission
# ResourceMemory API; the job helper must already be built and reviewed separately.
if(!$IsWindows -or [IntPtr]::Size -ne 8 -or $PSVersionTable.PSVersion.Major -lt 7){throw 'Windows x64 PowerShell7 required.'}
if(!$PlanPath -or !$ApprovedPlanSHA256){throw 'Run requires a reviewed plan file and its exact ApprovedPlanSHA256.'}
Assert-Hash $PlanPath $ApprovedPlanSHA256
$plan=Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json
if($plan.schema -cne 'iw7.community-download-plan/3' -or !$plan.reviewed_prebuilt_job_assembly_bound){throw 'Reviewed original-job assembly binding required.'}
if(@(Compare-Object $sourceNames @($plan.source_hashes.PSObject.Properties.Name)).Count -or
    @(Compare-Object $resourceNames @($plan.resource_source_hashes.PSObject.Properties.Name)).Count){throw 'Exact source and admission import pin sets required.'}
if($plan.physical_bytes -ne 4GB -or $plan.commit_bytes -ne 6GB -or $plan.artifact_limit_bytes -ne 32MB -or
    $plan.metadata_reserve_bytes -ne 1MB -or $plan.worker_timeout_seconds -ne 180 -or $plan.root_exit_grace_seconds -ne 2 -or $plan.expected_test_count -ne 46 -or
    $plan.group_deadline_seconds -ne 180 -or (@($plan.stages)-join ',') -cne 'Prepare,Compile,Tests' -or
    (@($plan.stage_seconds)-join ',') -cne '45,90,30'){throw 'Reviewed fixed harness budget/case profile differs.'}
$output=Assert-FreshOutput $plan.output_root
foreach($item in $plan.source_hashes.PSObject.Properties){Assert-Hash (Join-Path $PSScriptRoot $item.Name) $item.Value}
foreach($label in @('python','compiler','linker','telemetry')){Assert-Hash $plan.($label+'_path') $plan.($label+'_sha256')}
Assert-Hash (Join-Path $repo 'ops/Resource-Scheduler.Core.ps1') $plan.resource_helper_sha256
$binding=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'job-source.json') -Raw | ConvertFrom-Json
if($plan.job_type -cne $binding.Type -or $plan.job_source -cne $binding.Source -or
    $plan.job_source_commit -cne $binding.SourceCommit -or $plan.job_witness_sha256 -ine $binding.WitnessSHA256){throw 'Plan helper metadata differs from binding.'}
Assert-DownloadJobBinding $binding $plan.job_assembly $plan.job_assembly_sha256 $plan.job_source_sha256 $plan.job_witness_receipt
if(('IW7.AnimationProbe.NativeJob' -as [type]) -or ('IW7.H1Diagnostics.JobMembers' -as [type]) -or ('IW7ResourceMemoryV1' -as [type])){throw 'Fresh PowerShell host required for the reviewed helper and guarded admission telemetry.'}
$guards=[Collections.Generic.List[IO.FileStream]]::new()
$pins=[Collections.Generic.List[object]]::new()
$context=[pscustomobject]@{Owner=$null;Closed=$true;Lease=$null;Guards=$guards}
$lease=$null;$failure=$null;$timing=$null;$reserve=$null;$policiesLoaded=$false
$record=[ordered]@{Schema='iw7.community-download-admitted-run/2';Status='Pending';Admitted=$false;Passed=$false;
    ApprovedPlanSHA256=$ApprovedPlanSHA256;LeaseToken=$null;Quarantined=$false;QuarantineKey=$null;
    HistoricalIncidentRequalified=$false;ForcedStop=$false;OriginalJobClosed=$false;LeaseReleased=$false;
    ReadGuardsReleased=$false;WorkerPID=$null;WorkerCreationFileTime=$null;MemoryPeaksMeasured=$false;
    StartedUtc=[datetime]::UtcNow.ToString('o');Stages=[Collections.Generic.List[object]]::new();
    Ready=$false;FullNativeBuild=$false;Gameplay=$false;CommunityJoinValidated=$false}
function Measure-OutputPayload {
    $bytes=0L;$count=0;$pending=[Collections.Generic.Stack[string]]::new();$pending.Push($output)
    while($pending.Count){
        foreach($entry in [IO.Directory]::EnumerateFileSystemEntries($pending.Pop())){
            if(++$count -gt 128){throw 'Output entry bound exceeded.'}
            $attributes=[IO.File]::GetAttributes($entry)
            if($attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Reparse artifact refused before descent.'}
            if($attributes -band [IO.FileAttributes]::Directory){$pending.Push($entry)}
            elseif(!$reserve -or $entry -cne $reserve.Path){$bytes+=([IO.FileInfo]$entry).Length}
        }
    }
    $bytes
}
function Assert-OutputBudget {
    $bytes=Measure-OutputPayload
    if($bytes -gt 31MB){throw 'Harness output exceeds budget before final metadata.'}
    $bytes
}
function Hold-DownloadPin([string]$Path,[string]$SHA256){
    $guard=Open-DownloadReadGuard $Path $SHA256;$guards.Add($guard)
    $pins.Add([pscustomobject]@{Path=[IO.Path]::GetFullPath($Path);Bytes=$guard.Length;SHA256=$SHA256.ToLowerInvariant()})
}
function Assert-DownloadGlobal { Assert-H1Deadline $timing.StartedMs 180 }
try {
    Hold-DownloadPin $PlanPath $ApprovedPlanSHA256
    $guardedPlan=Get-Content -LiteralPath $PlanPath -Raw|ConvertFrom-Json
    if(($guardedPlan|ConvertTo-Json -Depth 12 -Compress) -cne ($plan|ConvertTo-Json -Depth 12 -Compress)){throw 'Plan changed before guard.'}
    foreach($name in $sourceNames){Hold-DownloadPin (Join-Path $PSScriptRoot $name) $plan.source_hashes.$name}
    foreach($name in $resourceNames){Hold-DownloadPin (Join-Path $repo $name) $plan.resource_source_hashes.$name}
    $providers=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'h1-source.json') -Raw|ConvertFrom-Json
    if(@($plan.provider_pins).Count -ne 4){throw 'Exact four H1 source providers required.'}
    foreach($entry in $providers.Providers.PSObject.Properties){
        $match=@($plan.provider_pins|Where-Object Relative -CEQ $entry.Name)
        if($match.Count -ne 1 -or $match[0].SHA256 -cne $entry.Value){throw 'H1 provider pin differs.'}
        Hold-DownloadPin $match[0].Path $entry.Value
        if($pins[$pins.Count-1].Bytes -ne $match[0].Bytes){throw 'H1 provider length differs.'}
    }
    foreach($label in 'python','compiler','linker','telemetry'){Hold-DownloadPin $plan.($label+'_path') $plan.($label+'_sha256')}
    if($plan.telemetry_path -ine (Join-Path (Split-Path $plan.compiler_path -Parent) 'vctip.exe') -or
       $plan.telemetry_sha256 -cne 'd591358c6aee4b673562ca3b3a15c250e612708394fe3b44a7a7eda2470570a5' -or
       $plan.compiler_sha256 -cne 'fe251ef50a1545b1b0835ee17b1e785459712b38d79e45b5c1d3d28970a36619' -or
       (Get-Item -LiteralPath $plan.telemetry_path).Length -ne 335288){throw 'Exact H1 tool identity required.'}
    Hold-DownloadPin $plan.job_assembly $plan.job_assembly_sha256
    Hold-DownloadPin (Join-Path $repo $plan.job_source) $plan.job_source_sha256
    Hold-DownloadPin $plan.job_witness_receipt $plan.job_witness_sha256
    . (Join-Path $PSScriptRoot 'Harness.Core.ps1');$policiesLoaded=$true
    foreach($name in 'H1Native.Core.ps1','MaterialV2.Compiler.ps1','H1Native.Compiler.ps1'){
        $provider=@($plan.provider_pins|Where-Object {[IO.Path]::GetFileName($_.Path) -ceq $name})
        if($provider.Count -ne 1){throw 'Exact provider filename required.'}
        . $provider[0].Path
    }
    . (Join-Path $PSScriptRoot 'Harness.Profile.ps1')
    . (Join-Path $repo 'ops/Resource-Scheduler.Core.ps1')
    $lease=Enter-IW7ResourceLease -Scope $output -Kind Build -Owner 'Community download sequential H1 jobs' -PhysicalBytes 4GB -CommitBytes 6GB
    $context.Lease=$lease;$record.Admitted=$true;$record.LeaseToken=$lease.Token
    $timing=[ordered]@{StartedMs=(Get-H1Clock)} # One clock before staging/observer load/all three jobs.
    if(Test-Path -LiteralPath $output){throw 'Output appeared during admission.'}
    [IO.Directory]::CreateDirectory($output)|Out-Null
    $reserve=New-DownloadReceiptReserve $output
    $null=[Reflection.Assembly]::LoadFrom($plan.job_assembly)
    Assert-DownloadGlobal
    $observer=@($plan.provider_pins|Where-Object Relative -CEQ 'tools-source/asset-bridge/h1-fixture/H1Native.JobMembers.cs')[0]
    Add-Type -LiteralPath $observer.Path # Existing unchanged read-only H1 observer; admitted Run only.
    Assert-DownloadGlobal
    $nativePlan=$plan.PSObject.Copy()
    $nativePlan|Add-Member Compiler $plan.compiler_path
    $nativePlan|Add-Member RunRoot $output
    $nativePlan|Add-Member Bindings @($pins.ToArray())
    $ticketPath=Join-Path $output 'worker-ticket.json'
    $ticket=[ordered]@{schema='iw7.community-download-worker/2';launcher_pid=$PID;expires_unix=[DateTimeOffset]::UtcNow.AddMinutes(4).ToUnixTimeSeconds();plan=$plan}
    [IO.File]::WriteAllText($ticketPath,($ticket|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
    $compileArgs=@(Get-DownloadCompileArguments $PSScriptRoot $output)
    if(($compileArgs -join "`0") -cne (@($plan.compiler_arguments) -join "`0")){throw 'Exact planned compiler command differs.'}
    $executable=Join-Path $output 'compile/test_download.exe'
    $compiledArtifacts=@()
    for($index=0;$index -lt 3;$index++){
        Assert-DownloadGlobal
        if(!$context.Closed){throw 'Previous original job is not closed.'}
        $name=$plan.stages[$index];$stageRoot=Join-Path $output $name.ToLowerInvariant()
        [IO.Directory]::CreateDirectory($stageRoot)|Out-Null
        $stage=[ordered]@{Stage=$name;PlanSHA256=$ApprovedPlanSHA256;DeadlineSeconds=$plan.stage_seconds[$index];
            MaxObservedOutputBytes=0L;TreeClosureConfirmed=$false;CompilerTelemetry=[ordered]@{Completed=$false;Action=$null}}
        $record.Stages.Add($stage)
        $image=if($name -ceq 'Prepare'){$plan.python_path}elseif($name -ceq 'Compile'){$plan.compiler_path}else{$executable}
        $imageHash=if($name -ceq 'Prepare'){$plan.python_sha256}elseif($name -ceq 'Compile'){$plan.compiler_sha256}else{
            @($compiledArtifacts|Where-Object Path -CEQ $executable)[0].SHA256
        }
        $start=[Diagnostics.ProcessStartInfo]::new($image)
        $start.WorkingDirectory=$stageRoot;$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.WindowStyle='Hidden'
        $start.Environment.Remove('CL')|Out-Null;$start.Environment.Remove('_CL_')|Out-Null
        $start.Environment['PATH']=(Split-Path $plan.compiler_path -Parent)+';'+$env:PATH
        $start.Environment['INCLUDE']=$plan.include_paths -join ';';$start.Environment['LIB']=$plan.lib_paths -join ';'
        $argsForStage=if($name -ceq 'Prepare'){@('-B',(Join-Path $PSScriptRoot 'run_tests.py'),'--original-job-ticket',$ticketPath)}elseif($name -ceq 'Compile'){$compileArgs}else{@()}
        foreach($arg in $argsForStage){$start.ArgumentList.Add([string]$arg)}
        $stage.Command=@($start.ArgumentList);$stage.ImageSHA256=$imageHash
        Invoke-DownloadH1Stage $nativePlan $stage $context $start $imageHash $stageRoot $timing {Assert-OutputBudget}
        # Regular files are sealed only after original-job closure/CloseConfirmed;
        # do not invent pipe EOF or pre-Stop stream closure from a file read.
        $stage.Logs=@(foreach($log in 'stdout.log','stderr.log'){Lock-DownloadArtifact (Join-Path $stageRoot $log) $guards 1MB})
        if($name -ceq 'Prepare'){
            $null=Lock-DownloadArtifact (Join-Path $output 'prepared-result.json') $guards 4KB
            $prepared=Read-H1SmallJson (Join-Path $output 'prepared-result.json') 4KB
            if($prepared.schema -cne 'iw7.community-download-prepared/1' -or $prepared.overlay_sha256 -cne $plan.overlay_sha256){throw 'Prepared receipt differs.'}
            $null=Assert-OutputBudget
            foreach($file in Get-ChildItem -LiteralPath (Join-Path $output 'work') -File -Recurse){$null=Lock-DownloadArtifact $file.FullName $guards 1MB}
            Assert-Hash (Join-Path $output 'work/reconstruction/src/client/component/download.cpp') $plan.overlay_sha256
        }elseif($name -ceq 'Compile'){
            $compiledArtifacts=@(Get-DownloadCompileArtifacts $plan $context);$stage.Artifacts=$compiledArtifacts
            if($stage.CompilerTelemetry.Completed){foreach($prior in $stage.CompilerTelemetry.Artifacts){
                $fresh=@($compiledArtifacts|Where-Object Path -CEQ $prior.Path)
                if($fresh.Count -ne 1 -or $fresh[0].SHA256 -cne $prior.SHA256 -or $fresh[0].Bytes -ne $prior.Bytes){throw 'Compiler artifact changed across closure.'}
            }}
        }else{
            $expected=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'tests/expected-cases.json') -Raw|ConvertFrom-Json
            Assert-DownloadCaseOutput ([IO.File]::ReadAllText((Join-Path $stageRoot 'stdout.log'))) $expected
            if((Get-Item -LiteralPath (Join-Path $stageRoot 'stderr.log')).Length -ne 0){throw 'Native case stderr is not empty.'}
            $record.Functional=[ordered]@{functional_passed=$true;test_count=46;executable_sha256=$imageHash;
                raw_tests_log_sha256=$stage.Logs[0].SHA256;overlay_sha256=$plan.overlay_sha256}
        }
        Assert-DownloadGlobal
    }
    foreach($item in $pins){Assert-Hash $item.Path $item.SHA256}
    $null=Assert-OutputBudget;Assert-DownloadGlobal
    $record.Status='FunctionalAndOriginalJobsClosed'
}catch{$failure=$_;$record.Status='Failed';$record.Error=$_.Exception.Message}
finally{
    if($context.Owner){$record.WorkerPID=$context.Owner.PID;$record.WorkerCreationFileTime=$context.Owner.CreationFileTime}
    if($policiesLoaded){
        Complete-DownloadOwnership $context.Owner $guards $record $lease {param($token) Exit-IW7ResourceLease -Token $token} {
            param($owner) Stop-DownloadOriginalJob $owner {param($job) Stop-H1OriginalJob $job}
        }
    }else{foreach($guard in $guards){$guard.Dispose()}}
    if($failure -or $record.ForcedStop -or !$record.LeaseReleased){$record.Status='Failed'}
    if($timing){
        try{Assert-DownloadGlobal}catch{$failure=$_;$record.Status='Failed';$record.Error=$_.Exception.Message}
        $record.ElapsedMs=(Get-H1Clock)-$timing.StartedMs
    }
    $record.FinishedUtc=[datetime]::UtcNow.ToString('o')
    $record.Passed=$record.Status -ceq 'FunctionalAndOriginalJobsClosed'
}
if($reserve){
    $receiptPath=Publish-DownloadReceipt $record $reserve {Measure-OutputPayload}
    if($record.Passed){try{Assert-DownloadGlobal}catch{
        $failure=$_;$record.Status='Failed';$record.Passed=$false;$record.Error=$_.Exception.Message
        # A slow final publication cannot leave a canonical Passed receipt.
        [IO.File]::Move($receiptPath,(Join-Path $output 'run-receipt.deadline-exceeded.json'))
        $payload=[Text.Encoding]::UTF8.GetBytes(($record|ConvertTo-Json -Depth 12))
        if($payload.Length -gt 1MB){throw 'Late failure metadata exceeds bound; late attempt preserved.'}
        [IO.File]::WriteAllBytes($receiptPath,$payload)
    }}
}
if($failure){throw $failure}
if(!$record.Passed){throw 'Run did not qualify.'}
$record
