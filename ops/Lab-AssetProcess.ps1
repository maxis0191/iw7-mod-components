# The caller owns the resource lease. CleanupState is shared (not a copied local
# Boolean) so nested callers retain the lease/drive if termination is unconfirmed.
if (!('IW7LabProcess' -as [type])) { Add-Type -Path "$PSScriptRoot/native/LabProcess.cs" }

function Invoke-IW7LabAssetProcess {
    param(
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string[]]$ToolArguments,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string]$LogDirectory,
        [Parameter(Mandatory)][ValidatePattern('^[a-z0-9_-]+$')][string]$Phase,
        [Parameter(Mandatory)][string]$LeaseToken,
        [Parameter(Mandatory)]$CleanupState,
        [ValidateRange(1,600)][int]$TimeoutSeconds = 240,
        [ValidateRange(50,2000)][int]$PollMilliseconds = 1000
    )
    if (!$CleanupState -or !$CleanupState.PSObject.Properties['Confirmed']) { throw 'Missing shared asset cleanup state.' }
    $quoted = foreach ($argument in $ToolArguments) {
        # Tool commands use simple tokens/paths, never shell interpolation.
        if (!$argument -or $argument -match '["\x00-\x1f]' -or $argument.EndsWith('\')) { throw 'Unsupported asset-tool argument.' }
        '"' + $argument + '"'
    }
    Assert-IW7MemoryHeadroom 2GB 2GB | Out-Null
    $runId = $Phase + '-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N')
    $stdout = Join-Path $LogDirectory ($runId + '.stdout.log')
    $stderr = Join-Path $LogDirectory ($runId + '.stderr.log')
    $desktop = 'IW7ParisLab_' + [guid]::NewGuid().ToString('N')
    $owned = $null
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        $owned = [IW7LabProcess]::StartOwned($Executable, ($quoted -join ' '), $WorkingDirectory, $stdout, $stderr, $desktop, $false)
        $CleanupState.Confirmed = $false
        try {
            if (!$owned.HasExited) { Add-IW7ResourceProcess -Token $LeaseToken -ProcessId $owned.Id }
        } catch {
            # CIM may miss a child which already exited. Only this specific race
            # is recoverable, with exit proven by the original creation handle.
            if (!$owned.HasExited -or $_.Exception.Message -ne 'Child identity unavailable; reservation retained.') { throw }
        }
        while (!$owned.HasExited) {
            $remaining = [long]$TimeoutSeconds * 1000 - $clock.ElapsedMilliseconds
            if ($remaining -le 0) { throw "$Phase exceeded its time budget; diagnostics: $stdout" }
            if ($owned.WaitForExit([int][math]::Min($PollMilliseconds, $remaining))) { break }
            if ((Test-IW7MemoryBudget (Get-IW7MemorySnapshot)).HighWater) {
                throw "$Phase exceeded its memory budget; diagnostics: $stdout"
            }
        }
        [pscustomobject]@{Phase=$Phase;ExitCode=$owned.ExitCode;ProcessId=$owned.Id;Stdout=$stdout;Stderr=$stderr}
    } finally {
        if ($owned) {
            try {
                if (!$owned.HasExited) { $owned.Terminate(3758096387) }
                if (!$owned.WaitForExit(5000)) { throw 'Asset child termination is not confirmed; retain its resource lease and diagnostics.' }
                $CleanupState.Confirmed = $true
            } finally { $owned.Dispose() }
        }
        $clock.Stop()
    }
}
