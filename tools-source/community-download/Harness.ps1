# Source preparation only until separately reviewed and admitted. Plan is read-only.
[CmdletBinding()]
param(
    [ValidateSet('Plan','Run')][string]$Action='Plan',
    [string]$NativeSource,[string]$OutputRoot,[string]$PythonExe,
    [string]$VCPath,[string]$WindowsSdkRoot,[string]$WindowsSdkVersion,
    [string]$JobAssembly,[string]$JobAssemblySHA256,[string]$JobAssemblySourceSHA256,
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

if($Action -eq 'Plan'){
    foreach($value in @($NativeSource,$OutputRoot,$PythonExe,$VCPath,$WindowsSdkRoot,$WindowsSdkVersion)){
        if([string]::IsNullOrWhiteSpace($value)){throw 'Plan requires NativeSource, OutputRoot, PythonExe, VCPath, WindowsSdkRoot and WindowsSdkVersion.'}
    }
    $manifest=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'manifest.json') -Raw | ConvertFrom-Json
    $sourceHashes=[ordered]@{}
    foreach($relative in @('Harness.ps1','run_tests.py','verify_archive.py','Download-NativeJob.cs','job-source.json','manifest.json',
        'overlay/src/client/component/download.cpp','patches/0001-contained-errors-and-verified-publication.patch',
        'tests/native_stubs.hpp','tests/test_download.cpp','LICENSE.upstream')){
        $sourceHashes[$relative]=Hash (Join-Path $PSScriptRoot $relative)
    }
    Assert-Hash (Join-Path $PSScriptRoot 'overlay/src/client/component/download.cpp') $manifest.overlay_sha256
    Assert-Hash (Join-Path $PSScriptRoot $manifest.patch) $manifest.patch_sha256
    $vc=[IO.Path]::GetFullPath($VCPath);$sdk=[IO.Path]::GetFullPath($WindowsSdkRoot)
    $compiler=Join-Path $vc 'bin/Hostx64/x64/cl.exe';$linker=Join-Path $vc 'bin/Hostx64/x64/link.exe'
    $python=[IO.Path]::GetFullPath($PythonExe)
    $includes=@((Join-Path $vc 'include'))+@('ucrt','shared','um','winrt' | ForEach-Object {Join-Path $sdk "Include/$WindowsSdkVersion/$_"})
    $libs=@((Join-Path $vc 'lib/x64'),(Join-Path $sdk "Lib/$WindowsSdkVersion/ucrt/x64"),(Join-Path $sdk "Lib/$WindowsSdkVersion/um/x64"))
    foreach($directory in @($includes)+@($libs)){if(!(Test-Path -LiteralPath $directory -PathType Container)){throw "Installed toolchain directory missing: $directory"}}
    $assemblyBound=$false;$assemblyPath=$null
    if($JobAssembly){
        $assemblyPath=[IO.Path]::GetFullPath($JobAssembly)
        Assert-Hash $assemblyPath $JobAssemblySHA256
        Assert-Hash (Join-Path $PSScriptRoot 'Download-NativeJob.cs') $JobAssemblySourceSHA256
        $assemblyBound=$true
    }
    [ordered]@{
        schema='iw7.community-download-plan/1';prepared_only=$true;native_started=$false;admitted=$false
        source_hashes=$sourceHashes;upstream_commit=$manifest.upstream_commit;overlay_sha256=$manifest.overlay_sha256
        native_source=[IO.Path]::GetFullPath($NativeSource);output_root=(Assert-FreshOutput $OutputRoot)
        python_path=$python;python_sha256=(Hash $python);compiler_path=$compiler;compiler_sha256=(Hash $compiler)
        compiler_file_version=(Get-Item -LiteralPath $compiler).VersionInfo.FileVersion
        linker_path=$linker;linker_sha256=(Hash $linker);include_paths=$includes;lib_paths=$libs
        resource_helper_sha256=(Hash (Join-Path $repo 'ops/Resource-Scheduler.Core.ps1'))
        physical_bytes=4GB;commit_bytes=6GB;artifact_limit_bytes=32MB;metadata_reserve_bytes=1MB
        expected_test_count=46;worker_timeout_seconds=180;root_exit_grace_seconds=2
        job_assembly=$assemblyPath;job_assembly_sha256=$JobAssemblySHA256;job_source_sha256=$sourceHashes['Download-NativeJob.cs']
        reviewed_prebuilt_job_assembly_bound=$assemblyBound
        original_job_contract='Atomic job-at-create; no breakaway; retain original handle through root exit, member capture, stop if required and ActiveProcesses=0'
        helper_binding_limit='Source/assembly hashes are review inputs, not proof of a qualified helper build; build/witness must be separately admitted'
    } | ConvertTo-Json -Depth 8
    return
}

