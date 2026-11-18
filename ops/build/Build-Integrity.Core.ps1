# Build integrity: a binary stored in the package cache must be built from the sources of its key (18 Nov 2026).
#
# What went wrong: the shared native tree held an object (16:06) newer than the changed source (16:02, the time its workspace file
# had since the checkout: Copy-Item keeps the source's time). MSBuild decides by file times, skipped the compile, the exe lacked the new
# code, and the package was stored under the key of the new sources and returned again.
#
# Two layers:
#  1. A source whose bytes differ from what the tree last built gets the time of NOW (Restore-IW7SourceTimes), whatever time its file
#     carries: it is newer than every object that exists. Only bytes equal to the last record get the recorded old time back.
#  2. A build is stored only when its own log proves it: every translation unit whose bytes differ from the last GOOD build (a build
#     that succeeded and passed this check) was compiled, in this build or in a failed build since that good one (units compiled
#     by a failed build are remembered with the hash of the source they were compiled from). A unit missing from that proof has its
#     object deleted and MSBuild runs once more; if it is still missing the build fails and nothing is stored.
#
# Files in the tree root: .iw7-source-good.json (hash of every source at the last good build), .iw7-compiled-since-good.json
# (translation unit -> source hash, compiled since then). Objects are matched by file name (MSBuild's minimal log prints the name only).

function Get-IW7SourceHashes {
    param([Parameter(Mandatory)][string]$NativeRoot)
    $map = @{}
    foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $NativeRoot 'src') -Recurse -File)) {
        $rel = [IO.Path]::GetRelativePath($NativeRoot, $f.FullName).Replace('\', '/')
        $map[$rel] = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA1).Hash
    }
    $map
}

function Read-IW7HashFile([string]$Path) {
    $h = @{}
    if (Test-Path -LiteralPath $Path) {
        try { foreach ($p in (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json).PSObject.Properties) { $h[$p.Name] = [string]$p.Value } } catch { $h = @{} }
    }
    $h
}

function Write-IW7HashFile([string]$Path, $Map) {
    $o = [ordered]@{}; foreach ($k in ($Map.Keys | Sort-Object)) { $o[$k] = $Map[$k] }
    $o | ConvertTo-Json | Set-Content -LiteralPath $Path -Encoding UTF8
}

# The compile units named in the output of an MSBuild run (lines that are only a source file name).
function Get-IW7CompiledUnitNames {
    param([string[]]$MsbuildOutput)
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($line in $MsbuildOutput) {
        if ($line -match '^\s+([A-Za-z0-9_.+-]+\.(?:cpp|cc|cxx|c))\s*$') { [void]$names.Add($Matches[1]) }
    }
    @($names)
}

# Units (by relative path) whose bytes differ from the last good build, or all of them when there was none.
function Get-IW7UnitsToProve {
    param([Parameter(Mandatory)][string]$NativeRoot, [Parameter(Mandatory)]$Current)
    $good = Read-IW7HashFile (Join-Path $NativeRoot '.iw7-source-good.json')
    $units = foreach ($rel in $Current.Keys) {
        if ($rel -notmatch '\.(cpp|cc|cxx|c)$') { continue }
        if (!$good.ContainsKey($rel) -or $good[$rel] -ne $Current[$rel]) { $rel }
    }
    @($units)
}

# After an MSBuild run (successful or not): remember what it compiled, with the hash of each unit's source.
function Add-IW7CompiledProof {
    param([Parameter(Mandatory)][string]$NativeRoot, [Parameter(Mandatory)]$Current, [string[]]$CompiledNames)
    $path = Join-Path $NativeRoot '.iw7-compiled-since-good.json'
    $proof = Read-IW7HashFile $path
    foreach ($rel in $Current.Keys) {
        if ($CompiledNames -contains [IO.Path]::GetFileName($rel)) { $proof[$rel] = $Current[$rel] }
    }
    Write-IW7HashFile $path $proof
}

# Units that differ from the last good build and are not proven compiled from their present bytes.
function Get-IW7UnprovenUnits {
    param([Parameter(Mandatory)][string]$NativeRoot, [Parameter(Mandatory)]$Current)
    $proof = Read-IW7HashFile (Join-Path $NativeRoot '.iw7-compiled-since-good.json')
    @(Get-IW7UnitsToProve -NativeRoot $NativeRoot -Current $Current | Where-Object { !$proof.ContainsKey($_) -or $proof[$_] -ne $Current[$_] })
}

# Delete the objects of these units so MSBuild must compile them.
function Remove-IW7UnitObjects {
    param([Parameter(Mandatory)][string]$NativeRoot, [string[]]$Units)
    $removed = 0
    foreach ($rel in $Units) {
        $base = [IO.Path]::GetFileNameWithoutExtension($rel)
        foreach ($o in @(Get-ChildItem -LiteralPath (Join-Path $NativeRoot 'build/obj') -Recurse -File -Filter "$base.obj" -ErrorAction SilentlyContinue)) { Remove-Item -LiteralPath $o.FullName -Force; $removed++ }
    }
    $removed
}

# The build passed its proof: this is the new good state and the compiled list starts again.
function Set-IW7GoodBuild {
    param([Parameter(Mandatory)][string]$NativeRoot, [Parameter(Mandatory)]$Current)
    Write-IW7HashFile (Join-Path $NativeRoot '.iw7-source-good.json') $Current
    Remove-Item -LiteralPath (Join-Path $NativeRoot '.iw7-compiled-since-good.json') -Force -ErrorAction SilentlyContinue
}
