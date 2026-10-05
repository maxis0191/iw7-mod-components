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

function Get-IW7LabAssetArguments([string]$BaseAssetRoot, [string]$ProfileRoot) {
    foreach ($path in @($BaseAssetRoot,$ProfileRoot)) {
        if (!$path -or ![IO.Path]::IsPathRooted($path) -or $path -match '["\r\n]' -or
            !(Test-Path -LiteralPath $path -PathType Container)) { throw 'Invalid installed asset/profile root.' }
    }
    if (!(Test-Path -LiteralPath (Join-Path $BaseAssetRoot 'iw7_ship.exe') -PathType Leaf) -or
        !(Test-Path -LiteralPath (Join-Path $BaseAssetRoot 'assetfile1.pak') -PathType Leaf) -or
        [IO.Path]::GetFullPath($BaseAssetRoot) -eq [IO.Path]::GetFullPath($ProfileRoot)) {
        throw 'Base asset root must be an installed game separate from the owned profile.'
    }
    ' +set fs_basepath "' + $BaseAssetRoot + '" +set fs_homepath "' + $ProfileRoot + '"'
}
