param([Parameter(Mandatory)][string]$CandidateRoot,[string]$PackageRoot,
      [ValidateRange(27100,27999)][int]$ServerPort=27116,[switch]$DryRun,[switch]$CaptureWriterPages,[switch]$CaptureNativeText,
      [ValidateSet(24,64)][int]$AgentCapacity=24,[switch]$PopulateAgents,
      [string]$ClientGameRoot,[ValidateRange(1,120)][int]$ClientObserveSeconds=30,
      [switch]$SkipReload,
      [ValidateSet('writer-path-20261019','binding-continuation-20261019')][string]$WriterPagePlan='writer-path-20261019')
$ErrorActionPreference='Stop'
if($PopulateAgents -and $AgentCapacity -ne 64){throw 'Pool construction probe requires explicit 64-agent candidate.'}
if($SkipReload -and (!$ClientGameRoot -or $CaptureWriterPages -or $CaptureNativeText)){throw 'Startup-only client mode cannot capture executable pages.'}
if($ClientGameRoot -and ($CaptureWriterPages -or $CaptureNativeText -or
   ($AgentCapacity -eq 64 -and !$PopulateAgents) -or ($AgentCapacity -eq 24 -and (!$SkipReload -or $PopulateAgents)))){throw 'Client probe requires private 64-agent construction or explicit unchanged 24-agent startup baseline.'}
