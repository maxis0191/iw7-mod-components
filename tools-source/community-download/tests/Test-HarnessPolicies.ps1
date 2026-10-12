# Pure policy checks: no Run, Add-Type, compiled helper, process, lease or network.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path $PSScriptRoot -Parent
$errors=$null;$tokens=$null
$core=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Harness.Core.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count -or @($core.EndBlock.Statements|Where-Object {$_ -isnot [Management.Automation.Language.FunctionDefinitionAst]}).Count){throw 'Policy import is not function-only.'}
. (Join-Path $root 'Harness.Core.ps1')
$runner=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Harness.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Runner source syntax invalid.'}
$guard=$runner.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Open-DownloadReadGuard'},$true)
if(!$guard){throw 'Actual retained guard implementation missing.'}
. ([scriptblock]::Create($guard.Extent.Text))
$script:Now=0L;$script:Checks=0;$script:Released=0;$script:Disposed=0
function Get-DownloadMonotonicMs {$script:Now}
function Check([bool]$Condition,[string]$Message){$script:Checks++;if(!$Condition){throw $Message}}
function Refuse([scriptblock]$Body,[string]$Message){$threw=$false;try {& $Body|Out-Null}catch{$threw=$true};Check $threw $Message}
function New-Timing { [ordered]@{StartedMs=0L;RootExitObservedMs=$null} }
function New-State { [ordered]@{Status='FunctionalAndOriginalJobClosed';Passed=$true;ForcedStop=$false;Quarantined=$false;QuarantineKey=$null;
    OriginalJobClosed=$false;LeaseReleased=$false;WorkerPID=123;WorkerCreationFileTime=456;LeaseToken='pure';ReadGuardsReleased=$false} }
function New-Owner {
    $item=[pscustomobject]@{Closed=$false;Root=$true;Tree=$true;RootDelay=0L;TreeDelay=0L;StopDelay=0L;StopFailure=$false;StopCalls=0}
    $item|Add-Member ScriptMethod RootExited {$script:Now+=$this.RootDelay;return $this.Root}
    $item|Add-Member ScriptMethod TreeExited {$script:Now+=$this.TreeDelay;return $this.Tree}
    $item|Add-Member ScriptMethod StopAndConfirm {param($limit) $this.StopCalls++;$script:Now+=$this.StopDelay;if($this.StopFailure){throw 'Mocked unresolved original tree'};$this.Closed=$true}
    $item
}
$script:Now=179999;$timing=New-Timing;$owner=New-Owner
Check (Observe-DownloadCompletion $owner $timing {0} {}) 'Before deadline should be accepted.'
$script:Now=180000;Refuse {Observe-DownloadCompletion (New-Owner) (New-Timing) {0} {}} 'At global deadline terminal observation must fail.'
$script:Now=0;$owner=New-Owner;$owner.TreeDelay=180000
Refuse {Observe-DownloadCompletion $owner (New-Timing) {0} {}} 'Slow terminal TreeExited must not bypass global deadline.'
$script:Now=0;$owner=New-Owner;$owner.RootDelay=2000
Refuse {Observe-DownloadCompletion $owner (New-Timing) {0} {}} 'Slow first root getter must count toward drain.'
$script:Now=0;$owner=New-Owner;$owner.TreeDelay=2000
Refuse {Observe-DownloadCompletion $owner (New-Timing) {0} {}} 'Late zero-active at drain deadline must fail.'
$script:Now=0;$timing=New-Timing;$owner=New-Owner;$owner.Tree=$false
Check (!(Observe-DownloadCompletion $owner $timing {0} {})) 'Residual initially remains pending.'
$script:Now=2000;$owner.Tree=$true
Refuse {Observe-DownloadCompletion $owner $timing {0} {}} 'Drain start must persist between polls.'
$script:Now=0;Refuse {Observe-DownloadCompletion (New-Owner) (New-Timing) {$script:Now=180000;0} {}} 'Budget measurement time must be included.'
$script:Now=0;Refuse {Observe-DownloadCompletion (New-Owner) (New-Timing) {0} {$script:Now=180000}} 'Member capture time must be included.'
$script:Now=175001;Refuse {Register-DownloadOwner (New-Owner) (New-Timing) {$script:Now=180000}} 'CIM return at global deadline must fail.'
$script:Now=0;Refuse {Register-DownloadOwner (New-Owner) (New-Timing) {$script:Now=5000}} 'CIM own deadline includes callback time.'
$script:Now=0;Register-DownloadOwner (New-Owner) (New-Timing) {$script:Now=4999};Check ($script:Now -eq 4999) 'Timely registration should return.'

