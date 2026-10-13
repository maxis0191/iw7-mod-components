# Downloader-only profile over unchanged H1 stage/telemetry controllers.
# Import functions only; no native types, processes, reservations or filesystem I/O.
function Invoke-DownloadH1Stage($Plan,$State,$Context,$Start,[string]$ImageHash,[string]$Root,$Timing,[scriptblock]$Measure) {
    $baseDeadline=${function:Assert-H1Deadline}
    $baseState=${function:Get-H1OriginalState}
    $baseRegister=${function:Register-H1Original}
    $started=Get-H1Clock
    $stageTiming=@{RootExitMs=$null;RegistrationLate=$false}
    # Scope overrides like T7, retaining both the single group clock and the
    # existing two-second drain, including checks inside telemetry qualification.
    function Assert-H1Deadline($Started,[int]$Seconds) {
        if($stageTiming.RegistrationLate){throw 'Original-job registration deadline reached.'}
        & $baseDeadline $Timing.StartedMs 180
        & $baseDeadline $Started $Seconds
        if($null -ne $stageTiming.RootExitMs){& $baseDeadline $stageTiming.RootExitMs 2}
    }
    function Get-H1OriginalState($Owner) {
        $before=Get-H1Clock
        $sample=& $baseState $Owner
        if($sample.RootExited -and $null -eq $stageTiming.RootExitMs){$stageTiming.RootExitMs=$before}
        Assert-H1Deadline $started $State.DeadlineSeconds
        $sample
    }
    function Register-H1Original($Lease,$Identity) {
        $before=Get-H1Clock
        try{& $baseRegister $Lease $Identity}finally{
            if((Get-H1Clock)-$before -ge 5000){$stageTiming.RegistrationLate=$true}
        }
        & $baseDeadline $before 5
        Assert-H1Deadline $started $State.DeadlineSeconds
    }
    function Test-H1Budget($BoundPlan,$Evidence) {
        # Observe non-compiler roots too: their descendants never qualify for the
        # compiler exception. Original H1 still makes every closure decision.
        if(!$Context.Closed){$null=Get-H1OriginalState $Context.Owner}
        $bytes=& $Measure
        $Evidence.MaxObservedOutputBytes=[math]::Max($Evidence.MaxObservedOutputBytes,$bytes)
        Assert-H1Deadline $started $State.DeadlineSeconds
    }
    function Get-H1CompilerArtifacts($BoundPlan,$BoundContext) {
        Get-DownloadCompileArtifacts $BoundPlan $BoundContext
    }
    Invoke-H1OwnedStage $Plan $State $Context $Start $ImageHash $Root $started
    Assert-H1Deadline $started $State.DeadlineSeconds
}

function Get-DownloadCompileArtifacts($Plan,$Context) {
    foreach($name in 'test_download.exe','test_download.obj') {
        $path=Join-Path $Plan.output_root ('compile/'+$name)
        $pin=Lock-DownloadArtifact $path $Context.Guards 16MB
        if($pin.Bytes -le 0){throw 'Compiler artifact is empty.'}
        $pin
    }
}
function Lock-DownloadArtifact([string]$Path,$Guards,[long]$Limit) {
    Assert-H1Path $Path
    $stream=[IO.FileStream]::new($Path,'Open','Read','Read')
    try {
        if($stream.Length -gt $Limit){throw 'Downloader artifact exceeds bound.'}
        $hash=[Security.Cryptography.SHA256]::Create()
        try{$sha=[Convert]::ToHexString($hash.ComputeHash($stream)).ToLowerInvariant()}finally{$hash.Dispose()}
        $stream.Position=0;$Guards.Add($stream)
        [pscustomobject]@{Path=$Path;Bytes=$stream.Length;SHA256=$sha}
    }catch{$stream.Dispose();throw}
}
function Get-DownloadCompileArguments([string]$Own,[string]$Output) {
    $work=Join-Path $Output 'work';$compile=Join-Path $Output 'compile'
    @('/nologo','/std:c++20','/EHsc','/W4','/WX','/Od','/D_CRT_SECURE_NO_WARNINGS',
      ('/I'+(Join-Path $work 'include')),('/I'+(Join-Path $work 'reconstruction/src/client/component')),
      ('/Fe:'+(Join-Path $compile 'test_download.exe')),('/Fo:'+(Join-Path $compile 'test_download.obj')),
      (Join-Path $Own 'tests/test_download.cpp'))
}
function Assert-DownloadCaseOutput([string]$Text,$Expected) {
    if(@($Expected).Count -ne 46 -or @($Expected|Sort-Object -Unique).Count -ne 46){throw 'Exact 46 distinct expected cases required.'}
    # A single final newline is optional; blank/extra/duplicate lines are not.
    $normalized=$Text.Replace("`r`n","`n")
    if($normalized.EndsWith("`n")){$normalized=$normalized.Substring(0,$normalized.Length-1)}
    $lines=@($normalized.Split("`n"))
    $wanted=@($Expected|ForEach-Object {'PASS '+$_})+@('RESULT 46 passed')
    if($lines.Count -ne 47 -or ($lines -join "`n") -cne ($wanted -join "`n")){throw 'Exact ordered 46-case output required.'}
}
