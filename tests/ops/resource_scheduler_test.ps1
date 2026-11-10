param([switch]$Contender,[string]$TestRoot,[string]$ResultPath,[switch]$RetainedReleaseSourceOnly,[switch]$InitialAdmissionSourceOnly)
if ($InitialAdmissionSourceOnly) {
    $ErrorActionPreference='Stop'
    # Extract actual production definitions; return before imports/real contenders.
    $tokens=$null;$parseErrors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../../ops/Resource-Scheduler.Core.ps1'),[ref]$tokens,[ref]$parseErrors)
    if($parseErrors.Count){throw 'Production Source parse failed.'}
    $definitions=@(foreach($name in @('Get-IW7CanonicalScope','Read-IW7ResourceState','Enter-IW7ResourceLease')){
        $matches=@($ast.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq$name},$true))
        if($matches.Count-ne1){throw ('One actual Source function required: '+$name)}
        $matches[0].Extent.Text
    })
    $script:initialChecks=0;$script:initialCases=0
    function Assert-InitialAdmission($Value,[string]$Message){$script:initialChecks++;if(!$Value){throw $Message}}
    $scope='c:\source-only\initial-admission'
    $baseImage='C:\source-only\base-client.exe'
    function New-InitialAdmissionLease {
        [pscustomobject]@{Token='0123456789abcdef0123456789abcdef';Scope=$scope;Kind='Runtime';Owner='retained owner';
            OwnerIdentity=[pscustomobject]@{PID=987654;Image='C:\source-only\original-host.exe';CreatedUtc='2026-10-19T00:00:00.0000000Z'};
            CreatedUtc='2026-10-19T00:00:00.0000000Z';Phase='Running';PhysicalBytes=17GB;CommitBytes=23GB;
            BaseClientImage=$baseImage;Processes=@();MemoryObservation=[pscustomobject]@{Historical=$true}}
    }
    function Invoke-InitialAdmissionCase {
        param([string]$Json='{"Version":1,"Leases":[]}',[string]$Mode='True',[switch]$Missing,[string]$RaceJson,
            [long]$PhysicalBytes=14GB,[long]$CommitBytes=15GB,[object[]]$Live=@())
        $script:initialCases++
        $c=[pscustomobject]@{Json=$Json;Exists=!$Missing;RaceJson=$RaceJson;RaceApplied=$false;BeforeJson=$null;
            BeforeParsedJson=$null;ReadState=$null;InitialMemory=$null;LockHeld=$false;LockCount=0;ReadCount=0;
            PathCount=0;ContentCount=0;ProcessCount=0;ReclaimCount=0;SnapshotCount=0;BudgetCount=0;SaveCount=0;LiveCount=0;
            Result=$null;Caught=$null;SavedState=$null;Budget=$null;BudgetArgs=$null;Live=$Live;
            Snapshot=[pscustomobject]@{PhysicalTotal=32GB;PhysicalAvailable=1MB;CommitLimit=48GB;Committed=47GB};
            Processes=@([pscustomobject]@{PID=$PID;Image='C:\source-only\pwsh.exe';CreatedUtc='2026-10-19T01:00:00.0000000Z';
                Name='pwsh.exe';Lab=$false;WorkingSet=0L;PrivateBytes=0L})}
        & {
            param($c,$definitions,$Mode,$PhysicalBytes,$CommitBytes,$scope,$baseImage)
            foreach($definition in $definitions){. ([scriptblock]::Create($definition))}
            # Keep the real reader body; this proxy only retains its actual result.
            $actualReader=(Get-Command Read-IW7ResourceState -CommandType Function).ScriptBlock
            function Get-IW7ResourceRoot { 'C:\source-only\fake-registry' }
            function Test-Path {
                param($LiteralPath)
                Assert-InitialAdmission ($c.LockHeld-and$LiteralPath-ceq'C:\source-only\fake-registry\leases.json') 'Reader left the fake registry or lock.'
                $c.PathCount++;$c.Exists
            }
            function Get-Content {
                param($LiteralPath,[switch]$Raw,$ErrorAction)
                Assert-InitialAdmission ($c.LockHeld-and$Raw-and$LiteralPath-ceq'C:\source-only\fake-registry\leases.json') 'Reader used another path/mode.'
                $c.ContentCount++;$c.Json
            }
            function Read-IW7ResourceState {
                $c.ReadCount++;$read=& $actualReader
                $c.ReadState=$read;$c.BeforeParsedJson=$read|ConvertTo-Json -Depth 20 -Compress
                if(@($read.Leases).Count){$c.InitialMemory=$read.Leases[0].MemoryObservation}
                $read
            }
            function Invoke-IW7ResourceLock {
                param([scriptblock]$Body)
                if($c.LockHeld){throw 'Nested Source lock is forbidden.'}
                $c.LockCount++;$c.LockHeld=$true
                try {
                    # The earlier photo is empty; a competitor wins before locked read.
                    if($c.RaceJson){$c.Json=$c.RaceJson;$c.Exists=$true;$c.RaceApplied=$true}
                    $c.BeforeJson=$c.Json
                    & $Body
                } finally {$c.LockHeld=$false}
            }
            function Get-IW7ResourceProcesses {$c.ProcessCount++;$c.Processes}
            function Remove-IW7FinishedRuntimeLeases {param($State,$Processes)$c.ReclaimCount++}
            function Get-IW7LeaseLiveProcesses {param($Lease,$Processes)$c.LiveCount++;$c.Live}
            function Test-IW7ProcessInScope {param($Process,$Scope)throw 'Unexpected scope callback.'}
            function Test-IW7ReservedProcess {param($Process,$Lease)throw 'Unexpected reserved-process callback.'}
            function Get-IW7ResourceSnapshot {$c.SnapshotCount++;$c.Snapshot}
            function Test-IW7ResourceBudget {
                param($Snapshot,[long]$PhysicalBytes,[long]$CommitBytes)
                $c.BudgetCount++;$c.BudgetArgs=@($PhysicalBytes,$CommitBytes)
                $c.Budget=[pscustomobject]@{Allowed=$true;Policy='TelemetryOnly';Physical=$PhysicalBytes;Commit=$CommitBytes}
                $c.Budget
            }
            function Save-IW7ResourceState {
                param($State)
                $c.SaveCount++;$c.SavedState=$State;$c.Json=$State|ConvertTo-Json -Depth 20 -Compress
            }
            try {
                $arguments=@{Scope=$scope;Kind='Runtime';PhysicalBytes=$PhysicalBytes;CommitBytes=$CommitBytes;Owner='initial-source';BaseClientImage=$baseImage}
                if($Mode-ceq'True'){$c.Result=Enter-IW7ResourceLease @arguments -RequireNewLease}
                elseif($Mode-ceq'False'){$c.Result=Enter-IW7ResourceLease @arguments -RequireNewLease:$false}
                elseif($Mode-ceq'Omitted'){$c.Result=Enter-IW7ResourceLease @arguments}
                else{throw 'Unknown Source mode.'}
            } catch {$c.Caught=$_}
        } $c $definitions $Mode $PhysicalBytes $CommitBytes $scope $baseImage
        $c
    }
    function Assert-InitialRefusal($Case,[string]$Name,[switch]$Malformed) {
        Assert-InitialAdmission ($null-ne$Case.Caught-and$null-eq$Case.Result) ('No refusal: '+$Name)
        if(!$Malformed){Assert-InitialAdmission ($Case.Caught.Exception.Message-like'A new resource lease was required;*') ('Wrong refusal: '+$Name)}
        Assert-InitialAdmission ($Case.LockCount-eq1-and$Case.ReadCount-eq1-and!$Case.LockHeld) ('Real reader/lock not reached once: '+$Name)
        foreach($counter in @('ProcessCount','ReclaimCount','SnapshotCount','BudgetCount','SaveCount','LiveCount')){
            Assert-InitialAdmission ($Case.$counter-eq0) ('Forbidden callback '+$counter+': '+$Name)
        }
        Assert-InitialAdmission ($Case.Json-ceq$Case.BeforeJson) ('Registry text changed: '+$Name)
        if($null-ne$Case.ReadState){
            Assert-InitialAdmission (($Case.ReadState|ConvertTo-Json -Depth 20 -Compress)-ceq$Case.BeforeParsedJson) ('Actual parsed state mutated: '+$Name)
        }
    }
    foreach($variant in @('SameScopeSameImage','DifferentScope','SameOwner','Orphan','UnknownOwner','OtherKind','Pending','Multiple','RaceAfterEmptyPhoto')){
        $lease=New-InitialAdmissionLease
        switch($variant){
            'DifferentScope' {$lease.Scope='C:\source-only\foreign'}
            'SameOwner' {$lease.OwnerIdentity=[pscustomobject]@{PID=$PID;Image='C:\source-only\pwsh.exe';CreatedUtc='2026-10-19T01:00:00.0000000Z'}}
            'Orphan' {$lease.OwnerIdentity.PID=999999}
            'UnknownOwner' {$lease.OwnerIdentity.Image=$null;$lease.OwnerIdentity.CreatedUtc=$null}
            'OtherKind' {$lease.Kind='Build';$lease.BaseClientImage=$null}
            'Pending' {$lease.Phase='Pending'}
        }
        $leases=@($lease)
        if($variant-ceq'Multiple'){$leases+=New-InitialAdmissionLease}
        $json=[pscustomobject]@{Version=1;Leases=$leases}|ConvertTo-Json -Depth 20 -Compress
        if($variant-ceq'RaceAfterEmptyPhoto'){
            $case=Invoke-InitialAdmissionCase -RaceJson $json
            Assert-InitialAdmission ($case.RaceApplied-and$case.BeforeJson-ceq$json) 'Race did not install the foreign state under lock.'
        }else{$case=Invoke-InitialAdmissionCase -Json $json}
        Assert-InitialRefusal $case $variant
    }
    $badLease=New-InitialAdmissionLease;$badLease.Phase='Unknown'
    foreach($malformed in @('{','{"Version":2,"Leases":[]}','{"Version":1,"Leases":null}',
        ([pscustomobject]@{Version=1;Leases=@($badLease)}|ConvertTo-Json -Depth 20 -Compress))){
        $case=Invoke-InitialAdmissionCase -Json $malformed
        Assert-InitialRefusal $case 'Malformed real reader' -Malformed
        Assert-InitialAdmission ($case.PathCount-eq1-and$case.ContentCount-eq1) 'Malformed case bypassed actual reader IO seams.'
        Assert-InitialAdmission ($case.Caught.Exception.Message-notlike'A new resource lease was required;*') 'Malformed reader was replaced by the new guard.'
    }
    foreach($missing in @($false,$true)){
        $case=Invoke-InitialAdmissionCase -Missing:$missing
        Assert-InitialAdmission ($null-eq$case.Caught-and$null-ne$case.Result) 'Empty first admission failed.'
        Assert-InitialAdmission ($case.Result.Token-is[string]-and$case.Result.Token-cmatch'^[0-9a-f]{32}$') 'Fresh token not scalar lowercase hex.'
        Assert-InitialAdmission ($case.LockCount-eq1-and$case.ReadCount-eq1-and$case.ProcessCount-eq1-and$case.ReclaimCount-eq1-and$case.SnapshotCount-eq1-and$case.BudgetCount-eq1-and$case.SaveCount-eq1) 'Fresh path callbacks changed.'
        Assert-InitialAdmission ($case.Result.Scope-ceq$scope-and$case.Result.BaseClientImage-ceq$baseImage-and$case.Result.Phase-ceq'Pending') 'Fresh reservation metadata changed.'
        Assert-InitialAdmission ([object]::ReferenceEquals($case.Result.OwnerIdentity,$case.Processes[0])-and[object]::ReferenceEquals($case.SavedState,$case.ReadState)) 'Fresh actual identities/state copied.'
        Assert-InitialAdmission ([object]::ReferenceEquals($case.Result.MemoryObservation.Snapshot,$case.Snapshot)-and[object]::ReferenceEquals($case.Result.MemoryObservation.Budget,$case.Budget)) 'Fresh memory observation changed.'
    }
    foreach($mode in @('Omitted','False')){
        foreach($larger in @($false,$true)){
            $lease=New-InitialAdmissionLease
            $json=[pscustomobject]@{Version=1;Leases=@($lease)}|ConvertTo-Json -Depth 20 -Compress
            $physical=if($larger){24GB}else{14GB};$commit=if($larger){27GB}else{15GB}
            $live=@([pscustomobject]@{WorkingSet=2GB;PrivateBytes=3GB})
            $case=Invoke-InitialAdmissionCase -Mode $mode -Json $json -PhysicalBytes $physical -CommitBytes $commit -Live $live
            $expectedPhysical=[math]::Max($physical,17GB);$expectedCommit=[math]::Max($commit,23GB)
            Assert-InitialAdmission ($null-eq$case.Caught-and$case.Result.Token-ceq$lease.Token) ('Legacy token/re-entry changed: '+$mode)
            Assert-InitialAdmission ([object]::ReferenceEquals($case.Result,$case.ReadState.Leases[0])-and[object]::ReferenceEquals($case.SavedState,$case.ReadState)) 'Legacy lease/state not the real reader objects.'
            Assert-InitialAdmission ($case.Result.PhysicalBytes-eq$expectedPhysical-and$case.Result.CommitBytes-eq$expectedCommit) 'Legacy maximum estimates changed.'
            Assert-InitialAdmission ($case.BudgetArgs[0]-eq($expectedPhysical-2GB)-and$case.BudgetArgs[1]-eq($expectedCommit-3GB)) 'Legacy resident budget subtraction changed.'
            Assert-InitialAdmission ($case.ProcessCount-eq1-and$case.ReclaimCount-eq1-and$case.LiveCount-eq1-and$case.SnapshotCount-eq1-and$case.BudgetCount-eq1-and$case.SaveCount-eq1) 'Legacy callbacks changed.'
            Assert-InitialAdmission ([object]::ReferenceEquals($case.Result.MemoryObservation.Snapshot,$case.Snapshot)-and[object]::ReferenceEquals($case.Result.MemoryObservation.Budget,$case.Budget)-and![object]::ReferenceEquals($case.Result.MemoryObservation,$case.InitialMemory)) 'Legacy fresh MemoryObservation changed.'
        }
    }
    Write-Output ("PASS "+$script:initialCases+" initial-admission Source cases / "+$script:initialChecks+" assertions; actual Enter/ReadState AST, fake lock/registry/process/reclaim/telemetry/budget/Save; no Core import, real registry, native telemetry, contenders or OS lifecycle.")
    return
}
if ($RetainedReleaseSourceOnly) {
    $ErrorActionPreference='Stop'
    # Only the actual function AST; never import Core or run real contenders.
    $tokens=$null;$parseErrors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../../ops/Resource-Scheduler.Core.ps1'),[ref]$tokens,[ref]$parseErrors)
    if($parseErrors.Count){throw 'Production Source parse failed.'}
    $functions=@($ast.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq'Invoke-IW7ResourceJob'},$true))
    if($functions.Count-ne1){throw 'One actual function required.'}
    $source=$functions[0].Extent.Text
    $script:checks=0;$script:ownedRootKeys=[Collections.Generic.List[string]]::new()
    function Assert-Source($v,[string]$message){$script:checks++;if(!$v){throw $message}}
    function New-SourceView {
        [pscustomobject]@{ResourceJobLease=$null;ResourceJobFirstErrorRecord=$null;ResourceJobFirstException=$null;
            ResourceJobSecondaryErrors=$null;ResourceJobReleaseAttempted=$false;ResourceJobReleaseReturned=$false}
    }
    function Invoke-SourceCase([scriptblock]$Configure,[object]$View) {
        if($null-eq$View){$View=New-SourceView}
        $c=[pscustomobject]@{
            View=$View;Events=[Collections.Generic.List[string]]::new();PrivateVisible=[Collections.Generic.List[string]]::new()
            Lease=[pscustomobject]@{Token='0123456789abcdef0123456789abcdef'}
            Mode='True';Mutation='';MutationStage='';TokenStage='';TokenValue=$null
            OmitHook=$false;OmitView=$false;OmitRoot=$false;NullHook=$false;NullView=$false;NullRoot=$false;Legacy=$false
            WrongWitness=$false;ReadonlyRoot=$false;UsedRoot=$false;WrongRoot=$false;AttributedRoot=$false;ProbePrivate=$false;Reenter=$false
            EnterFails=$false;ProcessFails=$false;ReadFails=$false;UnknownPriority=$false;LowerFails=$false
            RestoreFails=$false;RestoreSilent=$false;BodyFails=$false;ExitFails=$false
            EnterCount=0;ExitCount=0;BodyCount=0;HookCount=0
            RootVariable=$null;RootKey=$null;Owner=$null;OriginalSlots=$null;Caught=$null;Output=$null;ReenterCaught=$null;ReenterOwner=$null
            BodyException=[InvalidOperationException]::new('authored body failure')
            HookException=[InvalidOperationException]::new('authored hook failure')
            ExitException=[InvalidOperationException]::new('authored exit failure')
            Priority=[Diagnostics.ProcessPriorityClass]::Normal;HookFirst=$null;HookExceptionRef=$null;ExitToken=$null;Args=$null
        }
        if($Configure){&$Configure $c}
        & {
            param($c,$source)
            . ([scriptblock]::Create($source))
            $rootName='rr_source_'+[guid]::NewGuid().ToString('N')
            $c.RootVariable=New-Variable -Name $rootName -Value $null -PassThru
            $c.RootKey='IW7.ResourceJob.RetainedRelease.'+$rootName
            $script:ownedRootKeys.Add($c.RootKey)
            [AppDomain]::CurrentDomain.SetData($c.RootKey,$c.RootVariable)
            if($c.WrongWitness){[AppDomain]::CurrentDomain.SetData($c.RootKey,[Management.Automation.PSVariable]::new($rootName,$null))}
            if($c.ReadonlyRoot){$c.RootVariable.Options=[Management.Automation.ScopedItemOptions]::ReadOnly}
            if($c.UsedRoot){$c.RootVariable.Value='already used'}
            if($c.AttributedRoot){$c.RootVariable.Attributes.Add([Management.Automation.AllowNullAttribute]::new())}
            $c.OriginalSlots=@($c.View.PSObject.Properties)
            if($c.TokenStage-ceq'Initial'){$c.Lease.Token=$c.TokenValue}
            function Enter-IW7ResourceLease {
                param($Scope,$Kind,$PhysicalBytes,$CommitBytes,$Owner)
                $c.Events.Add('enter');$c.EnterCount++;$c.Args=@($Scope,$Kind,$PhysicalBytes,$CommitBytes,$Owner)
                if($c.EnterFails){throw 'authored enter failure'}
                return $c.Lease
            }
            function Exit-IW7ResourceLease {
                param($Token)
                $c.Events.Add('exit');$c.ExitCount++;$c.ExitToken=$Token
                if($c.ExitFails){throw $c.ExitException}
            }
            function Get-Process {
                param($Id)
                $c.Events.Add('process');if($c.ProcessFails){throw 'authored process failure'}
                $p=[pscustomobject]@{State=$c}
                $p|Add-Member ScriptProperty PriorityClass {
                    $this.State.Events.Add('read')
                    if($this.State.ReadFails){throw 'authored priority read failure'}
                    if($this.State.UnknownPriority){return $null}
                    $this.State.Priority
                } {
                    param($value)
                    $step=if($value-eq[Diagnostics.ProcessPriorityClass]::BelowNormal){'lower'}else{'restore'}
                    $this.State.Events.Add($step)
                    if(($step-ceq'lower'-and$this.State.LowerFails)-or($step-ceq'restore'-and$this.State.RestoreFails)){throw ('authored '+$step+' failure')}
                    if($step-ceq'restore'-and$this.State.RestoreSilent){return}
                    $this.State.Priority=$value
                    if(($step-ceq'lower'-and$this.State.TokenStage-ceq'BeforeBody')-or($step-ceq'restore'-and$this.State.TokenStage-ceq'BeforeHook')){
                        $this.State.Lease.Token=$this.State.TokenValue
                    }
                }
                return $p
            }
            function Invoke-AuthoredMutation($v) {
                switch -CaseSensitive($c.Mutation){
                    'LeaseNull' {$v.ResourceJobLease=$null}
                    'RemoveLease' {$v.PSObject.Properties.Remove('ResourceJobLease')}
                    'ReplaceLease' {$v.PSObject.Properties.Remove('ResourceJobLease');$v|Add-Member NoteProperty ResourceJobLease $null}
                    'RemoveFirst' {$v.PSObject.Properties.Remove('ResourceJobFirstErrorRecord')}
                    'NullFirst' {$v.ResourceJobFirstErrorRecord=$null}
                    'ReplaceSecondary' {$v.ResourceJobSecondaryErrors=[Collections.Generic.List[Management.Automation.ErrorRecord]]::new()}
                    'ClearSecondary' {$v.ResourceJobSecondaryErrors.Clear()}
                    'WriteOwner' {$c.RootVariable.Value['Lease']=$null}
                    'WriteJournal' {$c.RootVariable.Value['Journal'][0]['Exception']=$null}
                }
            }
            $body={
                $c.Events.Add('body');$c.BodyCount++
                if($c.ProbePrivate){
                    foreach($name in @('jobStore','jobJournal','jobSecondary','jobEvidence','jobExpected','jobSlots')){
                        if(Get-Variable -Name $name -ErrorAction SilentlyContinue){$c.PrivateVisible.Add('body:'+ $name)}
                    }
                }
                if($c.MutationStage-ceq'Body'){Invoke-AuthoredMutation $c.View}
                if($c.TokenStage-ceq'AfterBody'){$c.Lease.Token=$c.TokenValue}
                if($c.BodyFails){throw $c.BodyException}
                'authored output'
            }
            $hook={
                param($actual)
                $c.Events.Add('hook');$c.HookCount++
                $c.HookFirst=$actual.ResourceJobFirstErrorRecord;$c.HookExceptionRef=$actual.ResourceJobFirstException
                if($c.ProbePrivate){
                    foreach($name in @('jobStore','jobJournal','jobSecondary','jobEvidence','jobExpected','jobSlots')){
                        if(Get-Variable -Name $name -ErrorAction SilentlyContinue){$c.PrivateVisible.Add('hook:'+ $name)}
                    }
                }
                if($c.MutationStage-ceq'Hook'){Invoke-AuthoredMutation $actual}
                if($c.TokenStage-ceq'AfterHook'){$c.Lease.Token=$c.TokenValue}
                switch -CaseSensitive($c.Mode){
                    'True' {$true};'False' {$false};'String' {'true'};'Number' {1};'Array' {,@($true)};'Two' {$true;$true};'Empty' {}
                    'Throw' {throw $c.HookException}
                }
            }
            $args=@{Scope='owned-source';Kind='Analysis';PhysicalBytes=17;CommitBytes=23;Owner='authored';Body=$body}
            if(!$c.Legacy){
                if(!$c.OmitHook){$args.BeforeReleaseCheck=if($c.NullHook){$null}else{$hook}}
                if(!$c.OmitView){$args.OriginalContext=if($c.NullView){$null}else{$c.View}}
                if(!$c.OmitRoot){$args.RetentionRoot=if($c.NullRoot){$null}elseif($c.WrongRoot){[version]'1.2'}else{$c.RootVariable}}
            }
            try{$c.Output=Invoke-IW7ResourceJob @args}catch{$c.Caught=$_}
            $c.Owner=$c.RootVariable.Value
            if($c.Reenter){
                $args.OriginalContext=New-SourceView
                try{Invoke-IW7ResourceJob @args}catch{$c.ReenterCaught=$_}
                $c.ReenterOwner=$c.RootVariable.Value
            }
        } $c $source
        return $c
    }
    try {
        $legacy=@(
            '    $lease=Enter-IW7ResourceLease -Scope $Scope -Kind $Kind -PhysicalBytes $PhysicalBytes -CommitBytes $CommitBytes -Owner $Owner',
            '    $process=Get-Process -Id $PID','    $priority=$process.PriorityClass','    try {',
            '        $process.PriorityClass=''BelowNormal''','        & $Body','    } finally {',
            '        $process.PriorityClass=$priority','        Exit-IW7ResourceLease -Token $lease.Token','    }','}'
        )-join[string][char]10
        Assert-Source ($source.Replace([string][char]13,'').EndsWith($legacy,[StringComparison]::Ordinal)) 'Legacy literal tail changed.'
        $old=Invoke-SourceCase -Configure {param($c)$c.Legacy=$true}
        Assert-Source (!$old.Caught-and$old.EnterCount-eq1-and$old.ExitCount-eq1-and$old.HookCount-eq0-and$null-eq$old.Owner) 'Legacy semantics/root changed.'
        $ok=Invoke-SourceCase -Configure {param($c)$c.ProbePrivate=$true}
        Assert-Source (!$ok.Caught-and$ok.Output-ceq'authored output'-and$ok.ExitCount-eq1) 'Known normal Source outcome failed.'
        Assert-Source (($ok.Events-join',')-ceq'enter,process,read,lower,body,restore,read,hook,exit') 'Actual operation order differs.'
        Assert-Source ([object]::ReferenceEquals($ok.RootVariable.Value,$ok.Owner)-and[object]::ReferenceEquals([AppDomain]::CurrentDomain.GetData($ok.RootKey),$ok.RootVariable)) 'Original root owner differs after unwind.'
        Assert-Source ([object]::ReferenceEquals($ok.Owner['Lease'],$ok.Lease)-and$ok.Owner['ReleaseReturned']-and$ok.Owner['ReleaseAttempted']) 'Original lease/release outcome not durable.'
        Assert-Source ($ok.PrivateVisible.Count-eq0) ('Private writer exposed: '+($ok.PrivateVisible-join','))
        Assert-Source (($ok.Args-join'|')-ceq'owned-source|Analysis|17|23|authored') 'Admission arguments changed.'
        foreach($flag in @('OmitHook','OmitView','OmitRoot','NullHook','NullView','NullRoot','WrongWitness','ReadonlyRoot','UsedRoot','WrongRoot')){
            $x=Invoke-SourceCase -Configure ([scriptblock]::Create('param($c)$c.'+$flag+'=$true'))
            Assert-Source ($x.Caught-and$x.EnterCount-eq0) ('Bad triple/root reached admission: '+$flag)
        }
        $script:forbiddenGetter=0
        $badView=New-SourceView;$badView.PSObject.Properties.Remove('ResourceJobLease')
        $badView|Add-Member ScriptProperty ResourceJobLease {$script:forbiddenGetter++;throw 'forbidden'} {$script:forbiddenGetter++;throw 'forbidden'}
        foreach($view in @(@{},[version]'1.2',$badView)){
            $x=Invoke-SourceCase -View $view
            Assert-Source ($x.Caught-and$x.EnterCount-eq0) 'Bad view reached admission.'
        }
        Assert-Source ($script:forbiddenGetter-eq0) 'Validation invoked a scripted view accessor.'
        $attributed=Invoke-SourceCase -Configure {param($c)$c.AttributedRoot=$true}
        # Even an inert attribute is outside the ordinary root data contract.
        Assert-Source ($attributed.Caught-and$attributed.EnterCount-eq0-and$null-eq$attributed.Owner) 'Attributed root reached admission/binding.'
        foreach($mode in @('False','String','Number','Array','Two','Empty','Throw')){
            $x=Invoke-SourceCase -Configure ([scriptblock]::Create("param("+[char]36+"c)"+[char]36+"c.Mode='"+$mode+"'"))
            Assert-Source ($x.Caught-and$x.EnterCount-eq1-and$x.ExitCount-eq0) ('Non-strict check released: '+$mode)
            Assert-Source ([object]::ReferenceEquals($x.Owner['Lease'],$x.Lease)-and!$x.Owner['ReleaseAttempted']-and!$x.Owner['ReleaseReturned']) 'Unknown lease not retained independently.'
            Assert-Source ([object]::ReferenceEquals($x.Caught.Exception,$x.Owner['FirstException'])) 'Check primary Exception changed.'
        }
        foreach($stage in @('Body','Hook')){
            foreach($mutation in @('LeaseNull','RemoveLease','ReplaceLease','RemoveFirst','ReplaceSecondary')){
                $x=Invoke-SourceCase -Configure ([scriptblock]::Create("param("+[char]36+"c)"+[char]36+"c.MutationStage='"+$stage+"';"+[char]36+"c.Mutation='"+$mutation+"'"))
                Assert-Source ($x.Caught-and$x.ExitCount-eq0) ('Mutation released: '+$stage+'/'+$mutation)
                Assert-Source ([object]::ReferenceEquals($x.RootVariable.Value,$x.Owner)-and[object]::ReferenceEquals($x.Owner['Lease'],$x.Lease)) 'Actual lease disappeared AFTER unwind.'
                Assert-Source ($x.Owner['OriginalSlots'].Count-eq6-and[object]::ReferenceEquals($x.Owner['OriginalSlots'][0],$x.OriginalSlots[0])) 'Original removed/replaced slot disappeared AFTER unwind.'
                Assert-Source ([object]::ReferenceEquals($x.Owner['FirstErrorRecord'],$x.Owner['Journal'][0]['ErrorRecord'])-and[object]::ReferenceEquals($x.Caught.Exception,$x.Owner['FirstException'])) 'First record/Exception not durable after mutation.'
            }
        }
        $body=Invoke-SourceCase -Configure {param($c)$c.BodyFails=$true}
        Assert-Source ($body.ExitCount-eq1-and$body.Owner['ReleaseReturned']) 'Known failed Body could not release.'
        Assert-Source ([object]::ReferenceEquals($body.Owner['FirstException'],$body.BodyException)-and[object]::ReferenceEquals($body.Caught.Exception,$body.BodyException)) 'Body primary was replaced.'
        Assert-Source ([object]::ReferenceEquals($body.HookFirst,$body.Owner['FirstErrorRecord'])-and[object]::ReferenceEquals($body.HookExceptionRef,$body.BodyException)) 'Hook observed copied first error.'
        foreach($mutation in @('ClearSecondary','ReplaceSecondary','NullFirst','WriteOwner','WriteJournal')){
            $x=Invoke-SourceCase -Configure ([scriptblock]::Create("param("+[char]36+"c)"+[char]36+"c.BodyFails="+[char]36+"true;"+[char]36+"c.RestoreFails="+[char]36+"true;"+[char]36+"c.MutationStage='Hook';"+[char]36+"c.Mutation='"+$mutation+"'"))
            Assert-Source ($x.ExitCount-eq0-and$x.Owner['Journal'].Count-eq3-and$x.Owner['SecondaryErrors'].Count-eq2) ('Authoritative errors were erased: '+$mutation)
            Assert-Source ([object]::ReferenceEquals($x.Owner['FirstException'],$x.BodyException)-and[object]::ReferenceEquals($x.Caught.Exception,$x.BodyException)) 'Combined failure masked primary.'
            Assert-Source ($x.Owner['Journal'][1]['Frontier']-ceq'Priority'-and$x.Owner['Journal'][1]['Exception'].Message-like'*restore failure*') 'Priority secondary was lost/reordered.'
            Assert-Source ([object]::ReferenceEquals($x.Owner['SecondaryErrors'][0],$x.Owner['Journal'][1]['ErrorRecord'])) 'Secondary original record differs AFTER unwind.'
        }
        $combined=Invoke-SourceCase -Configure {param($c)$c.BodyFails=$true;$c.RestoreFails=$true;$c.Mode='Throw'}
        Assert-Source ([object]::ReferenceEquals($combined.Owner['Journal'][2]['Exception'],$combined.HookException)-and$combined.ExitCount-eq0) 'Hook secondary was copied or release allowed.'
        foreach($bodyFails in @($false,$true)){
            $againActual=Invoke-SourceCase -Configure ({param($c)$c.Reenter=$true;$c.BodyFails=$bodyFails}.GetNewClosure())
            Assert-Source ($againActual.ReenterCaught-and$againActual.EnterCount-eq1-and[object]::ReferenceEquals($againActual.Owner,$againActual.ReenterOwner)) 'Used actual root admitted again/replaced its owner.'
            Assert-Source ([object]::ReferenceEquals($againActual.ReenterOwner['Lease'],$againActual.Lease)) 'Used actual root lost its lease after second unwind.'
            if($bodyFails){Assert-Source ([object]::ReferenceEquals($againActual.ReenterOwner['FirstException'],$againActual.BodyException)) 'Repeated actual root masked first Exception.'}
        }
        foreach($flag in @('EnterFails','ProcessFails','ReadFails','UnknownPriority','LowerFails','RestoreFails','RestoreSilent','ExitFails')){
            $x=Invoke-SourceCase -Configure ([scriptblock]::Create('param($c)$c.'+$flag+'=$true'))
            Assert-Source ($x.Caught-and$x.EnterCount-eq1) ('Failure did not propagate: '+$flag)
            if($flag-ceq'EnterFails'){Assert-Source ($null-eq$x.Owner['Lease']-and$x.ExitCount-eq0) 'Failed Enter fabricated ownership.'}
            elseif($flag-ceq'LowerFails'){Assert-Source ($x.BodyCount-eq0-and$x.ExitCount-eq1) 'Known restored lower failure differs.'}
            elseif($flag-ceq'ExitFails'){Assert-Source ($x.Owner['ReleaseAttempted']-and!$x.Owner['ReleaseReturned']-and[object]::ReferenceEquals($x.Caught.Exception,$x.ExitException)) 'Release failure fabricated completion.'}
            else{Assert-Source ($x.ExitCount-eq0-and[object]::ReferenceEquals($x.Owner['Lease'],$x.Lease)) 'Unknown priority lost original lease.'}
        }
        $badTokens=@(
            @{Name='Null';Value=$null},@{Name='Empty';Value=''},@{Name='WrongString';Value=('f'*32)},@{Name='UpperHex';Value=('A'*32)},
            @{Name='Object';Value=[pscustomobject]@{Value='0123456789abcdef0123456789abcdef'}},
            @{Name='Array0';Value=[object[]]@()},@{Name='Array1';Value=[object[]]@('0123456789abcdef0123456789abcdef')}
        )
        foreach($stage in @('Initial','BeforeBody','AfterBody','BeforeHook','AfterHook')){
            foreach($bad in $badTokens){
                # Admission establishes the first token; any32lowerhex is valid
                # there. A different valid token is a counterexample only later.
                if($stage-ceq'Initial'-and$bad.Name-ceq'WrongString'){continue}
                $setup={param($c)$c.TokenStage=$stage;$c.TokenValue=$bad.Value}.GetNewClosure()
                $x=Invoke-SourceCase -Configure $setup
                Assert-Source ($x.Caught-and$x.ExitCount-eq0-and[object]::ReferenceEquals($x.Owner['Lease'],$x.Lease)) ('Token counterexample released/lost lease: '+$stage+'/'+$bad.Name)
                if($stage-ceq'AfterBody'){
                    Assert-Source ([object]::ReferenceEquals($x.Lease.Token,$bad.Value)-and$x.Owner['Token']-ceq'0123456789abcdef0123456789abcdef') 'Refusal repaired the live token or lost original comparison evidence.'
                }
            }
        }
        # Exact production predicate, also used immediately before Exit: prove its
        # scalar result without inventing an asynchronous token mutation window.
        $tokenGates=@($functions[0].FindAll({param($n)$n-is[Management.Automation.Language.IfStatementAst]-and$n.Extent.Text.Contains("throw 'The live original lease token must remain one exact scalar string.'")},$true)|Where-Object{$_.Extent.Text.StartsWith('if ($private:jobLiveToken -isnot')})
        Assert-Source ($tokenGates.Count-eq1) 'One exact shared scalar predicate required.'
        foreach($bad in $badTokens){
            $rejected=&{param($gate,$value)$private:jobLiveToken=$value;$private:jobStore=@{Token='0123456789abcdef0123456789abcdef'};try{.([scriptblock]::Create($gate));$false}catch{$true}} $tokenGates[0].Extent.Text $bad.Value
            Assert-Source $rejected ('Exact pre-Exit scalar predicate accepted '+$bad.Name)
        }
        Assert-Source ($source.Contains('. $private:jobAssert -jobCheckToken'+[char]10+'                        $private:jobStore[''ReleaseAttempted'']=$true'+[char]10+'                        Exit-IW7ResourceLease -Token $private:jobLiveToken')-or
            $source.Replace([string][char]13,'').Contains('. $private:jobAssert -jobCheckToken'+[char]10+'                        $private:jobStore[''ReleaseAttempted'']=$true'+[char]10+'                        Exit-IW7ResourceLease -Token $private:jobLiveToken')) 'Pre-Exit production gate is not immediately before attempt/call.'
        $first=$combined.Owner['FirstErrorRecord'];$exception=$combined.Owner['FirstException'];$lease=$combined.Owner['Lease']
        $again=Invoke-SourceCase -View $combined.View
        Assert-Source ($again.Caught-and$again.EnterCount-eq0) 'Used view began new admission.'
        Assert-Source ([object]::ReferenceEquals($combined.Owner['FirstErrorRecord'],$first)-and[object]::ReferenceEquals($combined.Owner['FirstException'],$exception)-and[object]::ReferenceEquals($combined.Owner['Lease'],$lease)) 'Repeated unwind overwrote original owner.'
        Write-Output ("PASS "+$script:checks+" retained-release corrective Source assertions; actual production AST/private token predicate, fake admission/process/priority/hook/Exit and owned managed root witnesses only; no Core import/real lease/registry/native/contenders.")
    } finally {
        foreach($key in $script:ownedRootKeys){[AppDomain]::CurrentDomain.SetData($key,$null)}
    }
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
# Invoke-IW7QueuedResourceJob queues a plain job behind a temporary holder for a bounded time; Invoke-IW7ResourceJob still refuses at once.
$waitHolder=Enter-IW7ResourceLease -Scope (Join-Path $TestRoot 'wait-holder') -Kind Runtime -PhysicalBytes 1GB -CommitBytes 1GB -Owner 'temporary holder'
$waitScope=Join-Path $TestRoot 'wait-job'
$message='';try { Invoke-IW7ResourceJob -Scope $waitScope -Owner 'no wait' -Body { 'ran' } } catch { $message=$_.Exception.Message }
Assert ($message -like 'Resource busy: Runtime owned by temporary holder.*') 'Without a wait a busy slot refuses at once.'
$script:waitSleeps=0
function Start-Sleep { $script:waitSleeps++ }
$message='';$clock=[Diagnostics.Stopwatch]::StartNew()
try { Invoke-IW7QueuedResourceJob -Scope $waitScope -Owner 'bounded wait' -WaitForSlotSeconds 1 -Body { 'ran' } } catch { $message=$_.Exception.Message }
Assert ($message -like 'Resource busy: Runtime owned by temporary holder.*' -and $script:waitSleeps -ge 1 -and $clock.Elapsed.TotalSeconds -ge 1) 'At the bound the last refusal is thrown, after waiting.'
Assert (@((Get-IW7ResourceStatus).Leases).Count -eq 1) 'A refused waiter must leave no lease.'
$script:waitSleeps=0
function Start-Sleep { $script:waitSleeps++; if ($script:waitSleeps -eq 2) { Exit-IW7ResourceLease -Token $waitHolder.Token } }
$ran=Invoke-IW7QueuedResourceJob -Scope $waitScope -Owner 'queued job' -WaitForSlotSeconds 600 -Body { 'ran' }
Assert ($ran -eq 'ran' -and $script:waitSleeps -eq 2) 'The queued job must run once the holder releases.'
Assert (@((Get-IW7ResourceStatus).Leases).Count -eq 0) 'The queued job must release its lease.'
$rogueWait=[pscustomobject]@{PID=22223;ParentPID=0;CreatedUtc='2026-10-04T12:00:00Z';Image='C:\foreign\iw7-paris-lab.exe';Name='iw7-paris-lab.exe';Lab=$true;Heavy=$true;WorkingSet=1GB;PrivateBytes=2GB}
$script:fakeProcesses += $rogueWait
$script:waitSleeps=0;$message=''
try { Invoke-IW7QueuedResourceJob -Scope $waitScope -Owner 'not waited' -WaitForSlotSeconds 600 -Body { 'ran' } } catch { $message=$_.Exception.Message }
Assert ($message -like 'An unreserved or foreign laboratory is running*' -and $script:waitSleeps -eq 0) 'A refusal that is not a temporary holder is never waited for.'
$script:fakeProcesses=@($script:fakeProcesses | Where-Object PID -EQ $PID)
Remove-Item Function:\Start-Sleep
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

