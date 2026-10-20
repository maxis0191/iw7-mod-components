param([Parameter(Mandatory)][string]$CandidateRoot,[string]$PackageRoot,
      [ValidateRange(27100,27999)][int]$ServerPort=27116,[switch]$DryRun,[switch]$CaptureWriterPages,[switch]$CaptureNativeText,
      [ValidateSet(24,64)][int]$AgentCapacity=24,[switch]$PopulateAgents,
      [string]$ClientGameRoot,[ValidateRange(1,600)][int]$ClientObserveSeconds=30,
      [ValidateSet('Full','Reduced')][string]$ClientGraphicsProfile='Reduced',
      [switch]$SkipReload,
      [ValidateSet('cp_zmb','cp_rave','cp_disco','cp_town','cp_final')][string]$Map='cp_zmb',
      [string]$CatalogRoot,[switch]$RotateBeast,
      [string]$StandardClientPackageRoot,
      [switch]$CaptureClientCrashMemory,
      [switch]$RequireSparseAgentWire,
      [switch]$ExerciseClientFire,[switch]$CaptureClientFrame,[switch]$InteractiveClient,
      [string]$HordeFixturePath,[string]$HordeFixtureSHA256,
      [string]$NaturalFixturePath,[string]$NaturalFixtureSHA256,
      [ValidateSet(24,48)][int]$HordeOrdinary=48,[ValidateRange(0,2)][int]$HordeSpecials=2,
      [string]$RetailCpPatchPath,[string]$RetailCpPatchSHA256,
      [ValidateSet('writer-path-20261019','binding-continuation-20261019')][string]$WriterPagePlan='writer-path-20261019')
