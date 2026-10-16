$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
# Compile only these authored managed sources, in memory. No native bindings/provider fixture.
Add-Type -Path @(
    (Join-Path $root 'ops/diagnostics/ImmutableSnapshotCursor.cs')
    (Join-Path $root 'tests/managed/immutable_snapshot_cursor_test.cs')
)
$assertions = [IW7.Tests.Source.ImmutableSnapshotCursorTests]::Run()
[ordered]@{
    ok = $true
    assertions = $assertions
    scope = 'PureManagedSourceModel'
    nativeEligibility = [IW7.Diagnostics.Source.SnapshotQualification]::NativeEligibility
    provider = [IW7.Diagnostics.Source.SnapshotQualification]::Provider
    dbgHelpPdbUnmatched = [IW7.Diagnostics.Source.SnapshotQualification]::DbgHelpPdbUnmatched
    h3Outcome = [IW7.Diagnostics.Source.SnapshotQualification]::H3Outcome
} | ConvertTo-Json -Compress
