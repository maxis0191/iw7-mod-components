#requires -Version 7.4
param([Parameter(Mandatory)][string]$PreparedRoot,[Parameter(Mandatory)][string]$RestorerPath,
    [Parameter(Mandatory)][string]$OutputRoot,[string]$ReviewedRestorerSHA256,
    [switch]$Execute,[switch]$RollbackOnFailure)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/Cable-Transaction.Core.ps1"
. "$PSScriptRoot/Cable-Execute.Core.ps1"
$plan=& "$PSScriptRoot/Cable-Transaction.ps1" -Action InstallPlan -PreparedRoot $PreparedRoot
$restorerHash='B5AF5BD60F7A29AF8CB4D8A566382B90F0FE07CAC97228D218CB913F3382D647'
$plan | Add-Member RestorerReviewed ($ReviewedRestorerSHA256 -ceq $restorerHash)
# Static witness is pinned to this exact setup, not inferred from absence of imports.
$plan | Add-Member NoAutomaticRebootInstructionFound $true
$plan | Add-Member RebootEvidence 'Pinned hidden install completion chain inspected; no automatic reboot instruction found. Not an exhaustive runtime guarantee.'
if (!$Execute) { return $plan }
if (!$plan.Elevated) { throw 'Already elevated token required; no runas/UAC fallback.' }
if (!$plan.RestorerReviewed) { throw 'Exact unsigned official restorer hash must first receive technical review.' }
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$runtime=[IO.Path]::GetFullPath((Join-Path $repo 'runtime'))
$pending=Join-Path $runtime 'voice-agent/cable-command-pending.local.json'
$out=[IO.Path]::GetFullPath($OutputRoot)
if (!$out.StartsWith($runtime+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $out)) { throw 'Fresh ignored runtime transaction root required.' }
for ($cursor=Split-Path $out -Parent;$cursor;$cursor=Split-Path $cursor -Parent) {
    if ((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Reparse ancestor refused.' }
}
$mutex=[Threading.Mutex]::new($false,'Local\IW7VoiceCableTransaction')
$held=$false;$locks=[Collections.Generic.List[IO.FileStream]]::new()
try {
    $held=$mutex.WaitOne(0);if (!$held) { throw 'Another cable transaction owns the installation scope.' }
    if (Test-Path -LiteralPath $pending) { throw 'Prior owned command is unresolved; inspect retained exact identity before retry. No implicit recovery.' }
    # Hold all extracted package files and restorer against modification/deletion.
    foreach ($file in @((Get-ChildItem -LiteralPath (Join-Path $PreparedRoot 'unpacked') -File -Force).FullName)+@([IO.Path]::GetFullPath($RestorerPath))) {
        $locks.Add([IO.File]::Open($file,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read))
    }
    New-Item -ItemType Directory -Path $out | Out-Null
    $state=@{Index=0}
    $journal={param($phase,$data) [ordered]@{Utc=[datetime]::UtcNow.ToString('o');Phase=$phase;Data=$data} | ConvertTo-Json -Depth 8 -Compress | Add-Content -LiteralPath (Join-Path $out 'phases.jsonl') -Encoding utf8}.GetNewClosure()
    $snapshot={param($phase) $state.Index++;$s=& "$PSScriptRoot/Cable-Transaction.ps1" -Action Snapshot; $s | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $out ('{0:D3}-{1}.json' -f $state.Index,$phase)) -Encoding utf8;return $s}.GetNewClosure()
    $verify={
        if (Test-Path -LiteralPath $pending) { throw 'An owned system command is still unresolved; concurrent mutation refused.' }
        $fresh=& "$PSScriptRoot/Cable-Transaction.ps1" -Action InstallPlan -PreparedRoot $PreparedRoot
        if (!$fresh.Elevated -or $fresh.Setup -cne $plan.Setup -or $fresh.ExpectedInfSHA256 -cne $plan.ExpectedInfSHA256) { throw 'Installer identity/token changed.' }
        if ((Get-FileHash -LiteralPath $RestorerPath).Hash -cne $restorerHash) { throw 'Reviewed restorer changed.' }
    }.GetNewClosure()
    $run={param($exe,$arguments,$seconds)
        $start=[Diagnostics.ProcessStartInfo]::new($exe);$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.WindowStyle='Hidden'
        $start.WorkingDirectory=Split-Path $exe -Parent
        foreach ($arg in $arguments) { $start.ArgumentList.Add([string]$arg) }
        # Persistent marker prevents a second transaction after timeout/unexpected exit.
        $marker=[IO.File]::Open($pending,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
        $marker.Dispose();$p=$null;$exited=$false
        try {
            $p=[Diagnostics.Process]::Start($start)
            @{Image=$exe;SHA256=(Get-FileHash -LiteralPath $exe).Hash;Pid=$p.Id;CreationUtc=$p.StartTime.ToUniversalTime().ToString('o');Transaction=$out;Arguments=$arguments} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $pending -Encoding utf8
            & $journal 'owned_command' @{Image=$exe;Arguments=$arguments;Pid=$p.Id;CreationUtc=$p.StartTime.ToUniversalTime().ToString('o')}
            if (!$p.WaitForExit($seconds*1000)) { throw 'Owned command deadline exceeded; retain diagnostics, no concurrent rollback or forced installer termination.' }
            $exited=$true
            return $p.ExitCode
        } finally {
            if (!$p -or $exited) { Remove-Item -LiteralPath $pending -Force }
            if ($p) { $p.Dispose() }
        }
    }.GetNewClosure()
    $install={ & $run $plan.Setup @('-i','-h') 180 }.GetNewClosure()
    $idle={ if (@(Get-CimInstance Win32_Process | Where-Object { $_.Name -match '^(iw7|aurora).*\.exe$' }).Count) { throw 'Game/launcher process present; coordinated idle installation required.' } }.GetNewClosure()
    $set={param($change) $code=& $run $RestorerPath $change.Arguments 20;if ($code -ne 0) { throw 'Exact endpoint restitution command failed.' }}.GetNewClosure()
    $export={param($rollback) $backup=Join-Path $out 'driver-export';New-Item -ItemType Directory -Path $backup | Out-Null; $code=& $run "$env:windir/System32/pnputil.exe" @('/export-driver',$rollback.PublishedName,$backup) 60; if ($code -ne 0 -or !(Get-ChildItem -LiteralPath $backup -Recurse -File)) { throw 'Driver export failed; deletion refused.' }}.GetNewClosure()
    $delete={param($rollback,$snapshot)
        $bindings=@($snapshot.Bindings | Where-Object InfName -CEQ $rollback.PublishedName)
        if (!$bindings.Count -or @($bindings | Where-Object { $_.DriverProviderName -notmatch 'VB-Audio|VB Audio|Vincent Burel' -or $_.DeviceName -notmatch 'VB-Audio|CABLE' }).Count) { throw 'Unexpected/missing package bindings; removal refused.' }
        & $journal 'delete_exact_added_package' @{Package=$rollback;Bindings=$bindings}
        $code=& $run "$env:windir/System32/pnputil.exe" $rollback.Arguments 60
        if ($code -ne 0 -and $code -ne 3010) { throw 'Exact package deletion failed.' }
    }.GetNewClosure()
    Invoke-IW7CableTransaction -Adapter @{Journal=$journal;Snapshot=$snapshot;Verify=$verify;AssertIdle=$idle;Install=$install;SetDefault=$set;Export=$export;Delete=$delete} -Plan $plan -RollbackOnFailure:$RollbackOnFailure
} finally { foreach ($fileLock in $locks) { $fileLock.Dispose() };if ($held) { $mutex.ReleaseMutex() };$mutex.Dispose() }
