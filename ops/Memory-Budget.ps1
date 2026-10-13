. "$PSScriptRoot/Resource-Memory.ps1"
function Get-IW7MemorySnapshot { Get-IW7NativeMemorySnapshot }

function Test-IW7MemoryBudget($Snapshot, [long]$AdditionalPhysical = 0, [long]$AdditionalCommit = 0) {
    if (!$Snapshot -or $Snapshot.PhysicalTotal -le 0 -or $Snapshot.CommitLimit -le 0 -or
        $Snapshot.PhysicalAvailable -lt 0 -or $Snapshot.PhysicalAvailable -gt $Snapshot.PhysicalTotal -or
        $Snapshot.Committed -lt 0 -or $Snapshot.Committed -gt $Snapshot.CommitLimit -or
        $AdditionalPhysical -lt 0 -or $AdditionalCommit -lt 0) { throw 'Invalid memory-budget inputs.' }
    $physicalUse = 1 - $Snapshot.PhysicalAvailable / $Snapshot.PhysicalTotal
    $commitUse = $Snapshot.Committed / $Snapshot.CommitLimit
    # Owner decision 2026-10-13: compatibility API for telemetry only.
    # Complete leases, ownership and teardown are enforced by Resource-Scheduler.
    [pscustomobject]@{
        Policy = 'TelemetryOnly'
        PhysicalUsedPercent = [Math]::Round(100 * $physicalUse, 2)
        CommitUsedPercent = [Math]::Round(100 * $commitUse, 2)
        AdditionalPhysical = $AdditionalPhysical
        AdditionalCommit = $AdditionalCommit
        PhysicalFits = $true
        CommitFits = $true
        HighWater = $false
    }
}

function Assert-IW7MemoryHeadroom([long]$AdditionalPhysical, [long]$AdditionalCommit) {
    $budget = Test-IW7MemoryBudget (Get-IW7MemorySnapshot) $AdditionalPhysical $AdditionalCommit
    # Preserve fresh snapshot validation; no estimated headroom may refuse work.
    $budget
}
