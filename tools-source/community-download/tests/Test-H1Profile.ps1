# Real H1 stage + residual policy, with synthetic native observations/owners.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Providers)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$own=Split-Path $PSScriptRoot -Parent
$pins=Get-Content -LiteralPath (Join-Path $own 'h1-source.json') -Raw|ConvertFrom-Json
foreach($name in 'tools-source/asset-bridge/h1-fixture/H1Native.Core.ps1',
                 'tools-source/asset-bridge/surfaces/MaterialV2.Compiler.ps1',
                 'tools-source/asset-bridge/h1-fixture/H1Native.Compiler.ps1'){
    $path=Join-Path $Providers $name
    if((Get-FileHash -LiteralPath $path).Hash -ine $pins.Providers.$name){throw 'Reviewed test provider differs.'}
    . $path
}
. (Join-Path $own 'Harness.Profile.ps1')
$script:checks=0
function Check($Condition,[string]$Message){$script:checks++;if(!$Condition){throw $Message}}
function Refuse([scriptblock]$Action,[string]$Message){$caught=$false;try{& $Action}catch{$caught=$true};Check $caught $Message}
$cl='fe251ef50a1545b1b0835ee17b1e785459712b38d79e45b5c1d3d28970a36619'
$vt='d591358c6aee4b673562ca3b3a15c250e612708394fe3b44a7a7eda2470570a5'
$plan=[pscustomobject]@{Compiler='C:\Pinned\cl.exe';RunRoot='C:\Synthetic';Bindings=@(
    [pscustomobject]@{Path='C:\Pinned\cl.exe';SHA256=$cl},[pscustomobject]@{Path='C:\Pinned\vctip.exe';SHA256=$vt})}
function Get-H1Clock {$script:clock}
function Register-H1Original($Lease,$Identity){if($script:case -ceq 'late-registration'){$script:clock+=5001}}
function Confirm-H1BoundInputs($Plan){if($script:case -ceq 'changed-input'){throw 'Changed pinned input.'}}
function Open-H1Pin($Pin){
    if($script:case -ceq 'changed-telemetry' -and $Pin.Path.EndsWith('vctip.exe')){throw 'Changed VCTIP bytes.'}
    [IO.MemoryStream]::new()
}
function Get-DownloadCompileArtifacts($Plan,$Context){
    $script:artifacts++
    if($script:case -ceq 'changed-artifact'){throw 'Artifact cannot be guarded.'}
    [pscustomobject]@{Path='C:\Synthetic\compile\test_download.exe';SHA256=('1'*64);Bytes=1024}
}
function Get-H1OriginalState($Owner){
    if($script:case -ceq 'late-observation'){$script:clock+=2001}
    if($script:stops -and $script:case -ceq 'stop-nonempty'){$script:clock+=1001}
    [pscustomobject]@{RootExited=$true;RootExitCode=$(if($script:case -ceq 'root-nonzero' -or ($script:stops -and $script:case -ceq 'changed-root-after-stop')){1}else{0});
        ActiveProcesses=$(if($script:case -ceq 'stop-nonempty'){1}elseif($script:stops -or $script:case -in @('natural','late-registration')){0}else{1});
        PID=101;Image=$Owner.Image;CreatedUtc='2026-10-12T11:00:00.0000000Z'}
}
function Get-H1OriginalMembers($Owner){
    $script:captures++
    if($script:stops){return [pscustomobject]@{AssignedCount=$(if($script:case -ceq 'bad-empty-capture'){1}else{0});ListedCount=0;Members=@()}}
    $member=[pscustomobject]@{PID=202;ParentPID=101;Image='C:\Pinned\vctip.exe';
        CreatedUtc='2026-10-12T11:00:01.0000000Z';InOriginalJob=$true;Error=$null;ParentError=$null}
    if($script:case -ceq 'foreign'){$member.InOriginalJob=$false}
    if($script:case -ceq 'wrong-image'){$member.Image='C:\Other\vctip.exe'}
    if($script:case -ceq 'wrong-parent'){$member.ParentPID=303}
    if($script:case -ceq 'pid-reused' -and $script:captures -eq 2){$member.CreatedUtc='2026-10-12T11:00:02.0000000Z'}
    if($script:case -ceq 'partial'){$member.Error='Incomplete observation'}
    $members=@($member);if($script:case -ceq 'second-member'){$members+= $member.PSObject.Copy()}
    [pscustomobject]@{AssignedCount=$members.Count;ListedCount=$members.Count;Members=$members;CapturedUtc='2026-10-12T11:00:03.0000000Z'}
}
function Stop-H1OriginalJob($Owner){
    Check ($script:artifacts -eq 1 -and $script:captures -eq 2) 'Stop requires artifacts and two original-job captures.'
    $script:stops++
    if($script:case -ceq 'late-stop'){$script:clock+=2001}
}
function New-H1Owner {
    $script:owner=[pscustomobject]@{PID=101;Image='';CreationFileTime=([datetime]'2026-10-12T11:00:00Z').ToFileTimeUtc();Closed=$false;ExitCode=0}
    $script:owner|Add-Member ScriptMethod Start {param($start,$hash,$out,$err) $this.Image=$start.FileName}
    $script:owner|Add-Member ScriptMethod TreeExited { [bool]($script:stops -or $script:case -in @('natural','late-registration')) }
    $script:owner|Add-Member ScriptMethod CloseConfirmed {
        if(!$this.TreeExited()){throw 'Premature close.'};$this.Closed=$true
        if($script:case -ceq 'late-close'){$script:clock+=2001}
    }
    $script:owner
}
foreach($script:case in @('valid','natural','root-nonzero','foreign','wrong-image','wrong-parent','pid-reused',
    'partial','second-member','changed-input','changed-telemetry','changed-artifact','late-observation','late-stop','late-close',
    'late-registration','group-expired','stop-nonempty','bad-empty-capture','changed-root-after-stop')){
    $script:clock=50000.0;$script:stops=0;$script:captures=0;$script:artifacts=0
    $state=[ordered]@{Stage='Compile';DeadlineSeconds=90;PlanSHA256=('2'*64);MaxObservedOutputBytes=0L;
        CompilerTelemetry=[ordered]@{Completed=$false;Action=$null}}
    $context=[pscustomobject]@{Owner=$null;Closed=$true;Lease='synthetic';Guards=[Collections.Generic.List[object]]::new()}
    $group=[ordered]@{StartedMs=$(if($script:case -ceq 'group-expired'){$script:clock-180000}else{$script:clock})}
    $caught=$null
    try{Invoke-DownloadH1Stage $plan $state $context ([pscustomobject]@{FileName=$plan.Compiler}) $cl 'C:\Synthetic' $group {100}}catch{$caught=$_}
    if($script:case -in @('valid','natural')){
        Check ($null -eq $caught -and $context.Closed) ('Accepted stage failed: '+$script:case+' '+$caught)
        if($script:case -ceq 'valid'){Check ($script:stops -eq 1 -and $script:captures -eq 3 -and $state.CompilerTelemetry.Completed) 'Exact VCTIP must close with fresh empty capture.'}
        else{Check ($script:stops -eq 0) 'Natural closure must not request Stop.'}
    }else{
        Check ($null -ne $caught) ('Unsafe stage accepted: '+$script:case)
        if($script:case -notin @('late-stop','late-close','stop-nonempty','bad-empty-capture','changed-root-after-stop')){Check ($script:stops -eq 0) ('Unqualified Stop: '+$script:case)}
    }
}
# The real Tests phase must never use the compiler exception, even for VCTIP.
$script:case='valid';$script:stops=0;$script:clock=50000.0;$state.Stage='Tests';$state.DeadlineSeconds=30
$state.CompilerTelemetry=[ordered]@{Completed=$false;Action=$null};$context.Closed=$true
Refuse {Invoke-DownloadH1Stage $plan $state $context ([pscustomobject]@{FileName='C:\Synthetic\test_download.exe'}) ('1'*64) 'C:\Synthetic' @{StartedMs=50000.0} {$script:clock+=1001;100}} 'Test residual must fail the two-second drain.'
Check ($script:stops -eq 0 -and !$state.CompilerTelemetry.Completed) 'Tests must never qualify telemetry.'
Assert-H1Deadline $script:clock 30
Check $true 'Scoped drain/global overrides must not escape into the H1 provider.'
$arguments=@(Get-DownloadCompileArguments 'C:\Synthetic\source' 'C:\Synthetic\output')
Check ($arguments.Count -eq 12 -and $arguments[3] -ceq '/W4' -and $arguments[4] -ceq '/WX' -and
    $arguments[9] -ceq '/Fe:C:\Synthetic\output\compile\test_download.exe' -and
    $arguments[10] -ceq '/Fo:C:\Synthetic\output\compile\test_download.obj' -and
    $arguments[11] -ceq 'C:\Synthetic\source\tests\test_download.cpp') 'Direct compiler command or warnings profile changed.'

