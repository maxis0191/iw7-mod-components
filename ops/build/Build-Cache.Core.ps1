# Machine-wide build cache shared by every worktree and every agent.
#
# What it holds (one folder, size capped, least recently used first):
#   packages/<key>/        a finished lab client (exe, pdb, manifest). The key is the SHA-256 of every input that can
#                          change the exe (see Get-IW7NativeInputKey), so a commit that was built anywhere is
#                          restored in a second by hard links.
#   tests-pass/<key>       the native unit tests passed for these test and source files: they are not compiled again.
#   native-trees/<pin>/    the native build tree (pinned upstream, submodules, objects, libraries): built in place by
#                          every build in turn, so it stays warm. Never copied (see Enter-IW7NativeTree).
#   source-dependencies/   the pinned source dependency archive (bootstrap.ps1), downloaded once per machine.
#
# Location: $env:IW7_BUILD_CACHE, default C:\IW7-Cache. Cap: $env:IW7_BUILD_CACHE_GB (default 40) for packages.
$script:IW7CacheDefault = 'C:\IW7-Cache'

function Get-IW7BuildCacheRoot {
    $root = $env:IW7_BUILD_CACHE
    if ([string]::IsNullOrWhiteSpace($root)) { $root = $script:IW7CacheDefault }
    $root = [IO.Path]::GetFullPath($root)
    [IO.Directory]::CreateDirectory($root) | Out-Null
    $root
}

function Get-IW7InputHash([string[]]$Lines) {
    $bytes = [Text.Encoding]::UTF8.GetBytes(($Lines -join "`n"))
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

# Paths of a prepared source workspace (source-workspace.json) that can change the client executable. Documents, tests
# and the creator tools are not inputs, so a change in them keeps the key. Everything under src and the build and
# overlay scripts are.
$script:IW7NativeInputPattern = '^(src/|ops/Build-Voice\.ps1$|ops/Build-StandardClient\.ps1$|ops/Apply-[^/]+$|ops/[^/]+\.Core\.ps1$|ops/agent-capacity/|ops/script-variables/|ops/standard-client/|ops/build/|client-profiles\.json$|product\.json$)'

function Get-IW7ToolchainId {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (!(Test-Path -LiteralPath $vswhere)) { return 'no-vswhere' }
    $inst = & $vswhere -products '*' -version '[17.0,18.0)' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Select-Object -First 1
    if (!$inst) { return 'no-vs' }
    $ver = & $vswhere -products '*' -version '[17.0,18.0)' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationVersion | Select-Object -First 1
    $tools = Get-ChildItem -LiteralPath (Join-Path $inst 'VC/Tools/MSVC') -Directory -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1
    "vs$ver+msvc$($tools.Name)"
}

function Get-IW7WorkspaceInputKey {
    param([Parameter(Mandatory)][string]$WorkspaceRoot, [Parameter(Mandatory)][string]$Pattern, [string[]]$Extra = @())
    $manifest = Get-Content -LiteralPath (Join-Path $WorkspaceRoot 'source-workspace.json') -Raw | ConvertFrom-Json
    $lines = @($manifest.files | Where-Object { $_.path -match $Pattern } | Sort-Object { $_.path } -CaseSensitive | ForEach-Object { "$($_.path)`t$($_.sha256)" })
    Get-IW7InputHash ($lines + @('--') + $Extra)
}

# The key of a lab client: every input of the executable and every switch that changes it.
function Get-IW7NativeInputKey {
    param([Parameter(Mandatory)][string]$WorkspaceRoot, [Parameter(Mandatory)][string[]]$Switches, [string]$Pin, [string]$Toolchain)
    $sw = (@($Switches | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique -CaseSensitive) -join '+')
    Get-IW7WorkspaceInputKey -WorkspaceRoot $WorkspaceRoot -Pattern $script:IW7NativeInputPattern -Extra @("switches=$sw", "pin=$Pin", "toolchain=$Toolchain", 'schema=1')
}

function New-IW7HardLinkOrCopy([string]$Path, [string]$Target) {
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    try { New-Item -ItemType HardLink -Path $Path -Target $Target -ErrorAction Stop | Out-Null }
    catch { Copy-Item -LiteralPath $Target -Destination $Path -Force }
}

function Get-IW7CachedPackage {
    param([Parameter(Mandatory)][string]$Key)
    $dir = Join-Path (Get-IW7BuildCacheRoot) "packages/$Key"
    $done = Join-Path $dir 'complete.json'
    if (!(Test-Path -LiteralPath $done)) { return $null }
    $info = Get-Content -LiteralPath $done -Raw | ConvertFrom-Json
    foreach ($f in 'iw7-paris-voice.exe', 'iw7-mod.pdb', 'build-manifest.json') { if (!(Test-Path -LiteralPath (Join-Path $dir $f))) { return $null } }
    # A cache entry is trusted only when its executable still has the recorded hash.
    if ((Get-FileHash -LiteralPath (Join-Path $dir 'iw7-paris-voice.exe')).Hash -ne $info.ExeSHA256) { return $null }
    [pscustomobject]@{ Dir = $dir; Info = $info }
}

# Put a cached client in this workspace: runtime/voice-package and runtime/voice-symbols/<sha>, hard links, no copy.
function Restore-IW7CachedPackage {
    param([Parameter(Mandatory)][string]$WorkspaceRoot, [Parameter(Mandatory)]$Package, [string]$ProjectCommit)
    $out = Join-Path $WorkspaceRoot 'runtime/voice-package'
    $sym = Join-Path $WorkspaceRoot ('runtime/voice-symbols/' + $Package.Info.ExeSHA256)
    New-Item -ItemType Directory -Path $out, $sym -Force | Out-Null
    New-IW7HardLinkOrCopy (Join-Path $out 'iw7-paris-voice.exe') (Join-Path $Package.Dir 'iw7-paris-voice.exe')
    New-IW7HardLinkOrCopy (Join-Path $sym 'iw7-paris-native-trace.exe') (Join-Path $Package.Dir 'iw7-paris-voice.exe')
    New-IW7HardLinkOrCopy (Join-Path $sym 'iw7-mod.pdb') (Join-Path $Package.Dir 'iw7-mod.pdb')
    # The manifest says what the executable was built from and that this workspace received it from the cache.
    $m = Get-Content -LiteralPath (Join-Path $Package.Dir 'build-manifest.json') -Raw | ConvertFrom-Json -AsHashtable
    $m.CacheKey = $Package.Info.Key
    $m.CacheRestoredUtc = [datetime]::UtcNow.ToString('o')
    $m.CacheBuiltForProjectCommit = $Package.Info.ProjectCommit
    $m.CacheRestoredForProjectCommit = $ProjectCommit
    $json = $m | ConvertTo-Json -Depth 8
    Set-Content -LiteralPath (Join-Path $out 'build-manifest.json') -Value $json -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $sym 'build-manifest.json') -Value $json -Encoding UTF8
    (New-Item -ItemType File -Path (Join-Path $Package.Dir 'used.stamp') -Force).LastWriteTimeUtc = [datetime]::UtcNow
    Join-Path $out 'iw7-paris-voice.exe'
}

