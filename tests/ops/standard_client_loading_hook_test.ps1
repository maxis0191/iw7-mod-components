param([string]$NativeRoot,[switch]$MainEngineDebuggerSourceOnly)
$ErrorActionPreference = 'Stop'
if($MainEngineDebuggerSourceOnly -and $NativeRoot){throw 'SourceOnly cannot inspect a supplied native checkout.'}
function Test-MainEngineDebuggerSource {
    function Check([bool]$Condition,[string]$Message){$script:mainEngineSourceAssertions++;if(!$Condition){throw $Message}}
    function Refuse([scriptblock]$Action){$caught=$false;try{& $Action|Out-Null}catch{$caught=$true};Check $caught 'Expected main-engine Source refusal.'}
    $script:mainEngineSourceAssertions=0
    $repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $builderText=[IO.File]::ReadAllText((Join-Path $repo 'ops/Build-StandardClient.ps1'))
    $overlayText=[IO.File]::ReadAllText((Join-Path $repo 'ops/Apply-DebuggerOverlay.ps1'))
    $tokens=$null;$errors=$null
    $builderAst=[Management.Automation.Language.Parser]::ParseInput($builderText,[ref]$tokens,[ref]$errors)
    Check (!$errors.Count) 'Builder Source must parse.'
    $overlayAst=[Management.Automation.Language.Parser]::ParseInput($overlayText,[ref]$tokens,[ref]$errors)
    Check (!$errors.Count) 'Overlay Source must parse.'
    foreach($entry in @(
        @($builderAst,'Assert-IW7StandardDebuggerOptions'),
        @($overlayAst,'Convert-IW7MainEngineDebuggerScheduler'),
        @($overlayAst,'Assert-IW7MainEngineDebuggerPathAttributes'),
        @($overlayAst,'Assert-IW7MainEngineDebuggerSourceState'),
        @($overlayAst,'Add-IW7MainEngineDebuggerOverlay')
    )){
        $definition=@($entry[0].FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)|Where-Object Name -CEQ $entry[1])
        Check ($definition.Count -eq 1) 'One actual consumer function required.'
        . ([scriptblock]::Create($definition[0].Extent.Text))
    }
    # Only the real three conditional legacy fragments are evaluated here.
    # Dot-source leaves are replaced with inert callbacks before any invocation.
    $fragments=@($builderAst.FindAll({param($n)$n -is [Management.Automation.Language.IfStatementAst]},$true)|Where-Object{
        $_.Clauses[0].Item1.Extent.Text -ceq '!$MainEngineDebugger' -and
        ($_.Extent.Text.Contains('agent-capacity/Peer-Overlay.Core.ps1') -or $_.Extent.Text.Contains('Remove-IW7CapacityPeerOverlay') -or $_.Extent.Text.Contains('$null=Set-IW7CapacityWatchBuildCopy'))
    })
    Check ($fragments.Count -eq 3) 'Three actual default-only capacity frontiers required.'
    $sourceFragments=foreach($fragment in $fragments){
        $text=$fragment.Extent.Text
        foreach($leaf in @('Owner-CheatsOverlay.Core.ps1','Cutscene-Overlay.Core.ps1','agent-capacity/Peer-Overlay.Core.ps1','agent-capacity/Build-Copy.Core.ps1')){
            $text=$text.Replace('. "$PSScriptRoot/'+$leaf+'"',"`$events.Add('import:$leaf')")
        }
        $text
    }
    function Remove-IW7CapacityPeerOverlay {$events.Add('remove:peer')}
    function Remove-IW7CutsceneOverlay {$events.Add('remove:cutscene')}
    function Remove-IW7OwnerCheatsOverlay {$events.Add('remove:owner')}
    function Set-IW7CapacityWatchBuildCopy {$events.Add('capacity:disabled')}
    $selection=[scriptblock]::Create($builderAst.ParamBlock.Extent.Text+"`n"+($sourceFragments-join"`n"))
    $histories=@()
    foreach($mode in @('omitted','false','true')){
        $events=[Collections.Generic.List[string]]::new();$root='SYNTHETIC_SOURCE';$repo='SYNTHETIC_REPO'
        if($mode -ceq 'omitted'){& $selection -NativeRoot 'SYNTHETIC_SOURCE'}
        else{& $selection -NativeRoot 'SYNTHETIC_SOURCE' -MainEngineDebugger:($mode-ceq'true')}
        $histories+=,@($events.ToArray())
    }
    Check (($histories[0]-join'|') -ceq ($histories[1]-join'|')) 'Omitted and explicit false must preserve the same legacy operations.'
    Check ($histories[0].Count -eq 8 -and $histories[2].Count -eq 0) 'Main-engine mode must invoke none of the legacy overlay imports/removals/capacity calls.'
    Assert-IW7StandardDebuggerOptions $false $true $true
    Assert-IW7StandardDebuggerOptions $true $false $false
    Refuse {Assert-IW7StandardDebuggerOptions $true $true $false}
    Refuse {Assert-IW7StandardDebuggerOptions $true $false $true}
    $optionGuard=$builderText.IndexOf('Assert-IW7StandardDebuggerOptions ([bool]$MainEngineDebugger)')
    Check ($optionGuard -gt 0 -and $optionGuard -lt $builderText.IndexOf('$profile=') -and $optionGuard -lt $builderText.IndexOf('. "$PSScriptRoot/standard-client/Loading-NewMap.Core.ps1"')) 'Exclusive options must refuse before imports or operational paths.'
    $application=$builderText.IndexOf('$mainEngineOverlay=. "$PSScriptRoot/Apply-DebuggerOverlay.ps1"')
    Check ($application -gt $builderText.IndexOf('Untracked native source refused') -and $application -gt $builderText.IndexOf('Exact standard client pin required')) 'Original HEAD/dirty/untracked gates must precede application.'
    Check ($application -gt $builderText.IndexOf('$loadingHook = Assert-IW7StandardClientLoadingHook') -and $application -lt $builderText.IndexOf('& ./tools/premake5.exe')) 'Loading hook must remain guarded before generation.'
    $baseline=@'
