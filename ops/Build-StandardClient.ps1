param([Parameter(Mandatory)][string]$NativeRoot,[ValidateRange(1,2)][int]$BuildJobs=1,[switch]$OwnerCheats,[switch]$Capacity64)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$profile=(Get-Content -LiteralPath (Join-Path $repo 'client-profiles.json') -Raw | ConvertFrom-Json).Standard
. "$PSScriptRoot/standard-client/Loading-NewMap.Core.ps1"
. "$PSScriptRoot/Owner-CheatsOverlay.Core.ps1"
. "$PSScriptRoot/Voice-RelayOverlay.Core.ps1"
. "$PSScriptRoot/Cutscene-Overlay.Core.ps1"
. "$PSScriptRoot/agent-capacity/Peer-Overlay.Core.ps1"
. "$PSScriptRoot/agent-capacity/Build-Copy.Core.ps1"
$root=[IO.Path]::GetFullPath($NativeRoot).TrimEnd('\','/')
if(![IO.Path]::IsPathFullyQualified($NativeRoot) -or $NativeRoot -match '[\x00-\x1f"%!]'){throw 'Absolute literal NativeRoot required.'}
$cursor=$root
while($cursor){
    if((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Redirected native source ancestry refused.'}
    $parent=Split-Path $cursor -Parent;if($parent -eq $cursor){break};$cursor=$parent
}
. "$PSScriptRoot/Resource-Scheduler.Core.ps1"
Invoke-IW7ResourceJob -Scope $repo -Owner 'CB compatible standard client native build' -PhysicalBytes (4GB*$BuildJobs) -CommitBytes (6GB*$BuildJobs) -Body {
    Remove-IW7VoiceCertifyOverlay $root
    Remove-IW7VoiceRelayOverlay $root
    Remove-IW7CapacityPeerOverlay $root
    Remove-IW7CutsceneOverlay $root
Remove-IW7OwnerCheatsOverlay $root
    if(!(Test-Path -LiteralPath (Join-Path $root '.git'))){
        git clone --no-checkout $profile.Repository $root
        if($LASTEXITCODE){throw 'Standard client source clone failed.'}
        $previous=$env:GIT_LFS_SKIP_SMUDGE
        try {$env:GIT_LFS_SKIP_SMUDGE='1';git -C $root checkout --detach $profile.Revision;if($LASTEXITCODE){throw 'Exact standard client pin checkout failed.'}}
        finally {if($null -eq $previous){Remove-Item Env:GIT_LFS_SKIP_SMUDGE -ErrorAction SilentlyContinue}else{$env:GIT_LFS_SKIP_SMUDGE=$previous}}
    }
    if((& git -C $root rev-parse HEAD).Trim() -cne $profile.Revision){throw 'Exact standard client pin required; preserve other checkouts.'}
    $null=Set-IW7CapacityWatchBuildCopy -RepoRoot $repo -NativeRoot $root -Enabled $false -PortOnly $true
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
    if($OwnerCheats){$ownerCheatsOverlay=Add-IW7OwnerCheatsOverlay $root $repo;$cutsceneOverlay=Add-IW7CutsceneOverlay $root $repo}
    if($Capacity64){
        $capacityBuild=Set-IW7CapacityWatchBuildCopy -RepoRoot $repo -NativeRoot $root -Enabled $true -PortOnly $true
        $capacityPeerOverlay=Add-IW7CapacityPeerOverlay $root
    }
    Push-Location $root
    try {
        & ./tools/premake5.exe --file=paris-build-only.lua vs2022
        if($LASTEXITCODE){throw 'Standard client Premake failed.'}
        $project=Join-Path $root 'build/client.vcxproj'
        $projectText=[IO.File]::ReadAllText($project)
        [xml]$generatedProject=$projectText
        $postBuildNodes=@($generatedProject.SelectNodes("//*[local-name()='PostBuildEvent']/*[local-name()='Command']")|Where-Object{![string]::IsNullOrWhiteSpace($_.InnerText)})
        if($postBuildNodes.Count){throw 'Automatic upstream copy/deployment post-build events refused before MSBuild.'}
        if($projectText -match '(?:paris_voice|voice_relay|voice_test|paris_test_fixture|player_movement)\.cpp'){throw 'Unexpected private or duplicate translation unit in regenerated client project.'}
        & "$installation/MSBuild/Current/Bin/MSBuild.exe" build/iw7-mod.sln "/m:$BuildJobs" /nr:false /v:minimal /p:Configuration=Release /p:Platform=x64 /p:MultiProcessorCompilation=false /p:PostBuildEventUseInBuild=false "/flp:logfile=$runtime/standard-client-build.log;verbosity=minimal"
        if($LASTEXITCODE){throw 'Standard client native build failed.'}
    } finally {Pop-Location}
    if($OwnerCheats -or $Capacity64){
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
    $output=Join-Path $runtime 'standard-client-package'
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
    $manifest|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $output 'build-manifest.json')
    Write-Output "Prepared standard client: $output"
}
