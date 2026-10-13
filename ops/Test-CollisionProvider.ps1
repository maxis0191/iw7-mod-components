param()
$ErrorActionPreference='Stop'
$taskRepo=Split-Path $PSScriptRoot -Parent
. "$PSScriptRoot/Resource-Scheduler.Core.ps1"
Invoke-IW7ResourceJob -Scope $taskRepo -Owner 'Collision provider pure C++ test' -PhysicalBytes 1GB -CommitBytes 1GB -Body {
    $taskLocator="${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if(!(Test-Path -LiteralPath $taskLocator)){throw 'VS 2022 C++ toolchain locator is unavailable'}
    $taskVS=& $taskLocator -products '*' -version '[17.0,18.0)' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Select-Object -First 1
    if(!$taskVS){throw 'VS 2022 C++ toolchain is unavailable'}
    $taskVcVars=Join-Path $taskVS 'VC/Auxiliary/Build/vcvars64.bat'
    $taskOutput=Join-Path $taskRepo ('runtime/collision-test-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $taskOutput | Out-Null
    foreach($taskPath in @($taskRepo,$taskVcVars,$taskOutput)){
        if($taskPath -match '[\x00-\x1f"%!]'){throw 'Compiler command requires literal unexpanded paths'}
    }
    $taskCommand=Join-Path $taskOutput 'compile.cmd'
    @"
@echo off
call "$taskVcVars" >nul
if errorlevel 1 exit /b 1
cl /nologo /std:c++17 /EHsc /W4 /WX /Od /RTC1 "$taskRepo\tests\native\collision_provider_test.cpp" /Fe:"$taskOutput\collision-provider-test.exe" /Fo:"$taskOutput\collision-provider-test.obj"
if errorlevel 1 exit /b 1
"$taskOutput\collision-provider-test.exe"
if errorlevel 1 exit /b 1
"@ | Set-Content -LiteralPath $taskCommand -Encoding ascii
    & cmd.exe /d /c "`"$taskCommand`""
    if($LASTEXITCODE){throw 'Collision provider geometry compilation/test failed; preserve the output'}
    Write-Output "PASS native collision box geometry; no engine/provider interop executed. Output: $taskOutput"
}
