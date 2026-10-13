param([Parameter(Mandatory)][string]$Root)
$ErrorActionPreference='Stop'
$Root=[IO.Path]::GetFullPath($Root).TrimEnd('/','\')
$receipt=Join-Path $Root 'source-workspace.json'
if(Test-Path -LiteralPath $receipt){
    & python -B (Join-Path $Root 'ops/source_workspace.py') --output $Root --verify | Out-Null
    if($LASTEXITCODE){throw 'Source input verification failed.'}
    $source=Get-Content -LiteralPath $receipt -Raw | ConvertFrom-Json
    [pscustomobject]@{Commit=$source.revisions.($source.product);Dirty=$false;Product=$source.product;Revisions=$source.revisions;ReceiptSHA256=(Get-FileHash -LiteralPath $receipt).Hash}
}else{
    $top=& git -C $Root rev-parse --show-toplevel
    if($LASTEXITCODE -or [IO.Path]::GetFullPath($top).TrimEnd('/','\') -ine $Root){throw 'An exact canonical Git root or verified source workspace is required.'}
    $commit=(& git -C $Root rev-parse HEAD).Trim()
    [pscustomobject]@{Commit=$commit;Dirty=[bool](& git -C $Root status --porcelain);Product='legacy-canonical-checkout';Revisions=@{};ReceiptSHA256=$null}
}