#include <std_include.hpp>
namespace scheduler {
void* main_frame_stub() {
    const auto _0 = gsl::finally([]() { execute(pipeline::main); });
    return utils::hook::invoke<void*>(0x140B8E2D0);
}
void other() { untouched(); }
}
'@
    $baseline=$baseline.Replace("`r`n","`n")+"`n"
    $converted=Convert-IW7MainEngineDebuggerScheduler $baseline
    Check ($converted.Split([string[]]@('paris_debugger::scope2 paris_main_scope;'),[StringSplitOptions]::None).Count -eq 2) 'Exactly one real scope2 insertion required.'
    Check ($converted.Contains('void other() { untouched(); }') -and $converted.IndexOf('gsl::finally') -lt $converted.IndexOf('paris_debugger::scope2') -and $converted.IndexOf('paris_debugger::scope2') -lt $converted.IndexOf('return utils::hook::invoke')) 'Scope2 must end before the existing finally callbacks; unrelated Source is preserved.'
    Check (!$converted.Contains('paris_server_scope') -and !$converted.Contains('frame_capture') -and !$converted.Contains('paris_function_scope')) 'Only main-engine instrumentation is allowed.'
    Check ((Convert-IW7MainEngineDebuggerScheduler ($baseline.Replace("`n","`r`n"))) -ceq $converted) 'Checkout line endings must preserve the same exact overlay.'
    Check ((Convert-IW7MainEngineDebuggerScheduler ($baseline+" `t`n`n")).EndsWith(" `t`n`n",[StringComparison]::Ordinal)) 'Conversion must preserve trailing whitespace and final lines.'
    Assert-IW7MainEngineDebuggerPathAttributes ([IO.FileAttributes]::Directory)
    Refuse {Assert-IW7MainEngineDebuggerPathAttributes ([IO.FileAttributes]::Directory -bor [IO.FileAttributes]::ReparsePoint)}
    Refuse {Convert-IW7MainEngineDebuggerScheduler ($baseline.Replace('0x140B8E2D0','0x140B8E2D1'))}
    Refuse {Convert-IW7MainEngineDebuggerScheduler ($baseline+"`n"+$baseline)}
    Refuse {Convert-IW7MainEngineDebuggerScheduler $converted}
    # Source text fixtures only. No git process, PCH, SDK, compiler or provider.
    $sourceSandbox=Join-Path ([IO.Path]::GetTempPath()) ('iw7-main-engine-source-'+[guid]::NewGuid().ToString('N'))
    $native=Join-Path $sourceSandbox 'native';$owner=Join-Path $sourceSandbox 'owner'
    $component=Join-Path $native 'src/client/component';$ownerSources=Join-Path $owner 'src/native'
    $names=@('paris_debugger.cpp','paris_debugger.hpp','debugger_stats.hpp','debugger_thread_cpu.hpp')
    $gitCalls=0
    function git {
        Check ($args.Count -eq 4 -and $args[0]-ceq'-C' -and $args[1]-ceq$native -and $args[2]-ceq'show' -and $args[3]-ceq'a99c04937513530648573fd4ca2a05321a90b4a5:src/client/component/scheduler.cpp') 'Only the fake fixed Source show is allowed.'
        Set-Variable LASTEXITCODE -Scope 1 -Value 0
        Set-Variable gitCalls -Scope 1 -Value ($gitCalls+1)
        $baseline.Substring(0,$baseline.Length-1) -split "`n"
    }
    try {
        $null=[IO.Directory]::CreateDirectory($component);$null=[IO.Directory]::CreateDirectory($ownerSources)
        $schedulerPath=Join-Path $component 'scheduler.cpp'
        [IO.File]::WriteAllText($schedulerPath,$baseline,[Text.UTF8Encoding]::new($false))
        foreach($name in $names){[IO.File]::WriteAllText((Join-Path $ownerSources $name),('// SYNTHETIC Source '+$name),[Text.UTF8Encoding]::new($false))}
        Refuse {Add-IW7MainEngineDebuggerOverlay $native 'cfca45b11ee14641945b9a264a95638387f48a4a' $owner}
        Check ($gitCalls -eq 0) 'Refused fork must perform no Source I/O callback.'
        $foreignTail=$baseline+" `t`n`n"
        [IO.File]::WriteAllText($schedulerPath,$foreignTail,[Text.UTF8Encoding]::new($false))
        Refuse {Add-IW7MainEngineDebuggerOverlay $native 'a99c04937513530648573fd4ca2a05321a90b4a5' $owner}
        Check ([IO.File]::ReadAllText($schedulerPath) -ceq $foreignTail -and @($names|Where-Object{[IO.File]::Exists((Join-Path $component $_))}).Count -eq 0) 'Foreign trailing whitespace must remain exact with zero copies written.'
        [IO.File]::WriteAllText($schedulerPath,$baseline,[Text.UTF8Encoding]::new($false))
        $addDefinition=@($overlayAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)|Where-Object Name -CEQ 'Add-IW7MainEngineDebuggerOverlay')[0].Extent.Text
        $fakeAttributeBody=$addDefinition
        foreach($expression in @('[IO.File]::GetAttributes($guardPath)','[IO.File]::GetAttributes($target)')) {
            Check ($fakeAttributeBody.Split([string[]]@($expression),[StringSplitOptions]::None).Count -eq 2) 'Each actual metadata acquisition expression must occur once.'
            $variable=if($expression.Contains('$guardPath')){'$guardPath'}else{'$target'}
            $fakeAttributeBody=$fakeAttributeBody.Replace($expression,('(Get-SyntheticMainEngineAttributes '+$variable+')'))
        }
        function Get-SyntheticMainEngineAttributes([string]$Path) {
            if($Path -ceq $fakeReparsePath){return [IO.FileAttributes]::Directory -bor [IO.FileAttributes]::ReparsePoint}
            [IO.File]::GetAttributes($Path)
        }
        # Replace only the two metadata reads in the real function before calls;
        # no real junction, process or foreign Source path is created.
        . ([scriptblock]::Create($fakeAttributeBody))
        foreach($fakeReparsePath in @((Join-Path $native 'src'),(Join-Path $native 'src/client'),$component,$schedulerPath,(Join-Path $component $names[0]))) {
            Refuse {Add-IW7MainEngineDebuggerOverlay $native 'a99c04937513530648573fd4ca2a05321a90b4a5' $owner}
            Check ([IO.File]::ReadAllText($schedulerPath) -ceq $baseline -and @($names|Where-Object{[IO.File]::Exists((Join-Path $component $_))}).Count -eq 0) 'Synthetic reparse refusal must precede every Source write.'
        }
        . ([scriptblock]::Create($addDefinition))
        [IO.File]::WriteAllText($schedulerPath,($baseline+'// foreign'),[Text.UTF8Encoding]::new($false))
        Refuse {Add-IW7MainEngineDebuggerOverlay $native 'a99c04937513530648573fd4ca2a05321a90b4a5' $owner}
        Check (@($names|Where-Object{[IO.File]::Exists((Join-Path $component $_))}).Count -eq 0) 'Foreign scheduler refusal must create no copies.'
        [IO.File]::WriteAllText($schedulerPath,$baseline,[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $component $names[0]),'foreign',[Text.UTF8Encoding]::new($false))
        Refuse {Add-IW7MainEngineDebuggerOverlay $native 'a99c04937513530648573fd4ca2a05321a90b4a5' $owner}
        Check ([IO.File]::ReadAllText((Join-Path $component $names[0])) -ceq 'foreign') 'Existing foreign target must remain untouched.'
        [IO.File]::Delete((Join-Path $component $names[0]))
        $receipt=Add-IW7MainEngineDebuggerOverlay $native 'a99c04937513530648573fd4ca2a05321a90b4a5' $owner
        Check ([IO.File]::ReadAllText($schedulerPath) -ceq $converted) 'The real overlay must write the exact pure seam result.'
        Check ($receipt.Files.Count -eq 4 -and !$receipt.GSCOverlay -and !$receipt.GUIOverlay -and !$receipt.CapacityOverlay) 'Receipt must expose the bounded actual Source scope.'
        $changed=@('src/client/component/scheduler.cpp')
        $untracked=@($names|ForEach-Object{'src/client/component/'+$_})
        $measured=@(([pscustomobject]@{Relative=$changed[0];SHA256=(Get-FileHash -LiteralPath $schedulerPath).Hash}))+@($receipt.Files|ForEach-Object{[pscustomobject]@{Relative=$_.Relative;SHA256=(Get-FileHash -LiteralPath (Join-Path $native $_.Relative)).Hash}})
        Assert-IW7MainEngineDebuggerSourceState $changed $untracked $receipt $measured
        Refuse {Assert-IW7MainEngineDebuggerSourceState ($changed+'foreign.cpp') $untracked $receipt $measured}
        Refuse {Assert-IW7MainEngineDebuggerSourceState @() $untracked $receipt $measured}
        Refuse {Assert-IW7MainEngineDebuggerSourceState $changed ($untracked+'foreign.hpp') $receipt $measured}
        Refuse {Assert-IW7MainEngineDebuggerSourceState $changed @($untracked[0],$untracked[0],$untracked[2],$untracked[3]) $receipt $measured}
        $bad=@($measured|ForEach-Object{[pscustomobject]@{Relative=$_.Relative;SHA256=$_.SHA256}});$bad[0].SHA256='0'*64
        Refuse {Assert-IW7MainEngineDebuggerSourceState $changed $untracked $receipt $bad}
        Refuse {Assert-IW7MainEngineDebuggerSourceState $changed $untracked $receipt @($measured[0])}
    } finally {
        # Only this fresh synthetic Source directory is recursively removed.
        $full=[IO.Path]::GetFullPath($sourceSandbox)
        $temporary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
        if(!$full.StartsWith($temporary,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -cnotmatch '\Aiw7-main-engine-source-[0-9a-f]{32}\z'){throw 'Synthetic Source cleanup target differs.'}
        if([IO.Directory]::Exists($full)){[IO.Directory]::Delete($full,$true)}
    }
    Write-Output "PASS main-engine debugger Source: real guards/seam/fake-git Source copies, default omission-false parity and foreign refusals; $script:mainEngineSourceAssertions assertions. No native build or runtime."
}
Test-MainEngineDebuggerSource
if($MainEngineDebuggerSourceOnly){return}
. "$PSScriptRoot/../../ops/standard-client/Loading-NewMap.Core.ps1"
. "$PSScriptRoot/../../ops/Download-CacheOverlay.Core.ps1"
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
void check_download_mod() { const auto hash = get_file_hash(file_path); }
'@
$entry = 'utils::hook::jump(0x1409B04D2, utils::hook::assemble(loading_new_map_cl_stub));'
$contract = Assert-IW7StandardClientLoadingHook $source
Assert ($contract.PatchBytes -eq 5) 'Entry patch width was not qualified.'
Assert (([Convert]::ToInt64($contract.ResumeAddress, 16) - [Convert]::ToInt64($contract.PatchAddress, 16)) -eq $contract.PatchBytes) 'Continuation overlaps the entry patch.'
$explicitNear = $source.Replace($entry, $entry.Replace('));', '), false);'))
Assert-IW7StandardClientLoadingHook $explicitNear | Out-Null
Assert-IW7StandardClientLoadingHook ($source.Replace("`n", "`r`n")) | Out-Null
# The server profile's client hash-cache overlay preserves the same entry/stub.
Assert-IW7StandardClientLoadingHook (Convert-IW7DownloadCacheSource $source) | Out-Null
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
$voiceBuilder = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '../../ops/Build-Voice.ps1'))
$voiceGuard = $voiceBuilder.IndexOf('$loadingHook = Assert-IW7StandardClientLoadingHook')
Assert ($voiceGuard -gt $voiceBuilder.IndexOf('"$PSScriptRoot/Apply-DownloadCacheOverlay.ps1"') -and $voiceGuard -lt $voiceBuilder.IndexOf('& ./tools/premake5.exe')) 'ServerModules guard must run after the owned party overlay and before native project generation.'
if ($NativeRoot) {
    Assert-IW7StandardClientLoadingHook ([IO.File]::ReadAllText((Join-Path $NativeRoot 'src/client/component/party.cpp'))) | Out-Null
}
Write-Output 'PASS standard-client loading hook: five-byte continuation, far-jump regression, unknown-source refusals and prebuild guard.'
