# The builder calls BeforeDebugger, its existing debugger helper, then AfterDebugger.
# No runtime packet or blind scheduler copy. Only exact derived overlays are owned.
param([Parameter(Mandatory)][string]$NativeRoot,[Parameter(Mandatory)][string]$Commit,
      [Parameter(Mandatory)][ValidateSet('BeforeDebugger','AfterDebugger')][string]$Phase,
      [switch]$Enabled)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/Checkpoint-Overlay.Core.ps1"
if($Commit -cnotmatch '^[0-9a-f]{40}$'){throw 'Exact native commit required.'}
$pinned=@('77e6d4d24e918ee363b3feee3735c3b889dff7d7','993737428781c4357fe21ecd375300e39a29a654')
# The map-transition successor has the same scheduler, but no enabled-watch qualification.
$disabledSuccessor='cfca45b11ee14641945b9a264a95638387f48a4a'
if($Enabled -and $Commit -cnotin $pinned){throw 'Checkpoint Watch requires the reviewed isolated debugger native pin.'}
$root=[IO.Path]::GetFullPath($NativeRoot)
$path=Join-Path $root 'src/client/component/scheduler.cpp'
foreach($start in @($root,$path)) {
    $cursor=$start
    while($cursor) {
        if((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Redirected scheduler path refused.'}
        $cursor=Split-Path $cursor -Parent
    }
}
$baseText=((git -C $root show ($Commit+':src/client/component/scheduler.cpp')) -join "`n").TrimEnd()+"`n"
if($LASTEXITCODE){throw 'Pinned scheduler source unavailable.'}
$clean=[Text.UTF8Encoding]::new($false,$true).GetBytes($baseText)
# Normal legacy profiles do not need the debugger/checkpoint anchors. They may
# only keep their exact clean scheduler; the existing debugger helper still owns
# removal of a profiler if it is present.
if($Commit -cnotin $pinned -and $Commit -cne $disabledSuccessor) {
    $current=[IO.File]::ReadAllBytes($path)
    if((Get-IW7CapacityCheckpointHash $current) -cne (Get-IW7CapacityCheckpointHash $clean)) {
        throw 'Unreviewed native pin has a scheduler overlay; preserve it.'
    }
    return [pscustomobject]@{Enabled=$false;Phase=$Phase;Commit=$Commit;WrittenSHA256=(Get-IW7CapacityCheckpointHash $current);Ready=$false}
}
$overlays=New-IW7CapacityCheckpointOverlays $clean
if((Get-IW7CapacityCheckpointHash $overlays.Profiler) -cne '263CC05D132DA8D7A01E2D12A2942ED3F137CC8E7B89DDF38B24D3BA3AE23ED7' -or
   (Get-IW7CapacityCheckpointHash $overlays.Watch) -cne 'BCB3E7488E94AA62E9F0352C5C967C881DE1B1022FC43C5ADC797559240C5486') {
    throw 'Reviewed native scheduler transforms differ; preserve source.'
}
$current=[IO.File]::ReadAllBytes($path)
$next=Get-IW7CapacityCheckpointTransition $current $overlays $Phase ([bool]$Enabled)
# Recheck immediately before write. Unknown intervening edits must not be erased.
if((Get-IW7CapacityCheckpointHash ([IO.File]::ReadAllBytes($path))) -cne (Get-IW7CapacityCheckpointHash $current)) {
    throw 'Scheduler changed during overlay preparation; preserve source.'
}
if((Get-IW7CapacityCheckpointHash $next) -cne (Get-IW7CapacityCheckpointHash $current)) {
    [IO.File]::WriteAllBytes($path,$next)
}
$written=Get-IW7CapacityCheckpointHash ([IO.File]::ReadAllBytes($path))
if($written -cne (Get-IW7CapacityCheckpointHash $next)){throw 'Written scheduler bytes differ.'}
[pscustomobject]@{Phase=$Phase;Enabled=[bool]$Enabled;Commit=$Commit;ProfilerSHA256=(Get-IW7CapacityCheckpointHash $overlays.Profiler);
    PinnedCleanSHA256=(Get-IW7CapacityCheckpointHash $clean);WrittenSHA256=$written;Ready=$false}
