$ErrorActionPreference='Stop'
. "$PSScriptRoot/../../ops/agent-capacity/Provenance-LifecycleOverlay.Core.ps1"
. "$PSScriptRoot/../../ops/agent-capacity/Provenance-BuildCopy.Core.ps1"
$encoding=[Text.UTF8Encoding]::new($false,$true)
$checks=0
function Assert([bool]$Condition,[string]$Message){if(!$Condition){throw $Message};$script:checks++}
function Refuses([scriptblock]$Action,[string]$Message){$refused=$false;try{& $Action|Out-Null}catch{$refused=$true};Assert $refused $Message}
function Same([byte[]]$A,[byte[]]$B){(Get-IW7WordProvenanceHash $A) -ceq (Get-IW7WordProvenanceHash $B)}
$fixture=[IO.File]::ReadAllBytes("$PSScriptRoot/fixtures/word_provenance_main_77e.cpp.txt")
Assert ((Get-IW7WordProvenanceHash $fixture) -ceq 'B0C9D1E20D3169F9614178F08EDED7D9CA4A0250434F43E99C7990FF395A82E1') 'The whole reviewed SDK fixture changed.'
foreach($nl in @("`n","`r`n")){
    $clean=$encoding.GetBytes($encoding.GetString($fixture).Replace("`n",$nl))
    $o=New-IW7WordProvenanceLifecycleOverlays $clean
    $enabled=$encoding.GetString($o.Enabled)
    Assert (Same $o.Clean $clean) 'Clean bytes were normalized.'
    Assert (Same (Get-IW7WordProvenanceLifecycleTransition $o.Clean $o $false) $clean) 'Disabled ordinary profile changed bytes.'
    Assert (Same (Get-IW7WordProvenanceLifecycleTransition $o.Clean $o $true) $o.Enabled) 'Clean-to-enabled output differs.'
    Assert (Same (Get-IW7WordProvenanceLifecycleTransition $o.Enabled $o $true) $o.Enabled) 'Idempotent enable differs.'
    Assert (Same (Get-IW7WordProvenanceLifecycleTransition $o.Enabled $o $false) $clean) 'Enable/disable did not restore exact original bytes.'
    Assert (!$o.RestartImplemented -and !$o.ArxanModified -and !$o.PrioritiesModified) 'The transform broadened its profile.'
    Assert ($enabled.Contains('#include "component/paris_word_provenance.hpp"')) 'The included header is not in the copied component directory.'
    $load=$enabled.IndexOf('game::base_address = base_address;')
    $loaded=$enabled.IndexOf('paris_word_provenance::loaded_boundary();')
    $postload=$enabled.IndexOf('if (!component_loader::post_load()) return EXIT_FAILURE;')
    $arm=$enabled.IndexOf('paris_word_provenance::after_all_post_load();')
    $retail=$enabled.IndexOf('return static_cast<int>(entry_point());')
    Assert ($load -ge 0 -and $loaded -gt $load -and $loaded -lt $postload) 'Loaded snapshot is outside the validated base/post-load interval.'
    Assert ($arm -gt $postload -and $arm -lt $retail) 'Arm is not between all post_load and retail entry.'
    $between=$enabled.Substring($postload,$arm-$postload)
    Assert ($between.Contains('MH_ApplyQueued();')) 'Arm precedes queued post_load hook application.'
    $before=$enabled.IndexOf('paris_word_provenance::before_first_post_unpack();')
    $unpack=$enabled.IndexOf('component_loader::post_unpack();')
    $after=$enabled.IndexOf('paris_word_provenance::after_first_post_unpack();')
    $affinity=$enabled.IndexOf('return SetThreadAffinityMask(hThread, dwThreadAffinityMask);')
    Assert ($before -ge 0 -and $before -lt $unpack -and $after -gt $unpack -and $after -lt $affinity) 'Unpack boundaries are misplaced.'
    Assert ($enabled.Substring($unpack,$after-$unpack).Contains('MH_ApplyQueued();')) 'After snapshot is before the complete hook phase.'
    Assert (($enabled.Split([string[]]@('paris_word_provenance::'),[StringSplitOptions]::None)).Count -eq 5) 'Unexpected number of direct lifecycle calls.'
    Assert (!$enabled.Contains('arxan::') -and !$enabled.Contains('component_priority') -and !$enabled.Contains('map_restart')) 'Unrelated policy or restart appeared.'
    $unknown=$encoding.GetBytes($enabled+'// unowned')
    $hash=Get-IW7WordProvenanceHash $unknown
    Refuses {Get-IW7WordProvenanceLifecycleTransition $unknown $o $true} 'Unknown enabled edit accepted.'
    Refuses {Get-IW7WordProvenanceLifecycleTransition $unknown $o $false} 'Unknown bytes were reset by disable.'
    Assert ((Get-IW7WordProvenanceHash $unknown) -ceq $hash) 'Refusal changed input bytes.'
}
foreach($bad in @($encoding.GetBytes($encoding.GetString($fixture)+'// mutation'),[byte[]]@(0xff),[byte[]]@())){
    Refuses {New-IW7WordProvenanceLifecycleOverlays $bad} 'Unpinned clean bytes accepted.'
}
Refuses {Convert-IW7WordProvenanceAnchor 'one' 'absent' 'new'} 'Missing lifecycle anchor accepted.'
Refuses {Convert-IW7WordProvenanceAnchor 'one one' 'one' 'new'} 'Duplicate lifecycle anchor accepted.'
Assert ((Convert-IW7WordProvenanceAnchor 'before one after' 'one' 'two') -ceq 'before two after') 'Exact anchor replacement failed.'
Assert-IW7WordProvenanceBuildProfile $true $true $true $true STARTUP; $checks++
Assert-IW7WordProvenanceBuildProfile $false $false $false $false STARTUP; $checks++
foreach($triple in @(@($false,$true,$true),@($true,$false,$true),@($true,$true,$false))){
    Refuses {Assert-IW7WordProvenanceBuildProfile $true $triple[0] $triple[1] $triple[2] STARTUP} 'Incomplete isolated/debugger build profile accepted.'
}
Refuses {Assert-IW7WordProvenanceBuildProfile $true $true $true $true RESTART} 'Restart build accepted.'
Refuses {Assert-IW7WordProvenanceBuildProfile $false $false $false $false RESTART} 'Disabled call silently reinterpreted Restart.'

