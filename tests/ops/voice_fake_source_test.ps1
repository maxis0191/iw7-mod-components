$ErrorActionPreference='Stop'
. "$PSScriptRoot/../../ops/voice-agent/fake-Source.Core.ps1"
$root=Join-Path ([IO.Path]::GetTempPath()) ('iw7-fake-source-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root)|Out-Null
$owned=$null
try {
    $path=Join-Path $root 'source.wav';$bytes=[byte[]]::new(44);$bytes[0]=82
    [IO.File]::WriteAllBytes($path,$bytes)
    $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    $owned=Open-IW7FakeCaptureSource $path $hash
    if($owned.Length -ne 44 -or $owned.Sha256 -cne $hash -or $owned.Bytes[0] -ne 82){throw 'Retained bytes differ.'}
    $refused=$false;try{$other=[IO.File]::OpenWrite($path);$other.Dispose()}catch{$refused=$true}
    if(!$refused){throw 'Source writer was admitted while retained.'}
    $replacement=Join-Path $root 'replacement.wav';[IO.File]::WriteAllBytes($replacement,$bytes)
    $refused=$false;try{[IO.File]::Move($replacement,$path,$true)}catch{$refused=$true}
    if(!$refused){throw 'Source replacement was admitted while retained.'}
    $owned.Handle.Dispose();$owned=$null
    $refused=$false;try{$unexpected=Open-IW7FakeCaptureSource $path ('0'*64);$unexpected.Handle.Dispose()}catch{$refused=$true}
    if(!$refused){throw 'Wrong source hash admitted.'}
    # Failure must dispose its handle, so the caller can recover the source.
    [IO.File]::Move($replacement,$path,$true)
    [IO.File]::WriteAllBytes($path,[byte[]]::new(43))
    $refused=$false;try{$unexpected=Open-IW7FakeCaptureSource $path $hash;$unexpected.Handle.Dispose()}catch{$refused=$true}
    if(!$refused){throw 'Short source admitted.'}
    'voice_fake_source: retained bytes/hash/write/replace/bounds/failure cleanup PASS'
} finally {
    if($null -ne $owned){$owned.Handle.Dispose()}
    foreach($file in [IO.Directory]::GetFiles($root)){[IO.File]::Delete($file)}
    [IO.Directory]::Delete($root)
}
