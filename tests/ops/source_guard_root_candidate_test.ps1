$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
# Only authored pure managed sources; no bindings, guards, provider or native fixture.
Add-Type -Path @(
    (Join-Path $root 'ops/diagnostics/SourceGuardRootCandidate.cs')
    (Join-Path $root 'tests/managed/source_guard_root_candidate_test.cs')
)
$assertions = [IW7.Tests.Source.SourceGuardRootCandidateTests]::Run()
[ordered]@{
    ok = $true
    assertions = $assertions
    scope = 'PureManagedSourceCandidateDerivation'
    nativeEligibility = [IW7.Diagnostics.Source.SourceGuardRootCandidate]::NativeEligibility
    pendingRouteQualified = [IW7.Diagnostics.Source.SourceGuardRootCandidate]::PendingRouteQualified
    operationalRoot = [IW7.Diagnostics.Source.SourceGuardRootCandidate]::OperationalRoot
    provider = [IW7.Diagnostics.Source.SourceGuardRootCandidate]::Provider
    h3Outcome = [IW7.Diagnostics.Source.SourceGuardRootCandidate]::H3Outcome
} | ConvertTo-Json -Compress
