param([string]$GscToolPath)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
foreach($file in @('ops/Collision-Player.Core.ps1','ops/Invoke-CollisionPlayerContact.ps1')){
    $tokens=$null;$errors=$null;$null=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root $file),[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'Player operation PowerShell grammar failed.'}
}
$effects=[Collections.Generic.List[string]]::new()
function Enter-IW7ResourceLease {$effects.Add('lease');throw 'No reservation in this source test.'}
function Start-IW7BaseClient {$effects.Add('client');throw 'No client in this source test.'}
function Send-IW7CollisionProbeCommand {$effects.Add('engine');throw 'No engine in this source test.'}
function Get-CimInstance {$effects.Add('process');throw 'No process inspection in default Plan.'}
$token='1234567890abcdef1234567890abcdef'
$plan=& (Join-Path $root 'ops/Invoke-CollisionPlayerContact.ps1') -Anchor @(10,20,30) -Token $token|ConvertFrom-Json
if($plan.PlannedClients -ne 1 -or $plan.ClientCollider -or $plan.ClearanceQualified -or $plan.OwnerAccepted -or
    $plan.Minimum[2] -ne 126 -or $plan.Maximum[2] -ne 142 -or $plan.Start[2] -ne 238){throw 'Source Plan overclaims or changes reviewed geometry.'}
$refused=$false
try{& (Join-Path $root 'ops/Invoke-CollisionPlayerContact.ps1') -Action Run -Anchor @(10,20,30) -Token $token}catch{
    if($_.Exception.Message -notmatch 'retained original server/client session'){throw};$refused=$true
}
if(!$refused -or $effects.Count){throw 'Missing-owned-context Run or default Plan performed a live effect.'}
. (Join-Path $root 'ops/Collision-Player.Core.ps1')
$created=[datetime]::Parse('2026-10-14T13:00:00Z').ToUniversalTime();$filetime=$created.ToFileTimeUtc()
$server=[pscustomobject]@{PID=42;Image='C:\candidate\native.exe';CreatedUtc=$created.ToString('o');CreationFileTime=$filetime;SHA256='5F1BF0569FF109A46CF23997E2A2EDF551FE6FD525B1F2B341BC8BEB91287006'}
$kernel=[pscustomobject]@{PID=42;Image=$server.Image;CreationFileTime=$filetime}
$hostRecord=[pscustomobject]@{PID=43;Image='C:\tools\pwsh.exe';CreatedUtc=$created.ToString('o')}
$session=[pscustomobject]@{PairOwnership=$null;Failed=$false;Plan=[pscustomobject]@{ServerPort=27116};Server=$server;LeaseToken=$token}
$lease=[pscustomobject]@{Kind='Runtime';Token=$token;OwnerIdentity=$hostRecord}
Assert-IW7CollisionPlayerOwnership $session $server $kernel $lease $hostRecord 43
$rejected=0
foreach($change in @('reused-server','reused-host','foreign-owner','wrong-lease','main-port','failed-session')){
    $s=$session|ConvertTo-Json -Depth 6|ConvertFrom-Json;$i=$server.PSObject.Copy();$k=$kernel.PSObject.Copy();$l=$lease|ConvertTo-Json -Depth 6|ConvertFrom-Json;$h=$hostRecord.PSObject.Copy()
    switch($change){
        'reused-server' {$k.CreationFileTime++}
        'reused-host' {$h.CreatedUtc=$created.AddSeconds(1).ToString('o')}
        'foreign-owner' {$l.OwnerIdentity.PID=99}
        'wrong-lease' {$l.Token='cccccccccccccccccccccccccccccccc'}
        'main-port' {$s.Plan.ServerPort=27016}
        'failed-session' {$s.Failed=$true}
    }
    try{Assert-IW7CollisionPlayerOwnership $s $i $k $l $h 43}catch{$rejected++;continue};throw 'Ambiguous/reused ownership accepted.'
}
if($GscToolPath){
    if((Get-FileHash -LiteralPath $GscToolPath).Hash -cne '1ADFD67414A9B886CBAD57EE0378F622EED485BCEF7711322AEE478E298FADCB'){throw 'Official pinned GSC parser differs.'}
    $output=@(& $GscToolPath -m parse -g iw7 -s pc -y (Join-Path $root 'tests/fixtures/collision_player_contact.gsc') 2>&1)
    if($LASTEXITCODE -ne 0 -or ($output -join "`n") -match '\[ERROR\]|failed|exception' -or
        @($output|Where-Object{"$_" -match '^parsed iw7/collision_player_contact.gsc$'}).Count -ne 1){throw 'GSC source grammar failed.'}
    Write-Output 'PASS pinned GSC grammar; Aurora/runtime compilation remains untested.'
}
Write-Output "PASS collision player source grammar, default Plan, missing-original and $rejected identity refusals; live effects=0."
