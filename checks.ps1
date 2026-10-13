param([Parameter(Mandatory)][string]$Workspace,[string]$Output)
$ErrorActionPreference='Stop'
$root=$PSScriptRoot
$Workspace=(Resolve-Path -LiteralPath $Workspace).Path
if(!$Output){$Output=Join-Path $root ('runtime/checks-'+[guid]::NewGuid().ToString('N'))}
$recipe=Join-Path $root 'ops/check_product.py'
if(!(Test-Path -LiteralPath $recipe)){
    $lock=Get-Content -LiteralPath (Join-Path $root 'dependency-package.json') -Raw | ConvertFrom-Json
    $recipe=Join-Path $root ('runtime/bootstrap/'+$lock.sha256+'/check_product.py')
}
& python -B (Join-Path (Split-Path $recipe -Parent) 'check_boundaries.py') $root
if($LASTEXITCODE){throw 'Product ownership gate failed.'}
& python -B $recipe --project $root --workspace $Workspace --output $Output
if($LASTEXITCODE){throw 'Source checks failed. See the retained results.json and logs.'}
