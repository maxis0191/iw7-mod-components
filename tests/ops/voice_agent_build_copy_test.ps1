$ErrorActionPreference='Stop'
. "$PSScriptRoot/../../ops/voice-agent/Build-Copy.Core.ps1"
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$source=[IO.File]::ReadAllText((Join-Path $repo 'src/native/paris_voice.cpp'))
$copy=Convert-IW7IsolatedVoiceSource $source
$lines=$copy -split "`n",3
if ($lines[0].TrimEnd("`r") -cne '#include <std_include.hpp>' -or $lines[1] -cne '#define IW7_PARIS_ISOLATED_VOICE_CAPTURE 1') { throw 'PCH must precede isolated define.' }
if ($copy.Replace("#define IW7_PARIS_ISOLATED_VOICE_CAPTURE 1`n",'') -cne $source) { throw 'Voice body bytes changed beyond scoped insertion.' }
foreach ($bad in @($source.Replace('#include <std_include.hpp>','#include <other.hpp>'),("// unexpected prefix`n"+$source),($source+"`n#include <std_include.hpp>`n"),$copy)) {
    $refused=$false;try { Convert-IW7IsolatedVoiceSource $bad | Out-Null } catch { $refused=$true }
    if (!$refused) { throw 'Missing/duplicate/nonleading PCH or transformed input did not refuse.' }
}
'PASS actual voice copied source keeps PCH first and body bytes exact; missing/duplicate/nonleading/transformed input refused.'
