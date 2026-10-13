$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. "$repo/ops/voice-agent/Cable-Transaction.Core.ps1"
function Make-Snapshot {
    [pscustomobject]@{Endpoints=@(
        [pscustomobject]@{Id='owner-capture';EndpointGuid='owner-capture-guid';Flow='capture';State=1;Name='Owner microphone';DefaultRoles=@('console','multimedia','communications')},
        [pscustomobject]@{Id='owner-render';EndpointGuid='owner-render-guid';Flow='render';State=1;Name='Owner headphones';DefaultRoles=@('console','multimedia','communications')}
    );Packages=@([pscustomobject]@{PublishedName='oem1.inf';OriginalName='unrelated.inf';InfSHA256='A'*64})}
}
$before=Make-Snapshot;$after=Make-Snapshot
$after.Endpoints[0].DefaultRoles=@('multimedia','communications')
$after.Endpoints+= [pscustomobject]@{Id='new-cable';EndpointGuid='new-cable-guid';Flow='capture';State=1;Name='CABLE Output (VB-Audio Virtual Cable)';DefaultRoles=@('console')}
$after.Packages+= [pscustomobject]@{PublishedName='oem2.inf';OriginalName='vbMmeCable64_win10.inf';InfSHA256='B'*64}
$restore=@(New-IW7AudioRestorationPlan $before $after $after)
if ($restore.Count -ne 1 -or $restore[0].RestoreId -ne 'owner-capture' -or $restore[0].Arguments[2] -ne '0') { throw 'Restoration changed unrelated/default roles or selected wrong endpoint.' }
$rollback=New-IW7CableRollbackPlan $before $after $after ('B'*64)
if ($rollback.PublishedName -ne 'oem2.inf' -or $rollback.Force -or $rollback.AutomaticReboot -or $rollback.Arguments.Count -ne 3) { throw 'Rollback was not scoped to exact new OEM package.' }
$already=Make-Snapshot;$already.Endpoints+= [pscustomobject]@{Id='new-cable';EndpointGuid='new-cable-guid';Flow='capture';State=1;Name='CABLE Output (VB-Audio Virtual Cable)';DefaultRoles=@()}
if (@(New-IW7AudioRestorationPlan $before $after $already).Count) { throw 'Already restored role would be written again.' }
$concurrent=Make-Snapshot;$concurrent.Endpoints[0].Id='owner-new-choice'
$refused=$false;try { New-IW7AudioRestorationPlan $before $after $concurrent | Out-Null } catch { $refused=$true }
if (!$refused) { throw 'Concurrent owner default overwritten.' }
$missing=Make-Snapshot;$missing.Endpoints[0].State=4;$missing.Endpoints[0].DefaultRoles=@('multimedia','communications');$missing.Endpoints+= $after.Endpoints[2]
$refused=$false;try { New-IW7AudioRestorationPlan $before $after $missing | Out-Null } catch { $refused=$true }
if (!$refused) { throw 'Missing/inactive original endpoint accepted.' }
$refused=$false;try { New-IW7CableRollbackPlan $after $after $after ('B'*64) | Out-Null } catch { $refused=$true }
if (!$refused) { throw 'Pre-existing cable package selected for rollback.' }
$changed=Make-Snapshot;$changed.Packages+= [pscustomobject]@{PublishedName='oem2.inf';OriginalName='vbMmeCable64_win10.inf';InfSHA256='C'*64}
$refused=$false;try { New-IW7CableRollbackPlan $before $after $changed ('B'*64) | Out-Null } catch { $refused=$true }
if (!$refused) { throw 'Changed OEM package hash accepted for rollback.' }
$parsed=@(Convert-IW7MediaPackages "Published Name: oem3.inf`nOriginal Name: vbMmeCable64_win10.inf`n`nNom publié: oem4.inf`nNom d'origine: unrelated.inf")
if ($parsed.Count -ne 2 -or $parsed[1].PublishedName -ne 'oem4.inf') { throw 'Localized driver package identity parsing failed.' }
'PASS cable transaction plans: only changed owned default role, exact new OEM/hash rollback; pre-existing/changed package, concurrent owner/default or inactive original refused; no system command executed.'
