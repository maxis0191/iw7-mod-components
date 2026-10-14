param(
    [ValidateSet('Plan','Run')][string]$Action='Plan',
    [Parameter(Mandatory)][double[]]$Anchor,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string]$Token,
    [string]$HelperRoot,[string]$HelperReceiptSHA256,[string]$SourceReceiptSHA256,
    $Session,$ServerHandle,$ServerIdentity,
    [switch]$Capture
)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/Collision-Player.Core.ps1"
$plan=New-IW7CollisionPlayerPlan $Anchor $Token
$plan|Add-Member FixtureSHA256 (Get-FileHash -LiteralPath "$PSScriptRoot/../tests/fixtures/collision_player_contact.gsc").Hash
if($Action -ceq 'Plan'){$plan|ConvertTo-Json -Depth 6;return}
# This is a measurement operation inside the caller's original protected
# session. The reviewed caller alone owns preparation/launch/cleanup/restoration.
# Never instantiate a process, add/release a lease or overwrite a game file here.
if(!$Session -or !$ServerHandle -or !$ServerIdentity -or !$HelperRoot -or
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
$steps=@(@{id='settle-controls';action='wait';duration_ms=4000},
    @{id='present-contact';action='assert_log';scope='server';contains="[Collision player] READY_F1 token=$Token";timeout_ms=5000},
    @{id='ordinary-walk';action='hold';button='forward';duration_ms=300},
    @{id='released-stable';action='wait';duration_ms=750})
if($Capture){$steps+=@{id='standing-frame';action='capture'}}
$steps+=@(@{id='request-removal';action='press';button='use'},
    @{id='removed-fall';action='assert_log';scope='server';contains="[Collision player] DONE token=$Token";timeout_ms=5000})
$scenario=Write-CollisionInputScenario 'collision-contact' $steps
$armTick=[Environment]::TickCount64
$null=Send-IW7CollisionProbeCommand $ServerHandle $ServerIdentity 'set paris_collision_probe_arm 1'
$input=Invoke-IW7AgentScenario -Session $Session -ScenarioPath $scenario
$null=Update-IW7BaseClient $Session
$text=Read-IW7BaseLog $ServerIdentity.Stdout
$stamp=Get-IW7CollisionPlayerOne $text ('(?m)^\[Collision player\] SAMPLE token='+$Token+' phase=F0 sample=1; server_pid='+$ServerIdentity.PID+'; client_nonce='+$nonce+'; server_generation=([a-f0-9]{32}); slot=0; native_tick_ms=\d+; protected=1;[^\r\n]*[\t ]*\r?$')
$measurement=Read-IW7CollisionPlayerResult -Text $text -Plan $plan -ServerId $ServerIdentity.PID -ClientNonce $nonce -Generation $stamp.Groups[1].Value -NotBeforeTick $armTick -NowTick ([Environment]::TickCount64)
if(!$measurement.Complete){throw 'Player measurements incomplete.'}
$result=[pscustomobject]@{Schema='iw7.collision-player-measurement/1';MeasurementPassed=$true;Measurements=$measurement;Input=$input;
    LifecycleClosed=$false;LeaseReleased=$false;OriginalHostExitObserved=$false;OwnerAccepted=$false;MainDeployed=$false;
    Meaning='Measurement only. Original caller must close client/server, restore, release, and observe actual host exit separately.'}
$path=Join-Path $Session.OutputRoot ('collision-player-'+$Token+'.local.json')
$writer=[IO.StreamWriter]::new([IO.File]::Open($path,'CreateNew','Write','Read'),[Text.UTF8Encoding]::new($false))
try{$writer.Write(($result|ConvertTo-Json -Depth 9))}finally{$writer.Dispose()}
$result
