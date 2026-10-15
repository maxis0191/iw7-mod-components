function Set-IW7WordProvenanceBuildCopy {
    param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$NativeRoot,
          [Parameter(Mandatory)][bool]$Enabled,[bool]$IsolatedLab=$false,[bool]$ServerModules=$false,
          [bool]$Debugger=$false,[string]$Mode='STARTUP',[switch]$Apply)
    . "$PSScriptRoot/Provenance-LifecycleOverlay.Core.ps1"
    Assert-IW7WordProvenanceBuildProfile $Enabled $IsolatedLab $ServerModules $Debugger $Mode
    $names=@('paris_word_provenance.cpp','paris_word_provenance.hpp')
    $component=Join-Path $NativeRoot 'src/client/component'
    $sourceRoot=Join-Path $RepoRoot 'src/native'
    foreach($base in @($component,$sourceRoot)){
        if(!(Test-Path -LiteralPath $base -PathType Container)){throw 'Provenance source/target directory absent.'}
        $cursor=[IO.Path]::GetFullPath($base)
        while($cursor){
            if((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Redirected provenance source/target refused.'}
            $cursor=Split-Path $cursor -Parent
        }
    }
    # Preflight BOTH files. An old differing copy requires root's explicit archival/removal, never overwrite.
    $rows=@(foreach($name in $names){
        $source=Join-Path $sourceRoot $name; $target=Join-Path $component $name
        $sourceItem=Get-Item -LiteralPath $source -Force
        if($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Redirected provenance source leaf refused.'}
        $hash=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
        $exists=Test-Path -LiteralPath $target
        if($exists -and (((Get-Item -LiteralPath $target -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -or
                         (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -cne $hash)){
            throw "Unowned provenance overlay $name; preserve it."
        }
        [pscustomobject]@{File=$name;Source=$source;Target=$target;SourceSHA256=$hash;Existed=$exists}
    })
    if($Apply){
        foreach($row in $rows){
            if((Get-FileHash -LiteralPath $row.Source -Algorithm SHA256).Hash -cne $row.SourceSHA256){throw 'Provenance source changed during preflight.'}
            if($Enabled){
                if(!$row.Existed){
                    # Exclusive CreateNew prevents racing another writer; never overwrite an existing target.
                    $input=[IO.File]::Open($row.Source,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
                    $output=$null
                    try{$output=[IO.File]::Open($row.Target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);$input.CopyTo($output);$output.Flush($true)}
                    finally{if($output){$output.Dispose()};$input.Dispose()}
                }
                if((Get-FileHash -LiteralPath $row.Target -Algorithm SHA256).Hash -cne $row.SourceSHA256){throw 'Provenance copied source differs.'}
            } elseif($row.Existed){
                if((Get-FileHash -LiteralPath $row.Target -Algorithm SHA256).Hash -cne $row.SourceSHA256){throw 'Provenance target changed; preserve it.'}
                Remove-Item -LiteralPath $row.Target
            }
        }
    }
    [pscustomobject]@{Compiled=[bool]($Apply -and $Enabled);Enabled=$Enabled;Mode=$Mode;PlanOnly=(!$Apply);NativeCompilationPerformed=$false;Files=$names;SourceHashes=@($rows|ForEach-Object{
        [pscustomobject]@{File=$_.File;SHA256=$_.SourceSHA256}});RestartImplemented=$false;
        RuntimeActivation='Explicit reviewed private dedicated lab debugger STARTUP flags and bounded launch binding only';
        HelperSHA256=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash;
        CoreSHA256=(Get-FileHash -LiteralPath "$PSScriptRoot/Provenance-LifecycleOverlay.Core.ps1" -Algorithm SHA256).Hash}
}
