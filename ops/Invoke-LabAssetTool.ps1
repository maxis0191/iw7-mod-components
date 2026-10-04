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
. "$PSScriptRoot/Resource-Scheduler.Core.ps1"
. "$PSScriptRoot/Lab-AssetProcess.ps1"
$assetLease = Enter-IW7ResourceLease -Scope $work -Kind Extract -PhysicalBytes 6GB -CommitBytes 8GB -Owner ('enemy asset ' + $Phase)
$assetCleanup = [pscustomobject]@{Confirmed=$true}
try {
    $result = Invoke-IW7LabAssetProcess -Executable $tool -ToolArguments $ToolArguments -WorkingDirectory $work `
        -LogDirectory $work -Phase $Phase -LeaseToken $assetLease.Token -CleanupState $assetCleanup -TimeoutSeconds $TimeoutSeconds
    $result | Add-Member NoteProperty ToolSHA256 $ToolSHA256 -PassThru
} finally {
    if ($assetCleanup.Confirmed) { Exit-IW7ResourceLease -Token $assetLease.Token }
    else { Write-Warning 'Asset cleanup is unconfirmed; resource lease retained.' }
}
