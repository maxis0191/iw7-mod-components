$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# ops/build/Build-Integrity.Core.ps1 and the time rule of Restore-IW7SourceTimes: a stale object must never be taken for a current one.
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('integrity-' + [guid]::NewGuid().ToString('N'))
$env:IW7_BUILD_CACHE = Join-Path $tmp 'cache'
function Assert([bool]$c, [string]$m) { if (!$c) { throw "build_integrity_test: $m" } }
try {
    . (Join-Path $root 'ops/build/Build-Cache.Core.ps1')
    . (Join-Path $root 'ops/build/Build-Integrity.Core.ps1')
    $tree = Join-Path $tmp 'tree'
    New-Item -ItemType Directory -Force -Path (Join-Path $tree 'src/client/component'), (Join-Path $tree 'build/obj/x64/Release/client') | Out-Null
    $cap = Join-Path $tree 'src/client/component/agent_capacity.cpp'; $other = Join-Path $tree 'src/client/component/other.cpp'; $hdr = Join-Path $tree 'src/client/component/x.hpp'
    Set-Content -LiteralPath $cap -Value 'old code'; Set-Content -LiteralPath $other -Value 'other'; Set-Content -LiteralPath $hdr -Value 'h'
    # --- the output of MSBuild ---
    $names = Get-IW7CompiledUnitNames -MsbuildOutput @('  agent_capacity.cpp', '  other.cpp', 'client.vcxproj -> C:\x\iw7-mod.exe', '  Generating code', '  zlib.c')
    Assert (($names | Sort-Object) -join ',' -ceq 'agent_capacity.cpp,other.cpp,zlib.c') "unit names: $($names -join ',')"
    # --- a good build, then a source changes: it must be proven compiled ---
    $h0 = Get-IW7SourceHashes -NativeRoot $tree
    Assert (@(Get-IW7UnprovenUnits -NativeRoot $tree -Current $h0).Count -eq 2) 'without a record of a good build every unit is unproven'
    Set-IW7GoodBuild -NativeRoot $tree -Current $h0
    Assert (@(Get-IW7UnprovenUnits -NativeRoot $tree -Current $h0).Count -eq 0) 'right after a good build nothing is unproven'
    Set-Content -LiteralPath $cap -Value 'NEW code'
    $h1 = Get-IW7SourceHashes -NativeRoot $tree
    $u = @(Get-IW7UnprovenUnits -NativeRoot $tree -Current $h1)
    Assert ($u.Count -eq 1 -and $u[0] -ceq 'src/client/component/agent_capacity.cpp') 'the changed unit is unproven'
    # a run that compiled it (even a failed run) proves it, by the hash it was compiled from
    Add-IW7CompiledProof -NativeRoot $tree -Current $h1 -CompiledNames @('agent_capacity.cpp')
    Assert (@(Get-IW7UnprovenUnits -NativeRoot $tree -Current $h1).Count -eq 0) 'a compiled unit is proven'
    # the source changes again after that run: the old proof does not cover the new bytes
    Set-Content -LiteralPath $cap -Value 'NEWER code'
    $h2 = Get-IW7SourceHashes -NativeRoot $tree
    Assert (@(Get-IW7UnprovenUnits -NativeRoot $tree -Current $h2).Count -eq 1) 'a proof of other bytes is no proof'
    # objects of unproven units are dropped
    Set-Content -LiteralPath (Join-Path $tree 'build/obj/x64/Release/client/agent_capacity.obj') -Value 'stale'
    Set-Content -LiteralPath (Join-Path $tree 'build/obj/x64/Release/client/other.obj') -Value 'keep'
    Assert ((Remove-IW7UnitObjects -NativeRoot $tree -Units @('src/client/component/agent_capacity.cpp')) -eq 1 -and !(Test-Path (Join-Path $tree 'build/obj/x64/Release/client/agent_capacity.obj')) -and (Test-Path (Join-Path $tree 'build/obj/x64/Release/client/other.obj'))) 'only the object of the unproven unit is dropped'
    Set-IW7GoodBuild -NativeRoot $tree -Current $h2
    Assert (!(Test-Path (Join-Path $tree '.iw7-compiled-since-good.json'))) 'a good build starts the compiled list again'
    # --- the time rule: this is a89's case ---
    Save-IW7SourceTimes -NativeRoot $tree            # the record: 'NEWER code' at its time
    (Get-Item $cap).LastWriteTimeUtc = [datetime]'2026-01-01'      # the time the workspace file carried since its checkout, older than any object
    Set-Content -LiteralPath $cap -Value 'workspace code'          # different bytes ...
    (Get-Item $cap).LastWriteTimeUtc = [datetime]'2026-01-01'      # ... with an old time (Copy-Item keeps the source's time)
    $r = Restore-IW7SourceTimes -NativeRoot $tree
    Assert ((Get-Item $cap).LastWriteTimeUtc -gt [datetime]::UtcNow.AddMinutes(-5)) "changed bytes with an old time must get the time of now: $((Get-Item $cap).LastWriteTimeUtc)"
    Assert ($r.Changed -eq 1) 'one changed file'
    Save-IW7SourceTimes -NativeRoot $tree
    (Get-Item $other).LastWriteTimeUtc = [datetime]'2026-02-02'    # same bytes, other time (a new workspace)
    $r = Restore-IW7SourceTimes -NativeRoot $tree
    Assert ((Get-Item $other).LastWriteTimeUtc -ne [datetime]'2026-02-02' -and $r.Kept -ge 1) 'same bytes get the recorded time back'
    'build_integrity_test: ok'
} finally {
    Remove-Item Env:IW7_BUILD_CACHE -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
