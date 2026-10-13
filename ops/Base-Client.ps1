param(
    [ValidateSet('Plan','Run')][string]$Action='Plan',
    [Parameter(Mandatory)][string]$GameRoot,
    [Parameter(Mandatory)][string]$ClientImage,
    [ValidateRange(27100,27999)][int]$ServerPort=27116,
    [ValidateRange(27100,27999)][int]$ClientPort=27117,
    [ValidateSet('Full','Reduced')][string]$GraphicsProfile='Full',
    [switch]$Debugger,
    [string]$ServerIdentityPath,
    [string]$LeaseToken,
    [string]$PasswordFile,
    [string]$OutputRoot,
    [string]$ScenarioPath,
    [ValidateRange(1,600)][int]$Seconds=60,
    [switch]$DryRun
)
$ErrorActionPreference='Stop'
if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'Use PowerShell 7.' }
. "$PSScriptRoot/Base-Client.Core.ps1"
$plan=New-IW7BaseClientPlan -GameRoot $GameRoot -ClientImage $ClientImage -ServerPort $ServerPort -ClientPort $ClientPort -GraphicsProfile $GraphicsProfile -Debugger:$Debugger
if ($Action -eq 'Plan' -or $DryRun) { $plan | ConvertTo-Json -Depth 8; return }
if (!$ServerIdentityPath -or !$LeaseToken -or !$PasswordFile -or !$OutputRoot) { throw 'Run needs existing server identity, complete lease, local password file and fresh output directory.' }
$server=Get-Content -LiteralPath $ServerIdentityPath -Raw | ConvertFrom-Json
$password=(Get-Content -LiteralPath $PasswordFile -Raw).Trim()
$context=$null
try {
    $context=Start-IW7BaseClient -Plan $plan -ServerIdentity $server -LeaseToken $LeaseToken -Password $password -OutputRoot $OutputRoot
    $joinDeadline=[datetime]::UtcNow.AddSeconds(180)
    do {
        $sample=Update-IW7BaseClient $context
        if ($sample.Protected) { break }
        Start-Sleep -Milliseconds 500
    } while ([datetime]::UtcNow -lt $joinDeadline)
    if (!$context.Protected) { throw 'No fresh protected playable client witness.' }
    if ($ScenarioPath) {
        . "$PSScriptRoot/Agent-Scenario.Core.ps1"
        $scenarioResult=Invoke-IW7AgentScenario -Session $context -ScenarioPath $ScenarioPath
    }
    $deadline=[datetime]::UtcNow.AddSeconds($Seconds)
    while ([datetime]::UtcNow -lt $deadline) {
        $sample=Update-IW7BaseClient $context
        $sample | ConvertTo-Json -Compress | Add-Content -LiteralPath (Join-Path $context.OutputRoot 'protection.jsonl')
        Start-Sleep -Milliseconds 500
    }
    if (!$context.Protected) { throw 'Observation ended without protected playable client evidence.' }
} finally {
    if ($context) { Stop-IW7BaseClient $context }
}
[ordered]@{Schema='iw7.base-client/1';Protected=$context.Protected;Restored=$context.Transaction.Restored;OutputRoot=$context.OutputRoot;LeaseReleased=$false} | ConvertTo-Json