# Store a finished client. Written to a temporary folder and renamed, so a reader never sees half of it.
function Save-IW7CachedPackage {
    param([Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][string]$Exe, [Parameter(Mandatory)][string]$Pdb, [Parameter(Mandatory)][string]$Manifest, [string]$ProjectCommit, [string[]]$Switches)
    $root = Join-Path (Get-IW7BuildCacheRoot) 'packages'
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $final = Join-Path $root $Key
    if (Test-Path -LiteralPath (Join-Path $final 'complete.json')) { return $final }
    $tmp = Join-Path $root ("$Key.tmp-$PID")
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    Copy-Item -LiteralPath $Exe -Destination (Join-Path $tmp 'iw7-paris-voice.exe')
    Copy-Item -LiteralPath $Pdb -Destination (Join-Path $tmp 'iw7-mod.pdb')
    Copy-Item -LiteralPath $Manifest -Destination (Join-Path $tmp 'build-manifest.json')
    $info = [ordered]@{ Key = $Key; ExeSHA256 = (Get-FileHash -LiteralPath (Join-Path $tmp 'iw7-paris-voice.exe')).Hash; ProjectCommit = $ProjectCommit; Switches = @($Switches); StoredUtc = [datetime]::UtcNow.ToString('o') }
    $info | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $tmp 'complete.json') -Encoding UTF8
    if (Test-Path -LiteralPath $final) { Remove-Item -LiteralPath $final -Recurse -Force }
    try { Move-Item -LiteralPath $tmp -Destination $final -ErrorAction Stop }
    catch { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    $final
}

