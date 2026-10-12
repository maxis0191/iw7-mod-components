# Pure lifecycle policies for this harness. No imports, native types or leases.
# Reuses the AppDomain quarantine pattern from Recipient/AnimationFF and the
# observation-before-decision deadline policy of the reviewed GSC audit archive.
function Get-DownloadMonotonicMs { [Environment]::TickCount64 }
function Assert-DownloadDeadline($Timing) {
    $now=Get-DownloadMonotonicMs
    if($now-$Timing.StartedMs -ge 180000){throw 'Original-job global deadline reached.'}
    if($null -ne $Timing.RootExitObservedMs -and $now-$Timing.RootExitObservedMs -ge 2000){throw 'Original-job drain deadline reached.'}
}
function Observe-DownloadCompletion($Owner,$Timing,[scriptblock]$Measure,[scriptblock]$Capture) {
    & $Capture | Out-Null
    & $Measure | Out-Null
    Assert-DownloadDeadline $Timing
    # Timestamp BEFORE getters, never grant a fresh drain after slow observation.
    $beforeRoot=Get-DownloadMonotonicMs
    $rootExited=$Owner.RootExited()
    if($rootExited -and $null -eq $Timing.RootExitObservedMs){$Timing.RootExitObservedMs=$beforeRoot}
    Assert-DownloadDeadline $Timing
    $treeExited=$Owner.TreeExited()
    Assert-DownloadDeadline $Timing # Late zero-active is still late.
    $treeExited
}
function Register-DownloadOwner($Owner,$Timing,[scriptblock]$Register) {
    Assert-DownloadDeadline $Timing
    $began=Get-DownloadMonotonicMs
    & $Register $Owner | Out-Null
    if((Get-DownloadMonotonicMs)-$began -ge 5000){throw 'Original-job registration deadline reached.'}
    Assert-DownloadDeadline $Timing
}
function Preserve-DownloadQuarantine([string]$Token,$Owner,$Guards,$State) {
    if(!$Token){throw 'Quarantine token is required.'}
    $key='IW7.CommunityDownload.Quarantine.'+$Token
    if($null -ne [AppDomain]::CurrentDomain.GetData($key)){throw 'Existing quarantine must not be overwritten.'}
    $State.QuarantineKey=$key
    $State.Quarantined=$true
    # These strong references outlive the script scope. Never auto-clear or dispose.
    [AppDomain]::CurrentDomain.SetData($key,@{Owner=$Owner;Guards=$Guards;State=$State})
    $key
}
function Complete-DownloadOwnership($Owner,$Guards,$State,$Lease,[scriptblock]$Release) {
    $State.LeaseReleased=$false;$State.OriginalJobClosed=$false;$State.ReadGuardsReleased=$false
    if($Owner){
        if(!$Owner.Closed){
            $State.ForcedStop=$true;$started=Get-DownloadMonotonicMs
            try {
                $Owner.StopAndConfirm(5000)
                if((Get-DownloadMonotonicMs)-$started -ge 5000){throw 'Original-job cleanup deadline reached.'}
            } catch {$State.ClosureError=$_.Exception.Message}
        }
        $State.OriginalJobClosed=$Owner.Closed -and !$State.Contains('ClosureError')
    } else {$State.OriginalJobClosed=$true;$State.NoJobStarted=$true}
    $State.OwnerReportsClosed=if($Owner){$Owner.Closed}else{$true}
    if(!$State.OriginalJobClosed){
        $State.Status='Failed';$State.Passed=$false
        $State.LeaseRetainedReason='Exact original owner/closure unresolved; owner and guards retained in this host.'
        $null=Preserve-DownloadQuarantine $Lease.Token $Owner $Guards $State
        return
    }
    if($Lease){
        try {& $Release $Lease.Token | Out-Null;$State.LeaseReleased=$true}
        catch {$State.Status='Failed';$State.Passed=$false;$State.LeaseReleaseError=$_.Exception.Message}
    }
    foreach($guard in $Guards){$guard.Dispose()}
    $State.ReadGuardsReleased=$true
}
function New-DownloadReceiptReserve([string]$Output) {
    $path=Join-Path $Output 'run-receipt.reserve'
    $stream=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read)
    try {$stream.Write([byte[]]::new(1MB),0,1MB);$stream.Flush($true)} catch {$stream.Dispose();throw}
    [pscustomobject]@{Path=$path;Stream=$stream;Capacity=1MB}
}
function Publish-DownloadReceipt($State,$Reserve,[scriptblock]$Measure) {
    # Reserve was physically allocated BEFORE launch. Oversized payload is retained;
    # it makes the result fail, but never suppresses a bounded failure receipt.
    try {
        $bytes=[long](& $Measure)
        $State.ArtifactPayloadBytes=$bytes
        if($bytes -gt 31MB){$State.ArtifactBudgetExceeded=$true;$State.Status='Failed';$State.Passed=$false}
    } catch {$State.OutputMeasureError=$_.Exception.Message;$State.Status='Failed';$State.Passed=$false}
    $serialized=[Text.Encoding]::UTF8.GetBytes(($State | ConvertTo-Json -Depth 12))
    if($serialized.Length -gt $Reserve.Capacity){
        $State.Status='Failed';$State.Passed=$false;$State.ReceiptTruncated=$true
        $compact=[ordered]@{Schema='iw7.community-download-admitted-run/1';Status='Failed';Passed=$false;
            ReceiptTruncated=$true;Reason='Detailed metadata exceeded reserved capacity';
            OriginalJobClosed=[bool]$State.OriginalJobClosed;LeaseReleased=[bool]$State.LeaseReleased;
            Quarantined=[bool]$State.Quarantined;WorkerPID=$State.WorkerPID;WorkerCreationFileTime=$State.WorkerCreationFileTime;
            LeaseToken=$State.LeaseToken;QuarantineKey=$State.QuarantineKey}
        $serialized=[Text.Encoding]::UTF8.GetBytes(($compact | ConvertTo-Json -Depth 4))
    }
    if($serialized.Length -gt $Reserve.Capacity){throw 'Even compact receipt exceeds reserve.'}
    try {
        $Reserve.Stream.Position=0;$Reserve.Stream.Write($serialized,0,$serialized.Length)
        $Reserve.Stream.SetLength($serialized.Length);$Reserve.Stream.Flush($true)
    } finally {$Reserve.Stream.Dispose()}
    $final=Join-Path (Split-Path $Reserve.Path -Parent) 'run-receipt.json'
    [IO.File]::Move($Reserve.Path,$final)
    $final
}
