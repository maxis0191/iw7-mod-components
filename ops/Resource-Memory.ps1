function Get-IW7NativeMemorySnapshot {
    if (!('IW7ResourceMemoryV1' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'native/ResourceMemory.cs') -ErrorAction Stop
    }
    $memory = [IW7ResourceMemoryV1]::Read()
    [pscustomobject]@{
        PhysicalTotal = $memory.PhysicalTotal
        PhysicalAvailable = $memory.PhysicalAvailable
        Committed = $memory.Committed
        CommitLimit = $memory.CommitLimit
        PagesInputPerSecond = $null
        PagesOutputPerSecond = $null
        CapturedUtc = [datetime]::UtcNow.ToString('o')
        Source = 'GetPerformanceInfo'
    }
}
