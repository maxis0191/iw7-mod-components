$ErrorActionPreference='Stop'
. "$PSScriptRoot/../../ops/voice-agent/PTT-Contract.Core.ps1"
$snapshot=[pscustomobject]@{ExactProcessIdentity=$true;OwnedSessionMatch=$true;IsolatedBuild=$true;ClientTestFlag=$true;IsolatedFlag=$true;MarkerVerified=$true;EngineProtected=$true;CgameInitialized=$true;NoInputCatchers=$true;VoiceEnabled=$false;VoiceAudioInitialized=$false;CaptureInterfacePresent=$false;NativeAudioProbeActive=$false;PTTActive=$false;Mode='CP';TestPort=27116;SafetyAgeMs=[long]50;TalkKey0=[int]0;TalkKey1=[int]0}
function Refuse($observation) { $refused=$false;try {New-IW7OrdinaryPTTPlan $observation | Out-Null}catch{$refused=$true};if(!$refused){throw 'Unowned/stale/audio PTT plan accepted.'} }
$plan=New-IW7OrdinaryPTTPlan $snapshot
if ($plan.PressBinding -ne 81 -or $plan.ReleaseBinding -ne 82 -or $plan.PhysicalKey -ne 222 -or !$plan.ReleaseOnAllExits -or $plan.ActionPerformed -or $plan.AudioActivated -or $plan.DvarChanged) { throw 'Plan must use ordinary bindings with owned release and no action.' }
$snapshot.Mode='MP';New-IW7OrdinaryPTTPlan $snapshot | Out-Null;$snapshot.Mode='CP'
foreach($name in @('ExactProcessIdentity','OwnedSessionMatch','IsolatedBuild','ClientTestFlag','IsolatedFlag','MarkerVerified','EngineProtected','CgameInitialized','NoInputCatchers')) {$snapshot.$name=$false;Refuse $snapshot;$snapshot.$name=$true}
foreach($name in @('VoiceEnabled','VoiceAudioInitialized','CaptureInterfacePresent','NativeAudioProbeActive','PTTActive')) {$snapshot.$name=$true;Refuse $snapshot;$snapshot.$name=$false}
$snapshot.SafetyAgeMs=[long]501;Refuse $snapshot;$snapshot.SafetyAgeMs=[long]50
$snapshot.TestPort=27016;Refuse $snapshot;$snapshot.TestPort=27116
$snapshot.TalkKey1=[int]86;Refuse $snapshot;$snapshot.TalkKey1=[int]0
$snapshot.VoiceEnabled=0;Refuse $snapshot;$snapshot.VoiceEnabled=$false
$snapshot.PSObject.Properties.Remove('CaptureInterfacePresent');Refuse $snapshot
'PASS ordinary CP/MP PTT dry contract; owner-held key, unknown audio state, enabled capture, wrong identity/UI/protection/port or stale safety refused; no dispatch/audio/dvar action.'

