# Synthetic reservation inputs, real scheduler read/lock and BaseLease assertion.
# The caller intentionally stops before native protection, process I/O or a game.
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Add-Type -Path "$repo/ops/native/LabProcess.cs"
. "$repo/ops/Base-Client.Core.ps1"
. "$repo/ops/Original-RigConsole.Core.ps1"
$root=Join-Path $repo ('runtime/rig-console-caller-test-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root)|Out-Null
# Only the test's resource directory is redirected; production has no test hook.
function Get-IW7ResourceRoot { $script:root }
function Update-IW7BaseClient { throw 'TEST_STOP_BEFORE_NATIVE_PROTECTION' }
$token='0123456789abcdef0123456789abcdef'
$server=[pscustomobject]@{PID=17;Image=(Join-Path $root 'dedicated/test.exe');CreatedUtc=[datetime]::UtcNow.ToString('o')}
$plan=[pscustomobject]@{OriginalRigConsole=$true;Image=(Join-Path $root 'client/test.exe');GameRoot=(Join-Path $root 'client');ServerPort=27116;RunPlan=[pscustomobject]@{PhysicalBytes=1L;CommitBytes=1L}}
$session=[pscustomobject]@{Plan=$plan;LeaseToken=$token;Server=$server;Identity=[pscustomobject]@{PID=18};Transaction=[pscustomobject]@{FixtureOnly=$true};Failed=$false;Protected=$false}
$target=[pscustomobject]@{Id=17;OriginalRigConsoleEnabled=$true}
$lease=[pscustomobject]@{Token=$token;Kind='Runtime';Phase='Running';Scope=(Join-Path $root 'dedicated');OwnerIdentity=[pscustomobject]@{PID=$PID};BaseClientImage=$plan.Image;PhysicalBytes=1L;CommitBytes=1L;Processes=@($server)}
function Save-Inputs($leases){[pscustomobject]@{Version=1;Leases=@($leases)}|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $root 'leases.json') -Encoding utf8NoBOM}
function Call-Message { try{Send-IW7OriginalRigConsoleCommand -Session $session -TargetHandle $target -TargetIdentity $server -Command 'listassetpool 8 paris_doom_skin_two_bone_first_a'|Out-Null;return 'NO_REFUSAL'}catch{return $_.Exception.Message} }
function Check($value,[string]$message){if(!$value){throw $message};$script:count++}
$count=0
$ErrorActionPreference='Continue'
Save-Inputs @($lease)
Check ((Call-Message) -ceq 'TEST_STOP_BEFORE_NATIVE_PROTECTION') 'Valid reservation did not pass the real existing lease API.'
Save-Inputs @()
Check ((Call-Message) -ceq 'Unique current running runtime reservation required.') 'Missing current reservation did not refuse before protection.'
Save-Inputs @($lease,$lease)
Check ((Call-Message) -ceq 'Unique current running runtime reservation required.') 'Duplicate reservation was accepted.'
$lease.Processes=@([pscustomobject]@{PID=$server.PID;Image=$server.Image;CreatedUtc=([datetime]::UtcNow.AddDays(-1)).ToString('o')})
Save-Inputs @($lease)
Check ((Call-Message) -ceq 'Registered server identity mismatch.') 'Stale reservation identity was accepted.'
$lease.Processes=@($server);$lease.Phase='Pending'
Save-Inputs @($lease)
Check ((Call-Message) -ceq 'Unique current running runtime reservation required.') 'Pending reservation was accepted for command dispatch.'
"$count caller lease checks passed through actual scheduler/BaseLease APIs; stopped before native/game/protection/I/O. Test-only state: $root"
