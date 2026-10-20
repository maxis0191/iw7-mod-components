param([switch]$Compile)
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. "$root/ops/auto-capacity/Overlay.Core.ps1"
$base=Join-Path ([IO.Path]::GetTempPath()) ('iw7-auto-profile-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($base)|Out-Null
try {
    $before='#include <std_include.hpp>'+"`n"+'if (!paris_agent_capacity::compatible_peer(info.get("paris_capacity"))) {}'
    $after=ConvertTo-IW7AutoCapacitySource 'src/client/component/party.cpp' $before
    if($after.IndexOf('switch_for_server') -gt $after.IndexOf('compatible_peer')){throw 'Automatic profile hook runs after rejection.'}
    try {ConvertTo-IW7AutoCapacitySource 'src/client/component/party.cpp' $after;throw 'Duplicate overlay accepted.'}catch{if($_.Exception.Message -eq 'Duplicate overlay accepted.'){throw}}
    $before='#include <std_include.hpp>'+"`n"+'const auto path = "iw7-mod/"s + game; auto cache = std::filesystem::path(fs_basepath->current.string) / "iw7-mod" / "players2";'
    $after=ConvertTo-IW7AutoCapacitySource 'src/client/component/filesystem.cpp' $before
    if(([regex]::Matches($after,'auto_capacity::player_directory\(\)')).Count -ne 2){throw 'Engine settings and shader cache are not isolated.'}
    $component=Join-Path $base 'src/client/component';[IO.Directory]::CreateDirectory($component)|Out-Null
    $party='#include <std_include.hpp>'+"`n"+'if (!paris_agent_capacity::compatible_peer(info.get("paris_capacity"))) {}'
    [IO.File]::WriteAllText("$component/party.cpp",$party)
    [IO.File]::WriteAllText("$component/filesystem.cpp",$before)
    [IO.File]::WriteAllText("$component/updater.cpp",'#include <std_include.hpp>'+"`n"+'if (utils::flags::has_flag("noupdate")) {}')
    $receipt=Set-IW7AutoCapacityOverlay $base $root $true
    $filesystemHash=(Get-FileHash "$component/filesystem.cpp").Hash
    [IO.File]::AppendAllText("$component/party.cpp",'foreign edit')
    try {Set-IW7AutoCapacityOverlay $base $root $false;throw 'Foreign edits accepted.'}catch{if($_.Exception.Message -eq 'Foreign edits accepted.'){throw}}
    if((Get-FileHash "$component/filesystem.cpp").Hash -cne $filesystemHash){throw 'Foreign edit caused partial restoration.'}
    [IO.File]::WriteAllBytes("$component/party.cpp",[Convert]::FromBase64String(($receipt.Files|Where-Object Path -CEQ 'src/client/component/party.cpp').Before))
    Set-IW7AutoCapacityOverlay $base $root $false
    if((Test-Path "$base/auto-capacity-overlay.local.json") -or (Test-Path "$component/auto_capacity.cpp")){throw 'Partial-application recovery left owned sources.'}
    if([IO.File]::ReadAllText("$component/party.cpp") -cne $party){throw 'Overlay recovery changed original source bytes.'}
    if($Compile) {
        . "$root/ops/Resource-Scheduler.Core.ps1"
        Invoke-IW7ResourceJob -Scope $root -Owner 'Automatic capacity native policy checks' -PhysicalBytes 1GB -CommitBytes 1GB -Body {
            $vswhere="${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
            $installation=& $vswhere -products '*' -version '[17.0,18.0)' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath|Select-Object -First 1
            $bat=Join-Path $base 'build.cmd'
            @('@echo off',('call "'+$installation+'\VC\Auxiliary\Build\vcvars64.bat" >nul'),('cl /nologo /EHsc /std:c++17 /W4 /WX "'+$root+'\tests\native\auto_capacity_test.cpp" /Fo"'+$base+'\test.obj" /Fe"'+$base+'\test.exe" /link shell32.lib')) | Set-Content -LiteralPath $bat -Encoding ascii
            & cmd /d /c $bat;if($LASTEXITCODE){throw 'Automatic profile policy compile failed.'}
            & "$base/test.exe";if($LASTEXITCODE){throw 'Automatic profile policy execution failed.'}
        }
    }
}finally {
    $resolved=[IO.Path]::GetFullPath($base);$temporary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if(!$resolved.StartsWith($temporary,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^iw7-auto-profile-[0-9a-f]{32}$'){throw 'Temporary cleanup boundary changed.'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
'Automatic profile overlay Source PASS; no game or network.'
