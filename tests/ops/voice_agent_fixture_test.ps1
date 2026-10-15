$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$tool=Join-Path $repo 'ops/voice-agent/Voice-Fixture.ps1'
$root=Join-Path ([IO.Path]::GetTempPath()) ('iw7-voice-fixture-test-'+[guid]::NewGuid().ToString('N'))
function Assert-Fixture($Condition,[string]$Message) { if (!$Condition) { throw $Message } }
function Get-Defaults($Inventory) {
    @($Inventory.Endpoints | ForEach-Object { foreach ($role in $_.DefaultRoles) { $_.Flow+'|'+$role+'|'+$_.Id } } | Sort-Object) -join "`n"
}
function Assert-SpokenWave([string]$Path) {
    $bytes=[IO.File]::ReadAllBytes($Path)
    Assert-Fixture ($bytes.Length -gt 44 -and $bytes.Length -lt 16MB) 'Generated audio size invalid.'
    Assert-Fixture ([Text.Encoding]::ASCII.GetString($bytes,0,4) -eq 'RIFF' -and [Text.Encoding]::ASCII.GetString($bytes,8,4) -eq 'WAVE') 'Source is not RIFF/WAVE.'
    Assert-Fixture ([BitConverter]::ToUInt32($bytes,4)+8 -eq $bytes.Length) 'WAVE size does not match actual file.'
    $format=$false;$data=$false;$offset=12
    while ($offset+8 -le $bytes.Length) {
        $tag=[Text.Encoding]::ASCII.GetString($bytes,$offset,4)
        $length=[BitConverter]::ToUInt32($bytes,$offset+4);$start=$offset+8
        Assert-Fixture ($length -le $bytes.Length-$start) 'Truncated WAVE chunk.'
        if ($tag -eq 'fmt ') {
            Assert-Fixture ($length -ge 16) 'Missing PCM format.'
            Assert-Fixture ([BitConverter]::ToUInt16($bytes,$start) -eq 1 -and [BitConverter]::ToUInt16($bytes,$start+2) -eq 1 -and [BitConverter]::ToUInt32($bytes,$start+4) -eq 16000 -and [BitConverter]::ToUInt16($bytes,$start+14) -eq 16) 'SAPI did not produce requested PCM mono16kHz16bit.'
            $format=$true
        }
        if ($tag -eq 'data') {
            Assert-Fixture ($length -gt 32000 -and $length -le 16000*2*30 -and $length%2 -eq 0) 'Spoken fixture duration is outside1..30seconds.'
            $sum=0.0;$active=0
            for ($index=$start;$index -lt $start+$length;$index+=2) {
                $sample=[BitConverter]::ToInt16($bytes,$index);$sum+=[double]$sample*$sample
                if ([math]::Abs([int]$sample) -gt 100) { $active++ }
            }
            Assert-Fixture ([math]::Sqrt($sum/($length/2)) -gt 100 -and $active -gt 1600) 'Generated speech is silent or too short.'
            $data=$true
        }
        $offset=$start+$length+($length%2)
    }
    Assert-Fixture ($format -and $data) 'WAVE is missing format or audible-source data.'
}
try {
    $before=& $tool -Action Inventory
    Assert-Fixture (!$before.CapturedMicrophone -and !$before.PlayedAudio -and !$before.ChangedAudioDefaults) 'Inventory touched audio capture/playback/defaults.'
    Assert-Fixture ($before.Voices.Count -gt 0) 'No installed SAPI voice: fixture generation cannot be tested.'
    foreach ($device in @($before.DirectSoundCapture | Where-Object { !$_.DefaultAlias })) {
        $matches=@($before.Endpoints | Where-Object { $_.Flow -eq 'capture' -and $_.EndpointGuid -and [guid]$_.EndpointGuid -eq [guid]$device.Guid })
        Assert-Fixture ($matches.Count -eq 1) 'DirectSound capture GUID cannot be correlated with exactly one CoreAudio endpoint.'
    }
    $first=& $tool -Action Generate -OutputRoot "$root/first"
    $manifest=Get-Content -LiteralPath $first.Manifest -Raw | ConvertFrom-Json
    Assert-Fixture ($manifest.SyntheticSpeech -and $manifest.DefaultsUnchanged -and $manifest.Files.Count -eq 2) 'Fixture provenance/default evidence missing.'
    foreach ($file in $manifest.Files) {
        Assert-SpokenWave (Join-Path $first.OutputRoot $file.File)
        Assert-Fixture ((Get-FileHash (Join-Path $first.OutputRoot $file.File)).Hash -eq $file.SHA256) 'Manifest does not describe actual source bytes.'
    }
    $second=& $tool -Action Generate -OutputRoot "$root/second" -VoiceTokenId $manifest.Voice.Id
    $secondManifest=Get-Content -LiteralPath $second.Manifest -Raw|ConvertFrom-Json
    Assert-Fixture (!$secondManifest.SynthesisPerformed -and $secondManifest.FrozenDescriptorSHA256 -ceq $manifest.FrozenDescriptorSHA256 -and
        $secondManifest.OriginalSynthesisUtc -ceq $manifest.OriginalSynthesisUtc) 'Repeated fixture did not reuse its original descriptor-bound synthesis.'
    foreach ($file in $first.Files) {
        $repeat=@($second.Files | Where-Object Name -eq $file.Name)
        Assert-Fixture ($repeat.Count -eq 1 -and $repeat[0].SHA256 -eq $file.SHA256) 'Same installed SAPI voice/settings did not reproduce identical speech bytes.'
    }
    Assert-Fixture ($first.Files[0].SHA256 -ne $first.Files[1].SHA256) 'Distinct PTT/reconnect stimuli are identical.'
    $guard=Join-Path $first.OutputRoot 'owner.txt';[IO.File]::WriteAllText($guard,'preserve existing output')
    $refused=$false;try { & $tool -Action Generate -OutputRoot $first.OutputRoot | Out-Null } catch { $refused=$true }
    Assert-Fixture ($refused -and [IO.File]::ReadAllText($guard) -eq 'preserve existing output') 'Generator overwrote an existing output directory.'
    $trackedOutput=Join-Path $repo ('docs/voice-fixture-test-'+[guid]::NewGuid().ToString('N'))
    $refused=$false;try { & $tool -Action Generate -OutputRoot $trackedOutput | Out-Null } catch { $refused=$true }
    Assert-Fixture ($refused -and !(Test-Path -LiteralPath $trackedOutput)) 'Generated audio entered tracked repository directories.'
    $badPackage=Join-Path $root 'invalid-package.zip';[IO.File]::WriteAllText($badPackage,'not the pinned official package')
    $packageOutput=Join-Path $repo ('runtime/voice-agent/package-negative-'+[guid]::NewGuid().ToString('N'))
    $refused=$false;try { & "$repo/ops/voice-agent/Prepare-VirtualCable.ps1" -OutputRoot $packageOutput -ArchivePath $badPackage | Out-Null } catch { $refused=$true }
    Assert-Fixture ($refused -and !(Test-Path -LiteralPath $packageOutput)) 'Untrusted driver archive was extracted or changed output before verification.'
    $after=& $tool -Action Inventory
    Assert-Fixture ((Get-Defaults $before) -eq (Get-Defaults $after)) 'Audio defaults changed across passive generation test.'
    'PASS voice-agent: passive CoreAudio/SAPI inventory, original deterministic source WAVs, real PCM/non-silence/duration/hash checks, distinct stimuli, existing-output refusal and unchanged defaults. No microphone capture or game test.'
} finally {
    $resolved=[IO.Path]::GetFullPath($root)
    if (!$resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -notlike 'iw7-voice-fixture-test-*') { throw 'Fixture cleanup containment failed.' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
