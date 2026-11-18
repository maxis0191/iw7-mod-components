param(
    [switch]$Apply,                                  # without it: only report what would go
    [int]$KeepHours = 24,                            # a lab client folder (el-*) younger than this stays
    [int]$KeepNewestPerWorktree = 3,                 # and the newest ones of each worktree stay whatever their age
    [int]$NativeTreeIdleHours = 48,                  # an own native build tree (a worker's NativeRoot) idle this long may go
    [switch]$IncludeOwnNativeTrees,                  # also the per-worker native trees that the pooled trees replace
    [string[]]$Roots = @('C:\w', 'C:\a*', 'C:\iw*', 'C:\c83', 'C:\c', 'C:\dev'),
    [double]$PackageCacheGB = 40
)
# Cleanup of lab client folders (runtime/el-*) and of per-worker native trees, by one rule shared by every agent.
# What is never removed: a folder that a running process names on its command line or that holds a scheduler lease,
# a folder younger than -KeepHours, the newest -KeepNewestPerWorktree of a worktree, and anything with a link to
# another place (junction or symbolic link). A lab client folder is rebuilt from the package cache in seconds
# (Build-Cache.Core.ps1), so removing it loses nothing the cache needs; hard links to cache files are safe to delete.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/Build-Cache.Core.ps1"
$ops = Split-Path $PSScriptRoot -Parent
function Get-ProtectedPaths {
    $paths = [Collections.Generic.List[string]]::new()
    foreach ($p in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
        if ($p.CommandLine) { $paths.Add($p.CommandLine.ToLowerInvariant()) }
        if ($p.ExecutablePath) { $paths.Add($p.ExecutablePath.ToLowerInvariant()) }
    }
    try {
        $st = & pwsh -NoProfile -File (Join-Path $ops 'Resource-Scheduler.ps1') -Action Status | ConvertFrom-Json
        foreach ($l in @($st.Leases)) { if ($l.Scope) { $paths.Add([string]$l.Scope.ToLowerInvariant()) } }
    } catch { Write-Output "cleanup: lease list unavailable ($($_.Exception.Message)); refusing to delete" ; throw }
    $paths
}
$protected = Get-ProtectedPaths
function Test-InUse([string]$Path) {
    $p = $Path.ToLowerInvariant().TrimEnd('\')
    foreach ($x in $protected) { if ($x.Contains($p)) { return $true } }
    $false
}
function Test-HasLink([string]$Path) {
    $null -ne (Get-ChildItem -LiteralPath $Path -Recurse -Force -Attributes ReparsePoint -ErrorAction SilentlyContinue | Select-Object -First 1)
}
$report = [Collections.Generic.List[object]]::new()
$cut = (Get-Date).AddHours(-$KeepHours)
$runtimeDirs = foreach ($r in $Roots) {
    foreach ($base in @(Get-ChildItem -Path $r -Directory -ErrorAction SilentlyContinue)) {
        if ($base.Name -eq 'runtime') { $base.FullName }
        $rt = Join-Path $base.FullName 'runtime'
        if (Test-Path -LiteralPath $rt) { $rt }
    }
    if ((Split-Path $r -Leaf) -ne '*' -and (Test-Path -LiteralPath (Join-Path $r 'runtime'))) { Join-Path $r 'runtime' }
}
foreach ($rt in @($runtimeDirs | Sort-Object -Unique)) {
    $els = @(Get-ChildItem -LiteralPath $rt -Directory -Filter 'el-*' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    $i = 0
    foreach ($d in $els) {
        $i++
        $why = $null
        if ($i -le $KeepNewestPerWorktree) { $why = 'among the newest of its worktree' }
        elseif ($d.LastWriteTime -gt $cut) { $why = "younger than $KeepHours h" }
        elseif (Test-InUse $d.FullName) { $why = 'a process or a lease names it' }
        elseif (Test-HasLink $d.FullName) { $why = 'holds a link to another place' }
        $bytes = (Get-ChildItem -LiteralPath $d.FullName -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
        $report.Add([pscustomobject]@{ Kind = 'lab client folder'; Path = $d.FullName; MB = [int]($bytes / 1MB); Keep = $why })
    }
}
if ($IncludeOwnNativeTrees) {
    $cutN = (Get-Date).AddHours(-$NativeTreeIdleHours)
    foreach ($r in $Roots) {
        foreach ($d in @(Get-ChildItem -Path $r -Directory -ErrorAction SilentlyContinue)) {
            if (!(Test-Path -LiteralPath (Join-Path $d.FullName 'premake5.lua')) -or !(Test-Path -LiteralPath (Join-Path $d.FullName 'build/iw7-mod.sln'))) { continue }
            $newest = (Get-ChildItem -LiteralPath (Join-Path $d.FullName 'build/bin') -Recurse -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
            if (!$newest) { $newest = $d.LastWriteTime }
            $why = $null
            if ($newest -gt $cutN) { $why = "built less than $NativeTreeIdleHours h ago" }
            elseif (Test-InUse $d.FullName) { $why = 'a process or a lease names it' }
            elseif (Test-HasLink $d.FullName) { $why = 'holds a link to another place' }
            $bytes = (Get-ChildItem -LiteralPath $d.FullName -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
            $report.Add([pscustomobject]@{ Kind = 'own native tree'; Path = $d.FullName; MB = [int]($bytes / 1MB); Keep = $why })
        }
    }
}
$go = @($report | Where-Object { !$_.Keep })
$keep = @($report | Where-Object { $_.Keep })
Write-Output ("cleanup: {0} folders seen, {1} kept ({2} MB), {3} removable ({4} MB){5}" -f $report.Count, $keep.Count, [int](($keep | Measure-Object MB -Sum).Sum), $go.Count, [int](($go | Measure-Object MB -Sum).Sum), $(if ($Apply) { '' } else { ' (dry run: add -Apply)' }))
foreach ($g in $go) {
    if ($Apply) {
        try { Remove-Item -LiteralPath $g.Path -Recurse -Force -ErrorAction Stop; Write-Output "removed $($g.Kind) $($g.Path) ($($g.MB) MB)" }
        catch { Write-Output "kept (could not remove: $($_.Exception.Message)) $($g.Path)" }
    } else { Write-Output "would remove $($g.Kind) $($g.Path) ($($g.MB) MB)" }
}
if ($Apply) { Invoke-IW7PackageCachePrune -MaxGB $PackageCacheGB }
