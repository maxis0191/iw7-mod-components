function Set-IW7CapacityWatchBuildCopy {
    param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$NativeRoot,
          [Parameter(Mandatory)][bool]$Enabled,[bool]$PortOnly=$false)
    $names=@('paris_capacity_watch.cpp','paris_capacity_watch.hpp','paris_agent_capacity.cpp','paris_agent_capacity.hpp')
    $selected=if($PortOnly){@('paris_agent_capacity.cpp','paris_agent_capacity.hpp')}else{$names}
    $component=Join-Path $NativeRoot 'src/client/component'
    if (!(Test-Path -LiteralPath $component -PathType Container)) { throw 'Native component directory absent.' }
    foreach ($base in @($component,(Join-Path $RepoRoot 'src/native'))) {
        $cursor=[IO.Path]::GetFullPath($base)
        while ($cursor) {
            if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Redirected capacity source/target refused.' }
            $cursor=Split-Path $cursor -Parent
        }
    }
    # Preflight every file before mutation; preserve unknown edits.
    $rows=@(foreach($name in $names) {
        $source=Join-Path $RepoRoot ('src/native/'+$name)
        $target=Join-Path $component $name
        $hash=(Get-FileHash -LiteralPath $source).Hash
        if (Test-Path -LiteralPath $target) {
            if ((Get-Item -LiteralPath $target -Force).Attributes -band [IO.FileAttributes]::ReparsePoint -or
                (Get-FileHash -LiteralPath $target).Hash -cne $hash) {
                throw "Unowned capacity overlay $name; preserve it and investigate."
            }
        }
        [pscustomobject]@{File=$name;Source=$source;Target=$target;SHA256=$hash}
    })
    foreach($row in $rows) {
        if($Enabled -and $row.File -cin $selected) {
            Copy-Item -LiteralPath $row.Source -Destination $row.Target -Force
            if((Get-FileHash -LiteralPath $row.Target).Hash -cne $row.SHA256) { throw 'Capacity build copy hash differs.' }
        } elseif(Test-Path -LiteralPath $row.Target) { Remove-Item -LiteralPath $row.Target }
    }
    [pscustomobject]@{Compiled=$Enabled;PortOnly=$PortOnly;Files=$selected;RuntimeActivation='Explicit paris-capacity-64; production also requires paris-capacity-production; private observer only in debugger';SourceHashes=@($rows|Where-Object File -CIn $selected|ForEach-Object{[pscustomobject]@{File=$_.File;SHA256=$_.SHA256}})}
}
