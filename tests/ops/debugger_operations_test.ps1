$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$observer=Join-Path $repo 'ops/Debug-Server.ps1'
$output=Join-Path $repo ('runtime/debugger/tests/observer-'+[guid]::NewGuid().ToString('N')+'.jsonl')
$hostProcess=Get-Process -Id $PID
try {
    $identity=(& $observer -Action Identity -ProcessId $PID | ConvertFrom-Json)
    if ($identity.Image -ne $hostProcess.MainModule.FileName -or !$identity.SHA256) { throw 'Identity did not bind exact process.' }
    $rejected=$false
    try { & $observer -Action Observe -ProcessId $PID -ExpectedImage $identity.Image -ExpectedCreatedUtc $identity.CreatedUtc -ExpectedSHA256 ('0'*64) -Seconds 1 -OutputPath $output }
    catch { $rejected=$true }
    if (!$rejected -or (Test-Path $output)) { throw 'Mismatched identity reached acquisition.' }
    & $observer -Action Observe -ProcessId $PID -ExpectedImage $identity.Image -ExpectedCreatedUtc $identity.CreatedUtc -ExpectedSHA256 $identity.SHA256 -Seconds 1 -IntervalMs 250 -Threads -Scenario 'CI process observer only' -OutputPath $output
    if (!(Test-Path $output)) { throw 'Observer output missing.' }
    $rows=@(Get-Content $output | ForEach-Object { $_ | ConvertFrom-Json })
    if ($rows[0].identity.pid -ne $PID -or @($rows | Where-Object type -EQ 'sample').Count -lt 1 -or $rows[-1].type -ne 'complete') { throw 'Observer coverage failed.' }
    if (($rows | ConvertTo-Json -Depth 10) -match 'CommandLine|password|playerGuid') { throw 'Observer persisted unrequested private fields.' }
    $after=Get-Process -Id $PID
    if ($after.StartTime -ne $hostProcess.StartTime) { throw 'Observer target changed.' }
    $after.Dispose()
    & python "$repo/ops/iw7_debugger.py" perf $output | Out-Null
    if ($LASTEXITCODE) { throw 'Real observer report failed.' }
    # Invalid build/install flags refuse before build tools, files or lab settings.
    foreach ($action in @({ & "$repo/ops/Build-Voice.ps1" -Debugger }, { & "$repo/ops/Isolated-Lab.ps1" -Action Status -Debugger })) {
        $refused=$false; try { & $action } catch { $refused=$true }
        if (!$refused) { throw 'Debugger escaped explicit laboratory profile.' }
    }
    Write-Output 'Debugger real process observer, identity mismatch, privacy and profile refusal checks passed.'
} finally { $hostProcess.Dispose() }
