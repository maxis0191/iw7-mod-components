param([switch]$TestsOnly, [switch]$Sanitizers, [switch]$RhinoExperiment, [switch]$EnemyExperiment, [switch]$ServerModules, [switch]$IsolatedLab, [switch]$VoiceTrace,
    [ValidateSet('Rave','Slasher')][string]$EnemyProfile = 'Rave')
$ErrorActionPreference = 'Stop'
if ($VoiceTrace -and (!$ServerModules -or !$IsolatedLab)) { throw 'VoiceTrace requires ServerModules and IsolatedLab.' }
if ($ServerModules -and ($RhinoExperiment -or $EnemyExperiment)) {
    throw 'ServerModules is incompatible with enemy/Rhino overlays.'
}
$repo = Split-Path $PSScriptRoot -Parent
$root = Join-Path $repo 'tools/iw7-mod-native'
$commit = '36f7afedb9e4c8c665b6e29227e3f5c660ed63d6'
if ($RhinoExperiment -or $EnemyExperiment -or $ServerModules) { $commit = '77e6d4d24e918ee363b3feee3735c3b889dff7d7' }
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
cl /nologo /std:c++17 /EHsc /W4 /WX /Od /RTC1 "$repo\tests\native\voice_state_test.cpp" /Fe:"$runtime\voice-state-test.exe" /Fo:"$runtime\voice-state-test.obj"
if errorlevel 1 exit /b 1
"$runtime\voice-state-test.exe"
if errorlevel 1 exit /b 1
cl /nologo /std:c++17 /EHsc /W4 /WX /Od /RTC1 "$repo\tests\native\voice_transport_test.cpp" /Fe:"$runtime\voice-transport-test.exe" /Fo:"$runtime\voice-transport-test.obj"
if errorlevel 1 exit /b 1
"$runtime\voice-transport-test.exe"
if errorlevel 1 exit /b 1
cl /nologo /std:c++17 /EHsc /W4 /WX /Od /RTC1 "$repo\tests\native\voice_simulation_test.cpp" /Fe:"$runtime\voice-simulation-test.exe" /Fo:"$runtime\voice-simulation-test.obj"
if errorlevel 1 exit /b 1
"$runtime\voice-simulation-test.exe"
if errorlevel 1 exit /b 1
cl /nologo /std:c++17 /EHsc /W4 /WX /Od "$repo\tests\native\audio_output_probe.cpp" /Fe:"$runtime\audio-output-probe.exe" /Fo:"$runtime\audio-output-probe.obj" ole32.lib uuid.lib ksuser.lib
"@ | Set-Content -LiteralPath $testCmd -Encoding ASCII
& $testCmd
if ($LASTEXITCODE) { throw 'Native protocol tests failed.' }
if ($Sanitizers) {
    $sanitizerCmd = Join-Path $runtime 'compile-voice-sanitizers.cmd'
    $lines = @('@echo off', "call `"$vcvars`" >nul", 'if errorlevel 1 exit /b 1')
    foreach ($name in @('voice_protocol_test','voice_state_test','voice_transport_test','voice_simulation_test')) {
        $lines += "cl /nologo /std:c++17 /EHsc /W4 /WX /O2 /Zi /fsanitize=address `"$repo\tests\native\$name.cpp`" /Fe:`"$runtime\$name-asan.exe`" /Fo:`"$runtime\$name-asan.obj`" /Fd:`"$runtime\$name-asan.pdb`" /link /INCREMENTAL:NO"
        $lines += 'if errorlevel 1 exit /b 1'
        $lines += "`"$runtime\$name-asan.exe`""
        $lines += 'if errorlevel 1 exit /b 1'
    }
    $lines | Set-Content -LiteralPath $sanitizerCmd -Encoding ASCII
    & $sanitizerCmd
    if ($LASTEXITCODE) { throw 'Native AddressSanitizer tests failed.' }
}
if ($TestsOnly) { return }
if (!(Test-Path -LiteralPath "$root/.git")) {
    if ($RhinoExperiment -or $EnemyExperiment -or $ServerModules) { git clone --recursive --branch develop https://github.com/bigmangeekf/iw7-mod.git $root }
    else { git clone --recursive https://github.com/auroramod/iw7-mod.git $root }
    if ($LASTEXITCODE) { throw 'Required IW7-Mod clone failed.' }
}
if ((git -C $root rev-parse HEAD) -ne $commit) { throw "Build checkout must be pinned to $commit; do not silently discard local work." }
git -C $root submodule update --init --recursive
if ($LASTEXITCODE) { throw 'Pinned submodule checkout failed.' }
$properties = Join-Path $root 'src/common/utils/properties.cpp'
$baseProperties = (((git -C $root show ($commit + ':src/common/utils/properties.cpp')) -join "`n").TrimEnd()) + "`n"
$labProperties = [IO.File]::ReadAllText("$repo/src/native/paris_lab_properties.cpp").Replace("`r`n", "`n").TrimEnd() + "`n"
$currentProperties = [IO.File]::ReadAllText($properties).Replace("`r`n", "`n").TrimEnd() + "`n"
if ($currentProperties -ne $baseProperties -and $currentProperties -ne $labProperties) {
    throw 'Unowned properties.cpp changes; use an isolated native checkout.'
}
[IO.File]::WriteAllText($properties, $(if ($IsolatedLab) { $labProperties } else { $baseProperties }), [Text.UTF8Encoding]::new($false))
$authPath = Join-Path $root 'src/client/component/auth.cpp'
$baseAuth = (((git -C $root show ($commit + ':src/client/component/auth.cpp')) -join "`n").TrimEnd()) + "`n"
$mutexMarker = 'const auto mutex = CreateMutexA(nullptr, FALSE, utils::string::va("iw7-mod-player-%d", i));'
if (($baseAuth.Split([string[]]@($mutexMarker), [StringSplitOptions]::None)).Count -ne 2) { throw 'Pinned player mutex marker changed.' }
$labAuth = $baseAuth.Replace('#include <utils/properties.hpp>', "#include <utils/properties.hpp>`n#include <utils/flags.hpp>").Replace($mutexMarker,
    'const auto mutex_name = utils::flags::has_flag("paris-isolated-lab") ? utils::string::va("iw7-paris-lab-player-%llx-%d", static_cast<unsigned long long>(std::hash<std::string>{}(utils::properties::get_appdata_path().generic_string())), i) : utils::string::va("iw7-mod-player-%d", i);' + "`n`t`t`t`t`t" + 'const auto mutex = CreateMutexA(nullptr, FALSE, mutex_name);')
$oldLabAuth = $labAuth
$entropyMarker = 'raw_entropy.append(get_player_suffix());'
if (($baseAuth.Split([string[]]@($entropyMarker), [StringSplitOptions]::None)).Count -ne 2) { throw 'Pinned key entropy marker changed.' }
$labAuth = $labAuth.Replace($entropyMarker, $entropyMarker + "`n`t`t`t" + 'if (utils::flags::has_flag("paris-isolated-lab")) raw_entropy.append(utils::properties::get_appdata_path().generic_string());')
$currentAuth = [IO.File]::ReadAllText($authPath).Replace("`r`n", "`n").TrimEnd() + "`n"
if ($currentAuth -ne $baseAuth -and $currentAuth -ne $labAuth -and $currentAuth -ne $oldLabAuth) { throw 'Unowned auth.cpp changes; use an isolated native checkout.' }
[IO.File]::WriteAllText($authPath, $(if ($IsolatedLab) { $labAuth } else { $baseAuth }), [Text.UTF8Encoding]::new($false))
# The normal profile lists its native components and both protocol/test headers. Lab properties
# replace common/utils/properties.cpp above, never a component source.
# Retire the known misplaced overlay from reused/package-source checkouts.
# Its intended location is common/utils; unknown edits remain untouched.
$labComponent = Join-Path $root 'src/client/component/paris_lab_properties.cpp'
if (Test-Path -LiteralPath $labComponent) {
    $currentLabComponent = [IO.File]::ReadAllText($labComponent).Replace("`r`n", "`n").TrimEnd() + "`n"
    if ($currentLabComponent -ne $labProperties) { throw 'Unowned lab component overlay; preserve it and use an isolated native checkout.' }
    Remove-Item -LiteralPath $labComponent
}
$nativeSources = @('paris_voice.cpp','paris_voice_protocol.hpp','paris_country.cpp','paris_identity.cpp','paris_test_fixture.cpp','paris_test_safety.hpp',
    'voice_relay.cpp','voice_relay.hpp','voice_state.hpp','voice_wire.hpp','voice_transport.hpp')
Copy-Item -LiteralPath @($nativeSources | ForEach-Object { Join-Path $repo ('src/native/' + $_) }) -Destination "$root/src/client/component"
# Extend the existing upstream kick hook, rather than install a competing detour.
$botsPath = Join-Path $root 'src/client/component/bots.cpp'
$baseBots = (((git -C $root show ($commit + ':src/client/component/bots.cpp')) -join "`n").TrimEnd()) + "`n"
$kickMarker = "void sv_kick_client_num_stub(const int client_num, const char* reason, bool kicked_for_inactivity)`n`t`t{"
if (($baseBots.Split([string[]]@($kickMarker), [StringSplitOptions]::None)).Count -ne 2) { throw 'Pinned existing kick hook marker changed.' }
$testBots = $baseBots.Replace('namespace bots', '#include "paris_test_safety.hpp"' + "`n`nnamespace bots").Replace($kickMarker,
    $kickMarker + "`n`t`t`tif (paris_test_fixture::suppress_inactivity_kick(client_num, reason)) return;")
$currentBots = [IO.File]::ReadAllText($botsPath).Replace("`r`n", "`n").TrimEnd() + "`n"
if ($currentBots -ne $baseBots -and $currentBots -ne $testBots) { throw 'Unowned bots.cpp changes; preserve them.' }
[IO.File]::WriteAllText($botsPath,$testBots,[Text.UTF8Encoding]::new($false))
$rhinoOverlay = Join-Path $root 'src/client/component/paris_rhino.cpp'
$rhinoScriptInclude = Join-Path $root 'src/client/component/paris_rhino_scripts.inc'
$enemyScriptInclude = Join-Path $root 'src/client/component/paris_enemy_scripts.inc'
$enemyAnimclassInclude = Join-Path $root 'src/client/component/paris_enemy_animclasses.inc'
$scriptManifest = $null
$scriptEntries = @()
if ($RhinoExperiment -or $EnemyExperiment) {
    Copy-Item -LiteralPath "$repo/src/custom_scripts/cp/experiments/paris_rhino.cpp" -Destination $rhinoOverlay
    if ($RhinoExperiment) {
        $scriptManifest = Join-Path $repo 'runtime/rhino-pack-scripts/rhino-script-manifest.json'
        if (!(Test-Path -LiteralPath $scriptManifest)) { throw 'Prepare Rhino script assets before the experimental native build.' }
        $scriptEntries = @(Get-Content -LiteralPath $scriptManifest -Raw | ConvertFrom-Json)
        if (!$scriptEntries.Count -or @($scriptEntries | Where-Object { $_.Asset -notmatch '^[a-zA-Z0-9_/-]+$' }).Count) {
            throw 'Invalid Rhino script manifest; refusing to generate the native preload list.'
        }
        $includeLines = @($scriptEntries | ForEach-Object { '            "' + $_.Asset + '",' })
        [IO.File]::WriteAllText($rhinoScriptInclude, ($includeLines -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
    } else {
        [IO.File]::WriteAllText($rhinoScriptInclude, "            nullptr,`n", [Text.UTF8Encoding]::new($false))
    }

    $enemyScriptList = Join-Path $repo 'ops/enemy-ports/rave-wave-agent-scriptfiles.txt'
    $enemyAnimclassList = Join-Path $repo 'ops/enemy-ports/rave-wave-agent-animclasses.txt'
    if ($EnemyProfile -eq 'Slasher') {
        $enemyScriptList = Join-Path $repo 'ops/enemy-ports/rave-slasher-scriptfile-delta-candidate.txt'
        $enemyAnimclassList = Join-Path $repo 'ops/enemy-ports/lab-slasher-animclasses.txt'
    }
    $enemyModules = @()
    $enemyAnimclasses = @()
    if ($EnemyExperiment) {
        if (!(Test-Path -LiteralPath $enemyScriptList) -or !(Test-Path -LiteralPath $enemyAnimclassList)) {
            throw 'Enemy experiment source manifests are missing.'
        }
        $enemyModules = @(Get-Content -LiteralPath $enemyScriptList | ForEach-Object { $_.Trim() } | Where-Object { $_ -and !($_.StartsWith('#')) })
        $enemyAnimclasses = @(Get-Content -LiteralPath $enemyAnimclassList | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if (!$enemyModules.Count -or @($enemyModules | Where-Object { $_ -notmatch '^[a-z0-9_/-]+$' -or $_.StartsWith('/') -or $_.Contains('..') }).Count -or
            !$enemyAnimclasses.Count -or @($enemyAnimclasses | Where-Object { $_ -notmatch '^[a-z0-9_]+$' }).Count -or
            @($enemyModules | Select-Object -Unique).Count -ne $enemyModules.Count -or
            @($enemyAnimclasses | Select-Object -Unique).Count -ne $enemyAnimclasses.Count) {
            throw 'Invalid/duplicate enemy preload manifest entries.'
        }
    }
    $enemyLines = @($enemyModules | ForEach-Object { '            "' + $_ + '",' })
    if (!$enemyLines.Count) { $enemyLines = @('            nullptr,') }
    [IO.File]::WriteAllText($enemyScriptInclude, ($enemyLines -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
    $animclassLines = @($enemyAnimclasses | ForEach-Object { '            "' + $_ + '",' })
    if (!$animclassLines.Count) { $animclassLines = @('            nullptr,') }
    [IO.File]::WriteAllText($enemyAnimclassInclude, ($animclassLines -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
} elseif (Test-Path -LiteralPath $rhinoOverlay) {
    Remove-Item -LiteralPath $rhinoOverlay
    foreach ($includePath in @($rhinoScriptInclude,$enemyScriptInclude,$enemyAnimclassInclude)) {
        if (Test-Path -LiteralPath $includePath) { Remove-Item -LiteralPath $includePath }
    }
}
$scriptLoading = Join-Path $root 'src/client/component/gsc/script_loading.cpp'
$baseScriptLoading = (((git -C $root show ($commit + ':src/client/component/gsc/script_loading.cpp')) -join "`n").TrimEnd()) + "`n"
$scriptLoadingDeclaration = "namespace paris_rhino { void preload_gsc_dependencies(); void resolve_gsc_function_handles(); }`n`nnamespace gsc"
if (($baseScriptLoading.Split([string[]]@('namespace gsc'), [StringSplitOptions]::None)).Count -ne 2) {
    throw 'Pinned GSC loader namespace marker changed; refusing to add the Rhino preload declaration.'
}
$experimentScriptLoading = $baseScriptLoading.Replace('namespace gsc', $scriptLoadingDeclaration)
$previousDeclaration = "namespace paris_rhino { void preload_gsc_dependencies(); }`n`nnamespace gsc"
$previousExperimentScriptLoading = $baseScriptLoading.Replace('namespace gsc', $previousDeclaration)
$loadScriptMarker = "`t`t`tload_scripts();"
if (($experimentScriptLoading.Split([string[]]@($loadScriptMarker), [StringSplitOptions]::None)).Count -ne 2) {
    throw 'Pinned GSC loader marker changed; refusing to apply the Rhino preload hook.'
}
$previousExperimentScriptLoading = $previousExperimentScriptLoading.Replace($loadScriptMarker,
    "`t`t`tparis_rhino::preload_gsc_dependencies();`n" + $loadScriptMarker)
$existingExperimentScriptLoading = $experimentScriptLoading.Replace($loadScriptMarker,
    "`t`t`tparis_rhino::preload_gsc_dependencies();`n" + $loadScriptMarker + "`n`t`t`tparis_rhino::resolve_gsc_function_handles();")
$initCompilerMarker = "`t`t`tinit_compiler();"
if (($experimentScriptLoading.Split([string[]]@($initCompilerMarker), [StringSplitOptions]::None)).Count -ne 2) {
    throw 'Pinned GSC compiler initialization marker changed; refusing to move the Rhino preload hook.'
}
$failedPrelinkExperimentScriptLoading = $experimentScriptLoading.Replace($initCompilerMarker,
    $initCompilerMarker + "`n`t`t`tparis_rhino::preload_gsc_dependencies();").Replace($loadScriptMarker,
    $loadScriptMarker + "`n`t`t`tparis_rhino::resolve_gsc_function_handles();")
$experimentScriptLoading = $existingExperimentScriptLoading
$initCompilerPosition = $experimentScriptLoading.IndexOf($initCompilerMarker, [StringComparison]::Ordinal)
$retailBeginPosition = $experimentScriptLoading.IndexOf('scr_begin_load_scripts_hook.invoke<void>(a1);', [StringComparison]::Ordinal)
$preloadPosition = $experimentScriptLoading.IndexOf('paris_rhino::preload_gsc_dependencies();', [StringComparison]::Ordinal)
$loadScriptsPosition = $experimentScriptLoading.IndexOf($loadScriptMarker, [StringComparison]::Ordinal)
$resolvePosition = $experimentScriptLoading.IndexOf('paris_rhino::resolve_gsc_function_handles();', [StringComparison]::Ordinal)
if (!($initCompilerPosition -lt $retailBeginPosition -and $retailBeginPosition -lt $preloadPosition -and
      $preloadPosition -lt $loadScriptsPosition -and $loadScriptsPosition -lt $resolvePosition)) {
    throw 'Rhino GSC preloading must run after the retail GSC VM setup and before IW7-Mod custom script loading.'
}
$currentScriptLoading = [IO.File]::ReadAllText($scriptLoading).Replace("`r`n", "`n").TrimEnd() + "`n"
if ($currentScriptLoading -ne $baseScriptLoading -and $currentScriptLoading -ne $previousExperimentScriptLoading -and
    $currentScriptLoading -ne $existingExperimentScriptLoading -and $currentScriptLoading -ne $failedPrelinkExperimentScriptLoading) {
    throw 'Unowned GSC loader edits in build checkout; use an isolated checkout.'
}
[IO.File]::WriteAllText($scriptLoading, $(if ($RhinoExperiment -or $EnemyExperiment) { $experimentScriptLoading } else { $baseScriptLoading }), [Text.UTF8Encoding]::new($false))
$fastfiles = Join-Path $root 'src/client/component/fastfiles.cpp'
$baseFastfiles = (((git -C $root show ($commit + ':src/client/component/fastfiles.cpp')) -join "`n").TrimEnd()) + "`n"
$declaration = "// Paris Rhino optional asset/script extension.`nnamespace paris_rhino { void extend_image_pool(); int donor_flags(const char*); void remember_script(game::XAssetType, game::XAssetHeader, const std::string&); game::XAssetHeader prefer_script(game::XAssetType, const char*, game::XAssetHeader); void augment_netconststrings(game::XAssetType, game::XAssetHeader*, const std::string&); void verify_netconststrings(game::XAssetType, game::XAssetHeader, const std::string&); }`n`nnamespace fastfiles"
$needle = 'reallocate_asset_pool(game::ASSET_TYPE_FX, 2048); // originally 16, iw6 uses 2048'
if (($baseFastfiles.Split([string[]]@($needle), [StringSplitOptions]::None)).Count -ne 2) { throw 'Pinned pool initialization marker changed.' }
$experimentFastfiles = $baseFastfiles.Replace('namespace fastfiles', $declaration).Replace($needle, $needle + "`n`t`t`tparis_rhino::extend_image_pool();")
$findMarker = 'auto result = db_find_xasset_header_hook.invoke<game::XAssetHeader>(type, name, allow_create_default);'
$addMarker = 'auto header = *header_ptr;'
$addResultMarker = 'auto result = db_add_xasset_hook.invoke<game::XAssetHeader>(type, header_ptr);'
$flagMarker = 'info.allocFlags = game::DB_ZONE_PERMANENT;'
foreach ($marker in @($findMarker,$addMarker,$addResultMarker,$flagMarker)) {
    if (($baseFastfiles.Split([string[]]@($marker), [StringSplitOptions]::None)).Count -ne 2) { throw 'Pinned asset hook marker changed.' }
}
$experimentFastfiles = $experimentFastfiles.Replace($findMarker, $findMarker + "`n`t`t`tresult = paris_rhino::prefer_script(type, name, result);")
$experimentFastfiles = $experimentFastfiles.Replace($addMarker, "const auto paris_rhino_zone = get_current_fastfile();`n`t`t`tparis_rhino::augment_netconststrings(type, header_ptr, paris_rhino_zone);`n`t`t`t" + $addMarker + "`n`t`t`tparis_rhino::remember_script(type, header, paris_rhino_zone);")
$experimentFastfiles = $experimentFastfiles.Replace($addResultMarker, $addResultMarker + "`n`t`t`tparis_rhino::verify_netconststrings(type, result, paris_rhino_zone);")
$experimentFastfiles = $experimentFastfiles.Replace($flagMarker, 'info.allocFlags = paris_rhino::donor_flags(name);')
$currentFastfiles = [IO.File]::ReadAllText($fastfiles).Replace("`r`n", "`n").TrimEnd() + "`n"
if ($currentFastfiles -ne $baseFastfiles -and $currentFastfiles -ne $experimentFastfiles) { throw 'Unowned fastfiles.cpp changes in build checkout; use an isolated checkout.' }
[IO.File]::WriteAllText($fastfiles, $(if ($RhinoExperiment -or $EnemyExperiment) { $experimentFastfiles } else { $baseFastfiles }), [Text.UTF8Encoding]::new($false))
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
$manifestSources = @($nativeSources)
if ($IsolatedLab) { $manifestSources += 'paris_lab_properties.cpp' }
$manifest = [ordered]@{ Upstream=$commit; Protocol=1; SHA256=(Get-FileHash "$output/iw7-paris-voice.exe").Hash; BuiltUtc=[datetime]::UtcNow.ToString('o'); GameplayAcceptance='Pending owner testing'; SourceHashes=@($manifestSources | ForEach-Object { @{File=$_;SHA256=(Get-FileHash -LiteralPath (Join-Path $repo ('src/native/' + $_))).Hash} }) }
$manifest.ServerModules = [bool]$ServerModules
$manifest.BuildProfile = if ($VoiceTrace) { 'isolated-voice-trace' } elseif ($ServerModules -and $IsolatedLab) { 'isolated-modules' } elseif ($ServerModules) { 'server-only' } elseif ($RhinoExperiment -or $EnemyExperiment) { 'experimental' } elseif ($IsolatedLab) { 'isolated-lab' } else { 'native-helper' }
$manifest.VoiceTrace = [bool]$VoiceTrace
$manifest.TestKickHookSHA256 = (Get-FileHash -LiteralPath $botsPath).Hash
$manifest.ExperimentalAssets = [bool]($RhinoExperiment -or $EnemyExperiment)
$manifest.ModuleProfile = if ($ServerModules) { 'server-only; Rhino assets and spawns excluded' } else { $manifest.BuildProfile }
$manifest.CountryAnnouncement = 'ipwho.is HTTPS, server only'
$manifest.SessionAliases = 'Temporary duplicate names, server only'
$manifest.IsolatedLab = [bool]$IsolatedLab
if ($IsolatedLab) {
    $manifest.LabPropertiesSHA256 = (Get-FileHash -LiteralPath $properties).Hash
    $manifest.LabAuthSHA256 = (Get-FileHash -LiteralPath $authPath).Hash
}
if ($RhinoExperiment) {
    $manifest.RhinoScriptManifestSHA256 = (Get-FileHash -LiteralPath $scriptManifest).Hash
    $manifest.RhinoScriptAssetCount = $scriptEntries.Count
    $manifest.RhinoScriptLoaderSHA256 = (Get-FileHash -LiteralPath $scriptLoading).Hash
}
if ($EnemyExperiment) {
    $manifest.EnemyProfile = $EnemyProfile
    $manifest.EnemyScriptListSHA256 = (Get-FileHash -LiteralPath $enemyScriptList).Hash
    $manifest.EnemyAnimclassListSHA256 = (Get-FileHash -LiteralPath $enemyAnimclassList).Hash
    $manifest.EnemyScriptAssetCount = $enemyModules.Count
    $manifest.EnemyAnimclassCount = $enemyAnimclasses.Count
    $manifest.EnemyScriptLoaderSHA256 = (Get-FileHash -LiteralPath $scriptLoading).Hash
    $manifest.EnemyAddonScriptSHA256 = (Get-FileHash -LiteralPath "$repo/src/custom_scripts/cp/experiments/paris_enemy_ports.gsc").Hash
    $manifest.EnemyAddonNativeSHA256 = (Get-FileHash -LiteralPath "$repo/src/custom_scripts/cp/experiments/paris_rhino.cpp").Hash
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$output/build-manifest.json" -Encoding UTF8
Write-Output "Prepared private client/server build: $output"
