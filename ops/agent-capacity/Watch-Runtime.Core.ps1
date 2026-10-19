# No launch, staging, socket or reservation on import.
. "$PSScriptRoot/../Agent-Scenario.Core.ps1"
function Get-IW7CapacityLeaseRetained($Lease,[bool]$LeaseReleased) {
    [bool]$Lease -and !$LeaseReleased
}
function New-IW7CapacityRconPacket([string]$Secret,[string]$Command) {
    if($Secret -cnotmatch '^[A-Za-z0-9_-]{32,64}$' -or
       ($Command -cnotmatch '^paris_capacity_arm [A-Za-z0-9_]{16,64}$' -and $Command -cnotin @('paris_capacity_stop','map_restart','map cp_zmb','quit','set paris_capacity_pool_validate 1'))) { throw 'Fixed capacity command/secret contract required.' }
    # Pin77 network::send defaults to space separator; rcon callback splits secret.
    ,[byte[]]([byte[]](255,255,255,255)+[Text.Encoding]::ASCII.GetBytes('rcon '+$Secret+' '+$Command))
}
function Assert-IW7CapacitySession($Session) {
    if(!$Session -or $Session.ServerPort -lt 27100 -or $Session.ServerPort -gt 27999 -or
       !$Session.Plan.Debugger -or $Session.Plan.PlannedClients -notin @(0,1) -or $Session.Plan.StockCopied -or $Session.Plan.MainDeployed) { throw 'Owned private debugger plan required.' }
    if($Session.Plan.PlannedClients -eq 1 -and (!$Session.Plan.ClientImage -or
       ($Session.Plan.AgentCapacity -eq 64 -and !$Session.Plan.PopulateAgents) -or
       ($Session.Plan.AgentCapacity -eq 24 -and (!$Session.Plan.SkipReload -or $Session.Plan.PopulateAgents)))){throw 'Declared matching construction client or unchanged startup baseline required.'}
    Assert-IW7BaseIdentity $Session.Identity
    if($Session.Handle.HasExited){throw 'Owned dedicated exited.'}
    $leases=@((Get-IW7ResourceStatus).Leases|Where-Object Token -CEQ $Session.LeaseToken)
    $root=[IO.Path]::GetFullPath($Session.CandidateRoot).TrimEnd('\','/')
    if($leases.Count -ne 1 -or $leases[0].Kind -cne 'Runtime' -or $leases[0].Scope -ine $root -or
       $leases[0].PhysicalBytes -lt 6GB -or $leases[0].CommitBytes -lt 7GB -or
       !$Session.Identity.Image.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)) {throw 'Exact candidate 6/7GiB lease required.'}
    $registered=@($leases[0].Processes|Where-Object PID -EQ $Session.Identity.PID)
    if($registered.Count -ne 1 -or $registered[0].Image -ine $Session.Identity.Image -or
       [math]::Abs((([datetimeoffset]$registered[0].CreatedUtc)-([datetimeoffset]$Session.Identity.CreatedUtc)).TotalMilliseconds) -gt 1){throw 'Exact registered server identity required.'}
    $process=Get-CimInstance Win32_Process -Filter "ProcessId=$($Session.Identity.PID)" -OperationTimeoutSec 5
    if(!$process -or $process.ExecutablePath -ine $Session.Identity.Image){throw 'Server image differs.'}
    foreach($flag in @('-dedicated','-paris-isolated-lab','-paris-server-test','-paris-debugger','-paris-capacity-watch')){
        if($process.CommandLine -notmatch ('(?:^|\s)'+[regex]::Escape($flag)+'(?:\s|$)')){throw 'Capacity opt-in flags absent.'}
    }
}
function Send-IW7CapacityRcon($Session,[string]$Command) {
    Assert-IW7CapacitySession $Session
    $packet=New-IW7CapacityRconPacket $Session.Secret $Command
    if($Command -in @('quit','map_restart','map cp_zmb') -or $Command.StartsWith('paris_capacity_arm ',[StringComparison]::Ordinal)) {
        if(!$Session.VacancyProof -or $Session.VacancyProof.Seconds -lt 30 -or
           ([datetime]::UtcNow- $Session.VacancyProof.ObservedUtc).TotalSeconds -gt 3){throw 'Fresh continuous 30-second vacancy proof required.'}
        $info=& "$PSScriptRoot/../Get-ServerInfo.ps1" -Address '127.0.0.1' -Port $Session.ServerPort
        if($info.clients -cne '0' -or $info.sv_running -cne '1' -or $info.mapname -cne 'cp_zmb'){throw 'Current vacancy differs; command refused.'}
    }
    $udp=[Net.Sockets.UdpClient]::new()
    try{$udp.Connect('127.0.0.1',$Session.ServerPort);$null=$udp.Send($packet,$packet.Length)}finally{$udp.Dispose()}
    # Transmission is not command acknowledgement. Never return/log the secret.
}
function Read-IW7CapacityServerInfo($Session) {
    & "$PSScriptRoot/../Get-ServerInfo.ps1" -Address '127.0.0.1' -Port $Session.ServerPort
}
function Wait-IW7CapacityClientDeparture($Session) {
    # Called only after exact fatal-client closure and successful restoration.
    # A residual connection grants no mutation: wait for actual zero, then the
    # ordinary stop still requires its own fresh continuous 30-second proof.
    $deadline=[datetime]::UtcNow.AddSeconds(60)
    do {
        Assert-IW7CapacitySession $Session
        $info=Read-IW7CapacityServerInfo $Session
        if($info.sv_running -cne '1' -or $info.mapname -cne 'cp_zmb' -or $info.clients -cnotin @('0','1')){throw 'Private post-fatal roster differs; preserve it.'}
        if($info.clients -ceq '0'){return}
        Start-Sleep -Milliseconds 1000
    }while([datetime]::UtcNow -lt $deadline)
    throw 'Fatal client departure not witnessed; preserve server and reservation.'
}
function Wait-IW7CapacityVacant($Session,[int]$Seconds=30,[int]$TimeoutSeconds=90) {
    $since=$null;$deadline=[datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        Assert-IW7CapacitySession $Session
        $info=& "$PSScriptRoot/../Get-ServerInfo.ps1" -Address '127.0.0.1' -Port $Session.ServerPort
        if($info.clients -cne '0' -or $info.sv_running -cne '1' -or $info.mapname -cne 'cp_zmb'){throw 'Candidate occupied or wrong map; preserve it.'}
        if(!$since){$since=[datetime]::UtcNow}
        if(([datetime]::UtcNow-$since).TotalSeconds -ge $Seconds){
            $prior=$Session.PSObject.Properties['VacancyProof']
            $proven=if($Seconds -ge 30){$Seconds}elseif($prior){$prior.Value.Seconds}else{0}
            $Session|Add-Member -Force NoteProperty VacancyProof ([pscustomobject]@{Seconds=$proven;ObservedUtc=[datetime]::UtcNow})
            return
        }
        Start-Sleep -Milliseconds 1000
    }while([datetime]::UtcNow -lt $deadline)
    throw 'Continuous real vacant evidence not established.'
}
function Test-IW7CapacityInteger($Value,[bigint]$Minimum=0,[bigint]$Maximum=([bigint]::Parse('18446744073709551615'))) {
    ($Value -is [int] -or $Value -is [long] -or $Value -is [bigint]) -and [bigint]$Value -ge $Minimum -and [bigint]$Value -le $Maximum
}
function Read-IW7CapacityJournal([string]$Text,$Identity,[string]$Nonce) {
    if([Text.Encoding]::UTF8.GetByteCount($Text) -gt 512KB -or $Nonce -cnotmatch '^[A-Za-z0-9_]{16,64}$'){throw 'Bounded fresh journal contract required.'}
    # Native truncation/partial writes do not become a numeric/JSON acknowledgement.
    $end=$Text.LastIndexOf("`n");if($end -lt 0){return $null}
    $rows=@($Text.Substring(0,$end).Split("`n")|Where-Object Length -GT 0|ForEach-Object{
        $doc=[System.Text.Json.JsonDocument]::Parse($_)
        try{Assert-IW7ScenarioJson $doc.RootElement}finally{$doc.Dispose()}
        ConvertFrom-Json -InputObject $_ -AsHashtable -Depth 8
    })
    if(!$rows.Count){return $null}
    $header=$rows[0]
    $keys=@('type','schema','pid','creation_filetime','nonce','qpc_frequency','b8_address','c0_address','max_events','duration_ms','native_hash_requires_parent_manifest','pristine')
    Assert-IW7ScenarioKeys $header $keys $keys
    if($header.native_hash_requires_parent_manifest -isnot [bool] -or !$header.native_hash_requires_parent_manifest){throw 'Parent manifest binding required.'}
    if($header.type -cne 'header' -or $header.schema -cne 'iw7.capacity-watch/1' -or $header.nonce -cne $Nonce -or
       $header.pid -isnot [long] -and $header.pid -isnot [int]){throw 'Capacity header schema/nonce/PID differs.'}
    foreach($field in @('pid','creation_filetime','qpc_frequency','max_events','duration_ms','b8_address','c0_address')) {
        if(!(Test-IW7CapacityInteger $header[$field] 1)){throw 'Capacity header integer type differs.'}
    }
    if($header.pid -ne $Identity.PID -or $header.creation_filetime -ne ([datetimeoffset]$Identity.CreatedUtc).UtcDateTime.ToFileTimeUtc() -or
       $header.qpc_frequency -le 0 -or $header.max_events -ne 64 -or $header.duration_ms -ne 10000 -or
       $header.b8_address -ne 0x143C986B8 -or $header.c0_address -ne 0x143C986C0 -or $header.pristine -isnot [bool] -or $header.pristine){throw 'Capacity identity/bounds differ.'}
    $events=@();$armed=$null;$complete=$null
    foreach($row in $rows|Select-Object -Skip 1){
        if($complete){throw 'Record published after terminal cleanup.'}
        switch -CaseSensitive ($row.type) {
            'event' {
                $keys=@('type','seq','kind','tid','roles','tick_ms','qpc','rip_after_write','slots','b8','c0','previous_b8','previous_c0','zero_seen','first_nonzero','context_hex')
                Assert-IW7ScenarioKeys $row $keys $keys
                foreach($field in @('seq','kind','tid','roles','tick_ms','qpc','rip_after_write','slots','b8','c0','previous_b8','previous_c0','zero_seen','first_nonzero')) {
                    if(!(Test-IW7CapacityInteger $row[$field])){throw 'Event integer type differs.'}
                }
                if($row.slots -gt 3 -or $row.zero_seen -gt 3 -or $row.first_nonzero -gt 3){throw 'Invalid event bitmask.'}
                if($events.Count -ge 64 -or $row.seq -is [bool] -or $row.seq -ne $events.Count -or
                   $row.kind -is [bool] -or $row.kind -notin @(0,1,2,3,4) -or $row.tid -le 0 -or $row.roles -notin @(1,2,3) -or
                   $row.tick_ms -le 0 -or $row.qpc -le 0 -or $row.context_hex -cnotmatch '^(?:[0-9a-f]{2}){512,4096}$'){throw 'Invalid bounded event/sequence/context.'}
                $events+=$row
            }
            'armed' {
                $keys=@('type','nonce','tick_ms','threads','all_init_threads_covered');Assert-IW7ScenarioKeys $row $keys $keys
                if($row.threads -isnot [array] -or !(Test-IW7CapacityInteger $row.tick_ms 1) -or $row.all_init_threads_covered -isnot [bool] -or $row.all_init_threads_covered){throw 'Invalid armed types/coverage.'}
                if($armed -or $row.nonce -cne $Nonce -or @($row.threads).Count -lt 1 -or @($row.threads).Count -gt 2){throw 'Duplicate or invalid armed acknowledgement.'}
                $covered=0;$tids=@()
                foreach($t in $row.threads){
                    $keys=@('tid','creation_filetime','roles','canary_pass');Assert-IW7ScenarioKeys $t $keys $keys
                    if(!(Test-IW7CapacityInteger $t.tid 1) -or !(Test-IW7CapacityInteger $t.creation_filetime 1) -or !(Test-IW7CapacityInteger $t.roles 1 3)){throw 'Thread integer type differs.'}
                    if($t.tid -le 0 -or $t.tid -in $tids -or $t.creation_filetime -le 0 -or $t.roles -notin @(1,2,3) -or $t.canary_pass -isnot [bool] -or !$t.canary_pass){throw 'Thread canary identity differs.'}
                    $canary=@($events|Where-Object{$_.kind -eq 0 -and $_.tid -eq $t.tid})
                    # The same TID may acquire the second scheduler role after
                    # its one hardware canary; role merging never changes TID.
                    if($canary.Count -ne 1 -or ($canary[0].roles -band $t.roles) -ne $canary[0].roles){throw 'Armed thread lacks its actual canary trap.'}
                    $covered=$covered -bor $t.roles;$tids+=$t.tid
                }
                if($covered -ne 3){throw 'Both scheduler roles must demonstrate canary.'};$armed=$row
            }
            'complete' {
                $keys=@('type','cleanup_confirmed','covered_roles','failures','canary_prerequisite_satisfied','event_limit_reached','all_init_threads_covered','patch_ready')
                Assert-IW7ScenarioKeys $row $keys $keys
                if(!(Test-IW7CapacityInteger $row.failures) -or !(Test-IW7CapacityInteger $row.covered_roles 0 3) -or
                   $row.canary_prerequisite_satisfied -isnot [bool] -or $row.all_init_threads_covered -isnot [bool] -or $row.all_init_threads_covered -or
                   $row.event_limit_reached -isnot [bool]){throw 'Invalid complete result types/coverage.'}
                if($complete -or $row.cleanup_confirmed -isnot [bool] -or !$row.cleanup_confirmed -or
                   $row.patch_ready -isnot [bool] -or $row.patch_ready){throw 'Invalid cleanup acknowledgement.'};$complete=$row
            }
            'failed' {throw 'Native probe failed without writer evidence.'}
            default {throw 'Unknown capacity journal record.'}
        }
    }
    [pscustomobject]@{Header=$header;Armed=$armed;Complete=$complete;Events=$events;WriterProven=$false;PatchReady=$false}
}
function Read-IW7CapacityOwnedJournal($Session) {
    Assert-IW7CapacitySession $Session
    $path=Resolve-IW7BasePath $Session.CandidateRoot $Session.JournalRelative
    if(!(Test-Path -LiteralPath $path)){return $null}
    $f=Get-Item -LiteralPath $path
    if($f.Length -gt 512KB -or $f.LastWriteTimeUtc -lt ([datetimeoffset]$Session.Identity.CreatedUtc).UtcDateTime){throw 'Stale/oversize capacity journal.'}
    $stream=[IO.File]::Open($path,'Open','Read','ReadWrite')
    try {
        $buffer=[byte[]]::new(512KB+1);$read=0
        do{$next=$stream.Read($buffer,$read,$buffer.Length-$read);$read+=$next}while($next -gt 0 -and $read -lt $buffer.Length)
        if($read -gt 512KB){throw 'Capacity journal grew beyond bound.'}
        $text=[Text.UTF8Encoding]::new($false,$true).GetString($buffer,0,$read)
    }finally{$stream.Dispose()}
    Read-IW7CapacityJournal $text $Session.Identity $Session.Nonce
}
function Invoke-IW7CapacityWatch($Session) {
    Wait-IW7CapacityVacant $Session
    if(Test-Path -LiteralPath (Resolve-IW7BasePath $Session.CandidateRoot $Session.JournalRelative)){throw 'Fresh nonce journal already exists.'}
    Send-IW7CapacityRcon $Session ('paris_capacity_arm '+$Session.Nonce)
    $deadline=[datetime]::UtcNow.AddSeconds(4);$journal=$null
    do{$journal=Read-IW7CapacityOwnedJournal $Session;if($journal -and $journal.Armed){break};Start-Sleep -Milliseconds 50}while([datetime]::UtcNow -lt $deadline)
    if(!$journal -or !$journal.Armed){throw 'No actual canary/armed acknowledgement; no restart authorized.'}
    # Recheck current UDP just before this ONE restart; 30s vacancy was established.
    Wait-IW7CapacityVacant $Session -Seconds 0 -TimeoutSeconds 3
    $reload=if($Session.PSObject.Properties['Plan'] -and $Session.Plan.PopulateAgents){'map cp_zmb'}else{'map_restart'}
    Send-IW7CapacityRcon $Session $reload
    $restartSent=[datetime]::UtcNow.ToString('o');$deadline=[datetime]::UtcNow.AddSeconds(12)
    do{$journal=Read-IW7CapacityOwnedJournal $Session;if($journal -and $journal.Complete){break};Start-Sleep -Milliseconds 50}while([datetime]::UtcNow -lt $deadline)
    Send-IW7CapacityRcon $Session 'paris_capacity_stop'
    if(!$journal -or !$journal.Complete){throw 'Disarm/removal acknowledgement absent; retain lease until exact owned exit.'}
    [pscustomobject]@{Schema='iw7.capacity-watch-runtime/1';RestartSentUtc=$restartSent;ReloadCommand=$reload;CanaryPassed=$true;NativeCleanupConfirmed=$true;
        WriteEvents=@($journal.Events|Where-Object kind -EQ 1).Count;CanaryOnly=(@($journal.Events|Where-Object kind -EQ 1).Count -eq 0);
        Events=$journal.Events;Failures=$journal.Complete.failures;CoveredRoles=$journal.Complete.covered_roles;
        WriterProven=$false;GlobalInitCoverage=$false;PatchReady=$false;JournalRelative=$Session.JournalRelative}
}
function Stop-IW7CapacityOwnedServer($Session) {
    # Generic OwnedStop forces even when StopAction throws. Here a refused UDP
    # vacancy check must preserve the process, never become a termination reason.
    Wait-IW7CapacityVacant $Session
    Send-IW7CapacityRcon $Session 'quit'
    $forced=$false
    if(!$Session.Handle.WaitForExit(10000)) {
        Wait-IW7CapacityVacant $Session
        Assert-IW7CapacitySession $Session
        $Session.Handle.Terminate(3758096385);$forced=$true
    }
    if(!$Session.Handle.WaitForExit(5000)){throw 'Owned exit unconfirmed; preserve lease and snapshots.'}
    [pscustomobject]@{Code=$Session.Handle.get_ExitCode();Kind=$(if($forced){'forced'}else{'quit'});RequestError=$null}
}
function Stop-IW7CapacityConfirmedFatal($Session,$Crash) {
    Assert-IW7CapacitySession $Session
    if(!$Crash -or !$Crash.ConfirmedFatal -or !$Crash.Report.correlated -or
       $Crash.Report.expected_pid -ne $Session.Identity.PID -or
       $Crash.Report.image.sha256 -ine $Session.Identity.SHA256 -or
       (Get-FileHash -LiteralPath $Crash.Artifact).Hash -ine $Crash.Report.dump.sha256){throw 'Same retained fatal artifact/image required.'}
    $dialog=Read-IW7AgentFatalDialog $Session.Identity
    if(!(Test-IW7AgentFatalEvidence $Crash.Report $dialog $Crash.OriginalDumpName)){throw 'Current exact fatal dialog absent; preserve process.'}
    Assert-IW7CapacitySession $Session
    $Session.Handle.Terminate(3758096385)
    if(!$Session.Handle.WaitForExit(5000)){throw 'Exact fatal process exit not confirmed; preserve reservation.'}
    [pscustomobject]@{Code=$Session.Handle.get_ExitCode();Kind='confirmed-fatal-recovery';RequestError=$null}
}
function Stop-IW7CapacityServerWithDiagnosis($Session,[string[]]$CrashBefore,[string]$OutputRoot,[hashtable]$CrashCache) {
    try{
        Send-IW7CapacityRcon $Session 'paris_capacity_stop'
        return Stop-IW7CapacityOwnedServer $Session
    }catch{
        $original=$_
        # The fatal dialog is published only after writing/compressing its dump.
        # Missing UDP alone still never grants termination authority.
        $deadline=[datetime]::UtcNow.AddSeconds(45)
        do{
            if($Session.Handle.HasExited){return [pscustomobject]@{Code=$Session.Handle.get_ExitCode();Kind='exited-during-diagnosis';RequestError=$original.Exception.Message}}
            $found=Get-IW7AgentNewCrash -CandidateRoot $Session.CandidateRoot -Identity $Session.Identity -Before $CrashBefore -OutputRoot $OutputRoot -Cache $CrashCache
            if($found){
                $Session|Add-Member -Force NoteProperty DiagnosedCrash $found
                if($found.ConfirmedFatal){return Stop-IW7CapacityConfirmedFatal $Session $found}
            }
            Start-Sleep -Milliseconds 250
        }while([datetime]::UtcNow -lt $deadline)
        throw $original
    }
}
