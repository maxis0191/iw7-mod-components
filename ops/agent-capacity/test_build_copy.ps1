$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. "$PSScriptRoot/Build-Copy.Core.ps1"
$root=Join-Path $repo ('runtime/capacity-copy-pure-'+[guid]::NewGuid().ToString('N'))
$components=Join-Path $root 'src/client/component'
$null=[IO.Directory]::CreateDirectory($components)
$enabled=Set-IW7CapacityWatchBuildCopy $repo $root $true
if(!$enabled.Compiled -or $enabled.Files.Count -ne 4){throw 'Isolated capacity source groups missing'}
foreach($row in $enabled.SourceHashes){if((Get-FileHash (Join-Path $components $row.File)).Hash -cne $row.SHA256){throw 'Copy integrity failed'}}
$disabled=Set-IW7CapacityWatchBuildCopy $repo $root $false
if($disabled.Compiled -or @(Get-ChildItem $components).Count){throw 'Ordinary profile still has watcher'}
$null=Set-IW7CapacityWatchBuildCopy $repo $root $true
$header=Join-Path $components 'paris_capacity_watch.hpp'
[IO.File]::AppendAllText($header,"`n// synthetic unknown edit`n")
$before=@(Get-ChildItem $components|ForEach-Object{(Get-FileHash $_.FullName).Hash})
foreach($enabled in @($false,$true)) {
    $refused=$false;try{$null=Set-IW7CapacityWatchBuildCopy $repo $root $enabled}catch{$refused=$true}
    if(!$refused){throw 'Unknown component accepted'}
    $after=@(Get-ChildItem $components|ForEach-Object{(Get-FileHash $_.FullName).Hash})
    if(($before -join ',') -cne ($after -join ',')){throw 'Preflight refusal mutated source pair'}
}
Write-Output "Capacity profile copies/hash/unknown-edit refusal passed; fixture retained: $root"
