$ErrorActionPreference='Stop'
. "$PSScriptRoot/../../ops/voice-agent/Render.Core.ps1"
function Refuse($action) { $refused=$false;try { & $action | Out-Null } catch { $refused=$true };if (!$refused) { throw 'Unsafe render evidence was accepted.' } }
$endpoint=[pscustomobject]@{Id='exact-render-id';EndpointGuid='11111111-2222-3333-4444-555555555555';Flow='render';State=1;Name='CABLE Input (VB-Audio Virtual Cable)'}
$inventory=[pscustomobject]@{Endpoints=@($endpoint)}
$route=Resolve-IW7VoiceRenderRoute $inventory 'exact-render-id'
if ($route.DefaultFallback) { throw 'Default fallback present.' }
Refuse { Resolve-IW7VoiceRenderRoute $inventory 'default' }
$endpoint.State=2;Refuse { Resolve-IW7VoiceRenderRoute $inventory 'exact-render-id' };$endpoint.State=1
$endpoint.Name='Owner Speakers';Refuse { Resolve-IW7VoiceRenderRoute $inventory 'exact-render-id' };$endpoint.Name='CABLE Input (VB-Audio Virtual Cable)'
$inventory.Endpoints=@($endpoint,$endpoint);Refuse { Resolve-IW7VoiceRenderRoute $inventory 'exact-render-id' };$inventory.Endpoints=@($endpoint)
$log="RENDER_COMPLETE source_frames=16000 submitted_frames=48000 mix_rate=48000 channels=2 bits=32 floating=1 default_fallback=0`n"
Assert-IW7RenderCompletion $log 16000 | Out-Null
foreach ($bad in @($log.Replace('submitted_frames=48000','submitted_frames=1'),$log.Replace('default_fallback=0','default_fallback=1'),$log.Replace('bits=32','bits=16'),$log.Replace('mix_rate=48000','mix_rate=999999'),("stale log`n"+$log),($log+$log))) { Refuse { Assert-IW7RenderCompletion $bad 16000 } }
Refuse { Assert-IW7RenderCompletion $log 240001 }
$dir=Join-Path ([IO.Path]::GetTempPath()) ('iw7-render-test-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $dir | Out-Null
try {
    $bytes=[byte[]]::new(48);[Text.Encoding]::ASCII.GetBytes('RIFF').CopyTo($bytes,0);[BitConverter]::GetBytes([uint32]40).CopyTo($bytes,4);[Text.Encoding]::ASCII.GetBytes('WAVEfmt ').CopyTo($bytes,8);[BitConverter]::GetBytes([uint32]16).CopyTo($bytes,16);$bytes[20]=1;$bytes[22]=1;[BitConverter]::GetBytes([uint32]16000).CopyTo($bytes,24);[BitConverter]::GetBytes([uint32]32000).CopyTo($bytes,28);$bytes[32]=2;$bytes[34]=16;[Text.Encoding]::ASCII.GetBytes('data').CopyTo($bytes,36);$bytes[40]=4
    $file=Join-Path $dir 'source.wav';[IO.File]::WriteAllBytes($file,$bytes)
    if ((Assert-IW7SpeechWAV $file).SourceFrames -ne 2) { throw 'Source frames incorrect.' }
    foreach ($offset in @(0,4,8,20,22,24,28,32,34,40)) { $bad=[byte[]]$bytes.Clone();$bad[$offset]=$bad[$offset] -bxor 1;[IO.File]::WriteAllBytes($file,$bad);Refuse { Assert-IW7SpeechWAV $file } }
} finally { Get-ChildItem -LiteralPath $dir -File | Remove-Item -Force;Remove-Item -LiteralPath $dir -Force }
'PASS explicit virtual render route, source RIFF bounds and fresh negotiated completion negatives; no audio stream activated.'