# Filesystem adapters use only a new isolated temp source/target fixture. No native checkout or binary is touched.
$tempBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$temp=Join-Path $tempBase ('iw7-word-provenance-tests-'+[guid]::NewGuid().ToString('N'))
$fakeRepo=Join-Path $temp 'repo';$fakeNative=Join-Path $temp 'sdk'
$sourceRoot=Join-Path $fakeRepo 'src/native';$targetRoot=Join-Path $fakeNative 'src/client/component'
$directories=@($temp,$fakeRepo,(Join-Path $fakeRepo 'src'),$sourceRoot,$fakeNative,(Join-Path $fakeNative 'src'),(Join-Path $fakeNative 'src/client'),$targetRoot)
$files=@()
try{
    foreach($d in $directories){[IO.Directory]::CreateDirectory($d)|Out-Null}
    foreach($name in @('paris_word_provenance.cpp','paris_word_provenance.hpp')){
        $source=Join-Path $sourceRoot $name;$target=Join-Path $targetRoot $name
        $files+=@($source,$target);[IO.File]::WriteAllText($source,('owned synthetic bytes '+$name),$encoding)
    }
    $params=@{RepoRoot=$fakeRepo;NativeRoot=$fakeNative;Enabled=$true;IsolatedLab=$true;ServerModules=$true;Debugger=$true}
    $plan=Set-IW7WordProvenanceBuildCopy @params
    Assert ($plan.PlanOnly -and !$plan.Compiled -and !$plan.NativeCompilationPerformed -and $plan.Enabled) 'PlanOnly claimed compilation or applied copy.'
    Assert (@(Get-ChildItem -LiteralPath $targetRoot -File).Count -eq 0) 'PlanOnly wrote files.'
    Assert ($plan.SourceHashes.Count -eq 2 -and !$plan.RestartImplemented) 'Source copy plan scope differs.'
    $applied=Set-IW7WordProvenanceBuildCopy @params -Apply
    Assert (!$applied.PlanOnly -and $applied.Compiled -and !$applied.NativeCompilationPerformed) 'Copy receipt conflates copying with compilation.'
    foreach($row in $applied.SourceHashes){Assert ((Get-FileHash -LiteralPath (Join-Path $targetRoot $row.File) -Algorithm SHA256).Hash -ceq $row.SHA256) 'Copy hash differs.'}
    $again=Set-IW7WordProvenanceBuildCopy @params -Apply
    Assert ($again.Compiled) 'Identical retained copy refused.'
    $disabled=Set-IW7WordProvenanceBuildCopy -RepoRoot $fakeRepo -NativeRoot $fakeNative -Enabled $false
    Assert ($disabled.PlanOnly -and @(Get-ChildItem -LiteralPath $targetRoot -File).Count -eq 2) 'Disabled PlanOnly removed files.'
    $unknown=Join-Path $targetRoot 'paris_word_provenance.hpp';[IO.File]::WriteAllText($unknown,'unowned header',$encoding)
    $cpp=Join-Path $targetRoot 'paris_word_provenance.cpp';$cppBefore=(Get-FileHash -LiteralPath $cpp -Algorithm SHA256).Hash
    Refuses {Set-IW7WordProvenanceBuildCopy @params -Apply} 'Unknown header accepted on enable.'
    Refuses {Set-IW7WordProvenanceBuildCopy -RepoRoot $fakeRepo -NativeRoot $fakeNative -Enabled $false -Apply} 'Unknown header accepted on disable.'
    Assert ((Get-FileHash -LiteralPath $cpp -Algorithm SHA256).Hash -ceq $cppBefore) 'Second-file refusal mutated the first copy.'
    Assert ([IO.File]::ReadAllText($unknown) -ceq 'unowned header') 'Unknown target was replaced.'
    [IO.File]::WriteAllBytes($unknown,[IO.File]::ReadAllBytes((Join-Path $sourceRoot 'paris_word_provenance.hpp')))
    $removed=Set-IW7WordProvenanceBuildCopy -RepoRoot $fakeRepo -NativeRoot $fakeNative -Enabled $false -Apply
    Assert (!$removed.Compiled -and @(Get-ChildItem -LiteralPath $targetRoot -File).Count -eq 0) 'Disabled profile retained its exact owned TU.'
    $params.Mode='RESTART'
    Refuses {Set-IW7WordProvenanceBuildCopy @params -Apply} 'Copy helper admitted Restart.'
    Assert (@(Get-ChildItem -LiteralPath $targetRoot -File).Count -eq 0) 'Restart refusal wrote a file.'
}finally{
    # Finite paths created by this test only; never recursive shell deletion.
    foreach($p in $files){
        $absolute=[IO.Path]::GetFullPath($p)
        if(!$absolute.StartsWith([IO.Path]::GetFullPath($temp)+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe test cleanup target'}
        if([IO.File]::Exists($absolute)){[IO.File]::Delete($absolute)}
    }
    for($i=$directories.Count-1;$i -ge 0;$i--){if([IO.Directory]::Exists($directories[$i])){[IO.Directory]::Delete($directories[$i],$false)}}
}
Write-Output "PASS $checks STARTUP lifecycle/profile/copy checks; exact fixture, no SDK mutation, no compiler/native API/lease/Run."
