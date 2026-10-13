param([string]$Output,[string]$DependencyArchive,[string]$Entry,[string[]]$Arguments=@())
# Thin product adapter. Source composition is owned by iw7-mod-components.
$ErrorActionPreference='Stop'
$root=$PSScriptRoot
$product=Get-Content -LiteralPath (Join-Path $root 'product.json') -Raw | ConvertFrom-Json
$lock=Get-Content -LiteralPath (Join-Path $root 'dependency-package.json') -Raw | ConvertFrom-Json
$revision=(& git -C $root rev-parse HEAD).Trim()
if($LASTEXITCODE){throw 'A committed product checkout is required.'}
& git -C $root diff --quiet HEAD
if($LASTEXITCODE){throw 'Dirty tracked product sources refused.'}
if(!$Output){$Output=Join-Path $root ('runtime/source-'+$revision)}
$Output=[IO.Path]::GetFullPath($Output)
if(!$DependencyArchive){
    $cache=Join-Path $root ('runtime/source-dependencies/'+$lock.sha256)
    [IO.Directory]::CreateDirectory($cache) | Out-Null
    $DependencyArchive=Join-Path $cache $lock.name
    if(!(Test-Path -LiteralPath $DependencyArchive)){
        & gh release download $lock.tag --repo ('maxis0191/'+$product.id) --pattern $lock.name --dir $cache
        if($LASTEXITCODE){throw 'Pinned private source dependencies could not be downloaded.'}
    }
}
$DependencyArchive=(Resolve-Path -LiteralPath $DependencyArchive).Path
if((Get-Item -LiteralPath $DependencyArchive).Length -ne $lock.bytes -or
   (Get-FileHash -LiteralPath $DependencyArchive -Algorithm SHA256).Hash -ine $lock.sha256){throw 'Dependency archive identity differs.'}
$recipe=Join-Path $root 'ops/source_workspace.py'
if(!(Test-Path -LiteralPath $recipe)){
    # The archive digest is pinned in this reviewed repository. Extract only
    # these three fixed bootstrap sources, never arbitrary archive paths.
    $code=Join-Path $root ('runtime/bootstrap/'+$lock.sha256)
    [IO.Directory]::CreateDirectory($code) | Out-Null
    $zip=[IO.Compression.ZipFile]::OpenRead($DependencyArchive)
    try {
        foreach($name in @('source_workspace.py','check_product.py','check_boundaries.py')){
            $member=$zip.GetEntry('ops/'+$name)
            if(!$member -or $member.Length -gt 1MB){throw 'Complete pinned source bootstrap required.'}
            $target=Join-Path $code $name
            $stream=$member.Open();$buffer=[IO.MemoryStream]::new()
            try {$stream.CopyTo($buffer);$bytes=$buffer.ToArray()} finally {$stream.Dispose();$buffer.Dispose()}
            if(Test-Path -LiteralPath $target){
                $expected=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
                if((Get-FileHash -LiteralPath $target).Hash -cne $expected){throw 'Existing bootstrap changed; preserve it and use a fresh checkout.'}
            }else{
                $created=[IO.File]::Open($target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                try {$created.Write($bytes,0,$bytes.Length)} finally {$created.Dispose()}
            }
        }
    } finally {$zip.Dispose()}
    $recipe=Join-Path $code 'source_workspace.py'
}
if(Test-Path -LiteralPath $Output){
    & python -B $recipe --output $Output --verify
    if($LASTEXITCODE){throw 'Existing source workspace changed; preserve it and choose a fresh Output.'}
    $manifest=Get-Content -LiteralPath (Join-Path $Output 'source-workspace.json') -Raw | ConvertFrom-Json
    if($manifest.revisions.($product.id) -cne $revision){throw 'Existing source workspace belongs to another product revision.'}
}else{
    & python -B $recipe --project $root --revision $revision --output $Output --dependency-package $DependencyArchive
    if($LASTEXITCODE){throw 'Product source composition failed.'}
}
if($Entry){
    if($Entry -match '(^/|\\|:|(^|/)\.\.(/|$))'){throw 'Literal relative source entrypoint required.'}
    $target=[IO.Path]::GetFullPath((Join-Path $Output $Entry))
    if(!$target.StartsWith($Output+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Entry escaped source workspace.'}
    if([IO.Path]::GetExtension($target) -ne '.ps1'){throw 'Use the printed source workspace for non-PowerShell commands.'}
    $sourceManifest=Get-Content -LiteralPath (Join-Path $Output 'source-workspace.json') -Raw | ConvertFrom-Json
    if($Entry -cnotin $sourceManifest.files.path){throw 'Entrypoint is not a declared product source.'}
    & (Join-Path $PSHOME 'pwsh.exe') -NoLogo -NoProfile -File $target @Arguments
    if($LASTEXITCODE){throw 'Product entrypoint failed; preserve its receipts.'}
}
Write-Output $Output
