# Source preparation only until separately reviewed and admitted. Plan is read-only.
[CmdletBinding()]
param(
    [ValidateSet('Plan','Run')][string]$Action='Plan',
    [string]$NativeSource,[string]$OutputRoot,[string]$PythonExe,
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
$sourceNames=@('Harness.ps1','Harness.Core.ps1','run_tests.py','verify_archive.py','Download-NativeJob.cs','job-source.json','manifest.json',
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
    foreach($value in @($NativeSource,$OutputRoot,$PythonExe,$VCPath,$WindowsSdkRoot,$WindowsSdkVersion)){
        if([string]::IsNullOrWhiteSpace($value)){throw 'Plan requires NativeSource, OutputRoot, PythonExe, VCPath, WindowsSdkRoot and WindowsSdkVersion.'}
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
    [ordered]@{
        schema='iw7.community-download-plan/2';prepared_only=$true;native_started=$false;admitted=$false
        source_hashes=$sourceHashes;upstream_commit=$manifest.upstream_commit;overlay_sha256=$manifest.overlay_sha256
        native_source=[IO.Path]::GetFullPath($NativeSource);output_root=(Assert-FreshOutput $OutputRoot)
        python_path=$python;python_sha256=(Hash $python);compiler_path=$compiler;compiler_sha256=(Hash $compiler)
        compiler_file_version=(Get-Item -LiteralPath $compiler).VersionInfo.FileVersion
        linker_path=$linker;linker_sha256=(Hash $linker);include_paths=$includes;lib_paths=$libs
        resource_helper_sha256=(Hash (Join-Path $repo 'ops/Resource-Scheduler.Core.ps1'))
        resource_source_hashes=$resourceHashes
        physical_bytes=4GB;commit_bytes=6GB;artifact_limit_bytes=32MB;metadata_reserve_bytes=1MB
        expected_test_count=46;worker_timeout_seconds=180;root_exit_grace_seconds=2
        job_assembly=$assemblyPath;job_assembly_sha256=$binding.AssemblySHA256;job_source_sha256=$binding.SourceSHA256
        job_type=$binding.Type;job_source=$binding.Source;job_source_commit=$binding.SourceCommit
        job_witness_receipt=$receiptPath;job_witness_sha256=$binding.WitnessSHA256
        reviewed_prebuilt_job_assembly_bound=$assemblyBound
        original_job_contract='Atomic job-at-create; no breakaway; retain original handle through root exit, member capture, stop if required and ActiveProcesses=0'
        member_observation_contract='Bounded partial process samples; exact original-job membership checked on retained process handles; never a complete list or closure authority'
        helper_binding_limit='Existing native-job witness qualifies only the pinned helper; this PowerShell binding and the 46-case admitted pipeline remain unexecuted'
    } | ConvertTo-Json -Depth 8
    return
}

# Plan never imports native telemetry. Run may initialize the guarded admission
# ResourceMemory API; the job helper must already be built and reviewed separately.
if(!$IsWindows -or [IntPtr]::Size -ne 8 -or $PSVersionTable.PSVersion.Major -lt 7){throw 'Windows x64 PowerShell7 required.'}
if(!$PlanPath -or !$ApprovedPlanSHA256){throw 'Run requires a reviewed plan file and its exact ApprovedPlanSHA256.'}
Assert-Hash $PlanPath $ApprovedPlanSHA256
$plan=Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json
if($plan.schema -cne 'iw7.community-download-plan/2' -or !$plan.reviewed_prebuilt_job_assembly_bound){throw 'Reviewed original-job assembly binding required.'}
if(@(Compare-Object $sourceNames @($plan.source_hashes.PSObject.Properties.Name)).Count -or
    @(Compare-Object $resourceNames @($plan.resource_source_hashes.PSObject.Properties.Name)).Count){throw 'Exact source and admission import pin sets required.'}
if($plan.physical_bytes -ne 4GB -or $plan.commit_bytes -ne 6GB -or $plan.artifact_limit_bytes -ne 32MB -or
    $plan.metadata_reserve_bytes -ne 1MB -or $plan.worker_timeout_seconds -ne 180 -or $plan.root_exit_grace_seconds -ne 2 -or $plan.expected_test_count -ne 46){throw 'Reviewed fixed harness budget/case profile differs.'}
$output=Assert-FreshOutput $plan.output_root
foreach($item in $plan.source_hashes.PSObject.Properties){Assert-Hash (Join-Path $PSScriptRoot $item.Name) $item.Value}
foreach($label in @('python','compiler','linker')){Assert-Hash $plan.($label+'_path') $plan.($label+'_sha256')}
Assert-Hash (Join-Path $repo 'ops/Resource-Scheduler.Core.ps1') $plan.resource_helper_sha256
$binding=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'job-source.json') -Raw | ConvertFrom-Json
if($plan.job_type -cne $binding.Type -or $plan.job_source -cne $binding.Source -or
    $plan.job_source_commit -cne $binding.SourceCommit -or $plan.job_witness_sha256 -ine $binding.WitnessSHA256){throw 'Plan helper metadata differs from binding.'}
Assert-DownloadJobBinding $binding $plan.job_assembly $plan.job_assembly_sha256 $plan.job_source_sha256 $plan.job_witness_receipt
if(('IW7.AnimationProbe.NativeJob' -as [type]) -or ('IW7ResourceMemoryV1' -as [type])){throw 'Fresh PowerShell host required for the reviewed helper and guarded admission telemetry.'}
$guards=[Collections.Generic.List[IO.FileStream]]::new()
$lease=$null
$owner=$null;$access=$null;$failure=$null;$members=@{};$timing=$null;$reserve=$null;$policiesLoaded=$false
$record=[ordered]@{Schema='iw7.community-download-admitted-run/1';Status='Pending';Admitted=$false;Passed=$false;
    ApprovedPlanSHA256=$ApprovedPlanSHA256;AdmissionSnapshot=$null;LeaseToken=$null;
    LauncherPID=$PID;LauncherCreationFileTime=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToFileTimeUtc();
    StartedUtc=[datetime]::UtcNow.ToString('o');JobSourceSHA256=$plan.job_source_sha256;JobAssemblySHA256=$plan.job_assembly_sha256;
    WorkerPID=$null;WorkerCreationFileTime=$null;WorkerImage=$null;ExitCode=$null;ForcedStop=$false;
    OriginalJobClosed=$false;LeaseReleased=$false;HistoricalIncidentRequalified=$false;ObservedMembers=@();MemoryPeaksMeasured=$false;
    Quarantined=$false;QuarantineKey=$null;ReadGuardsReleased=$false;
    JobType=$plan.job_type;JobSourceCommit=$plan.job_source_commit;JobWitnessSHA256=$plan.job_witness_sha256;
    MemberObservationComplete=$false;MemberSampleCount=0;MemberSampleReadErrors=0;MemberSamplesTruncated=0}
function Measure-OutputPayload {
    $bytes=0L
    foreach($entry in Get-ChildItem -LiteralPath $output -Recurse -Force){
        if($entry.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Reparse artifact refused.'}
        if(!$entry.PSIsContainer -and (!$reserve -or $entry.FullName -cne $reserve.Path)){$bytes+=$entry.Length}
    }
    $bytes
}
function Assert-OutputBudget {
    $bytes=Measure-OutputPayload
    if($bytes -gt 31MB){throw 'Harness output exceeds budget before final metadata.'}
    $bytes
}
function Get-DownloadJobAccess($Owner) {
    $type=$Owner.GetType()
    if($type.FullName -cne 'IW7.AnimationProbe.NativeJob' -or
        [IO.Path]::GetFullPath($type.Assembly.Location) -ine [IO.Path]::GetFullPath($plan.job_assembly)){throw 'Exact loaded original-job type/location required.'}
    $instance=[Reflection.BindingFlags]'NonPublic,Instance,DeclaredOnly'
    $static=[Reflection.BindingFlags]'NonPublic,Static,DeclaredOnly'
    $result=@{Job=$type.GetField('job',$instance);Root=$type.GetMethod('RootExited',$instance)}
    foreach($name in @('TerminateJobObject','IsProcessInJob','GetProcessTimes','QueryFullProcessImageNameW')){$result[$name]=$type.GetMethod($name,$static)}
    if($result.Job.FieldType -ne [Microsoft.Win32.SafeHandles.SafeFileHandle] -or @($result.Values | Where-Object {$null -eq $_}).Count){throw 'Pinned original-job private API differs.'}
    $result
}
function Read-DownloadRoot($JobOwner) { $access.Root.Invoke($JobOwner,@()) }
function Terminate-DownloadJob($JobOwner) {
    $job=$access.Job.GetValue($JobOwner)
    if($null -ne $job -and !$job.IsInvalid){
        if(!$access.TerminateJobObject.Invoke($null,@($job,[uint32]3758096385))){throw 'Termination of exact original job failed.'}
    }
}
function Capture-OriginalMembers {
    if(!$access -or $owner.Closed){return}
    $job=$access.Job.GetValue($owner)
    if($null -eq $job -or $job.IsInvalid){return}
    # Existing P/Invokes only. No second job/native helper or PID-based kill.
    # Process inventory is a partial diagnostic sample, never closure evidence.
    $started=Get-DownloadMonotonicMs;$inventory=[Diagnostics.Process]::GetProcesses()
    $record.MemberSampleCount++;$seen=0
    try {
        foreach($candidate in $inventory){
            if($seen -ge 4096 -or (Get-DownloadMonotonicMs)-$started -ge 750){$record.MemberSamplesTruncated++;break}
            $seen++;$safe=$null;$borrowed=$null;$held=$false
            try {
                $safe=$candidate.SafeHandle;$safe.DangerousAddRef([ref]$held)
                $borrowed=[Microsoft.Win32.SafeHandles.SafeFileHandle]::new($safe.DangerousGetHandle(),$false)
                $inside=[object[]]@($borrowed,$job,$false)
                if(!$access.IsProcessInJob.Invoke($null,$inside)){throw 'Membership query failed.'}
                if(!$inside[2]){continue}
                $times=[object[]]@($borrowed,0L,0L,0L,0L)
                if(!$access.GetProcessTimes.Invoke($null,$times)){throw 'Member creation identity unavailable.'}
                $image=[Text.StringBuilder]::new(32768);$imageArgs=[object[]]@($borrowed,[uint32]0,$image,[uint32]32768)
                if(!$access.QueryFullProcessImageNameW.Invoke($null,$imageArgs)){throw 'Member image unavailable.'}
                $key="$($candidate.Id):$($times[1])"
                if(!$members.ContainsKey($key) -and $members.Count -ge 1024){throw 'Historical member observation bound exceeded.'}
                $members[$key]=[ordered]@{PID=$candidate.Id;CreationFileTime=$times[1];Image=$image.ToString();
                    MembershipVerified=$true;ObservedUtc=[datetime]::UtcNow.ToString('o')}
            } catch {$record.MemberSampleReadErrors++}
            finally {if($borrowed){$borrowed.Dispose()};if($held){$safe.DangerousRelease()}}
        }
    } finally {foreach($candidate in $inventory){$candidate.Dispose()}}
    [GC]::KeepAlive($owner)
}
function Stop-DownloadReusedOwner($JobOwner) {
    if(!$access){$script:access=Get-DownloadJobAccess $JobOwner}
    Stop-DownloadOriginalJob $JobOwner {param($jobOwner) Terminate-DownloadJob $jobOwner}
}
try {
    # Retain critical inputs BEFORE importing sources or loading the DLL. Recheck
    # the exact plan after acquiring its read guard to close hash/read replacement.
    $guards.Add((Open-DownloadReadGuard $PlanPath $ApprovedPlanSHA256))
    $guardedPlan=Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json
    if(($guardedPlan|ConvertTo-Json -Depth 12 -Compress) -cne ($plan|ConvertTo-Json -Depth 12 -Compress)){throw 'Plan changed between initial read and retained guard.'}
    foreach($name in $sourceNames){$guards.Add((Open-DownloadReadGuard (Join-Path $PSScriptRoot $name) $plan.source_hashes.$name))}
    foreach($name in $resourceNames){$guards.Add((Open-DownloadReadGuard (Join-Path $repo $name) $plan.resource_source_hashes.$name))}
    foreach($label in @('python','compiler','linker')){$guards.Add((Open-DownloadReadGuard $plan.($label+'_path') $plan.($label+'_sha256')))}
    $guards.Add((Open-DownloadReadGuard $plan.job_assembly $plan.job_assembly_sha256))
    $guards.Add((Open-DownloadReadGuard (Join-Path $repo $plan.job_source) $plan.job_source_sha256))
    $guards.Add((Open-DownloadReadGuard $plan.job_witness_receipt $plan.job_witness_sha256))
    . (Join-Path $PSScriptRoot 'Harness.Core.ps1');$policiesLoaded=$true
    . (Join-Path $repo 'ops/Resource-Scheduler.Core.ps1')
    $lease=Enter-IW7ResourceLease -Scope $output -Kind Build -Owner 'Community download original-job harness' -PhysicalBytes 4GB -CommitBytes 6GB
    $record.Admitted=$true;$record.LeaseToken=$lease.Token;$record.AdmissionSnapshot=Get-IW7ResourceSnapshot
    [IO.Directory]::CreateDirectory($output)|Out-Null
    $reserve=New-DownloadReceiptReserve $output # Allocated before any original-job launch.
    $null=[Reflection.Assembly]::LoadFrom($plan.job_assembly)
    $owner=[IW7.AnimationProbe.NativeJob]::new() # Exact existing owner retained BEFORE Start.
    $access=Get-DownloadJobAccess $owner
    $ticketPath=Join-Path $output 'worker-ticket.json'
    $ticket=[ordered]@{schema='iw7.community-download-worker/1';launcher_pid=$PID;expires_unix=[DateTimeOffset]::UtcNow.AddMinutes(4).ToUnixTimeSeconds();plan=$plan}
    [IO.File]::WriteAllText($ticketPath,($ticket|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
    $start=[Diagnostics.ProcessStartInfo]::new($plan.python_path)
    $start.WorkingDirectory=$output;$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.WindowStyle='Hidden'
    foreach($arg in @('-B',(Join-Path $PSScriptRoot 'run_tests.py'),'--original-job-ticket',$ticketPath)){$start.ArgumentList.Add($arg)}
    $start.Environment.Remove('CL')|Out-Null;$start.Environment.Remove('_CL_')|Out-Null
    $start.Environment['PATH']=(Split-Path $plan.compiler_path -Parent)+';'+$env:PATH
    $start.Environment['INCLUDE']=$plan.include_paths -join ';';$start.Environment['LIB']=$plan.lib_paths -join ';'
    $record.Command=@($start.ArgumentList);$record.ImageSHA256=$plan.python_sha256
    $timing=[ordered]@{StartedMs=(Get-DownloadMonotonicMs);RootExitObservedMs=$null}
    $owner.Start($start,$plan.python_sha256,(Join-Path $output 'worker.stdout.log'),(Join-Path $output 'worker.stderr.log'))
    Assert-DownloadDeadline $timing
    $record.WorkerPID=$owner.PID;$record.WorkerCreationFileTime=$owner.CreationFileTime;$record.WorkerImage=$owner.Image
    Register-DownloadOwner $owner $timing {param($job) Add-IW7ResourceProcess -Token $lease.Token -ProcessId $job.PID}
    while($true){
        $exited=Observe-DownloadCompletion $owner $timing {Assert-OutputBudget} {Capture-OriginalMembers} {param($jobOwner) Read-DownloadRoot $jobOwner}
        if($exited){break}
        Start-Sleep -Milliseconds 100
    }
    $owner.CloseConfirmed();Assert-DownloadDeadline $timing
    $record.ExitCode=$owner.ExitCode;$record.ElapsedMs=(Get-DownloadMonotonicMs)-$timing.StartedMs
    if($owner.ExitCode -ne 0){throw 'Worker failed; retained logs are authoritative.'}
    $functional=Get-Content -LiteralPath (Join-Path $output 'functional-result.json') -Raw | ConvertFrom-Json
    if(!$functional.functional_passed -or $functional.test_count -ne 46 -or $functional.overlay_sha256 -cne $plan.overlay_sha256){throw 'Functional receipt differs from reviewed plan.'}
    foreach($item in $plan.source_hashes.PSObject.Properties){Assert-Hash (Join-Path $PSScriptRoot $item.Name) $item.Value}
    Assert-DownloadDeadline $timing
    $record.Functional=$functional;$record.Status='FunctionalAndOriginalJobClosed'
} catch {$failure=$_;$record.Status='Failed';$record.Error=$_.Exception.Message}
finally {
    if($owner){
        $record.WorkerPID=$owner.PID;$record.WorkerCreationFileTime=$owner.CreationFileTime;$record.WorkerImage=$owner.Image
        if(!$owner.Closed){try {Capture-OriginalMembers} catch {$record.MemberCaptureError=$_.Exception.Message}}
    }
    if($policiesLoaded){Complete-DownloadOwnership $owner $guards $record $lease {param($token) Exit-IW7ResourceLease -Token $token} {param($jobOwner) Stop-DownloadReusedOwner $jobOwner}}
    else {foreach($guard in $guards){$guard.Dispose()};$record.ReadGuardsReleased=$true}
    if($owner -and $owner.Closed){$record.ExitCode=$owner.ExitCode}
    $record.ObservedMembers=@($members.Values)
    $record.FinishedUtc=[datetime]::UtcNow.ToString('o')
    if($failure -or $record.ForcedStop -or !$record.LeaseReleased){$record.Status='Failed'}
    $record.Passed=$record.Status -ceq 'FunctionalAndOriginalJobClosed'
}
if($reserve){
    $null=Publish-DownloadReceipt $record $reserve {Measure-OutputPayload}
}
if($failure){throw $failure}
if(!$record.Passed){throw 'Run did not qualify.'}
$record
