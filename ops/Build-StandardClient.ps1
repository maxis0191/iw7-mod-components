param([Parameter(Mandatory)][string]$NativeRoot,[ValidateRange(1,2)][int]$BuildJobs=1,[switch]$OwnerCheats,[switch]$Capacity64,[switch]$MainEngineDebugger,
    [scriptblock]$NativeStageRunner=$null,[scriptblock]$BeforeReleaseCheck=$null,[object]$OriginalContext=$null,[object]$RetentionRoot=$null)
$ErrorActionPreference='Stop'
function Assert-IW7StandardDebuggerOptions([bool]$Enabled,[bool]$OwnerCheats,[bool]$Capacity64) {
    if($Enabled -and ($OwnerCheats -or $Capacity64)){throw 'MainEngineDebugger is exclusive with OwnerCheats and Capacity64.'}
}
function Test-IW7StandardControlledBuild([bool]$Enabled,[Collections.IDictionary]$Bound) {
    $names=@('NativeStageRunner','BeforeReleaseCheck','OriginalContext','RetentionRoot')
    if(!@($names|Where-Object{$Bound.ContainsKey($_)}).Count){return $false}
    if(!$Enabled){throw 'Controlled native stages require MainEngineDebugger.'}
    foreach($name in $names){
        if(!$Bound.ContainsKey($name) -or $null -eq $Bound[$name]){throw 'NativeStageRunner, BeforeReleaseCheck, OriginalContext and RetentionRoot must be supplied together and non-null.'}
    }
    return $true
}
function Invoke-IW7StandardNativeStage([scriptblock]$Runner,[ValidateSet('Premake','MSBuild')][string]$Stage,[string]$FilePath,[string[]]$ArgumentList,[string]$WorkingDirectory) {
    $exitCode=& $Runner -Stage $Stage -FilePath $FilePath -ArgumentList $ArgumentList -WorkingDirectory $WorkingDirectory
    if($exitCode -isnot [int]){throw 'NativeStageRunner must return exactly one Int32 exit code.'}
    if($exitCode -ne 0){throw "Standard client $Stage failed with exit code $exitCode."}
}
Assert-IW7StandardDebuggerOptions ([bool]$MainEngineDebugger) ([bool]$OwnerCheats) ([bool]$Capacity64)
$controlledBuild=Test-IW7StandardControlledBuild ([bool]$MainEngineDebugger) $PSBoundParameters
$repo=Split-Path $PSScriptRoot -Parent
$profile=(Get-Content -LiteralPath (Join-Path $repo 'client-profiles.json') -Raw | ConvertFrom-Json).Standard
. "$PSScriptRoot/standard-client/Loading-NewMap.Core.ps1"
if(!$MainEngineDebugger){
    . "$PSScriptRoot/Owner-CheatsOverlay.Core.ps1"
    . "$PSScriptRoot/Cutscene-Overlay.Core.ps1"
    . "$PSScriptRoot/agent-capacity/Peer-Overlay.Core.ps1"
    . "$PSScriptRoot/agent-capacity/Build-Copy.Core.ps1"
}
$root=[IO.Path]::GetFullPath($NativeRoot).TrimEnd('\','/')
if(![IO.Path]::IsPathFullyQualified($NativeRoot) -or $NativeRoot -match '[\x00-\x1f"%!]'){throw 'Absolute literal NativeRoot required.'}
$cursor=$root
while($cursor){
    if((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Redirected native source ancestry refused.'}
    $parent=Split-Path $cursor -Parent;if($parent -eq $cursor){break};$cursor=$parent
}
. "$PSScriptRoot/Resource-Scheduler.Core.ps1"
$admissionOptions=@{}
if($MainEngineDebugger){$admissionOptions.RequireNewLease=$true}
if($controlledBuild){
    $admissionOptions.BeforeReleaseCheck=$BeforeReleaseCheck
    $admissionOptions.OriginalContext=$OriginalContext
    $admissionOptions.RetentionRoot=$RetentionRoot
}
Invoke-IW7ResourceJob -Scope $repo -Owner 'CB compatible standard client native build' -PhysicalBytes (4GB*$BuildJobs) -CommitBytes (6GB*$BuildJobs) @admissionOptions -Body {
    if(!$MainEngineDebugger){
        Remove-IW7CapacityPeerOverlay $root
        Remove-IW7CutsceneOverlay $root
        Remove-IW7OwnerCheatsOverlay $root
    }
    if(!(Test-Path -LiteralPath (Join-Path $root '.git'))){
        if($MainEngineDebugger){throw 'Main-engine debugger requires an existing clean Standard checkout; no implicit clone.'}
        git clone --no-checkout $profile.Repository $root
        if($LASTEXITCODE){throw 'Standard client source clone failed.'}
        $previous=$env:GIT_LFS_SKIP_SMUDGE
        try {$env:GIT_LFS_SKIP_SMUDGE='1';git -C $root checkout --detach $profile.Revision;if($LASTEXITCODE){throw 'Exact standard client pin checkout failed.'}}
        finally {if($null -eq $previous){Remove-Item Env:GIT_LFS_SKIP_SMUDGE -ErrorAction SilentlyContinue}else{$env:GIT_LFS_SKIP_SMUDGE=$previous}}
    }
    if((& git -C $root rev-parse HEAD).Trim() -cne $profile.Revision){throw 'Exact standard client pin required; preserve other checkouts.'}
    if(!$MainEngineDebugger){$null=Set-IW7CapacityWatchBuildCopy -RepoRoot $repo -NativeRoot $root -Enabled $false -PortOnly $true}
    git -C $root diff --quiet HEAD
    if($LASTEXITCODE){throw 'Modified tracked standard client source refused.'}
    $untracked=@(& git -C $root ls-files --others --exclude-standard src)
    if($untracked.Count){throw 'Untracked native source refused; a prior Paris build must be retired with its exact hash receipt.'}
    foreach($ancestor in @($profile.CBBase,$profile.OfficialUpstream)){
        git -C $root merge-base --is-ancestor $ancestor HEAD
        if($LASTEXITCODE){throw 'Required upstream ancestry missing.'}
    }
    if(Test-Path -LiteralPath (Join-Path $root 'src/client/component/player_movement.cpp')){throw 'Retired duplicate movement translation unit present.'}
    foreach($required in @('nat.cpp','friends.cpp','ipc.cpp','upnp.cpp','discord.cpp')){
        if(!(Test-Path -LiteralPath (Join-Path $root ('src/client/component/'+$required)))){throw 'CB compatibility source missing.'}
    }
    $loadingHook = Assert-IW7StandardClientLoadingHook ([IO.File]::ReadAllText((Join-Path $root 'src/client/component/party.cpp')))
    git -C $root submodule sync --recursive
    git -C $root submodule update --init --recursive
    if($LASTEXITCODE){throw 'Pinned standard client submodules unavailable.'}
    $vswhere="${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    $installation=& $vswhere -products '*' -version '[17.0,18.0)' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Select-Object -First 1
    if(!$installation){throw 'VS2022 C++ toolchain required.'}
    $runtime=Join-Path $repo 'runtime'
    [IO.Directory]::CreateDirectory($runtime)|Out-Null
    $wrapperSource=Join-Path $PSScriptRoot 'standard-client/premake-build-only.lua'
    $wrapper=Join-Path $root 'paris-build-only.lua'
    if((Test-Path -LiteralPath $wrapper) -and (Get-FileHash $wrapper).Hash -ne (Get-FileHash $wrapperSource).Hash){throw 'Unowned build-only Premake wrapper; preserve it.'}
    Copy-Item -LiteralPath $wrapperSource -Destination $wrapper -Force
    $cutsceneOverlay=$null
    $ownerCheatsOverlay=$null
    $capacityPeerOverlay=$null
    $capacityBuild=$null
    $mainEngineOverlay=$null
    if($OwnerCheats){$ownerCheatsOverlay=Add-IW7OwnerCheatsOverlay $root $repo;$cutsceneOverlay=Add-IW7CutsceneOverlay $root $repo}
    if($Capacity64){
        $capacityBuild=Set-IW7CapacityWatchBuildCopy -RepoRoot $repo -NativeRoot $root -Enabled $true -PortOnly $true
        $capacityPeerOverlay=Add-IW7CapacityPeerOverlay $root
    }
    if($MainEngineDebugger){
        # Load only this explicit Standard mode after HEAD/dirty/untracked guards.
        $mainEngineOverlay=. "$PSScriptRoot/Apply-DebuggerOverlay.ps1" -NativeRoot $root -Commit $profile.Revision -Enabled -MainEngineOnly
    }
    Push-Location $root
    try {
        if($controlledBuild){
            Invoke-IW7StandardNativeStage -Runner $NativeStageRunner -Stage 'Premake' -FilePath (Join-Path $root 'tools/premake5.exe') -ArgumentList ([string[]]@('--file=paris-build-only.lua','vs2022')) -WorkingDirectory $root
        }else{
            & ./tools/premake5.exe --file=paris-build-only.lua vs2022
            if($LASTEXITCODE){throw 'Standard client Premake failed.'}
        }
        $project=Join-Path $root 'build/client.vcxproj'
        $projectText=[IO.File]::ReadAllText($project)
        [xml]$generatedProject=$projectText
        $postBuildNodes=@($generatedProject.SelectNodes("//*[local-name()='PostBuildEvent']/*[local-name()='Command']")|Where-Object{![string]::IsNullOrWhiteSpace($_.InnerText)})
        if($postBuildNodes.Count){throw 'Automatic upstream copy/deployment post-build events refused before MSBuild.'}
        if($projectText -match '(?:paris_voice|voice_relay|paris_test_fixture|player_movement)\.cpp'){throw 'Unexpected private or duplicate translation unit in regenerated client project.'}
        if($controlledBuild){
            Invoke-IW7StandardNativeStage -Runner $NativeStageRunner -Stage 'MSBuild' -FilePath "$installation/MSBuild/Current/Bin/MSBuild.exe" -ArgumentList ([string[]]@('build/iw7-mod.sln',"/m:$BuildJobs",'/nr:false','/v:minimal','/p:Configuration=Release','/p:Platform=x64','/p:MultiProcessorCompilation=false','/p:PostBuildEventUseInBuild=false',"/flp:logfile=$runtime/standard-client-build.log;verbosity=minimal")) -WorkingDirectory $root
        }else{
            & "$installation/MSBuild/Current/Bin/MSBuild.exe" build/iw7-mod.sln "/m:$BuildJobs" /nr:false /v:minimal /p:Configuration=Release /p:Platform=x64 /p:MultiProcessorCompilation=false /p:PostBuildEventUseInBuild=false "/flp:logfile=$runtime/standard-client-build.log;verbosity=minimal"
            if($LASTEXITCODE){throw 'Standard client native build failed.'}
        }
    } finally {Pop-Location}
    if($MainEngineDebugger){
        $changed=@(& git -C $root diff --name-only HEAD);if($LASTEXITCODE){throw 'Debugger tracked source inventory failed.'}
        $untracked=@(& git -C $root ls-files --others --exclude-standard src);if($LASTEXITCODE){throw 'Debugger untracked source inventory failed.'}
        $expected=@([pscustomobject]@{Relative='src/client/component/scheduler.cpp';SHA256=$mainEngineOverlay.SchedulerSHA256})+@($mainEngineOverlay.Files)
        $measured=@($expected|ForEach-Object{[pscustomobject]@{Relative=$_.Relative;SHA256=(Get-FileHash -LiteralPath (Join-Path $root $_.Relative)).Hash}})
        Assert-IW7MainEngineDebuggerSourceState $changed $untracked $mainEngineOverlay $measured
    }elseif($OwnerCheats -or $Capacity64){
        $changed=@(& git -C $root diff --name-only HEAD)
        $allowed=@()
        if($OwnerCheats){$allowed+=@('src/client/component/auth.cpp','src/client/component/command.cpp','src/client/component/dvar_cheats.cpp','src/client/component/gsc/script_extension.cpp','src/client/component/gsc/script_loading.cpp','src/client/component/input.cpp')}
        if($Capacity64){$allowed+=@('src/client/component/auth.cpp','src/client/component/party.cpp')}
        if(@($changed|Where-Object{$_ -cnotin $allowed}).Count){throw 'Build modified unowned tracked client source.'}
        foreach($row in $ownerCheatsOverlay.Files){
            $peer=@($capacityPeerOverlay.Files|Where-Object Name -CEQ $row.Name)
            $expected=if($peer.Count){$peer[0].AfterSHA256}else{$row.AfterSHA256}
            if((Get-FileHash -LiteralPath (Join-Path $root ('src/client/component/'+$row.Name))).Hash -cne $expected){throw 'Build modified owner-cheats input.'}
        }
        foreach($row in $capacityPeerOverlay.Files){if((Get-FileHash -LiteralPath (Join-Path $root ('src/client/component/'+$row.Name))).Hash -cne $row.AfterSHA256){throw 'Build modified capacity peer input.'}}
    }else{
        git -C $root diff --quiet HEAD
        if($LASTEXITCODE){throw 'Build unexpectedly modified tracked standard client source.'}
    }
    $output=if($MainEngineDebugger){Join-Path $runtime 'standard-client-main-engine-debugger-package'}else{Join-Path $runtime 'standard-client-package'}
    if(Test-Path -LiteralPath $output){throw 'Fresh standard client package output required.'}
    [IO.Directory]::CreateDirectory($output)|Out-Null
    foreach($file in @('iw7-mod.exe','iw7-mod.pdb')){Copy-Item -LiteralPath (Join-Path $root ('build/bin/x64/Release/'+$file)) -Destination (Join-Path $output $file)}
    if($Capacity64){
        Copy-Item -LiteralPath (Join-Path $repo 'config/Launch-IW7-Paris48.bat') -Destination $output
        Copy-Item -LiteralPath (Join-Path $output 'iw7-mod.exe') -Destination (Join-Path $output 'iw7-paris48.exe')
    }
    $identity=& "$PSScriptRoot/Get-SourceIdentity.ps1" -Root $repo
    $manifest=[ordered]@{Schema='iw7.standard-client-build/1';NativeRevision=$profile.Revision;NativeTree=(& git -C $root rev-parse 'HEAD^{tree}').Trim();OfficialUpstream=$profile.OfficialUpstream;CBBase=$profile.CBBase;ProjectCommit=$identity.Commit;SourceIdentity=$identity;SHA256=(Get-FileHash (Join-Path $output 'iw7-mod.exe')).Hash;SymbolsSHA256=(Get-FileHash (Join-Path $output 'iw7-mod.pdb')).Hash;BuiltUtc=[datetime]::UtcNow.ToString('o');AutoUpdate='Locally merged profile: retain existing CB updater URL, launch using documented -noupdate to prevent an older remote binary/data overwrite';NativeSourceHashes=@(Get-ChildItem -LiteralPath (Join-Path $root 'src') -Recurse -File|Sort-Object FullName|ForEach-Object{@{File=[IO.Path]::GetRelativePath($root,$_.FullName).Replace('\','/');SHA256=(Get-FileHash $_.FullName).Hash}});GeneratedProjectSHA256=(Get-FileHash $project).Hash;BuildOnlyWrapperSHA256=(Get-FileHash $wrapper).Hash;AutoCopySuppressed=$true;GameplayAcceptance='Pending owner gameplay; no FPS, WAN, NAT or microphone claim'}
    $manifest.LoadingNewMapHook=$loadingHook
    $manifest.OwnerCheatsEnabled=[bool]$OwnerCheats
    $manifest.OwnerCheatsOverlay=$ownerCheatsOverlay
    $manifest.CutsceneOverlay=$cutsceneOverlay
    $manifest.Capacity64Capability=[bool]$Capacity64
    $manifest.CapacityWireContract=if($Capacity64){'64-v2'}else{$null}
    $manifest.CapacityBuild=$capacityBuild
    $manifest.CapacityPeerOverlay=$capacityPeerOverlay
    $manifest.CapacityPeerHelperSHA256=if($capacityPeerOverlay){(Get-FileHash -LiteralPath "$PSScriptRoot/agent-capacity/Peer-Overlay.Core.ps1").Hash}else{$null}
    $manifest.CapacityLauncherSHA256=if($Capacity64){(Get-FileHash -LiteralPath (Join-Path $output 'Launch-IW7-Paris48.bat')).Hash}else{$null}
    if($MainEngineDebugger){
        $manifest.MainEngineDebugger=$true
        $manifest.MainEngineDebuggerOverlay=$mainEngineOverlay
        $manifest.Instrumentation='Standard main-engine scope2 only; no GUI/GSC/capacity overlays. The unchanged TU can register three GSC natives under its explicit runtime flags.'
        $manifest.RuntimeQualification='None: build-only; no privacy, protection, lifecycle or performance acceptance.'
    }
    $manifest|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $output 'build-manifest.json')
    Write-Output "Prepared standard client: $output"
}
