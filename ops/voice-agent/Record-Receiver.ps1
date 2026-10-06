#requires -Version 7.4
param(
    [Parameter(Mandatory)][string]$ProbePath,
    [Parameter(Mandatory)][int]$ProcessId,
    [Parameter(Mandatory)][uint64]$CreationFileTime,
    [Parameter(Mandatory)][string]$ExpectedImage,
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedSHA256,
    [Parameter(Mandatory)][string]$OutputRoot,
    [ValidateRange(1,60)][int]$Seconds=15,
    [Parameter(Mandatory)][switch]$SyntheticFixture,
    [switch]$DryRun
)
# Receiver output only. Never opens a microphone, changes devices, or selects a
# device-wide fallback. The caller owns admission/protection and the known speech.
$ErrorActionPreference='Stop'
. "$PSScriptRoot/Recording.Core.ps1"
if (!('IW7.VoiceAgent.OwnedProbe' -as [type])) { Add-Type -Path "$PSScriptRoot/OwnedProbe.cs" }
if (!$SyntheticFixture -or $ProcessId -le 0 -or !$CreationFileTime) { throw 'Known synthetic fixture and exact nonzero process identity required.' }
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$runtime=[IO.Path]::GetFullPath((Join-Path $repo 'runtime'))
$root=[IO.Path]::GetFullPath($OutputRoot)
if (!$root.StartsWith($runtime+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $root)) { throw 'Fresh output directory under ignored repository runtime required.' }
$cursor=Split-Path $root -Parent
while ($cursor) {
    if ((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Recording ancestors must not be reparse points.' }
    $parent=Split-Path $cursor -Parent;if ($parent -eq $cursor) { break };$cursor=$parent
}
$probe=[IO.Path]::GetFullPath($ProbePath)
$image=[IO.Path]::GetFullPath($ExpectedImage)
$process=Get-Process -Id $ProcessId
try {
    if ($process.HasExited -or $process.Path -ine $image -or [uint64]$process.StartTime.ToFileTimeUtc() -ne $CreationFileTime) { throw 'Exact receiver PID/creation/image mismatch.' }
} finally { $process.Dispose() }
if ((Get-FileHash -LiteralPath $image -Algorithm SHA256).Hash -ine $ExpectedSHA256) { throw 'Receiver image hash mismatch.' }
$probeHash=(Get-FileHash -LiteralPath $probe -Algorithm SHA256).Hash
$wav=Join-Path $root 'receiver.wav'
$plan=[ordered]@{
    Kind='known_synthetic_receiver_process_loopback';ProcessId=$ProcessId;CreationFileTime=$CreationFileTime
    ExpectedImage=$image;ExpectedSHA256=$ExpectedSHA256;ProbePath=$probe;ProbeSHA256=$probeHash
    Seconds=$Seconds;OutputWAV=$wav;Format='PCM16 stereo 48000Hz';MaximumPCMBytes=$Seconds*192000
    Scope='Windows INCLUDE_TARGET_PROCESS_TREE; bounded recursive snapshot descendants checked before/after and every 100ms; short-lived children and orphaned descendants can escape snapshots; not PID-only or audio-session isolation'
    DeviceFallback=$false;MicrophoneCaptured=$false;ChangedAudioDefaults=$false;HumanAcceptance=$false
}
if ($DryRun) { return [pscustomobject]$plan }
New-Item -ItemType Directory -Path $root | Out-Null
$manifest=Join-Path $root 'manifest.local.json'
$result=[ordered]@{Plan=$plan;StartedUtc=[datetime]::UtcNow.ToString('o');Completed=$false;ExitCode=$null;WAVSHA256=$null;Error=$null}
try {
    $result.Probe=[IW7.VoiceAgent.OwnedProbe]::Run($probe,$probeHash,
        [string[]]@('--record',"$Seconds","$ProcessId","$CreationFileTime",$image,$ExpectedSHA256,$wav),
        (Join-Path $root 'recording.log'),(Join-Path $root 'recording-error.log'),$Seconds+15)
    $result.ExitCode=$result.Probe.ExitCode
    if ($result.Probe.TimedOut -or $result.Probe.LogBoundExceeded -or $result.ExitCode) { throw "Exact receiver probe failed (exit $($result.ExitCode), timeout=$($result.Probe.TimedOut)); retain diagnostics." }
    $result.WAVValidation=Assert-IW7ReceiverWAV -Path $wav -Seconds $Seconds
    $result.WAVSHA256=(Get-FileHash -LiteralPath $wav -Algorithm SHA256).Hash
    $result.Completed=$true
} catch { $result.Error=$_.Exception.Message;throw }
finally {
    $result.FinishedUtc=[datetime]::UtcNow.ToString('o')
    $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifest -Encoding utf8
}
[pscustomobject]$result
