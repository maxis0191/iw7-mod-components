$ErrorActionPreference='Stop'
. "$PSScriptRoot/../../ops/agent-capacity/Checkpoint-Overlay.Core.ps1"
$encoding=[Text.UTF8Encoding]::new($false)
$checks=0
function Assert([bool]$Condition,[string]$Message) {
    if(!$Condition){throw $Message};$script:checks++
}
function Same([byte[]]$A,[byte[]]$B){(Get-IW7CapacityCheckpointHash $A) -ceq (Get-IW7CapacityCheckpointHash $B)}
function Refuses([scriptblock]$Action,[string]$Message){$refused=$false;try{& $Action|Out-Null}catch{$refused=$true};Assert $refused $Message}
$source=@'
#include <std_include.hpp>
#include "scheduler.hpp"
void server() {
    utils::hook::invoke<void>(0x140B15E20);
    execute(pipeline::server);
}
void main() {
    execute(pipeline::main);
    return utils::hook::invoke<void*>(0x140B8E2D0);
}
'@+"`n"
$source=$source.Replace("`r`n","`n")
$clean=$encoding.GetBytes($source)
$o=New-IW7CapacityCheckpointOverlays $clean
Assert (Same $o.Clean $clean) 'Clean bytes changed.'
$enabled=$encoding.GetString($o.Enabled)
Assert ($enabled.StartsWith('#include <std_include.hpp>'+"`n"+'#define IW7_PARIS_CAPACITY_CHECKPOINT_DRAFT 1')) 'Watch macro must follow the PCH.'
Assert ($enabled.Contains('execute(pipeline::server);'+"`n"+'#ifdef IW7_PARIS_CAPACITY_CHECKPOINT_DRAFT'+"`n`t`t"+'paris_capacity_watch::checkpoint(1);')) 'Server checkpoint must follow execute.'
Assert ($enabled.Contains('execute(pipeline::main);'+"`n"+'#ifdef IW7_PARIS_CAPACITY_CHECKPOINT_DRAFT'+"`n`t`t`t`t"+'paris_capacity_watch::checkpoint(2);')) 'Main checkpoint must follow execute.'
foreach($current in @($o.Watch,$o.Enabled)) {
    Assert (Same (Get-IW7CapacityCheckpointTransition $current $o BeforeDebugger $true) $o.Profiler) 'Owned watch reversal differs.'
}
foreach($current in @($o.Clean,$o.Profiler)) {
    Assert (Same (Get-IW7CapacityCheckpointTransition $current $o BeforeDebugger $false) $current) 'Before debugger should preserve the exact baseline.'
}
Assert (Same (Get-IW7CapacityCheckpointTransition $o.Profiler $o AfterDebugger $true) $o.Enabled) 'Enabled phase differs.'
Assert (Same (Get-IW7CapacityCheckpointTransition $o.Clean $o AfterDebugger $false) $o.Clean) 'Ordinary build changed.'
foreach($text in @($source.Replace("`n","`r`n"),$source.Substring(0,$source.Length-1),$source.Replace("`n","`r`n").TrimEnd("`r","`n"))) {
    Assert (Same (Get-IW7CapacityCheckpointTransition ($encoding.GetBytes($text)) $o BeforeDebugger $true) $o.Clean) 'Exact Windows baseline newline form refused.'
}
foreach($text in @($source+"`n",$source.Replace('void main()', 'void  main()'),$source.Replace("`n","`r"))) {
    Refuses {Get-IW7CapacityCheckpointTransition ($encoding.GetBytes($text)) $o BeforeDebugger $true} 'Unknown whitespace/source/newline edit accepted.'
}
Assert (!$encoding.GetString((Get-IW7CapacityCheckpointTransition $o.Clean $o AfterDebugger $false)).Contains('IW7_PARIS_CAPACITY_CHECKPOINT_DRAFT')) 'Ordinary build kept a watch macro.'
Refuses {Get-IW7CapacityCheckpointTransition $o.Profiler $o AfterDebugger $false} 'Disabled phase accepted debugger bytes.'
Refuses {Get-IW7CapacityCheckpointTransition $o.Clean $o AfterDebugger $true} 'Enabled phase accepted clean bytes.'
$unowned=$encoding.GetBytes($source+'unowned edit')
$hash=Get-IW7CapacityCheckpointHash $unowned
foreach($phase in @('BeforeDebugger','AfterDebugger')) {
    Refuses {Get-IW7CapacityCheckpointTransition $unowned $o $phase $true} 'Unknown scheduler bytes accepted.'
    Assert ((Get-IW7CapacityCheckpointHash $unowned) -ceq $hash) 'Refusal mutated unknown bytes.'
}
Refuses {New-IW7CapacityCheckpointOverlays ($encoding.GetBytes($source.Replace('execute(pipeline::server);','other();')))} 'Missing checkpoint anchor accepted.'
Refuses {New-IW7CapacityCheckpointOverlays ($encoding.GetBytes($source.Replace('execute(pipeline::main);','execute(pipeline::main); execute(pipeline::main);')))} 'Duplicate checkpoint anchor accepted.'
Refuses {New-IW7CapacityCheckpointOverlays ($encoding.GetBytes($source.Replace("`n","`r`n")))} 'Noncanonical bytes accepted.'
Write-Output "PASS $checks capacity checkpoint overlay checks; pure transforms only, no native checkout touched."
