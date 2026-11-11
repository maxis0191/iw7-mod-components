param([string]$NativeRoot,[switch]$Compile)
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. "$repo/ops/Owner-CheatsOverlay.Core.ps1"
function Assert([bool]$Value,[string]$Message){if(!$Value){throw $Message}}
function Refuses([scriptblock]$Body){$failed=$false;try{& $Body|Out-Null}catch{$failed=$true};Assert $failed 'Expected refusal.'}
$scratch=Join-Path $repo ('runtime/owner-cheats-test-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory((Join-Path $scratch 'src/client/component'))|Out-Null
$sources=@{
    'command.cpp'="#include <std_include.hpp>`n"+((1..10|ForEach-Object{'if (!game::shared::cheats_ok(client_num, true)) {}'}) -join "`n")+"`ncmd_give(client_num, params.get_all());"
    'dvar_cheats.cpp'='#include <std_include.hpp>'+"`n"+'if ((dvar->flags & game::DvarFlags::DVAR_FLAG_CHEAT) && (!game::shared::cheats_ok() && *game::isCheatOverride)) {}'
    'auth.cpp'='#include <std_include.hpp>'+"`n"+'game::SV_ClientMP_DirectConnect(from);'
}
if($NativeRoot){foreach($name in @($sources.Keys)){$sources[$name]=[IO.File]::ReadAllText((Join-Path $NativeRoot ('src/client/component/'+$name)))}}
foreach($name in $sources.Keys){[IO.File]::WriteAllText((Join-Path $scratch ('src/client/component/'+$name)),$sources[$name])}
$before=@{};foreach($name in $sources.Keys){$before[$name]=(Get-FileHash (Join-Path $scratch ('src/client/component/'+$name))).Hash}
$receipt=Add-IW7OwnerCheatsOverlay $scratch $repo
Assert ($receipt.Files.Count -eq 7) 'Incomplete overlay.'
foreach($name in $sources.Keys){
    $text=[IO.File]::ReadAllText((Join-Path $scratch ('src/client/component/'+$name)))
    Assert ($text.StartsWith('#include <std_include.hpp>')) 'Precompiled header must remain first.'
}
$auth=[IO.File]::ReadAllText((Join-Path $scratch 'src/client/component/auth.cpp'))
Assert ($auth.IndexOf('owner_cheats::invalidate(from);') -lt $auth.IndexOf('game::SV_ClientMP_DirectConnect(from);')) 'Reconnect invalidation must precede retail connection.'
$command=[IO.File]::ReadAllText((Join-Path $scratch 'src/client/component/command.cpp'))
Assert ($command.Contains('if (!owner_cheats::give_customized(client_num, params.get_all())) cmd_give(client_num, params.get_all());')) 'Console give must try the Barracks build first.'
Refuses {Add-IW7OwnerCheatsOverlay $scratch $repo}
$target=Join-Path $scratch 'src/client/component/command.cpp'
[IO.File]::AppendAllText($target,'// unknown edit')
Refuses {Remove-IW7OwnerCheatsOverlay $scratch}
$originalRow=@($receipt.Files|Where-Object Name -EQ 'command.cpp')[0]
[IO.File]::WriteAllBytes($target,[Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-IW7OwnerCheatsSource 'command.cpp' $sources['command.cpp'])))
Remove-IW7OwnerCheatsOverlay $scratch
foreach($name in $sources.Keys){Assert ((Get-FileHash (Join-Path $scratch ('src/client/component/'+$name))).Hash -ceq $before[$name]) 'Native source restoration changed bytes.'}
Refuses {ConvertTo-IW7OwnerCheatsSource 'command.cpp' ($sources['command.cpp'].Replace('cheats_ok(client_num, true)','changed(client_num, true)'))}
Refuses {ConvertTo-IW7OwnerCheatsSource 'arbitrary.cpp' $sources['command.cpp']}
Refuses {ConvertTo-IW7OwnerCheatsSource 'command.cpp' ($sources['command.cpp'].Replace('cmd_give(client_num, params.get_all());',''))}
if($Compile){
    . "$repo/ops/Resource-Scheduler.Core.ps1"
    Invoke-IW7QueuedResourceJob -Scope $repo -Owner 'Owner cheats policy and Windows CNG tests' -WaitForSlotSeconds 420 -PhysicalBytes 512MB -CommitBytes 1GB -Body {
        $kit=Join-Path $scratch 'keys'
        & "$repo/ops/New-OwnerCheatsKit.ps1" -OutputDirectory $kit
        Refuses {& "$repo/ops/New-OwnerCheatsKit.ps1" -OutputDirectory $kit}
        $vswhere="${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
        $vs=& $vswhere -products '*' -version '[17.0,18.0)' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath|Select-Object -First 1
        if(!$vs){throw 'VS2022 C++ tools required.'}
        $batch=Join-Path $scratch 'compile.cmd'
        $exe=Join-Path $scratch 'owner-cheats-test.exe'
        @('@echo off',('call "'+$vs+'\VC\Auxiliary\Build\vcvars64.bat" >nul'),('cl /nologo /std:c++20 /EHsc /W4 /Fe:"'+$exe+'" /Fo:"'+$scratch+'\owner-cheats-test.obj" "'+$repo+'\tests\native\owner_cheats_test.cpp" bcrypt.lib'),('if errorlevel 1 exit /b %errorlevel%'),('"'+$exe+'" "'+$kit+'"'))|Set-Content -LiteralPath $batch -Encoding ascii
        & $env:ComSpec /d /c $batch
        if($LASTEXITCODE){throw 'Native owner-cheats behavior/crypto tests failed.'}
    }
}
Write-Output 'Owner cheats overlay checks passed; no game or production mutation.'
