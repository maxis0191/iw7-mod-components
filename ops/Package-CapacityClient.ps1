param([Parameter(Mandatory)][string]$PackageRoot,[Parameter(Mandatory)][string]$Output)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$PackageRoot=(Resolve-Path -LiteralPath $PackageRoot).Path
$Output=[IO.Path]::GetFullPath($Output)
if(Test-Path -LiteralPath $Output){throw 'A fresh distribution output is required.'}
$receipt=Join-Path $PackageRoot 'build-manifest.json'
$m=Get-Content -LiteralPath $receipt -Raw|ConvertFrom-Json
$exe=Join-Path $PackageRoot 'iw7-mod.exe'
if($m.Schema -cne 'iw7.standard-client-build/1' -or
   $m.NativeRevision -cne 'a99c04937513530648573fd4ca2a05321a90b4a5' -or
   $m.Capacity64Capability -isnot [bool] -or !$m.Capacity64Capability -or
   $m.CapacityWireContract -cne '64-v3' -or !$m.CapacityBuild.Compiled -or !$m.CapacityBuild.PortOnly -or
   $m.SHA256 -cnotmatch '^[A-Fa-f0-9]{64}$' -or (Get-FileHash -LiteralPath $exe).Hash -cne $m.SHA256){throw 'Matched standard capacity executable provenance required.'}
foreach($name in @('paris_agent_capacity.cpp','paris_agent_capacity.hpp')){
    $rows=@($m.CapacityBuild.SourceHashes|Where-Object File -CEQ $name)
    if($rows.Count -ne 1 -or $rows[0].SHA256 -cne (Get-FileHash -LiteralPath "$repo/src/native/$name").Hash){throw 'Distribution port differs from reviewed compiled source.'}
}
if($m.CapacityPeerHelperSHA256 -cne (Get-FileHash -LiteralPath "$PSScriptRoot/agent-capacity/Peer-Overlay.Core.ps1").Hash){throw 'Distribution peer recipe differs.'}
$launcher=Join-Path $repo 'config/Launch-IW7-Paris48.bat'
$text=[IO.File]::ReadAllText($launcher)
if(!$text.Contains('iw7-paris48.exe') -or !$text.Contains('-paris-capacity-64 -paris-capacity-production')){throw 'Matched sidecar launcher required.'}
$folder=Join-Path $Output 'IW7-Paris48'
[IO.Directory]::CreateDirectory($folder)|Out-Null
Copy-Item -LiteralPath $exe -Destination "$folder/iw7-paris48.exe"
Copy-Item -LiteralPath $launcher -Destination $folder
Copy-Item -LiteralPath $receipt -Destination "$folder/BUILD-RECEIPT.json"
@'
Extract these files beside your existing IW7 game files, then run Launch-IW7-Paris48.bat.
This client supports the Paris 48-zombie server. All players joining that server need this update.
Keep your existing iw7-mod.exe and usual launcher for ordinary servers.
No game assets, saved profile, keys or bank data are included or replaced.
'@|Set-Content -LiteralPath "$folder/README.txt" -Encoding utf8
$manifest=[ordered]@{Schema='iw7.capacity-client-distribution/1';WireContract='64-v3';Ordinary=48;SpecialHeadroom=16;Executable='iw7-paris48.exe';SHA256=$m.SHA256;OriginalBuildReceiptSHA256=(Get-FileHash $receipt).Hash;LauncherSHA256=(Get-FileHash $launcher).Hash;RecipeSHA256=(Get-FileHash $PSCommandPath).Hash;BuiltUtc=$m.BuiltUtc;PackagedUtc=[datetime]::UtcNow.ToString('o');GameplayAcceptance='See linked server validation; owner and WAN acceptance remain separate.'}
$manifest|ConvertTo-Json -Depth 5|Set-Content -LiteralPath "$folder/distribution-manifest.json"
if((Get-FileHash "$folder/iw7-paris48.exe").Hash -cne $m.SHA256){throw 'Distribution executable hash differs.'}
$archive=Join-Path $Output 'IW7-Paris48.zip'
[IO.Compression.ZipFile]::CreateFromDirectory($folder,$archive)
@{Archive=$archive;SHA256=(Get-FileHash $archive).Hash;Bytes=(Get-Item $archive).Length;ExecutableSHA256=$m.SHA256}|ConvertTo-Json