# Run is deliberately unreachable from the default Plan path. Never Add-Type here:
# the parent must supply an already reviewed, separately admitted helper assembly.
if(!$IsWindows -or [IntPtr]::Size -ne 8 -or $PSVersionTable.PSVersion.Major -lt 7){throw 'Windows x64 PowerShell7 required.'}
if(!$PlanPath -or !$ApprovedPlanSHA256){throw 'Run requires a reviewed plan file and its exact ApprovedPlanSHA256.'}
Assert-Hash $PlanPath $ApprovedPlanSHA256
$plan=Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json
if($plan.schema -cne 'iw7.community-download-plan/1' -or !$plan.reviewed_prebuilt_job_assembly_bound){throw 'Reviewed original-job assembly binding required.'}
if($plan.physical_bytes -ne 4GB -or $plan.commit_bytes -ne 6GB -or $plan.artifact_limit_bytes -ne 32MB -or
    $plan.metadata_reserve_bytes -ne 1MB -or $plan.worker_timeout_seconds -ne 180 -or $plan.root_exit_grace_seconds -ne 2 -or $plan.expected_test_count -ne 46){throw 'Reviewed fixed harness budget/case profile differs.'}
$output=Assert-FreshOutput $plan.output_root
foreach($item in $plan.source_hashes.PSObject.Properties){Assert-Hash (Join-Path $PSScriptRoot $item.Name) $item.Value}
foreach($label in @('python','compiler','linker')){Assert-Hash $plan.($label+'_path') $plan.($label+'_sha256')}
Assert-Hash (Join-Path $repo 'ops/Resource-Scheduler.Core.ps1') $plan.resource_helper_sha256
Assert-Hash (Join-Path $PSScriptRoot 'Download-NativeJob.cs') $plan.job_source_sha256
Assert-Hash $plan.job_assembly $plan.job_assembly_sha256
if('IW7.CommunityDownload.NativeJob' -as [type]){throw 'Fresh PowerShell process required for the exact reviewed helper assembly.'}
. (Join-Path $repo 'ops/Resource-Scheduler.Core.ps1')
$lease=$null
$owner=$null;$failure=$null;$members=@{};$rootExitedAt=$null
$record=[ordered]@{Schema='iw7.community-download-admitted-run/1';Status='Pending';Admitted=$false;Passed=$false;
    ApprovedPlanSHA256=$ApprovedPlanSHA256;AdmissionSnapshot=$null;LeaseToken=$null;
    LauncherPID=$PID;LauncherCreationFileTime=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToFileTimeUtc();
    StartedUtc=[datetime]::UtcNow.ToString('o');JobSourceSHA256=$plan.job_source_sha256;JobAssemblySHA256=$plan.job_assembly_sha256;
    WorkerPID=$null;WorkerCreationFileTime=$null;WorkerImage=$null;ExitCode=$null;ForcedStop=$false;
    OriginalJobClosed=$false;LeaseReleased=$false;HistoricalIncidentRequalified=$false;ObservedMembers=@();MemoryPeaksMeasured=$false}
