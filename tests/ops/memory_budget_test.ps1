$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../../ops/Memory-Budget.ps1"
function Check($condition, [string]$message) { if (!$condition) { throw $message } }
$sample = [pscustomobject]@{PhysicalTotal=32GB;PhysicalAvailable=16GB;CommitLimit=50GB;Committed=30GB}
$result = Test-IW7MemoryBudget $sample 8GB 8GB
Check ($result.PhysicalFits -and $result.CommitFits -and !$result.HighWater) 'Expected bounded reduced-client headroom.'
$result = Test-IW7MemoryBudget $sample 12GB 12GB
Check ($result.PhysicalFits -and $result.CommitFits) 'Neither RAM nor commit has an artificial reserve.'
$sample.PhysicalAvailable = 24GB; $sample.Committed = 43GB
$result = Test-IW7MemoryBudget $sample 8GB 8GB
Check ($result.PhysicalFits -and !$result.CommitFits) 'Paging/trimmed resident use must not hide committed pressure.'
$sample.PhysicalAvailable = 7GB; $sample.Committed = 20GB
$result = Test-IW7MemoryBudget $sample
Check ($result.PhysicalFits -and $result.CommitFits -and !$result.HighWater) 'Zero additional RAM must fit regardless of the former margin.'
$sample.PhysicalAvailable = 6GB
Check (!(Test-IW7MemoryBudget $sample).HighWater) 'RAM usage above80 percent must not stop tests.'
$sample.PhysicalAvailable = 1GB
Check ((Test-IW7MemoryBudget $sample 1GB 0).PhysicalFits) 'Exact available RAM must fit without a reserve.'
Check (!(Test-IW7MemoryBudget $sample (1GB+1) 0).PhysicalFits) 'Do not reserve more RAM than is actually available.'
$sample.PhysicalAvailable = 20GB; $sample.Committed = 43GB
Check (!(Test-IW7MemoryBudget $sample).HighWater) 'Commit use above 85 percent must not stop tests.'
Check ((Test-IW7MemoryBudget $sample 0 7GB).CommitFits) 'Exact available commit capacity must fit.'
Check (!(Test-IW7MemoryBudget $sample 0 (7GB+1)).CommitFits) 'Actual commit capacity must not be exceeded.'
$sample.Committed=50GB
Check ((Test-IW7MemoryBudget $sample).HighWater) 'Actual commit exhaustion remains observable.'
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
