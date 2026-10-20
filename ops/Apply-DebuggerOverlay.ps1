# Called only by the guarded builder after its source commit check.
param([Parameter(Mandatory)][string]$NativeRoot,[Parameter(Mandatory)][string]$Commit,[switch]$Enabled,[switch]$MainEngineOnly)
$ErrorActionPreference='Stop'
function Convert-IW7MainEngineDebuggerScheduler([string]$Source) {
    $base=$Source.Replace("`r`n","`n")
    $pch='#include <std_include.hpp>'
    $call='return utils::hook::invoke<void*>(0x140B8E2D0);'
    foreach($marker in @($pch,$call)) {
        if($base.Split([string[]]@($marker),[StringSplitOptions]::None).Count -ne 2){throw 'Standard main-engine scheduler marker must occur exactly once.'}
    }
    if($base.Contains('paris_debugger')){throw 'Existing debugger scheduler source refused; preserve it.'}
    $base.Replace($pch,$pch+"`n"+'#include "paris_debugger.hpp"').Replace($call,'paris_debugger::scope2 paris_main_scope;'+"`n`t`t`t"+$call)
}
function Assert-IW7MainEngineDebuggerPathAttributes([IO.FileAttributes]$Attributes) {
    if($Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Reparse Standard debugger source path refused; preserve it.'}
}
function Assert-IW7MainEngineDebuggerSourceState([string[]]$Changed,[string[]]$Untracked,$Receipt,[object[]]$Measured) {
    $scheduler='src/client/component/scheduler.cpp'
    $names=@('paris_debugger.cpp','paris_debugger.hpp','debugger_stats.hpp','debugger_thread_cpu.hpp')
    $copies=@($names|ForEach-Object{'src/client/component/'+$_})
    if(@($Changed).Count -ne 1 -or $Changed[0] -cne $scheduler){throw 'Main-engine build changed foreign tracked source.'}
    if(@($Untracked).Count -ne 4 -or @($Untracked|Select-Object -Unique).Count -ne 4 -or @($Untracked|Where-Object{$_ -cnotin $copies}).Count){throw 'Main-engine build has foreign or missing untracked source.'}
    if($Receipt.Commit -cne 'a99c04937513530648573fd4ca2a05321a90b4a5' -or @($Receipt.Files).Count -ne 4){throw 'Original Standard debugger receipt required.'}
    $expected=@([pscustomobject]@{Relative=$scheduler;SHA256=$Receipt.SchedulerSHA256})+@($Receipt.Files)
    if(@($expected.Relative|Select-Object -Unique).Count -ne 5 -or @($expected|Where-Object{$_.Relative -cne $scheduler -and $_.Relative -cnotin $copies}).Count){throw 'Debugger receipt paths differ.'}
    if(@($Measured).Count -ne 5 -or @($Measured.Relative|Select-Object -Unique).Count -ne 5){throw 'Every original debugger source must be remeasured.'}
    foreach($pin in $expected) {
        $actual=@($Measured|Where-Object Relative -CEQ $pin.Relative)
        if($pin.SHA256 -isnot [string] -or $pin.SHA256 -cnotmatch '\A[0-9a-fA-F]{64}\z' -or $actual.Count -ne 1 -or
           $actual[0].SHA256 -isnot [string] -or ![string]::Equals($pin.SHA256,$actual[0].SHA256,[StringComparison]::OrdinalIgnoreCase)){throw 'Build modified an original debugger source.'}
    }
}
function Add-IW7MainEngineDebuggerOverlay([string]$NativeRoot,[string]$Commit,[string]$RepoRoot) {
    if($Commit -cne 'a99c04937513530648573fd4ca2a05321a90b4a5'){throw 'Main-engine debugger requires the exact Standard source pin; cfca is not a fallback.'}
    $relative='src/client/component/scheduler.cpp'
    foreach($guardRelative in @('src','src/client','src/client/component',$relative)) {
        $guardPath=Join-Path $NativeRoot $guardRelative
        Assert-IW7MainEngineDebuggerPathAttributes ([IO.File]::GetAttributes($guardPath))
    }
    # The fixed a99 scheduler blob has no final newline. Rejoin its native
    # output lines without inventing one; normalize CRLF only below.
    $base=(git -C $NativeRoot show ($Commit+':'+$relative)) -join "`n"
    if($LASTEXITCODE){throw 'Pinned Standard scheduler could not be read.'}
    $overlay=Convert-IW7MainEngineDebuggerScheduler $base
    $raw=[Text.UTF8Encoding]::new($false,$true).GetBytes($overlay)
    $files=foreach($name in @('paris_debugger.cpp','paris_debugger.hpp','debugger_stats.hpp','debugger_thread_cpu.hpp')) {
        $target=Join-Path $NativeRoot ('src/client/component/'+$name)
        $attributes=$null
        try {$attributes=[IO.File]::GetAttributes($target)} catch [IO.FileNotFoundException] {}
        if($null -ne $attributes){Assert-IW7MainEngineDebuggerPathAttributes $attributes;throw "Existing debugger target refused; preserve $name."}
        $bytes=[IO.File]::ReadAllBytes((Join-Path $RepoRoot ('src/native/'+$name)))
        if(!$bytes.Length -or $bytes.Length -gt 1MB){throw 'Bounded debugger Source required.'}
        [pscustomobject]@{Relative='src/client/component/'+$name;Target=$target;Raw=$bytes;SHA256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))}
    }
    $stream=$null
    try {
        $stream=[IO.FileStream]::new((Join-Path $NativeRoot $relative),'Open','ReadWrite','None')
        if(!$stream.Length -or $stream.Length -gt 1MB){throw 'Bounded Standard scheduler required.'}
        $before=[byte[]]::new([int]$stream.Length);$used=0
        while($used -lt $before.Length){$n=$stream.Read($before,$used,$before.Length-$used);if(!$n){throw 'Standard scheduler early EOF.'};$used+=$n}
        if($stream.ReadByte() -ne -1 -or [Text.UTF8Encoding]::new($false,$true).GetString($before).Replace("`r`n","`n") -cne $base){throw 'Unowned Standard scheduler source; preserve it.'}
        foreach($file in $files) {
            $copy=$null
            try {$copy=[IO.FileStream]::new($file.Target,'CreateNew','Write','None');$copy.Write($file.Raw,0,$file.Raw.Length);$copy.Flush($true)}
            finally {if($copy){$copy.Dispose()}}
        }
        $stream.Position=0;$stream.Write($raw,0,$raw.Length);$stream.SetLength($raw.Length);$stream.Flush($true)
    } finally {if($stream){$stream.Dispose()}}
    [pscustomobject]@{Commit=$Commit;Mode='main-engine-only';SchedulerSHA256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($raw));Files=@($files|Select-Object Relative,SHA256);GSCOverlay=$false;GUIOverlay=$false;CapacityOverlay=$false}
}
$repo=Split-Path $PSScriptRoot -Parent
if($MainEngineOnly) {
    if(!$Enabled){throw 'MainEngineOnly requires explicit Enabled; it does not retire another profile.'}
    Add-IW7MainEngineDebuggerOverlay $NativeRoot $Commit $repo
    return
}
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
