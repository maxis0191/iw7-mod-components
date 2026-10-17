param([string]$NativeRoot)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../../ops/standard-client/Loading-NewMap.Core.ps1"
function Assert([bool]$Condition, [string]$Message) { if (!$Condition) { throw $Message } }
function Refuses([scriptblock]$Action) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert $rejected 'Expected loading-new-map source refusal.'
}
$source = @'
void loading_new_map_cl_stub(utils::hook::assembler& a)
{
    a.pushad64();
    a.mov(r8, r12);
    a.call_aligned(set_new_map);
    a.popad64();
    a.jmp(0x1409B04D7);
}
void post_unpack()
{
    utils::hook::jump(0x1409B04D2, utils::hook::assemble(loading_new_map_cl_stub));
    utils::hook::jump(0x140C563C3, utils::hook::assemble(reset_mem_stuff_stub), true);
}
'@
$entry = 'utils::hook::jump(0x1409B04D2, utils::hook::assemble(loading_new_map_cl_stub));'
$contract = Assert-IW7StandardClientLoadingHook $source
Assert ($contract.PatchBytes -eq 5) 'Entry patch width was not qualified.'
Assert (([Convert]::ToInt64($contract.ResumeAddress, 16) - [Convert]::ToInt64($contract.PatchAddress, 16)) -eq $contract.PatchBytes) 'Continuation overlaps the entry patch.'
$explicitNear = $source.Replace($entry, $entry.Replace('));', '), false);'))
Assert-IW7StandardClientLoadingHook $explicitNear | Out-Null
Assert-IW7StandardClientLoadingHook ($source.Replace("`n", "`r`n")) | Out-Null
# Reproduce the shipped bug: a twelve-byte far patch with a +5 continuation.
Refuses { Assert-IW7StandardClientLoadingHook ($source.Replace($entry, $entry.Replace('));', '), true);'))) }
Refuses { Assert-IW7StandardClientLoadingHook ($source.Replace($entry, $entry.Replace('));', '), true, true);'))) }
Refuses { Assert-IW7StandardClientLoadingHook ($source.Replace('0x1409B04D2', '0x1409B04E2')) }
Refuses { Assert-IW7StandardClientLoadingHook ($source.Replace('0x1409B04D7', '0x1409B04DE')) }
Refuses { Assert-IW7StandardClientLoadingHook ($source.Replace('a.popad64();', '')) }
Refuses { Assert-IW7StandardClientLoadingHook ($source.Replace($entry, '')) }
Refuses { Assert-IW7StandardClientLoadingHook ($source + "`n" + $entry) }
Refuses { Assert-IW7StandardClientLoadingHook ($source + "`n" + $source) }
$builder = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '../../ops/Build-StandardClient.ps1'))
$guard = $builder.IndexOf('$loadingHook = Assert-IW7StandardClientLoadingHook')
Assert ($guard -ge 0 -and $guard -lt $builder.IndexOf('& ./tools/premake5.exe')) 'Source contract must run before native project generation.'
Assert ($builder.Contains('git -C $root diff --quiet HEAD')) 'Native dirty-source gate must remain.'
if ($NativeRoot) {
    Assert-IW7StandardClientLoadingHook ([IO.File]::ReadAllText((Join-Path $NativeRoot 'src/client/component/party.cpp'))) | Out-Null
}
Write-Output 'PASS standard-client loading hook: five-byte continuation, far-jump regression, unknown-source refusals and prebuild guard.'
