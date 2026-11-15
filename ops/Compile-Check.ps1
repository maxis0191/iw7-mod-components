# Fast compile check (a34): compiles only the translation unit(s) you name, with the real project flags, and tells you
# the compiler errors in seconds instead of after a full client build (minutes). Run it before every full build.
#
#   pwsh -NoProfile -File ops/Compile-Check.ps1 -NativeRoot <native tree built once by Build-Voice> -Source src/native/agent_capacity.cpp
#
# What it does, in order (stops at the first failing step):
#   1. exports: ops/check_boundaries.py (tracked tree against product.json) and ops/compile_check_exports.py (every local file the
#      unit includes, .inc and .hpp too, is exported by product.json and listed by ops/Build-Voice.ps1; catches a new file that is
#      still untracked). A missing export entry fails here, not after a build.
#   2. sync: copies the unit and its local includes from src/native into <NativeRoot>/src/client/component when they differ.
#   3. compile: MSBuild client.vcxproj /t:ClCompile /p:SelectedFiles=<units>: the project's own flags, include paths, precompiled
#      header and warnings-as-errors (a raw newline in a string, a variable hiding an engine global are errors here too).
# Exit 0 ok, 1 export check refused, 2 compile errors (printed, at most -MaxErrors), 3 the tree is not ready or is in use.
# The native tree must have been built once with ops/Build-Voice.ps1 (it holds the overlays and the premake project). Do not run
# this on a tree while a full build of the same tree runs: it refuses when it sees one.
param([Parameter(Mandatory)][string[]]$Source,
    [Parameter(Mandatory)][string]$NativeRoot,
    [string]$Configuration = 'Release',
    [int]$MaxErrors = 15)
$ErrorActionPreference = 'Stop'
$watch = [Diagnostics.Stopwatch]::StartNew()
$repo = Split-Path $PSScriptRoot -Parent
$root = (Resolve-Path -LiteralPath $NativeRoot).Path
function Phase([string]$name, [scriptblock]$body) { $t = $watch.Elapsed.TotalSeconds; & $body; Write-Output ('compile-check: {0} {1:N1} s' -f $name, ($watch.Elapsed.TotalSeconds - $t)) }

$units = @($Source | ForEach-Object { ($_ -replace '\\', '/') -replace '^\./', '' })
foreach ($unit in $units) {
    if ($unit -notmatch '^(src/native/)?[A-Za-z0-9_./-]+\.cpp$') { throw "Source must be a .cpp of src/native: $unit" }
    if (!(Test-Path -LiteralPath (Join-Path $repo ($unit -replace '^(?!src/native/)', 'src/native/')))) { throw "Source not found: $unit" }
}
$names = @($units | ForEach-Object { $_ -replace '^src/native/', '' })

# 1. exports
Phase 'exports' {
    & python -B (Join-Path $PSScriptRoot 'check_boundaries.py') $repo
    if ($LASTEXITCODE) { Write-Output 'compile-check: REFUSED (product ownership gate, see above)'; exit 1 }
    & python -B (Join-Path $PSScriptRoot 'compile_check_exports.py') $repo @($names | ForEach-Object { "src/native/$_" })
    if ($LASTEXITCODE) { Write-Output 'compile-check: REFUSED (export or build list, see above)'; exit 1 }
}

