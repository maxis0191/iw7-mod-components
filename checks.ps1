param([string]$Workspace,[string]$Output,[string[]]$Only=@(),[switch]$SortExports)
$ErrorActionPreference='Stop'
$root=$PSScriptRoot
# product.json "exports" stays sorted, one path a line: two branches that add files then change different lines and
# merge without a conflict. -SortExports puts the list in order; inside a conflicted merge it keeps every path of both
# sides that exists on disk, which resolves the conflict. Nothing else in the file is touched.
$exportsOrder=@'
import os, re, sys
root, mode = sys.argv[1], sys.argv[2]
path = os.path.join(root, 'product.json')
raw = open(path, 'rb').read()
text = raw.decode('utf-8-sig')
m = re.search(r'("exports"\s*:\s*\[\n)(.*?)(\n[ \t]*\])', text, re.S)
if not m:
    sys.exit('product.json: no "exports" list')
body = m.group(2).split('\n')
paths, marked, bad = [], False, []
for line in body:
    s = line.strip()
    if re.match(r'^(<{7}|\|{7}|={7}|>{7})', s):
        marked = True
        continue
    g = re.match(r'^"([^"\\]+)",?$', s)
    if g:
        paths.append(g.group(1))
    elif s:
        bad.append(s)
if bad:
    sys.exit('product.json exports: unexpected line ' + bad[0])
if re.search(r'^(<{7}|={7}|>{7})', text[:m.start()] + text[m.end():], re.M):
    sys.exit('product.json has conflict markers outside "exports": resolve those by hand first')
want = sorted(set(paths))
if marked:
    want = [p for p in want if os.path.isfile(os.path.join(root, p))]
if mode == 'check':
    if marked or paths != want:
        wrong = next((p for p, q in zip(paths, want) if p != q), 'a repeated path')
        sys.exit('product.json exports are not in sorted order (first out of place: %s)' % wrong)
    sys.exit(0)
indent = re.match(r'^[ \t]*', next((l for l in body if l.strip().startswith('"')), '    ')).group(0)
new = '\n'.join(indent + '"' + p + '"' + (',' if i < len(want) - 1 else '') for i, p in enumerate(want))
text = text[:m.start(2)] + new + text[m.end(2):]
open(path, 'wb').write((b'\xef\xbb\xbf' if raw.startswith(b'\xef\xbb\xbf') else b'') + text.encode('utf-8'))
print('product.json: %d exports in sorted order' % len(want))
'@
$exportsOrder | & python -B - $root $(if($SortExports){'fix'}else{'check'})
if($LASTEXITCODE){throw 'product.json exports must stay sorted. Run: pwsh -NoProfile -File checks.ps1 -SortExports'}
if($SortExports){return}
if(!$Workspace){throw '-Workspace is required (or -SortExports alone).'}
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
