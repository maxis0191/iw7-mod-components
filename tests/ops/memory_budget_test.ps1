$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../../ops/Memory-Budget.ps1"
function Check($condition, [string]$message) { if (!$condition) { throw $message } }
$sample = [pscustomobject]@{PhysicalTotal=32GB;PhysicalAvailable=16GB;CommitLimit=50GB;Committed=30GB}
$result = Test-IW7MemoryBudget $sample 8GB 8GB
Check ($result.Policy -eq 'TelemetryOnly' -and $result.PhysicalFits -and $result.CommitFits -and !$result.HighWater) 'Valid telemetry must use the owner telemetry-only policy.'
$result = Test-IW7MemoryBudget $sample 12GB 12GB
Check ($result.PhysicalFits -and $result.CommitFits) 'No projected commit reserve may block tests.'
$sample.PhysicalAvailable = 24GB; $sample.Committed = 39GB
$result = Test-IW7MemoryBudget $sample 8GB 8GB
Check ($result.PhysicalFits -and $result.CommitFits -and $result.CommitUsedPercent -eq 78) 'Committed pressure remains visible without refusing work.'
$sample.PhysicalAvailable = 7GB; $sample.Committed = 20GB
$result = Test-IW7MemoryBudget $sample
Check ($result.PhysicalFits -and $result.CommitFits -and !$result.HighWater) 'Zero additional RAM must fit regardless of the former margin.'
$sample.PhysicalAvailable = 6GB
Check (!(Test-IW7MemoryBudget $sample).HighWater) 'RAM usage above80 percent must not stop tests.'
$sample.PhysicalAvailable = 1GB
Check ((Test-IW7MemoryBudget $sample 1GB 0).PhysicalFits) 'Exact available RAM must fit without a reserve.'
Check ((Test-IW7MemoryBudget $sample 96GB 96GB).PhysicalFits) 'An estimate above available memory must not refuse work.'
$sample.PhysicalAvailable = 20GB; $sample.Committed = 43GB
Check (!(Test-IW7MemoryBudget $sample).HighWater) 'Committed percentages must not stop tests.'
$sample.PhysicalAvailable = 8GB; $sample.Committed = 40GB
$result = Test-IW7MemoryBudget $sample
Check ($result.PhysicalFits -and $result.CommitFits -and !$result.HighWater) 'Exact reservation boundaries should fit without a new allocation.'
$sample.PhysicalAvailable=0; $sample.Committed=$sample.CommitLimit
$result=Test-IW7MemoryBudget $sample 96GB 96GB
Check ($result.PhysicalFits -and $result.CommitFits -and !$result.HighWater -and $result.PhysicalUsedPercent -eq 100 -and $result.CommitUsedPercent -eq 100) 'Zero available capacity is telemetry, not a replacement numeric barrier.'
Check ($result.AdditionalPhysical -eq 96GB -and $result.AdditionalCommit -eq 96GB) 'Complete estimates remain visible.'
function Get-IW7MemorySnapshot { $sample }
Check ((Assert-IW7MemoryHeadroom 96GB 96GB).Policy -eq 'TelemetryOnly') 'The real assertion wrapper must not reintroduce projected-capacity refusal.'
foreach ($invalid in @($null,[pscustomobject]@{PhysicalTotal=0;PhysicalAvailable=0;CommitLimit=50GB;Committed=0},
    [pscustomobject]@{PhysicalTotal=32GB;PhysicalAvailable=33GB;CommitLimit=50GB;Committed=0})) {
    $rejected=$false
    try { Test-IW7MemoryBudget $invalid | Out-Null } catch { $rejected=$true }
    Check $rejected 'Unknown or impossible memory data must fail closed.'
}
$rejected=$false
try { Test-IW7MemoryBudget $sample -1 0 | Out-Null } catch { $rejected=$true }
Check $rejected 'Negative allocation estimates must be rejected.'
Write-Output 'PASS: telemetry-only physical/commit estimates and percentages, assertion wrapper and invalid telemetry.'