function Assert-OutputBudget {
    $bytes=0L
    foreach($entry in Get-ChildItem -LiteralPath $output -Recurse -Force){
        if($entry.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Reparse artifact refused.'}
        if(!$entry.PSIsContainer){$bytes+=$entry.Length}
    }
    if($bytes -gt 31MB){throw 'Harness output exceeds budget before final metadata.'}
    $bytes
}
function Capture-OriginalMembers {
    foreach($member in $owner.SnapshotMembers()){
        $key="$($member.PID):$($member.CreationFileTime)"
        $members[$key]=[ordered]@{PID=$member.PID;CreationFileTime=$member.CreationFileTime;Image=$member.Image;
            MembershipVerified=$member.MembershipVerified;Error=$member.Error;ObservedUtc=[datetime]::UtcNow.ToString('o')}
        if($members.Count -gt 1024){throw 'Historical member observation bound exceeded.'}
    }
}
try {
    $lease=Enter-IW7ResourceLease -Scope $output -Kind Build -Owner 'Community download original-job harness' -PhysicalBytes 4GB -CommitBytes 6GB
    $record.Admitted=$true;$record.LeaseToken=$lease.Token;$record.AdmissionSnapshot=Get-IW7ResourceSnapshot
    [IO.Directory]::CreateDirectory($output)|Out-Null
    $null=[Reflection.Assembly]::LoadFrom($plan.job_assembly)
    $owner=[IW7.CommunityDownload.NativeJob]::new() # Retained BEFORE Start, including partial failures.
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
    $owner.Start($start,$plan.python_sha256,(Join-Path $output 'worker.stdout.log'),(Join-Path $output 'worker.stderr.log'))
    $record.WorkerPID=$owner.PID;$record.WorkerCreationFileTime=$owner.CreationFileTime;$record.WorkerImage=$owner.Image
    Add-IW7ResourceProcess -Token $lease.Token -ProcessId $owner.PID
    $timer=[Diagnostics.Stopwatch]::StartNew()
    while(!$owner.TreeExited()){
        Capture-OriginalMembers
        $null=Assert-OutputBudget
        if($owner.RootExited()){
            if($null -eq $rootExitedAt){$rootExitedAt=$timer.Elapsed.TotalSeconds}
            if($timer.Elapsed.TotalSeconds-$rootExitedAt -gt 2){throw 'Root exited with residual original-job members; capture retained, run fails.'}
        }
        if($timer.Elapsed.TotalSeconds -gt 180){throw 'Original-job harness timeout.'}
        Start-Sleep -Milliseconds 100
    }
    $owner.CloseConfirmed();$record.ExitCode=$owner.ExitCode;$record.ElapsedMs=$timer.ElapsedMilliseconds
    if($owner.ExitCode -ne 0){throw 'Worker failed; retained logs are authoritative.'}
    $functional=Get-Content -LiteralPath (Join-Path $output 'functional-result.json') -Raw | ConvertFrom-Json
    if(!$functional.functional_passed -or $functional.test_count -ne 46 -or $functional.overlay_sha256 -cne $plan.overlay_sha256){throw 'Functional receipt differs from reviewed plan.'}
    foreach($item in $plan.source_hashes.PSObject.Properties){Assert-Hash (Join-Path $PSScriptRoot $item.Name) $item.Value}
    $record.Functional=$functional;$record.Status='FunctionalAndOriginalJobClosed'
} catch {$failure=$_;$record.Status='Failed';$record.Error=$_.Exception.Message}
finally {
    if($owner){
        $record.WorkerPID=$owner.PID;$record.WorkerCreationFileTime=$owner.CreationFileTime;$record.WorkerImage=$owner.Image
        if(!$owner.Closed){
            try {Capture-OriginalMembers} catch {$record.MemberCaptureError=$_.Exception.Message}
            try {$record.ForcedStop=$true;$owner.StopAndConfirm(5000)} catch {$record.ClosureError=$_.Exception.Message;if(!$failure){$failure=$_}}
        }
        $record.OriginalJobClosed=$owner.Closed
        if($owner.Closed){$record.ExitCode=$owner.ExitCode}
    } else {$record.OriginalJobClosed=$true;$record.NoJobStarted=$true}
    if($lease -and $record.OriginalJobClosed){
        try {Exit-IW7ResourceLease -Token $lease.Token;$record.LeaseReleased=$true} catch {$record.LeaseReleaseError=$_.Exception.Message;if(!$failure){$failure=$_}}
    } elseif($lease) {$record.LeaseRetainedReason='Original-job closure unconfirmed; reservation quarantined.'}
    $record.ObservedMembers=@($members.Values)
    $record.FinishedUtc=[datetime]::UtcNow.ToString('o')
    if($failure -or $record.ForcedStop -or !$record.LeaseReleased){$record.Status='Failed'}
    $record.Passed=$record.Status -ceq 'FunctionalAndOriginalJobClosed'
}
if(Test-Path -LiteralPath $output){
    $record.ArtifactBytesBeforeReceipt=Assert-OutputBudget
    $serialized=[Text.Encoding]::UTF8.GetBytes(($record | ConvertTo-Json -Depth 12))
    if($serialized.Length -gt 1MB){throw 'Receipt metadata bound exceeded; no success receipt published.'}
    $pending=Join-Path $output 'run-receipt.pending.json';$final=Join-Path $output 'run-receipt.json'
    $stream=[IO.File]::Open($pending,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try {$stream.Write($serialized,0,$serialized.Length)} finally {$stream.Dispose()}
    [IO.File]::Move($pending,$final)
}
if($failure){throw $failure}
if(!$record.Passed){throw 'Run did not qualify.'}
$record
