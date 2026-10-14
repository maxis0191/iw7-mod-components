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
$plan.RigAssetsProbe=$true
Check ((Get-IW7BaseClientArguments $plan 'fixture') -notmatch '-paris-rig-scene-probe') 'Absent scene probe changed default arguments.'
$plan|Add-Member RigSceneProbe $false
Check ((Get-IW7BaseClientArguments $plan 'fixture') -notmatch '-paris-rig-scene-probe') 'False scene probe changed default arguments.'
$plan.RigSceneProbe=$true
$arguments=Get-IW7BaseClientArguments $plan 'fixture'
Check (([regex]::Matches($arguments,'(?:^|\s)-paris-rig-scene-probe(?:\s|$)')).Count -eq 1) 'Explicit scene flag absent/duplicated.'
Check ($arguments -match '-paris-rig-assets-probe' -and $arguments -match '-wincon') 'Scene dependencies lost.'
$plan.RigAssetsProbe=$false
Refuses {Get-IW7BaseClientArguments $plan 'fixture'} 'Scene allowed without assets probe.'
$plan.RigAssetsProbe=$true
$plan.RigSceneProbe='false'
Refuses {Get-IW7BaseClientArguments $plan 'fixture'} 'String scene probe accepted.'
$plan.RigSceneProbe=1
Refuses {Get-IW7BaseClientArguments $plan 'fixture'} 'Numeric scene probe accepted.'
$plan.RigSceneProbe=@($true)
Refuses {Get-IW7BaseClientArguments $plan 'fixture'} 'Array scene probe accepted.'
Refuses {New-IW7BaseClientPlan -GameRoot 'unused' -ClientImage 'unused' -ServerPort 27116 -ClientPort 27117 -OriginalRigConsole -RigSceneProbe} 'Plan accepted unpaired scene before filesystem work.'
$plan.RigSceneProbe=$true
Check ((Get-IW7BaseClientArguments $plan 'fixture') -notmatch '-paris-rig-scene-stock-witness') 'Absent witness changed default arguments.'
$plan|Add-Member RigSceneStockWitness $false
Check ((Get-IW7BaseClientArguments $plan 'fixture') -notmatch '-paris-rig-scene-stock-witness') 'False witness changed default arguments.'
$plan.RigSceneStockWitness=$true
$arguments=Get-IW7BaseClientArguments $plan 'fixture'
Check (([regex]::Matches($arguments,'(?:^|\s)-paris-rig-scene-stock-witness(?:\s|$)')).Count -eq 1) 'Explicit witness flag absent/duplicated.'
Check ($arguments -match '-paris-rig-scene-probe' -and $arguments -match '-paris-rig-assets-probe') 'Witness dependencies lost.'
$plan.RigSceneProbe=$false
Refuses {Get-IW7BaseClientArguments $plan 'fixture'} 'Witness allowed without scene.'
$plan.RigSceneProbe=$true
$plan.OriginalRigConsole=$false
Refuses {Get-IW7BaseClientArguments $plan 'fixture'} 'Witness allowed without original-rig plan.'
$plan.OriginalRigConsole=$true
foreach($wrong in @('false',1,@($true))){
    $plan.RigSceneStockWitness=$wrong
    Refuses {Get-IW7BaseClientArguments $plan 'fixture'} 'Non-boolean witness accepted.'
}
Refuses {New-IW7BaseClientPlan -GameRoot 'unused' -ClientImage 'unused' -ServerPort 27116 -ClientPort 27117 -OriginalRigConsole -RigAssetsProbe -RigSceneStockWitness} 'Plan accepted unpaired witness before filesystem work.'
"$count rig assets/scene probe argument checks passed; new scene CPP compilation/runtime remain pending."