. "$PSScriptRoot/../../ops/voice-agent/PTT-InputBridge.Core.ps1"
. "$PSScriptRoot/../../ops/voice-agent/Build-Copy.Core.ps1"
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$encoding=[Text.UTF8Encoding]::new($false,$true)
$bridgeChecks=0
function Check-PTTBridge([bool]$Value,[string]$Message){$script:bridgeChecks++;if(!$Value){throw $Message}}
function Refuse-PTTBridge([scriptblock]$Action,[string]$Reason){
    $caught=$false
    try{& $Action | Out-Null}catch{$caught=$true;Check-PTTBridge ($_.Exception.Message.Contains($Reason)) ('Unexpected refusal: '+$_.Exception.Message)}
    Check-PTTBridge $caught ('Required refusal missing: '+$Reason)
}
$clean=[IO.File]::ReadAllBytes((Join-Path $repo 'ops/voice-agent/PTT-InputBase.inc'))
$template=[IO.File]::ReadAllBytes((Join-Path $repo 'ops/voice-agent/PTT-InputBridge.inc'))
$enabled=New-IW7PTTInputBridgeSource $clean $template
$baseText=$encoding.GetString((ConvertTo-IW7PTTBridgeCanonical $clean))
$enabledText=$encoding.GetString($enabled)
Check-PTTBridge ((Get-IW7PTTBridgeHash (ConvertTo-IW7PTTBridgeCanonical $clean)) -ceq '9CF51FBEDB64BFEC414EC1B4B141875759C803791CF5AC9B360EF09DCFA428EF') 'Pinned upstream source changed.'
Check-PTTBridge ($enabledText.Contains('#define IW7_PARIS_ISOLATED_PTT_INPUT_BRIDGE 1')) 'Enabled input lacks scoped bridge macro.'
Check-PTTBridge (([regex]::Matches($enabledText,'cl_execute_key_hook\.create\(0x14032A3B0, &cl_execute_key_stub\);')).Count -eq 1) 'Ordinary detour creation must remain exactly once.'
$stubStart=$baseText.IndexOf("`t`tvoid cl_execute_key_stub",[StringComparison]::Ordinal)
$stubEnd=$baseText.IndexOf("`n`t}`n`n`tclass component",$stubStart,[StringComparison]::Ordinal)
Check-PTTBridge ($stubStart -ge 0 -and $stubEnd -gt $stubStart -and $enabledText.Contains($baseText.Substring($stubStart,$stubEnd-$stubStart))) 'Ordinary 118-binding stub was altered.'
Check-PTTBridge ($enabledText.IndexOf('voice_ptt_capture_before_hook();',[StringComparison]::Ordinal) -lt $enabledText.IndexOf('cl_execute_key_hook.create(0x14032A3B0',[StringComparison]::Ordinal)) 'Prehook proof must precede actual detour creation.'
Check-PTTBridge ($enabledText.IndexOf('voice_ptt_capture_owned_hook();',[StringComparison]::Ordinal) -gt $enabledText.IndexOf('cl_execute_key_hook.create(0x14032A3B0',[StringComparison]::Ordinal)) 'Owner tuple must be captured from the created detour.'
Check-PTTBridge ($enabledText.Contains('cl_execute_key_hook.get_original()') -and $enabledText.Contains('voice_ptt_guard::validate_code(sample)') -and $enabledText.Contains('voice_ptt_guard::validate(sample)')) 'Live ownership and final state gates are required.'
Check-PTTBridge ($enabledText.IndexOf('proof = voice_ptt_guard::validate_code(sample);',[StringComparison]::Ordinal) -lt $enabledText.IndexOf('sample.getter_active = utils::hook::invoke',[StringComparison]::Ordinal)) 'Getter must execute only after safe code/data proof.'
$crlf=$encoding.GetBytes($baseText.TrimEnd("`n").Replace("`n","`r`n"))
Check-PTTBridge ((Get-IW7PTTBridgeHash $crlf) -ceq '258C12FF209E14A89FAEE62160B9349714B1C984BE8B2D1A80220296800A13F1') 'Physical CP baseline witness changed.'
foreach($inputBytes in @($clean,$crlf)){
    $normal=Get-IW7PTTInputBridgeTransition $inputBytes $clean $enabled $null $false
    Check-PTTBridge ((Get-IW7PTTBridgeHash $normal) -ceq (Get-IW7PTTBridgeHash $inputBytes)) 'Normal profile must preserve exact LF/CRLF bytes.'
    $scoped=Get-IW7PTTInputBridgeTransition $inputBytes $clean $enabled $null $true
    Check-PTTBridge ((Get-IW7PTTBridgeHash $scoped) -ceq (Get-IW7PTTBridgeHash $enabled)) 'Exact baseline failed scoped transition.'
    $restored=Get-IW7PTTInputBridgeTransition $enabled $clean $enabled $inputBytes $false
    Check-PTTBridge ((Get-IW7PTTBridgeHash $restored) -ceq (Get-IW7PTTBridgeHash $inputBytes)) 'Retirement must restore exact captured original bytes.'
}
$unknown=$encoding.GetBytes($baseText.Replace('return 118;','return 119;'))
Refuse-PTTBridge {New-IW7PTTInputBridgeSource $unknown $template} 'Exact pinned CP'
Refuse-PTTBridge {New-IW7PTTInputBridgeSource $enabled $template} 'Exact pinned CP'
Refuse-PTTBridge {New-IW7PTTInputBridgeSource ($encoding.GetBytes($baseText+"`n")) $template} 'Exact pinned CP'
Refuse-PTTBridge {Get-IW7PTTInputBridgeTransition $unknown $clean $enabled $null $true} 'Unowned input.cpp'
Refuse-PTTBridge {Get-IW7PTTInputBridgeTransition $unknown $clean $enabled $null $false} 'Unowned input.cpp'
Refuse-PTTBridge {Get-IW7PTTInputBridgeTransition $enabled $clean $enabled $null $true} 'lacks original byte receipt'
Refuse-PTTBridge {Get-IW7PTTInputBridgeTransition $enabled $clean $enabled $null $false} 'missing PTT original'
Refuse-PTTBridge {Get-IW7PTTInputBridgeTransition $enabled $clean $enabled $unknown $false} 'unknown/missing'
Refuse-PTTBridge {Get-IW7PTTInputBridgeTransition $clean $unknown $enabled $clean $true} 'Unowned input.cpp'
$fixtureSource=[IO.File]::ReadAllText((Join-Path $repo 'src/native/paris_test_fixture.cpp'))
$captureFixture=$encoding.GetBytes((Convert-IW7IsolatedVoiceSource $fixtureSource))
$bridgeFixture=Convert-IW7PTTFixtureSource $captureFixture
Check-PTTBridge ($encoding.GetString($bridgeFixture).Replace("`r`n","`n").StartsWith("#include <std_include.hpp>`n#define IW7_PARIS_ISOLATED_PTT_INPUT_BRIDGE 1`n#define IW7_PARIS_ISOLATED_VOICE_CAPTURE 1`n")) 'Fixture must share the scoped bridge definition.'
Refuse-PTTBridge {Convert-IW7PTTFixtureSource $bridgeFixture} 'Exact isolated capture fixture'
Refuse-PTTBridge {Convert-IW7PTTFixtureSource ($encoding.GetBytes($fixtureSource))} 'Exact isolated capture fixture'
Refuse-PTTBridge {Resolve-IW7PTTBridgePath $repo '../outside.cpp'} 'leaves its owned root'
$pins=@(Get-IW7PTTBridgeDependencies)
Check-PTTBridge ($pins.Count -eq 8 -and @($pins|ForEach-Object{$_.File}|Select-Object -Unique).Count -eq 8) 'Complete unique SDK owner/MinHook/HDE pins required.'
Check-PTTBridge (@($pins|Where-Object{$_.SHA256 -cnotmatch '^[0-9A-F]{64}$' -or $_.CanonicalSHA256 -cnotmatch '^[0-9A-F]{64}$'}).Count -eq 0) 'Exact SHA-256 pins required.'
foreach($pin in $pins){Refuse-PTTBridge {Assert-IW7PTTBridgeDependency ([byte[]]@(1,2,3)) $pin} 'Unknown PTT SDK dependency'}

