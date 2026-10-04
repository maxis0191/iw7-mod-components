$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. "$repo/ops/Lab-AssetProcess.ps1"
$shell = (Get-Process -Id $PID).Path
$scratch = Join-Path $repo ('runtime/lab-asset-process-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
$script:registration = 'normal'
$script:monitor = 'normal'
$script:witness = $null
$script:registeredId = 0

function Assert-True($value, [string]$message) { if (!$value) { throw $message } }
# Inject only scheduler/telemetry dependencies. Native launch, process handles,
# waiting, exit codes and termination are real; no game or asset tool is used.
function Assert-IW7MemoryHeadroom { param($Physical, $Commit) }
function Get-IW7MemorySnapshot {
    if ($script:monitor -eq 'throws') { throw 'Injected telemetry unavailable.' }
    [pscustomobject]@{HighWater=($script:monitor -eq 'high')}
}
function Test-IW7MemoryBudget($Snapshot) { $Snapshot }
function Add-IW7ResourceProcess {
    param([string]$Token, [int]$ProcessId)
    $script:registeredId = $ProcessId
    # This independent test witness is acquired while registration holds the
    # real child alive. The production cleanup never opens a process by PID.
    $script:witness = [Diagnostics.Process]::GetProcessById($ProcessId)
    $null = $script:witness.Handle
    if ($script:registration -eq 'throws') { throw 'Injected resource registration failure.' }
    if ($script:registration -eq 'exit-race') {
        Assert-True ($script:witness.WaitForExit(10000)) 'Fast-exit test shell did not finish.'
        throw 'Child identity unavailable; reservation retained.'
    }
}
function Invoke-TestChild([string]$Code, [string]$Phase, [int]$Timeout = 10) {
    $script:cleanup = [pscustomobject]@{Confirmed=$true}
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Code))
    Invoke-IW7LabAssetProcess -Executable $shell -ToolArguments @('-NoProfile','-NonInteractive','-EncodedCommand',$encoded) `
        -WorkingDirectory $scratch -LogDirectory $scratch -Phase $Phase -LeaseToken 'synthetic-lease' `
        -CleanupState $script:cleanup -TimeoutSeconds $Timeout -PollMilliseconds 100
}
function Close-TestWitness {
    if ($script:witness) {
        try { Assert-True ($script:witness.WaitForExit(1000)) 'Owned child survived the production finally block.' }
        finally { $script:witness.Dispose(); $script:witness=$null }
    }
}

$logs = @()
foreach ($code in @(0,7,259)) {
    try {
        $result = Invoke-TestChild ('Write-Output ''stdout-marker''; [Console]::Error.WriteLine(''stderr-marker''); exit ' + $code) 'fast-exit'
        Assert-True ($result.ExitCode -eq $code) "Actual fast exit $code was not retained."
        Assert-True $script:cleanup.Confirmed 'Fast exit cleanup is unconfirmed.'
        Assert-True ((Get-Content -Raw -LiteralPath $result.Stdout).Contains('stdout-marker')) 'Stdout redirect missing.'
        Assert-True ((Get-Content -Raw -LiteralPath $result.Stderr).Contains('stderr-marker')) 'Stderr redirect missing.'
        $logs += $result.Stdout
    } finally { Close-TestWitness }
}
Assert-True (@($logs | Select-Object -Unique).Count -eq 3) 'Repeated phases reused a log path.'

$script:registration='exit-race'
try {
    $result = Invoke-TestChild 'exit 7' 'registration-race'
    Assert-True ($result.ExitCode -eq 7 -and $script:cleanup.Confirmed) 'Confirmed exit during missing CIM identity was lost.'
} finally { Close-TestWitness; $script:registration='normal' }

foreach ($failure in @('registration','timeout','telemetry','high-water')) {
    $script:registration = if ($failure -eq 'registration') { 'throws' } else { 'normal' }
    $script:monitor = if ($failure -eq 'telemetry') { 'throws' } elseif ($failure -eq 'high-water') { 'high' } else { 'normal' }
    $script:registeredId = 0
    $caught = $null
    $elapsed = [Diagnostics.Stopwatch]::StartNew()
    try {
        try { $null = Invoke-TestChild 'Start-Sleep -Seconds 60; exit 0' $failure 1 }
        catch { $caught = $_.Exception.Message }
        Assert-True ([bool]$caught) "$failure was incorrectly reported as success."
        Assert-True ($script:registeredId -gt 0) "$failure did not exercise a live child after launch."
        Assert-True $script:cleanup.Confirmed "$failure failed to confirm cleanup."
        Assert-True ($elapsed.Elapsed.TotalSeconds -lt 10) "$failure cleanup exceeded its bound."
        Assert-True ($script:witness.WaitForExit(1000)) "$failure orphaned the launched child."
        Assert-True ($script:witness.ExitCode -ne 0) "$failure was reported as a clean child exit."
        if ($failure -eq 'registration') { Assert-True $caught.Contains('Injected resource registration failure') 'Registration failure was masked.' }
        if ($failure -eq 'telemetry') { Assert-True $caught.Contains('Injected telemetry unavailable') 'Telemetry failure was masked.' }
    } finally { Close-TestWitness; $elapsed.Stop() }
}
$script:registration='normal'; $script:monitor='normal'
# A CreateProcess failure creates no child and permits releasing the lease.
$cleanup = [pscustomobject]@{Confirmed=$true}
$caught = $false
try {
    $null = Invoke-IW7LabAssetProcess -Executable "$scratch/missing.exe" -ToolArguments @('unused') -WorkingDirectory $scratch `
        -LogDirectory $scratch -Phase 'launch-failure' -LeaseToken 'synthetic-lease' -CleanupState $cleanup -TimeoutSeconds 1
} catch { $caught=$true }
Assert-True ($caught -and $cleanup.Confirmed) 'Pre-child launch failure incorrectly retained an active child.'
Write-Output "PASS: original launch handles; exits 0/7/259; CIM exit race; registration/timeout/telemetry/high-water cleanup; unique logs. Diagnostics: $scratch"
