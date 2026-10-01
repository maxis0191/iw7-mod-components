param([switch]$TestsOnly, [switch]$RhinoExperiment)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$root = Join-Path $repo 'tools/iw7-mod-native'
$commit = '36f7afedb9e4c8c665b6e29227e3f5c660ed63d6'
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (!(Test-Path -LiteralPath $vswhere)) { throw 'Install Microsoft VS 2022 Build Tools with VCTools and ATL; see docs/TOOLS.md.' }
$installation = & $vswhere -products '*' -version '[17.0,18.0)' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Select-Object -First 1
if (!$installation) { throw 'VS 2022 C++ toolchain not found.' }
$vcvars = Join-Path $installation 'VC/Auxiliary/Build/vcvars64.bat'
$runtime = Join-Path $repo 'runtime'
New-Item -ItemType Directory -Path $runtime -Force | Out-Null
$testSource = Join-Path $repo 'tests/native/voice_protocol_test.cpp'
$testExe = Join-Path $runtime 'voice-protocol-test.exe'
# Save the compiler invocation to avoid PowerShell 5 native-argument quote rewriting.
$testCmd = Join-Path $runtime 'compile-voice-tests.cmd'
@"
@echo off
call "$vcvars" >nul
if errorlevel 1 exit /b 1
cl /nologo /std:c++17 /EHsc /W4 /WX /Od /RTC1 "$testSource" /Fe:"$testExe" /Fo:"$runtime\voice-protocol-test.obj"
if errorlevel 1 exit /b 1
"$testExe"
if errorlevel 1 exit /b 1
cl /nologo /std:c++17 /EHsc /W4 /WX /Od "$repo\tests\native\audio_output_probe.cpp" /Fe:"$runtime\audio-output-probe.exe" /Fo:"$runtime\audio-output-probe.obj" ole32.lib uuid.lib ksuser.lib
"@ | Set-Content -LiteralPath $testCmd -Encoding ASCII
& $testCmd
if ($LASTEXITCODE) { throw 'Native protocol tests failed.' }
if ($TestsOnly) { return }
if (!(Test-Path -LiteralPath "$root/.git")) {
    git clone --recursive https://github.com/auroramod/iw7-mod.git $root
    if ($LASTEXITCODE) { throw 'Official upstream clone failed.' }
}
if ((git -C $root rev-parse HEAD) -ne $commit) { throw "Build checkout must be pinned to $commit; do not silently discard local work." }
git -C $root submodule update --init --recursive
if ($LASTEXITCODE) { throw 'Pinned submodule checkout failed.' }
Copy-Item -LiteralPath "$repo/src/native/paris_voice.cpp","$repo/src/native/paris_voice_protocol.hpp" -Destination "$root/src/client/component"
$rhinoOverlay = Join-Path $root 'src/client/component/paris_rhino.cpp'
if ($RhinoExperiment) { Copy-Item -LiteralPath "$repo/src/custom_scripts/cp/experiments/paris_rhino.cpp" -Destination $rhinoOverlay }
elseif (Test-Path -LiteralPath $rhinoOverlay) { Remove-Item -LiteralPath $rhinoOverlay }
$fastfiles = Join-Path $root 'src/client/component/fastfiles.cpp'
$baseFastfiles = (((git -C $root show ($commit + ':src/client/component/fastfiles.cpp')) -join "`n").TrimEnd()) + "`n"
$declaration = "// Paris Rhino optional asset filter.`nnamespace paris_rhino { bool filter_asset(game::XAssetType, game::XAssetHeader*, game::XAssetHeader*); void observe_asset(game::XAssetType, game::XAssetHeader); void begin_filtered_asset(game::XAssetType, game::XAssetHeader); }`n`nnamespace fastfiles"
$needle = 'auto result = db_add_xasset_hook.invoke<game::XAssetHeader>(type, header_ptr);'
$filter = "game::XAssetHeader filtered{};`n`t`t`tif (paris_rhino::filter_asset(type, header_ptr, &filtered)) { paris_rhino::begin_filtered_asset(type, *header_ptr); return filtered; }`n`t`t`t" + $needle
$experimentFastfiles = $baseFastfiles.Replace('namespace fastfiles', $declaration).Replace($needle, $filter + "`n`t`t`tparis_rhino::observe_asset(type, result);")
$currentFastfiles = [IO.File]::ReadAllText($fastfiles).Replace("`r`n", "`n").TrimEnd() + "`n"
if ($currentFastfiles -ne $baseFastfiles -and $currentFastfiles -ne $experimentFastfiles) { throw 'Unowned fastfiles.cpp changes in build checkout; use an isolated checkout.' }
[IO.File]::WriteAllText($fastfiles, $(if ($RhinoExperiment) { $experimentFastfiles } else { $baseFastfiles }), [Text.UTF8Encoding]::new($false))
Push-Location $root
try {
    & ./tools/premake5.exe vs2022
    if ($LASTEXITCODE) { throw 'Premake failed.' }
    & "$installation/MSBuild/Current/Bin/MSBuild.exe" build/iw7-mod.sln /m:4 /nr:false /v:minimal /p:Configuration=Release /p:Platform=x64 "/flp:logfile=$runtime/voice-build.log;verbosity=minimal"
    if ($LASTEXITCODE) { throw 'Voice build failed.' }
} finally { Pop-Location }
$output = Join-Path $runtime 'voice-package'
New-Item -ItemType Directory -Path $output -Force | Out-Null
Copy-Item -LiteralPath "$root/build/bin/x64/Release/iw7-mod.exe" -Destination "$output/iw7-paris-voice.exe"
$manifest = [ordered]@{ Upstream=$commit; Protocol=1; SHA256=(Get-FileHash "$output/iw7-paris-voice.exe").Hash; BuiltUtc=[datetime]::UtcNow.ToString('o'); GameplayAcceptance='Pending owner testing'; SourceHashes=@(Get-ChildItem "$repo/src/native/*" | ForEach-Object { @{File=$_.Name;SHA256=(Get-FileHash $_.FullName).Hash} }) }
$manifest.CountryAnnouncement = 'ipwho.is HTTPS, server only'
$manifest.SessionAliases = 'Temporary duplicate names, server only'
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$output/build-manifest.json" -Encoding UTF8
Write-Output "Prepared private client/server build: $output"
