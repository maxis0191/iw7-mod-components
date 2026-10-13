$ErrorActionPreference='Stop'
$taskProject=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$taskBuild=[IO.File]::ReadAllText((Join-Path $taskProject 'ops/Build-Voice.ps1'))
$taskTokens=$null;$taskErrors=$null
$taskAST=[Management.Automation.Language.Parser]::ParseInput($taskBuild,[ref]$taskTokens,[ref]$taskErrors)
if($taskErrors.Count){throw 'Build-Voice parse failed'}
if('CollisionProvider' -cnotin @($taskAST.ParamBlock.Parameters.Name.VariablePath.UserPath)){throw 'CollisionProvider build switch absent'}
$taskGuard=$taskAST.Find({param($node) $node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.StartsWith('if ($CollisionProvider -and')},$true)
if(!$taskGuard -or $taskGuard.Extent.StartOffset -ge $taskBuild.IndexOf('Invoke-IW7ResourceJob')){throw 'Profile refusal must precede any admission/build'}
$taskSelection=$taskBuild.Substring($taskBuild.IndexOf('# Collision provider source selection;'))
$taskSelection=$taskSelection.Substring(0,$taskSelection.IndexOf('# End collision provider source selection.'))
$taskSandbox=Join-Path ([IO.Path]::GetTempPath()) ('iw7-collision-build-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $taskSandbox 'repo/src/native'),(Join-Path $taskSandbox 'native/src/client/component') | Out-Null
try{
    $taskRepo=Join-Path $taskSandbox 'repo';$taskNative=Join-Path $taskSandbox 'native'
    foreach($taskName in @('collision_provider.cpp','collision_provider.hpp')){
        [IO.File]::WriteAllText((Join-Path $taskRepo ('src/native/'+$taskName)), 'synthetic owned '+$taskName)
    }
    $taskChecks=0
    foreach($taskEnabled in @($false,$true)){
        foreach($taskIsolated in @($false,$true)){
            foreach($taskModules in @($false,$true)){
                $CollisionProvider=$taskEnabled;$IsolatedLab=$taskIsolated;$ServerModules=$taskModules
                $taskRejected=$false
                try{Invoke-Expression $taskGuard.Extent.Text}catch{$taskRejected=$true}
                if($taskRejected -ne ($taskEnabled -and (!$taskIsolated -or !$taskModules))){throw 'Unexpected collision build profile decision'}
                ++$taskChecks
            }
        }
    }
    $root=$taskNative;$repo=$taskRepo;$nativeSources=@('base.cpp');$CollisionProvider=$true
    Invoke-Expression $taskSelection
    if(($nativeSources -join ',') -cne 'base.cpp,collision_provider.cpp,collision_provider.hpp'){throw 'Enabled provider source inventory differs'}
    ++$taskChecks
    foreach($taskName in @('collision_provider.cpp','collision_provider.hpp')){
        Copy-Item -LiteralPath (Join-Path $taskRepo ('src/native/'+$taskName)) -Destination (Join-Path $taskNative ('src/client/component/'+$taskName))
    }
    $nativeSources=@('base.cpp');$CollisionProvider=$false
    Invoke-Expression $taskSelection
    if($nativeSources.Count -ne 1 -or @(Get-ChildItem -LiteralPath (Join-Path $taskNative 'src/client/component')).Count){throw 'Disabled profile retained a provider TU'}
    ++$taskChecks
    $taskUnknown=Join-Path $taskNative 'src/client/component/collision_provider.cpp'
    [IO.File]::WriteAllText($taskUnknown,'unrelated edit')
    $taskRejected=$false
    try{Invoke-Expression $taskSelection}catch{$taskRejected=$true}
    if(!$taskRejected -or [IO.File]::ReadAllText($taskUnknown) -cne 'unrelated edit'){throw 'An unowned disabled overlay was removed'}
    ++$taskChecks
    if(!$taskBuild.Contains('$manifest.CollisionProvider = [bool]$CollisionProvider')){throw 'Scalar collision build declaration absent'}
    ++$taskChecks
    Write-Output "PASS $taskChecks collision build profile/source selection checks; no native compile or runtime"
}finally{
    $taskResolved=[IO.Path]::GetFullPath($taskSandbox)
    $taskTemp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(!$taskResolved.StartsWith($taskTemp,[StringComparison]::OrdinalIgnoreCase)){throw 'Temporary cleanup escaped its root'}
    Remove-Item -LiteralPath $taskResolved -Recurse -Force
}
