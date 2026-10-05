param(
    [ValidateSet('Status','Release','Measure')][string]$Action='Status',
    [string]$Token,
    [ValidateRange(1,300)][int]$Seconds=15,
    [string]$OutputPath
)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/Resource-Scheduler.Core.ps1"
if ($Action -eq 'Release') {
    if (!$Token) { throw 'Release requires an exact lease token.' }
    Exit-IW7ResourceLease -Token $Token
    return
}
if ($Action -eq 'Status') { Get-IW7ResourceStatus | ConvertTo-Json -Depth 10; return }
if (!$OutputPath) {
    $runtime=Join-Path (Split-Path $PSScriptRoot -Parent) 'runtime'
    [IO.Directory]::CreateDirectory($runtime) | Out-Null
    $OutputPath=Join-Path $runtime ('resources-'+[datetime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'.jsonl')
}
$writer=[IO.StreamWriter]::new([IO.File]::Open($OutputPath,'CreateNew','Write','Read'),[Text.UTF8Encoding]::new($false))
try {
    $system=Get-CimInstance Win32_ComputerSystem
    $metadata=[pscustomobject]@{Type='machine';Utc=[datetime]::UtcNow.ToString('o');
        Processor=@(Get-CimInstance Win32_Processor | Select-Object Name,NumberOfCores,NumberOfLogicalProcessors);
        GPU=@(Get-CimInstance Win32_VideoController | Select-Object Name,DriverVersion);
        AutomaticManagedPagefile=$system.AutomaticManagedPagefile;
        Pagefiles=@(Get-CimInstance Win32_PageFileUsage | Select-Object AllocatedBaseSize,CurrentUsage,PeakUsage);
        Disks=@(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | Select-Object DeviceID,FreeSpace,Size)}
    $writer.WriteLine(($metadata | ConvertTo-Json -Depth 6 -Compress))
    $deadline=[datetime]::UtcNow.AddSeconds($Seconds)
    $samples=0; $maxPhysical=0.0; $maxCommit=0.0; $maxInput=$null; $maxOutput=$null
    do {
        $snapshot=Get-IW7ResourceSnapshot
        $budget=Test-IW7ResourceBudget $snapshot 0 0
        $cpu=Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'"
        $disk=Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk -Filter "Name='_Total'"
        $allProcesses=@(Get-IW7ResourceProcesses)
        $auxiliaries=@($allProcesses | Where-Object { $_.Name -in @('node.exe','node_repl.exe') } | Group-Object Name | ForEach-Object {
            [pscustomobject]@{Name=$_.Name;Count=$_.Count;
                WorkingSet=($_.Group | Measure-Object WorkingSet -Sum).Sum;
                PrivateBytes=($_.Group | Measure-Object PrivateBytes -Sum).Sum}
        })
        $processes=@($allProcesses | Where-Object { $_.Heavy -or $_.Name -match '^(?:codex|ChatGPT).*\.exe$' } |
            Select-Object PID,CreatedUtc,Name,Lab,WorkingSet,PrivateBytes)
        $gpu=$null
        $smi=Get-Command nvidia-smi -ErrorAction SilentlyContinue
        if ($smi -and $samples % 5 -eq 0) {
            $gpu=@(& $smi.Source --query-gpu=memory.total,memory.used,utilization.gpu,temperature.gpu,power.draw --format=csv,noheader,nounits 2>$null)
            if ($LASTEXITCODE) { $gpu=@('unavailable') }
        }
        $row=[pscustomobject]@{Type='sample';Snapshot=$snapshot;Budget=$budget;
            CpuPercent=$cpu.PercentProcessorTime;DiskQueue=$disk.CurrentDiskQueueLength;
            GPU=$gpu;GpuUnits='MiB, MiB, percent, Celsius, watts';Processes=$processes;
            AuxiliaryProcesses=$auxiliaries;AuxiliaryScope='All user projects; working sets can include shared pages. Not a reclaimable-memory estimate.'}
        $writer.WriteLine(($row | ConvertTo-Json -Depth 7 -Compress)); $writer.Flush()
        $maxPhysical=[math]::Max($maxPhysical,$budget.PhysicalUsedPercent)
        $maxCommit=[math]::Max($maxCommit,$budget.CommitUsedPercent)
        if ($null -ne $snapshot.PagesInputPerSecond) { $maxInput=[math]::Max($maxInput,$snapshot.PagesInputPerSecond) }
        if ($null -ne $snapshot.PagesOutputPerSecond) { $maxOutput=[math]::Max($maxOutput,$snapshot.PagesOutputPerSecond) }
        $samples++
        if ([datetime]::UtcNow -lt $deadline) { Start-Sleep -Seconds 1 }
    } while ([datetime]::UtcNow -lt $deadline)
    [pscustomobject]@{OutputPath=[IO.Path]::GetFullPath($OutputPath);Samples=$samples;
        PeakPhysicalPercent=$maxPhysical;PeakCommitPercent=$maxCommit;
        MaxPagesInputPerSecond=$maxInput;MaxPagesOutputPerSecond=$maxOutput;
        Meaning='Observation only. Paging input includes mapped files; this is not a frametime or gameplay acceptance test.'}
} finally { $writer.Dispose() }
