$ErrorActionPreference = 'Stop'
# ops/Stop-OwnProcesses.ps1: stops only processes inside the given worktree; refuses everything else. Real child processes, a temporary folder.
$repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$tool = Join-Path $repo 'ops/Stop-OwnProcesses.ps1'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('stopown-' + [guid]::NewGuid().ToString('N'))
$mine = Join-Path $tmp 'trees\a'; $sibling = Join-Path $tmp 'trees\ab'; $other = Join-Path $tmp 'trees\zzz'
foreach ($d in $mine, $sibling, $other) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
$pwsh = (Get-Process -Id $PID).Path
$started = @()
function Start-Idle([string]$Folder) {
    $script = Join-Path $Folder 'idle.ps1'
    Set-Content -LiteralPath $script -Value 'Start-Sleep -Seconds 300'
    $p = Start-Process $pwsh -ArgumentList @('-NoLogo', '-NoProfile', '-File', "`"$script`"") -PassThru -WindowStyle Hidden
    $script:started += $p; $p
}
function Assert($Value, [string]$Message) { if (!$Value) { throw "stop_own_processes_test: $Message" } }
try {
    $a = Start-Idle $mine; $ab = Start-Idle $sibling; $z = Start-Idle $other
    Start-Sleep -Milliseconds 1500
    # list only: nothing stopped
    $out = & $pwsh -NoLogo -NoProfile -File $tool -Worktree $mine | Out-String
    Assert ($out -match "would stop $($a.Id) " -and $out -notmatch "$($ab.Id) " -and $out -notmatch "$($z.Id) ") "the listing names only the worktree's process: $out"
    Assert (!$a.HasExited -and !$ab.HasExited -and !$z.HasExited) 'listing stopped something'
    # a PID that is not inside the worktree is refused and survives
    $out = & $pwsh -NoLogo -NoProfile -File $tool -Worktree $mine -ProcessId $z.Id -Apply | Out-String
    Assert ($LASTEXITCODE -eq 2 -and $out -match "REFUSED $($z.Id)" -and !$z.HasExited) "a foreign PID was not refused: $out"
    # a worktree whose name only starts like another one does not select it
    $out = & $pwsh -NoLogo -NoProfile -File $tool -Worktree $mine -ProcessId $ab.Id -Apply | Out-String
    Assert ($LASTEXITCODE -eq 2 -and !$ab.HasExited) "a sibling folder with the same prefix was selected: $out"
    # the calling shell and its parents are never stopped, whatever they are
    $out = & $pwsh -NoLogo -NoProfile -File $tool -Worktree $mine -ProcessId $PID -Apply | Out-String
    Assert ($LASTEXITCODE -eq 2 -and $out -match 'REFUSED') 'the caller was not refused'
    # a too short worktree is refused
    $threw = $false; try { & $pwsh -NoLogo -NoProfile -File $tool -Worktree 'C:\' -Apply *> $null; $threw = ($LASTEXITCODE -ne 0) } catch { $threw = $true }
    Assert $threw 'a drive root was accepted as a worktree'
    # its own process, by PID and by worktree, is stopped
    $out = & $pwsh -NoLogo -NoProfile -File $tool -Worktree $mine -ProcessId $a.Id -Apply | Out-String
    Assert ($LASTEXITCODE -eq 0 -and $out -match "stopped $($a.Id) ") "the worktree's own PID was not stopped: $out"
    $a2 = Start-Idle $mine; Start-Sleep -Milliseconds 1500
    $out = & $pwsh -NoLogo -NoProfile -File $tool -Worktree $mine -Apply | Out-String
    $a2.WaitForExit(5000) | Out-Null
    Assert ($a2.HasExited -and !$ab.HasExited -and !$z.HasExited) "stopping by worktree touched another folder's process: $out"
    Write-Output 'PASS stop_own_processes: only processes inside the worktree are stopped; a foreign PID, a same-prefix sibling, the caller and a drive root are refused.'
} finally {
    foreach ($p in $started) { if (!$p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
