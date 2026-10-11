$ErrorActionPreference='Stop'
$repo=(Resolve-Path "$PSScriptRoot/../..").Path
. "$repo/ops/Agent-Pair.Core.ps1"
. "$repo/ops/voice-agent/Providers.Core.ps1"
Add-Type -Path "$repo/ops/native/LabProcess.cs"
Initialize-IW7AgentPairNtfs
function Check($value,$message){if(!$value){throw $message}}
function Refuses($body){$failed=$false;try{& $body|Out-Null}catch{$failed=$true};Check $failed 'Changed ARM ownership accepted.'}
$process=[Diagnostics.Process]::GetCurrentProcess();$handle=$null;$pin=$null;$child=$null;$childHandle=$null
try {
    $record=[pscustomobject]@{PID=$PID;Image=$process.MainModule.FileName;CreatedUtc=$process.StartTime.ToUniversalTime().ToString('o');SHA256=(Get-FileHash -LiteralPath $process.MainModule.FileName).Hash}
    $handle=[IW7LabProcess]::OpenOwned($record.PID,$record.Image,([datetimeoffset]$record.CreatedUtc).UtcDateTime.ToFileTimeUtc())
    $pin=New-IW7VoiceArmProcessPin $record $handle
    Assert-IW7VoiceArmProcessPin $pin
    Check ($pin.Original.PID -eq $PID -and $pin.Original.Image -ieq $record.Image) 'Original kernel tuple lost.'
    Refuses{[IO.File]::Open($record.Image,'Open','Write','ReadWrite').Dispose()}
    $fileId=$pin.FileId;$pin.FileId='foreign';Refuses{Assert-IW7VoiceArmProcessPin $pin};$pin.FileId=$fileId
    $record.PID++;Refuses{Assert-IW7VoiceArmProcessPin $pin};$record.PID--
    $foreign=$record.PSObject.Copy();$foreign.SHA256='0'*64
    Refuses{New-IW7VoiceArmProcessPin $foreign $handle}
    $start=[Diagnostics.ProcessStartInfo]::new($record.Image);$start.UseShellExecute=$false;$start.CreateNoWindow=$true
    foreach($arg in @('-NoProfile','-Command','Start-Sleep -Milliseconds 250')){$start.ArgumentList.Add($arg)}
    $child=[Diagnostics.Process]::Start($start)
    $childHandle=[IW7LabProcess]::OpenOwned($child.Id,$record.Image,$child.StartTime.ToUniversalTime().ToFileTimeUtc())
    $null=$childHandle.ReadIdentity();Check ($childHandle.WaitForExit(5000)) 'Test child did not exit.'
    Refuses{$childHandle.ReadIdentity()}
    $pin.Image.Dispose();Refuses{Assert-IW7VoiceArmProcessPin $pin}

    # The fast registry boundary still validates current exact registration,
    # scope and complete budgets, without invoking admission or mutating state.
    function Invoke-IW7ResourceLock($Body){& $Body}
    function Read-IW7ResourceState {[pscustomobject]@{Leases=@($script:lease)}}
    $scope=Join-Path ([IO.Path]::GetTempPath()) 'iw7-arm-lease-test'
    $server=[pscustomobject]@{PID=99;Image=(Join-Path $scope 'server.exe');CreatedUtc=$record.CreatedUtc}
    $a=[pscustomobject]@{Identity=$record;LeaseToken='arm-test';PairOwnership=$null}
    $b=[pscustomobject]@{Identity=[pscustomobject]@{PID=22;Image=(Join-Path $scope 'peer.exe');CreatedUtc=$record.CreatedUtc};LeaseToken='arm-test';PairOwnership=$null}
    $base=[pscustomobject]@{Image=$record.Image;GameRoot=(Split-Path $record.Image);RunPlan=[pscustomobject]@{PhysicalBytes=20GB;CommitBytes=20GB}}
    $pair=[pscustomobject]@{Schema='iw7.agent-pair-owned/1';Closed=$false;LeaseToken='arm-test';Server=$server;Sessions=@{A=$a;B=$b};Plan=[pscustomobject]@{Schema='iw7.agent-pair/1';Roles=@([pscustomobject]@{Plan=$base},[pscustomobject]@{});BaseClientImage=$record.Image;ServerRoot=$scope;RunPlan=$base.RunPlan}}
    $a.PairOwnership=$pair;$b.PairOwnership=$pair
    $script:lease=[pscustomobject]@{Token='arm-test';Kind='Runtime';Phase='Running';PhysicalBytes=20GB;CommitBytes=20GB;Scope=$scope;BaseClientImage=$record.Image;Processes=@($server,$record,$b.Identity)}
    $null=Get-IW7VoiceArmLease $pair
    $script:lease.CommitBytes=19GB;Refuses{Get-IW7VoiceArmLease $pair};$script:lease.CommitBytes=20GB
    $script:lease.Token='other';Refuses{Get-IW7VoiceArmLease $pair};$script:lease.Token='arm-test'
    $script:lease.Processes=@($server,$record);Refuses{Get-IW7VoiceArmLease $pair};$script:lease.Processes=@($server,$record,$b.Identity)
    $b.Identity.CreatedUtc=([datetimeoffset]$record.CreatedUtc).AddSeconds(1).ToString('o')
    # Separate the registered tuple from the now changed session tuple.
    $script:lease.Processes[2]=[pscustomobject]@{PID=22;Image=$b.Identity.Image;CreatedUtc=$record.CreatedUtc}
    Refuses{Get-IW7VoiceArmLease $pair}
    'PASS original kernel process identity, immutable image guards, exit refusal and current exact ARM lease. No game/audio.'
} finally {
    if($pin){$pin.Image.Dispose()};if($handle){$handle.Dispose()};$process.Dispose()
    if($childHandle){if(!$childHandle.HasExited){$childHandle.Terminate(1)};$childHandle.Dispose()};if($child){$child.Dispose()}
}
