param(
    [Parameter(Mandatory=$true)][string]$WorkingDirectory,
    [Parameter(Mandatory=$true)][string]$ToolSHA256,
    [Parameter(Mandatory=$true)][string[]]$ToolArguments,
    [Parameter(Mandatory=$true)][ValidatePattern('^[a-z0-9_-]+$')][string]$Phase,
    [ValidateRange(10,600)][int]$TimeoutSeconds = 240
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$runtime = [IO.Path]::GetFullPath((Join-Path $repo 'runtime'))
$work = (Resolve-Path -LiteralPath $WorkingDirectory).Path
if (!$work.StartsWith($runtime + '\',[StringComparison]::OrdinalIgnoreCase) -or
    ((Get-Item -LiteralPath $work).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Asset tool requires a real work directory inside this worktree runtime.' }
$ancestor = Get-Item -LiteralPath $work
while ($ancestor -and ($ancestor.FullName -eq $runtime -or $ancestor.FullName.StartsWith($runtime + '\',[StringComparison]::OrdinalIgnoreCase))) {
    if ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Asset-tool runtime ancestors may not be links.' }
    $ancestor = $ancestor.Parent
}
$tool = Join-Path $work 'zonetool.exe'
if (((Get-Item -LiteralPath $tool).Attributes -band [IO.FileAttributes]::ReparsePoint) -or
    $ToolSHA256 -notmatch '^[A-Fa-f0-9]{64}$' -or (Get-FileHash -LiteralPath $tool).Hash -ne $ToolSHA256) { throw 'Asset tool checksum/link mismatch.' }
. "$PSScriptRoot/Memory-Budget.ps1"
Assert-IW7MemoryHeadroom 2GB 2GB | Out-Null
$quotedArguments = foreach ($argument in $ToolArguments) {
    # These offline commands need only simple tokens/paths. Refuse quoting or
    # control characters rather than constructing an ambiguous command line.
    if (!$argument -or $argument -match '["\x00-\x1f]' -or $argument.EndsWith('\')) { throw 'Unsupported asset-tool argument.' }
    '"' + $argument + '"'
}
$process = Start-Process -FilePath $tool -WorkingDirectory $work -ArgumentList $quotedArguments -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput "$work/$Phase.stdout.log" -RedirectStandardError "$work/$Phase.stderr.log"
$identity = Get-CimInstance Win32_Process -Filter "ProcessId=$($process.Id)"
if (!$identity -and !$process.HasExited) { throw 'Asset-tool identity unavailable; inspect its diagnostics.' }
$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
try {
    while (!$process.WaitForExit(2000)) {
        $budget = Test-IW7MemoryBudget (Get-IW7MemorySnapshot)
        if ($budget.HighWater -or [DateTime]::UtcNow -ge $deadline) { throw 'Asset tool exceeded memory/time budget.' }
    }
    [pscustomobject]@{Phase=$Phase;ExitCode=$process.ExitCode;ToolSHA256=$ToolSHA256;Stdout="$work/$Phase.stdout.log";Stderr="$work/$Phase.stderr.log"}
} finally {
    if (!$process.HasExited) {
        $live = Get-CimInstance Win32_Process -Filter "ProcessId=$($process.Id)"
        if ($identity -and $live -and $live.ExecutablePath -eq $tool -and $live.CreationDate -eq $identity.CreationDate -and
            $live.CommandLine -eq $identity.CommandLine -and (Get-FileHash -LiteralPath $live.ExecutablePath).Hash -eq $ToolSHA256) {
            $process.Kill(); $process.WaitForExit()
        } else { Write-Warning 'Asset-tool identity changed; foreign process preserved.' }
    }
}
