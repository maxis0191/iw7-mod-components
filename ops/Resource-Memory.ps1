function Initialize-IW7ResourceMemory {
    # Compiling the reader costs about 0.75 s once per process: callers do it before taking the admission lock.
    if (!('IW7ResourceMemoryV1' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'native/ResourceMemory.cs') -ErrorAction Stop
    }
}
function Get-IW7NativeMemorySnapshot {
    Initialize-IW7ResourceMemory
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
