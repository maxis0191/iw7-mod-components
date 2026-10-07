# Pure scheduler transforms. Importing this file performs no IO or mutation.
function Get-IW7CapacityCheckpointHash([byte[]]$Bytes) {
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes))
}
function Convert-IW7CapacityCheckpointAnchor([string]$Text,[string]$Old,[string]$New) {
    if(($Text.Split([string[]]@($Old),[StringSplitOptions]::None)).Count -ne 2) {
        throw 'Pinned scheduler anchor changed; preserve the source.'
    }
    $Text.Replace($Old,$New)
}
function New-IW7CapacityCheckpointOverlays([byte[]]$CleanBytes) {
    $encoding=[Text.UTF8Encoding]::new($false,$true)
    $clean=$encoding.GetString($CleanBytes)
    if($clean.Contains("`r") -or !$clean.EndsWith("`n") -or $clean.Contains('IW7_PARIS_CAPACITY_CHECKPOINT_DRAFT')) {
        throw 'Canonical clean scheduler bytes required.'
    }
    $pch='#include <std_include.hpp>'
    $profile=Convert-IW7CapacityCheckpointAnchor $clean $pch ($pch+"`n"+'#include "paris_debugger.hpp"')
    $profile=Convert-IW7CapacityCheckpointAnchor $profile 'utils::hook::invoke<void>(0x140B15E20);' ('paris_debugger::scope paris_server_scope(1);'+"`n`t`t`t"+'utils::hook::invoke<void>(0x140B15E20);')
    $profile=Convert-IW7CapacityCheckpointAnchor $profile 'return utils::hook::invoke<void*>(0x140B8E2D0);' ('paris_debugger::scope paris_main_scope(2);'+"`n`t`t`t"+'return utils::hook::invoke<void*>(0x140B8E2D0);')
    $watch=Convert-IW7CapacityCheckpointAnchor $profile '#include "scheduler.hpp"' ('#include "scheduler.hpp"'+"`n"+'#ifdef IW7_PARIS_CAPACITY_CHECKPOINT_DRAFT'+"`n"+'#include "paris_capacity_watch.hpp"'+"`n"+'#endif')
    $watch=Convert-IW7CapacityCheckpointAnchor $watch 'execute(pipeline::server);' ('execute(pipeline::server);'+"`n"+'#ifdef IW7_PARIS_CAPACITY_CHECKPOINT_DRAFT'+"`n`t`t"+'paris_capacity_watch::checkpoint(1);'+"`n"+'#endif')
    $watch=Convert-IW7CapacityCheckpointAnchor $watch 'execute(pipeline::main);' ('execute(pipeline::main);'+"`n"+'#ifdef IW7_PARIS_CAPACITY_CHECKPOINT_DRAFT'+"`n`t`t`t`t"+'paris_capacity_watch::checkpoint(2);'+"`n"+'#endif')
    $enabled=Convert-IW7CapacityCheckpointAnchor $watch $pch ($pch+"`n"+'#define IW7_PARIS_CAPACITY_CHECKPOINT_DRAFT 1')
    [pscustomobject]@{Clean=$CleanBytes;Profiler=$encoding.GetBytes($profile);Watch=$encoding.GetBytes($watch);Enabled=$encoding.GetBytes($enabled)}
}
function Get-IW7CapacityCheckpointTransition([byte[]]$Current,$Overlays,[string]$Phase,[bool]$Enabled) {
    if($Phase -cnotin @('BeforeDebugger','AfterDebugger')){throw 'Unknown checkpoint overlay phase.'}
    $hash=Get-IW7CapacityCheckpointHash $Current
    $cleanHash=Get-IW7CapacityCheckpointHash $Overlays.Clean
    $profilerHash=Get-IW7CapacityCheckpointHash $Overlays.Profiler
    $watchHash=Get-IW7CapacityCheckpointHash $Overlays.Watch
    $enabledHash=Get-IW7CapacityCheckpointHash $Overlays.Enabled
    if($Phase -ceq 'BeforeDebugger') {
        if($hash -cin @($watchHash,$enabledHash)) {return ,$Overlays.Profiler}
        if($hash -cin @($cleanHash,$profilerHash)) {return ,$Current}
        throw 'Unowned scheduler edit; preserve source.'
    }
    $expected=if($Enabled){$profilerHash}else{$cleanHash}
    if($hash -cne $expected){throw 'Debugger phase did not produce the exact expected scheduler baseline.'}
    if($Enabled){return ,$Overlays.Enabled}
    return ,$Current
}
