function Convert-IW7MediaPackages {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    foreach ($block in ($Text -split '(?:\r?\n){2,}')) {
        $published=@([regex]::Matches($block,'(?im)^\s*[^:\r\n]+:\s*(oem\d+\.inf)\s*$') | ForEach-Object { $_.Groups[1].Value })
        if (!$published.Count) { continue }
        $original=@([regex]::Matches($block,'(?im)^\s*[^:\r\n]+:\s*([^:\r\n]+\.inf)\s*$') | ForEach-Object { $_.Groups[1].Value.Trim() } | Where-Object { $_ -notmatch '^oem\d+\.inf$' })
        if ($published.Count -ne 1 -or $original.Count -ne 1) { throw 'Ambiguous published/original driver package names.' }
        [pscustomobject]@{PublishedName=$published[0];OriginalName=$original[0]}
    }
}
function Get-IW7AudioDefaults {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Endpoints)
    foreach ($flow in @('capture','render')) { foreach ($role in @('console','multimedia','communications')) {
        $matches=@($Endpoints | Where-Object { $_.Flow -ceq $flow -and $_.DefaultRoles -contains $role })
        if ($matches.Count -ne 1) { throw "Exactly one current default required for $flow/$role; missing defaults cannot be restored safely by this route." }
        [pscustomobject]@{Flow=$flow;Role=$role;EndpointId=$matches[0].Id;EndpointGuid=$matches[0].EndpointGuid}
    } }
}
function New-IW7AudioRestorationPlan {
    param([Parameter(Mandatory)]$Before,[Parameter(Mandatory)]$After,[Parameter(Mandatory)]$Current)
    $prior=@(Get-IW7AudioDefaults $Before.Endpoints);$post=@(Get-IW7AudioDefaults $After.Endpoints);$now=@(Get-IW7AudioDefaults $Current.Endpoints)
    foreach ($item in $prior) {
        $changed=@($post | Where-Object { $_.Flow -ceq $item.Flow -and $_.Role -ceq $item.Role })[0]
        if ($changed.EndpointId -ceq $item.EndpointId) { continue }
        $currentDefault=@($now | Where-Object { $_.Flow -ceq $item.Flow -and $_.Role -ceq $item.Role })[0]
        $installed=@($After.Endpoints | Where-Object { $_.Id -ceq $changed.EndpointId -and $_.Flow -ceq $item.Flow -and $_.Name -match '^CABLE (Input|Output)\s*\(' })
        if ($currentDefault.EndpointId -ceq $item.EndpointId) { continue } # Already restored; no write.
        if ($currentDefault.EndpointId -cne $changed.EndpointId -or $installed.Count -ne 1 -or
            @($Before.Endpoints | Where-Object Id -CEQ $changed.EndpointId).Count) { throw 'Changed default is not an owned newly installed cable, or a concurrent owner change occurred.' }
        $target=@($Current.Endpoints | Where-Object { $_.Id -ceq $item.EndpointId -and $_.Flow -ceq $item.Flow -and $_.State -eq 1 -and $_.EndpointGuid -ceq $item.EndpointGuid })
        if ($target.Count -ne 1) { throw 'Original endpoint is missing/inactive or its identity changed.' }
        [pscustomobject]@{Flow=$item.Flow;Role=$item.Role;ExpectedCurrentId=$changed.EndpointId;RestoreId=$item.EndpointId;
            Arguments=@('/SetDefault',$item.EndpointId,@{console='0';multimedia='1';communications='2'}[$item.Role])}
    }
}
function New-IW7CableRollbackPlan {
    param([Parameter(Mandatory)]$Before,[Parameter(Mandatory)]$After,[Parameter(Mandatory)]$Current,[Parameter(Mandatory)][string]$ExpectedInfSHA256)
    $prior=@($Before.Packages | ForEach-Object PublishedName)
    $added=@($After.Packages | Where-Object { $_.PublishedName -notin $prior -and $_.OriginalName -ieq 'vbMmeCable64_win10.inf' })
    if ($added.Count -ne 1 -or $added[0].PublishedName -notmatch '^oem\d+\.inf$') { throw 'Rollback requires exactly one newly added VB-CABLE package, never an existing package.' }
    $currentPackage=@($Current.Packages | Where-Object PublishedName -CEQ $added[0].PublishedName)
    if ($currentPackage.Count -ne 1 -or $currentPackage[0].OriginalName -cne $added[0].OriginalName -or
        $currentPackage[0].InfSHA256 -ine $ExpectedInfSHA256 -or $added[0].InfSHA256 -ine $ExpectedInfSHA256) { throw 'Added package identity/hash changed; refuse rollback.' }
    [pscustomobject]@{PublishedName=$added[0].PublishedName;InfSHA256=$ExpectedInfSHA256;
        Arguments=@('/delete-driver',$added[0].PublishedName,'/uninstall');Force=$false;AutomaticReboot=$false;
        Boundary='Only this added OEM package; inventory bindings and retain export before deletion; coordinate subsequent reboot.'}
}
