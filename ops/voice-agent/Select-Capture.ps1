param([Parameter(Mandatory)][string]$EndpointId)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/Capture-Route.Core.ps1"
$inventory=& "$PSScriptRoot/Voice-Fixture.ps1" -Action Inventory
Resolve-IW7VoiceCaptureRoute -Inventory $inventory -EndpointId $EndpointId