$ErrorActionPreference='Stop'
if(($ExerciseClientFire -or $CaptureClientFrame -or $InteractiveClient) -and (!$NaturalFixturePath -or !$StandardClientPackageRoot)){
    throw 'Fixed client input/capture requires the pinned natural observation and standard client.'
}
if($NaturalFixturePath -or $NaturalFixtureSHA256){
    if(!$SkipReload -or !$ClientGameRoot -or !$CatalogRoot -or $PopulateAgents -or $HordeFixturePath -or
       $AgentCapacity -ne 64 -or $ClientObserveSeconds -lt 90 -or ![IO.Path]::IsPathFullyQualified($NaturalFixturePath) -or
       $NaturalFixtureSHA256 -cnotmatch '^[A-Fa-f0-9]{64}$'){throw 'Natural capacity observation requires its complete protected64 catalog/client scenario without forced construction or a horde supplier.'}
    $naturalItem=Get-Item -LiteralPath $NaturalFixturePath
    if($naturalItem.Length -lt 1 -or $naturalItem.Length -gt 16KB -or $naturalItem.Extension -cne '.gsc' -or
       ($naturalItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or (Get-FileHash -LiteralPath $NaturalFixturePath).Hash -ine $NaturalFixtureSHA256){throw 'Pinned natural observation source differs.'}
}
if($RetailCpPatchPath -or $RetailCpPatchSHA256){
    if(![IO.Path]::IsPathFullyQualified($RetailCpPatchPath) -or $RetailCpPatchSHA256 -cnotmatch '^[A-Fa-f0-9]{64}$'){throw 'Pinned managed CP patch required.'}
    $retailItem=Get-Item -LiteralPath $RetailCpPatchPath
    if($retailItem.Length -lt 1 -or $retailItem.Length -gt 64KB -or $retailItem.Extension -cne '.gsc' -or
       ($retailItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or (Get-FileHash -LiteralPath $RetailCpPatchPath).Hash -ine $RetailCpPatchSHA256){throw 'Managed CP patch identity differs.'}
}
if($HordeFixturePath -or $HordeFixtureSHA256){
    if(!$SkipReload -or !$ClientGameRoot -or !$PopulateAgents -or $AgentCapacity -ne 64 -or
       $ClientObserveSeconds -lt 60 -or ![IO.Path]::IsPathFullyQualified($HordeFixturePath) -or
       $HordeFixtureSHA256 -cnotmatch '^[A-Fa-f0-9]{64}$'){throw 'Horde fixture requires a pinned source and complete protected startup64 observation.'}
    $hordeItem=Get-Item -LiteralPath $HordeFixturePath
    if($hordeItem.Length -lt 1 -or $hordeItem.Length -gt 64KB -or $hordeItem.Extension -cne '.gsc' -or
       ($hordeItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
       (Get-FileHash -LiteralPath $HordeFixturePath).Hash -ine $HordeFixtureSHA256){throw 'Pinned bounded horde source differs.'}
}
if($PopulateAgents -and $AgentCapacity -ne 64){throw 'Pool construction probe requires explicit 64-agent candidate.'}
if($RequireSparseAgentWire -and (!$HordeFixturePath -or !$ClientGameRoot -or $HordeOrdinary -ne 48)){throw 'Sparse wire witness requires the pinned active48 encounter and owned client.'}
if($SkipReload -and (!$ClientGameRoot -or $CaptureWriterPages -or $CaptureNativeText)){throw 'Startup-only client mode cannot capture executable pages.'}
if($ClientGameRoot -and ($CaptureWriterPages -or $CaptureNativeText -or
   ($AgentCapacity -eq 64 -and !$PopulateAgents -and !$NaturalFixturePath) -or ($AgentCapacity -eq 24 -and (!$SkipReload -or $PopulateAgents)))){throw 'Client probe requires private64 construction, explicit natural observation or an unchanged24 startup baseline.'}
$ops=Split-Path $PSScriptRoot -Parent;$repo=Split-Path $ops -Parent
if(($Map -cne 'cp_zmb' -or $CatalogRoot -or $RotateBeast) -and !$SkipReload){throw 'Map/catalog probes require fresh protected startup.'}
if($RotateBeast -and (!$ClientGameRoot -or !$CatalogRoot -or $Map -ceq 'cp_final')){throw 'Occupied Beast rotation requires the complete catalog and owned client.'}
$catalog=@()
if($CatalogRoot){
    $CatalogRoot=(Resolve-Path -LiteralPath $CatalogRoot).Path
    $catalogManifest=Get-Content (Join-Path $CatalogRoot 'source-workspace.json') -Raw|ConvertFrom-Json
    $catalog=@($catalogManifest.files|Where-Object path -Match '^src/custom_scripts/cp/[^/]+\.gsc$')
    if($catalog.Count -lt 18){throw 'Complete composed production catalog required.'}
    foreach($f in $catalog){if((Get-FileHash (Join-Path $CatalogRoot $f.path)).Hash -ine $f.sha256){throw 'Catalog source differs.'}}
    $reader=@($catalogManifest.files|Where-Object path -CEQ 'ops/native/DoomDiagnostics.cs')
    if($reader.Count -ne 1 -or (Get-FileHash (Join-Path $CatalogRoot $reader[0].path)).Hash -ine $reader[0].sha256){throw 'Pinned catalog capacity reader required.'}
    foreach($path in @('ops/modding/Agent-Restoration.Core.ps1','ops/hud-lab/HudFileIdentity.cs')){
        $row=@($catalogManifest.files|Where-Object path -CEQ $path)
        if($row.Count -ne 1 -or (Get-FileHash (Join-Path $CatalogRoot $path)).Hash -ine $row[0].sha256){throw 'Pinned catalog bank isolation source required.'}
    }
}
. "$ops/Base-Client.Core.ps1"
. "$ops/Resource-Scheduler.Core.ps1"
. "$ops/Lab-Lifecycle.ps1"
. "$ops/Lab-RunPlan.ps1"
. "$ops/Agent-LabCrash.Core.ps1"
. "$PSScriptRoot/Watch-Runtime.Core.ps1"
. "$PSScriptRoot/Standard-Client.Core.ps1"
$standardManifest=$null
if($StandardClientPackageRoot){
    if(!$ClientGameRoot -or !$SkipReload -or $AgentCapacity -ne 64){throw 'Standard client needs protected expanded startup.'}
    $standardManifest=Get-Content (Join-Path $StandardClientPackageRoot 'build-manifest.json') -Raw|ConvertFrom-Json
    if($standardManifest.Schema -cne 'iw7.standard-client-build/1' -or $standardManifest.Capacity64Capability -ne $true -or
       $standardManifest.CapacityWireContract -cne '64-v2' -or
       (Get-FileHash (Join-Path $StandardClientPackageRoot 'iw7-mod.exe')).Hash -cne $standardManifest.SHA256){throw 'Pinned expanded standard client required.'}
    foreach($name in @('paris_agent_capacity.cpp','paris_agent_capacity.hpp')){
        $row=@($standardManifest.NativeSourceHashes|Where-Object File -CEQ ('src/client/component/'+$name))
        if($row.Count -ne 1 -or $row[0].SHA256 -cne (Get-FileHash (Join-Path $repo ('src/native/'+$name))).Hash){throw 'Standard client port source differs.'}
    }
}
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
Assert-IW7CapacityCatalogCapabilities $catalog $manifest
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
$budget=Get-IW7LabRunPlan -PlannedClients $plannedClients -GraphicsProfile $ClientGraphicsProfile -Debugger
if($CaptureClientCrashMemory){
    if(!$ClientGameRoot){throw 'Client crash capture requires the owned protected client scenario.'}
    $budget.PhysicalBytes+=512MB;$budget.CommitBytes+=1GB
}
$image=Resolve-IW7BasePath $CandidateRoot 'iw7-paris-agent-lab.exe'
$plan=[pscustomobject]@{Schema='iw7.capacity-watch-server/1';CandidateRoot=$CandidateRoot;ServerImage=$image;ServerPort=$ServerPort;
    Map=$Map;Catalog=@($catalog);RotateBeast=[bool]$RotateBeast;PlannedClients=$plannedClients;ClientImage=$clientImage;AgentCapacity=$AgentCapacity;PopulateAgents=[bool]$PopulateAgents;SkipReload=[bool]$SkipReload;HordeFixtureSHA256=$HordeFixtureSHA256;HordeOrdinary=$HordeOrdinary;HordeSpecials=$HordeSpecials;RetailCpPatchSHA256=$RetailCpPatchSHA256;PhysicalBytes=$budget.PhysicalBytes;CommitBytes=$budget.CommitBytes;Debugger=$true;NativeSHA256=$manifest.SHA256;StockCopied=$false;MainDeployed=$false}
$plan|Add-Member NoteProperty NaturalFixtureSHA256 $NaturalFixtureSHA256
$plan|Add-Member NoteProperty RequireSparseAgentWire ([bool]$RequireSparseAgentWire)
$plan|Add-Member NoteProperty ClientGraphicsProfile $ClientGraphicsProfile
$plan|Add-Member NoteProperty ExerciseClientFire ([bool]$ExerciseClientFire)
$plan|Add-Member NoteProperty CaptureClientFrame ([bool]$CaptureClientFrame)
$plan|Add-Member NoteProperty InteractiveClient ([bool]$InteractiveClient)
Assert-IW7CapacityClientPlan $plan
if($DryRun){$plan|ConvertTo-Json;return}
Assert-IW7AgentCandidateVacant -CandidateRoot $CandidateRoot -Ports @($ServerPort)
$case=Join-Path $repo ('runtime/agent-capacity/watch-server-'+[datetime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff')+'-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($case)
$plan|ConvertTo-Json|Set-Content (Join-Path $case 'plan.local.json')
$lease=$null;$transaction=$null;$journalTransaction=$null;$server=$null;$session=$null;$result=$null;$failure=$null;$cleanupError=$null;$restored=$false;$stopResult=$null;$ownedExited=$false;$leaseReleased=$false
$pageReader=$null;$pageReaderClosed=$true;$pageCapture=$null;$pageCaptureError=$null;$textCapture=$null
$crash=$null;$crashCache=@{}
$client=$null;$clientImageTransaction=$null
$bankIsolation=$null;$clientManagedRestored=$false
$clientCrash=$null;$clientCrashCache=@{}
$fireStarted=$false;$fireStopped=$false;$frameRequested=$false;$fireDeadline=$null
try{
    $leaseOptions=@{}
    if($clientImage){$leaseOptions.BaseClientImage=$clientImage}
    $lease=Enter-IW7ResourceLease -Scope $CandidateRoot -Kind Runtime -PhysicalBytes $budget.PhysicalBytes -CommitBytes $budget.CommitBytes -Owner 'Private capacity construction and optional matching client' -RequireNewLease @leaseOptions
    # Recheck scope/ports under the reservation, before the first staged byte.
    Assert-IW7AgentCandidateVacant -CandidateRoot $CandidateRoot -Ports @($ServerPort)
    if($ClientGameRoot -and $CatalogRoot){
        . (Join-Path $CatalogRoot 'ops/modding/Agent-Restoration.Core.ps1')
        $bankIsolation=New-IW7AgentBankIsolation $ClientGameRoot $CandidateRoot
    }
    $stage=[pscustomobject]@{GameRoot=$CandidateRoot;MutableFiles=@('iw7-paris-agent-lab.exe','iw7-mod/server_capacity_watch.cfg','iw7-mod/paris-server-client.request','iw7-mod/paris-server-client.response');
        ProfileDirectory='iw7-mod/players2';ProfileDirectories=@('iw7-mod/custom_scripts/cp','iw7-mod/lab-appdata','mods/paris_beta/bank','mods/paris_beta/stats','iw7-mod/players2')}
    $transaction=Save-IW7BaseTransaction $stage (Join-Path $case 'dedicated-backup')
    # Keep the reusable stock. Retire only saved custom script files, not directories.
    foreach($entry in $transaction.Files|Where-Object {$_.Path.StartsWith('iw7-mod/custom_scripts/cp/') -and $_.Path -match '\.(gsc|gscbin)$'}){
        $path=Resolve-IW7BasePath $CandidateRoot $entry.Path
        if((Get-FileHash $path).Hash -cne $entry.SHA256){throw 'Script changed after snapshot.'}
    }
    foreach($entry in $transaction.Files|Where-Object {$_.Path.StartsWith('iw7-mod/custom_scripts/cp/') -and $_.Path -match '\.(gsc|gscbin)$'}){Remove-Item -LiteralPath (Resolve-IW7BasePath $CandidateRoot $entry.Path)}
    foreach($f in $catalog){
        $target=Resolve-IW7BasePath $CandidateRoot ('iw7-mod/custom_scripts/cp/'+[IO.Path]::GetFileName($f.path))
        Copy-Item -LiteralPath (Join-Path $CatalogRoot $f.path) -Destination $target
        if((Get-FileHash $target).Hash -ine $f.sha256){throw 'Staged catalog differs.'}
    }
    if($RetailCpPatchPath){
        $retailTarget=Resolve-IW7BasePath $CandidateRoot 'iw7-mod/lab-appdata/cdata/custom_scripts/cp/patches.gsc'
        [IO.Directory]::CreateDirectory((Split-Path $retailTarget -Parent))|Out-Null
        Copy-Item -LiteralPath $RetailCpPatchPath -Destination $retailTarget
        if((Get-FileHash -LiteralPath $retailTarget).Hash -ine $RetailCpPatchSHA256 -or
           (Get-FileHash -LiteralPath $RetailCpPatchPath).Hash -ine $RetailCpPatchSHA256){throw 'Managed CP patch changed during staging.'}
    }
    if($PopulateAgents -or $ClientGameRoot){Copy-Item -LiteralPath (Join-Path $repo 'tests/fixtures/capacity_pool.gsc') -Destination (Resolve-IW7BasePath $CandidateRoot 'iw7-mod/custom_scripts/cp/capacity_pool.gsc')}
    if($HordeFixturePath){
        $target=Resolve-IW7BasePath $CandidateRoot 'iw7-mod/custom_scripts/cp/capacity_horde.gsc'
        Copy-Item -LiteralPath $HordeFixturePath -Destination $target
        if((Get-FileHash $target).Hash -ine $HordeFixtureSHA256 -or (Get-FileHash $HordeFixturePath).Hash -ine $HordeFixtureSHA256){throw 'Horde source changed during staging.'}
    }
    if($NaturalFixturePath){
        $target=Resolve-IW7BasePath $CandidateRoot 'iw7-mod/custom_scripts/cp/capacity_natural.gsc'
        Copy-Item -LiteralPath $NaturalFixturePath -Destination $target
        if((Get-FileHash -LiteralPath $target).Hash -ine $NaturalFixtureSHA256 -or (Get-FileHash -LiteralPath $NaturalFixturePath).Hash -ine $NaturalFixtureSHA256){throw 'Natural observation source changed during staging.'}
    }
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
set paris_capacity_natural_probe $([int][bool]$NaturalFixturePath)
set paris_capacity_pool_validate 0
set paris_capacity_client_probe $plannedClients
set paris_capacity_horde_target $(if($HordeFixturePath){$HordeOrdinary}else{0})
set paris_capacity_horde_specials $HordeSpecials
set paris_enemy_capacity $(if($CatalogRoot){48}else{0})
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
set paris_mod_rush $([int][bool]$NaturalFixturePath)
set paris_mod_loadout 0
set paris_join_loadout_test 0
set sv_mapRotation "gametype zombie map $Map"
set sv_mapRotationCurrent ""
"@
    [IO.File]::WriteAllText((Resolve-IW7BasePath $CandidateRoot 'iw7-mod/server_capacity_watch.cfg'),$config,[Text.UTF8Encoding]::new($false))
    if(!('IW7LabProcess' -as [type])){Add-Type -Path "$ops/native/LabProcess.cs"}
    $desktop='IW7ParisLab_'+[guid]::NewGuid().ToString('N')
    $capacityFlag=if($AgentCapacity -eq 64){' -paris-capacity-64'}else{''}
    if($RequireSparseAgentWire){$capacityFlag+=' -paris-capacity-sparse-wire-probe'}
    $crashBefore=@(Get-ChildItem -LiteralPath (Join-Path $CandidateRoot 'minidumps') -Filter '*.zip' -File -ErrorAction SilentlyContinue|ForEach-Object FullName)
    $arguments="-dedicated -allow_root_io -noupdate -nosteam -cpMode -stdout -paris-server-test -paris-isolated-lab -paris-debugger -paris-capacity-watch -paris-voice-base-test$capacityFlag +set net_ip 127.0.0.1 +set sv_lanOnly 1 +set net_port $ServerPort +exec server_capacity_watch.cfg +map_rotate"
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
        Assert-IW7CapacityScriptLog (Read-IW7BaseLog (Join-Path $case 'server.stdout.log')) -DiagnosticRuntime:([bool]$NaturalFixturePath)
        try{$info=& "$ops/Get-ServerInfo.ps1" -Address '127.0.0.1' -Port $ServerPort}catch{$info=$null}
        if($info -and $info.sv_running -ceq '1' -and $info.mapname -ceq $Map -and $info.clients -ceq '0'){break}
        Start-Sleep -Milliseconds 500
    }while([datetime]::UtcNow -lt $deadline)
    if(!$info -or $info.clients -cne '0' -or $info.mapname -cne $Map){throw 'Startup not proven; preserve loading dedicated for diagnosis.'}
    if($CatalogRoot){
        if(!('IW7DoomDiagnostics' -as [type])){Add-Type -Path (Join-Path $CatalogRoot 'ops/native/DoomDiagnostics.cs')}
        $pool=[IW7DoomDiagnostics]::Canonical($identity.PID,$identity.Image,([datetimeoffset]$identity.CreatedUtc).UtcDateTime.ToFileTimeUtc())
        $canonical=@([pscustomobject]@{Map=$Map;Phase='Cold';Used=$pool[0];Free=(4095-$pool[0]);NameBytes=$pool[1]})
        if($canonical[0].Free -lt 64){throw 'Cold canonical floor failed.'}
    }
    if($SkipReload){$result=[pscustomobject]@{Schema='iw7.capacity-watch-runtime/1';ReloadCommand='none';ProbeSkipped=$true;NativeCleanupConfirmed=$false}}
    else{$result=Invoke-IW7CapacityWatch $session}
    if($ClientGameRoot){
        Assert-IW7CapacityScriptLog (Read-IW7BaseLog (Join-Path $case 'server.stdout.log')) -DiagnosticRuntime:([bool]$NaturalFixturePath)
        Assert-IW7BaseVacant $ClientGameRoot
        $clientStage=[pscustomobject]@{GameRoot=$ClientGameRoot;MutableFiles=@('iw7-capacity-test-client.exe');ProfileDirectory='iw7-mod/players2';ProfileDirectories=@()}
        $clientImageTransaction=Save-IW7BaseTransaction $clientStage (Join-Path $case 'client-image-backup')
        $clientExe=if($standardManifest){Join-Path $StandardClientPackageRoot 'iw7-mod.exe'}else{$exe}
        Copy-Item -LiteralPath $clientExe -Destination $clientImage
        $clientPlan=New-IW7BaseClientPlan -GameRoot $ClientGameRoot -ClientImage $clientImage -ServerPort $ServerPort -ClientPort ($ServerPort+1) -Debugger -GraphicsProfile $ClientGraphicsProfile -Capacity64:(!$standardManifest -and $AgentCapacity -eq 64)
        try{
            if($standardManifest){$client=Start-IW7CapacityStandardClient $clientPlan $identity $lease.Token $password (Join-Path $case 'client') ([bool]$InteractiveClient)}
            else{$client=Start-IW7BaseClient -Plan $clientPlan -ServerIdentity $identity -LeaseToken $lease.Token -Password $password -OutputRoot (Join-Path $case 'client')}
        }
        catch{if($_.Exception.Data.Contains('BaseClientContext')){$client=$_.Exception.Data['BaseClientContext']};throw}
        $clientDeadline=[datetime]::UtcNow.AddSeconds(180)
        do{
            Assert-IW7CapacityScriptLog (Read-IW7BaseLog (Join-Path $case 'server.stdout.log')) -DiagnosticRuntime:([bool]$NaturalFixturePath)
            $newClientCrash=Get-IW7AgentNewCrash -CandidateRoot $ClientGameRoot -Identity $client.Identity -Before @() -OutputRoot $case -Cache $clientCrashCache
            if($newClientCrash){$clientCrash=$newClientCrash;throw 'Correlated native client exception; artifact retained.'}
            $sample=Update-IW7BaseClient $client
            if($client.Protected){break}
            Start-Sleep -Milliseconds 250
        }while([datetime]::UtcNow -lt $clientDeadline)
        if(!$client.Protected){throw 'Matching capacity client lacks fresh protected playable witness.'}
        $observeUntil=[datetime]::UtcNow.AddSeconds($ClientObserveSeconds)
        $inputAt=[datetime]::UtcNow.AddSeconds(60)
        do{
            Assert-IW7CapacityScriptLog (Read-IW7BaseLog (Join-Path $case 'server.stdout.log')) -DiagnosticRuntime:([bool]$NaturalFixturePath)
            $observedCrash=Get-IW7AgentNewCrash -CandidateRoot $CandidateRoot -Identity $identity -Before $crashBefore -OutputRoot $case -Cache $crashCache
            if($observedCrash){$crash=$observedCrash;if($crash.ConfirmedFatal){throw 'Correlated native dedicated fatal during natural observation; dump preserved.'}}
            $newClientCrash=Get-IW7AgentNewCrash -CandidateRoot $ClientGameRoot -Identity $client.Identity -Before @() -OutputRoot $case -Cache $clientCrashCache
            if($newClientCrash){$clientCrash=$newClientCrash;throw 'Correlated native client exception; artifact retained.'}
            Update-IW7BaseClient $client|ConvertTo-Json -Compress|Add-Content (Join-Path $case 'client/protection.jsonl')
            if(($ExerciseClientFire -or $CaptureClientFrame) -and [datetime]::UtcNow -ge $inputAt -and
               (Read-IW7BaseLog (Join-Path $case 'server.stdout.log')).Contains('; ordinary=48;')){
                Assert-IW7BaseIdentity $client.Identity $client.Handle
                if(!$client.Protected -or ([datetime]::UtcNow-$client.LastHeartbeatUtc).TotalSeconds -gt 5){throw 'Fresh protection required before fixed client input.'}
                $inputIdentity=$client.Handle.ReadIdentity()
                if($CaptureClientFrame -and !$frameRequested){$client.Handle.WriteCapacityLifecycle('capture',$inputIdentity.Image,$inputIdentity.CreationFileTime);$frameRequested=$true}
                if($ExerciseClientFire -and !$fireStarted){$client.Handle.WriteCapacityLifecycle('fire-on',$inputIdentity.Image,$inputIdentity.CreationFileTime);$fireStarted=$true;$fireDeadline=[datetime]::UtcNow.AddMilliseconds(500)}
                if($fireStarted -and !$fireStopped -and [datetime]::UtcNow -ge $fireDeadline){$client.Handle.WriteCapacityLifecycle('fire-off',$inputIdentity.Image,$inputIdentity.CreationFileTime);$fireStopped=$true}
            }
            if($HordeFixturePath -and (Read-IW7BaseLog (Join-Path $case 'server.stdout.log')).Contains('[Paris capacity horde] FAIL')){throw 'Private horde reported failure; stop and retain its diagnostics.'}
            if($NaturalFixturePath -and (Read-IW7BaseLog (Join-Path $case 'server.stdout.log')).Contains('[Paris natural capacity] FAIL')){throw 'Private natural observer reported failure; retain its diagnostics.'}
            Start-Sleep -Milliseconds 250
        }while([datetime]::UtcNow -lt $observeUntil)
        $result|Add-Member NoteProperty MatchingClientProtected $true
        if($NaturalFixturePath){
            $naturalLog=Read-IW7BaseLog (Join-Path $case 'server.stdout.log')
            if(!$naturalLog.Contains('[Paris natural capacity] OBSERVE native=64;')){throw 'Natural capacity observation was not recorded.'}
            $result|Add-Member NoteProperty NaturalObservationSourceSHA256 $NaturalFixtureSHA256
            $result|Add-Member NoteProperty ForcedPoolConstruction $false
            $result|Add-Member NoteProperty ClientVisibilityQualified $false
            $result|Add-Member NoteProperty ScriptRuntimeErrorCount ([regex]::Matches($naturalLog,'(?im)^\*+\s*script runtime error\b').Count)
            $result|Add-Member NoteProperty DiagnosticOnly $true
            $result|Add-Member NoteProperty ClientFireInputSent $fireStarted
            $result|Add-Member NoteProperty FrameCommandSent $frameRequested
        }
        if($HordeFixturePath){
            $hordeLog=Read-IW7BaseLog (Join-Path $case 'server.stdout.log')
            $expected="[Paris capacity horde] PASS ordinary=$HordeOrdinary special=$HordeSpecials total=$($HordeOrdinary+$HordeSpecials);"
            if($hordeLog.Contains('[Paris capacity horde] FAIL') -or !$hordeLog.Contains($expected)){throw 'Requested active horde plateau not proven.'}
            $result|Add-Member NoteProperty HordePopulationConfirmed $true
            $result|Add-Member NoteProperty Horde48PlusSpecialsConfirmed ($HordeOrdinary -eq 48 -and $HordeSpecials -eq 2)
            if($RequireSparseAgentWire){
                if(![regex]::IsMatch($hordeLog,'\[Paris capacity agent wire\] explicit id=(?:6[4-9]|7[0-9]|8[01]) previous=-?\d+ removed=[01] width=7 bits=\d+')){throw 'Actual sparse high-agent wire update not witnessed.'}
                $result|Add-Member NoteProperty SparseAgentWireConfirmed $true
            }
        }
        if($CatalogRoot){
            $pool=[IW7DoomDiagnostics]::Canonical($identity.PID,$identity.Image,([datetimeoffset]$identity.CreatedUtc).UtcDateTime.ToFileTimeUtc())
            $canonical+=@([pscustomobject]@{Map=$Map;Phase='Occupied';Used=$pool[0];Free=(4095-$pool[0]);NameBytes=$pool[1]})
            if($canonical[-1].Free -lt 64){throw 'Occupied canonical floor failed.'}
        }
        if($RotateBeast){
            $null=Update-IW7BaseClient $client
            $offset=(Read-IW7BaseLog $identity.Stdout).Length
            $request="$($identity.PID) $([guid]::NewGuid().ToString('N')) map_cp_final"
            [IO.File]::WriteAllText((Resolve-IW7BasePath $CandidateRoot 'iw7-mod/paris-server-client.request'),$request,[Text.Encoding]::ASCII)
            $deadline=[datetime]::UtcNow.AddSeconds(180);$arrived=$false
            do{
                Assert-IW7CapacitySession $session
                if(!(Test-IW7BaseClientActive $client)){throw 'Owned client exited during occupied rotation.'}
                $fresh=(Read-IW7BaseLog $identity.Stdout).Substring($offset)
                if($fresh -match 'MAX_CANONICAL_STRING|failed to compile|script compile error|\[Paris test protection failure\]'){throw 'Occupied rotation compile/protection failure.'}
                try{$info=& "$ops/Get-ServerInfo.ps1" -Port $ServerPort}catch{$info=$null}
                $safe=[regex]::Matches($fresh,'\[Paris capacity heartbeat\] slot=0; tick_ms=(\d+); protected=1; bound=1; godmode=1; inactivity=0; cheats=0; failed=0')
                if($info -and $info.mapname -ceq 'cp_final' -and $info.clients -ceq '1' -and $safe.Count -and
                   [Environment]::TickCount64-[long]$safe[-1].Groups[1].Value -lt 10000){$arrived=$true;break}
                Start-Sleep -Milliseconds 500
            }while([datetime]::UtcNow -lt $deadline)
            if(!$arrived){throw 'Fresh protected occupied Beast arrival not witnessed.'}
            $session.Plan.Map='cp_final'
            $pool=[IW7DoomDiagnostics]::Canonical($identity.PID,$identity.Image,([datetimeoffset]$identity.CreatedUtc).UtcDateTime.ToFileTimeUtc())
            $canonical+=@([pscustomobject]@{Map='cp_final';Phase='OccupiedRotation';Used=$pool[0];Free=(4095-$pool[0]);NameBytes=$pool[1]})
            if($canonical[-1].Free -lt 64){throw 'Occupied Beast canonical floor failed.'}
            $result|Add-Member NoteProperty OccupiedBeastRotation $true
        }
    }
    if($PopulateAgents){
        $phase=if($client){'PLAYABLE'}else{'READY'}
        $freshLog=Read-IW7BaseLog (Join-Path $case 'server.stdout.log')
        if($freshLog.Contains('[Paris capacity pool] FAIL') -or
           !$freshLog.Contains("[Paris capacity pool] $phase native=64 initialized=64 unique=64 bounded=82; combat=0")){throw '64-agent construction lacks its requested script-phase witness.'}
        $result|Add-Member NoteProperty PoolConstructionConfirmed $true
        $result|Add-Member NoteProperty PoolConstructionPhase $phase
    }
    if($CatalogRoot){$result|Add-Member NoteProperty Canonical $canonical}
}catch{
    $failure=$_.Exception.Message
    if($CaptureClientCrashMemory -and $clientCrash -and $clientCrash.ConfirmedFatal -and $client -and !$client.Handle.HasExited){
        # The native fatal handler has already suspended its own threads. Retain
        # their memory through a read-only, nonsuspending attachment before the
        # normal exact-owned recovery closes the dialog. Never attach to Main.
        $reader=$null
        try{
            Assert-IW7BaseIdentity $client.Identity $client.Handle
            $originalTools=(Get-AppxPackage Microsoft.WinDbg).InstallLocation+'/amd64'
            $cdb=Resolve-IW7BasePath $CandidateRoot 'iw7-mod/capacity-tools/cdb.exe'
            if((Get-FileHash $cdb).Hash -cne '5F54ABAFCA3AE5638BBF807D402FABB350A64575C1DFA9FBFC7F5732DF5BEE67'){throw 'Reviewed scoped CDB identity differs.'}
            foreach($name in @('cdb.exe','dbgeng.dll','dbghelp.dll','dbgcore.dll','dbgmodel.dll')){
                $scoped=Join-Path (Split-Path $cdb) $name
                if((Get-FileHash $scoped).Hash -cne (Get-FileHash (Join-Path $originalTools $name)).Hash){throw 'Scoped debugger runtime differs from the retained Microsoft package.'}
            }
            $dump=Join-Path $case 'client-fatal-memory.local.dmp'
            if($dump.Contains('"') -or (Test-Path $dump)){throw 'Fresh literal crash capture required.'}
            $arguments='-pvr -p '+$client.Identity.PID+' -c ".dump /ma \"'+$dump+'\"; qd"'
            $reader=[IW7LabProcess]::StartOwned($cdb,$arguments,(Split-Path $cdb),"$case/crash-memory.stdout.log","$case/crash-memory.stderr.log",$client.DesktopName,$false,$false,$false,0)
            $readerIdentity=$reader.ReadIdentity()
            Add-IW7ResourceProcess -Token $lease.Token -ProcessId $readerIdentity.PID
            if(!$reader.WaitForExit(60000)){$reader.Terminate(3758096386);if(!$reader.WaitForExit(5000)){throw 'Crash reader closure unconfirmed.'};throw 'Crash memory capture timed out.'}
            if($reader.ExitCode -ne 0 -or !(Test-Path $dump)){throw 'Crash memory capture incomplete.'}
            Assert-IW7BaseIdentity $client.Identity $client.Handle
            @{Schema='iw7.capacity-client-fatal-memory/1';Client=$client.Identity;DebuggerSHA256=(Get-FileHash $cdb).Hash;DumpSHA256=(Get-FileHash $dump).Hash;Noninvasive=$true;Nonsuspending=$true;Utc=[datetime]::UtcNow.ToString('o')}|ConvertTo-Json -Depth 4|Set-Content "$case/crash-memory.receipt.local.json"
        }catch{
            $_.Exception.Message|Set-Content "$case/crash-memory.error.local.txt"
        }finally{if($reader){if(!$reader.HasExited){$reader.Terminate(3758096386);$null=$reader.WaitForExit(5000)};if($reader.HasExited){$reader.Dispose()}}}
    }
    if($session -and $server -and !$server.HasExited){
        try{$lateCrash=Get-IW7AgentNewCrash -CandidateRoot $CandidateRoot -Identity $identity -Before $crashBefore -OutputRoot $case -Cache $crashCache;if($lateCrash){$crash=$lateCrash}}catch{}
    }
}
finally{
    try{
        if($standardManifest -and $client -and $client.Handle -and !$client.Handle.HasExited){
            $id=$client.Handle.ReadIdentity()
            $null=Invoke-IW7OwnedStop -Handle $client.Handle -TimeoutMs 10000 -StopAction {$client.Handle.WriteCapacityLifecycle('stop',$id.Image,$id.CreationFileTime)}
        }
        if($client){
            Stop-IW7BaseClient $client -AgentMainBankIsolation $bankIsolation
            $clientManagedRestored=if($bankIsolation){$bankIsolation.Audits.Count -gt 0 -and @($bankIsolation.Audits|Where-Object {!$_.ManagedFilesRestored -or !$_.StaticMainUnchanged}).Count -eq 0}else{$client.Transaction.Restored}
            if(!$clientManagedRestored){throw 'Owned client restoration not verified.'}
        }
        if($session -and $standardManifest -and $client -and $clientManagedRestored -and !($crash -and $crash.ConfirmedFatal)){Wait-IW7CapacityClientDeparture $session}
        if($session -and $clientCrash -and $clientCrash.ConfirmedFatal -and $clientManagedRestored -and !($crash -and $crash.ConfirmedFatal)){
            Wait-IW7CapacityClientDeparture $session
        }
        if($clientImageTransaction){
            Assert-IW7BaseVacant $ClientGameRoot
            if($bankIsolation){
                $audit=Restore-IW7AgentMainTransaction $clientImageTransaction $bankIsolation
                if(!$audit.ManagedFilesRestored -or !$audit.StaticMainUnchanged){throw 'Owned client image restoration not verified.'}
            }else{Restore-IW7BaseTransaction $clientImageTransaction}
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
            # Normal closure still requires actual vacant UDP. A late dump may
            # separately qualify the exact fatal process while UDP is absent.
            $stopResult=Stop-IW7CapacityServerWithDiagnosis $session $crashBefore $case $crashCache
            if($session.PSObject.Properties['DiagnosedCrash']){$crash=$session.DiagnosedCrash}
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
        NativeText=$textCapture;RequestedAgentCapacity=$AgentCapacity;Canonical=$canonical;Crash=$crash;ClientCrash=$clientCrash;
        StockCopied=$false;BaseClientTouched=[bool]$ClientGameRoot;ClientRestored=$(if($client){$clientManagedRestored}else{$null});ClientStrictAuditRestored=$(if($client){$client.Transaction.Restored}else{$null});MainBankDeltasObserved=$(if($bankIsolation){@($bankIsolation.Audits|Where-Object MainBankDeltaObserved).Count -gt 0}else{$null});MainBankWriterAttributed=$false;WriterProven=$false;PatchReady=$false}|ConvertTo-Json -Depth 9|Set-Content (Join-Path $case 'result.local.json')
}
if($failure){throw "$failure ; evidence=$case"};if($cleanupError){throw "Cleanup pending: $cleanupError ; evidence=$case"};if($pageCaptureError){throw "Writer pages failed: $pageCaptureError ; evidence=$case"}
Write-Output "Capacity server probe restored=$restored evidence=$case"
