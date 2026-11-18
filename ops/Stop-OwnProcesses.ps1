param(
    [Parameter(Mandatory)][string]$Worktree,        # the folder whose processes are yours: a process is yours when its command line or its executable is inside this folder
    [int[]]$ProcessId = @(),                        # PIDs you recorded at launch; each one must also be inside the Worktree, or it is refused
    [switch]$Apply                                  # without it: list only
)
# Stops only what belongs to one worktree. Never stop a process by a name pattern (18 Nov 2026: a pattern on Invoke-EngineLab, Build-Voice
# and MSBuild may have killed other agents' builds). This tool refuses
#  - a PID that is not inside the worktree (by command line or executable path), whoever launched it;
#  - this process and every process above it;
#  - a worktree that is a drive root or a short path (fewer than three folders), so a typo cannot select the machine;
#  - a path that only starts like the worktree (C:\w\a88 does not select C:\w\a88d).
# With -ProcessId only those PIDs are considered; without, every process inside the worktree is listed (and stopped with -Apply), each
# with its whole process tree below it.
# Exit: 0 done or listed, 2 something was refused (nothing was stopped for a refused PID).
$ErrorActionPreference = 'Stop'
$full = [IO.Path]::GetFullPath($Worktree).TrimEnd('\', '/')
if (($full -split '[\\/]' | Where-Object { $_ }).Count -lt 3) { throw "Worktree '$full' is too short to select processes." }
if (!(Test-Path -LiteralPath $full)) { throw "Worktree '$full' does not exist." }
function Test-Inside([string]$Text) {
    if (!$Text) { return $false }
    $needle = $full.ToLowerInvariant(); $t = $Text.ToLowerInvariant().Replace('/', '\')
    $i = 0
    while (($i = $t.IndexOf($needle, $i, [StringComparison]::Ordinal)) -ge 0) {
        $after = $i + $needle.Length
        if ($after -ge $t.Length -or $t[$after] -in '\', '"', "'", ' ', ';', ',') { return $true }
        $i = $after
    }
    $false
}
$all = @(Get-CimInstance Win32_Process)
$byPid = @{}; foreach ($p in $all) { $byPid[[int]$p.ProcessId] = $p }
$protected = @{}; $cursor = $PID
while ($cursor -and $byPid.ContainsKey($cursor) -and !$protected.ContainsKey($cursor)) { $protected[$cursor] = $true; $cursor = [int]$byPid[$cursor].ParentProcessId }
$inside = @($all | Where-Object { (Test-Inside $_.CommandLine) -or (Test-Inside $_.ExecutablePath) })
$refused = @()
if ($ProcessId.Count) {
    $targets = @()
    foreach ($id in $ProcessId) {
        $p = $byPid[[int]$id]
        if (!$p) { Write-Output "gone: $id"; continue }
        if ($protected.ContainsKey([int]$id)) { Write-Output "REFUSED $id ($($p.Name)): this process or one above it"; $refused += $id; continue }
        if (!(Test-Inside $p.CommandLine) -and !(Test-Inside $p.ExecutablePath)) { Write-Output "REFUSED $id ($($p.Name)): not inside $full"; $refused += $id; continue }
        $targets += $p
    }
} else { $targets = @($inside | Where-Object { !$protected.ContainsKey([int]$_.ProcessId) }) }
# the tree below each target, children first
function Get-Tree($Root) {
    $out = [Collections.Generic.List[object]]::new()
    $stack = [Collections.Stack]::new(); $stack.Push($Root); $seen = @{}
    while ($stack.Count) {
        $n = $stack.Pop(); if ($seen.ContainsKey([int]$n.ProcessId)) { continue }; $seen[[int]$n.ProcessId] = 1; $out.Add($n)
        foreach ($c in $all) { if ([int]$c.ParentProcessId -eq [int]$n.ProcessId -and $c.CreationDate -ge $n.CreationDate -and !$protected.ContainsKey([int]$c.ProcessId)) { $stack.Push($c) } }
    }
    $out.Reverse(); $out
}
$list = @(); foreach ($t in $targets) { foreach ($n in (Get-Tree $t)) { if ($n.ProcessId -notin ($list | ForEach-Object ProcessId)) { $list += $n } } }
foreach ($n in $list) {
    if ($Apply) {
        try { Stop-Process -Id $n.ProcessId -Force -ErrorAction Stop; Write-Output "stopped $($n.ProcessId) $($n.Name)" } catch { Write-Output "could not stop $($n.ProcessId) $($n.Name): $($_.Exception.Message)" }
    } else { Write-Output "would stop $($n.ProcessId) $($n.Name)" }
}
if (!$list.Count -and !$refused.Count) { Write-Output "nothing inside $full" }
if ($refused.Count) { exit 2 }
exit 0
