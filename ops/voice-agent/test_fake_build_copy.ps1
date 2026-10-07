param([Parameter(Mandatory)][string]$RepoRoot)
$ErrorActionPreference='Stop'
$repo=(Resolve-Path -LiteralPath $RepoRoot).Path
$root=Join-Path $repo ('runtime/voice-agent/fake-copy-test-'+[guid]::NewGuid().ToString('N'))
$source=Join-Path $root 'source';$native=Join-Path $root 'native'
foreach($dir in @('source/src/native','source/ops/voice-agent','native/src/client/component')){$null=[IO.Directory]::CreateDirectory((Join-Path $root $dir))}
Copy-Item -LiteralPath (Join-Path $repo 'ops/Base-Client.Core.ps1') -Destination (Join-Path $source 'ops/Base-Client.Core.ps1')
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Fake-BuildCopy.Core.ps1') -Destination (Join-Path $source 'ops/voice-agent/Fake-BuildCopy.Core.ps1')
. (Join-Path $source 'ops/voice-agent/Fake-BuildCopy.Core.ps1')
$names=@('voice_test_capture.cpp','voice_test_capture.hpp','paris_voice_test_capture.cpp','paris_voice_test_capture.hpp','voice_test_binding.hpp','voice_capture_wire.hpp')
foreach($name in $names){$text=if($name -ceq 'voice_test_capture.cpp'){'#include "voice_test_capture.hpp"' + "`n"+'// synthetic fixture'}else{'// synthetic fixture '+$name};[IO.File]::WriteAllText((Join-Path $source ('src/native/'+$name)),$text)}
$enabled=Set-IW7FakeCaptureBuildCopy $source $native $true
if(!$enabled.Compiled -or $enabled.Files.Count -ne 6){throw 'Isolated six-file copy differs.'}
$copied=Join-Path $native 'src/client/component/voice_test_capture.cpp'
if([IO.File]::ReadAllText($copied) -notmatch '#pragma comment\(lib, "bcrypt.lib"\)'){throw 'Explicit isolated link dependency missing.'}
Set-IW7FakeCaptureBuildCopy $source $native $false|Out-Null
if(@(Get-ChildItem (Join-Path $native 'src/client/component') -File).Count){throw 'Known profile files not retired.'}
Set-IW7FakeCaptureBuildCopy $source $native $true|Out-Null
$first=Join-Path $native 'src/client/component/voice_test_capture.cpp';$before=(Get-FileHash $first).Hash
$foreign=Join-Path $native 'src/client/component/voice_test_capture.hpp';[IO.File]::WriteAllText($foreign,'foreign edit')
foreach($mode in @($false,$true)){
    $reject=$false;try{Set-IW7FakeCaptureBuildCopy $source $native $mode|Out-Null}catch{$reject=$true}
    if(!$reject -or !(Test-Path $first) -or (Get-FileHash $first).Hash -cne $before -or [IO.File]::ReadAllText($foreign) -cne 'foreign edit'){throw 'Unknown overlay mutated another file.'}
}
'Fake build-copy synthetic PASS; preserved fixtures='+$root