$expected=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'expected-cases.json') -Raw|ConvertFrom-Json
$valid=(@($expected|ForEach-Object {'PASS '+$_})+@('RESULT 46 passed')) -join "`n"
Assert-DownloadCaseOutput ($valid+"`n") $expected;Check $true '46 exact cases accepted.'
foreach($bad in @($valid.Replace('RESULT 46 passed','RESULT 45 passed'),$valid.Replace('PASS '+$expected[1],'PASS '+$expected[0]),($valid+"`nextra"),($valid+"`n`n"))){
    Refuse {Assert-DownloadCaseOutput $bad $expected} 'Malformed/duplicate/extra native case output accepted.'
}
$fixture=Join-Path $own ('.scratch/h1-profile-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixture)|Out-Null
$file=Join-Path $fixture 'output.log';[IO.File]::WriteAllText($file,'')
$guards=[Collections.Generic.List[IO.FileStream]]::new()
$writer=[IO.FileStream]::new($file,'Open','Write','ReadWrite')
try{Refuse {Lock-DownloadArtifact $file $guards 128|Out-Null} 'Open inherited writer must prevent artifact seal.'}finally{$writer.Dispose()}
$pin=Lock-DownloadArtifact $file $guards 128;Check ($pin.Bytes -eq 0) 'Empty stderr must be sealable after closure.'
try{Refuse {[IO.File]::WriteAllText($file,'changed')} 'Sealed output must deny later writers.'}finally{foreach($guard in $guards){$guard.Dispose()}}
if(('IW7.AnimationProbe.NativeJob' -as [type]) -or ('IW7.H1Diagnostics.JobMembers' -as [type]) -or ('IW7ResourceMemoryV1' -as [type])){throw 'Native type loaded during pure checks.'}
[ordered]@{Checks=$script:checks;Passed=$true;NativeTypesLoaded=$false;LeaseAcquired=$false;ChildrenStarted=0}|ConvertTo-Json
