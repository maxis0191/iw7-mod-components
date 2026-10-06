#requires -Version 7.4
param([Parameter(Mandatory)][string]$ProbePath,[Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedProbeSHA256,
    [Parameter(Mandatory)][string]$EndpointId,[Parameter(Mandatory)][string]$SourceWAV,
    [Parameter(Mandatory)][string]$OutputRoot,[Parameter(Mandatory)][switch]$SyntheticFixture,[switch]$DryRun)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/Render.Core.ps1"
if (!$SyntheticFixture) { throw 'Known original synthetic speech fixture required.' }
$inventory=& "$PSScriptRoot/Voice-Fixture.ps1" -Action Inventory
$route=Resolve-IW7VoiceRenderRoute $inventory $EndpointId
$wav=[IO.Path]::GetFullPath($SourceWAV);$probe=[IO.Path]::GetFullPath($ProbePath)
$waveLock=[IO.File]::Open($wav,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
try {
    $source=Assert-IW7SpeechWAV $wav;$hash=(Get-FileHash -LiteralPath $wav).Hash
    if ((Get-FileHash -LiteralPath $probe).Hash -ine $ExpectedProbeSHA256) { throw 'Expected render helper hash changed.' }
    $runtime=[IO.Path]::GetFullPath((Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'runtime'))
    $root=[IO.Path]::GetFullPath($OutputRoot)
    if (!$root.StartsWith($runtime+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $root)) { throw 'Fresh ignored runtime output required.' }
    $cursor=Split-Path $root -Parent
    while ($cursor) {
        if ((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Output reparse ancestor refused.' }
        $parent=Split-Path $cursor -Parent;if ($parent -eq $cursor) { break };$cursor=$parent
    }
    $plan=[ordered]@{Kind='explicit_virtual_render_original_speech';Route=$route;Source=$source;SourceWAV=$wav;SourceSHA256=$hash;Helper=$probe;HelperSHA256=$ExpectedProbeSHA256;MaximumStreamSeconds=15;MaximumHelperSeconds=25;ChangedAudioDefaults=$false;ChangedVolume=$false;ChangedMute=$false;MicrophoneCaptured=$false;HumanConversation=$false}
    if ($DryRun) { return [pscustomobject]$plan }
    if (!('IW7.VoiceAgent.OwnedProbe' -as [type])) { Add-Type -Path "$PSScriptRoot/OwnedProbe.cs" }
    New-Item -ItemType Directory -Path $root | Out-Null
    $result=[ordered]@{Plan=$plan;Completed=$false;Error=$null;Scope='WASAPI explicit CABLE Input shared render buffer submission/drain; receiver intelligibility not proven'}
    try {
        $result.Probe=[IW7.VoiceAgent.OwnedProbe]::Run($probe,$ExpectedProbeSHA256,[string[]]@('--play',$route.EndpointId,$route.EndpointGuid,$hash,$wav),(Join-Path $root 'render.log'),(Join-Path $root 'render-error.log'),25)
        if ($result.Probe.TimedOut -or $result.Probe.LogBoundExceeded -or $result.Probe.ExitCode) { throw 'Exact render helper failed; retain diagnostics.' }
        $log=Get-Content -LiteralPath (Join-Path $root 'render.log') -Raw
        $result.NegotiatedEvidence=Assert-IW7RenderCompletion $log $source.SourceFrames
        $result.Completed=$true
    } catch { $result.Error=$_.Exception.Message;throw }
    finally { $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $root 'manifest.local.json') -Encoding utf8 }
    [pscustomobject]$result
} finally { $waveLock.Dispose() }
