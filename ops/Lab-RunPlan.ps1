function Get-IW7LabRunPlan {
    param([ValidateSet('Full','Reduced')][string]$GraphicsProfile = 'Full',
        [ValidateRange(1,2)][int]$PlannedClients = 1, [switch]$EnableAudio)
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
