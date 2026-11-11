param([Parameter(Mandatory)][string]$Workspace,[string]$Output,[string[]]$Only=@())
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
# -Only <id>[,<id>...] runs the named checks alone (a re-run after a fix); a head is judged by the full run.
$selection=@(foreach($id in $Only){'--only';$id})
& python -B $recipe --project $root --workspace $Workspace --output $Output @selection
if($LASTEXITCODE){
    $resultsPath=Join-Path $Output 'results.json'
    if(Test-Path -LiteralPath $resultsPath){
        $results=Get-Content -LiteralPath $resultsPath -Raw | ConvertFrom-Json
        foreach($failure in @($results.results | Where-Object exit_code -NE 0)){
            Write-Output ("Failed source check: "+$failure.id)
            Get-Content -LiteralPath (Join-Path $Output $failure.log) -Tail 100
        }
    }
    throw 'Source checks failed. See the retained results.json and logs.'
}
