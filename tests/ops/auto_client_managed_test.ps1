param([string]$DownloadRoot)
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('iw7-managed-data-'+[guid]::NewGuid().ToString('N')+' path with spaces')
[IO.Directory]::CreateDirectory($temporary)|Out-Null
try {
    # Light managed Source test, like the other tests/managed suites. This is not
    # Package-AutoClient, a native build, an asset extraction or a game fixture.
    $compiler=Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
    $image=Join-Path $temporary 'data-probe.exe'
    $response=Join-Path $temporary 'compile.rsp'
    $lines=@('/nologo','/target:exe','/platform:x64','/optimize+','/warnaserror+',
        '/main:AutoClientDataProbe','/r:System.Windows.Forms.dll','/r:System.IO.Compression.dll',
        '/r:System.Web.Extensions.dll','/r:System.Management.dll',
        ('/resource:"'+[IO.Path]::GetFullPath((Join-Path $root 'config/auto-client-data.json'))+'",community-data.json'),
        ('/out:"'+$image+'"'),
        ('"'+[IO.Path]::GetFullPath((Join-Path $root 'src/bootstrap/AutoClient.cs'))+'"'),
        ('"'+[IO.Path]::GetFullPath((Join-Path $root 'tests/managed/auto_client_data_probe.cs'))+'"'))
    [IO.File]::WriteAllLines($response,$lines,[Text.UTF8Encoding]::new($true))
    & $compiler ('@'+$response)
    if($LASTEXITCODE){throw 'Managed auto-client Source compilation failed.'}
    if($DownloadRoot){& $image $DownloadRoot}else{& $image}
    if($LASTEXITCODE){throw 'Managed auto-client data probe failed.'}
}finally {
    $resolved=[IO.Path]::GetFullPath($temporary)
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(!$resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^iw7-managed-data-[0-9a-f]{32} path with spaces$'){throw 'Managed test cleanup boundary changed.'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