$testKey='pure-'+[guid]::NewGuid().ToString('N')
$lease=[pscustomobject]@{Token=$testKey};$state=New-State;$owner=New-Owner;$owner.StopFailure=$true
$fakeGuard=[pscustomobject]@{};$fakeGuard|Add-Member ScriptMethod Dispose {$script:Disposed++}
$guards=[Collections.Generic.List[object]]::new();$guards.Add($fakeGuard)
$script:Now=0
Complete-DownloadOwnership $owner $guards $state $lease {$script:Released++}
try {
    $held=[AppDomain]::CurrentDomain.GetData($state.QuarantineKey)
    Check ([object]::ReferenceEquals($held.Owner,$owner)) 'Quarantine must retain the exact original owner.'
    Check ([object]::ReferenceEquals($held.Guards,$guards)) 'Quarantine must retain exact read guards.'
    Check ($script:Released -eq 0 -and $script:Disposed -eq 0 -and !$state.OriginalJobClosed) 'Unknown closure cannot release lease or guards.'
    $weak=[WeakReference]::new($owner);$owner=$null;$held=$null
    [GC]::Collect();[GC]::WaitForPendingFinalizers();[GC]::Collect()
    Check $weak.IsAlive 'Original owner must survive script-local reference loss and GC.'
    Refuse {Preserve-DownloadQuarantine $testKey (New-Owner) @() (New-State)} 'Quarantine cannot overwrite an existing owner.'
} finally {
    # Only this test's mocked owner is unrooted. Never operates on real quarantine.
    [AppDomain]::CurrentDomain.SetData(('IW7.CommunityDownload.Quarantine.'+$testKey),$null)
}
$script:Now=0;$owner=New-Owner;$owner.StopDelay=5000;$state=New-State;$lease.Token='pure-'+[guid]::NewGuid().ToString('N')
Complete-DownloadOwnership $owner $guards $state $lease {$script:Released++}
try {Check ($state.Quarantined -and !$state.LeaseReleased) 'Late cleanup must remain unqualified and retained.'}
finally {[AppDomain]::CurrentDomain.SetData($state.QuarantineKey,$null)}
$script:Now=0;$owner=New-Owner;$owner.Closed=$true;$state=New-State
Complete-DownloadOwnership $owner $guards $state $lease {$script:Released++}
Check ($state.LeaseReleased -and $state.ReadGuardsReleased -and $script:Released -eq 1 -and $script:Disposed -eq 1) 'Confirmed closure releases once.'
$state=New-State;Complete-DownloadOwnership $owner @() $state $lease {throw 'release refused'}
Check (!$state.LeaseReleased -and !$state.Passed -and $state.Status -ceq 'Failed') 'Release refusal cannot qualify.'

$fixture=Join-Path $root ('.scratch/policy-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixture)|Out-Null
$inputPath=Join-Path $fixture 'source.txt';[IO.File]::WriteAllText($inputPath,'reviewed')
$hash=(Get-FileHash -LiteralPath $inputPath).Hash
$held=Open-DownloadReadGuard $inputPath $hash
try {
    Refuse {[IO.File]::WriteAllText($inputPath,'changed')} 'Retained input must deny write between hash and use.'
    Refuse {[IO.File]::Delete($inputPath)} 'Retained input must deny deletion/replacement.'
} finally {$held.Dispose()}
Refuse {Open-DownloadReadGuard $inputPath ('0'*64)} 'Wrong hash must be refused.'
[IO.File]::WriteAllText($inputPath,'after-refusal')
Check ((Get-Content -LiteralPath $inputPath -Raw) -ceq 'after-refusal') 'Hash-refused guard must release its handle.'

foreach($case in @('over-budget','measure-error','metadata-overflow')){
    $out=Join-Path $fixture $case;[IO.Directory]::CreateDirectory($out)|Out-Null
    $reserve=New-DownloadReceiptReserve $out
    Check ((Get-Item -LiteralPath $reserve.Path).Length -eq 1MB) 'Metadata must be allocated before native launch.'
    $state=New-State
    if($case -eq 'metadata-overflow'){$state.Error='x'*(1MB+64)}
    $measure=switch($case){'over-budget' {{32MB}} 'measure-error' {{throw 'output scan failed'}} default {{0}}}
    $published=Publish-DownloadReceipt $state $reserve $measure
    $receipt=Get-Content -LiteralPath $published -Raw|ConvertFrom-Json
    Check (!$receipt.Passed -and $receipt.Status -ceq 'Failed') 'Oversize/measurement failure needs an explicit failure receipt.'
    Check ((Get-Item -LiteralPath $published).Length -le 1MB) 'Failure receipt must fit reserved capacity.'
}
$source=$runner.Extent.Text
Check ($source.IndexOf('$timing=[ordered]') -lt $source.IndexOf('$owner.Start(')) 'Clock must begin before Start.'
Check ($source.IndexOf('$reserve=New-DownloadReceiptReserve') -lt $source.IndexOf('$owner.Start(')) 'Reserve must precede launch.'
Check ($source.IndexOf('Open-DownloadReadGuard $plan.job_assembly') -lt $source.IndexOf('[Reflection.Assembly]::LoadFrom')) 'DLL must remain guarded across LoadFrom.'
foreach($name in 'ops/Resource-Memory.ps1','ops/Resource-RecorderOwnedProcess.Core.ps1','ops/native/ResourceMemory.cs'){
    Check ($source.Contains($name)) "Admission transitive pin missing: $name"
}
Check (!$source.Contains('while(!$owner.TreeExited())')) 'Terminal predicate must not precede deadline checks.'
Check (!$source.Contains('ArtifactBytesBeforeReceipt=Assert-OutputBudget')) 'Failure receipt must not be gated by payload cap.'
if(('IW7ResourceMemoryV1' -as [type]) -or ('IW7.CommunityDownload.NativeJob' -as [type])){throw 'Native type unexpectedly loaded.'}
"PASS: $script:Checks pure policy checks; no Run, Add-Type, native process or reservation. Fixtures: $fixture"
