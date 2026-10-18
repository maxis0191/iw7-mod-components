param([switch]$Contender,[string]$TestRoot,[string]$ResultPath,[switch]$RetainedReleaseSourceOnly)
if ($RetainedReleaseSourceOnly) {
    $ErrorActionPreference='Stop'
    # Return before the Core import, real registry, process query and contenders.
    $tokens=$null;$parseErrors=$null
    $sourceAST=[Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot '../../ops/Resource-Scheduler.Core.ps1'),[ref]$tokens,[ref]$parseErrors)
    if ($parseErrors.Count) { throw 'Production Source parse failed.' }
    $production=@($sourceAST.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Invoke-IW7ResourceJob'},$true))
    if ($production.Count-ne1) { throw 'One exact production function required.' }
    $productionText=$production[0].Extent.Text
    $script:releaseSourceChecks=0
    function Assert-ReleaseSource($Value,[string]$Message) {
        $script:releaseSourceChecks++
        if (!$Value) { throw $Message }
    }
    function New-ReleaseSourceContext {
        [pscustomobject]@{
            ResourceJobLease=$null;ResourceJobFirstErrorRecord=$null;ResourceJobFirstException=$null
            ResourceJobSecondaryErrors=[Collections.Generic.List[Management.Automation.ErrorRecord]]::new()
            ResourceJobReleaseAttempted=$false;ResourceJobReleaseReturned=$false
        }
    }
    function Invoke-ReleaseSourceCase([string]$Mode='True',[scriptblock]$Configure,[object]$Context) {
        if ($null-eq$Context) { $Context=New-ReleaseSourceContext }
        $case=[pscustomobject]@{
            Mode=$Mode;Context=$Context;Events=[Collections.Generic.List[string]]::new()
            Lease=[pscustomobject]@{Token='0123456789abcdef0123456789abcdef'}
            EnterCount=0;ExitCount=0;BodyCount=0;HookCount=0
            EnterFails=$false;ProcessFails=$false;PriorityReadFails=$false;PriorityUnknown=$false
            LowerFails=$false;RestoreFails=$false;RestoreSilent=$false;BodyFails=$false;ExitFails=$false;HalfPair=$false
            ExplicitNullHook=$false;ExplicitNullContext=$false;NoPair=$false;ContextOnly=$false;HookMutation=$false
            BodyException=[InvalidOperationException]::new('authored body failure')
            HookException=[InvalidOperationException]::new('authored hook failure')
            ExitException=[InvalidOperationException]::new('authored release failure')
            Output=$null;Caught=$null;HookContext=$null;FirstSeenByHook=$null;FirstExceptionSeenByHook=$null
            ExitToken=$null;Priority=[Diagnostics.ProcessPriorityClass]::Normal;ObservedArguments=$null
        }
        if ($Configure) { & $Configure $case }
        & {
            param($case,$productionText)
            . ([scriptblock]::Create($productionText))
            function Enter-IW7ResourceLease {
                param($Scope,$Kind,$PhysicalBytes,$CommitBytes,$Owner)
                $case.Events.Add('enter');$case.EnterCount++
                $case.ObservedArguments=@($Scope,$Kind,$PhysicalBytes,$CommitBytes,$Owner)
                if ($case.EnterFails) { throw 'authored admission failure' }
                return $case.Lease
            }
            function Exit-IW7ResourceLease {
                param($Token)
                $case.Events.Add('exit');$case.ExitCount++;$case.ExitToken=$Token
                if ($case.ExitFails) { throw $case.ExitException }
            }
            function Get-Process {
                param($Id)
                $case.Events.Add('process')
                if ($case.ProcessFails) { throw 'authored process lookup failure' }
                $fake=[pscustomobject]@{State=$case}
                $fake|Add-Member ScriptProperty PriorityClass {
                    $this.State.Events.Add('priority-read')
                    if ($this.State.PriorityReadFails) { throw 'authored priority read failure' }
                    if ($this.State.PriorityUnknown) { return $null }
                    $this.State.Priority
                } {
                    param($value)
                    $event=if($value-eq[Diagnostics.ProcessPriorityClass]::BelowNormal){'lower'}else{'restore'}
                    $this.State.Events.Add($event)
                    if (($event-ceq'lower'-and$this.State.LowerFails)-or($event-ceq'restore'-and$this.State.RestoreFails)) { throw ('authored '+$event+' failure') }
                    if ($event-ceq'restore'-and$this.State.RestoreSilent) { return }
                    $this.State.Priority=$value
                }
                return $fake
            }
            $body={
                $case.Events.Add('body');$case.BodyCount++
                if ($case.BodyFails) { throw $case.BodyException }
                'authored body output'
            }
            $hook={
                param($actualContext)
                $case.Events.Add('hook');$case.HookCount++;$case.HookContext=$actualContext
                $case.FirstSeenByHook=$actualContext.ResourceJobFirstErrorRecord
                $case.FirstExceptionSeenByHook=$actualContext.ResourceJobFirstException
                if ($case.HookMutation) { $actualContext.ResourceJobLease=[pscustomobject]@{Token=$case.Lease.Token} }
                switch -CaseSensitive ($case.Mode) {
                    'True' { $true }
                    'False' { $false }
                    'String' { 'true' }
                    'Number' { 1 }
                    'Array' { ,@($true) }
                    'Two' { $true;$true }
                    'Empty' { }
                    'Throw' { throw $case.HookException }
                }
            }
            $arguments=@{Scope='source-only-scope';Kind='Analysis';PhysicalBytes=17;CommitBytes=23;Owner='authored owner';Body=$body}
            if (!$case.NoPair) {
                if (!$case.ContextOnly) { $arguments.BeforeReleaseCheck=if($case.ExplicitNullHook){$null}else{$hook} }
                if (!$case.HalfPair) { $arguments.OriginalContext=if($case.ExplicitNullContext){$null}else{$case.Context} }
            }
            try { $case.Output=Invoke-IW7ResourceJob @arguments }
            catch { $case.Caught=$_ }
        } $case $productionText
        return $case
    }
    $legacy=@(
        '    $lease=Enter-IW7ResourceLease -Scope $Scope -Kind $Kind -PhysicalBytes $PhysicalBytes -CommitBytes $CommitBytes -Owner $Owner',
        '    $process=Get-Process -Id $PID',
        '    $priority=$process.PriorityClass',
        '    try {',
        '        $process.PriorityClass=''BelowNormal''',
        '        & $Body',
        '    } finally {',
        '        $process.PriorityClass=$priority',
        '        Exit-IW7ResourceLease -Token $lease.Token',
        '    }',
        '}'
    ) -join [string][char]10
    Assert-ReleaseSource ($productionText.Replace([string][char]13,'').EndsWith($legacy,[StringComparison]::Ordinal)) 'The literal legacy implementation changed.'
    $legacyCase=Invoke-ReleaseSourceCase -Configure {param($c)$c.NoPair=$true}
    Assert-ReleaseSource (!$legacyCase.Caught-and$legacyCase.EnterCount-eq1-and$legacyCase.ExitCount-eq1-and$legacyCase.HookCount-eq0) 'Default did not use only the original branch.'
    Assert-ReleaseSource ($null-eq$legacyCase.Context.ResourceJobLease-and$legacyCase.Output-ceq'authored body output') 'Default changed caller state or Body output.'
    $normal=Invoke-ReleaseSourceCase
    Assert-ReleaseSource (!$normal.Caught-and$normal.Output-ceq'authored body output') 'Known normal outcome failed or changed Body output.'
    Assert-ReleaseSource (($normal.Events-join',')-ceq'enter,process,priority-read,lower,body,restore,priority-read,hook,exit') 'Actual function order differs.'
    Assert-ReleaseSource ([object]::ReferenceEquals($normal.Context.ResourceJobLease,$normal.Lease)-and[object]::ReferenceEquals($normal.HookContext,$normal.Context)) 'Original context/lease reference was copied.'
    Assert-ReleaseSource ($normal.Context.ResourceJobReleaseAttempted-and$normal.Context.ResourceJobReleaseReturned-and$normal.ExitCount-eq1-and$normal.ExitToken-ceq$normal.Lease.Token) 'Known release outcome differs.'
    Assert-ReleaseSource (($normal.ObservedArguments-join'|')-ceq'source-only-scope|Analysis|17|23|authored owner') 'Existing admission arguments changed.'
    foreach($configuration in @(
        {param($c)$c.HalfPair=$true},
        {param($c)$c.ContextOnly=$true},
        {param($c)$c.ExplicitNullHook=$true},
        {param($c)$c.ExplicitNullContext=$true},
        {param($c)$c.ExplicitNullHook=$true;$c.ExplicitNullContext=$true}
    )) {
        $refused=Invoke-ReleaseSourceCase -Configure $configuration
        Assert-ReleaseSource ($refused.Caught-and$refused.EnterCount-eq0-and$refused.BodyCount-eq0) 'Explicit null/half-pair reached admission.'
    }
    $contexts=@(@{},[version]'1.2',(New-ReleaseSourceContext),(New-ReleaseSourceContext),(New-ReleaseSourceContext))
    $script:forbiddenContextAccesses=0
    $contexts[2].PSObject.Properties.Remove('ResourceJobLease')
    $contexts[2]|Add-Member ScriptProperty ResourceJobLease {$script:forbiddenContextAccesses++;throw 'must not read scripted getter'} {$script:forbiddenContextAccesses++;throw 'must not call scripted setter'}
    $contexts[3].ResourceJobSecondaryErrors=[Collections.ArrayList]::new()
    $contexts[4].ResourceJobReleaseReturned='false'
    foreach($context in $contexts) {
        $refused=Invoke-ReleaseSourceCase -Context $context
        Assert-ReleaseSource ($refused.Caught-and$refused.EnterCount-eq0) 'Wrong type/scripted/readonly/typed slots reached admission.'
    }
    Assert-ReleaseSource ($script:forbiddenContextAccesses-eq0) 'Validation executed a scripted context getter/setter.'
    foreach($mode in @('False','String','Number','Array','Two','Empty','Throw')) {
        $refused=Invoke-ReleaseSourceCase -Mode $mode
        Assert-ReleaseSource ($refused.Caught-and$refused.EnterCount-eq1-and$refused.ExitCount-eq0) ('Non-strict hook result released: '+$mode)
        Assert-ReleaseSource ([object]::ReferenceEquals($refused.Context.ResourceJobLease,$refused.Lease)-and!$refused.Context.ResourceJobReleaseAttempted-and!$refused.Context.ResourceJobReleaseReturned) 'Unknown release lost same lease or fabricated release.'
        Assert-ReleaseSource ([object]::ReferenceEquals($refused.Context.ResourceJobFirstException,$refused.Caught.Exception)) 'Hook primary Exception changed on rethrow.'
    }
    $bodyFailed=Invoke-ReleaseSourceCase -Configure {param($c)$c.BodyFails=$true}
    Assert-ReleaseSource ($bodyFailed.ExitCount-eq1-and$bodyFailed.Context.ResourceJobReleaseReturned) 'Known failed Body could not release after explicit known check.'
    Assert-ReleaseSource ([object]::ReferenceEquals($bodyFailed.Context.ResourceJobFirstException,$bodyFailed.BodyException)-and[object]::ReferenceEquals($bodyFailed.Caught.Exception,$bodyFailed.BodyException)) 'Body primary Exception was replaced.'
    Assert-ReleaseSource ([object]::ReferenceEquals($bodyFailed.FirstSeenByHook,$bodyFailed.Context.ResourceJobFirstErrorRecord)-and[object]::ReferenceEquals($bodyFailed.FirstExceptionSeenByHook,$bodyFailed.Context.ResourceJobFirstException)) 'First record/Exception was not retained identically.'
    $combined=Invoke-ReleaseSourceCase -Mode Throw -Configure {param($c)$c.BodyFails=$true;$c.RestoreFails=$true}
    Assert-ReleaseSource ($combined.ExitCount-eq0-and$combined.HookCount-eq1-and$combined.Context.ResourceJobSecondaryErrors.Count-eq2) 'Priority failure masked hook or allowed release.'
    Assert-ReleaseSource ([object]::ReferenceEquals($combined.Caught.Exception,$combined.BodyException)-and[object]::ReferenceEquals($combined.Context.ResourceJobFirstException,$combined.BodyException)) 'Combined failures masked Body.'
    Assert-ReleaseSource ($combined.Context.ResourceJobSecondaryErrors[0].Exception.Message-like'*restore failure*'-and[object]::ReferenceEquals($combined.Context.ResourceJobSecondaryErrors[1].Exception,$combined.HookException)) 'Secondary errors were reordered or copied.'
    foreach($property in @('ProcessFails','PriorityReadFails','PriorityUnknown','LowerFails','RestoreFails','RestoreSilent','EnterFails')) {
        $failure=Invoke-ReleaseSourceCase -Configure ([scriptblock]::Create('param($c)$c.'+$property+'=$true'))
        Assert-ReleaseSource ($failure.Caught-and$failure.EnterCount-eq1) ('Setup failure did not propagate: '+$property)
        if($property-cin@('ProcessFails','PriorityReadFails','PriorityUnknown','RestoreFails','RestoreSilent')) {
            Assert-ReleaseSource ($failure.ExitCount-eq0-and$failure.HookCount-eq1-and[object]::ReferenceEquals($failure.Context.ResourceJobLease,$failure.Lease)) 'Unknown priority/process must retain lease but still observe hook.'
        }
        if($property-ceq'EnterFails') { Assert-ReleaseSource ($failure.ExitCount-eq0-and$failure.HookCount-eq0-and$null-eq$failure.Context.ResourceJobLease) 'Failed Enter manufactured a lease or cleanup.' }
        if($property-ceq'LowerFails') { Assert-ReleaseSource ($failure.BodyCount-eq0-and$failure.ExitCount-eq1) 'Known restored priority after lower failure differs.' }
    }
    $releaseFailed=Invoke-ReleaseSourceCase -Configure {param($c)$c.ExitFails=$true}
    Assert-ReleaseSource ($releaseFailed.ExitCount-eq1-and$releaseFailed.Context.ResourceJobReleaseAttempted-and!$releaseFailed.Context.ResourceJobReleaseReturned) 'Exit throw fabricated known release.'
    Assert-ReleaseSource ([object]::ReferenceEquals($releaseFailed.Caught.Exception,$releaseFailed.ExitException)-and[object]::ReferenceEquals($releaseFailed.Context.ResourceJobLease,$releaseFailed.Lease)) 'Release failure lost original exception/lease.'
    $mutation=Invoke-ReleaseSourceCase -Configure {param($c)$c.HookMutation=$true}
    Assert-ReleaseSource ($mutation.Caught-and$mutation.ExitCount-eq0) 'Foreign same-token lease substituted in hook was accepted.'
    foreach($used in @($normal,$combined,$releaseFailed)) {
        $first=$used.Context.ResourceJobFirstErrorRecord;$exception=$used.Context.ResourceJobFirstException;$lease=$used.Context.ResourceJobLease
        $repeated=Invoke-ReleaseSourceCase -Context $used.Context
        Assert-ReleaseSource ($repeated.Caught-and$repeated.EnterCount-eq0) 'Reused/terminal context began a second admission.'
        Assert-ReleaseSource ([object]::ReferenceEquals($used.Context.ResourceJobFirstErrorRecord,$first)-and[object]::ReferenceEquals($used.Context.ResourceJobFirstException,$exception)-and[object]::ReferenceEquals($used.Context.ResourceJobLease,$lease)) 'Repeated unwind rewrote original retained state.'
    }
    Write-Output ("PASS "+$script:releaseSourceChecks+" retained-release Source assertions; actual function AST, fake lease/process/priority/hook only; no Core import, native provider, contender or real registry.")
    return
}

