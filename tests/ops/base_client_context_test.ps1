$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. "$repo/ops/Base-Client.Core.ps1"
function Assert-Test($Value,[string]$Message) { if(!$Value){throw $Message} }
$plan=[pscustomobject]@{GameRoot='synthetic-unused-game'}
$server=[pscustomobject]@{PID=123;Stdout='synthetic-unused-log'}
$ordinary=New-IW7BaseClientContext $plan $server 'fixture-lease' 'synthetic-evidence' 17
Assert-Test ($null -eq $ordinary.PairOwnership -and $ordinary.PairRole -ceq 'A') 'Ordinary context lacks explicit null pair ownership/default role.'
Assert-Test ([object]::ReferenceEquals($ordinary.Plan,$plan) -and [object]::ReferenceEquals($ordinary.Server,$server) -and $ordinary.LogLength -eq 17) 'Constructor loses plan/server/log boundary.'
Assert-Test (!$ordinary.Protected -and !$ordinary.Failed -and !$ordinary.Handle -and !$ordinary.Transaction -and $ordinary.StartedTick -gt 0) 'Initial lifecycle state is not safe.'
# Exercise the actual single-client dispatch under StrictMode: an unstarted
# context must report the owned-client boundary, not a missing pair property.
$failure=$null
try { Update-IW7BaseClient $ordinary | Out-Null } catch { $failure=$_.Exception.Message }
Assert-Test ($failure -ceq 'Owned client exited.' -and $ordinary.Failed) 'Ordinary update fails before its actual owned-client check.'
$script:VacancyCalls=0
function Assert-IW7BaseVacant([string]$GameRoot,[int]$OwnedPid=0,$PairOwnership=$null,$CurrentContext=$null) {
    if($GameRoot -cne 'synthetic-unused-game' -or $OwnedPid -ne 0 -or $null -ne $PairOwnership -or $null -eq $CurrentContext){throw 'Unexpected ordinary cleanup dispatch.'}
    $script:VacancyCalls++
}
Stop-IW7BaseClient $ordinary
Assert-Test ($script:VacancyCalls -eq 1 -and !$ordinary.Handle) 'Prelaunch ordinary cleanup cannot complete its vacancy boundary.'
$ownership=[pscustomobject]@{Marker='synthetic-pair'}
$paired=New-IW7BaseClientContext $plan $server 'fixture-pair-lease' 'synthetic-pair-evidence' 23 $ownership 'B'
Assert-Test ([object]::ReferenceEquals($paired.PairOwnership,$ownership) -and $paired.PairRole -ceq 'B') 'Pair ownership reference or second-client role was lost.'
$script:PairCalls=0
function Update-IW7AgentPairClient($Context) {
    Assert-Test ([object]::ReferenceEquals($Context.PairOwnership,$ownership) -and $Context.PairRole -ceq 'B') 'Pair update receives a changed ownership contract.'
    $script:PairCalls++
    [pscustomobject]@{Protected=$false;PairWitness='delegated'}
}
$sample=Update-IW7BaseClient $paired
Assert-Test ($sample.PairWitness -ceq 'delegated' -and $script:PairCalls -eq 1 -and !$paired.Failed) 'Pair lifecycle bypassed its coordinator.'
$invalidRoleRefused=$false
try { New-IW7BaseClientContext $plan $server 'fixture-lease' 'synthetic-evidence' 0 $ownership 'C' | Out-Null } catch { $invalidRoleRefused=$true }
Assert-Test $invalidRoleRefused 'Unknown pair role accepted.'
Write-Output 'Base client context tests passed: 8 (StrictMode ordinary update/prelaunch cleanup and pair dispatch).'
