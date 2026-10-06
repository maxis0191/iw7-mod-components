param(
    [Parameter(Mandatory)][string]$ReferenceRoot,
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$RetainedReport,
    [ValidateRange(30,300)][int]$TimeoutSeconds=180
)
$ErrorActionPreference='Stop'
if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'Use PowerShell 7.' }
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repo 'ops/Resource-Scheduler.Core.ps1')
$python=(Get-Command python -ErrorAction Stop).Source
$script=Join-Path $PSScriptRoot 'xref_owners.py'
Invoke-IW7ResourceJob -Scope $repo -Kind Analysis -Owner 'Agent capacity bounded RIP xrefs and unwind owners' -PhysicalBytes 4GB -CommitBytes 6GB -Body {
    $start=[Diagnostics.ProcessStartInfo]::new($python)
    $start.UseShellExecute=$false
    $start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true
    $start.RedirectStandardError=$true
    foreach ($argument in @($script,'--reference-root',$ReferenceRoot,'--output',$OutputPath)) { $start.ArgumentList.Add($argument) }
    if ($RetainedReport) { $start.ArgumentList.Add('--retained-report'); $start.ArgumentList.Add((Resolve-Path -LiteralPath $RetainedReport).Path) }
    $process=[Diagnostics.Process]::Start($start)
    try {
        $stdout=$process.StandardOutput.ReadToEndAsync()
        $stderr=$process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit($TimeoutSeconds*1000)) {
            $process.Kill($true)
            $process.WaitForExit()
            throw 'Owned offline analysis exceeded its bound; no game process was touched.'
        }
        $out=$stdout.GetAwaiter().GetResult()
        $err=$stderr.GetAwaiter().GetResult()
        if ($out) { Write-Output $out.TrimEnd() }
        if ($process.ExitCode) { throw "Offline analysis failed ($($process.ExitCode)): $err" }
    } finally { $process.Dispose() }
}