$ErrorActionPreference='Stop'
. "$PSScriptRoot/../../ops/Resource-Scheduler.Core.ps1"
function Assert($Value,[string]$Message) { if (!$Value) { throw $Message } }
if (!$TestRoot) { $TestRoot=Join-Path ([IO.Path]::GetTempPath()) ('iw7-resource-tests-'+[guid]::NewGuid().ToString('N')) }
[IO.Directory]::CreateDirectory($TestRoot) | Out-Null
# Tests never change the production global registry or launch a game.
function Get-IW7ResourceRoot { Join-Path $TestRoot 'registry' }
$script:fakeSnapshot=[pscustomobject]@{PhysicalTotal=32GB;PhysicalAvailable=28GB;CommitLimit=48GB;Committed=12GB}
function Get-IW7ResourceSnapshot { $script:fakeSnapshot }
$self=Get-Process -Id $PID
$script:fakeProcesses=@([pscustomobject]@{PID=$PID;ParentPID=0;CreatedUtc=$self.StartTime.ToUniversalTime().ToString('o');Image=$self.Path;Name='pwsh.exe';Lab=$false;Heavy=$false;WorkingSet=100MB;PrivateBytes=100MB})
function Get-IW7ResourceProcesses { $script:fakeProcesses }
if ($Contender) {
    try {
        $lease=Enter-IW7ResourceLease -Scope (Join-Path $TestRoot ('lab-'+$PID)) -Kind Build -PhysicalBytes 4GB -CommitBytes 6GB -Owner "contender-$PID"
        [IO.File]::WriteAllText($ResultPath,'admitted')
        # Keep the winner pending until both launchers have tried admission.
    } catch { [IO.File]::WriteAllText($ResultPath,'refused: '+$_.Exception.Message) }
    return
}
$snapshot=Get-IW7ResourceSnapshot
Assert (Test-IW7ResourceBudget $snapshot 96GB 96GB).Allowed 'An estimate above available RAM/commit must not refuse authorized work.'
$observed=Test-IW7ResourceBudget $snapshot 20GB 1GB
Assert ($observed.Policy -eq 'TelemetryOnly' -and $observed.PhysicalReserve -eq 0 -and $observed.CommitReserve -eq 0) 'No fixed RAM or commit reserve may survive.'
Assert ($observed.AdditionalPhysical -eq 20GB -and $observed.AdditionalCommit -eq 1GB) 'Whole-workload estimates remain visible as telemetry.'
$script:fakeSnapshot=[pscustomobject]@{PhysicalTotal=32GB;PhysicalAvailable=0;CommitLimit=48GB;Committed=48GB}
$busyBudget=Test-IW7ResourceBudget (Get-IW7ResourceSnapshot) 96GB 96GB
Assert ($busyBudget.Allowed -and !$busyBudget.HighWater -and $busyBudget.PhysicalUsedPercent -eq 100 -and $busyBudget.CommitUsedPercent -eq 100) 'No use percentage or estimated headroom may refuse or stop work; actual percentages remain visible.'
$bad=[pscustomobject]@{PhysicalTotal=0;PhysicalAvailable=0;CommitLimit=0;Committed=0}
$rejected=$false; try { Test-IW7ResourceBudget $bad 0 0 } catch { $rejected=$true }; Assert $rejected 'Missing telemetry must refuse.'
$scope=Join-Path $TestRoot 'lab-a'
$validSnapshot=$script:fakeSnapshot
$script:fakeSnapshot=$bad
$rejected=$false; try { Enter-IW7ResourceLease -Scope $scope -Kind Runtime -PhysicalBytes 14GB -CommitBytes 16GB -Owner 'invalid telemetry' } catch { $rejected=$true }; Assert $rejected 'Invalid telemetry must still block actual admission.'
Assert (@((Read-IW7ResourceState).Leases).Count -eq 0) 'Failed telemetry must not create a lease.'
$script:fakeSnapshot=$validSnapshot
$lease=Enter-IW7ResourceLease -Scope $scope -Kind Runtime -PhysicalBytes 14GB -CommitBytes 16GB -Owner 'test-a'
Assert ($lease.MemoryObservation.Snapshot.PhysicalAvailable -eq 0 -and $lease.MemoryObservation.Budget.Allowed) 'Real admission must accept low headroom and retain the fresh observation.'
$rejected=$false; try { Enter-IW7ResourceLease -Scope (Join-Path $TestRoot 'lab-b') -Kind Runtime -PhysicalBytes 1GB -CommitBytes 1GB -Owner 'test-b' } catch { $rejected=$true }
Assert $rejected 'A different holder must still block even though memory estimates never refuse.'
$script:fakeSnapshot=[pscustomobject]@{PhysicalTotal=32GB;PhysicalAvailable=1MB;CommitLimit=48GB;Committed=(48GB-1MB)}
$again=Enter-IW7ResourceLease -Scope $scope -Kind Runtime -PhysicalBytes 10GB -CommitBytes 10GB -Owner 'test-a'
Assert ($again.Token -eq $lease.Token -and $again.PhysicalBytes -eq 14GB) 'Reservation must be idempotent and cannot shrink.'
Assert ($again.MemoryObservation.Snapshot.PhysicalAvailable -eq 1MB -and (Read-IW7ResourceState).Leases[0].MemoryObservation.Snapshot.PhysicalAvailable -eq 1MB) 'Re-entry must persist a fresh observation rather than reuse earlier admission telemetry.'
$child=[pscustomobject]@{PID=12345;ParentPID=$PID;CreatedUtc='2026-10-04T10:00:00Z';Image=(Join-Path $scope 'iw7-paris-lab.exe');Name='iw7-paris-lab.exe';Lab=$true;Heavy=$true;WorkingSet=8GB;PrivateBytes=10GB}
$script:fakeProcesses += $child
Add-IW7ResourceProcess -Token $lease.Token -ProcessId 12345
$rejected=$false; try { Exit-IW7ResourceLease -Token $lease.Token } catch { $rejected=$true }; Assert $rejected 'Live child must retain reservation.'
$child.Image=$null
$rejected=$false; try { Exit-IW7ResourceLease -Token $lease.Token } catch { $rejected=$true }; Assert $rejected 'Unreadable child must retain reservation.'
$rejected=$false; try { Enter-IW7ResourceLease -Scope $scope -Kind Runtime -PhysicalBytes 14GB -CommitBytes 16GB -Owner 'test-a' } catch { $rejected=$true }; Assert $rejected 'Unknown attached identity must still block re-entry with low headroom.'
$child.Image='C:\Windows\unrelated.exe'; $child.CreatedUtc='2026-10-04T11:00:00Z'; $child.Lab=$false
Exit-IW7ResourceLease -Token $lease.Token
Assert (@((Get-IW7ResourceStatus).Leases).Count -eq 0) 'Reused PID must not be targeted or retain an old lease.'
$script:fakeProcesses=@($script:fakeProcesses | Where-Object PID -EQ $PID)
$launcherImage=$script:fakeProcesses[0].Image
$script:fakeProcesses[0].Image=$null
$rejected=$false; try { Enter-IW7ResourceLease -Scope $scope -Kind Runtime -PhysicalBytes 14GB -CommitBytes 16GB -Owner 'unknown launcher' } catch { $rejected=$true }; Assert $rejected 'Unknown launcher identity must still block first admission.'
$script:fakeProcesses[0].Image=$launcherImage
# The base client is an explicitly declared executable outside the server lab.
# Only its scoped fixture flags permit attachment; normal owner clients cannot
# be adopted, and the declaration/whole-scenario budget stay immutable.
$baseImage=Join-Path $TestRoot 'base/iw7-paris-voice.exe'
$baseLease=Enter-IW7ResourceLease -Scope $scope -Kind Runtime -PhysicalBytes 12GB -CommitBytes 12GB -Owner 'base-client test' -BaseClientImage $baseImage
$state=Read-IW7ResourceState
$state.Leases[0].BaseClientImage='relative/client.exe'
Save-IW7ResourceState $state
$rejected=$false; try { Get-IW7ResourceStatus } catch { $rejected=$true }; Assert $rejected 'Malformed persisted client declaration must refuse admission.'
$state.Leases[0].BaseClientImage=$baseImage
Save-IW7ResourceState $state
$baseChild=[pscustomobject]@{PID=33333;ParentPID=$PID;CreatedUtc='2026-10-04T12:00:00Z';Image=$baseImage;Name='iw7-paris-voice.exe';Lab=$true;BaseClientTest=$false;Heavy=$true;WorkingSet=4GB;PrivateBytes=5GB}
$script:fakeProcesses += $baseChild
$rejected=$false; try { Add-IW7ResourceProcess -Token $baseLease.Token -ProcessId 33333 } catch { $rejected=$true }; Assert $rejected 'Ordinary owner client cannot be adopted.'
$baseChild.BaseClientTest=$true; $baseChild.Lab=$false
$rejected=$false; try { Add-IW7ResourceProcess -Token $baseLease.Token -ProcessId 33333 } catch { $rejected=$true }; Assert $rejected 'Both private client fixture markers are required.'
$baseChild.Lab=$true
$rejected=$false; try { Exit-IW7ResourceLease -Token $baseLease.Token } catch { $rejected=$true }; Assert $rejected 'Unregistered declared client must retain reservation.'
Add-IW7ResourceProcess -Token $baseLease.Token -ProcessId 33333
$again=Enter-IW7ResourceLease -Scope $scope -Kind Runtime -PhysicalBytes 8GB -CommitBytes 8GB -Owner 'base-client test'
Assert ($again.Token -eq $baseLease.Token -and $again.PhysicalBytes -eq 12GB) 'Declared client re-entry keeps full scenario budget.'
$rejected=$false; try { Enter-IW7ResourceLease -Scope $scope -Kind Runtime -PhysicalBytes 12GB -CommitBytes 12GB -Owner 'base-client test' -BaseClientImage (Join-Path $TestRoot 'other.exe') } catch { $rejected=$true }; Assert $rejected 'Cannot change declared base image after reservation.'
$baseChild.Image=Join-Path $TestRoot 'foreign/iw7-paris-voice.exe'
$rejected=$false; try { Add-IW7ResourceProcess -Token $baseLease.Token -ProcessId 33333 } catch { $rejected=$true }; Assert $rejected 'A different executable remains outside scope.'
$script:fakeProcesses=@($script:fakeProcesses | Where-Object PID -EQ $PID)
Exit-IW7ResourceLease -Token $baseLease.Token
# Unmanaged labs and builds must also block admission, without touching them.
$rogue=[pscustomobject]@{PID=22222;ParentPID=0;CreatedUtc='2026-10-04T12:00:00Z';Image='C:\foreign\iw7-paris-lab.exe';Name='iw7-paris-lab.exe';Lab=$true;Heavy=$true;WorkingSet=1GB;PrivateBytes=2GB}
$script:fakeProcesses += $rogue
$rejected=$false; try { Enter-IW7ResourceLease -Scope $scope -Kind Build -PhysicalBytes 4GB -CommitBytes 6GB -Owner 'blocked' } catch { $rejected=$true }
Assert $rejected 'Unregistered foreign lab must block.'
$rogue.Lab=$false; $rogue.Name='MSBuild.exe'; $rogue.Image='C:\tools\MSBuild.exe'
$rejected=$false; try { Enter-IW7ResourceLease -Scope $scope -Kind Runtime -PhysicalBytes 14GB -CommitBytes 16GB -Owner 'blocked' } catch { $rejected=$true }
Assert $rejected 'Unregistered compiler must block.'
$script:fakeProcesses=@($script:fakeProcesses | Where-Object PID -EQ $PID)
$failed=$false
try { Invoke-IW7ResourceJob -Scope $scope -Owner 'intentional error' -Body { throw 'body failure' } } catch { $failed=$true }
Assert $failed 'Workload exception must propagate.'
Assert (@((Get-IW7ResourceStatus).Leases).Count -eq 0) 'Failed synchronous job must release.'
# A real cross-process race on a shared file lock, without heavyweight children.
$shell=(Get-Process -Id $PID).Path
$children=@()
foreach ($i in 1..2) {
    $result=Join-Path $TestRoot "contender-$i.txt"
    $args=@('-NoProfile','-File',('"'+$PSCommandPath+'"'),'-Contender','-TestRoot',('"'+$TestRoot+'"'),'-ResultPath',('"'+$result+'"'))
    $children+=Start-Process -FilePath $shell -ArgumentList $args -WindowStyle Hidden -PassThru
}
foreach ($childProcess in $children) { Assert ($childProcess.WaitForExit(15000)) 'Contender timed out.'; Assert ($childProcess.ExitCode -eq 0) 'Contender failed.' }
$outcomes=@(Get-Content (Join-Path $TestRoot 'contender-1.txt');Get-Content (Join-Path $TestRoot 'contender-2.txt'))
Assert (@($outcomes | Where-Object {$_ -eq 'admitted'}).Count -eq 1) 'Exactly one cross-process contender must win.'
Assert (@($outcomes | Where-Object {$_ -like 'refused:*'}).Count -eq 1) 'Exactly one contender must defer.'
# An orphan build stays visible; explicit release only after no heavy child exists.
$remaining=(Get-IW7ResourceStatus).Leases
Assert (@($remaining).Count -eq 1) 'Orphan build must remain quarantined.'
Exit-IW7ResourceLease -Token $remaining[0].Token
Assert (@((Get-IW7ResourceStatus).Leases).Count -eq 0) 'Proven closed orphan can be released.'
Write-Output 'Resource scheduler passed: telemetry-only memory admission, unknown telemetry/identity, idempotency, PID reuse, failure cleanup and real cross-process contention.'
Write-Output "Test evidence retained: $TestRoot"
