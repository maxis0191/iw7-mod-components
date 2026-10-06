#requires -Version 7.4
param([Parameter(Mandatory)][string]$OutputRoot)
# Only independent helper compilation and pure tests; never invokes an audio stream.
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$runtime=[IO.Path]::GetFullPath((Join-Path $repo 'runtime'))
$out=[IO.Path]::GetFullPath($OutputRoot)
if (!$out.StartsWith($runtime+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $out)) { throw 'Fresh ignored runtime build output required.' }
$cursor=Split-Path $out -Parent
while ($cursor) {
    if ((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Build output reparse ancestor refused.' }
    $parent=Split-Path $cursor -Parent;if ($parent -eq $cursor) { break };$cursor=$parent
}
$vswhere="${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
$installation=& $vswhere -products '*' -version '[17.0,18.0)' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Select-Object -First 1
if (!$installation) { throw 'Existing VS2022 C++ toolchain required.' }
$vcvars=Join-Path $installation 'VC/Auxiliary/Build/vcvars64.bat'
if (@($repo,$out,$vcvars) | Where-Object { $_ -match '[%\r\n!]' }) { throw 'Unsupported command-script path characters.' }
New-Item -ItemType Directory -Path $out | Out-Null
$cmd=Join-Path $out 'compile-render.cmd'
@"
@echo off
call "$vcvars" >nul
if errorlevel 1 exit /b 1
cl /nologo /std:c++17 /EHsc /W4 /WX /Od /RTC1 /DWIN32_LEAN_AND_MEAN /DNOMINMAX "$PSScriptRoot/render_wave_test.cpp" /Fe:"$out/render-wave-test.exe" /Fo:"$out/render-wave-test.obj"
if errorlevel 1 exit /b 1
"$out/render-wave-test.exe"
if errorlevel 1 exit /b 1
cl /nologo /std:c++17 /EHsc /W4 /WX /Od /RTC1 /DWIN32_LEAN_AND_MEAN /DNOMINMAX "$PSScriptRoot/render_wave.cpp" /Fe:"$out/render-wave.exe" /Fo:"$out/render-wave.obj"
if errorlevel 1 exit /b 1
"@ | Set-Content -LiteralPath $cmd -Encoding ascii
$manifest=[ordered]@{Kind='private_independent_render_helper';Compiler='/W4 /WX /RTC1; WIN32_LEAN_AND_MEAN; NOMINMAX';AudioActivated=$false;Completed=$false;Error=$null}
try {
    & $cmd *> (Join-Path $out 'build.log')
    if ($LASTEXITCODE) { throw 'Strict helper compilation/pure C++ test failed; retain build.log.' }
    & pwsh -NoProfile -File "$repo/tests/ops/voice_agent_render_test.ps1" *> (Join-Path $out 'powershell-test.log')
    if ($LASTEXITCODE) { throw 'Pure render PowerShell tests failed.' }
    $manifest.SourceHashes=@('render_wave.cpp','RenderWave.hpp','render_wave_test.cpp','Render.Core.ps1','Play-Source.ps1' | ForEach-Object { [ordered]@{File=$_;SHA256=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $_)).Hash} })
    $manifest.ExecutableSHA256=(Get-FileHash -LiteralPath (Join-Path $out 'render-wave.exe')).Hash
    $manifest.Completed=$true
} catch { $manifest.Error=$_.Exception.Message;throw }
finally { $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $out 'build.local.json') -Encoding utf8 }
[pscustomobject]@{Helper=(Join-Path $out 'render-wave.exe');SHA256=$manifest.ExecutableSHA256;AudioActivated=$false;BuildManifest=(Join-Path $out 'build.local.json')}
