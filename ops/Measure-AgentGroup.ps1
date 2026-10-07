[CmdletBinding()]
param([Parameter(Mandatory)][string[]]$IdentityPath,[Parameter(Mandatory)][int[]]$LeasePid,
    [Parameter(Mandatory)][string]$OutputPath,[ValidateRange(1,300)][int]$Seconds=300,
    [Parameter(Mandatory)][bool]$PartialStartup)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/Measure-AgentGroup.Core.ps1"
$ids=@($IdentityPath|ForEach-Object{Get-Content -LiteralPath $_ -Raw|ConvertFrom-Json})
Assert-IW7GroupIdentities $ids $LeasePid
if(!$PartialStartup){throw 'This collector attaches to existing processes; PartialStartup must be true. It cannot measure time before attach.'}
if(!( 'IW7GroupMemoryNative' -as [type])){
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class IW7GroupMemoryNative {
 [StructLayout(LayoutKind.Sequential)] public struct Counters {
  public uint cb, PageFaultCount; public UIntPtr PeakWorkingSetSize, WorkingSetSize, QuotaPeakPagedPoolUsage, QuotaPagedPoolUsage, QuotaPeakNonPagedPoolUsage, QuotaNonPagedPoolUsage, PagefileUsage, PeakPagefileUsage, PrivateUsage;
 }
 [DllImport("psapi.dll", SetLastError=true)] public static extern bool GetProcessMemoryInfo(IntPtr h, ref Counters c, uint size);
}
"@
}
$handles=@();$writer=$null;$samples=[Collections.Generic.List[object]]::new()
try{
    foreach($id in $ids){
        $process=[Diagnostics.Process]::GetProcessById([int]$id.PID)
        try{
            $handle=$process.Handle
            if($process.HasExited -or $process.MainModule.FileName -ine $id.Image -or [math]::Abs(($process.StartTime.ToUniversalTime()-([datetimeoffset]$id.CreatedUtc).UtcDateTime).TotalMilliseconds) -gt 1 -or (Get-FileHash -LiteralPath $id.Image).Hash -ine $id.SHA256){throw 'Exact process identity mismatch before attach.'}
            $handles+=@{Identity=$id;Process=$process;Handle=$handle}
        }catch{$process.Dispose();throw}
    }
    $writer=[IO.StreamWriter]::new([IO.File]::Open([IO.Path]::GetFullPath($OutputPath),'CreateNew','Write','Read'),[Text.UTF8Encoding]::new($false))
    $writer.WriteLine((@{Type='start';Schema='iw7.agent-group-memory/1';Utc=[datetime]::UtcNow.ToString('o');PartialStartup=$PartialStartup;LeasePid=$LeasePid;Identities=$ids;Seconds=$Seconds;IntervalMs=1000;AdmissionChanged=$false}|ConvertTo-Json -Depth 8 -Compress));$writer.Flush()
    $start=[Environment]::TickCount64;$next=$start
    while([Environment]::TickCount64-$start -lt $Seconds*1000){
        $rows=@();$sampleTick=[Environment]::TickCount64
        foreach($entry in $handles){
            $row=Read-IW7GroupProcessMemory -ProcessId ([int]$entry.Identity.PID) -HasExited { $entry.Process.HasExited } -ReadCounters {
                $counter=[IW7GroupMemoryNative+Counters]::new();$counter.cb=[Runtime.InteropServices.Marshal]::SizeOf($counter)
                if(![IW7GroupMemoryNative]::GetProcessMemoryInfo($entry.Handle,[ref]$counter,$counter.cb)){throw 'GetProcessMemoryInfo failed.'}
                [pscustomobject]@{WorkingSetBytes=[long]$counter.WorkingSetSize.ToUInt64();PrivateBytes=[long]$counter.PrivateUsage.ToUInt64()}
            }
            $rows+=[pscustomobject]$row
        }
        $sample=New-IW7GroupSample $rows $LeasePid $sampleTick ([datetime]::UtcNow.ToString('o'));$sample|Add-Member CollectionEndTickMs ([Environment]::TickCount64);$sample|Add-Member CollectionSpanMs ($sample.CollectionEndTickMs-$sampleTick);$samples.Add($sample)
        $writer.WriteLine(($sample|ConvertTo-Json -Depth 8 -Compress));$writer.Flush()
        $next+=1000L;$remaining=$next-[Environment]::TickCount64
        if($remaining -gt 0){Start-Sleep -Milliseconds ([int]$remaining)}else{$next=[Environment]::TickCount64}
    }
    $changed=@($ids|Where-Object{!(Test-Path -LiteralPath $_.Image -PathType Leaf) -or (Get-FileHash -LiteralPath $_.Image).Hash -ine $_.SHA256})
    $summary=Get-IW7GroupSummary @($samples) $PartialStartup
    $summary|Add-Member ImageHashesUnchanged ($changed.Count -eq 0)
    $writer.WriteLine(($summary|ConvertTo-Json -Depth 8 -Compress));$writer.Flush();$summary
    if($changed.Count){throw 'Image bytes changed during measurement; retained series is not accepted identity evidence.'}
}finally{if($writer){$writer.Dispose()};foreach($entry in $handles){$entry.Process.Dispose()}}
