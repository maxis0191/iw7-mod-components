param([Parameter(Mandatory)][string]$NativeRoot,[string]$Commit='')
$ErrorActionPreference='Stop'
# One list of GPU/UI/sound-stream/texture-streaming hooks (src/native/paris_no_gpu.hpp). The dedicated profile of the engine fork (client/component/dedicated.cpp) carries its own copy of the
# same sites; this overlay removes every one of them from that file and makes post_unpack call paris_no_gpu::apply() once instead, so the dedicated server and the no-render bot client
# never drift apart. Idempotent. A line it does not recognise is left alone and named (the dedicated profile is not changed in behaviour: the same sites are patched with the same bytes).
$repo=Split-Path $PSScriptRoot -Parent
$header=[IO.File]::ReadAllText((Join-Path $repo 'src/native/paris_no_gpu.hpp'))
$sites=[regex]::Match($header,'(?s)// <sites>(.*)// </sites>').Groups[1].Value
$addr=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach($m in [regex]::Matches($sites,'0x1[0-9A-Fa-f]{8}')){ [void]$addr.Add($m.Value.ToUpper().Replace('0X','0x')) }
$path=Join-Path $NativeRoot 'src/client/component/dedicated.cpp'
# always from the pinned blob when a commit is given (the native tree is shared between builds: a file left edited would break a build that does not carry the header)
$text=if($Commit){ ((git -C $NativeRoot show ($Commit+':src/client/component/dedicated.cpp')) -join "`n") }else{ [IO.File]::ReadAllText($path) }
$text=$text.Replace("`r`n","`n")
if($Commit -and $LASTEXITCODE){ throw 'Pinned dedicated.cpp unavailable.' }
$out=[Collections.Generic.List[string]]::new(); $removed=0; $inserted=$false
foreach($line in $text.Split("`n")){
    $t=$line.Trim()
    $drop=$false
    if($t -match '^utils::hook::(set(<uint8_t>)?|nop)\((0x1[0-9A-Fa-f]{8})\s*(\+\s*\d+)?[,)]'){ if(!$Matches[4] -and $addr.Contains(('0x'+$Matches[3].Substring(2).ToUpper()))){ $drop=$true } }
    if($t -match '^dvars::override::register_bool\("(r_preloadShaders|r_loadForRenderer|intro)"'){ $drop=$true }
    if($t -like 'utils::hook::jump(0x140341B60, init_dedicated_server, true);*'){ $drop=$true }
    if($drop){ $removed++; continue }
    $out.Add($line)
    if(!$inserted -and $t -like '*// Is party dedicated*'){ $out.Add("`t`t`tparis_no_gpu::apply();"); $inserted=$true }
}
if(!$inserted){ throw 'dedicated.cpp: the insertion point (// Is party dedicated) was not found.' }
$new=($out -join "`n").Replace('#include "network.hpp"','#include "network.hpp"'+"`n"+'#include "paris_no_gpu.hpp"')
$new=$new.TrimEnd()+"`n"
[IO.File]::WriteAllText($path,$new,[Text.UTF8Encoding]::new($false))
[pscustomobject]@{Applied=$true;Removed=$removed;File=$path}
