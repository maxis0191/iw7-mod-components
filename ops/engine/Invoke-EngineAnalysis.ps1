<#
.SYNOPSIS
Runs one Ghidra step of the engine database (analyze or export) under the scheduler's Analysis reservation.

.DESCRIPTION
The step holds the named resource ghidra:<project> as a long holder (-Long) with its measured memory (analysis
peak 1.3 GB working set, heap capped at -Heap; the export adds one decompiler process per -Threads), so builds,
sessions and other analyses run beside it; only another step on the same project waits. The export resumes
where it stopped; -MaxMinutes bounds one run.

  pwsh -File ops/engine/Invoke-EngineAnalysis.ps1 -Step analyze -WaitForSlotSeconds 3600
  pwsh -File ops/engine/Invoke-EngineAnalysis.ps1 -Step export -MaxMinutes 25 -WaitForSlotSeconds 3600

Paths default to the RE lab layout (docs/ENGINE.md, "Where things are"); override them with the parameters.
#>
param(
    [Parameter(Mandatory)][ValidateSet('analyze','export')][string]$Step,
    [string]$Lab = (Join-Path $env:USERPROFILE 'Documents\IW7-RE-Lab'),
    [string]$Image,
    [string]$Project,
    [string]$Name = 'iw7_ship',
    [string]$Database,
    [string]$Names,
    [string]$Knowledge = (Join-Path $PSScriptRoot 'knowledge\engine-knowledge.json'),
    [string]$Heap = '4g',
    [int]$Threads = 6,
    [int]$MaxMinutes = 25,
    [long]$PhysicalBytes = 4GB,
    [long]$CommitBytes = 6GB,
    [Parameter(Mandatory)][ValidateRange(1,86400)][int]$WaitForSlotSeconds,
    [string[]]$Extra = @()
)
$ErrorActionPreference = 'Stop'
$manifest = Get-Content (Join-Path $Lab 'toolchain-manifest.json') -Raw | ConvertFrom-Json
$ghidra = ($manifest.tools | Where-Object { $_.name -like 'Ghidra *' } | Select-Object -Last 1).installPath
$java = ($manifest.tools | Where-Object { $_.name -like 'Temurin JDK*' } | Select-Object -Last 1).installPath
$venv = ($manifest.tools | Where-Object { $_.name -like 'PyGhidra-MCP*' } | Select-Object -Last 1).installPath
$python = Join-Path $venv 'Scripts\python.exe'
foreach ($p in @($ghidra, $java, $python)) { if (!(Test-Path $p)) { throw "missing tool: $p (see toolchain-manifest.json)" } }
if (!$Image) { $Image = Join-Path $Lab 'engine\image\iw7_ship_live.exe' }
if (!$Project) { $Project = Join-Path $Lab 'engine\ghidra' }
if (!$Database) { $Database = Join-Path $Lab 'engine\iw7-engine.sqlite' }
if (!$Names) { $Names = Join-Path $Lab 'engine\names\names.json' }

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
. (Join-Path $repo 'ops\Resource-Scheduler.Core.ps1')

if ($Step -eq 'analyze') {
    $arguments = @('-I', '-B', (Join-Path $PSScriptRoot 'ghidra_analyze.py'), '--image', $Image, '--project', $Project,
        '--name', $Name, '--ghidra', $ghidra, '--java', $java, '--names', $Names, '--heap', $Heap)
    if (Test-Path $Knowledge) { $arguments += @('--knowledge', $Knowledge) }
} else {
    $arguments = @('-I', '-B', (Join-Path $PSScriptRoot 'ghidra_export.py'), '--project', $Project, '--name', $Name,
        '--program', (Split-Path $Image -Leaf), '--ghidra', $ghidra, '--java', $java, '--db', $Database, '--heap', $Heap,
        '--threads', $Threads, '--max-minutes', $MaxMinutes)
}
$arguments += $Extra
$log = Join-Path $Lab ("engine\logs\{0}-{1:yyyyMMdd-HHmmss}.log" -f $Step, (Get-Date))
New-Item -ItemType Directory -Force (Split-Path $log) | Out-Null
$watch = [Diagnostics.Stopwatch]::StartNew()
Invoke-IW7QueuedResourceJob -Scope $repo -Kind Analysis -PhysicalBytes $PhysicalBytes -CommitBytes $CommitBytes `
    -Resources "ghidra:$Project" -Long -Cores ([math]::Max(1, $Threads)) `
    -Owner "engine database $Step" -WaitForSlotSeconds $WaitForSlotSeconds -Body {
        Write-Host ("slot granted after {0:N0} s; log {1}" -f $watch.Elapsed.TotalSeconds, $log)
        & $python @arguments 2>&1 | Tee-Object -FilePath $log | Where-Object { $_ -match '^\{|^done|Error|Exception|^export' }
        $script:code = $LASTEXITCODE
    }
Write-Host ("{0} finished with exit {1} after {2:N0} s" -f $Step, $script:code, $watch.Elapsed.TotalSeconds)
exit $script:code
