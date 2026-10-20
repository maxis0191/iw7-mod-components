param([Parameter(Mandatory)][string]$PackageRoot,[Parameter(Mandatory)][string]$Output)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$manifest=Get-Content -LiteralPath (Join-Path $PackageRoot 'build-manifest.json') -Raw|ConvertFrom-Json
$image=Join-Path $PackageRoot 'iw7-mod.exe'
if($manifest.Schema -cne 'iw7.standard-client-build/1' -or $manifest.AutomaticProfiles -ne $true -or
   $manifest.Capacity64Capability -ne $true -or $manifest.OwnerCheatsEnabled -ne $false -or
   (Get-FileHash -LiteralPath $image).Hash -cne $manifest.SHA256 -or
   (Get-FileHash -LiteralPath "$PSScriptRoot/auto-capacity/Overlay.Core.ps1").Hash -cne $manifest.AutoProfileRecipeSHA256){throw 'Reviewed automatic client build provenance required.'}
foreach($row in $manifest.AutoProfileOverlay.Added){if((Get-FileHash -LiteralPath (Join-Path $repo ('src/native/'+[IO.Path]::GetFileName($row.Path)))).Hash -cne $row.SHA256){throw 'Compiled automatic client component differs.'}}
$Output=[IO.Path]::GetFullPath($Output)
if(Test-Path -LiteralPath $Output){throw 'Fresh one-file player delivery output required.'}
[IO.Directory]::CreateDirectory($Output)|Out-Null
$payload=Join-Path $Output 'client.gz'
$input=[IO.File]::OpenRead($image);$target=[IO.File]::Open($payload,'CreateNew','Write','None');$gzip=[IO.Compression.GZipStream]::new($target,[IO.Compression.CompressionLevel]::Optimal)
try{$input.CopyTo($gzip)}finally{$gzip.Dispose();$target.Dispose();$input.Dispose()}
[IO.File]::WriteAllText((Join-Path $Output 'client.sha256'),$manifest.SHA256,[Text.UTF8Encoding]::new($false))
. "$PSScriptRoot/Resource-Scheduler.Core.ps1"
Invoke-IW7ResourceJob -Scope $repo -Owner 'Single-file automatic client onboarding build' -PhysicalBytes 1GB -CommitBytes 1GB -Body {
    $compiler=Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
    $result=Join-Path $Output 'IW7-Paris.exe'
    & $compiler /nologo /target:winexe /platform:x64 /optimize+ /warnaserror+ /r:System.Windows.Forms.dll /r:System.IO.Compression.dll "/resource:$payload,client.gz" "/resource:$Output/client.sha256,client.sha256" "/out:$result" "$repo/src/bootstrap/AutoClient.cs"
    if($LASTEXITCODE){throw 'Automatic client onboarding compilation failed.'}
    @{Schema='iw7.auto-client-delivery/1';File='IW7-Paris.exe';SHA256=(Get-FileHash $result).Hash;ClientSHA256=$manifest.SHA256;BuildReceiptSHA256=(Get-FileHash (Join-Path $PackageRoot 'build-manifest.json')).Hash;BootstrapSourceSHA256=(Get-FileHash "$repo/src/bootstrap/AutoClient.cs").Hash;Bytes=(Get-Item $result).Length;DistributionBoundary='First execution or community distributor update required; no manual archive extraction.'}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $Output 'delivery.json')
    Write-Output "One-file automatic onboarding: $result"
}
