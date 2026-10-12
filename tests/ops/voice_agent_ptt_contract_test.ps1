param([ValidateNotNullOrEmpty()][ValidateScript({[IO.Path]::IsPathFullyQualified($_)})][string]$NativeSdkRoot=(Join-Path $PSScriptRoot '../../tools/iw7-mod-native'))
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
$localSDK=[IO.Path]::GetFullPath($NativeSdkRoot)
Assert-IW7PTTBridgeAncestry $localSDK
if((Test-Path -LiteralPath $localSDK) -and !(Get-Item -LiteralPath $localSDK -Force).PSIsContainer){throw 'NativeSdkRoot must be a directory.'}
$encoding=[Text.UTF8Encoding]::new($false,$true)
$bridgeChecks=0
function Check-PTTBridge([bool]$Value,[string]$Message){$script:bridgeChecks++;if(!$Value){throw $Message}}
function Refuse-PTTBridge([scriptblock]$Action,[string]$Reason){
    $caught=$false
    try{& $Action | Out-Null}catch{$caught=$true;Check-PTTBridge ($_.Exception.Message.Contains($Reason)) ('Unexpected refusal: '+$_.Exception.Message)}
    Check-PTTBridge $caught ('Required refusal missing: '+$Reason)
}
# Extract only the pure root resolver and the generated command string. Never
# execute Build-Voice or import its scheduler/toolchain from this source test.
$buildErrors=$null;$buildTokens=$null
$buildAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'ops/Build-Voice.ps1'),[ref]$buildTokens,[ref]$buildErrors)
Check-PTTBridge (@($buildErrors).Count -eq 0) 'Build-Voice must parse.'
$rootFunctions=@($buildAst.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Resolve-IW7VoiceBuildNativeRoot'},$true))
Check-PTTBridge ($rootFunctions.Count -eq 1) 'One pure native root resolver required.'
. ([scriptblock]::Create($rootFunctions[0].Extent.Text))
$rootAssignments=@($buildAst.FindAll({param($node)$node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq '$root'},$true))
Check-PTTBridge ($rootAssignments.Count -eq 1 -and $rootAssignments[0].Right.Extent.Text -ceq 'Resolve-IW7VoiceBuildNativeRoot $NativeRoot') 'Every native operation must keep the single validated root.'
$firstImport=@($buildAst.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst] -and $node.InvocationOperator -eq [Management.Automation.Language.TokenKind]::Dot},$true))[0]
Check-PTTBridge ($rootAssignments[0].Extent.EndOffset -lt $firstImport.Extent.StartOffset) 'Root validation must precede scheduler import/admission.'
$rootParameter=@($buildAst.ParamBlock.Parameters | Where-Object {$_.Name.VariablePath.UserPath -ceq 'NativeRoot'})
Check-PTTBridge ($rootParameter.Count -eq 1 -and $rootParameter[0].DefaultValue.Extent.Text -ceq "(Join-Path `$PSScriptRoot '../tools/iw7-mod-native')") 'Historic default checkout must remain unchanged.'
$commandTemplates=@($buildAst.FindAll({param($node)$node -is [Management.Automation.Language.ExpandableStringExpressionAst] -and $node.Extent.Text.Contains('voice_agent_ptt_contract_test.ps1')},$true))
Check-PTTBridge ($commandTemplates.Count -eq 1 -and @($commandTemplates[0].NestedExpressions | Where-Object {$_ -isnot [Management.Automation.Language.VariableExpressionAst]}).Count -eq 0) 'Only a literal command template with variable substitutions may be expanded by this test.'
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
    $realRoot=Join-Path $temp 'real sdk';New-Item -ItemType Directory -Path $realRoot | Out-Null
    Check-PTTBridge ((Resolve-IW7VoiceBuildNativeRoot $realRoot) -ceq $realRoot) 'An explicitly supplied real checkout must retain its exact path, including spaces.'
    $missingRoot=Join-Path $realRoot 'future/checkout'
    Check-PTTBridge ((Resolve-IW7VoiceBuildNativeRoot $missingRoot) -ceq [IO.Path]::GetFullPath($missingRoot) -and !(Test-Path -LiteralPath $missingRoot)) 'Missing clone destination must validate without creation.'
    foreach($badRoot in @('', 'relative/sdk', ($realRoot+'%EXPAND%'), ($realRoot+'!EXPAND!'), ($realRoot+'"'), ($realRoot+"`n"))){Refuse-PTTBridge {Resolve-IW7VoiceBuildNativeRoot $badRoot} 'absolute literal directory path'}
    $generatedCommand=& {param($root,$repo,$runtime,$vcvars,$expression) & ([scriptblock]::Create($expression))} $realRoot $repo $temp 'unused-vcvars' $commandTemplates[0].Extent.Text
    $pttCommands=@($generatedCommand -split '\r?\n' | Where-Object {$_.Contains('voice_agent_ptt_contract_test.ps1')})
    Check-PTTBridge ($pttCommands.Count -eq 1 -and $pttCommands[0] -ceq ('pwsh -NoProfile -File "'+$repo+'\tests\ops\voice_agent_ptt_contract_test.ps1" -NativeSdkRoot "'+$realRoot+'"')) 'Generated PTT command must forward the exact selected checkout once, quoted.'
    $inputPath=Join-Path $temp 'src/client/component/input.cpp'
    $fixturePath=Join-Path $temp 'src/client/component/paris_test_fixture.cpp'
    $headerPath=Join-Path $temp 'src/client/component/voice_ptt_guard.hpp'
    $retainPath=Join-Path $temp 'paris-overlay-receipts/ptt-input-original.bin'
    [IO.File]::WriteAllBytes($inputPath,$crlf)
    [IO.File]::WriteAllBytes($fixturePath,$captureFixture)
    $boundedPath=Join-Path $temp 'bounded-source.cpp'
    [IO.File]::WriteAllBytes($boundedPath,[byte[]]::new(64KB))
    Refuse-PTTBridge {Resolve-IW7VoiceBuildNativeRoot $boundedPath} 'only directories'
    Refuse-PTTBridge {Resolve-IW7VoiceBuildNativeRoot (Join-Path $boundedPath 'child')} 'only directories'
    Check-PTTBridge ((Read-IW7PTTBridgeBytes $boundedPath).Length -eq 64KB) 'Ordinary sources must accept the exact 64 KiB boundary.'
    [IO.File]::WriteAllBytes($boundedPath,[byte[]]::new(64KB+1))
    Refuse-PTTBridge {Read-IW7PTTBridgeBytes $boundedPath} 'size/type bound refused'
    # A fixture filename alone must not opt into the larger limit.
    [IO.File]::WriteAllBytes($fixturePath,[byte[]]::new(64KB+1))
    Refuse-PTTBridge {Read-IW7PTTBridgeBytes $fixturePath} 'size/type bound refused'
    Check-PTTBridge ((Read-IW7PTTBridgeBytes $fixturePath -Fixture).Length -eq (64KB+1)) 'Explicit fixture reads must accept bytes above the ordinary bound.'
    [IO.File]::WriteAllBytes($fixturePath,[byte[]]::new(128KB))
    Check-PTTBridge ((Read-IW7PTTBridgeBytes $fixturePath -Fixture).Length -eq 128KB) 'Fixture reads must accept the exact 128 KiB boundary.'
    [IO.File]::WriteAllBytes($fixturePath,[byte[]]::new(128KB+1))
    Refuse-PTTBridge {Read-IW7PTTBridgeBytes $fixturePath -Fixture} 'size/type bound refused'
    Refuse-PTTBridge {Set-IW7PTTInputBridgeBuildCopy -RepoRoot $repo -NativeRoot $temp -BaseInput $clean -IsolatedLab $false -ServerModules $false} 'size/type bound refused'
    Check-PTTBridge ((Get-IW7PTTBridgeHash ([IO.File]::ReadAllBytes($inputPath))) -ceq (Get-IW7PTTBridgeHash $crlf) -and !(Test-Path -LiteralPath $headerPath) -and !(Test-Path -LiteralPath $retainPath)) 'Oversized fixture must refuse before source or receipt writes.'
    [IO.File]::WriteAllBytes($fixturePath,[byte[]]::new(0))
    Refuse-PTTBridge {Read-IW7PTTBridgeBytes $fixturePath -Fixture} 'size/type bound refused'
    Refuse-PTTBridge {Read-IW7PTTBridgeBytes $temp -Fixture} 'size/type bound refused'
    # Keep a valid capture prefix while guaranteeing a fixture above 64 KiB,
    # even if the real source becomes smaller in a later revision.
    $largeFixture=$encoding.GetBytes($encoding.GetString($captureFixture)+"`n/*"+('x'*[Math]::Max(0,65537-$captureFixture.Length))+"*/`n")
    [IO.File]::WriteAllBytes($fixturePath,$largeFixture)
    $largeRead=Read-IW7PTTBridgeBytes $fixturePath -Fixture
    Check-PTTBridge ($largeRead.Length -gt 64KB -and (Get-IW7PTTBridgeHash $largeRead) -ceq (Get-IW7PTTBridgeHash $largeFixture)) 'Large valid fixture bytes must survive the bounded read exactly.'
    Check-PTTBridge ($encoding.GetString((Convert-IW7PTTFixtureSource $largeRead)).Contains('#define IW7_PARIS_ISOLATED_PTT_INPUT_BRIDGE 1')) 'Large valid fixture must retain the scoped transform.'
    Refuse-PTTBridge {Set-IW7PTTInputBridgeBuildCopy -RepoRoot $repo -NativeRoot $temp -BaseInput $clean -IsolatedLab $true -ServerModules $true} 'not copied from the exact current source'
    Check-PTTBridge ((Get-IW7PTTBridgeHash ([IO.File]::ReadAllBytes($fixturePath))) -ceq (Get-IW7PTTBridgeHash $largeFixture) -and (Get-IW7PTTBridgeHash ([IO.File]::ReadAllBytes($inputPath))) -ceq (Get-IW7PTTBridgeHash $crlf) -and !(Test-Path -LiteralPath $headerPath) -and !(Test-Path -LiteralPath $retainPath)) 'Larger fixture allowance must not weaken provenance or permit partial writes.'
    [IO.File]::WriteAllBytes($fixturePath,$captureFixture)
    $outside=Join-Path $temp 'outside';New-Item -ItemType Directory -Path $outside | Out-Null
    $junction=Join-Path $temp 'junction'
    New-Item -ItemType Junction -Path $junction -Target $outside | Out-Null
    try{
        Refuse-PTTBridge {Resolve-IW7VoiceBuildNativeRoot $junction} 'reparse ancestry refused'
        Refuse-PTTBridge {Resolve-IW7VoiceBuildNativeRoot (Join-Path $junction 'missing/sdk')} 'reparse ancestry refused'
        Check-PTTBridge ((Resolve-IW7VoiceBuildNativeRoot $outside) -ceq $outside) 'Only the explicitly named real target may validate; never follow the junction.'
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
        Check-PTTBridge (!$normalPlan.Compiled -and !$normalPlan.Files.Count -and $normalPlan.InputCopiedSHA256 -ceq (Get-IW7PTTBridgeHash $crlf) -and $normalPlan.FixtureCopiedSHA256 -ceq (Get-IW7PTTBridgeHash $captureFixture)) 'Bridge must compile only for both scoped flags and preserve the exact current fixture bytes.'
    }
    Refuse-PTTBridge {Set-IW7PTTInputBridgeBuildCopy -RepoRoot $repo -NativeRoot $temp -BaseInput $clean -IsolatedLab $true -ServerModules $true} 'Cannot find path'
    Check-PTTBridge ((Get-IW7PTTBridgeHash ([IO.File]::ReadAllBytes($inputPath))) -ceq (Get-IW7PTTBridgeHash $crlf) -and !(Test-Path -LiteralPath $headerPath) -and !(Test-Path -LiteralPath $retainPath)) 'Missing SDK pins must refuse before any write.'
    # A local SDK, when already present, supplies only these eight small source
    # files to exercise real pins and positive IO. No clone/download is needed
    # for CI's independent transform/transition/adversarial contracts above.
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
    }else{'SKIP optional eight SDK source pins and temporary Plan/Install/Retire: selected NativeSdkRoot is absent.'}
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
