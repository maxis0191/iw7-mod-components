param([switch]$Compile)
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. "$repo/ops/Cutscene-Overlay.Core.ps1"
function Check([bool]$v,[string]$m){if(!$v){throw $m}}
function Refuses([scriptblock]$body){$failed=$false;try{& $body|Out-Null}catch{$failed=$true};Check $failed 'Expected refusal.'}
$scratch=Join-Path $repo ('runtime/cutscene-test-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory((Join-Path $scratch 'src/client/component/gsc'))|Out-Null
$source=@{
 'gsc/script_extension.cpp'="#include <std_include.hpp>`nnamespace gsc {`n`tnamespace function`n`t{ } }"
 'gsc/script_loading.cpp'="#include <std_include.hpp>`nreturn game::DB_FindXAssetHeader(type, name, allow_create_default).scriptfile;"
 'input.cpp'="#include <std_include.hpp>`nvoid cl_key_event_stub(const int local_client_num, const int key, const int down)`n`t`t{ }"
}
foreach($name in $source.Keys){[IO.File]::WriteAllText((Join-Path $scratch ('src/client/component/'+$name)),$source[$name])}
$r=Add-IW7CutsceneOverlay $scratch $repo
Check ($r.Files.Count -eq 6) 'Incomplete overlay.'
Refuses {Add-IW7CutsceneOverlay $scratch $repo}
$target=Join-Path $scratch 'src/client/component/cutscene.cpp'
[IO.File]::AppendAllText($target,'// foreign')
Refuses {Remove-IW7CutsceneOverlay $scratch}
Copy-Item -LiteralPath "$repo/src/native/cutscene.cpp" -Destination $target -Force
Remove-IW7CutsceneOverlay $scratch
foreach($name in $source.Keys){Check ([IO.File]::ReadAllText((Join-Path $scratch ('src/client/component/'+$name))) -ceq $source[$name]) 'Original source bytes changed.'}
Refuses {ConvertTo-IW7CutsceneSource 'gsc/script_loading.cpp' '#include <std_include.hpp>'}
if($Compile){
 . "$repo/ops/Resource-Scheduler.Core.ps1"
 Invoke-IW7ResourceJob -Scope $repo -Owner 'Cutscene policy tests' -PhysicalBytes 256MB -CommitBytes 512MB -Body {
  $vs=& "${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe" -products '*' -version '[17.0,18.0)' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath|Select-Object -First 1
  if(!$vs){throw 'VS2022 C++ tools required.'}
  $batch=Join-Path $scratch 'compile.cmd';$exe=Join-Path $scratch 'cutscene-test.exe'
  @('@echo off',('call "'+$vs+'\VC\Auxiliary\Build\vcvars64.bat" >nul'),('cl /nologo /std:c++20 /EHsc /W4 /Fe:"'+$exe+'" /Fo:"'+$scratch+'\cutscene-test.obj" "'+$repo+'\tests\native\cutscene_test.cpp"'),('if errorlevel 1 exit /b %errorlevel%'),('"'+$exe+'"'))|Set-Content -LiteralPath $batch -Encoding ascii
  & $env:ComSpec /d /c $batch
  if($LASTEXITCODE){throw 'Cutscene native policy checks failed.'}
 }
}
Write-Output 'PASS cutscene overlay refusal and byte-exact restoration; gameplay remains separate.'
