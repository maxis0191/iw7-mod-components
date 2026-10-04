$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../../ops/Memory-Budget.ps1"
function Check($condition, [string]$message) { if (!$condition) { throw $message } }
$sample = [pscustomobject]@{PhysicalTotal=32GB;PhysicalAvailable=16GB;CommitLimit=50GB;Committed=30GB}
$result = Test-IW7MemoryBudget $sample 8GB 8GB
Check ($result.PhysicalFits -and $result.CommitFits -and !$result.HighWater) 'Expected bounded reduced-client headroom.'
$result = Test-IW7MemoryBudget $sample 12GB 12GB
Check (!$result.PhysicalFits -and !$result.CommitFits) 'A full client must not consume the reserved margins.'
$sample.PhysicalAvailable = 24GB; $sample.Committed = 39GB
$result = Test-IW7MemoryBudget $sample 8GB 8GB
Check ($result.PhysicalFits -and !$result.CommitFits) 'Paging/trimmed resident use must not hide committed pressure.'
$sample.PhysicalAvailable = 7GB; $sample.Committed = 20GB
$result = Test-IW7MemoryBudget $sample
Check (!$result.PhysicalFits -and $result.CommitFits -and !$result.HighWater) 'Launch reservation and emergency thresholds must remain distinct.'
$sample.PhysicalAvailable = 6GB
Check ((Test-IW7MemoryBudget $sample).HighWater) 'Physical high-water mark must stop tests.'
$sample.PhysicalAvailable = 20GB; $sample.Committed = 43GB
Check ((Test-IW7MemoryBudget $sample).HighWater) 'Committed high-water mark must stop tests independently.'
$sample.PhysicalAvailable = 8GB; $sample.Committed = 40GB
$result = Test-IW7MemoryBudget $sample
Check ($result.PhysicalFits -and $result.CommitFits -and !$result.HighWater) 'Exact reservation boundaries should fit without a new allocation.'
foreach ($invalid in @($null,[pscustomobject]@{PhysicalTotal=0;PhysicalAvailable=0;CommitLimit=50GB;Committed=0},
    [pscustomobject]@{PhysicalTotal=32GB;PhysicalAvailable=33GB;CommitLimit=50GB;Committed=0})) {
    $rejected=$false
    try { Test-IW7MemoryBudget $invalid | Out-Null } catch { $rejected=$true }
    Check $rejected 'Unknown or impossible memory data must fail closed.'
}
$rejected=$false
try { Test-IW7MemoryBudget $sample -1 0 | Out-Null } catch { $rejected=$true }
Check $rejected 'Negative allocation estimates must be rejected.'
Write-Output 'PASS: independent physical/commit reservations, high-water marks, paging pressure and invalid telemetry.'
