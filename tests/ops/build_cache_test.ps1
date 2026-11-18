$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# The machine build cache (ops/build/Build-Cache.Core.ps1): input keys, package store and restore, pruning, the native
# test marker, content-addressed source times, the native tree pool. Runs on a temporary cache; compiles nothing.
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('bcache-' + [guid]::NewGuid().ToString('N'))
$env:IW7_BUILD_CACHE = Join-Path $tmp 'cache'
try {
    . (Join-Path $root 'ops/build/Build-Cache.Core.ps1')
    function Assert([bool]$c, [string]$m) { if (!$c) { throw "build_cache_test: $m" } }
    # --- a fake prepared workspace ---
    $ws = Join-Path $tmp 'ws'
    New-Item -ItemType Directory -Force -Path (Join-Path $ws 'src/native'), (Join-Path $ws 'docs') | Out-Null
    function Write-Ws([string]$native, [string]$doc) {
        Set-Content -LiteralPath (Join-Path $ws 'src/native/a.cpp') -Value $native
        Set-Content -LiteralPath (Join-Path $ws 'docs/x.md') -Value $doc
        $files = foreach ($p in 'src/native/a.cpp', 'docs/x.md') { @{ path = $p; sha256 = (Get-FileHash -LiteralPath (Join-Path $ws $p)).Hash; blob = 'x'; bytes = 1; owner = 'o'; commit = 'c' } }
        @{ schema = 'iw7.source-workspace/1'; product = 'p'; revisions = @{ 'iw7-mod-components' = 'c0ffee' }; files = @($files) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $ws 'source-workspace.json')
    }
    Write-Ws 'int a;' 'doc one'
    $k1 = Get-IW7NativeInputKey -WorkspaceRoot $ws -Switches @('ServerModules', 'Perf') -Pin 'pin1' -Toolchain 'tc1'
    Write-Ws 'int a;' 'doc two'
    $k2 = Get-IW7NativeInputKey -WorkspaceRoot $ws -Switches @('Perf', 'servermodules') -Pin 'pin1' -Toolchain 'tc1'
    Assert ($k1 -ceq $k2) 'a document change or the switch order changed the key'
    Write-Ws 'int b;' 'doc two'
    $k3 = Get-IW7NativeInputKey -WorkspaceRoot $ws -Switches @('ServerModules', 'Perf') -Pin 'pin1' -Toolchain 'tc1'
    Assert ($k3 -cne $k1) 'a source change kept the key'
    Assert ((Get-IW7NativeInputKey -WorkspaceRoot $ws -Switches @('ServerModules') -Pin 'pin1' -Toolchain 'tc1') -cne $k3) 'a switch change kept the key'
    Assert ((Get-IW7NativeInputKey -WorkspaceRoot $ws -Switches @('ServerModules', 'Perf') -Pin 'pin1' -Toolchain 'tc2') -cne $k3) 'a toolchain change kept the key'
    # --- package store and restore ---
    Assert ($null -eq (Get-IW7CachedPackage -Key $k3)) 'a package existed before it was stored'
    $built = Join-Path $tmp 'built'; New-Item -ItemType Directory -Force -Path $built | Out-Null
    Set-Content -LiteralPath (Join-Path $built 'a.exe') -Value 'EXE-BYTES'; Set-Content -LiteralPath (Join-Path $built 'a.pdb') -Value 'PDB-BYTES'
    '{"SHA256":"x","ProjectCommit":"c1"}' | Set-Content -LiteralPath (Join-Path $built 'm.json')
    $null = Save-IW7CachedPackage -Key $k3 -Exe (Join-Path $built 'a.exe') -Pdb (Join-Path $built 'a.pdb') -Manifest (Join-Path $built 'm.json') -ProjectCommit 'c1' -Switches @('ServerModules')
    $hit = Get-IW7CachedPackage -Key $k3
    Assert ($null -ne $hit) 'a stored package was not found'
    $ws2 = Join-Path $tmp 'ws2'
    $exe = Restore-IW7CachedPackage -WorkspaceRoot $ws2 -Package $hit -ProjectCommit 'c2'
    Assert ((Get-Content -LiteralPath $exe -Raw).Trim() -ceq 'EXE-BYTES') 'restored executable differs'
    $m = Get-Content -LiteralPath (Join-Path $ws2 'runtime/voice-package/build-manifest.json') -Raw | ConvertFrom-Json
    Assert ($m.CacheBuiltForProjectCommit -ceq 'c1' -and $m.CacheRestoredForProjectCommit -ceq 'c2') 'the manifest does not say where the client came from'
    Assert (Test-Path -LiteralPath (Join-Path $ws2 ('runtime/voice-symbols/' + $hit.Info.ExeSHA256 + '/iw7-mod.pdb'))) 'symbols were not restored'
    # a damaged cache entry is refused, not trusted
    Set-Content -LiteralPath (Join-Path $hit.Dir 'iw7-paris-voice.exe') -Value 'DAMAGED'
    Assert ($null -eq (Get-IW7CachedPackage -Key $k3)) 'a damaged package was trusted'
    # --- prune keeps the most recently used ---
    $null = Save-IW7CachedPackage -Key $k1 -Exe (Join-Path $built 'a.exe') -Pdb (Join-Path $built 'a.pdb') -Manifest (Join-Path $built 'm.json') -ProjectCommit 'c1' -Switches @()
    (New-Item -ItemType File -Path (Join-Path (Get-IW7BuildCacheRoot) "packages/$k1/used.stamp") -Force).LastWriteTimeUtc = [datetime]::UtcNow
    (Get-Item -LiteralPath (Join-Path (Get-IW7BuildCacheRoot) "packages/$k3/used.stamp")).LastWriteTimeUtc = [datetime]::UtcNow.AddDays(-3)
    $oneBytes = (Get-ChildItem -LiteralPath (Join-Path (Get-IW7BuildCacheRoot) "packages/$k1") -File | Measure-Object Length -Sum).Sum
    Invoke-IW7PackageCachePrune -MaxGB (($oneBytes + 10) / 1GB)
    Assert (Test-Path -LiteralPath (Join-Path (Get-IW7BuildCacheRoot) "packages/$k1")) 'prune removed the most recently used package'
    Assert (!(Test-Path -LiteralPath (Join-Path (Get-IW7BuildCacheRoot) "packages/$k3"))) 'prune kept the least recently used package over the cap'
    # --- test marker ---
    Assert (!(Test-IW7TestsPassed 'abc')) 'marker present before set'
    Set-IW7TestsPassed 'abc'
    Assert (Test-IW7TestsPassed 'abc') 'marker missing after set'
    # --- source times: same bytes get the recorded time back, changed bytes keep theirs ---
    $nr = Join-Path $tmp 'native'; New-Item -ItemType Directory -Force -Path (Join-Path $nr 'src') | Out-Null
    $f1 = Join-Path $nr 'src/one.cpp'; $f2 = Join-Path $nr 'src/two.cpp'
    Set-Content -LiteralPath $f1 -Value 'one'; Set-Content -LiteralPath $f2 -Value 'two'
    (Get-Item $f1).LastWriteTimeUtc = [datetime]'2026-01-01'; (Get-Item $f2).LastWriteTimeUtc = [datetime]'2026-01-01'
    Save-IW7SourceTimes -NativeRoot $nr
    Set-Content -LiteralPath $f1 -Value 'one'          # same bytes, new time (what a new workspace does)
    Set-Content -LiteralPath $f2 -Value 'two changed'  # really changed
    $r = Restore-IW7SourceTimes -NativeRoot $nr
    Assert ($r.Kept -eq 1 -and $r.Changed -eq 1) "kept $($r.Kept) changed $($r.Changed)"
    Assert ((Get-Item $f1).LastWriteTimeUtc -eq [datetime]'2026-01-01') 'the unchanged file did not get its time back'
    Assert ((Get-Item $f2).LastWriteTimeUtc -gt [datetime]'2026-06-01') 'the changed file lost its new time'
    Assert (!(Test-Path -LiteralPath (Join-Path $nr '.iw7-source-times.json'))) 'the record stayed after the restore; a failed build would trust it'
    # --- native tree pool: two builds get two trees, a third waits ---
    $pin = 'abcdef0123456789abcdef0123456789abcdef01'
    $t1 = Enter-IW7NativeTree -Pin $pin -Max 2 -WaitSeconds 5
    $t2 = Enter-IW7NativeTree -Pin $pin -Max 2 -WaitSeconds 5
    Assert ($t1.Path -cne $t2.Path) 'two builds got the same tree'
    $waited = $false; try { $null = Enter-IW7NativeTree -Pin $pin -Max 2 -WaitSeconds 1 } catch { $waited = $true }
    Assert $waited 'a third build got a tree while both were held'
    Exit-IW7NativeTree $t1
    $t3 = Enter-IW7NativeTree -Pin $pin -Max 2 -WaitSeconds 5
    Assert ($t3.Path -ceq $t1.Path) 'a released tree was not reused'
    Exit-IW7NativeTree $t2; Exit-IW7NativeTree $t3
    'build_cache_test: ok'
} finally {
    Remove-Item Env:IW7_BUILD_CACHE -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