# Keep the cache under its cap: the least recently used packages go first. A package a running game may read is a
# hard link in a workspace, and deleting the cache entry never touches that link.
function Invoke-IW7PackageCachePrune {
    param([double]$MaxGB = $(if ($env:IW7_BUILD_CACHE_GB) { [double]$env:IW7_BUILD_CACHE_GB } else { 40 }))
    $root = Join-Path (Get-IW7BuildCacheRoot) 'packages'
    if (!(Test-Path -LiteralPath $root)) { return }
    $items = @(Get-ChildItem -LiteralPath $root -Directory | ForEach-Object {
        $stamp = Join-Path $_.FullName 'used.stamp'
        $used = if (Test-Path -LiteralPath $stamp) { (Get-Item -LiteralPath $stamp).LastWriteTimeUtc } else { $_.LastWriteTimeUtc }
        $bytes = (Get-ChildItem -LiteralPath $_.FullName -File | Measure-Object Length -Sum).Sum
        [pscustomobject]@{ Dir = $_.FullName; Used = $used; Bytes = [long]$bytes }
    } | Sort-Object Used)
    $total = ($items | Measure-Object Bytes -Sum).Sum
    $cap = [long]($MaxGB * 1GB)
    foreach ($i in $items) {
        if ($total -le $cap) { break }
        Remove-Item -LiteralPath $i.Dir -Recurse -Force -ErrorAction SilentlyContinue
        $total -= $i.Bytes
    }
}

# ---- the native unit tests ----
# Build-Voice compiles and runs about twenty unit tests (one cl.exe each, one after the other: about 85 s) before every
# build. A test is a function of its own source, the headers it can include (tests/native and src/native) and its
# compiler line, so a change of a component's .cpp file or of a script leaves every test as it was. Test results are
# kept by that hash in the cache; the passed ones are left out of the generated command file.
function Test-IW7TestsPassed([string]$Key) { Test-Path -LiteralPath (Join-Path (Get-IW7BuildCacheRoot) "tests-pass/$Key") }
function Set-IW7TestsPassed([string]$Key) {
    $d = Join-Path (Get-IW7BuildCacheRoot) 'tests-pass'
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $d $Key) -Value ([datetime]::UtcNow.ToString('o'))
}

function Select-IW7UnitTests {
    param([Parameter(Mandatory)][string]$Script, [Parameter(Mandatory)][string]$Repo, [string]$Toolchain)
    $headerFiles = @(Get-ChildItem -LiteralPath (Join-Path $Repo 'src/native'), (Join-Path $Repo 'tests/native') -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.hpp', '.h', '.inc' } | Sort-Object FullName)
    $headerHash = Get-IW7InputHash @($headerFiles | ForEach-Object { "$($_.Name)`t$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)" })
    $lines = @($Script -split "`r?`n")
    $out = [Collections.Generic.List[string]]::new()
    $keys = [Collections.Generic.List[string]]::new()
    $skippedExe = @{}
    $run = 0; $skipped = 0
    $i = 0
    while ($i -lt $lines.Count) {
        $line = $lines[$i]
        $isCl = $line -match '^cl /nologo .*/Fe:"[^"]*\\([^\\"]+)\.exe"'
        if ($isCl) {
            $exe = $Matches[1]
            $src = if ($line -match '"([^"]*\\tests\\native\\[^"\\]+\.cpp)"') { $Matches[1] } else { $null }
            if ($src -and (Test-Path -LiteralPath $src)) {
                $key = 't-' + (Get-IW7InputHash @($line.Replace($Repo, '<repo>'), (Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash, $headerHash, $Toolchain))
                $block = @($line); if ($lines[$i + 1] -like 'if errorlevel*') { $block += $lines[$i + 1]; $i++ }
                if (Test-IW7TestsPassed $key) { $skippedExe[$exe] = $true; $skipped++ }
                else { foreach ($b in $block) { $out.Add($b) }; $keys.Add($key); $run++ }
                $i++; continue
            }
        }
        # a run line of a test whose compile was left out
        if ($line -match '^"[^"]*\\([^\\"]+)\.exe"' -and $skippedExe[$Matches[1]]) {
            if ($lines[$i + 1] -like 'if errorlevel*') { $i++ }
            $i++; continue
        }
        $out.Add($line); $i++
    }
    [pscustomobject]@{ Script = ($out -join "`r`n"); Run = $run; Skipped = $skipped; Keys = @($keys) }
}

# ---- content-addressed timestamps ----
# MSBuild decides what to compile by file times. A fresh workspace copies every overlay source with a new time, and
# the overlay scripts rewrite files with the same text, so every build compiled every overlay again and then linked.
# After the overlays are applied, a file whose bytes are what the last successful build compiled gets that build's
# time back; only files that really changed keep their new time and are compiled.
function Restore-IW7SourceTimes {
    param([Parameter(Mandatory)][string]$NativeRoot)
    $state = Join-Path $NativeRoot '.iw7-source-times.json'
    $old = @{}
    if (Test-Path -LiteralPath $state) { foreach ($p in (Get-Content -LiteralPath $state -Raw | ConvertFrom-Json).PSObject.Properties) { $old[$p.Name] = $p.Value } }
    # The record is removed now and written again only by a build that succeeds, so a failed build never leaves a
    # record that claims objects it did not make.
    if (Test-Path -LiteralPath $state) { Remove-Item -LiteralPath $state -Force }
    $kept = 0; $changed = 0
    foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $NativeRoot 'src') -Recurse -File)) {
        $rel = [IO.Path]::GetRelativePath($NativeRoot, $f.FullName).Replace('\', '/')
        $e = $old[$rel]
        if ($e -and $e.Length -eq $f.Length) {
            $h = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA1).Hash
            if ($h -eq $e.Hash) {
                if ($f.LastWriteTimeUtc.Ticks -ne [long]$e.Ticks) { $f.LastWriteTimeUtc = [datetime]::new([long]$e.Ticks, 'Utc') }
                $kept++; continue
            }
        }
        $changed++
    }
    [pscustomobject]@{ Kept = $kept; Changed = $changed }
}

