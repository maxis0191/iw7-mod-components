function Invoke-IW7CableTransaction {
    param([Parameter(Mandatory)]$Adapter,[Parameter(Mandatory)]$Plan,[switch]$RollbackOnFailure)
    # All effects are injected; pure tests exercise the same state machine.
    if (!$Plan.Elevated -or $Plan.ReuseFirst -or !$Plan.RestorerReviewed -or !$Plan.NoAutomaticRebootInstructionFound) { throw 'Installation prerequisites are not satisfied.' }
    $before=$null;$after=$null;$setupReturned=$false
    try {
        & $Adapter.Journal 'preflight' $null
        & $Adapter.Verify
        $before=& $Adapter.Snapshot 'before'
        [void]@(Get-IW7AudioDefaults $before.Endpoints)
        if (@($before.Packages | Where-Object OriginalName -match '^vbMmeCable').Count -or @($before.Endpoints | Where-Object Name -match '^CABLE (Input|Output)').Count) { throw 'Cable appeared after planning; reuse/diagnose instead.' }
        & $Adapter.Verify
        & $Adapter.AssertIdle
        & $Adapter.Journal 'install_started' $null
        $exit=& $Adapter.Install
        $setupReturned=$true
        $after=& $Adapter.Snapshot 'after'
        & $Adapter.Journal 'install_returned' @{ExitCode=$exit}
        if ($exit -ne 0) { throw "Installer returned $exit; retain actual after state." }
        foreach ($change in @(New-IW7AudioRestorationPlan $before $after $after)) {
            & $Adapter.Verify
            $now=& $Adapter.Snapshot 'role_precheck'
            $fresh=@(New-IW7AudioRestorationPlan $before $after $now | Where-Object { $_.Flow -ceq $change.Flow -and $_.Role -ceq $change.Role })
            if (!$fresh.Count) { continue }
            & $Adapter.Journal 'restore_role' $fresh[0]
            & $Adapter.SetDefault $fresh[0]
        }
        $final=& $Adapter.Snapshot 'final'
        if (@(New-IW7AudioRestorationPlan $before $after $final).Count) { throw 'Restitution verification failed.' }
        $prior=@(Get-IW7AudioDefaults $before.Endpoints);$actual=@(Get-IW7AudioDefaults $final.Endpoints)
        foreach ($role in $prior) { if (@($actual | Where-Object { $_.Flow -ceq $role.Flow -and $_.Role -ceq $role.Role -and $_.EndpointId -ceq $role.EndpointId }).Count -ne 1) { throw 'Six-default verification failed.' } }
        [void](New-IW7CableRollbackPlan $before $after $final $Plan.ExpectedInfSHA256)
        & $Adapter.Journal 'complete_reboot_pending' $null
        return [pscustomobject]@{Completed=$true;RebootRequired=$true;AutomaticReboot=$false}
    } catch {
        $failure=$_
        & $Adapter.Journal 'failed' @{Error=$failure.Exception.Message;SetupReturned=$setupReturned}
        # Default restitution is independent of optional package removal. A
        # returned installer may have changed roles even with a nonzero exit.
        if ($setupReturned -and $before) {
            try {
                & $Adapter.Verify # Persistent live-command marker refuses all writes.
                if (!$after) {
                    for ($attempt=0;$attempt -lt 2 -and !$after;$attempt++) {
                        try { $after=& $Adapter.Snapshot 'after_retry' }
                        catch { & $Adapter.Journal 'after_snapshot_retry_failed' @{Attempt=$attempt;Error=$_.Exception.Message} }
                    }
                    if (!$after) { throw 'No retained post-state; restitution identity cannot be proven.' }
                }
                $now=& $Adapter.Snapshot 'failure_restore_precheck'
                foreach ($change in @(New-IW7AudioRestorationPlan $before $after $now)) {
                    & $Adapter.Verify
                    $live=& $Adapter.Snapshot 'failure_restore_role_precheck'
                    $fresh=@(New-IW7AudioRestorationPlan $before $after $live | Where-Object { $_.Flow -ceq $change.Flow -and $_.Role -ceq $change.Role })
                    if ($fresh.Count) { & $Adapter.Journal 'failure_restore_role' $fresh[0]; & $Adapter.SetDefault $fresh[0] }
                }
                $live=& $Adapter.Snapshot 'failure_restore_final'
                if (@(New-IW7AudioRestorationPlan $before $after $live).Count) { throw 'Failed-install restitution did not complete.' }
                & $Adapter.Journal 'failure_defaults_restored' $null
            } catch { & $Adapter.Journal 'failure_defaults_refused_or_failed' @{Error=$_.Exception.Message;OriginalError=$failure.Exception.Message} }
        }
        # No rollback while setup may be alive or when post-state could not be retained.
        if ($RollbackOnFailure -and $setupReturned -and $before -and $after) {
            try {
                & $Adapter.Verify
                $now=& $Adapter.Snapshot 'rollback_precheck'
                $rollback=New-IW7CableRollbackPlan $before $after $now $Plan.ExpectedInfSHA256
                # Restore owned changed roles before removing the new endpoint.
                foreach ($change in @(New-IW7AudioRestorationPlan $before $after $now)) {
                    $live=& $Adapter.Snapshot 'rollback_role_precheck'
                    $fresh=@(New-IW7AudioRestorationPlan $before $after $live | Where-Object { $_.Flow -ceq $change.Flow -and $_.Role -ceq $change.Role })
                    if ($fresh.Count) { & $Adapter.Verify; & $Adapter.SetDefault $fresh[0] }
                }
                $live=& $Adapter.Snapshot 'rollback_export_precheck'
                if (@(New-IW7AudioRestorationPlan $before $after $live).Count) { throw 'Default restitution incomplete; refuse package removal.' }
                $rollback=New-IW7CableRollbackPlan $before $after $live $Plan.ExpectedInfSHA256
                & $Adapter.Export $rollback
                & $Adapter.Verify
                $live=& $Adapter.Snapshot 'rollback_delete_precheck'
                $rollback=New-IW7CableRollbackPlan $before $after $live $Plan.ExpectedInfSHA256
                # Adapter must freshly inspect current package bindings before deletion.
                & $Adapter.Delete $rollback $live
                $final=& $Adapter.Snapshot 'rollback_final'
                if (@($final.Packages | Where-Object PublishedName -CEQ $rollback.PublishedName).Count) { throw 'Package deletion not verified.' }
                & $Adapter.Journal 'rollback_complete_reboot_pending' $null
            } catch { & $Adapter.Journal 'rollback_refused_or_failed' @{Error=$_.Exception.Message} }
        }
        throw $failure
    }
}
