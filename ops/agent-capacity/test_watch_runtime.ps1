$ErrorActionPreference='Stop'
. "$PSScriptRoot/Watch-Runtime.Core.ps1"
function Reject([scriptblock]$Action){$rejected=$false;try{&$Action|Out-Null}catch{$rejected=$true};if(!$rejected){throw 'Adversarial fixture was accepted.'}}
$identity=[pscustomobject]@{PID=123;CreatedUtc='2026-10-07T01:00:00.1234567Z'};$nonce='0123456789abcdef'
$header=@{type='header';schema='iw7.capacity-watch/1';pid=123;creation_filetime=([datetimeoffset]$identity.CreatedUtc).UtcDateTime.ToFileTimeUtc();nonce=$nonce;qpc_frequency=10000000;b8_address=0x143C986B8;c0_address=0x143C986C0;max_events=64;duration_ms=10000;native_hash_requires_parent_manifest=$true;pristine=$false}
$event=@{type='event';seq=0;kind=0;tid=77;roles=3;tick_ms=100;qpc=1000;rip_after_write=0;slots=1;b8=0;c0=0;previous_b8=0;previous_c0=0;zero_seen=0;first_nonzero=0;context_hex=('00'*1232)}
$armed=@{type='armed';nonce=$nonce;tick_ms=101;threads=@(@{tid=77;creation_filetime=123;roles=3;canary_pass=$true});all_init_threads_covered=$false}
$complete=@{type='complete';cleanup_confirmed=$true;covered_roles=3;failures=0;canary_prerequisite_satisfied=$true;event_limit_reached=$false;all_init_threads_covered=$false;patch_ready=$false}
function Wire($Rows){(@($Rows|ForEach-Object{ConvertTo-Json $_ -Depth 8 -Compress}) -join "`n")+"`n"}
$wire=Wire @($header,$event,$armed,$complete)
$parsed=Read-IW7CapacityJournal $wire $identity $nonce
if(!$parsed.Armed -or !$parsed.Complete -or $parsed.Events.Count -ne 1 -or $parsed.WriterProven -or $parsed.PatchReady){throw 'Valid canary fixture result differs.'}
if(Read-IW7CapacityJournal ($wire.Split("`n")[0]) $identity $nonce){throw 'Partial header accepted.'}
if(!(Read-IW7CapacityJournal ($wire+'{"type":"event","seq":1') $identity $nonce).Complete){throw 'Trailing partial row affected complete records.'}
Reject {Read-IW7CapacityJournal ($wire.Replace('"pid":123','"pid":123,"PID":123')) $identity $nonce}
Reject {Read-IW7CapacityJournal ($wire.Replace('"pid":123','"pid":123,"pid":123')) $identity $nonce}
Reject {Read-IW7CapacityJournal ($wire.Replace('"pid":123','"pid":123,"extra":1')) $identity $nonce}
Reject {Read-IW7CapacityJournal ($wire.Replace('"pid":123','"pid":"123"')) $identity $nonce}
Reject {Read-IW7CapacityJournal ($wire.Replace('"seq":0','"seq":true')) $identity $nonce}
Reject {Read-IW7CapacityJournal ($wire.Replace('"seq":0','"seq":1')) $identity $nonce}
Reject {Read-IW7CapacityJournal $wire ([pscustomobject]@{PID=124;CreatedUtc=$identity.CreatedUtc}) $nonce}
Reject {Read-IW7CapacityJournal $wire $identity 'fedcba9876543210'}
Reject {Read-IW7CapacityJournal (Wire @($header,$armed,$complete)) $identity $nonce}
Reject {Read-IW7CapacityJournal (Wire @($header,$event,$armed,$armed)) $identity $nonce}
Reject {Read-IW7CapacityJournal ($wire.Replace('"roles":3','"roles":4')) $identity $nonce}
Reject {Read-IW7CapacityJournal ($wire.Replace('"patch_ready":false','"patch_ready":true')) $identity $nonce}
Reject {Read-IW7CapacityJournal ('x'*524289) $identity $nonce}
$overflow=@($header)
for($i=0;$i -lt 65;$i++){$e=$event.Clone();$e.seq=$i;$overflow+=$e}
Reject {Read-IW7CapacityJournal (Wire $overflow) $identity $nonce}
Reject {Read-IW7CapacityJournal (Wire @($header,$event,$armed,$complete,$event)) $identity $nonce}
$merged=$event.Clone();$merged.roles=1
if(!(Read-IW7CapacityJournal (Wire @($header,$merged,$armed,$complete)) $identity $nonce).Armed){throw 'Same TID scheduler role merge rejected.'}
if(!(Test-IW7CapacityInteger ([bigint]::Parse('18446744073709551615'))) -or (Test-IW7CapacityInteger 1.0) -or (Test-IW7CapacityInteger $true)){throw 'Integer boundaries differ.'}
$secret='a'*32;$packet=New-IW7CapacityRconPacket $secret 'map_restart'
if($packet.Length -ne 4+5+32+1+11 -or $packet[0] -ne 255 -or [Text.Encoding]::ASCII.GetString($packet,4,$packet.Length-4) -cne ('rcon '+$secret+' map_restart')){throw 'RCON bytes differ.'}
Reject {New-IW7CapacityRconPacket $secret "map_restart`nquit"}
Reject {New-IW7CapacityRconPacket $secret 'set sv_cheats 1'}
# Pure orchestrator: a canary acknowledgement is required before ONE restart.
$script:commands=@();$script:reads=0
function Assert-IW7CapacitySession($Session){}
function Wait-IW7CapacityVacant($Session,[int]$Seconds=30,[int]$TimeoutSeconds=90){$script:commands+=('vacant:'+ $Seconds)}
function Resolve-IW7BasePath($Root,$Relative){Join-Path $Root $Relative}
function Send-IW7CapacityRcon($Session,[string]$Command){$script:commands+=$Command}
function Read-IW7CapacityOwnedJournal($Session){$script:reads++;if($script:reads -eq 1){return [pscustomobject]@{Armed=$armed;Complete=$null;Events=@($event)}};$parsed}
$session=[pscustomobject]@{CandidateRoot=$env:TEMP;JournalRelative=('absent-'+[guid]::NewGuid()+'.jsonl');Nonce=$nonce}
$result=Invoke-IW7CapacityWatch $session
if(($script:commands -join '|') -cne ('vacant:30|paris_capacity_arm '+$nonce+'|vacant:0|map_restart|paris_capacity_stop') -or !$result.CanaryOnly -or $result.WriterProven){throw 'Lifecycle order/partial evidence differs.'}
$session|Add-Member NoteProperty Plan ([pscustomobject]@{PopulateAgents=$true})
$script:commands=@();$script:reads=0
$full=Invoke-IW7CapacityWatch $session
if($full.ReloadCommand -cne 'map cp_zmb' -or ($script:commands -join '|') -cne ('vacant:30|paris_capacity_arm '+$nonce+'|vacant:0|map cp_zmb|paris_capacity_stop')){throw 'Pool qualification did not select a full guarded map load.'}
Reject {New-IW7CapacityRconPacket $secret 'map cp_town'}
$script:terminated=$false
$handle=[pscustomobject]@{}
$handle|Add-Member ScriptMethod WaitForExit {$false}
$handle|Add-Member ScriptMethod Terminate {param($Code);$script:terminated=$true}
$session|Add-Member NoteProperty Handle $handle
function Wait-IW7CapacityVacant($Session,[int]$Seconds=30,[int]$TimeoutSeconds=90){throw 'Occupied fixture'}
Reject {Stop-IW7CapacityOwnedServer $session}
if($script:terminated){throw 'Refused vacancy triggered termination.'}
function Wait-IW7CapacityVacant($Session,[int]$Seconds=30,[int]$TimeoutSeconds=90){}
function Send-IW7CapacityRcon($Session,[string]$Command){throw 'Current occupied fixture'}
Reject {Stop-IW7CapacityOwnedServer $session}
if($script:terminated){throw 'Refused command triggered termination.'}
# Fatal recovery requires a retained matching artifact AND a fresh exact dialog.
$artifact=Join-Path $env:TEMP ('capacity-fatal-pure-'+[guid]::NewGuid()+'.bin')
[IO.File]::WriteAllText($artifact,'synthetic fatal artifact')
$hash=(Get-FileHash $artifact).Hash
$session|Add-Member NoteProperty Identity ([pscustomobject]@{PID=123;SHA256=$hash})
$fatal=[pscustomobject]@{ConfirmedFatal=$true;Artifact=$artifact;OriginalDumpName='synthetic.zip';Report=[pscustomobject]@{correlated=$true;expected_pid=123;image=[pscustomobject]@{sha256=$hash};dump=[pscustomobject]@{sha256=$hash}}}
function Read-IW7AgentFatalDialog($Identity){'synthetic dialog'}
function Test-IW7AgentFatalEvidence($Report,$Dialog,$OriginalDumpName){$false}
Reject {Stop-IW7CapacityConfirmedFatal $session $fatal}
if($script:terminated){throw 'Missing fresh fatal dialog allowed termination.'}
function Test-IW7AgentFatalEvidence($Report,$Dialog,$OriginalDumpName){$true}
$fatal.Report.expected_pid=124
Reject {Stop-IW7CapacityConfirmedFatal $session $fatal}
if($script:terminated){throw 'Foreign fatal PID allowed termination.'}
$fatal.Report.expected_pid=123
$handle|Add-Member -Force ScriptMethod WaitForExit {$true}
$handle|Add-Member ScriptMethod get_ExitCode {3758096385}
$fatalResult=Stop-IW7CapacityConfirmedFatal $session $fatal
if(!$script:terminated -or $fatalResult.Kind -cne 'confirmed-fatal-recovery'){throw 'Confirmed owned fatal recovery failed.'}
Remove-Item -LiteralPath $artifact
# Exact cleanup status model: file restoration does not imply lease release.
$lease=[pscustomobject]@{Token='synthetic'};$restored=$true;$leaseReleased=$false
function Exit-IW7ResourceLease {param($Token);throw 'Injected release failure'}
try{Exit-IW7ResourceLease -Token $lease.Token;$leaseReleased=$true}catch{}
if(!(Get-IW7CapacityLeaseRetained $lease $leaseReleased) -or !$restored){throw 'Release failure lost retained lease status.'}
if((Get-IW7CapacityLeaseRetained $null $false) -or (Get-IW7CapacityLeaseRetained $lease $true)){throw 'Released/absent lease status differs.'}
foreach($path in @('Watch-Runtime.Core.ps1','Watch-Server.ps1')){
    $errors=$null;$tokens=$null;[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $path),[ref]$tokens,[ref]$errors)|Out-Null
    if($errors){throw ($errors|Out-String)}
}
'Capacity watch parser/command/lifecycle pure tests PASS (no process or socket launched).'
