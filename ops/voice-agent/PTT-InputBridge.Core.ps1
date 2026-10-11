# Pure transforms plus an explicit, bounded build-copy entry point. Importing
# performs no IO. PTT-InputBase.inc is input.cpp from CP SDK 77e6d4d24e918ee3...
# retained as readable source for independent tests, with its exact canonical pin.
function Get-IW7PTTBridgeHash([byte[]]$Bytes) {
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes))
}
function ConvertTo-IW7PTTBridgeCanonical([byte[]]$Bytes) {
    $text=[Text.UTF8Encoding]::new($false,$true).GetString($Bytes).Replace("`r`n","`n")
    if($text.Contains("`r")){throw 'Unknown PTT source newline shape; preserve source.'}
    [Text.UTF8Encoding]::new($false).GetBytes($text)
}
function Get-IW7PTTBridgeDependencies {
    @(
        @{File='deps/minhook/src/trampoline.c';SHA256='824ED887EC9DA606960962AF8973205D1F97CD03241E75517EBA485280FB6377';CanonicalSHA256='F13A169F803FF5A8E45C58CE668B4377A9878C0FC4452369B8A1325065186B2B'},
        @{File='deps/minhook/src/hook.c';SHA256='4005D39875CA4B8A957AABBA73BD053CBA77E50A8B383D48E0CB44C13F26669B';CanonicalSHA256='EDCCE4C81985D7DD5B73FEAE96D6498C8F749B1BCA4C3D2D9926EA9A17A84755'},
        @{File='deps/minhook/src/trampoline.h';SHA256='23681F7768D5DBD23EA14B45BA64E488A337501F23122253C532B05DBED4B85F';CanonicalSHA256='53ED9934492320617A27BFD952FFE7F5B7A4A1D09963D4512447082FE7B727B4'},
        @{File='deps/minhook/src/hde/hde64.c';SHA256='06B588A5140E15F0A55E13DDADC7E3A4648F3223CEFAB2D5285B796A422BB9F5';CanonicalSHA256='824EAFA315322E6DA105A7CE4EC1FC0E0ADEEE0106D32152FBB0B59E709BD15C'},
        @{File='deps/minhook/src/hde/hde64.h';SHA256='FD5B39E2865E12B9525EBDA8FD9E9658B341EAD5932D1BCB412A189F81CA42CA';CanonicalSHA256='E99AA4997BDA14B534C614C3D8CB78A72C4ACA91A1212C8B03EC605D1D75E36E'},
        @{File='deps/minhook/src/hde/table64.h';SHA256='0B6C69AD498E67907E0C574AB06123AEE4EC30C99FA181099EA929A8D820BFC1';CanonicalSHA256='B774446D2F110CE954FB0A710F4693C5562DDBD8D56FE84106F2EE80DB8B50A2'},
        @{File='src/common/utils/hook.cpp';SHA256='21D0281852037011ABBE17578D7542E32A8DE95B129DE6056BA010953B4C3C0A';CanonicalSHA256='CF82980799A5B8A1F19A3013986C5297E54A173FE13C310116B0B2F9DB38FBF7'},
        @{File='src/common/utils/hook.hpp';SHA256='A127D39D4CDEAF99B60F89FC36D8F925461A6E98824F542FD0CC68E2BE697DFD';CanonicalSHA256='A78110C8D5D1D36C33EB2807EBA37A1331C0352160C1C09871C42A95E62471A2'}
    )
}
function Assert-IW7PTTBridgeDependency([byte[]]$Bytes,$Pin) {
    $hash=Get-IW7PTTBridgeHash $Bytes
    if($hash -cnotin @($Pin.SHA256,$Pin.CanonicalSHA256) -or
        (Get-IW7PTTBridgeHash (ConvertTo-IW7PTTBridgeCanonical $Bytes)) -cne $Pin.CanonicalSHA256){
        throw ('Unknown PTT SDK dependency bytes: '+$Pin.File+'; preserve source.')
    }
    $hash
}
function Convert-IW7PTTBridgeAnchor([string]$Text,[string]$Old,[string]$New) {
    if(($Text.Split([string[]]@($Old),[StringSplitOptions]::None)).Count -ne 2){throw 'Exact single PTT input anchor required; preserve source.'}
    $Text.Replace($Old,$New)
}
function New-IW7PTTInputBridgeSource([byte[]]$CleanBytes,[byte[]]$TemplateBytes) {
    $clean=ConvertTo-IW7PTTBridgeCanonical $CleanBytes
    if((Get-IW7PTTBridgeHash $clean) -cne '9CF51FBEDB64BFEC414EC1B4B141875759C803791CF5AC9B360EF09DCFA428EF'){
        throw 'Exact pinned CP input.cpp required; preserve source.'
    }
    $encoding=[Text.UTF8Encoding]::new($false,$true)
    $text=$encoding.GetString($clean)
    $template=$encoding.GetString((ConvertTo-IW7PTTBridgeCanonical $TemplateBytes))
    if(!$template.EndsWith("`n") -or $template.Contains('REGISTER_COMPONENT') -or !$template.Contains('voice_ptt_capture_before_hook()')){
        throw 'Invalid PTT bridge template.'
    }
    $pch='#include <std_include.hpp>'
    $text=Convert-IW7PTTBridgeAnchor $text $pch ($pch+"`n"+'#define IW7_PARIS_ISOLATED_PTT_INPUT_BRIDGE 1'+"`n"+'#include "voice_ptt_guard.hpp"'+"`n"+'#include <utils/flags.hpp>'+"`n"+'#include <cstdio>')
    $class="`tclass component final : public component_interface"
    $text=Convert-IW7PTTBridgeAnchor $text $class ($template+"`n"+$class)
    $create="`t`t`tcl_execute_key_hook.create(0x14032A3B0, &cl_execute_key_stub);"
    $text=Convert-IW7PTTBridgeAnchor $text $create ("`t`t`tvoice_ptt_capture_before_hook();`n"+$create+"`n`t`t`tvoice_ptt_capture_owned_hook();")
    $registration='REGISTER_COMPONENT(input::component)'
    $wrapper=@'
namespace voice_ptt_guard
{
    result input_snapshot(unsigned char* destination, std::size_t size, unsigned long main_thread)
    {
        return input::read_voice_ptt_snapshot(destination, size, main_thread);
    }
}

'@
    $text=Convert-IW7PTTBridgeAnchor $text $registration ($wrapper.Replace("`r`n","`n")+"`n"+$registration)
    $encoding.GetBytes($text)
}
function Convert-IW7PTTFixtureSource([byte[]]$Bytes) {
    $encoding=[Text.UTF8Encoding]::new($false,$true)
    $text=$encoding.GetString($Bytes)
    $pch=[regex]::Matches($text,'(?m)^#include <std_include\.hpp>\r?$')
    if($pch.Count -ne 1 -or $pch[0].Index -ne 0 -or
        $text -match '(?m)^\s*#\s*define\s+IW7_PARIS_ISOLATED_PTT_INPUT_BRIDGE\b' -or
        @([regex]::Matches($text,'(?m)^#define IW7_PARIS_ISOLATED_VOICE_CAPTURE 1\r?$')).Count -ne 1){
        throw 'Exact isolated capture fixture prefix required; preserve source.'
    }
    $end=$pch[0].Length
    if($end -ge $text.Length -or $text[$end] -cne "`n"){throw 'PTT fixture PCH must end with a newline.'}
    $encoding.GetBytes($text.Substring(0,$end+1)+"#define IW7_PARIS_ISOLATED_PTT_INPUT_BRIDGE 1`n"+$text.Substring($end+1))
}
function Test-IW7PTTBridgeSameBaseline([string]$Hash,[string]$BaseHash) {
    # SDK physical input ends without LF (81C6 after CRLF->LF only). PowerShell
    # git-show joining adds one final LF (9CF5). These two exact known forms
    # are the only CP equivalents; whitespace/extra LF/unknown edits refuse.
    ($Hash -ceq $BaseHash) -or ($BaseHash -ceq '9CF51FBEDB64BFEC414EC1B4B141875759C803791CF5AC9B360EF09DCFA428EF' -and
        $Hash -ceq '81C6D9D826368C95331B0E0184F9A83B53E3E59AF1A4870BDF933F47037BDC20')
}
function Get-IW7PTTInputBridgeTransition([byte[]]$Current,[byte[]]$Base,[byte[]]$EnabledBytes,[byte[]]$Retained,[bool]$Enabled) {
    $canonicalHash=Get-IW7PTTBridgeHash (ConvertTo-IW7PTTBridgeCanonical $Current)
    $baseHash=Get-IW7PTTBridgeHash (ConvertTo-IW7PTTBridgeCanonical $Base)
    $overlayHash=Get-IW7PTTBridgeHash (ConvertTo-IW7PTTBridgeCanonical $EnabledBytes)
    $isBase=Test-IW7PTTBridgeSameBaseline $canonicalHash $baseHash
    if(!$isBase -and $canonicalHash -cne $overlayHash){throw 'Unowned input.cpp edit; preserve source.'}
    if($Enabled){
        if($baseHash -cne '9CF51FBEDB64BFEC414EC1B4B141875759C803791CF5AC9B360EF09DCFA428EF'){throw 'PTT bridge requires exact CP SDK.'}
        if($canonicalHash -ceq $overlayHash -and !$Retained){throw 'Owned PTT overlay lacks original byte receipt; preserve source.'}
        if($Retained -and !(Test-IW7PTTBridgeSameBaseline (Get-IW7PTTBridgeHash (ConvertTo-IW7PTTBridgeCanonical $Retained)) $baseHash)){throw 'PTT original byte receipt does not match SDK baseline.'}
        return ,$EnabledBytes
    }
    if($isBase){return ,$Current} # Normal profile: no write, exact bytes unchanged.
    if(!$Retained -or !(Test-IW7PTTBridgeSameBaseline (Get-IW7PTTBridgeHash (ConvertTo-IW7PTTBridgeCanonical $Retained)) $baseHash)){throw 'Cannot restore unknown/missing PTT original bytes.'}
    return ,$Retained
}
function Assert-IW7PTTBridgeAncestry([string]$Path) {
    $current=[IO.Path]::GetFullPath($Path)
    while($current){
        $item=$null
        try{$item=Get-Item -LiteralPath $current -Force -ErrorAction Stop}
        catch{if($_.CategoryInfo.Category -ne [Management.Automation.ErrorCategory]::ObjectNotFound){throw}}
        if($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'PTT bridge reparse ancestry refused; preserve source.'}
        $parent=[IO.Directory]::GetParent($current)
        if(!$parent){break}
        $current=$parent.FullName
    }
}
function Resolve-IW7PTTBridgePath([string]$Root,[string]$Relative) {
    $parent=[IO.Path]::GetFullPath($Root).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    $path=[IO.Path]::GetFullPath((Join-Path $parent $Relative))
    if(!$path.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase)){throw 'PTT bridge path leaves its owned root.'}
    Assert-IW7PTTBridgeAncestry $path
    $path
}
function Read-IW7PTTBridgeBytes([string]$Path) {
    Assert-IW7PTTBridgeAncestry $Path
    $item=Get-Item -LiteralPath $Path
    if($item.PSIsContainer -or $item.Length -le 0 -or $item.Length -gt 65536){throw 'PTT source size/type bound refused.'}
    ,[IO.File]::ReadAllBytes($item.FullName)
}
function Write-IW7PTTBridgeOriginalBytes([string]$Path,[byte[]]$Bytes) {
    Assert-IW7PTTBridgeAncestry $Path
    $stream=[IO.FileStream]::new($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$stream.Write($Bytes,0,$Bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
}
function Set-IW7PTTInputBridgeBuildCopy {
    param([string]$RepoRoot,[string]$NativeRoot,[byte[]]$BaseInput,[bool]$IsolatedLab,[bool]$ServerModules,[switch]$PlanOnly)
    $enabled=$IsolatedLab -and $ServerModules
    $helper=Resolve-IW7PTTBridgePath $RepoRoot 'ops/voice-agent/PTT-InputBridge.Core.ps1'
    $templatePath=Resolve-IW7PTTBridgePath $RepoRoot 'ops/voice-agent/PTT-InputBridge.inc'
    $pinnedPath=Resolve-IW7PTTBridgePath $RepoRoot 'ops/voice-agent/PTT-InputBase.inc'
    $pinned=Read-IW7PTTBridgeBytes $pinnedPath
    $template=Read-IW7PTTBridgeBytes $templatePath
    $overlay=New-IW7PTTInputBridgeSource $pinned $template
    $inputPath=Resolve-IW7PTTBridgePath $NativeRoot 'src/client/component/input.cpp'
    $retainPath=Resolve-IW7PTTBridgePath $NativeRoot 'paris-overlay-receipts/ptt-input-original.bin'
    $current=Read-IW7PTTBridgeBytes $inputPath
    $retained=$null
    if(Test-Path -LiteralPath $retainPath){$retained=Read-IW7PTTBridgeBytes $retainPath}
    $next=Get-IW7PTTInputBridgeTransition $current $BaseInput $overlay $retained $enabled
    $headerSource=Resolve-IW7PTTBridgePath $RepoRoot 'src/native/voice_ptt_guard.hpp'
    $headerTarget=Resolve-IW7PTTBridgePath $NativeRoot 'src/client/component/voice_ptt_guard.hpp'
    $headerBytes=Read-IW7PTTBridgeBytes $headerSource
    $headerHash=Get-IW7PTTBridgeHash $headerBytes
    if((Test-Path -LiteralPath $headerTarget) -and (Get-IW7PTTBridgeHash (Read-IW7PTTBridgeBytes $headerTarget)) -cne $headerHash){throw 'Unowned PTT guard header; preserve source.'}
    $fixturePath=Resolve-IW7PTTBridgePath $NativeRoot 'src/client/component/paris_test_fixture.cpp'
    $fixtureBytes=Read-IW7PTTBridgeBytes $fixturePath
    $nextFixture=$fixtureBytes
    $dependencies=@()
    if($enabled){
        . (Resolve-IW7PTTBridgePath $RepoRoot 'ops/voice-agent/Build-Copy.Core.ps1')
        $sourceFixture=Read-IW7PTTBridgeBytes (Resolve-IW7PTTBridgePath $RepoRoot 'src/native/paris_test_fixture.cpp')
        $expectedFixture=[Text.UTF8Encoding]::new($false).GetBytes((Convert-IW7IsolatedVoiceSource ([Text.UTF8Encoding]::new($false,$true).GetString($sourceFixture))))
        if((Get-IW7PTTBridgeHash $fixtureBytes) -cne (Get-IW7PTTBridgeHash $expectedFixture)){throw 'PTT fixture was not copied from the exact current source.'}
        $nextFixture=Convert-IW7PTTFixtureSource $fixtureBytes
        foreach($pin in Get-IW7PTTBridgeDependencies){
            $hash=Assert-IW7PTTBridgeDependency (Read-IW7PTTBridgeBytes (Resolve-IW7PTTBridgePath $NativeRoot $pin.File)) $pin
            $dependencies+=[pscustomobject]@{File=$pin.File;SHA256=$hash;CanonicalSHA256=$pin.CanonicalSHA256}
        }
        if(!$retained){$retained=$current}
    }
    # Validate the complete source set above before any write/remove. Never
    # discard an unknown target or accept generic E9/MinHook-shaped code.
    if(!$PlanOnly){
        if($enabled){
            if(!(Test-Path -LiteralPath $retainPath)){
                New-Item -ItemType Directory -Path (Split-Path $retainPath -Parent) -Force | Out-Null
                Write-IW7PTTBridgeOriginalBytes $retainPath $retained
            }
            foreach($path in @($headerTarget,$fixturePath,$inputPath)){Assert-IW7PTTBridgeAncestry $path}
            [IO.File]::WriteAllBytes($headerTarget,$headerBytes)
            [IO.File]::WriteAllBytes($fixturePath,$nextFixture)
        }elseif(Test-Path -LiteralPath $headerTarget){Assert-IW7PTTBridgeAncestry $headerTarget;Remove-Item -LiteralPath $headerTarget}
        Assert-IW7PTTBridgeAncestry $inputPath
        if((Get-IW7PTTBridgeHash $next) -cne (Get-IW7PTTBridgeHash $current)){[IO.File]::WriteAllBytes($inputPath,$next)}
    }
    [pscustomobject]@{
        Compiled=[bool]$enabled;Files=$(if($enabled){@('voice_ptt_guard.hpp')}else{@()});PlanOnly=[bool]$PlanOnly
        InputFile='src/client/component/input.cpp';InputBaseCanonicalSHA256=(Get-IW7PTTBridgeHash (ConvertTo-IW7PTTBridgeCanonical $BaseInput))
        InputBeforeSHA256=(Get-IW7PTTBridgeHash $current);InputCopiedSHA256=(Get-IW7PTTBridgeHash $next)
        OriginalInputRetentionFile='paris-overlay-receipts/ptt-input-original.bin';OriginalInputSHA256=$(if($retained){Get-IW7PTTBridgeHash $retained}else{Get-IW7PTTBridgeHash $current})
        HeaderSourceSHA256=$headerHash;HeaderCopiedSHA256=$(if($enabled){$headerHash}else{$null})
        FixtureCopiedSHA256=(Get-IW7PTTBridgeHash $nextFixture);SDKDependencies=$dependencies
        HelperSHA256=(Get-IW7PTTBridgeHash (Read-IW7PTTBridgeBytes $helper));TemplateSHA256=(Get-IW7PTTBridgeHash $template)
        InputBaseWitnessSHA256=(Get-IW7PTTBridgeHash $pinned)
        InputPhysicalBaselineSHA256='258C12FF209E14A89FAEE62160B9349714B1C984BE8B2D1A80220296800A13F1'
        InputPhysicalNormalizedSHA256='81C6D9D826368C95331B0E0184F9A83B53E3E59AF1A4870BDF933F47037BDC20'
        Activation='IsolatedLab AND ServerModules build; explicit private fake-capture relay client flags; original main-thread getter only; no audio/input authority'
        Shape='retail282 before create; owner tuple; E9->owned(original+19); trampoline5+FF25->retail+5; relay14->owned stub; live277/getter22/state20 each read'
    }
}