# the tree
$project = Join-Path $root 'build/client.vcxproj'
$component = Join-Path $root 'src/client/component'
if (!(Test-Path -LiteralPath $project) -or !(Test-Path -LiteralPath $component)) { Write-Output "compile-check: $root is not a built native tree (no build/client.vcxproj): run ops/Build-Voice.ps1 once on it"; exit 3 }
$busy = @(Get-CimInstance Win32_Process -Filter "Name='MSBuild.exe' OR Name='cl.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -and $_.CommandLine.Replace('/', '\').IndexOf($root.Replace('/', '\'), [StringComparison]::OrdinalIgnoreCase) -ge 0 })
if ($busy.Count) { Write-Output "compile-check: a build of $root is running (pid $($busy[0].ProcessId)); not touching its tree"; exit 3 }
$tree = [IO.File]::ReadAllText($project)
foreach ($name in $names) {
    if ($tree.IndexOf("component\$name", [StringComparison]::OrdinalIgnoreCase) -lt 0 -and $tree.IndexOf("component/$name", [StringComparison]::OrdinalIgnoreCase) -lt 0) {
        Write-Output "compile-check: $name is not in the tree's project: build the tree once with the switch that compiles it (ops/Build-Voice.ps1 ... -AgentCapacity etc.)"; exit 3
    }
}

# 2. sync the unit and every local include into the tree
$synced = 0
Phase 'sync' {
    $closure = & python -B -c @'
import sys
sys.path.insert(0, sys.argv[1] + '/ops')
from pathlib import Path
import compile_check_exports as c
seen = []
for u in sys.argv[2:]:
    order, _ = c.closure(Path(sys.argv[1]) / 'src' / 'native', u)
    seen += [o for o in order if o not in seen]
print('\n'.join(seen))
'@ $repo @($names)
    foreach ($file in @($closure | Where-Object { $_ })) {
        $from = Join-Path $repo "src/native/$file"
        $to = Join-Path $component $file
        if (!(Test-Path -LiteralPath $to) -or (Get-FileHash -LiteralPath $from).Hash -ne (Get-FileHash -LiteralPath $to).Hash) {
            Copy-Item -LiteralPath $from -Destination $to -Force; $script:synced++
        }
    }
    Write-Output "compile-check: $script:synced file(s) copied into the tree"
}

# 3. compile
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$installation = & $vswhere -products '*' -version '[17.0,18.0)' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Select-Object -First 1
if (!$installation) { Write-Output 'compile-check: VS 2022 C++ toolchain not found'; exit 3 }
# SelectedFiles must be written as the project writes its items (relative to build/): an absolute path selects nothing. ONE unit a
# MSBuild call: a list "a.cpp;b.cpp" selects nothing (msbuild says "All outputs are up-to-date" and the check reports OK although
# the sources are never compiled; found by a40 with a deliberate syntax error in the second unit).
$log = Join-Path ([IO.Path]::GetTempPath()) ('compile-check-' + [guid]::NewGuid().ToString('N') + '.log')
$code = 0
Phase 'compile' {
    foreach ($name in $names) {
        $selected = '..\src\client\component\' + ($name -replace '/', '\')
        & "$installation/MSBuild/Current/Bin/MSBuild.exe" $project /t:ClCompile "/p:Configuration=$Configuration" /p:Platform=x64 "/p:SelectedFiles=$selected" /p:BuildProjectReferences=false /nr:false /m:1 /v:minimal "/flp:logfile=$log;verbosity=minimal;encoding=UTF-8;append" *> $null
        if ($LASTEXITCODE) { $script:code = $LASTEXITCODE }
    }
}
if ($code) {
    $errors = @(Select-String -LiteralPath $log -Pattern '\berror\s+[A-Z]+\d+|fatal error' | ForEach-Object { ($_.Line -replace '\s*\[[^\]]*\.vcxproj\]\s*$', '').Trim() } | Select-Object -Unique)
    Write-Output ('compile-check: COMPILE FAILED, {0} error line(s); first {1}:' -f $errors.Count, [Math]::Min($errors.Count, $MaxErrors))
    $errors | Select-Object -First $MaxErrors | ForEach-Object { '  ' + $_.Substring(0, [Math]::Min(300, $_.Length)) }
    if (!$errors.Count) { Get-Content -LiteralPath $log -Tail 15 }
    Write-Output ('compile-check: total {0:N1} s (log {1})' -f $watch.Elapsed.TotalSeconds, $log)
    exit 2
}
Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
Write-Output ('compile-check: OK, {0} unit(s) compile; total {1:N1} s' -f $names.Count, $watch.Elapsed.TotalSeconds)
exit 0
