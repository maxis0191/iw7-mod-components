param([string]$TestRoot)
# Queued waits (18 Nov 2026): a queued request is admitted or it times out at its limit; it never fails early. A queued lab build
# came back as SLOT_BUSY after minutes of waiting because 'An unreserved or foreign laboratory is running', 'Heavy job already
# reserved' and 'Existing lab has no reservation' were not in the list of refusals that Invoke-IW7QueuedResourceJob waits for.
# Part 1: every "not now" refusal is waited for, a real error is thrown at once, the limit ends the wait with the last refusal.
# Part 2: N processes ask at once for a reservation that only one can hold; all are admitted, in the order they asked.
# A private registry and a synthetic machine; no game, no compiler.
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../../ops/Resource-Scheduler.Core.ps1"
if (!$TestRoot) { $TestRoot=Join-Path ([IO.Path]::GetTempPath()) ('iw7-queued-tests-'+[guid]::NewGuid().ToString('N')) }
[IO.Directory]::CreateDirectory($TestRoot) | Out-Null
$checks=0
function Assert($Value,[string]$Message) { $script:checks++; if (!$Value) { throw $Message } }

# ---- part 1: in-process, the lease call replaced by a scripted one ----
function Start-Sleep { param([int]$Seconds) $script:slept += $Seconds }   # no real waiting
$messages=@('Resource busy: not enough measured free memory.',
    'Resource admission lock busy; retry later.',
    'Heavy job already reserved, including this worktree.',
    'An unreserved or foreign laboratory is running; wait for its owner to close it.',
    'Existing lab has no reservation; wait for it.',
    'Reserved process identity unavailable; reservation retained.',
    'An existing compiler/extractor/Java analysis is running; wait for it.')
foreach ($m in $messages) {
    $script:calls=0; $script:slept=0; $script:ran=$false
    function Enter-IW7ResourceLease { $script:calls++; if ($script:calls -le 3) { throw $m }; [pscustomobject]@{Token='t'} }
    function Exit-IW7ResourceLease { param($Token) }
    Invoke-IW7QueuedResourceJob -Scope 'x' -Kind Build -WaitForSlotSeconds 600 -Body { $script:ran=$true } | Out-Null
    Assert ($script:ran -and $script:calls -eq 4) "waited for '$m': ran=$($script:ran) calls=$($script:calls)"
}
$script:calls=0
function Enter-IW7ResourceLease { $script:calls++; throw 'Invalid resource lease; admission refused.' }
$thrown=$false; try { Invoke-IW7QueuedResourceJob -Scope 'x' -Kind Build -WaitForSlotSeconds 600 -Body { } } catch { $thrown=$_.Exception.Message -like 'Invalid resource lease*' }
Assert ($thrown -and $script:calls -eq 1) 'a real error is thrown at once, without waiting'
# the limit: always busy, a stopwatch-free check through a tiny limit
function Enter-IW7ResourceLease { throw 'An unreserved or foreign laboratory is running; wait for its owner to close it.' }
$thrown=$false; $t0=Get-Date
function Start-Sleep { param([int]$Seconds) Microsoft.PowerShell.Utility\Start-Sleep -Milliseconds 300 }
try { Invoke-IW7QueuedResourceJob -Scope 'x' -Kind Build -WaitForSlotSeconds 1 -Body { } } catch { $thrown=$_.Exception.Message -like 'An unreserved or foreign laboratory*' }
Assert ($thrown -and ((Get-Date)-$t0).TotalSeconds -ge 1) 'at its limit the wait ends with the last refusal'
Remove-Item Function:\Start-Sleep, Function:\Enter-IW7ResourceLease, Function:\Exit-IW7ResourceLease -ErrorAction SilentlyContinue

# ---- part 2: N processes, one reservation at a time, admitted in the order they asked ----
$registry=Join-Path $TestRoot 'registry'
$child=Join-Path $TestRoot 'child.ps1'
@'
param([string]$Core,[string]$Registry,[string]$Name,[string]$Log)
$ErrorActionPreference='Stop'
. $Core
function Get-IW7ResourceRoot { $Registry }
function Get-IW7ResourceSnapshot { [pscustomobject]@{PhysicalTotal=[long]32GB;PhysicalAvailable=[long]30GB;CommitLimit=96GB;Committed=12GB} }
# The machine's real game clients and compilers are not "foreign labs" of this private registry: they are left out of the process list;
# every other process stays in it, so the waiting callers (the other test children) are seen alive.
$realProcesses=${function:Get-IW7ResourceProcesses}
function Get-IW7ResourceProcesses { @(& $realProcesses | Where-Object { !$_.Heavy -and !$_.Lab -and !$_.BaseClientTest }) }
$scope=Join-Path $Registry ('tree-'+$Name)
Invoke-IW7QueuedResourceJob -Scope $scope -Kind Build -PhysicalBytes 20GB -CommitBytes 20GB -Owner $Name -WaitForSlotSeconds 300 -Body {
    Add-Content -LiteralPath $Log -Value ("{0} start {1}" -f $Name,[datetime]::UtcNow.ToString('o'))
    Start-Sleep -Seconds 3
    Add-Content -LiteralPath $Log -Value ("{0} end {1}" -f $Name,[datetime]::UtcNow.ToString('o'))
} | Out-Null
'@ | Set-Content -LiteralPath $child
$log=Join-Path $TestRoot 'order.log'
$core=(Resolve-Path "$PSScriptRoot/../../ops/Resource-Scheduler.Core.ps1").Path
$n=4; $procs=@()
foreach ($i in 1..$n) {
    $procs += Start-Process pwsh -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-File',$child,'-Core',$core,'-Registry',$registry,'-Name',"b$i",'-Log',$log) -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $TestRoot "b$i.out") -RedirectStandardError (Join-Path $TestRoot "b$i.err")
    Microsoft.PowerShell.Utility\Start-Sleep -Milliseconds 1500    # the order they ask in
}
foreach ($p in $procs) { if (!$p.WaitForExit(240000)) { $procs | ForEach-Object { if (!$_.HasExited) { $_.Kill() } }; throw 'queued builds did not finish in 240 s' } }
Assert (@($procs | Where-Object ExitCode -ne 0).Count -eq 0) "a queued build failed early: exit codes $(($procs | ForEach-Object ExitCode) -join ','); $((Get-ChildItem $TestRoot -Filter *.err | ForEach-Object { (Get-Content $_.FullName -Raw) }) -join ' | ')"
$rows=@(Get-Content -LiteralPath $log | ForEach-Object { $f=$_ -split ' '; [pscustomobject]@{Name=$f[0];Event=$f[1];Time=[datetime]$f[2]} })
$starts=@($rows | Where-Object Event -EQ 'start' | Sort-Object Time)
$ends=@($rows | Where-Object Event -EQ 'end' | Sort-Object Time)
Assert ($starts.Count -eq $n) "all $n admitted: $($starts.Count)"
Assert ((($starts | ForEach-Object Name) -join ',') -ceq ((1..$n | ForEach-Object { "b$_" }) -join ',')) "admitted in the order asked: $(($starts | ForEach-Object Name) -join ',')"
for ($i=1; $i -lt $n; $i++) { Assert ($starts[$i].Time -ge $ends[$i-1].Time) "b$($i+1) started before b$i ended: two held the 20 GB reservation at once" }
Write-Output "PASS queued waits: 7 refusals waited for, a real error thrown at once, the limit honoured; $n queued builds admitted in order ($checks assertions); private registry only."
