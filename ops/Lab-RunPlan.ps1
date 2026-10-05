function Get-IW7LabRunPlan {
    param([ValidateSet('Full','Reduced')][string]$GraphicsProfile = 'Full',
        [ValidateRange(0,2)][int]$PlannedClients = 1, [switch]$EnableAudio)
    $clientBytes = if ($GraphicsProfile -eq 'Reduced') { 8GB } else { 12GB }
    $picmip = if ($GraphicsProfile -eq 'Reduced') { 2 } else { 0 }
    [pscustomobject]@{
        GraphicsProfile=$GraphicsProfile;PlannedClients=$PlannedClients
        PhysicalBytes=(4GB + $PlannedClients * $clientBytes)
        CommitBytes=(4GB + $PlannedClients * $clientBytes)
        Picmip=$picmip;EnableAudio=[bool]$EnableAudio
        GraphicsArguments=" +set r_picmip $picmip +set r_picmip_bump $picmip +set r_picmip_spec $picmip"
    }
}

function Assert-IW7LabClientPlan($Plan, [ValidateSet('A','B')][string]$Slot = 'A') {
    if (!$Plan -or $Plan.PlannedClients -lt 1 -or $Plan.PlannedClients -gt 2 -or
        ($Slot -eq 'B' -and $Plan.PlannedClients -ne 2)) {
        throw 'Client was not included in the complete reservation; close the server and select a new plan.'
    }
}

function Assert-IW7LabFixturePlan([string]$Profile, [string]$Fixture, [int]$PlannedClients) {
    if ($Profile -eq 'Modules' -and $Fixture -eq 'StartupOnly' -and $PlannedClients -ne 0) {
        throw 'StartupOnly has no player fixture; reserve a zero-client linkage witness.'
    }
}
