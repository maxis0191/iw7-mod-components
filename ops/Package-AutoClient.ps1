param([Parameter(Mandatory)][string]$PackageRoot,[Parameter(Mandatory)][string]$Output)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$manifest=Get-Content -LiteralPath (Join-Path $PackageRoot 'build-manifest.json') -Raw|ConvertFrom-Json
$image=Join-Path $PackageRoot 'iw7-mod.exe'
if($manifest.Schema -cne 'iw7.standard-client-build/1' -or $manifest.AutomaticProfiles -ne $true -or
   $manifest.Capacity64Capability -ne $true -or $manifest.OwnerCheatsEnabled -ne $false -or
   (Get-FileHash -LiteralPath $image).Hash -cne $manifest.SHA256 -or
   (Get-FileHash -LiteralPath "$PSScriptRoot/auto-capacity/Overlay.Core.ps1").Hash -cne $manifest.AutoProfileRecipeSHA256){throw 'Reviewed automatic client build provenance required.'}
if($manifest.AutoProfileOverlay.Schema -cne 'iw7.auto-capacity-overlay/1' -or @($manifest.AutoProfileOverlay.Added).Count -ne 3 -or @($manifest.AutoProfileOverlay.Files).Count -ne 5){throw 'Complete automatic profile composition required.'}
foreach($name in @('auto_capacity.cpp','auto_capacity.hpp','auto_capacity_policy.hpp','paris_agent_capacity.cpp','paris_agent_capacity.hpp')){
    $rows=@($manifest.NativeSourceHashes|Where-Object File -CEQ ('src/client/component/'+$name))
    if($rows.Count -ne 1 -or (Get-FileHash -LiteralPath (Join-Path $repo ('src/native/'+$name))).Hash -cne $rows[0].SHA256){throw 'Compiled automatic client component differs.'}
}
& python -B "$repo/tests/ops/auto_client_data_test.py"
if($LASTEXITCODE){throw 'Bundled community-data metadata is not qualified.'}
$Output=[IO.Path]::GetFullPath($Output)
if(Test-Path -LiteralPath $Output){throw 'Fresh one-file player delivery output required.'}
[IO.Directory]::CreateDirectory($Output)|Out-Null
$payload=Join-Path $Output 'client.gz'
$payloadInput=[IO.File]::OpenRead($image);$payloadTarget=[IO.File]::Open($payload,'CreateNew','Write','None');$gzip=[IO.Compression.GZipStream]::new($payloadTarget,[IO.Compression.CompressionLevel]::Optimal)
try{$payloadInput.CopyTo($gzip)}finally{$gzip.Dispose();$payloadTarget.Dispose();$payloadInput.Dispose()}
[IO.File]::WriteAllText((Join-Path $Output 'client.sha256'),$manifest.SHA256,[Text.UTF8Encoding]::new($false))
. "$PSScriptRoot/Resource-Scheduler.Core.ps1"
Invoke-IW7ResourceJob -Scope $repo -Owner 'Single-file automatic client onboarding build' -PhysicalBytes 1GB -CommitBytes 1GB -Body {
    $compiler=Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
    $result=Join-Path $Output 'IW7-Paris.exe'
    # Framework csc misresolves mixed slash paths, even when they are absolute.
    # Use normalized Windows paths and a response file for all embedded inputs.
    $response=Join-Path $Output 'compile.rsp'
    $lines=@('/nologo','/target:winexe','/platform:x64','/optimize+','/warnaserror+',
        '/r:System.Windows.Forms.dll','/r:System.IO.Compression.dll','/r:System.Web.Extensions.dll','/r:System.Management.dll',
        ('/resource:"'+[IO.Path]::GetFullPath((Join-Path $repo 'config/auto-client-data.json'))+'",community-data.json'),
        ('/resource:"'+[IO.Path]::GetFullPath($payload)+'",client.gz'),
        ('/resource:"'+[IO.Path]::GetFullPath((Join-Path $Output 'client.sha256'))+'",client.sha256'),
        ('/out:"'+[IO.Path]::GetFullPath($result)+'"'),
        ('"'+[IO.Path]::GetFullPath((Join-Path $repo 'src/bootstrap/AutoClient.cs'))+'"'))
    [IO.File]::WriteAllLines($response,$lines,[Text.UTF8Encoding]::new($true))
    & $compiler ('@'+$response)
    if($LASTEXITCODE){throw 'Automatic client onboarding compilation failed.'}
    @{Schema='iw7.auto-client-delivery/1';File='IW7-Paris.exe';SHA256=(Get-FileHash $result).Hash;ClientSHA256=$manifest.SHA256;BuildReceiptSHA256=(Get-FileHash (Join-Path $PackageRoot 'build-manifest.json')).Hash;BootstrapSourceSHA256=(Get-FileHash "$repo/src/bootstrap/AutoClient.cs").Hash;CommunityDataManifestSHA256=(Get-FileHash "$repo/config/auto-client-data.json").Hash;Bytes=(Get-Item $result).Length;DistributionBoundary='First execution or community distributor update required; no manual archive extraction.'}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $Output 'delivery.json')
    Write-Output "One-file automatic onboarding: $result"
}
