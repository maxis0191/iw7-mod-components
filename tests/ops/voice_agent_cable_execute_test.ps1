$ErrorActionPreference='Stop'
. "$PSScriptRoot/../../ops/voice-agent/Cable-Transaction.Core.ps1"
. "$PSScriptRoot/../../ops/voice-agent/Cable-Execute.Core.ps1"
function New-TestContext {
    $endpoints=@(foreach ($flow in @('capture','render')) { [pscustomobject]@{Id=$flow;EndpointGuid=$flow;Flow=$flow;Name='Owner';State=1;DefaultRoles=@('console','multimedia','communications')} })
    $s=@{Before=[pscustomobject]@{Endpoints=$endpoints;Packages=@()};Now=$null;Installed=0;Set=0;Deleted=0;Exported=0;FailInstall=$false;Timeout=$false;Conflict=$false;BadPackage=$false;RestoreError=$false;AfterError=$false;Events=[Collections.Generic.List[string]]::new()}
    $s.Now=$s.Before
    $plan=[pscustomobject]@{Elevated=$true;ReuseFirst=$false;RestorerReviewed=$true;NoAutomaticRebootInstructionFound=$true;ExpectedInfSHA256='A'}
    $adapter=@{
        Journal={param($phase,$data)$s.Events.Add($phase)}.GetNewClosure()
        Verify={}.GetNewClosure();AssertIdle={}.GetNewClosure()
        Snapshot={param($phase)
            if ($s.AfterError -and $phase -eq 'after') { throw 'after snapshot failed' }
            if ($s.Conflict -and $phase -eq 'role_precheck') { $s.Now.Endpoints[0].DefaultRoles=@('console','multimedia','communications');$s.Now.Endpoints[2].DefaultRoles=@();$s.Now.Endpoints[0].Id='owner_new_choice' }
            return $s.Now
        }.GetNewClosure()
        Install={
            $s.Installed++
            $e=@($s.Before.Endpoints | ForEach-Object { [pscustomobject]@{Id=$_.Id;EndpointGuid=$_.EndpointGuid;Flow=$_.Flow;Name=$_.Name;State=1;DefaultRoles=@($_.DefaultRoles)} })
            # Only capture console changes, all other five roles remain original.
            $e[0].DefaultRoles=@('multimedia','communications');$e[1].DefaultRoles=@('console','multimedia','communications')
            $e+=[pscustomobject]@{Id='new_cable';EndpointGuid='cable';Flow='capture';Name='CABLE Output (VB-Audio Virtual Cable)';State=1;DefaultRoles=@('console')}
            $s.Now=[pscustomobject]@{Endpoints=$e;Packages=@([pscustomobject]@{PublishedName='oem77.inf';OriginalName='vbMmeCable64_win10.inf';InfSHA256='A'})}
            if ($s.BadPackage) { $s.Now.Packages[0].InfSHA256='foreign' }
            if ($s.Timeout) { throw 'Installer still running' };if ($s.FailInstall) { return 1 };return 0
        }.GetNewClosure()
        SetDefault={param($change)if ($s.RestoreError) { throw 'restorer refused' };$s.Set++;$s.Now.Endpoints[0].DefaultRoles=@('console','multimedia','communications');$s.Now.Endpoints[2].DefaultRoles=@()}.GetNewClosure()
        Export={param($r)$s.Exported++}.GetNewClosure()
        Delete={param($r,$live) if ($r.PublishedName -cne 'oem77.inf' -or $r.Arguments -contains '/force' -or $r.Arguments -contains '/reboot') { throw 'Wrong deletion' };$s.Deleted++;$s.Now=$s.Before}.GetNewClosure()
    }
    return @{State=$s;Plan=$plan;Adapter=$adapter}
}
function Assert-Test($value,$message) { if (!$value) { throw $message } }
$c=New-TestContext;$result=Invoke-IW7CableTransaction $c.Adapter $c.Plan
Assert-Test ($result.Completed -and $result.RebootRequired -and !$result.AutomaticReboot -and $c.State.Set -eq 1 -and !$c.State.Deleted) 'Success/restoration wrong.'
foreach ($field in @('Elevated','RestorerReviewed','NoAutomaticRebootInstructionFound')) {
    $c=New-TestContext;$c.Plan.$field=$false;$refused=$false
    try { Invoke-IW7CableTransaction $c.Adapter $c.Plan } catch { $refused=$true }
    Assert-Test ($refused -and !$c.State.Installed) "Missing $field did not refuse before setup."
}
$c=New-TestContext;$c.State.FailInstall=$true
try { Invoke-IW7CableTransaction $c.Adapter $c.Plan -RollbackOnFailure;throw 'Expected failure' } catch { if ($_.Exception.Message -eq 'Expected failure') { throw } }
Assert-Test ($c.State.Set -eq 1 -and $c.State.Exported -eq 1 -and $c.State.Deleted -eq 1 -and $c.State.Events.Contains('rollback_complete_reboot_pending')) 'Failed install did not retain/restore/export/delete exact added package.'
$c=New-TestContext;$c.State.Timeout=$true
try { Invoke-IW7CableTransaction $c.Adapter $c.Plan -RollbackOnFailure } catch {}
Assert-Test (!$c.State.Deleted -and !$c.State.Exported -and !$c.State.Set) 'Live/timed out setup must not trigger concurrent rollback.'
$c=New-TestContext;$c.State.Conflict=$true
try { Invoke-IW7CableTransaction $c.Adapter $c.Plan -RollbackOnFailure } catch {}
Assert-Test (!$c.State.Set -and !$c.State.Deleted -and $c.State.Events.Contains('rollback_refused_or_failed')) 'Concurrent owner choice was overwritten/deleted.'
foreach ($mode in @('FailInstall','BadPackage','AfterError')) {
    $c=New-TestContext;$c.State[$mode]=$true;$message=$null
    try { Invoke-IW7CableTransaction $c.Adapter $c.Plan } catch { $message=$_.Exception.Message }
    Assert-Test ($message -and $c.State.Set -eq 1 -and !$c.State.Deleted) "Owned default was not restored without driver rollback for $mode."
}
$c=New-TestContext;$c.State.FailInstall=$true;$c.State.RestoreError=$true;$message=$null
try { Invoke-IW7CableTransaction $c.Adapter $c.Plan } catch { $message=$_.Exception.Message }
Assert-Test ($message -match 'Installer returned 1' -and $c.State.Events.Contains('failure_defaults_refused_or_failed') -and !$c.State.Deleted) 'Restitution error lost original setup error or removed package.'
'PASS cable executor state machine: admin/review/reboot refusal, exact-role success, failed setup exact rollback, live setup and owner conflicts preserved; no system execution.'