# The production client has no private fixture; classify only its explicit,
# loopback-only test invocation, never an ordinary Paris48 player.
$normalCapacityArgs='iw7.exe -cpMode -paris-capacity-64 -paris-capacity-production -paris-capacity-client-probe +set net_ip 127.0.0.1 +set net_port 27947'
if(!(Test-IW7NormalCapacityClientProbe $normalCapacityArgs)){throw 'Exact normal capacity client probe refused.'}
foreach($required in @('-cpMode','-paris-capacity-64','-paris-capacity-production','-paris-capacity-client-probe','+set net_ip 127.0.0.1','+set net_port 27947')){
    if(Test-IW7NormalCapacityClientProbe ($normalCapacityArgs.Replace($required,''))){throw 'Incomplete production probe classified as an admitted lab.'}
}
foreach($private in @('-dedicated','-paris-isolated-lab','-paris-debugger','-paris-server-test','-paris-server-client-test')){
    if(Test-IW7NormalCapacityClientProbe ($normalCapacityArgs+' '+$private)){throw 'Mixed production/private probe classified.'}
}
foreach($bad in @('27016','28000','279470')){
    if(Test-IW7NormalCapacityClientProbe ($normalCapacityArgs.Replace('27947',$bad))){throw 'Unreserved probe port classified.'}
}
if(Test-IW7NormalCapacityClientProbe ($normalCapacityArgs.Replace('127.0.0.1','0.0.0.0'))){throw 'Non-loopback probe classified.'}
