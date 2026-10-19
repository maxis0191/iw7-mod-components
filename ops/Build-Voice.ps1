param([switch]$TestsOnly, [switch]$Sanitizers, [switch]$RhinoExperiment, [switch]$EnemyExperiment, [switch]$ServerModules, [switch]$IsolatedLab, [switch]$VoiceTrace, [switch]$Debugger, [switch]$CollisionProvider, [switch]$WordProvenance, [switch]$OwnerCheats,
    [ValidateSet('Rave','Slasher')][string]$EnemyProfile = 'Rave',
    [ValidateRange(1,2)][int]$BuildJobs = 1,
    [ValidateNotNullOrEmpty()][string]$NativeRoot = (Join-Path $PSScriptRoot '../tools/iw7-mod-native'))
$ErrorActionPreference = 'Stop'
function Resolve-IW7VoiceBuildNativeRoot([string]$Path) {
    # Never discover/follow a junction target. The caller must name the actual
    # checkout explicitly. A missing checkout remains eligible for the existing
    # clone path, provided every existing ancestor is an ordinary directory.
    # This path is also embedded in a quoted CMD argument: forbid expansion.
    if ([string]::IsNullOrWhiteSpace($Path) -or ![IO.Path]::IsPathFullyQualified($Path) -or $Path -match '[\x00-\x1f"%!]') {
        throw 'NativeRoot must be an absolute literal directory path.'
    }
    $full = [IO.Path]::GetFullPath($Path)
    $current = $full
    while ($current) {
        $item = $null
        try { $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop }
        catch { if ($_.CategoryInfo.Category -ne [Management.Automation.ErrorCategory]::ObjectNotFound) { throw } }
        if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'NativeRoot reparse ancestry refused; provide the exact real checkout path.' }
        if ($item -and !$item.PSIsContainer) { throw 'NativeRoot ancestry must contain only directories.' }
        $parent = [IO.Directory]::GetParent($current)
        if (!$parent) { break }
        $current = $parent.FullName
    }
    $full
}
if ($Debugger -and (!$ServerModules -or !$IsolatedLab)) { throw 'Debugger requires ServerModules and IsolatedLab.' }
if ($VoiceTrace -and (!$ServerModules -or !$IsolatedLab)) { throw 'VoiceTrace requires ServerModules and IsolatedLab.' }
if ($CollisionProvider -and (!$ServerModules -or !$IsolatedLab)) { throw 'CollisionProvider requires ServerModules and IsolatedLab.' }
if ($WordProvenance -and (!$ServerModules -or !$IsolatedLab -or !$Debugger)) { throw 'WordProvenance requires ServerModules, IsolatedLab and Debugger.' }
if ($ServerModules -and ($RhinoExperiment -or $EnemyExperiment)) {
    throw 'ServerModules is incompatible with enemy/Rhino overlays.'
}
$repo = Split-Path $PSScriptRoot -Parent
$root = Resolve-IW7VoiceBuildNativeRoot $NativeRoot
if ($OwnerCheats -and !$ServerModules) { throw 'OwnerCheats requires the current ServerModules native profile.' }
. "$PSScriptRoot/Owner-CheatsOverlay.Core.ps1"
. "$PSScriptRoot/Cutscene-Overlay.Core.ps1"
. "$PSScriptRoot/Resource-Scheduler.Core.ps1"
# Reserve the complete operation before compiling tests, sanitizer binaries or
# native sources. TestsOnly uses the same admission and final release path.
Invoke-IW7ResourceJob -Scope $repo -Owner 'IW7 native build and checks' -PhysicalBytes (4GB * $BuildJobs) -CommitBytes (6GB * $BuildJobs) -Body {
$null = Resolve-IW7VoiceBuildNativeRoot $root
Remove-IW7CutsceneOverlay $root
Remove-IW7OwnerCheatsOverlay $root
$commit = '36f7afedb9e4c8c665b6e29227e3f5c660ed63d6'
if ($RhinoExperiment -or $EnemyExperiment) { $commit = '77e6d4d24e918ee363b3feee3735c3b889dff7d7' }
if ($ServerModules) { $commit = 'cfca45b11ee14641945b9a264a95638387f48a4a' }
if (!$TestsOnly) {
$null = Resolve-IW7VoiceBuildNativeRoot $root
if (!(Test-Path -LiteralPath "$root/.git")) {
    if ($RhinoExperiment -or $EnemyExperiment -or $ServerModules) { git clone --no-checkout https://github.com/maxis0191/iw7-mod.git $root }
    else { git clone --no-checkout https://github.com/auroramod/iw7-mod.git $root }
    if ($LASTEXITCODE) { throw 'Required IW7-Mod clone failed.' }
    git -C $root checkout --detach $commit
    if ($LASTEXITCODE) { throw 'Exact IW7-Mod pin checkout failed.' }
}
$null = Resolve-IW7VoiceBuildNativeRoot $root
if ((git -C $root rev-parse HEAD) -ne $commit) { throw "Build checkout must be pinned to $commit; do not silently discard local work." }
git -C $root submodule update --init --recursive
if ($LASTEXITCODE) { throw 'Pinned submodule checkout failed.' }
}
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
cl /nologo /std:c++17 /EHsc /W4 /WX /Od /RTC1 "$repo\tests\native\collision_provider_test.cpp" /Fe:"$runtime\collision-provider-test.exe" /Fo:"$runtime\collision-provider-test.obj"
if errorlevel 1 exit /b 1
"$runtime\collision-provider-test.exe"
if errorlevel 1 exit /b 1
cl /nologo /std:c++17 /EHsc /W4 /WX /Od /RTC1 "$repo\tests\native\afk_inactivity_test.cpp" /Fe:"$runtime\afk-inactivity-test.exe" /Fo:"$runtime\afk-inactivity-test.obj"
if errorlevel 1 exit /b 1
"$runtime\afk-inactivity-test.exe"
if errorlevel 1 exit /b 1
cl /nologo /std:c++17 /EHsc /W4 /WX /Od /RTC1 "$repo\tests\native\word_provenance_test.cpp" /Fe:"$runtime\word-provenance-test.exe" /Fo:"$runtime\word-provenance-test.obj"
if errorlevel 1 exit /b 1
"$runtime\word-provenance-test.exe"
if errorlevel 1 exit /b 1
cl /nologo /std:c++17 /EHsc /W4 /WX /Od /RTC1 "$testSource" /Fe:"$testExe" /Fo:"$runtime\voice-protocol-test.obj"
if errorlevel 1 exit /b 1
"$testExe"
if errorlevel 1 exit /b 1
cl /nologo /std:c++17 /EHsc /W4 /WX /Od /RTC1 "$repo\tests\native\doom_test.cpp" /Fe:"$runtime\doom-test.exe" /Fo:"$runtime\doom-test.obj"
if errorlevel 1 exit /b 1
"$runtime\doom-test.exe"
if errorlevel 1 exit /b 1
cl /nologo /std:c++17 /EHsc /W4 /WX /Od /RTC1 "$repo\tests\native\debugger_stats_test.cpp" /Fe:"$runtime\debugger-stats-test.exe" /Fo:"$runtime\debugger-stats-test.obj"
if errorlevel 1 exit /b 1
"$runtime\debugger-stats-test.exe"
if errorlevel 1 exit /b 1
cl /nologo /std:c++17 /EHsc /W4 /WX /Od /RTC1 "$repo\tests\native\capacity_watch_test.cpp" /Fe:"$runtime\capacity-watch-test.exe" /Fo:"$runtime\capacity-watch-test.obj"
if errorlevel 1 exit /b 1
"$runtime\capacity-watch-test.exe"
if errorlevel 1 exit /b 1
cl /nologo /std:c++17 /EHsc /W4 /WX /Od /RTC1 "$repo\tests\native\capacity_checkpoint_publication_test.cpp" /Fe:"$runtime\capacity-checkpoint-publication-test.exe" /Fo:"$runtime\capacity-checkpoint-publication-test.obj"
if errorlevel 1 exit /b 1
"$runtime\capacity-checkpoint-publication-test.exe"
if errorlevel 1 exit /b 1
pwsh -NoProfile -File "$repo\tests\ops\capacity_checkpoint_overlay_test.ps1"
if errorlevel 1 exit /b 1
pwsh -NoProfile -File "$repo\tests\ops\kernel_image_alias_regression_test.ps1"
if errorlevel 1 exit /b 1
cl /nologo /std:c++17 /EHsc /W4 /WX /Od /RTC1 /c "$repo\tests\native\voice_test_capture_test.cpp" /Fo:"$runtime\fake-capture-test.obj"
if errorlevel 1 exit /b 1
cl /nologo /std:c++17 /EHsc /W4 /WX /Od /RTC1 /c "$repo\src\native\voice_test_capture.cpp" /Fo:"$runtime\fake-capture-impl.obj"
if errorlevel 1 exit /b 1
cl /nologo "$runtime\fake-capture-test.obj" "$runtime\fake-capture-impl.obj" /Fe:"$runtime\voice-test-capture.exe" /link bcrypt.lib dxguid.lib
if errorlevel 1 exit /b 1
"$runtime\voice-test-capture.exe"
if errorlevel 1 exit /b 1
cl /nologo /std:c++17 /EHsc /W4 /WX /Od /RTC1 /I"$repo\src\native" "$repo\tests\native\voice_test_binding_test.cpp" /Fe:"$runtime\voice-test-binding.exe" /Fo:"$runtime\voice-test-binding.obj"
if errorlevel 1 exit /b 1
"$runtime\voice-test-binding.exe"
if errorlevel 1 exit /b 1
cl /nologo /std:c++17 /EHsc /W4 /WX /Od /RTC1 /I"$repo\src\native" "$repo\tests\native\voice_pcm_witness_test.cpp" /Fe:"$runtime\voice-pcm-witness.exe" /Fo:"$runtime\voice-pcm-witness.obj"
if errorlevel 1 exit /b 1
"$runtime\voice-pcm-witness.exe"
if errorlevel 1 exit /b 1
cl /nologo /std:c++17 /EHsc /W4 /WX /Od /RTC1 /I"$repo\src\native" "$repo\tests\native\voice_capture_wire_test.cpp" /Fe:"$runtime\voice-capture-wire.exe" /Fo:"$runtime\voice-capture-wire.obj"
if errorlevel 1 exit /b 1
"$runtime\voice-capture-wire.exe"
if errorlevel 1 exit /b 1
cl /nologo /std:c++17 /EHsc /W4 /WX /Od /RTC1 /I"$repo\src\native" "$repo\tests\native\voice_ptt_protocol_test.cpp" /Fe:"$runtime\voice-ptt-protocol.exe" /Fo:"$runtime\voice-ptt-protocol.obj"
if errorlevel 1 exit /b 1
"$runtime\voice-ptt-protocol.exe"
if errorlevel 1 exit /b 1
cl /nologo /std:c++17 /EHsc /W4 /WX /Od /RTC1 /I"$repo\src\native" "$repo\tests\native\voice_ptt_guard_test.cpp" /Fe:"$runtime\voice-ptt-guard.exe" /Fo:"$runtime\voice-ptt-guard.obj"
if errorlevel 1 exit /b 1
"$runtime\voice-ptt-guard.exe"
if errorlevel 1 exit /b 1
pwsh -NoProfile -File "$repo\tests\ops\voice_agent_ptt_contract_test.ps1" -NativeSdkRoot "$root"
if errorlevel 1 exit /b 1
pwsh -NoProfile -File "$repo\ops\voice-agent\test_fake_build_copy.ps1" -RepoRoot "$repo"
if errorlevel 1 exit /b 1
pwsh -NoProfile -File "$repo\ops\agent-capacity\test_build_copy.ps1"
if errorlevel 1 exit /b 1
cl /nologo /std:c++17 /EHsc /W4 /WX /Od /RTC1 "$repo\tests\native\agent_scenario_test.cpp" /Fe:"$runtime\agent-scenario-test.exe" /Fo:"$runtime\agent-scenario-test.obj"
if errorlevel 1 exit /b 1
"$runtime\agent-scenario-test.exe"
if errorlevel 1 exit /b 1
cl /nologo /std:c++17 /EHsc /W4 /WX /Od /RTC1 "$repo\tests\native\voice_state_test.cpp" /Fe:"$runtime\voice-state-test.exe" /Fo:"$runtime\voice-state-test.obj"
if errorlevel 1 exit /b 1
"$runtime\voice-state-test.exe"
if errorlevel 1 exit /b 1
cl /nologo /std:c++17 /EHsc /W4 /WX /Od /RTC1 "$repo\tests\native\voice_launch_test.cpp" /Fe:"$runtime\voice-launch-test.exe" /Fo:"$runtime\voice-launch-test.obj"
if errorlevel 1 exit /b 1
"$runtime\voice-launch-test.exe"
if errorlevel 1 exit /b 1
cl /nologo /std:c++17 /EHsc /W4 /WX /Od /RTC1 "$repo\tests\native\take_chat_test.cpp" /Fe:"$runtime\take-chat-test.exe" /Fo:"$runtime\take-chat-test.obj"
if errorlevel 1 exit /b 1
"$runtime\take-chat-test.exe"
if errorlevel 1 exit /b 1
cl /nologo /std:c++17 /EHsc /W4 /WX /Od /RTC1 "$repo\tests\native\voice_transport_test.cpp" /Fe:"$runtime\voice-transport-test.exe" /Fo:"$runtime\voice-transport-test.obj"
if errorlevel 1 exit /b 1
"$runtime\voice-transport-test.exe"
if errorlevel 1 exit /b 1
cl /nologo /std:c++17 /EHsc /W4 /WX /Od /RTC1 "$repo\tests\native\voice_simulation_test.cpp" /Fe:"$runtime\voice-simulation-test.exe" /Fo:"$runtime\voice-simulation-test.obj"
if errorlevel 1 exit /b 1
"$runtime\voice-simulation-test.exe"
if errorlevel 1 exit /b 1
cl /nologo /std:c++17 /EHsc /W4 /WX /Od /RTC1 "$repo\tests\native\voice_inbox_test.cpp" /Fe:"$runtime\voice-inbox-test.exe" /Fo:"$runtime\voice-inbox-test.obj"
if errorlevel 1 exit /b 1
"$runtime\voice-inbox-test.exe"
if errorlevel 1 exit /b 1
cl /nologo /std:c++17 /EHsc /W4 /WX /Od /RTC1 "$repo\tests\native\voice_wan_test.cpp" /Fe:"$runtime\voice-wan-test.exe" /Fo:"$runtime\voice-wan-test.obj"
if errorlevel 1 exit /b 1
"$runtime\voice-wan-test.exe"
if errorlevel 1 exit /b 1
cl /nologo /std:c++17 /EHsc /W4 /WX /Od /RTC1 "$repo\tests\native\dvar_metadata_test.cpp" /Fe:"$runtime\dvar-metadata-test.exe" /Fo:"$runtime\dvar-metadata-test.obj"
if errorlevel 1 exit /b 1
"$runtime\dvar-metadata-test.exe"
if errorlevel 1 exit /b 1
cl /nologo /std:c++17 /EHsc /W4 /WX /Od "$repo\tests\native\audio_output_probe.cpp" /Fe:"$runtime\audio-output-probe.exe" /Fo:"$runtime\audio-output-probe.obj" ole32.lib uuid.lib ksuser.lib mmdevapi.lib
if errorlevel 1 exit /b 1
"$runtime\audio-output-probe.exe" --self-test
if errorlevel 1 exit /b 1
cl /nologo /std:c++17 /EHsc /W4 /WX /Od "$repo\ops\voice-agent\capture_adapter_test.cpp" /Fe:"$runtime\capture-adapter-test.exe" /Fo:"$runtime\capture-adapter-test.obj"
if errorlevel 1 exit /b 1
"$runtime\capture-adapter-test.exe"
if errorlevel 1 exit /b 1
cl /nologo /std:c++17 /EHsc /W4 /WX /Od "$repo\tests\native\audio_probe_worker_test.cpp" /Fe:"$runtime\audio-probe-worker-test.exe" /Fo:"$runtime\audio-probe-worker-test.obj"
if errorlevel 1 exit /b 1
pwsh -NoProfile -File "$repo\tests\ops\voice_agent_recorder_test.ps1" -WorkerPath "$runtime\audio-probe-worker-test.exe"
if errorlevel 1 exit /b 1
cl /nologo /std:c++17 /EHsc /W4 /WX /Od /RTC1 "$repo\tests\native\voice_pair_recorder_worker_test.cpp" /Fe:"$runtime\voice-pair-recorder-worker-test.exe" /Fo:"$runtime\voice-pair-recorder-worker-test.obj"
if errorlevel 1 exit /b 1
pwsh -NoProfile -File "$repo\tests\ops\voice_fake_source_test.ps1"
if errorlevel 1 exit /b 1
pwsh -NoProfile -File "$repo\tests\ops\voice_pair_provider_test.ps1"
if errorlevel 1 exit /b 1
pwsh -NoProfile -File "$repo\tests\ops\voice_pair_witness_test.ps1"
if errorlevel 1 exit /b 1
pwsh -NoProfile -File "$repo\tests\ops\voice_pair_source_options_test.ps1"
if errorlevel 1 exit /b 1
pwsh -NoProfile -File "$repo\tests\ops\voice_pair_envelope_test.ps1"
if errorlevel 1 exit /b 1
pwsh -NoProfile -File "$repo\tests\ops\voice_pair_recorder_test.ps1" -WorkerPath "$runtime\voice-pair-recorder-worker-test.exe"
if errorlevel 1 exit /b 1
"@ | Set-Content -LiteralPath $testCmd -Encoding ASCII
& $testCmd
if ($LASTEXITCODE) { throw 'Native protocol tests failed.' }
if ($Sanitizers) {
    $sanitizerCmd = Join-Path $runtime 'compile-voice-sanitizers.cmd'
    $lines = @('@echo off', "call `"$vcvars`" >nul", 'if errorlevel 1 exit /b 1')
    foreach ($name in @('voice_protocol_test','voice_state_test','voice_launch_test','take_chat_test','voice_transport_test','voice_simulation_test','voice_inbox_test','voice_wan_test','dvar_metadata_test')) {
        $lines += "cl /nologo /std:c++17 /EHsc /W4 /WX /O2 /Zi /fsanitize=address `"$repo\tests\native\$name.cpp`" /Fe:`"$runtime\$name-asan.exe`" /Fo:`"$runtime\$name-asan.obj`" /Fd:`"$runtime\$name-asan.pdb`" /link /INCREMENTAL:NO"
        $lines += 'if errorlevel 1 exit /b 1'
        $lines += "`"$runtime\$name-asan.exe`""
        $lines += 'if errorlevel 1 exit /b 1'
    }
    $lines | Set-Content -LiteralPath $sanitizerCmd -Encoding ASCII
    & $sanitizerCmd
    if ($LASTEXITCODE) { throw 'Native AddressSanitizer tests failed.' }
}
& "$repo/tests/ops/download_cache_overlay_test.ps1"
if ($TestsOnly) { return }
$flagsPath = Join-Path $root 'src/common/utils/flags.cpp'
$baseFlags = (((git -C $root show ($commit + ':src/common/utils/flags.cpp')) -join "`n").TrimEnd()) + "`n"
$flagsMarker = "`t`t`tLocalFree(argv);"
if (($baseFlags.Split([string[]]@($flagsMarker), [StringSplitOptions]::None)).Count -ne 2) { throw 'Pinned flag parser changed.' }
$playerFlags = $baseFlags.Replace('#include "nt.hpp"', '#include "nt.hpp"' + "`n" + '#include "../../client/component/voice_relay.hpp"').Replace($flagsMarker,
    "`t`t`tvoice_relay::apply_player_defaults(nt::library{}.get_name(), num_args, flags);`n" + $flagsMarker)
$currentFlags = [IO.File]::ReadAllText($flagsPath).Replace("`r`n", "`n").TrimEnd() + "`n"
if ($currentFlags -ne $baseFlags -and $currentFlags -ne $playerFlags) { throw 'Unowned flag parser edits; use an isolated checkout.' }
[IO.File]::WriteAllText($flagsPath, $playerFlags, [Text.UTF8Encoding]::new($false))
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
$nativeSources = @('paris_voice.cpp','paris_voice_protocol.hpp','voice_capture_adapter.hpp','paris_country.cpp','paris_identity.cpp','paris_chat.hpp','paris_test_fixture.cpp','paris_test_safety.hpp',
    'voice_relay.cpp','voice_relay.hpp','voice_state.hpp','voice_wire.hpp','voice_transport.hpp','voice_inbox.hpp','dvar_metadata.hpp','agent_scenario.hpp',
    'paris_model_diagnostics.cpp','paris_model_diagnostics.hpp','paris_incident.cpp','paris_incident.hpp','paris_afk.cpp','paris_afk.hpp','afk_inactivity.hpp')
if ($ServerModules) { $nativeSources += @('paris_doom.cpp','paris_doom.hpp') }
else {
    # The older standalone voice SDK does not expose the pinned CP WeaponDef.
    # Clear only this task's exact previously copied adapter when switching
    # profiles; an independently edited component requires investigation.
    foreach ($file in @('paris_doom.cpp','paris_doom.hpp')) {
        $target=Join-Path $root ('src/client/component/' + $file)
        if (Test-Path -LiteralPath $target) {
            if ((Get-FileHash -LiteralPath $target).Hash -ne (Get-FileHash -LiteralPath (Join-Path $repo ('src/native/' + $file))).Hash) {
                throw 'Unowned Doom overlay; preserve it and use a separate native source checkout.'
            }
            Remove-Item -LiteralPath $target
        }
    }
}
# Collision provider source selection; do not leave its TU in a disabled build.
if ($CollisionProvider) { $nativeSources += @('collision_provider.cpp','collision_provider.hpp') }
else {
    foreach ($file in @('collision_provider.cpp','collision_provider.hpp')) {
        $target=Join-Path $root ('src/client/component/' + $file)
        if (Test-Path -LiteralPath $target) {
            if ((Get-FileHash -LiteralPath $target).Hash -ne (Get-FileHash -LiteralPath (Join-Path $repo ('src/native/' + $file))).Hash) {
                throw 'Unowned collision provider overlay; preserve it and use a separate native source checkout.'
            }
            Remove-Item -LiteralPath $target
        }
    }
}
# End collision provider source selection.
. "$PSScriptRoot/agent-capacity/Build-Copy.Core.ps1"
# Debugger already requires IsolatedLab+ServerModules (pinned CP SDK).
# Main/nondebugger profiles contain no capacity watcher translation unit.
$capacityWatchBuild=Set-IW7CapacityWatchBuildCopy -RepoRoot $repo -NativeRoot $root -Enabled:([bool]($IsolatedLab -and $Debugger))
if ($capacityWatchBuild.Compiled) { $nativeSources += $capacityWatchBuild.Files }
. "$PSScriptRoot/voice-agent/Fake-BuildCopy.Core.ps1"
$fakeCaptureBuild=Set-IW7FakeCaptureBuildCopy -RepoRoot $repo -NativeRoot $root -Enabled:([bool]$IsolatedLab)
if($fakeCaptureBuild.Compiled){$nativeSources+=$fakeCaptureBuild.Files}
Copy-Item -LiteralPath @($nativeSources | Where-Object { $_ -cnotin $fakeCaptureBuild.Files } | ForEach-Object { Join-Path $repo ('src/native/' + $_) }) -Destination "$root/src/client/component"
$copiedVoice=Join-Path $root 'src/client/component/paris_voice.cpp'
if ($IsolatedLab) {
    . "$PSScriptRoot/voice-agent/Build-Copy.Core.ps1"
    $voiceSource=[IO.File]::ReadAllText($copiedVoice)
    [IO.File]::WriteAllText($copiedVoice,(Convert-IW7IsolatedVoiceSource $voiceSource),[Text.UTF8Encoding]::new($false))
    foreach($name in @('voice_relay.cpp','paris_test_fixture.cpp')){
        $path=Join-Path $root ('src/client/component/'+$name)
        [IO.File]::WriteAllText($path,(Convert-IW7IsolatedVoiceSource ([IO.File]::ReadAllText($path))),[Text.UTF8Encoding]::new($false))
    }
}
# The real input owner is bridged only in the pinned CP isolated profile.
# Disabled/ordinary profiles preserve clean input.cpp bytes exactly. Reusing
# a known enabled checkout restores its retained original bytes, never a guessed
# or generic detour. Helper/template/dependency pins enter the build manifest.
. "$PSScriptRoot/voice-agent/PTT-InputBridge.Core.ps1"
$inputBaseText=((git -C $root show ($commit+':src/client/component/input.cpp')) -join "`n")+"`n"
if($LASTEXITCODE){throw 'Pinned upstream input.cpp could not be read.'}
$pttInputBridgeBuild=Set-IW7PTTInputBridgeBuildCopy -RepoRoot $repo -NativeRoot $root -BaseInput ([Text.UTF8Encoding]::new($false).GetBytes($inputBaseText)) -IsolatedLab:([bool]$IsolatedLab) -ServerModules:([bool]$ServerModules)
if($pttInputBridgeBuild.Compiled){$nativeSources+=$pttInputBridgeBuild.Files}
& "$PSScriptRoot/Apply-ChatOverlay.ps1" -NativeRoot $root -Commit $commit
$incidentOverlay = & "$PSScriptRoot/Apply-IncidentOverlay.ps1" -NativeRoot $root -Commit $commit
$testPrivacyOverlay = & "$PSScriptRoot/Apply-TestPrivacyOverlay.ps1" -NativeRoot $root -Commit $commit
$downloadCacheOverlay = $null
if ($ServerModules -or $commit -eq '77e6d4d24e918ee363b3feee3735c3b889dff7d7') {
    $downloadCacheOverlay = & "$PSScriptRoot/Apply-DownloadCacheOverlay.ps1" -NativeRoot $root -Commit $commit
}
$loadingHook = $null
if ($ServerModules) {
    . "$PSScriptRoot/standard-client/Loading-NewMap.Core.ps1"
    $loadingHook = Assert-IW7StandardClientLoadingHook ([IO.File]::ReadAllText((Join-Path $root 'src/client/component/party.cpp')))
}
$capacityCheckpointEnabled=[bool]($IsolatedLab -and $Debugger)
$null = & "$PSScriptRoot/agent-capacity/Apply-WatchCheckpointOverlay.ps1" -NativeRoot $root -Commit $commit -Phase BeforeDebugger -Enabled:$capacityCheckpointEnabled
& "$PSScriptRoot/Apply-DebuggerOverlay.ps1" -NativeRoot $root -Commit $commit -Enabled:$Debugger
$capacityCheckpointBuild = & "$PSScriptRoot/agent-capacity/Apply-WatchCheckpointOverlay.ps1" -NativeRoot $root -Commit $commit -Phase AfterDebugger -Enabled:$capacityCheckpointEnabled
if ($Debugger) { $nativeSources += @('paris_debugger.cpp','paris_debugger.hpp','debugger_stats.hpp') }
. "$PSScriptRoot/agent-capacity/Provenance-BuildCopy.Core.ps1"
$wordProvenanceBuild=Set-IW7WordProvenanceBuildCopy -RepoRoot $repo -NativeRoot $root -Enabled:([bool]$WordProvenance) -IsolatedLab:([bool]$IsolatedLab) -ServerModules:([bool]$ServerModules) -Debugger:([bool]$Debugger) -Mode STARTUP -Apply
if($wordProvenanceBuild.Compiled){$nativeSources+=$wordProvenanceBuild.Files}
$wordProvenanceLifecycle=$null
if($commit -ceq '77e6d4d24e918ee363b3feee3735c3b889dff7d7'){
    $wordProvenanceLifecycle=& "$PSScriptRoot/agent-capacity/Apply-ProvenanceLifecycleOverlay.ps1" -NativeRoot $root -Commit $commit -Enabled:([bool]$WordProvenance) -IsolatedLab:([bool]$IsolatedLab) -ServerModules:([bool]$ServerModules) -Debugger:([bool]$Debugger) -Mode STARTUP -Apply
}
# Preserve the engine's metadata API while serializing its cache and keeping it
# alive during CRT shutdown. Accept only the pinned file or this exact overlay.
$dvarsPath = Join-Path $root 'src/client/game/dvars.cpp'
$baseDvars = (((git -C $root show ($commit + ':src/client/game/dvars.cpp')) -join "`n").TrimEnd()) + "`n"
$metadataMarker = "`tstd::unordered_map<const game::dvar_t*, std::string> dvar_names;"
$metadataStart = $baseDvars.IndexOf($metadataMarker, [StringComparison]::Ordinal)
if ($metadataStart -lt 0 -or $baseDvars.IndexOf($metadataMarker, $metadataStart + 1, [StringComparison]::Ordinal) -ge 0) { throw 'Pinned dvar metadata marker changed.' }
$metadataApi = @'
	std::string dvar_get_name(const game::dvar_t* dvar)
	{
		return iw7::metadata::process_cache<const game::dvar_t*>().name(dvar);
	}
	void dvar_set_name(const game::dvar_t* dvar, const std::string& name)
	{
		iw7::metadata::process_cache<const game::dvar_t*>().name(dvar, name);
	}
	std::string dvar_get_description(const game::dvar_t* dvar)
	{
		return iw7::metadata::process_cache<const game::dvar_t*>().description(dvar);
	}
	void dvar_set_description(const game::dvar_t* dvar, const std::string& description)
	{
		iw7::metadata::process_cache<const game::dvar_t*>().description(dvar, description);
	}
}
'@
$testDvars = ($baseDvars.Substring(0, $metadataStart) + $metadataApi.Replace("`r`n", "`n").TrimEnd() + "`n").Replace('#include "dvars.hpp"', '#include "dvars.hpp"' + "`n" + '#include "component/dvar_metadata.hpp"')
$currentDvars = [IO.File]::ReadAllText($dvarsPath).Replace("`r`n", "`n").TrimEnd() + "`n"
if ($currentDvars -ne $baseDvars -and $currentDvars -ne $testDvars) { throw 'Unowned dvar metadata edits; preserve them.' }
[IO.File]::WriteAllText($dvarsPath,$testDvars,[Text.UTF8Encoding]::new($false))
# Extend the existing upstream kick hook, rather than install a competing detour.
$botsPath = Join-Path $root 'src/client/component/bots.cpp'
$baseBots = (((git -C $root show ($commit + ':src/client/component/bots.cpp')) -join "`n").TrimEnd()) + "`n"
$kickMarker = "void sv_kick_client_num_stub(const int client_num, const char* reason, bool kicked_for_inactivity)`n`t`t{"
if (($baseBots.Split([string[]]@($kickMarker), [StringSplitOptions]::None)).Count -ne 2) { throw 'Pinned existing kick hook marker changed.' }
$legacyTestBots = $baseBots.Replace('namespace bots', '#include "paris_test_safety.hpp"' + "`n`nnamespace bots").Replace($kickMarker,
    $kickMarker + "`n`t`t`tif (paris_test_fixture::suppress_inactivity_kick(client_num, reason)) return;")
$testBots = $legacyTestBots.Replace('#include "paris_test_safety.hpp"', '#include "paris_test_safety.hpp"'+"`n"+'#include "paris_afk.hpp"').Replace($kickMarker,
    $kickMarker + "`n`t`t`tif (paris_afk::suppress_script_inactivity(client_num, reason)) return;")
$currentBots = [IO.File]::ReadAllText($botsPath).Replace("`r`n", "`n").TrimEnd() + "`n"
if ($currentBots -ne $baseBots -and $currentBots -ne $legacyTestBots -and $currentBots -ne $testBots) { throw 'Unowned bots.cpp changes; preserve them.' }
[IO.File]::WriteAllText($botsPath,$testBots,[Text.UTF8Encoding]::new($false))
# The pinned anti-debug helper writes legacy heap-header offsets. PageHeap uses
# a different layout; preserve its verifier state only in the explicit private
# diagnostic profile. Ordinary launches keep the pinned upstream behavior.
$arxanPath = Join-Path $root 'src/client/component/arxan/arxan.cpp'
$baseArxan = (((git -C $root show ($commit + ':src/client/component/arxan/arxan.cpp')) -join "`n").TrimEnd()) + "`n"
$heapMarker = "void hide_being_debugged()`n`t`t{`n`t`t`tauto* const peb = PPEB(__readgsqword(0x60));"
if (($baseArxan.Split([string[]]@($heapMarker), [StringSplitOptions]::None)).Count -ne 2) { throw 'Pinned heap-debug helper marker changed.' }
$testArxan = $baseArxan.Replace('#include <utils/string.hpp>', "#include <utils/string.hpp>`n#include <utils/flags.hpp>").Replace($heapMarker,
    $heapMarker + "`n`t`t`t// Keep Windows PageHeap headers and flags intact during the private trace.`n`t`t`t" +
    'if (utils::flags::has_flag("paris-voice-native-trace") && (*reinterpret_cast<PDWORD>(LPSTR(peb) + 0xBC) & 0x02000000)) return;')
$currentArxan = [IO.File]::ReadAllText($arxanPath).Replace("`r`n", "`n").TrimEnd() + "`n"
if ($currentArxan -ne $baseArxan -and $currentArxan -ne $testArxan) { throw 'Unowned anti-debug helper edits; preserve them.' }
[IO.File]::WriteAllText($arxanPath,$testArxan,[Text.UTF8Encoding]::new($false))
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
$cutsceneOverlay = $null
$ownerCheatsOverlay = $null
if ($OwnerCheats) {
    $ownerCheatsOverlay = Add-IW7OwnerCheatsOverlay $root $repo
    $cutsceneOverlay = Add-IW7CutsceneOverlay $root $repo
    $nativeSources += @('cutscene.cpp','cutscene.hpp','cutscene_policy.hpp')
    $nativeSources += @('owner_cheats.cpp','owner_cheats.hpp','owner_cheats_policy.hpp','owner_cheats_crypto.hpp')
}
Push-Location $root
try {
    & ./tools/premake5.exe vs2022
    if ($LASTEXITCODE) { throw 'Premake failed.' }
    & "$installation/MSBuild/Current/Bin/MSBuild.exe" build/iw7-mod.sln "/m:$BuildJobs" /nr:false /v:minimal /p:Configuration=Release /p:Platform=x64 /p:MultiProcessorCompilation=false "/flp:logfile=$runtime/voice-build.log;verbosity=minimal"
    if ($LASTEXITCODE) { throw 'Voice build failed.' }
} finally { Pop-Location }
$output = Join-Path $runtime 'voice-package'
New-Item -ItemType Directory -Path $output -Force | Out-Null
Copy-Item -LiteralPath "$root/build/bin/x64/Release/iw7-mod.exe" -Destination "$output/iw7-paris-voice.exe"
$manifestSources = @($nativeSources)
if ($IsolatedLab) { $manifestSources += 'paris_lab_properties.cpp' }
$manifest = [ordered]@{ Upstream=$commit; Protocol=1; SHA256=(Get-FileHash "$output/iw7-paris-voice.exe").Hash; BuiltUtc=[datetime]::UtcNow.ToString('o'); GameplayAcceptance='Pending owner testing'; SourceHashes=@($manifestSources | ForEach-Object { @{File=$_;SHA256=(Get-FileHash -LiteralPath (Join-Path $repo ('src/native/' + $_))).Hash} }) }
$sourceIdentity = & (Join-Path $repo 'ops/Get-SourceIdentity.ps1') -Root $repo
$manifest.OfficialUpstream = if ($ServerModules) { '37abcb260408ce7cdef0dde831bbfcad594510e3' } else { $null }
$manifest.VoiceRelayProtocol = 2
if ($ServerModules) { $manifest.LoadingNewMapHook = $loadingHook }
$manifest.NativeTree = (& git -C $root rev-parse ($commit + '^{tree}')).Trim()
$manifest.NativeSourceHashes = @(Get-ChildItem -LiteralPath (Join-Path $root 'src') -Recurse -File | Sort-Object FullName | ForEach-Object {
    @{ File=[IO.Path]::GetRelativePath($root,$_.FullName).Replace('\','/'); SHA256=(Get-FileHash -LiteralPath $_.FullName).Hash }
})
$manifest.ProjectCommit = $sourceIdentity.Commit
$manifest.SourceIdentity = $sourceIdentity
$manifest.DownloadCacheOverlay = $downloadCacheOverlay
$manifest.ProjectDirty = $sourceIdentity.Dirty
# Retain matching symbols before the next rebuild replaces them. These local
# files enable reliable crash stacks and must never be added to Git.
$symbols = Join-Path $runtime ('voice-symbols/' + $manifest.SHA256)
New-Item -ItemType Directory -Path $symbols -Force | Out-Null
Copy-Item -LiteralPath "$output/iw7-paris-voice.exe" -Destination (Join-Path $symbols 'iw7-paris-native-trace.exe') -Force
Copy-Item -LiteralPath "$root/build/bin/x64/Release/iw7-mod.pdb" -Destination (Join-Path $symbols 'iw7-mod.pdb') -Force
$manifest.SymbolsSHA256 = (Get-FileHash -LiteralPath (Join-Path $symbols 'iw7-mod.pdb')).Hash
$manifest.Debugger = [bool]$Debugger
$manifest.CollisionProvider = [bool]$CollisionProvider
$manifest.FakeCaptureBuild=$fakeCaptureBuild
$manifest.PTTInputBridgeBuild=$pttInputBridgeBuild
$manifest.FakeCaptureBuildHelperSHA256=(Get-FileHash -LiteralPath "$PSScriptRoot/voice-agent/Fake-BuildCopy.Core.ps1").Hash
$manifest.FakeCaptureTransformedSourceHashes=@(@('paris_voice.cpp','voice_relay.cpp','paris_test_fixture.cpp')|ForEach-Object{
    @{File=$_;SHA256=(Get-FileHash -LiteralPath (Join-Path $root ('src/client/component/'+$_))).Hash}
})
$manifest.CapacityWatchBuild = $capacityWatchBuild
$manifest.CapacityCheckpointBuild = $capacityCheckpointBuild
$manifest.CapacityCheckpointOverlayHelperSHA256 = (Get-FileHash -LiteralPath "$PSScriptRoot/agent-capacity/Apply-WatchCheckpointOverlay.ps1").Hash
$manifest.CapacityCheckpointOverlayCoreSHA256 = (Get-FileHash -LiteralPath "$PSScriptRoot/agent-capacity/Checkpoint-Overlay.Core.ps1").Hash
$manifest.CapacityWatchBuildHelperSHA256 = (Get-FileHash -LiteralPath "$PSScriptRoot/agent-capacity/Build-Copy.Core.ps1").Hash
$manifest.WordProvenanceBuild=$wordProvenanceBuild
$manifest.WordProvenanceLifecycle=$wordProvenanceLifecycle
$manifest.WordProvenanceBuildHelperSHA256=(Get-FileHash -LiteralPath "$PSScriptRoot/agent-capacity/Provenance-BuildCopy.Core.ps1").Hash
$manifest.WordProvenanceLifecycleHelperSHA256=(Get-FileHash -LiteralPath "$PSScriptRoot/agent-capacity/Apply-ProvenanceLifecycleOverlay.ps1").Hash
$manifest.WordProvenanceLifecycleCoreSHA256=(Get-FileHash -LiteralPath "$PSScriptRoot/agent-capacity/Provenance-LifecycleOverlay.Core.ps1").Hash
if ((Get-FileHash -LiteralPath (Join-Path $symbols 'iw7-paris-native-trace.exe')).Hash -ne $manifest.SHA256) { throw 'Archived diagnostic executable mismatch.' }
$manifest.ServerModules = [bool]$ServerModules
$manifest.OwnerCheatsEnabled = [bool]$OwnerCheats
$manifest.OwnerCheatsOverlay = $ownerCheatsOverlay
$manifest.CutsceneOverlay = $cutsceneOverlay
$manifest.RigAssetsProbeCapability = [bool]($ServerModules -and $IsolatedLab)
$manifest.RigSceneProbeCapability = [bool]($ServerModules -and $IsolatedLab)
$manifest.RigSceneStockWitnessCapability = [bool]($ServerModules -and $IsolatedLab)
$manifest.BuildProfile = if ($VoiceTrace) { 'isolated-voice-trace' } elseif ($ServerModules -and $IsolatedLab) { 'isolated-modules' } elseif ($ServerModules) { 'server-only' } elseif ($RhinoExperiment -or $EnemyExperiment) { 'experimental' } elseif ($IsolatedLab) { 'isolated-lab' } else { 'native-helper' }
$manifest.VoiceTrace = [bool]$VoiceTrace
$manifest.TestKickHookSHA256 = (Get-FileHash -LiteralPath $botsPath).Hash
$manifest.TestHeapHookSHA256 = (Get-FileHash -LiteralPath $arxanPath).Hash
$manifest.DvarMetadataOverlaySHA256 = (Get-FileHash -LiteralPath $dvarsPath).Hash
$manifest.PlayerFlagsOverlaySHA256 = (Get-FileHash -LiteralPath $flagsPath).Hash
$manifest.PlayerChatOverlaySHA256 = (Get-FileHash -LiteralPath (Join-Path $root 'src/client/component/logprint.cpp')).Hash
$manifest.ExperimentalAssets = [bool]($RhinoExperiment -or $EnemyExperiment)
$manifest.ModuleProfile = if ($ServerModules) { 'server-only; Rhino assets and spawns excluded' } else { $manifest.BuildProfile }
$manifest.CountryAnnouncement = 'ipwho.is HTTPS, server only'
$manifest.SessionAliases = 'Temporary duplicate names, server only'
$manifest.IncidentOverlaySHA256 = $incidentOverlay.SHA256
$manifest.IncidentDropOverlaySHA256 = $incidentOverlay.DropSHA256
$manifest.TestPrivacyOverlaySHA256 = $testPrivacyOverlay.SHA256
$manifest.TestHeartbeatSuppressed = $testPrivacyOverlay.TestHeartbeatSuppressed
$manifest.IncidentRecorder = 'Explicit dedicated paris-incident-log flag; no packet retries or protocol changes'
$manifest.IsolatedLab = [bool]$IsolatedLab
$manifest.VoiceCaptureSelectorBuild = [bool]$IsolatedLab
$manifest.VoiceCopiedSourceSHA256 = (Get-FileHash -LiteralPath $copiedVoice).Hash
$manifest.VoiceSourceTransformation = if ($IsolatedLab) { 'insert IW7_PARIS_ISOLATED_VOICE_CAPTURE=1 immediately after exact leading PCH include; explicit startup admission still required' } else { 'none; selector code excluded' }
$manifest.VoiceSourceTransformationHelperSHA256 = (Get-FileHash -LiteralPath "$PSScriptRoot/voice-agent/Build-Copy.Core.ps1").Hash
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
Copy-Item -LiteralPath "$output/build-manifest.json" -Destination (Join-Path $symbols 'build-manifest.json') -Force
Write-Output "Prepared private client/server build: $output"
}
