param(
    [ValidateSet('Run','Observe')][string]$Action='Observe',
    [ValidateRange(1,600)][int]$Seconds=60,
    [switch]$Client,
    [string]$SeparateClientReason,
    [switch]$ReducedGraphics,
    [ValidateRange(1,1000)][double]$ExpectedFps=30,
    [ValidateRange(1,1000)][double]$ExpectedTPS=20,
    [ValidateSet('cp_zmb','cp_rave','cp_disco','cp_town','cp_final')][string]$Map='cp_zmb',
    [switch]$SkipPresentMon,
    [string]$ComparisonContext,
    [int]$MeasurementStartSeconds,
    [int]$MeasurementEndSeconds
)
$ErrorActionPreference='Stop'
$hasComparisonContext=$PSBoundParameters.ContainsKey('ComparisonContext')
$hasMeasurementStart=$PSBoundParameters.ContainsKey('MeasurementStartSeconds')
$hasMeasurementEnd=$PSBoundParameters.ContainsKey('MeasurementEndSeconds')
if ($hasComparisonContext -or $hasMeasurementStart -or $hasMeasurementEnd) {
    if (!$hasComparisonContext -or !$hasMeasurementStart -or !$hasMeasurementEnd -or
        [string]::IsNullOrWhiteSpace($ComparisonContext)) { throw 'Supply ComparisonContext, MeasurementStartSeconds and MeasurementEndSeconds together.' }
    if ($MeasurementStartSeconds -lt 30 -or $MeasurementStartSeconds -ge $MeasurementEndSeconds -or
        $MeasurementEndSeconds -gt $Seconds) { throw 'Comparison window must satisfy 30 <= start < end <= Seconds.' }
}
if ($Client -and [string]::IsNullOrWhiteSpace($SeparateClientReason)) {
    throw 'The automated debugger client uses a separate lab root. Use the base client by default, or document a necessary exception with -SeparateClientReason; see docs/INSTANCE-WORKFLOW.md.'
}
if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'Use PowerShell 7.' }
$repo=Split-Path $PSScriptRoot -Parent
$lab=Join-Path $repo 'runtime/isolated-lab'
$statePath=Join-Path $lab 'lab.json'
$case=Join-Path $repo ('runtime/debugger/session-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))
if (!(Test-Path $statePath)) { throw 'Prepare this worktree isolated lab first; see docs/DEBUGGER.md.' }
# Reuse checked path/identity/lease helpers; never launch a raw game executable.
$labOps=Join-Path $PSScriptRoot 'Isolated-Lab.ps1'
$startedServer=$false; $startedClient=$false; $present=$null
try {
    $state=Get-Content $statePath -Raw | ConvertFrom-Json
    foreach ($path in @($repo,(Join-Path $repo 'runtime'),$lab,(Join-Path $repo 'runtime/debugger'))) {
        if ((Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Redirected session container refused.' }
    }
    if (!$state.Debugger -and $Action -eq 'Observe') { throw 'Observe requires an explicitly installed debugger lab.' }
    if ($Action -eq 'Run') {
        # Closed identities are retained as evidence. Install checks actual
        # owned/unrecorded processes, including PID reuse, before any mutation.
        & $labOps -Action Install -Profile Modules -Debugger -ModuleFixture $(if ($Client) {'CrossMap'} else {'StartupOnly'}) -Map $Map
        & $labOps -Action StartServer -PlannedClients $([int][bool]$Client) -ReducedGraphics:$ReducedGraphics -EnableAudio:$Client
        $startedServer=$true
        if ($Client) { & $labOps -Action StartClient -SeparateClientReason $SeparateClientReason; $startedClient=$true }
        $state=Get-Content $statePath -Raw | ConvertFrom-Json
    }
    if (!$state.Debugger -or !$state.RunPlan.Debugger -or !$state.ResourceToken -or !$state.Server) { throw 'Exact active debugger runtime plan required.' }
    . "$PSScriptRoot/Resource-Scheduler.Core.ps1"
    $status=Get-IW7ResourceStatus
    $lease=@($status.Leases | Where-Object { $_.Token -eq $state.ResourceToken -and $_.Kind -eq 'Runtime' -and $_.Scope -eq (Get-IW7CanonicalScope $lab) })
    if ($lease.Count -ne 1 -or $lease[0].PhysicalBytes -lt $state.RunPlan.PhysicalBytes -or $lease[0].CommitBytes -lt $state.RunPlan.CommitBytes) { throw 'Complete active reservation could not be verified.' }
    [IO.Directory]::CreateDirectory($case) | Out-Null
    $targets=@()
    foreach ($kind in @('Server','Client')) {
        $record=$state.$kind
        if (!$record) { continue }
        $root=Join-Path $lab $(if ($kind -eq 'Server') {'server'} else {'client'})
        $image=Join-Path $root 'iw7-paris-lab.exe'
        # Identity adapter plus Python retained handle both check this process.
        $identity=(& "$PSScriptRoot/Debug-Server.ps1" -Action Identity -ProcessId $record.PID | ConvertFrom-Json)
        if ($identity.Image -ne $image -or $identity.SHA256 -ne $record.SHA256 -or
            [math]::Abs((([datetimeoffset]$identity.CreatedUtc)-([datetimeoffset]$record.CreatedUtc)).TotalMilliseconds) -gt 1) { throw 'Session process identity changed; preserve it.' }
        $targets += [ordered]@{name=$kind;pid=[int]$record.PID;image=$image;created_utc=([datetimeoffset]$record.CreatedUtc).ToString('o');sha256=$record.SHA256;stdout=$record.Stdout;stderr=$record.Stderr}
    }
    $targetsPath=Join-Path $case 'targets.local.json'
    $targets | ConvertTo-Json -Depth 5 -AsArray | Set-Content $targetsPath -Encoding utf8
    $csv=Join-Path $case 'presents.csv'
    $clientTarget=@($targets | Where-Object name -EQ 'Client')
    if ($clientTarget.Count -and !$SkipPresentMon) {
        $exe=Join-Path $repo 'tools/presentmon/PresentMon-2.6.0-x64.exe'
        if (!(Test-Path $exe) -or (Get-FileHash $exe).Hash -ne 'B2A706BC6AD475749E3B7E3409263AA1E6906D45BDCF993F6DBC0F660188F1AF') { throw 'Install pinned PresentMon: ops/Install-Tools.ps1 -IncludeDebugger.' }
        $start=[Diagnostics.ProcessStartInfo]::new($exe)
        $start.UseShellExecute=$false; $start.CreateNoWindow=$true
        $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
        foreach ($arg in @('--process_id',"$($clientTarget[0].pid)",'--output_file',$csv,'--v1_metrics','--timed',"$Seconds",'--terminate_after_timed','--terminate_on_proc_exit','--no_console_stats','--session_name',('IW7Debugger-'+[guid]::NewGuid().ToString('N')))) { $start.ArgumentList.Add($arg) }
        $present=[Diagnostics.Process]::Start($start)
        $presentOut=$present.StandardOutput.ReadToEndAsync(); $presentErr=$present.StandardError.ReadToEndAsync()
    }
    $arguments=@("$PSScriptRoot/iw7_watch.py",'--targets',$targetsPath,'--seconds',"$Seconds",'--output',(Join-Path $case 'live.jsonl'),
        '--frame-budget-ms',([double](1000/$ExpectedFps)).ToString([Globalization.CultureInfo]::InvariantCulture),'--expected-tps',$ExpectedTPS.ToString([Globalization.CultureInfo]::InvariantCulture),'--port',"$($state.ServerPort)")
    if ($hasComparisonContext) {
        $arguments+=@('--comparison-context',$ComparisonContext,
            '--measurement-start-seconds',$MeasurementStartSeconds.ToString([Globalization.CultureInfo]::InvariantCulture),
            '--measurement-end-seconds',$MeasurementEndSeconds.ToString([Globalization.CultureInfo]::InvariantCulture))
    }
    if ($present) { $arguments+=@('--present-csv',$csv) }
    & python @arguments
    if ($LASTEXITCODE) { throw "Live observer aborted; evidence remains at $case." }
    if ($present) {
        if (!$present.WaitForExit(5000)) { $present.Kill($true); $present.WaitForExit() }
        [IO.File]::WriteAllText((Join-Path $case 'presentmon.local.txt'),$presentOut.GetAwaiter().GetResult()+$presentErr.GetAwaiter().GetResult())
        if ($present.ExitCode) { Write-Warning "PresentMon unavailable (exit $($present.ExitCode)); FPS coverage was not established." }
    }
    & python "$PSScriptRoot/iw7_debugger.py" --output (Join-Path $case 'performance.json') perf (Join-Path $case 'live.jsonl') --token-root "$repo/tools/iw7-mod-native/deps/gsc-tool/src/gsc/engine" | Out-Null
    if ($LASTEXITCODE) { throw 'Session report failed.' }
    Write-Output "Debugger evidence: $case"
} finally {
    if ($present) { if (!$present.HasExited) { $present.Kill($true); $present.WaitForExit() }; $present.Dispose() }
    if ($startedClient) { & $labOps -Action StopClient }
    if ($startedServer) { & $labOps -Action StopServer }
}