$ops=Split-Path $PSScriptRoot -Parent;$repo=Split-Path $ops -Parent
. "$ops/Base-Client.Core.ps1"
. "$ops/Resource-Scheduler.Core.ps1"
. "$ops/Lab-Lifecycle.ps1"
. "$ops/Lab-RunPlan.ps1"
. "$ops/Agent-LabCrash.Core.ps1"
. "$PSScriptRoot/Watch-Runtime.Core.ps1"
$CandidateRoot=(Resolve-Path -LiteralPath $CandidateRoot).Path.TrimEnd('\','/')
$marker=Resolve-IW7BasePath $CandidateRoot 'iw7-mod/paris-isolated-lab.marker'
if(!(Test-Path $marker) -or [IO.File]::ReadAllText($marker) -cne 'iw7-paris-isolated-lab-v1' -or
   (Test-Path (Join-Path $CandidateRoot 'STOCK-ASSETS-REMOVED.json')) -or !(Test-Path (Join-Path $CandidateRoot 'iw7_ship.exe'))){throw 'Retained complete marked dedicated required.'}
if(!$PackageRoot){$PackageRoot=Join-Path $repo 'runtime/voice-package'}
$exe=Resolve-IW7BasePath $PackageRoot 'iw7-paris-voice.exe'
$manifest=Get-Content (Resolve-IW7BasePath $PackageRoot 'build-manifest.json') -Raw|ConvertFrom-Json
if(!$manifest.IsolatedLab -or !$manifest.ServerModules -or !$manifest.Debugger -or !$manifest.CapacityWatchBuild.Compiled -or
   !$manifest.TestHeartbeatSuppressed -or
   $manifest.BuildProfile -cne 'isolated-modules' -or (Get-FileHash $exe).Hash -cne $manifest.SHA256){throw 'Reviewed isolated watcher package required.'}
foreach($row in $manifest.SourceHashes){
    if($row.File -cnotmatch '^[a-zA-Z0-9_]+\.(cpp|hpp)$' -or (Get-FileHash (Join-Path $repo ('src/native/'+$row.File))).Hash -cne $row.SHA256){throw 'Native source/build mismatch.'}
}
foreach($name in @('paris_capacity_watch.cpp','paris_capacity_watch.hpp')){
    if(@($manifest.SourceHashes|Where-Object File -CEQ $name).Count -ne 1){throw 'Watcher source pin absent/duplicated.'}
}
if($AgentCapacity -eq 64 -and @($manifest.SourceHashes|Where-Object File -CEQ 'paris_agent_capacity.cpp').Count -ne 1){throw 'Capacity prototype source absent from native build.'}
$plannedClients=[int][bool]$ClientGameRoot
$clientImage=$null
if($ClientGameRoot){
    $ClientGameRoot=(Resolve-Path -LiteralPath $ClientGameRoot).Path.TrimEnd('\','/')
    Assert-IW7BaseVacant $ClientGameRoot
    $clientImage=Resolve-IW7BasePath $ClientGameRoot 'iw7-capacity-test-client.exe'
}
$budget=Get-IW7LabRunPlan -PlannedClients $plannedClients -Debugger
$image=Resolve-IW7BasePath $CandidateRoot 'iw7-paris-agent-lab.exe'
$plan=[pscustomobject]@{Schema='iw7.capacity-watch-server/1';CandidateRoot=$CandidateRoot;ServerImage=$image;ServerPort=$ServerPort;
    PlannedClients=$plannedClients;ClientImage=$clientImage;AgentCapacity=$AgentCapacity;PopulateAgents=[bool]$PopulateAgents;SkipReload=[bool]$SkipReload;PhysicalBytes=$budget.PhysicalBytes;CommitBytes=$budget.CommitBytes;Debugger=$true;NativeSHA256=$manifest.SHA256;StockCopied=$false;MainDeployed=$false}
if($DryRun){$plan|ConvertTo-Json;return}
Assert-IW7AgentCandidateVacant -CandidateRoot $CandidateRoot -Ports @($ServerPort)
$case=Join-Path $repo ('runtime/agent-capacity/watch-server-'+[datetime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff')+'-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($case)
$plan|ConvertTo-Json|Set-Content (Join-Path $case 'plan.local.json')
$lease=$null;$transaction=$null;$journalTransaction=$null;$server=$null;$session=$null;$result=$null;$failure=$null;$cleanupError=$null;$restored=$false;$stopResult=$null;$ownedExited=$false;$leaseReleased=$false
$pageReader=$null;$pageReaderClosed=$true;$pageCapture=$null;$pageCaptureError=$null;$textCapture=$null
$crash=$null;$crashCache=@{}
$client=$null;$clientImageTransaction=$null
try{
    $leaseOptions=@{}
    if($clientImage){$leaseOptions.BaseClientImage=$clientImage}
    $lease=Enter-IW7ResourceLease -Scope $CandidateRoot -Kind Runtime -PhysicalBytes $budget.PhysicalBytes -CommitBytes $budget.CommitBytes -Owner 'Private capacity construction and optional matching client' -RequireNewLease @leaseOptions
    # Recheck scope/ports under the reservation, before the first staged byte.
    Assert-IW7AgentCandidateVacant -CandidateRoot $CandidateRoot -Ports @($ServerPort)
    $stage=[pscustomobject]@{GameRoot=$CandidateRoot;MutableFiles=@('iw7-paris-agent-lab.exe','iw7-mod/server_capacity_watch.cfg');
        ProfileDirectory='iw7-mod/players2';ProfileDirectories=@('iw7-mod/custom_scripts/cp','iw7-mod/lab-appdata','mods/paris_beta/bank','iw7-mod/players2')}
    $transaction=Save-IW7BaseTransaction $stage (Join-Path $case 'dedicated-backup')
    # Keep the reusable stock. Retire only saved custom script files, not directories.
    foreach($entry in $transaction.Files|Where-Object {$_.Path.StartsWith('iw7-mod/custom_scripts/cp/') -and $_.Path -match '\.(gsc|gscbin)$'}){
        $path=Resolve-IW7BasePath $CandidateRoot $entry.Path
        if((Get-FileHash $path).Hash -cne $entry.SHA256){throw 'Script changed after snapshot.'}
    }
    foreach($entry in $transaction.Files|Where-Object {$_.Path.StartsWith('iw7-mod/custom_scripts/cp/') -and $_.Path -match '\.(gsc|gscbin)$'}){Remove-Item -LiteralPath (Resolve-IW7BasePath $CandidateRoot $entry.Path)}
    if($PopulateAgents -or $ClientGameRoot){Copy-Item -LiteralPath (Join-Path $repo 'tests/fixtures/capacity_pool.gsc') -Destination (Resolve-IW7BasePath $CandidateRoot 'iw7-mod/custom_scripts/cp/capacity_pool.gsc')}
    # This native allocation probe needs retail CP only. The split Native
    # product intentionally does not vendor the Server gameplay script set.
    Copy-Item -LiteralPath $exe -Destination $image
    if((Get-FileHash $image).Hash -cne $manifest.SHA256){throw 'Staged watcher hash differs.'}
    $secret=[guid]::NewGuid().ToString('N')+[guid]::NewGuid().ToString('N')
    $password=[guid]::NewGuid().ToString('N');$nonce=[guid]::NewGuid().ToString('N')
    $config=@"
set sv_hostname "IW7 Capacity Diagnostic"
set sv_maxclients 4
set g_gametype "zombie"
set scr_zombie_maxagents $AgentCapacity
set paris_capacity_pool_probe $([int][bool]$PopulateAgents)
set paris_capacity_pool_validate 0
set paris_capacity_client_probe $plannedClients
set net_ip 127.0.0.1
set sv_lanOnly 1
set g_password "$password"
set rcon_password "$secret"
set fs_game ""
set g_inactivity 0
set sv_cheats 0
set developer_script 1
set paris_isolated_lab 1
set paris_test_probe 0
set paris_agent_actions_probe 0
set paris_agent_combat_probe 0
set paris_model_probe 0
set paris_mod_voice 0
set paris_mod_doom 0
set paris_mod_rush 0
set paris_mod_loadout 0
set paris_join_loadout_test 0
set sv_mapRotation "gametype zombie map cp_zmb"
set sv_mapRotationCurrent ""
"@
    [IO.File]::WriteAllText((Resolve-IW7BasePath $CandidateRoot 'iw7-mod/server_capacity_watch.cfg'),$config,[Text.UTF8Encoding]::new($false))
    if(!('IW7LabProcess' -as [type])){Add-Type -Path "$ops/native/LabProcess.cs"}
    $desktop='IW7ParisLab_'+[guid]::NewGuid().ToString('N')
    $capacityFlag=if($AgentCapacity -eq 64){' -paris-capacity-64'}else{''}
    $crashBefore=@(Get-ChildItem -LiteralPath (Join-Path $CandidateRoot 'minidumps') -Filter '*.zip' -File -ErrorAction SilentlyContinue|ForEach-Object FullName)
    $arguments="-dedicated -allow_root_io -noupdate -nosteam -cpMode -stdout -paris-server-test -paris-isolated-lab -paris-debugger -paris-capacity-watch$capacityFlag +set net_ip 127.0.0.1 +set sv_lanOnly 1 +set net_port $ServerPort +exec server_capacity_watch.cfg +map_rotate"
    $server=[IW7LabProcess]::StartOwned($image,$arguments,$CandidateRoot,(Join-Path $case 'server.stdout.log'),(Join-Path $case 'server.stderr.log'),$desktop)
    $p=Get-Process -Id $server.Id
    try{$identity=[pscustomobject]@{PID=$server.Id;Image=$image;CreatedUtc=$p.StartTime.ToUniversalTime().ToString('o');SHA256=$manifest.SHA256;Stdout=(Join-Path $case 'server.stdout.log');DesktopName=$desktop}}finally{$p.Dispose()}
    $identity|ConvertTo-Json|Set-Content (Join-Path $case 'server.identity.local.json')
    Add-IW7ResourceProcess -Token $lease.Token -ProcessId $server.Id
    $relative='iw7-capacity-watch-'+$server.Id+'-'+$nonce+'.jsonl'
    $journalTransaction=Save-IW7BaseTransaction ([pscustomobject]@{GameRoot=$CandidateRoot;MutableFiles=@($relative);ProfileDirectory='iw7-mod/players2';ProfileDirectories=@()}) (Join-Path $case 'journal-backup')
    $session=[pscustomobject]@{CandidateRoot=$CandidateRoot;ServerPort=$ServerPort;Identity=$identity;Handle=$server;Plan=$plan;LeaseToken=$lease.Token;Nonce=$nonce;Secret=$secret;JournalRelative=$relative}
    # Missing UDP alone cannot authorize killing a loading process.
    $deadline=[datetime]::UtcNow.AddSeconds(120)
    do{
        Assert-IW7CapacitySession $session
        $observedCrash=Get-IW7AgentNewCrash -CandidateRoot $CandidateRoot -Identity $identity -Before $crashBefore -OutputRoot $case -Cache $crashCache
        if($observedCrash){$crash=$observedCrash;if($crash.ConfirmedFatal){throw 'Correlated native fatal during private startup; dump preserved.'}}
        try{$info=& "$ops/Get-ServerInfo.ps1" -Address '127.0.0.1' -Port $ServerPort}catch{$info=$null}
        if($info -and $info.sv_running -ceq '1' -and $info.mapname -ceq 'cp_zmb' -and $info.clients -ceq '0'){break}
        Start-Sleep -Milliseconds 500
    }while([datetime]::UtcNow -lt $deadline)
    if(!$info -or $info.clients -cne '0' -or $info.mapname -cne 'cp_zmb'){throw 'Startup not proven; preserve loading dedicated for diagnosis.'}
    if($SkipReload){$result=[pscustomobject]@{Schema='iw7.capacity-watch-runtime/1';ReloadCommand='none';ProbeSkipped=$true;NativeCleanupConfirmed=$false}}
    else{$result=Invoke-IW7CapacityWatch $session}
    if($ClientGameRoot){
        Assert-IW7BaseVacant $ClientGameRoot
        $clientStage=[pscustomobject]@{GameRoot=$ClientGameRoot;MutableFiles=@('iw7-capacity-test-client.exe');ProfileDirectory='iw7-mod/players2';ProfileDirectories=@()}
        $clientImageTransaction=Save-IW7BaseTransaction $clientStage (Join-Path $case 'client-image-backup')
        Copy-Item -LiteralPath $exe -Destination $clientImage
        $clientPlan=New-IW7BaseClientPlan -GameRoot $ClientGameRoot -ClientImage $clientImage -ServerPort $ServerPort -ClientPort ($ServerPort+1) -Debugger -GraphicsProfile Reduced -Capacity64:($AgentCapacity -eq 64)
        try{$client=Start-IW7BaseClient -Plan $clientPlan -ServerIdentity $identity -LeaseToken $lease.Token -Password $password -OutputRoot (Join-Path $case 'client')}
        catch{if($_.Exception.Data.Contains('BaseClientContext')){$client=$_.Exception.Data['BaseClientContext']};throw}
        $clientDeadline=[datetime]::UtcNow.AddSeconds(180)
        do{
            $sample=Update-IW7BaseClient $client
            if($client.Protected){break}
            Start-Sleep -Milliseconds 250
        }while([datetime]::UtcNow -lt $clientDeadline)
        if(!$client.Protected){throw 'Matching capacity client lacks fresh protected playable witness.'}
        $observeUntil=[datetime]::UtcNow.AddSeconds($ClientObserveSeconds)
        do{
            Update-IW7BaseClient $client|ConvertTo-Json -Compress|Add-Content (Join-Path $case 'client/protection.jsonl')
            Start-Sleep -Milliseconds 250
        }while([datetime]::UtcNow -lt $observeUntil)
        $result|Add-Member NoteProperty MatchingClientProtected $true
    }
    if($PopulateAgents){
        # Empty CP maps may stop advancing script frames after a full reload.
        # A declared protected client resumes the retail scheduler before this
        # fresh check; do not confuse a sent dvar command with script execution.
        Send-IW7CapacityRcon $session 'set paris_capacity_pool_validate 1'
        $poolDeadline=[datetime]::UtcNow.AddSeconds(5)
        do{
            Assert-IW7CapacitySession $session
            if($client){Update-IW7BaseClient $client|Out-Null}
            $freshLog=Read-IW7BaseLog (Join-Path $case 'server.stdout.log')
            if($freshLog.Contains('[Paris capacity pool] POST_RESTART native=64 initialized=64 unique=64 bounded=82; combat=0')){break}
            Start-Sleep -Milliseconds 50
        }while([datetime]::UtcNow -lt $poolDeadline)
        if($freshLog.Contains('[Paris capacity pool] FAIL') -or
           !$freshLog.Contains('[Paris capacity pool] READY native=64 initialized=64 unique=64 bounded=82; combat=0') -or
           !$freshLog.Contains('[Paris capacity pool] POST_RESTART native=64 initialized=64 unique=64 bounded=82; combat=0')){throw '64-agent construction not proven at startup and after restart.'}
        $result|Add-Member NoteProperty PoolConstructionConfirmed $true
    }
}catch{$failure=$_.Exception.Message}
finally{
    try{
        if($client){Stop-IW7BaseClient $client}
        if($clientImageTransaction){
            Assert-IW7BaseVacant $ClientGameRoot
            Restore-IW7BaseTransaction $clientImageTransaction
        }
        if($session -and !$server.HasExited -and $crash -and $crash.ConfirmedFatal){
            $stopResult=Stop-IW7CapacityConfirmedFatal $session $crash
        }elseif($session -and !$server.HasExited){
            if($CaptureWriterPages -or $CaptureNativeText){
                try{
                    $journal=Read-IW7CapacityOwnedJournal $session
                    if(!$journal -or !$journal.Armed){throw 'Writer pages require the same live journal and hardware canaries.'}
                    $writes=@($journal.Events|Where-Object kind -EQ 1)
                    foreach($site in @(0x14C1ED66C,0x14BFE5A30)){
                        if(!@($writes|Where-Object rip_after_write -EQ $site).Count){throw 'Observed writer site differs; no new page selection inferred.'}
                    }
                    . "$PSScriptRoot/CodePages.Core.ps1"
                    if(!('IW7CapacityPages' -as [type])){Add-Type -Path "$PSScriptRoot/CodePages.cs"}
                    Assert-IW7CapacitySession $session
                    $pageReader=[IW7CapacityPages]::new([int]$identity.PID,$identity.Image,([datetimeoffset]$identity.CreatedUtc).UtcDateTime.ToFileTimeUtc(),$WriterPagePlan)
                    $pageReaderClosed=$false
                    $proof=[pscustomobject]@{NativeSHA256=$manifest.SHA256;Header=$journal.Header;Armed=$journal.Armed;ObservedWriterAfter=@(0x14C1ED66C,0x14BFE5A30)}
                    if($CaptureWriterPages){
                        $pageCapture=Join-Path $case 'writer-pages'
                        Save-IW7CapacityCodePages $pageReader $pageCapture $identity $WriterPagePlan $proof
                    }
                    if($CaptureNativeText){
                        $textCapture=Join-Path $case 'native-text'
                        Save-IW7CapacityNativeText $pageReader $textCapture $identity $proof
                    }
                    Assert-IW7CapacitySession $session
                }catch{$pageCaptureError=$_.Exception.Message}
                finally{
                    if($pageReader){$pageReader.Dispose();$pageReaderClosed=$pageReader.Closed}
                }
                if(!$pageReaderClosed){throw 'Writer page reader closure unknown; retain reservation and original state.'}
            }
            Send-IW7CapacityRcon $session 'paris_capacity_stop'
            # Actual vacant UDP is mandatory before quit/owned-stop fallback.
            $stopResult=Stop-IW7CapacityOwnedServer $session
        }
        if($server -and !$server.HasExited){throw 'Owned dedicated exit absent; retain lease and snapshots.'}
        $ownedExited=($null -ne $server -and $server.HasExited)
        if($session){
            $journal=Resolve-IW7BasePath $CandidateRoot $session.JournalRelative
            if(Test-Path $journal){
                $before=(Get-FileHash -LiteralPath $journal).Hash
                $retained=Join-Path $case 'watch.raw.jsonl';Copy-Item -LiteralPath $journal -Destination $retained
                if((Get-FileHash -LiteralPath $journal).Hash -cne $before -or (Get-FileHash -LiteralPath $retained).Hash -cne $before){throw 'Retained journal changed during capture.'}
            }
        }
        # Owned process exit destroys its DRs/VEH; no false claim of cooperative ack.
        Assert-IW7AgentCandidateVacant -CandidateRoot $CandidateRoot -Ports @($ServerPort)
        if($journalTransaction){Restore-IW7BaseTransaction $journalTransaction}
        if($transaction){Restore-IW7BaseTransaction $transaction}
        $restored=$true
        if($lease){Exit-IW7ResourceLease -Token $lease.Token;$leaseReleased=$true}
    }catch{$cleanupError=$_.Exception.Message}
    if($server -and $server.HasExited){$server.Dispose()}
    [pscustomobject]@{Schema='iw7.capacity-watch-server/1';Result=$result;Failure=$failure;CleanupError=$cleanupError;Restored=$restored;
        ExactOwnedProcessExited=$ownedExited;Stop=$stopResult;LeaseReleased=$leaseReleased;LeaseRetained=(Get-IW7CapacityLeaseRetained $lease $leaseReleased);OutputRoot=$case;
        WriterPages=$pageCapture;WriterPageError=$pageCaptureError;WriterReaderClosed=$pageReaderClosed;
        NativeText=$textCapture;RequestedAgentCapacity=$AgentCapacity;Crash=$crash;
        StockCopied=$false;BaseClientTouched=[bool]$ClientGameRoot;ClientRestored=$(if($client){$client.Transaction.Restored}else{$null});WriterProven=$false;PatchReady=$false}|ConvertTo-Json -Depth 9|Set-Content (Join-Path $case 'result.local.json')
}
if($failure){throw "$failure ; evidence=$case"};if($cleanupError){throw "Cleanup pending: $cleanupError ; evidence=$case"};if($pageCaptureError){throw "Writer pages failed: $pageCaptureError ; evidence=$case"}
Write-Output "Capacity server probe restored=$restored evidence=$case"