function Save-IW7SourceTimes {
    param([Parameter(Mandatory)][string]$NativeRoot)
    $state = Join-Path $NativeRoot '.iw7-source-times.json'
    $map = [ordered]@{}
    foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $NativeRoot 'src') -Recurse -File)) {
        $rel = [IO.Path]::GetRelativePath($NativeRoot, $f.FullName).Replace('\', '/')
        $map[$rel] = [ordered]@{ Length = $f.Length; Ticks = $f.LastWriteTimeUtc.Ticks; Hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA1).Hash }
    }
    $map | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $state -Encoding UTF8
}

# ---- the native build tree ----
# A native tree (pinned upstream, submodules, objects, libraries) is 2 GB, and a cold build of it clones 17 repositories
# and compiles every dependency (measured 18 Nov 2026: 11 minutes). Every worker used to make its own. Now one tree per
# pinned upstream lives in the cache and every build of every worktree takes it in turn: a lock file held open for the
# whole build (released by the system if the build dies), overlays applied, and only what differs from what the tree
# built last is compiled. Builds are exclusive on the machine anyway (the scheduler's Build reservation), so one tree
# serves them all. A tree is never copied: MSBuild's tracking logs hold absolute paths, so a copy at another path
# compiles everything again (measured: the seed copy of this change rebuilt asmjit, curl and DirectXTex).
# -Max above 1 makes extra trees for callers that hold a build reservation of their own; each starts cold.
function Enter-IW7NativeTree {
    param([Parameter(Mandatory)][string]$Pin, [ValidateRange(1,8)][int]$Max = 1, [int]$WaitSeconds = 7200)
    $root = Join-Path (Get-IW7BuildCacheRoot) 'native-trees'
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $deadline = [datetime]::UtcNow.AddSeconds($WaitSeconds)
    $waitStart = Get-Date
    while ($true) {
        for ($n = 1; $n -le $Max; $n++) {
            $name = "$($Pin.Substring(0,10))-$n"
            $lock = $null
            try { $lock = [IO.File]::Open((Join-Path $root "$name.lock"), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) } catch { continue }
            $tree = Join-Path $root $name
            $source = if (Test-Path -LiteralPath (Join-Path $tree '.git')) { 'warm' } else { 'cold: cloned now' }
            $owner = [Text.Encoding]::UTF8.GetBytes("pid=$PID since=$([datetime]::UtcNow.ToString('o'))")
            $lock.SetLength(0); $lock.Write($owner, 0, $owner.Length); $lock.Flush()
            return [pscustomobject]@{ Path = $tree; Lock = $lock; Source = $source; Waited = [int]((Get-Date) - $waitStart).TotalSeconds; Pin = $Pin }
        }
        if ([datetime]::UtcNow -gt $deadline) { throw "No native build tree became free in $WaitSeconds s (all $Max are in use)." }
        Start-Sleep -Seconds 5
    }
}

function Exit-IW7NativeTree {
    param([Parameter(Mandatory)]$Tree)
    if ($Tree.Lock) { $Tree.Lock.Dispose() }
}
