$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../../ops/Collision-Probe.Core.ps1')
if(!('IW7LabProcess' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot '../../ops/native/LabProcess.cs')}
foreach($cmd in @('set paris_collision_probe_arm 1','quit')){
    if(![IW7LabProcess]::IsCollisionProbeCommand($cmd)){throw 'Exact collision command refused by compiled transport policy.'}
}
foreach($cmd in @('set paris_collision_probe_arm 0','set sv_cheats 1','set paris_rig_play 1',"quit`nset sv_cheats 1",'Quit')){
    if([IW7LabProcess]::IsCollisionProbeCommand($cmd)){throw 'Foreign command accepted by compiled policy.'}
}
$launch='-dedicated -wincon -paris-server-test -paris-isolated-lab -paris-collision-provider'
if(![IW7LabProcess]::IsCollisionProbeLaunch($launch)){throw 'Exact collision dedicated profile refused.'}
foreach($arg in @(($launch.Replace('-dedicated','')),($launch.Replace('-paris-collision-provider','')),
    ($launch+' -paris-server-client-test'),($launch+' -terminal'),($launch+' -noconsole'))){
    if([IW7LabProcess]::IsCollisionProbeLaunch($arg)){throw 'Unqualified console role accepted.'}
}
$record=[pscustomobject]@{PID=321;Image='C:\private-candidate\iw7-collision.exe';CreationFileTime=123456789L}
$kernel=[pscustomobject]@{PID=$record.PID;Image=$record.Image;CreationFileTime=$record.CreationFileTime}
$handle=[pscustomobject]@{Id=$record.PID;CollisionProbeConsoleEnabled=$true;HasExited=$false;Kernel=$kernel;Calls=[Collections.Generic.List[object]]::new()}
$handle|Add-Member ScriptMethod ReadIdentity {$this.Kernel}
$handle|Add-Member ScriptMethod WriteCollisionProbeCommand {
    param($cmd,$image,$created)
    $this.Calls.Add([pscustomobject]@{Command=$cmd;Image=$image;Created=$created})
    $cmd.Length+1
}
$sent=Send-IW7CollisionProbeCommand $handle $record 'set paris_collision_probe_arm 1'
if($handle.Calls.Count -ne 1 -or $handle.Calls[0].Command -cne 'set paris_collision_probe_arm 1' -or
    $handle.Calls[0].Image -cne $record.Image -or $handle.Calls[0].Created -ne $record.CreationFileTime -or
    $sent.BytesWritten -ne 32 -or $sent.EngineConsumed){throw 'Exact command did not reach the owned transport contract.'}
function Refused([scriptblock]$Call){$before=$handle.Calls.Count;$refused=$false;try{& $Call|Out-Null}catch{$refused=$true};if(!$refused -or $handle.Calls.Count -ne $before){throw 'Foreign target or command reached transport.'}}
Refused {Send-IW7CollisionProbeCommand $handle $record 'set sv_cheats 1'}
$handle.Id=322;Refused {Send-IW7CollisionProbeCommand $handle $record 'quit'};$handle.Id=321
$kernel.PID=322;Refused {Send-IW7CollisionProbeCommand $handle $record 'quit'};$kernel.PID=321
$kernel.CreationFileTime++;Refused {Send-IW7CollisionProbeCommand $handle $record 'quit'};$kernel.CreationFileTime--
$kernel.Image='C:\foreign.exe';Refused {Send-IW7CollisionProbeCommand $handle $record 'quit'};$kernel.Image=$record.Image
$handle.CollisionProbeConsoleEnabled=$false;Refused {Send-IW7CollisionProbeCommand $handle $record 'quit'};$handle.CollisionProbeConsoleEnabled=$true
$handle.HasExited=$true;Refused {Send-IW7CollisionProbeCommand $handle $record 'quit'}
Write-Output 'PASS compiled fixed collision console policy and actual caller-to-mocked-owned-transport dispatch; foreign PID/kernel/creation/image/role/command refused. No Win32 call, console attachment, process, game or lease.'
