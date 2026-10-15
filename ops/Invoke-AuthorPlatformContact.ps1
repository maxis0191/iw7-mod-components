param(
    [ValidateSet('Plan','Run')][string]$Action='Plan',
    [ValidateSet('Contact','DisplayOnly',IgnoreCase=$false)][string]$Phase='Contact',
    [double[]]$Anchor,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string]$Token,
    [string]$HelperRoot,[string]$HelperReceiptSHA256,[string]$SourceReceiptSHA256,
    [string]$SDKSourceRoot,[string]$SDKSourceReceiptSHA256,
    $Session,$ServerHandle,$ServerIdentity,
    [switch]$Capture
)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/Author-Platform.Core.ps1"
$anchorProvided=$PSBoundParameters.ContainsKey('Anchor')
$fixtureHash=(Get-FileHash -LiteralPath "$PSScriptRoot/../tests/fixtures/author_platform_contact.gsc").Hash
if($Action -ceq 'Plan'){
    if($anchorProvided){$plan=New-IW7AuthorPlatformPlan $Anchor $Token $Phase;$plan|Add-Member PreviewOnly $true}
    else{$plan=[pscustomobject]@{Schema='iw7.author-platform-plan/1';Token=$Token;Anchor=$null;CoordinatesPending=$true;AnchorSelection='Fresh protected stock-spawn pose after actual retail readiness';PlannedClients=1;ClearanceQualified=$false;ClientCollider=$false;OwnerAccepted=$false;Config="set paris_collision_player_test 1`nset paris_collision_player_anchor_current 1`nset paris_author_platform_contact 1`nset sdk_author_platform_enable 1`nset fs_game mods/sdk_author_platform`nset paris_collision_probe_arm 0`nset paris_collision_probe_token `"$Token`"`n"}}
    $plan|Add-Member FixtureSHA256 $fixtureHash
    if(!$anchorProvided){
        $plan|Add-Member SDKContract (Get-IW7AuthorPlatformSDKContract)
        $plan|Add-Member Phase $Phase
        $plan.Config+="set paris_author_platform_display_only $(if($Phase -ceq 'DisplayOnly'){1}else{0})`n"
    }
    $plan|ConvertTo-Json -Depth 6;return
}
if($anchorProvided){throw 'Run selects actual frozen stock pose from native-stamped readiness; explicit coordinates are preview only.'}
# This is a measurement operation inside the caller's original protected
# session. The reviewed caller alone owns preparation/launch/cleanup/restoration.
# Never instantiate a process, add/release a lease or overwrite a game file here.
if(!$Session -or !$ServerHandle -or !$ServerIdentity -or !$HelperRoot -or !$SDKSourceRoot -or
    $SDKSourceReceiptSHA256 -cnotmatch '^[a-fA-F0-9]{64}$' -or
    $HelperReceiptSHA256 -cnotmatch '^[a-fA-F0-9]{64}$' -or $SourceReceiptSHA256 -cnotmatch '^[a-fA-F0-9]{64}$'){throw 'Run requires the retained original server/client session and sealed helpers.'}
if(!(Test-Path -LiteralPath "$PSScriptRoot/../source-workspace.json")){throw 'Run only the separately reviewed prepared source product.'}
. "$PSScriptRoot/Base-Client.Core.ps1"
function Assert-CollisionPlayerSource([string]$Root,[string]$ExpectedReceipt) {
    $receipt=Resolve-IW7BasePath $Root 'source-workspace.json'
    if((Get-Item -LiteralPath $receipt).Length -gt 1MB -or ($ExpectedReceipt -and (Get-FileHash -LiteralPath $receipt).Hash -ine $ExpectedReceipt)){throw 'Bounded source receipt changed.'}
    $d=Get-Content -LiteralPath $receipt -Raw|ConvertFrom-Json
    if($d.schema -cne 'iw7.source-workspace/1' -or !$d.files -or $d.files.Count -gt 2000){throw 'Prepared source receipt required.'}
    $paths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($entry in $d.files){
        if(!$paths.Add($entry.path) -or $entry.sha256 -cnotmatch '^[a-fA-F0-9]{64}$'){throw 'Ambiguous source entry.'}
        $path=Resolve-IW7BasePath $Root $entry.path
        if((Get-Item -LiteralPath $path).Length -ne $entry.bytes -or (Get-FileHash -LiteralPath $path).Hash -ine $entry.sha256){throw 'Frozen source input changed.'}
    }
    $d
}
$selfReceipt=Assert-CollisionPlayerSource (Split-Path $PSScriptRoot -Parent) $SourceReceiptSHA256
$helperReceipt=Assert-CollisionPlayerSource $HelperRoot $HelperReceiptSHA256
$sdkReceipt=Assert-CollisionPlayerSource $SDKSourceRoot $SDKSourceReceiptSHA256
Assert-IW7AuthorPlatformSDKSource $sdkReceipt $SDKSourceRoot
if($selfReceipt.product -cne 'iw7-mod-components' -or $helperReceipt.product -cne 'iw7-paris-server'){throw 'Explicit native-operation/server-helper products required.'}
foreach($relative in @('Base-Client.Core.ps1','Agent-Scenario.Core.ps1','Lab-Lifecycle.ps1','Resource-Scheduler.Core.ps1')){. (Join-Path $HelperRoot ('ops/'+$relative))}
. "$PSScriptRoot/Collision-Probe.Core.ps1"
if($ServerHandle.Id -ne $ServerIdentity.PID -or !$ServerHandle.CollisionProbeConsoleEnabled -or $ServerHandle.HasExited){throw 'Retained original dedicated collision console required.'}
$lease=@((Get-IW7ResourceStatus).Leases|Where-Object Token -CEQ $Session.LeaseToken)
if($lease.Count -ne 1 -or $lease[0].OwnerIdentity.PID -ne $PID){throw 'Retained original reservation owner must call this operation.'}
$originalHost=@(Get-IW7ResourceProcesses|Where-Object PID -EQ $PID)
if($originalHost.Count -ne 1 -or !(Test-IW7ResourceIdentity $lease[0].OwnerIdentity $originalHost[0])){throw 'Original reservation host creation/image changed.'}
$kernel=$ServerHandle.ReadIdentity()
Assert-IW7CollisionPlayerOwnership $Session $ServerIdentity $kernel $lease[0] $originalHost[0] $PID
Assert-IW7BaseLease $lease[0] $Session.Plan $ServerIdentity
$null=Update-IW7BaseClient $Session
if(!$Session.Protected){throw 'Fresh engine-protected playable client required.'}
function Write-CollisionInputScenario([string]$Name,$Steps) {
    $path=Join-Path $Session.OutputRoot ($Name+'-'+[guid]::NewGuid().ToString('N')+'.json')
    $value=[ordered]@{schema='iw7.agent-scenario/1';name=$Name;steps=@($Steps)}|ConvertTo-Json -Depth 6
    $writer=[IO.StreamWriter]::new([IO.File]::Open($path,'CreateNew','Write','Read'),[Text.UTF8Encoding]::new($false))
    try{$writer.Write($value)}finally{$writer.Dispose()}
    $null=Read-IW7AgentScenario $path
    $path
}
# Bind the existing native nonce/protection handshake without moving the player.
$warmup=Write-CollisionInputScenario 'collision-bind' @(@{id='bind';action='wait';duration_ms=1000})
$null=Invoke-IW7AgentScenario -Session $Session -ScenarioPath $warmup
$wire=Read-IW7AgentWire (Resolve-IW7BasePath $Session.Plan.GameRoot 'iw7-mod/paris-agent.session') -RequireTerminator
if($wire -cnotmatch ('^'+$Session.Identity.PID+' ([a-f0-9]{32})$')){throw 'Actual native client nonce absent.'};$nonce=$Matches[1]
# Retail intro/stock-spawn scripts must finish their own position/control work
# before any placement. This passive wait is outside the measured/arm budget.
$readyDeadline=[Environment]::TickCount64+180000;$generation=$null
do{
    $null=Update-IW7BaseClient $Session
    $readyText=Read-IW7BaseLog $ServerIdentity.Stdout
    $ready=if($Phase -ceq 'DisplayOnly'){
        Read-IW7AuthorDisplayReady $readyText $Token $ServerIdentity.PID $nonce $Session.StartedTick ([Environment]::TickCount64)
    }else{Read-IW7CollisionPlayerReady $readyText $Token $ServerIdentity.PID $nonce $Session.StartedTick ([Environment]::TickCount64)}
    if($ready.Ready){$generation=$ready.Generation;$firstReady=$ready;break}
    if([Environment]::TickCount64 -ge $readyDeadline){throw 'Fresh playable/retail-intro readiness unavailable; no placement or collision arm.'}
    Start-Sleep -Milliseconds 100
}while($true)
$plan=New-IW7AuthorPlatformPlan $firstReady.Anchor $Token $Phase
$plan|Add-Member FixtureSHA256 $fixtureHash
$plan|Add-Member AnchorSelection 'Actual frozen protected stock-spawn pose'
$plan|Add-Member ReadinessTick $firstReady.Tick
$planPath=Join-Path $Session.OutputRoot ('author-platform-anchor-'+$Token+'.local.json')
$writer=[IO.StreamWriter]::new([IO.File]::Open($planPath,'CreateNew','Write','Read'),[Text.UTF8Encoding]::new($false))
try{$writer.Write(($plan|ConvertTo-Json -Depth 6))}finally{$writer.Dispose()}
if($Phase -ceq 'DisplayOnly'){
    # Capture only. Native input arm/abort belongs to the existing capture API;
    # the collision arm remains zero. No contact command, placement or Use.
    $before=Read-IW7AuthorDisplayReady (Read-IW7BaseLog $ServerIdentity.Stdout) $Token $ServerIdentity.PID $nonce $Session.StartedTick ([Environment]::TickCount64)
    Assert-IW7CollisionPlayerFrozenReady $firstReady $before
    $scenario=Write-CollisionInputScenario 'author-platform-display' @(@{id='display-original-frame';action='capture'})
    $captureStarted=[Environment]::TickCount64
    $displayInput=Invoke-IW7AgentScenario -Session $Session -ScenarioPath $scenario
    $captureCompleted=[Environment]::TickCount64
    $displayDeadline=$captureCompleted+1000
    do{
        $null=Update-IW7BaseClient $Session
        $after=Read-IW7AuthorDisplayReady (Read-IW7BaseLog $ServerIdentity.Stdout) $Token $ServerIdentity.PID $nonce $captureCompleted ([Environment]::TickCount64)
        if($after.Ready){break}
        if([Environment]::TickCount64 -ge $displayDeadline){throw 'Fresh same-visual display observation unavailable after capture.'}
        Start-Sleep -Milliseconds 50
    }while($true)
    $evidence=[IO.Path]::GetFullPath($displayInput.Evidence)
    if([IO.Path]::GetExtension($evidence) -cne '.jsonl' -or
        !$evidence.StartsWith([IO.Path]::GetFullPath($Session.OutputRoot)+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or
        (Get-Item -LiteralPath $evidence).Length -gt 1MB){throw 'Original capture scenario evidence must remain bounded inside the session output.'}
    $rows=@(Get-Content -LiteralPath $evidence|ForEach-Object {ConvertFrom-Json $_})
    $result=New-IW7AuthorDisplayResult $before $after $displayInput $rows $captureStarted $captureCompleted
    if(![IO.Path]::GetFullPath($result.OriginalCapture.path).StartsWith([IO.Path]::GetFullPath($Session.OutputRoot)+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){
        throw 'Original frame must remain inside the retained session output.'
    }
    $path=Join-Path $Session.OutputRoot ('author-platform-display-'+$Token+'.local.json')
    $writer=[IO.StreamWriter]::new([IO.File]::Open($path,'CreateNew','Write','Read'),[Text.UTF8Encoding]::new($false))
    try{$writer.Write(($result|ConvertTo-Json -Depth 9))}finally{$writer.Dispose()}
    $result;return
}
$steps=@(@{id='settle-controls';action='wait';duration_ms=4000},
    @{id='present-contact';action='assert_log';scope='server';contains="[Collision player] READY_F1 token=$Token";timeout_ms=5000},
    @{id='ordinary-walk';action='hold';button='forward';duration_ms=300},
    @{id='released-stable';action='wait';duration_ms=750})
if($Capture){$steps+=@{id='standing-frame';action='capture'}}
$steps+=@(@{id='sdk-use-armed';action='assert_log';scope='server';contains="[Author contact] USE_ARMED token=$Token";timeout_ms=1000},
    @{id='retail-use';action='press';button='use'},
    @{id='removed-fall';action='assert_log';scope='server';contains="[Collision player] DONE token=$Token";timeout_ms=5000})
$scenario=Write-CollisionInputScenario 'author-platform-contact' $steps
$currentReady=Read-IW7CollisionPlayerReady (Read-IW7BaseLog $ServerIdentity.Stdout) $Token $ServerIdentity.PID $nonce $Session.StartedTick ([Environment]::TickCount64)
Assert-IW7CollisionPlayerFrozenReady $firstReady $currentReady
$armTick=[Environment]::TickCount64
$null=Send-IW7CollisionProbeCommand $ServerHandle $ServerIdentity 'set paris_collision_probe_arm 1'
$input=Invoke-IW7AgentScenario -Session $Session -ScenarioPath $scenario
$null=Update-IW7BaseClient $Session
$text=Read-IW7BaseLog $ServerIdentity.Stdout
$measurement=Read-IW7AuthorPlatformResult -Text $text -Plan $plan -ServerId $ServerIdentity.PID -ClientNonce $nonce -Generation $generation -NotBeforeTick $armTick -NowTick ([Environment]::TickCount64)
if(!$measurement.Complete){throw 'Player measurements incomplete.'}
$result=[pscustomobject]@{Schema='iw7.author-platform-measurement/1';MeasurementPassed=$true;Measurements=$measurement;Input=$input;
    LifecycleClosed=$false;LeaseReleased=$false;OriginalHostExitObserved=$false;OwnerAccepted=$false;MainDeployed=$false;
    Meaning='Measurement only. Original caller must close client/server, restore, release, and observe actual host exit separately.'}
$path=Join-Path $Session.OutputRoot ('author-platform-'+$Token+'.local.json')
$writer=[IO.StreamWriter]::new([IO.File]::Open($path,'CreateNew','Write','Read'),[Text.UTF8Encoding]::new($false))
try{$writer.Write(($result|ConvertTo-Json -Depth 9))}finally{$writer.Dispose()}
$result
