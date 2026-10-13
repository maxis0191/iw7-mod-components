param([Parameter(Mandatory)][string]$ReferenceRoot)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$ReferenceRoot = (Resolve-Path -LiteralPath $ReferenceRoot).Path
$ghidraRoot = Join-Path $repo 'tools/ghidra'
$analysisRoot = Join-Path $repo ('runtime/voice-analysis-' + (Get-Date -Format yyyyMMdd-HHmmss-fff))
New-Item -ItemType Directory -Path $analysisRoot -Force | Out-Null
# Ghidra rejects project paths containing any dot-prefixed element, including
# managed .codex worktrees. Keep its project in a separate local scratch folder.
$projectRoot = Join-Path $env:LOCALAPPDATA ('IW7-VoiceAnalysis/' + (Split-Path $analysisRoot -Leaf))
New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null
$inputs = @('unpacked-text.bin','unpacked-rdata.bin','unpacked-pdata.bin')
$hashes = foreach ($name in $inputs) {
    $path = Join-Path $ReferenceRoot $name
    if (!(Test-Path -LiteralPath $path)) { throw "Missing local reference: $name" }
    [pscustomobject]@{Name=$name;SHA256=(Get-FileHash -LiteralPath $path).Hash}
}
$hashes | ConvertTo-Json | Set-Content (Join-Path $analysisRoot 'reference-hashes.json')
$previousJava = $env:JAVA_HOME
try {
    $env:JAVA_HOME = Join-Path $ghidraRoot 'jdk-21.0.12.1+1'
    . "$PSScriptRoot/Resource-Scheduler.Core.ps1"
    Invoke-IW7ResourceJob -Scope $repo -Kind Analysis -Owner 'Selected Ghidra functions' -PhysicalBytes 4GB -CommitBytes 6GB -Body {
    & (Join-Path $ghidraRoot 'ghidra_12.1.4_PUBLIC/support/analyzeHeadless.bat') $projectRoot voice `
        -import (Join-Path $ReferenceRoot 'unpacked-text.bin') -loader BinaryLoader `
        -loader-baseAddr 140001000 -processor x86:LE:64:default -cspec windows -noanalysis `
        -scriptPath (Join-Path $PSScriptRoot 'ghidra') -postScript DecompileSelected.java `
        (Join-Path $ReferenceRoot 'unpacked-rdata.bin') 141435000 `
        (Join-Path $ReferenceRoot 'unpacked-pdata.bin') (Join-Path $PSScriptRoot 'ghidra/voice-functions.csv') `
        (Join-Path $analysisRoot 'selected-functions.c') -log (Join-Path $analysisRoot 'headless.log')
    if ($LASTEXITCODE -or !(Test-Path -LiteralPath (Join-Path $analysisRoot 'selected-functions.c'))) {
        throw 'Selected-function analysis failed. Preserve the local log and inspect diagnostics.'
    }
    }
    Write-Output "Local analysis complete: $analysisRoot. Game-derived output stays ignored and must not be redistributed."
} finally { $env:JAVA_HOME = $previousJava }
