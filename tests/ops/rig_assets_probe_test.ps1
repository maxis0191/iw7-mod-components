# Actual argument builders only; no compiler, process, game or assets.
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. "$repo/ops/Base-Client.Core.ps1"
$plan=[pscustomobject]@{OriginalRigConsole=$false;ClientPort=27117;ServerPort=27116;RunPlan=[pscustomobject]@{Picmip=0;Debugger=$false};KeyboardYawDegreesPerSecond=0;KeyboardPitchDegreesPerSecond=0}
$count=0
function Check($value,[string]$message){if(!$value){throw $message};$script:count++}
function Refuses([scriptblock]$Action,[string]$message){$refused=$false;try{& $Action|Out-Null}catch{$refused=$true};Check $refused $message}
Check ((Get-IW7BaseClientArguments $plan 'fixture') -notmatch '-paris-rig-assets-probe') 'Absent probe changed default arguments.'
$plan|Add-Member RigAssetsProbe $false
Check ((Get-IW7BaseClientArguments $plan 'fixture') -notmatch '-paris-rig-assets-probe') 'False probe changed default arguments.'
$plan.RigAssetsProbe=$true
Refuses {Get-IW7BaseClientArguments $plan 'fixture'} 'Probe allowed without the original-rig plan.'
$plan.OriginalRigConsole=$true
$arguments=Get-IW7BaseClientArguments $plan 'fixture'
Check (([regex]::Matches($arguments,'(?:^|\s)-paris-rig-assets-probe(?:\s|$)')).Count -eq 1) 'Explicit probe flag absent/duplicated.'
Check ($arguments -match '(?:^|\s)-wincon(?:\s|$)') 'Owned transport flag lost.'
Check ($arguments -match '-paris-server-client-test' -and $arguments -match '-paris-isolated-lab') 'Private client-test scope lost.'
$plan.RigAssetsProbe='false'
Refuses {Get-IW7BaseClientArguments $plan 'fixture'} 'String probe accepted.'
$plan.RigAssetsProbe=1
Refuses {Get-IW7BaseClientArguments $plan 'fixture'} 'Numeric probe accepted.'
Refuses {New-IW7BaseClientPlan -GameRoot 'unused' -ClientImage 'unused' -ServerPort 27116 -ClientPort 27117 -RigAssetsProbe} 'Plan accepted unpaired probe before filesystem work.'
"$count rig assets probe argument checks passed; native CPP compilation/runtime remain pending."
