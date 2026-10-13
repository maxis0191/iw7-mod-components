. "$PSScriptRoot/Resource-Memory.ps1"
function Get-IW7MemorySnapshot { Get-IW7NativeMemorySnapshot }

function Test-IW7MemoryBudget($Snapshot, [long]$AdditionalPhysical = 0, [long]$AdditionalCommit = 0) {
    if (!$Snapshot -or $Snapshot.PhysicalTotal -le 0 -or $Snapshot.CommitLimit -le 0 -or
        $Snapshot.PhysicalAvailable -lt 0 -or $Snapshot.PhysicalAvailable -gt $Snapshot.PhysicalTotal -or
        $Snapshot.Committed -lt 0 -or $Snapshot.Committed -gt $Snapshot.CommitLimit -or
        $AdditionalPhysical -lt 0 -or $AdditionalCommit -lt 0) { throw 'Invalid memory-budget inputs.' }
    $physicalUse = 1 - $Snapshot.PhysicalAvailable / $Snapshot.PhysicalTotal
    $commitUse = $Snapshot.Committed / $Snapshot.CommitLimit
    [pscustomobject]@{
        PhysicalUsedPercent = [Math]::Round(100 * $physicalUse, 2)
        CommitUsedPercent = [Math]::Round(100 * $commitUse, 2)
        PhysicalFits = ($Snapshot.PhysicalAvailable - $AdditionalPhysical) -ge 0
        CommitFits = ($Snapshot.CommitLimit - $Snapshot.Committed - $AdditionalCommit) -ge ($Snapshot.CommitLimit * 0.20)
        HighWater = ($commitUse -ge 0.85)
    }
}

function Assert-IW7MemoryHeadroom([long]$AdditionalPhysical, [long]$AdditionalCommit) {
    $budget = Test-IW7MemoryBudget (Get-IW7MemorySnapshot) $AdditionalPhysical $AdditionalCommit
    if ($budget.HighWater -or !$budget.PhysicalFits -or !$budget.CommitFits) {
        throw "Memory budget refuses launch: physical=$($budget.PhysicalUsedPercent)%, commit=$($budget.CommitUsedPercent)%; estimated workload must fit available RAM (no reserve) and leave 20% commit headroom."
    }
    $budget
}
