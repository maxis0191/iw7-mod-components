$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../../ops/Resource-Scheduler.Core.ps1"
. "$PSScriptRoot/../../ops/Memory-Budget.ps1"
$first = Get-IW7ResourceSnapshot
$structure = [IW7ResourceMemoryV1+PerformanceInformation]
$expectedSize = if ([IntPtr]::Size -eq 8) { 104 } else { 56 }
if ([Runtime.InteropServices.Marshal]::SizeOf([Activator]::CreateInstance($structure)) -ne $expectedSize) { throw 'Incorrect Windows ABI.' }
$pageOffset = if ([IntPtr]::Size -eq 8) { 80 } else { 40 }
if ([Runtime.InteropServices.Marshal]::OffsetOf($structure,'PageSize').ToInt32() -ne $pageOffset) { throw 'Incorrect SIZE_T alignment.' }
foreach ($i in 1..100) {
    $snapshot = Get-IW7MemorySnapshot
    $budget = Test-IW7ResourceBudget $snapshot 0 0
    if ($snapshot.Source -ne 'GetPerformanceInfo' -or $snapshot.PhysicalTotal -ne $first.PhysicalTotal -or
        $snapshot.Committed -le 0 -or !$snapshot.CapturedUtc -or
        $null -ne $snapshot.PagesInputPerSecond -or $null -ne $snapshot.PagesOutputPerSecond -or
        $budget.PhysicalReserve -ne 0 -or $budget.CommitReserve -lt 4GB) { throw 'Invalid fresh native snapshot or memory policy mismatch.' }
}
Write-Output 'PASS: actual Windows ABI and 100 fresh RAM/commit reads; unavailable paging remains null.'
