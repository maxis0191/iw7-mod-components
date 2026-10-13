$ErrorActionPreference='Stop'
. "$PSScriptRoot/../../ops/Measure-AgentGroup.Core.ps1"
function Check($v,$message){if(!$v){throw $message}}
function Refuses($action){$refused=$false;try{&$action|Out-Null}catch{$refused=$true};Check $refused 'Invalid group accepted.'}
$ids=@([pscustomobject]@{PID=1;Image='C:\lab\server.exe';CreatedUtc='2026-10-07T00:00:00Z';SHA256=('a'*64)},[pscustomobject]@{PID=2;Image='C:\lab\client.exe';CreatedUtc='2026-10-07T00:00:00Z';SHA256=('b'*64)})
Assert-IW7GroupIdentities $ids @(1,2)
Refuses{Assert-IW7GroupIdentities $ids @(1)}
Refuses{Assert-IW7GroupIdentities @($ids[0],$ids[0]) @(1,2)}
function Row($p,$r,$c,$valid=$true){[pscustomobject]@{PID=$p;Valid=$valid;WorkingSetBytes=$r;PrivateBytes=$c}}
$a=New-IW7GroupSample @((Row 1 100 50),(Row 2 20 10)) @(1,2) 1 'a'
$b=New-IW7GroupSample @((Row 1 10 5),(Row 2 200 90)) @(1,2) 2 'b'
$gap=New-IW7GroupSample @((Row 1 999 999),(Row 2 0 0 $false)) @(1,2) 3 'c'
$summary=Get-IW7GroupSummary @($a,$b,$gap) $true
Check ($summary.SampledPeakGroupWorkingSetBytes -eq 210 -and $summary.SampledPeakGroupPrivateBytes -eq 95) 'Individual lifetime peaks were added or incomplete sum accepted.'
Check ($summary.GapSamples -eq 1 -and $summary.PartialStartup -and $null -eq $gap.WorkingSetBytes) 'Gap/startup limits concealed.'
Refuses{New-IW7GroupSample @((Row 1 1 1),(Row 3 1 1)) @(1,2) 1 'a'}
Refuses{New-IW7GroupSample @((Row 1 1 1),(Row 1 1 1)) @(1,2) 1 'a'}
$empty=Get-IW7GroupSummary @($gap) $false
Check ($null -eq $empty.SampledPeakGroupWorkingSetBytes -and $empty.CompleteSamples -eq 0) 'No valid samples falsely measured peak.'
foreach($bad in @($null,'100',[double]::NaN,[double]::PositiveInfinity,1.5,$true,-1,[uint64]::MaxValue)){
    Refuses{New-IW7GroupSample @((Row 1 $bad 10),(Row 2 10 10)) @(1,2) 1 'a'}
    Refuses{New-IW7GroupSample @((Row 1 10 $bad),(Row 2 10 10)) @(1,2) 1 'a'}
}
Refuses{New-IW7GroupSample @((Row 1 ([long]::MaxValue) 10),(Row 2 1 10)) @(1,2) 1 'a'}
$script:exited=$false;$script:reads=0
$race=Read-IW7GroupProcessMemory -ProcessId 1 -HasExited {$script:exited} -ReadCounters {
    $script:reads++;$script:exited=$true
    [pscustomobject]@{WorkingSetBytes=999;PrivateBytes=999}
}
Check (!$race.Valid -and $null -eq $race.WorkingSetBytes -and $null -eq $race.PrivateBytes -and $script:reads -eq 1 -and $race.Gap -match 'during') 'Successful counters from a concurrent exit were accepted.'
$raceGroup=New-IW7GroupSample @($race,(Row 2 10 10)) @(1,2) 4 'd'
Check (!$raceGroup.Complete -and $null -eq $raceGroup.WorkingSetBytes) 'Concurrent exit retained a group sum.'
$before=Read-IW7GroupProcessMemory -ProcessId 1 -HasExited {$true} -ReadCounters {throw 'Should not query an exited member.'}
Check (!$before.Valid -and $before.Gap -match 'before') 'Exit before read was queried.'
$alive=Read-IW7GroupProcessMemory -ProcessId 1 -HasExited {$false} -ReadCounters {[pscustomobject]@{WorkingSetBytes=12L;PrivateBytes=8L}}
Check ($alive.Valid -and $alive.WorkingSetBytes -eq 12 -and $alive.PrivateBytes -eq 8) 'Live counters rejected.'

$wrapper=[IO.File]::ReadAllText("$PSScriptRoot/../../ops/Measure-AgentGroup.ps1")
if($wrapper -notmatch '(?s)Add-Type -TypeDefinition @"\r?\n(.*?)\r?\n"@'){throw 'Memory ABI declaration missing.'}
if(!( 'IW7GroupMemoryNative' -as [type])){Add-Type -TypeDefinition $Matches[1]}
$abi=[IW7GroupMemoryNative+Counters]::new()
Check ([Runtime.InteropServices.Marshal]::SizeOf($abi) -eq (8+9*[IntPtr]::Size)) 'PROCESS_MEMORY_COUNTERS_EX layout incorrect.'
'PASS group memory pure lease membership, simultaneous sums, gaps and peak limits. No process attached.'
