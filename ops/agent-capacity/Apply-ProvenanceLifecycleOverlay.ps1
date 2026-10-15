# PlanOnly by default. Root composes this after the existing SDK transformations.
param([Parameter(Mandatory)][string]$NativeRoot,[Parameter(Mandatory)][string]$Commit,
      [bool]$Enabled=$false,[bool]$IsolatedLab=$false,[bool]$ServerModules=$false,[bool]$Debugger=$false,
      [ValidateSet('STARTUP','RESTART')][string]$Mode='STARTUP',[switch]$Apply)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/Provenance-LifecycleOverlay.Core.ps1"
Assert-IW7WordProvenanceBuildProfile $Enabled $IsolatedLab $ServerModules $Debugger $Mode
if($Commit -cne '77e6d4d24e918ee363b3feee3735c3b889dff7d7'){throw 'Exact reviewed SDK commit required.'}
$root=[IO.Path]::GetFullPath($NativeRoot)
$actualHead=(& git -C $root rev-parse HEAD).Trim()
if($LASTEXITCODE -or $actualHead -cne $Commit){throw 'Native checkout HEAD differs from the exact reviewed SDK commit.'}
$path=Join-Path $root 'src/client/main.cpp'
$cursor=$path
while($cursor){
    if((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){
        throw 'Redirected lifecycle source refused.'
    }
    $cursor=Split-Path $cursor -Parent
}
$current=[IO.File]::ReadAllBytes($path)
$canonical=(((git -C $root show ($Commit+':src/client/main.cpp')) -join "`n").TrimEnd())+"`n"
if($LASTEXITCODE){throw 'Pinned SDK main.cpp could not be read.'}
$encoding=[Text.UTF8Encoding]::new($false,$true)
# Preserve the actual original newline representation through enabled/disabled round trips.
if($encoding.GetString($current).Contains("`r")){$canonical=$canonical.Replace("`n","`r`n")}
$overlays=New-IW7WordProvenanceLifecycleOverlays ($encoding.GetBytes($canonical))
$next=Get-IW7WordProvenanceLifecycleTransition $current $overlays $Enabled
$before=Get-IW7WordProvenanceHash $current
$after=Get-IW7WordProvenanceHash $next
if($Apply -and $before -cne $after){
    if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $before){throw 'Lifecycle source changed during preflight.'}
    [IO.File]::WriteAllBytes($path,$next)
    if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $after){throw 'Lifecycle output bytes differ.'}
}
[pscustomobject]@{Mode=$Mode;PlanOnly=(!$Apply);Applied=[bool]($Apply -and $before -cne $after);
    Enabled=$Enabled;SDKCommit=$Commit;Path=$path;InputSHA256=$before;OutputSHA256=$after;
    CleanSHA256=$overlays.CleanSHA256;Newline=$overlays.Newline;RestartImplemented=$false;
    ArxanModified=$false;PrioritiesModified=$false;HelperSHA256=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash;
    CoreSHA256=(Get-FileHash -LiteralPath "$PSScriptRoot/Provenance-LifecycleOverlay.Core.ps1" -Algorithm SHA256).Hash}