# Bounded IO cases use temporary source trees. Never edit the real SDK, launch
# an engine/compiler, or import scheduler/device code from this pure test.
$temp=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('iw7-ptt-bridge-'+[guid]::NewGuid().ToString('N'))))
try{
    New-Item -ItemType Directory -Path (Join-Path $temp 'src/client/component') -Force | Out-Null
    $inputPath=Join-Path $temp 'src/client/component/input.cpp'
    $fixturePath=Join-Path $temp 'src/client/component/paris_test_fixture.cpp'
    $headerPath=Join-Path $temp 'src/client/component/voice_ptt_guard.hpp'
    $retainPath=Join-Path $temp 'paris-overlay-receipts/ptt-input-original.bin'
    [IO.File]::WriteAllBytes($inputPath,$crlf)
    [IO.File]::WriteAllBytes($fixturePath,$captureFixture)
    $outside=Join-Path $temp 'outside';New-Item -ItemType Directory -Path $outside | Out-Null
    $junction=Join-Path $temp 'junction'
    New-Item -ItemType Junction -Path $junction -Target $outside | Out-Null
    try{
        Refuse-PTTBridge {Resolve-IW7PTTBridgePath $temp 'junction/new.cpp'} 'reparse ancestry refused'
        Refuse-PTTBridge {Read-IW7PTTBridgeBytes (Join-Path $junction 'missing.cpp')} 'reparse ancestry refused'
        Refuse-PTTBridge {Write-IW7PTTBridgeOriginalBytes (Join-Path $junction 'new.bin') ([byte[]]@(1,2,3))} 'reparse ancestry refused'
        Check-PTTBridge (!(Test-Path -LiteralPath (Join-Path $outside 'new.bin'))) 'Junction target must remain unwritten.'
    }finally{Remove-Item -LiteralPath $junction -Force}
    $linkTarget=Join-Path $outside 'source.cpp';[IO.File]::WriteAllBytes($linkTarget,[byte[]]@(7,8,9))
    $fileLink=Join-Path $temp 'file-link.cpp';$fileLinkCreated=$false
    try{New-Item -ItemType SymbolicLink -Path $fileLink -Target $linkTarget -ErrorAction Stop | Out-Null;$fileLinkCreated=$true}
    catch{'INFO temporary file symlink unavailable without elevation; junction ancestry checks executed.'}
    if($fileLinkCreated){
        try{
            Refuse-PTTBridge {Read-IW7PTTBridgeBytes $fileLink} 'reparse ancestry refused'
            Refuse-PTTBridge {Write-IW7PTTBridgeOriginalBytes $fileLink ([byte[]]@(1,2,3))} 'reparse ancestry refused'
            Check-PTTBridge ((Get-IW7PTTBridgeHash ([IO.File]::ReadAllBytes($linkTarget))) -ceq (Get-IW7PTTBridgeHash ([byte[]]@(7,8,9)))) 'File symlink target must survive refusal.'
        }finally{Remove-Item -LiteralPath $fileLink -Force}
    }
    $collision=Join-Path $temp 'collision.bin';[IO.File]::WriteAllBytes($collision,[byte[]]@(7,8,9))
    Refuse-PTTBridge {Write-IW7PTTBridgeOriginalBytes $collision ([byte[]]@(1,2,3))} 'already exists'
    Check-PTTBridge ((Get-IW7PTTBridgeHash ([IO.File]::ReadAllBytes($collision))) -ceq (Get-IW7PTTBridgeHash ([byte[]]@(7,8,9)))) 'CreateNew collision must preserve original bytes.'
    foreach($profile in @(@($false,$false),@($true,$false),@($false,$true))){
        $normalPlan=Set-IW7PTTInputBridgeBuildCopy -RepoRoot $repo -NativeRoot $temp -BaseInput $clean -IsolatedLab $profile[0] -ServerModules $profile[1] -PlanOnly
        Check-PTTBridge (!$normalPlan.Compiled -and !$normalPlan.Files.Count -and $normalPlan.InputCopiedSHA256 -ceq (Get-IW7PTTBridgeHash $crlf)) 'Bridge must compile only for both scoped flags.'
    }
    Refuse-PTTBridge {Set-IW7PTTInputBridgeBuildCopy -RepoRoot $repo -NativeRoot $temp -BaseInput $clean -IsolatedLab $true -ServerModules $true} 'Cannot find path'
    Check-PTTBridge ((Get-IW7PTTBridgeHash ([IO.File]::ReadAllBytes($inputPath))) -ceq (Get-IW7PTTBridgeHash $crlf) -and !(Test-Path -LiteralPath $headerPath) -and !(Test-Path -LiteralPath $retainPath)) 'Missing SDK pins must refuse before any write.'
    # A local SDK, when already present, supplies only these eight small source
    # files to exercise real pins and positive IO. No clone/download is needed
    # for CI's independent transform/transition/adversarial contracts above.
    $localSDK=Join-Path $repo 'tools/iw7-mod-native'
    if(Test-Path -LiteralPath $localSDK){
        foreach($pin in $pins){
            $source=Read-IW7PTTBridgeBytes (Resolve-IW7PTTBridgePath $localSDK $pin.File)
            $actual=Assert-IW7PTTBridgeDependency $source $pin
            Check-PTTBridge ($actual -ceq $pin.SHA256 -or $actual -ceq $pin.CanonicalSHA256) 'Local SDK bytes must match the approved pin.'
            $destination=Resolve-IW7PTTBridgePath $temp $pin.File
            New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
            [IO.File]::WriteAllBytes($destination,$source)
        }
        $beforeInput=Get-IW7PTTBridgeHash ([IO.File]::ReadAllBytes($inputPath))
        $beforeFixture=Get-IW7PTTBridgeHash ([IO.File]::ReadAllBytes($fixturePath))
        $scopedPlan=Set-IW7PTTInputBridgeBuildCopy -RepoRoot $repo -NativeRoot $temp -BaseInput $clean -IsolatedLab $true -ServerModules $true -PlanOnly
        Check-PTTBridge ($scopedPlan.Compiled -and $scopedPlan.SDKDependencies.Count -eq 8 -and $scopedPlan.InputBaseWitnessSHA256 -ceq (Get-IW7PTTBridgeHash $clean)) 'Positive plan must contain the complete provenance set.'
        Check-PTTBridge ((Get-IW7PTTBridgeHash ([IO.File]::ReadAllBytes($inputPath))) -ceq $beforeInput -and (Get-IW7PTTBridgeHash ([IO.File]::ReadAllBytes($fixturePath))) -ceq $beforeFixture -and !(Test-Path -LiteralPath $retainPath) -and !(Test-Path -LiteralPath $headerPath)) 'PlanOnly must not change any source or receipt.'
        $installed=Set-IW7PTTInputBridgeBuildCopy -RepoRoot $repo -NativeRoot $temp -BaseInput $clean -IsolatedLab $true -ServerModules $true
        Check-PTTBridge ((Get-IW7PTTBridgeHash ([IO.File]::ReadAllBytes($inputPath))) -ceq $installed.InputCopiedSHA256 -and (Get-IW7PTTBridgeHash ([IO.File]::ReadAllBytes($fixturePath))) -ceq $installed.FixtureCopiedSHA256 -and (Get-IW7PTTBridgeHash ([IO.File]::ReadAllBytes($headerPath))) -ceq $installed.HeaderCopiedSHA256) 'Installed temporary overlay must match manifest pins.'
        Check-PTTBridge ((Get-IW7PTTBridgeHash ([IO.File]::ReadAllBytes($retainPath))) -ceq $beforeInput) 'Original physical bytes must be retained exactly.'
        $retired=Set-IW7PTTInputBridgeBuildCopy -RepoRoot $repo -NativeRoot $temp -BaseInput $clean -IsolatedLab $false -ServerModules $true
        Check-PTTBridge (!$retired.Compiled -and (Get-IW7PTTBridgeHash ([IO.File]::ReadAllBytes($inputPath))) -ceq $beforeInput -and !(Test-Path -LiteralPath $headerPath)) 'Retiring owned bridge must restore exact input and remove only owned header.'
        [IO.File]::WriteAllBytes($fixturePath,$captureFixture)
        $badDependency=Resolve-IW7PTTBridgePath $temp $pins[0].File
        [IO.File]::WriteAllBytes($badDependency,[byte[]]@(1,2,3))
        Refuse-PTTBridge {Set-IW7PTTInputBridgeBuildCopy -RepoRoot $repo -NativeRoot $temp -BaseInput $clean -IsolatedLab $true -ServerModules $true} 'Unknown PTT SDK dependency'
        Check-PTTBridge ((Get-IW7PTTBridgeHash ([IO.File]::ReadAllBytes($inputPath))) -ceq $beforeInput -and !(Test-Path -LiteralPath $headerPath)) 'Unknown dependency must refuse without partially applying overlay.'
        'PASS real eight SDK source pins and temporary-only Plan/Install/Retire; actual SDK untouched.'
    }
    [IO.File]::WriteAllBytes($inputPath,$unknown)
    Refuse-PTTBridge {Set-IW7PTTInputBridgeBuildCopy -RepoRoot $repo -NativeRoot $temp -BaseInput $clean -IsolatedLab $false -ServerModules $false} 'Unowned input.cpp'
    Check-PTTBridge ((Get-IW7PTTBridgeHash ([IO.File]::ReadAllBytes($inputPath))) -ceq (Get-IW7PTTBridgeHash $unknown)) 'Unknown input must survive refusal.'
    [IO.File]::WriteAllBytes($inputPath,$crlf)
    [IO.File]::WriteAllBytes($headerPath,[byte[]]@(1,2,3))
    Refuse-PTTBridge {Set-IW7PTTInputBridgeBuildCopy -RepoRoot $repo -NativeRoot $temp -BaseInput $clean -IsolatedLab $true -ServerModules $true} 'Unowned PTT guard'
    Check-PTTBridge ((Get-IW7PTTBridgeHash ([IO.File]::ReadAllBytes($headerPath))) -ceq (Get-IW7PTTBridgeHash ([byte[]]@(1,2,3)))) 'Unknown guard header must survive refusal.'
}finally{
    $prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(!$temp.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($temp) -notmatch '^iw7-ptt-bridge-[0-9a-f]{32}$'){throw 'Temporary cleanup target refused.'}
    if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force}
}
"PASS $bridgeChecks PTT bridge source/copy contracts; normal bytes preserved, only exact owner/profile/SDK accepted, no engine/compiler/audio calls."
