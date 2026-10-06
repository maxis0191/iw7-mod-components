param(
    [ValidateSet('Inventory','Generate')][string]$Action='Inventory',
    [string]$OutputRoot,
    [string]$VoiceTokenId
)
$ErrorActionPreference='Stop'
if (![Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) { throw 'Windows CoreAudio/SAPI required.' }
if ($Action -eq 'Generate' -and !$OutputRoot) { throw 'Generate requires a fresh local output directory.' }
if (!('IW7.VoiceAgent.CoreAudioInventory' -as [type])) { Add-Type -Path "$PSScriptRoot/CoreAudioInventory.cs" }
function Release-VoiceCom($Object) { if ($null -ne $Object -and [Runtime.InteropServices.Marshal]::IsComObject($Object)) { $null=[Runtime.InteropServices.Marshal]::FinalReleaseComObject($Object) } }
$voice=$null;$tokens=$null;$stream=$null;$selected=$null
try {
    $before=@([IW7.VoiceAgent.CoreAudioInventory]::Read())
    $voice=New-Object -ComObject SAPI.SpVoice
    $tokens=$voice.GetVoices()
    $installed=@(for ($index=0;$index -lt $tokens.Count;$index++) {
        $token=$tokens.Item($index)
        try { [pscustomobject]@{Id=$token.Id;Name=$token.GetDescription();Language=$token.GetAttribute('Language')} }
        finally { Release-VoiceCom $token }
    })
    $result=[ordered]@{Schema=1;Utc=[datetime]::UtcNow.ToString('o');Kind='passive_inventory';Endpoints=$before;
        DirectSoundCapture=@([IW7.VoiceAgent.CoreAudioInventory]::ReadDirectSoundCapture());Voices=$installed;
        InventorySourceSHA256=(Get-FileHash -LiteralPath "$PSScriptRoot/CoreAudioInventory.cs").Hash;
        CapturedMicrophone=$false;ChangedAudioDefaults=$false;PlayedAudio=$false;SyntheticSpeech=$false;
        EvidenceBoundary='OS endpoint enumeration only; no device capture, codec, transport, decode or render proof.'}
    if ($Action -eq 'Generate') {
        $root=[IO.Path]::GetFullPath($OutputRoot)
        if (Test-Path -LiteralPath $root) { throw 'Fresh output directory required; existing files will not be overwritten.' }
        $repo=[IO.Path]::GetFullPath((Split-Path (Split-Path $PSScriptRoot -Parent) -Parent))
        $runtime=Join-Path $repo 'runtime'
        if ($root.StartsWith($repo+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -and
            !$root.StartsWith($runtime+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Generated audio inside the repository must remain under ignored runtime.' }
        $candidate=if ($VoiceTokenId) { @($installed | Where-Object Id -eq $VoiceTokenId) } else { @($installed | Where-Object { $_.Language -match '(?i)(^|;)409(;|$)' } | Select-Object -First 1) }
        if ($candidate.Count -ne 1) { throw 'Select one installed SAPI voice token; no voice will be downloaded.' }
        for ($index=0;$index -lt $tokens.Count;$index++) {
            $token=$tokens.Item($index)
            if ($token.Id -eq $candidate[0].Id) { $selected=$token;break }
            Release-VoiceCom $token
        }
        $voice.Voice=$selected;$voice.Rate=0;$voice.Volume=100
        [IO.Directory]::CreateDirectory($root) | Out-Null
        $phrases=[ordered]@{
            'ptt'='Alpha seven. The blue lantern is beside the quiet river. Four nine two. Release the talk key after this sentence.'
            'reconnect'='Bravo three. The green bicycle waits near the wooden bridge. Six one eight. This is a new message after reconnect.'
        }
        $files=@(foreach ($entry in $phrases.GetEnumerator()) {
            $path=Join-Path $root ($entry.Key+'.wav')
            $stream=New-Object -ComObject SAPI.SpFileStream
            try {
                $format=$stream.Format
                try { $format.Type=18 } finally { Release-VoiceCom $format } # SAFT16kHz16BitMono
                $stream.Open($path,3,$false) # SSFMCreateForWrite, local file only
                $voice.AudioOutputStream=$stream
                $null=$voice.Speak($entry.Value,0) # synchronous original text; no XML
                $stream.Close()
            } finally { Release-VoiceCom $stream;$stream=$null }
            [pscustomobject]@{Name=$entry.Key;File=[IO.Path]::GetFileName($path);Text=$entry.Value;SHA256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash;Bytes=(Get-Item -LiteralPath $path).Length}
        })
        $result.Kind='synthetic_speech_fixture';$result.SyntheticSpeech=$true
        $result.EvidenceBoundary='Generated source WAV only; has not traversed OS microphone capture, IW7 codec, transport, decoder or rendering.'
        $result.Voice=$candidate[0];$result.Format='PCM mono 16000 Hz 16-bit';$result.Rate=0;$result.Volume=100
        $result.Reproducibility='Fixed original text/token/rate/format; byte identity is checked by hashes. Different installed speech-engine versions may produce different bytes.'
        $result.Files=$files
        $result.GeneratorSHA256=(Get-FileHash -LiteralPath $PSCommandPath).Hash
        $result.OSVersion=[Environment]::OSVersion.VersionString
        $after=@([IW7.VoiceAgent.CoreAudioInventory]::Read())
        $beforeDefaults=@($before | ForEach-Object { foreach ($role in $_.DefaultRoles) { $_.Flow+'|'+$role+'|'+$_.Id } } | Sort-Object)
        $afterDefaults=@($after | ForEach-Object { foreach ($role in $_.DefaultRoles) { $_.Flow+'|'+$role+'|'+$_.Id } } | Sort-Object)
        if (($beforeDefaults -join "`n") -ne ($afterDefaults -join "`n")) { throw 'Audio defaults changed during generation; retain artifacts and investigate external device changes.' }
        $result.DefaultsUnchanged=$true
        $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $root 'manifest.local.json') -Encoding utf8
        [pscustomobject]@{OutputRoot=$root;Manifest=(Join-Path $root 'manifest.local.json');Files=$files;SyntheticSpeech=$true;DefaultsUnchanged=$true;EvidenceBoundary=$result.EvidenceBoundary}
    } else { [pscustomobject]$result }
} finally { Release-VoiceCom $stream;Release-VoiceCom $selected;Release-VoiceCom $tokens;Release-VoiceCom $voice }
