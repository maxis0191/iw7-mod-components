# Called only by the guarded builder after its source commit check.
param([Parameter(Mandatory)][string]$NativeRoot,[Parameter(Mandatory)][string]$Commit,[switch]$Enabled)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
if (!$Enabled -and !(Test-Path -LiteralPath (Join-Path $NativeRoot 'src/client/component/paris_debugger.cpp'))) {
    # Legacy non-debugger forks predate frame_capture. An ordinary build must
    # not require any diagnostic marker or touch its source files.
    return
}
function Set-DebugOverlay([string]$Relative,[hashtable]$Replacements,[string]$Include) {
    $path=Join-Path $NativeRoot $Relative
    $base=(((git -C $NativeRoot show ($Commit+':'+$Relative)) -join "`n").TrimEnd())+"`n"
    if ($LASTEXITCODE) { throw 'Pinned profiler source could not be read.' }
    $pch='#include <std_include.hpp>'
    if (($base.Split([string[]]@($pch),[StringSplitOptions]::None)).Count -ne 2) { throw 'Pinned precompiled header marker changed.' }
    $overlay=$base.Replace($pch,$pch+"`n"+$Include)
    $failedOverlay=$Include+"`n"+$base
    foreach ($marker in $Replacements.Keys) {
        if (($base.Split([string[]]@($marker),[StringSplitOptions]::None)).Count -ne 2) { throw "Profiler marker changed in $Relative; inspect pinned source." }
        $overlay=$overlay.Replace($marker,$Replacements[$marker])
        $failedOverlay=$failedOverlay.Replace($marker,$Replacements[$marker])
    }
    $current=[IO.File]::ReadAllText($path).Replace("`r`n","`n").TrimEnd()+"`n"
    if ($current -ne $base -and $current -ne $overlay -and $current -ne $failedOverlay) { throw "Unowned profiler source edit: $Relative. Preserve it." }
    [IO.File]::WriteAllText($path,$(if ($Enabled) { $overlay } else { $base }),[Text.UTF8Encoding]::new($false))
}
Set-DebugOverlay 'src/client/component/scheduler.cpp' @{
    'utils::hook::invoke<void>(0x140B15E20);'='paris_debugger::scope paris_server_scope(1);'+"`n`t`t`t"+'utils::hook::invoke<void>(0x140B15E20);';
    'return utils::hook::invoke<void*>(0x140B8E2D0);'='paris_debugger::scope2 paris_main_scope;'+"`n`t`t`t"+'return utils::hook::invoke<void*>(0x140B8E2D0);'
} '#include "paris_debugger.hpp"'
Set-DebugOverlay 'src/client/component/gsc/script_extension.cpp' @{
    'const std::uint16_t function_id = get_function_id();'='const std::uint16_t function_id = get_function_id();'+"`n`t`t`t"+'paris_debugger::scope paris_function_scope(0x100 + function_id);';
    'const auto custom_function_id = static_cast<std::uint16_t>(meth_function_id);'='paris_debugger::scope paris_method_scope(0x1100 + (static_cast<unsigned>(meth_function_id) - 0x8000));'+"`n`t`t`t"+'const auto custom_function_id = static_cast<std::uint16_t>(meth_function_id);'
} '#include "../paris_debugger.hpp"'
Set-DebugOverlay 'src/client/component/gui/gui.cpp' @{
    'frame_capture::on_present(swap_chain);'='frame_capture::on_present(swap_chain);'+"`n`t`t`t`t"+'paris_debugger::render_frame(swap_chain);'
} '#include "../paris_debugger.hpp"'
foreach ($name in @('paris_debugger.cpp','paris_debugger.hpp','debugger_stats.hpp','debugger_thread_cpu.hpp')) {
    $source=Join-Path $repo ('src/native/'+$name)
    $target=Join-Path $NativeRoot ('src/client/component/'+$name)
    if ($Enabled) { Copy-Item -LiteralPath $source -Destination $target -Force }
    elseif (Test-Path -LiteralPath $target) {
        if ((Get-FileHash $source).Hash -ne (Get-FileHash $target).Hash) { throw "Unowned debugger component $name; preserve it." }
        Remove-Item -LiteralPath $target
    }
}
