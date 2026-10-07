param([Parameter(Mandatory)][string]$CaseRoot,[Parameter(Mandatory)][string]$LeaseToken,
      [Parameter(Mandatory)]$CleanupState,[switch]$DryRun,
      [ValidateSet("reset-callers","reset-entry-targets")][string]$PagePlan="reset-callers")
$ErrorActionPreference='Stop'
$ops=Split-Path $PSScriptRoot -Parent;$repo=Split-Path $ops -Parent
. "$ops/Base-Client.Core.ps1"
. "$ops/Resource-Scheduler.Core.ps1"
. "$PSScriptRoot/CodePages.Core.ps1"
$container=Resolve-IW7BasePath $repo 'runtime/agent-lab'
$absolute=(Resolve-Path -LiteralPath $CaseRoot).Path.TrimEnd('\','/')
if (!$absolute.StartsWith($container+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Case must be inside this worktree Agent-Lab runtime.' }
$case=Resolve-IW7BasePath $container $absolute.Substring($container.Length+1)
foreach ($name in @('plan.local.json','server.identity.local.json')) {
    if ((Get-Item -LiteralPath (Resolve-IW7BasePath $case $name)).Length -gt 1MB) { throw 'Bounded owned case evidence required.' }
}
$plan=Get-Content -LiteralPath (Resolve-IW7BasePath $case 'plan.local.json') -Raw|ConvertFrom-Json
$identity=Get-Content -LiteralPath (Resolve-IW7BasePath $case 'server.identity.local.json') -Raw|ConvertFrom-Json
if ([IO.Path]::GetFullPath($identity.Stdout) -ine (Resolve-IW7BasePath $case 'server.stdout.log')) { throw 'Server stdout is not this owned case.' }
$leases=@((Get-IW7ResourceStatus).Leases | Where-Object Token -CEQ $LeaseToken)
if ($leases.Count -ne 1) { throw 'Exact active runtime lease absent.' }
Assert-IW7BaseIdentity $identity
$process=Get-CimInstance Win32_Process -Filter "ProcessId=$($identity.PID)" -OperationTimeoutSec 5
Assert-IW7CapacityPageAdmission $plan $identity $leases[0] $process
if (!$CleanupState -or !$CleanupState.PSObject.Properties['Confirmed']) { throw 'Caller-owned shared cleanup state required; no launch.' }
$proof=$null
if ($PagePlan -eq 'reset-entry-targets') {
    $proofPath=Join-Path $PSScriptRoot 'reset-entry-plan.json'
    $proof=Get-Content -LiteralPath $proofPath -Raw|ConvertFrom-Json
    $parentPath=Resolve-IW7BasePath $repo $proof.parent_capture
    $manifest=Resolve-IW7BasePath $parentPath 'manifest.local.json'
    if ((Get-FileHash -LiteralPath $manifest).Hash -ine $proof.manifest_sha256) { throw 'Parent capture proof hash differs.' }
    foreach ($entry in $proof.entries) {
        $page=Resolve-IW7BasePath $parentPath $entry.parent_page
        if ((Get-Item -LiteralPath $page).Length -ne 4096 -or (Get-FileHash -LiteralPath $page).Hash -ine $entry.parent_page_sha256) { throw 'Parent thunk page proof differs.' }
    }
}
$count=if ($PagePlan -eq 'reset-entry-targets') { 2 } else { 8 }
$output=Resolve-IW7BasePath $case ('capacity-pages-'+[guid]::NewGuid().ToString('N'))
if ($DryRun) { [pscustomobject]@{CaseRoot=$case;PID=$identity.PID;PagePlan=$PagePlan;Pages=$count;Bytes=($count*4096);Suspends=$false;WritesTarget=$false;ChildProcesses=0;Output=$output};return }
if (!('IW7CapacityPages' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'CodePages.cs') }
$reader=$null
try {
    $reader=[IW7CapacityPages]::new([int]$identity.PID,$identity.Image,([datetimeoffset]$identity.CreatedUtc).UtcDateTime.ToFileTimeUtc(),$PagePlan)
    $CleanupState.Confirmed=$false
    Save-IW7CapacityCodePages $reader $output $identity $PagePlan $proof
    Assert-IW7BaseIdentity $identity
} finally {
    if ($reader) {
        $reader.Dispose()
        $CleanupState.Confirmed=$reader.Closed
    }
}
$admission=[ordered]@{Schema='iw7.capacity-page-admission/1';CaseRoot=$case;PlanSHA256=(Get-FileHash -LiteralPath (Join-Path $case 'plan.local.json')).Hash;
    Identity=$identity;LeaseToken=$LeaseToken;LeaseScope=$leases[0].Scope;PhysicalBytes=$leases[0].PhysicalBytes;CommitBytes=$leases[0].CommitBytes;
    HelperSHA256=(Get-FileHash -LiteralPath $PSCommandPath).Hash;ReaderSourceSHA256=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'CodePages.cs')).Hash;
    PagePlan=$PagePlan;ParentProof=$proof;PlanFixtureSHA256=$(if ($proof) {(Get-FileHash -LiteralPath $proofPath).Hash}else{$null});
    ChildProcesses=0;ReadOnlyHandleAccess='QUERY_INFORMATION|VM_READ|SYNCHRONIZE';Pristine=$false;PatchReady=$false}
$stream=[IO.File]::Open((Resolve-IW7BasePath $output 'admission.local.json'),'CreateNew','Write','None')
try { $bytes=[Text.Encoding]::UTF8.GetBytes(($admission | ConvertTo-Json -Depth 8));$stream.Write($bytes) } finally {$stream.Dispose()}
[pscustomobject]@{Output=$output;Pristine=$false;PatchReady=$false;ChildProcesses=0}
