$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../../ops/Lab-Evidence.ps1"
$good = '[Paris lab heartbeat] game_time_ms=12000; map=cp_zmb; port=27116; slot=0; tick_ms=100000; protected=1; bound=1; godmode=1; inactivity=0; cheats=0; failed=0'
$null = Assert-IW7LabHeartbeat $good cp_zmb 27116 1 105000
$other = $good.Replace('slot=0','slot=1')
$null = Assert-IW7LabHeartbeat ($good + "`n" + $other) cp_zmb 27116 2 100001
function Reject([string]$log, [long]$now = 100001, [int]$count = 1) {
    $refused = $false
    try { $null = Assert-IW7LabHeartbeat $log cp_zmb 27116 $count $now } catch { $refused = $true }
    if (!$refused) { throw "Invalid heartbeat was accepted: $log" }
}
Reject $good 105001
Reject $good 99999
foreach ($change in @(@('godmode=1','godmode=0'),@('bound=1','bound=0'),@('cheats=0','cheats=1'),
    @('inactivity=0','inactivity=420'),@('protected=1','protected=0'),@('failed=0','failed=1'),
    @('slot=0','slot=4'),@('cp_zmb','cp_rave'),@('27116','27016'))) { Reject $good.Replace($change[0],$change[1]) }
Reject ($good + "`n" + $good) 100001 2
Reject ($good + "`n[Paris test protection failure] slot=0")
Reject ($good + "`nStarting map: cp_zmb")
Reject ("Starting map: cp_rave`n" + $good)
$null = Assert-IW7LabHeartbeat ("[Paris lab protection failure] old run`nStarting map: cp_zmb`n" + $good) cp_zmb 27116 1 100001
$record = [pscustomobject]@{PID=123;Token='test-token'}
$supervisor = [pscustomobject]@{PID=123;Token='test-token';TickMs=100000;Failure=$null}
Assert-IW7LabSupervisor $supervisor $record 110000
foreach ($invalid in @([pscustomobject]@{PID=123;Token='test-token';TickMs=99999;Failure=$null},
    [pscustomobject]@{PID=124;Token='test-token';TickMs=110000;Failure=$null},
    [pscustomobject]@{PID=123;Token='old-token';TickMs=110000;Failure=$null},
    [pscustomobject]@{PID=123;Token='test-token';TickMs=110000;Failure='memory pressure'},
    [pscustomobject]@{PID=123;Token='test-token';TickMs=110001;Failure=$null})) {
    $refused = $false
    try { Assert-IW7LabSupervisor $invalid $record 110000 } catch { $refused = $true }
    if (!$refused) { throw 'Unsafe/reused supervisor heartbeat accepted.' }
}
Write-Output 'PASS: current-map heartbeat, freshness boundaries, all clients, actual protection fields and failure latch.'
