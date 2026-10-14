param(
    [Parameter(Mandatory)][string]$HelperRoot,
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$HelperReceiptSHA256,
    [Parameter(Mandatory)][string]$NativeSourceRoot,
    [Parameter(Mandatory)][string]$PackageRoot,
    [Parameter(Mandatory)][string]$CandidateRoot,
    [Parameter(Mandatory)][string]$MainRoot,
    [Parameter(Mandatory)][string]$OutputRoot,
    [switch]$Run
)
$ErrorActionPreference='Stop'
$selfRoot=Split-Path $PSScriptRoot -Parent
$expectedCommit='56a2ef7cab451830cc506449291e748d5f9ff7b1'
$expectedImage='B78B6020C1E0AFDD9E548B81FC3910C68477C253ABFB43EDE159AED36D9752CE'
$expectedManifest='CA4249B2FCF4EB4C6BD11F0A6434C34B0FE1A10656039A444101115A3CE97526'
$expectedSymbols='6961C40B11196ED20F48A5A4F331CB6A526E7CE2B4D4D81A2AC019E51BB48A61'
$helperRoot=(Resolve-Path -LiteralPath $HelperRoot).Path.TrimEnd('\','/')
$nativeSourceRoot=(Resolve-Path -LiteralPath $NativeSourceRoot).Path.TrimEnd('\','/')
$packageRoot=(Resolve-Path -LiteralPath $PackageRoot).Path.TrimEnd('\','/')
$candidateRoot=(Resolve-Path -LiteralPath $CandidateRoot).Path.TrimEnd('\','/')
$mainRoot=(Resolve-Path -LiteralPath $MainRoot).Path.TrimEnd('\','/')
$outputRoot=[IO.Path]::GetFullPath($OutputRoot)
$helperReceipt=Join-Path $helperRoot 'source-workspace.json'
if((Get-Item -LiteralPath $helperReceipt).Length -gt 1MB){throw 'Source receipt exceeds the bounded metadata contract.'}
if((Get-FileHash -LiteralPath $helperReceipt).Hash -ine $HelperReceiptSHA256){throw 'Helper source receipt changed.'}
$helperIdentity=Get-Content -LiteralPath $helperReceipt -Raw | ConvertFrom-Json
if($helperIdentity.schema -cne 'iw7.source-workspace/1' -or $helperIdentity.product -cne 'iw7-paris-server' -or
    $helperIdentity.revisions.'iw7-mod-components' -cne '303c44d92e23579a2142f46b9f65ce2e62a1dee2'){
    throw 'Explicit prepared server helpers with the reviewed native303 contract required.'
}
# Own reviewed path helpers have no import-time native or process action.
. "$PSScriptRoot/Base-Client.Core.ps1"
. "$PSScriptRoot/Collision-Probe.Core.ps1"
foreach($root in @($candidateRoot,$mainRoot,$helperRoot,$nativeSourceRoot,$packageRoot,$outputRoot)){
    $null=Resolve-IW7BasePath $root 'collision-path-check'
}
foreach($root in @($mainRoot,$candidateRoot)){
    foreach($other in @($helperRoot,$nativeSourceRoot,$packageRoot,$outputRoot)){
        if($other -ieq $root -or $other.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase) -or
            $root.StartsWith($other+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Runtime, evidence and source roots must be independent.'}
    }
}
foreach($root in @($selfRoot,$helperRoot,$nativeSourceRoot,$packageRoot)){
    if($outputRoot -ieq $root -or $outputRoot.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase) -or
        $root.StartsWith($outputRoot+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Evidence must be outside every source/package root.'}
}
if($mainRoot -ieq $candidateRoot -or $mainRoot.StartsWith($candidateRoot+'\',[StringComparison]::OrdinalIgnoreCase) -or
    $candidateRoot.StartsWith($mainRoot+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Main and candidate roots must be independent.'}
if(Test-Path -LiteralPath $outputRoot){throw 'A fresh output root is required.'}
$manifestPath=Resolve-IW7BasePath $packageRoot 'build-manifest.json'
if((Get-Item -LiteralPath $manifestPath).Length -gt 1MB){throw 'Native manifest exceeds the bounded metadata contract.'}
if((Get-FileHash -LiteralPath $manifestPath).Hash -cne $expectedManifest){throw 'Only the separately compiled B78 package is qualified for this route.'}
$manifest=Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if($manifest.ProjectCommit -cne $expectedCommit -or $manifest.ProjectDirty -ne $false -or
    $manifest.CollisionProvider -isnot [bool] -or !$manifest.CollisionProvider -or $manifest.SourceHashes.Count -ne 36){throw 'Compiled collision source identity differs.'}
$fixture=Resolve-IW7BasePath $selfRoot 'tests/fixtures/collision_zero_client_probe.gsc'
$plan=[ordered]@{Schema='iw7.collision-probe/1';Mode=$(if($Run){'Run'}else{'Plan'});PlannedClients=0;
    HelperRoot=$helperRoot;HelperReceiptSHA256=$HelperReceiptSHA256;HelperRevisions=$helperIdentity.revisions;
    NativeSourceRoot=$nativeSourceRoot;PackageRoot=$packageRoot;CompiledCommit=$expectedCommit;ExecutableSHA256=$expectedImage;
    ManifestSHA256=$expectedManifest;SymbolsSHA256=$expectedSymbols;SourceCount=36;CollisionProvider=$true;
    CandidateRoot=$candidateRoot;MainRoot=$mainRoot;ServerPort=27116;FixtureSHA256=(Get-FileHash -LiteralPath $fixture).Hash;
    World=0;Minimum=@(-256,-192,4080);Maximum=@(256,192,4096);ClientActivation=$false;StockCopied=$false;MainDeployed=$false}
if(!$Run){[pscustomobject]$plan | ConvertTo-Json -Depth 8;return}
if(!(Test-Path -LiteralPath (Join-Path $selfRoot 'source-workspace.json'))){throw 'Run this reviewed operation from its freshly prepared source package.'}
. "$PSScriptRoot/Resource-Scheduler.Core.ps1"
$server=$null;$identity=$null;$imageGuard=$null;$lease=$null;$transaction=$null;$mainTransaction=$null;$isolation=$null
$failure=$null;$measurement=$null;$stop=$null;$restored=$false;$exitCode=$null;$crash=$null;$crashCache=@{}
$closure=@{Restored=$false;Stop=$null;Crash=$null}
function Assert-CollisionOriginal {
    if(!$server -or $server.HasExited){throw 'Original collision dedicated is no longer alive.'}
    $actual=$server.ReadIdentity()
    if($actual.PID -ne $identity.PID -or $actual.Image -ine $identity.Image -or $actual.CreationFileTime -ne $identity.CreationFileTime){throw 'Original collision kernel identity changed.'}
}
function Read-CollisionPrivateInfo([bool]$RequireProtocol2=$true) {
    Assert-CollisionOriginal
    $before=Get-IW7ProtocolProbeEndpoint $identity $server 27116
    $info=& (Join-Path $helperRoot 'ops/Get-ServerInfo.ps1') -Address '127.0.0.1' -Port 27116
    $null=Get-IW7ProtocolProbeEndpoint $identity $server 27116
    if($info.clients -cne '0' -or ($RequireProtocol2 -and ($info.protocol -cne '2' -or $info.isPrivate -cne '1'))){throw 'Actual private zero-client game protocol2 required.'}
    [pscustomobject]@{Info=$info;Endpoint=$before;ObservedUtc=[datetime]::UtcNow.ToString('o')}
}
try{
    $lease=Enter-IW7ResourceLease -Scope $candidateRoot -Kind Runtime -PhysicalBytes 4GB -CommitBytes 6GB -Owner 'Original box: dedicated only, zero clients'
    [IO.Directory]::CreateDirectory($outputRoot)|Out-Null
    [pscustomobject]@{Host=$lease.OwnerIdentity;LeaseToken=$lease.Token;MemoryObservation=$lease.MemoryObservation;
        PhysicalEstimate=$lease.PhysicalBytes;CommitEstimate=$lease.CommitBytes;PlannedClients=0}|
        ConvertTo-Json -Depth 7|Set-Content -LiteralPath (Join-Path $outputRoot 'host-and-lease.local.json')
    $plan|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $outputRoot 'plan.local.json')
    foreach($root in @($selfRoot,$helperRoot,$nativeSourceRoot)){
        & python -B (Join-Path $root 'ops/source_workspace.py') --output $root --verify | Out-Null
        if($LASTEXITCODE){throw 'Prepared source input changed.'}
    }
    if((Get-FileHash -LiteralPath $helperReceipt).Hash -ine $HelperReceiptSHA256){throw 'Helper receipt changed under admission.'}
    # Execute the external helper definitions only after verifying their sealed
    # source package. Their existing lifecycle remains the sole implementation.
    foreach($file in @('Base-Client.Core.ps1','Lab-Lifecycle.ps1','Agent-Scenario.Core.ps1','Agent-LabCrash.Core.ps1',
        'modding/Agent-Vertical.Runtime.ps1','modding/Agent-NativePackage.Core.ps1','modding/Agent-Restoration.Core.ps1','modding/Agent-ProtocolProbe.ps1')){
        . (Join-Path $helperRoot ('ops/'+$file))
    }
    $native=Read-IW7AgentNativePackage $packageRoot $nativeSourceRoot $false
    if($native.Evidence.ExecutableSHA256 -cne $expectedImage -or $native.Evidence.LineEndingVariantCount -ne 0 -or !$native.Evidence.CollisionProvider){throw 'All36 raw compiled source hashes required.'}
    $symbols=Resolve-IW7BasePath $nativeSourceRoot ('runtime/voice-symbols/'+$expectedImage+'/iw7-mod.pdb')
    if((Get-FileHash -LiteralPath $symbols).Hash -cne $expectedSymbols){throw 'Matching compiled symbols changed.'}
    $native.Evidence|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $outputRoot 'native-under-lease.local.json')
    Assert-IW7AgentCandidateVacant -CandidateRoot $candidateRoot -Ports @(27116)
    if((Get-Content -LiteralPath (Resolve-IW7BasePath $candidateRoot 'iw7-mod/paris-isolated-lab.marker') -Raw).Trim() -cne 'iw7-paris-isolated-lab-v1' -or
        !(Test-Path -LiteralPath (Resolve-IW7BasePath $candidateRoot 'iw7_ship.exe')) -or
        (Test-Path -LiteralPath (Resolve-IW7BasePath $candidateRoot 'STOCK-ASSETS-REMOVED.json'))){throw 'Complete retained private dedicated required.'}
    $isolation=New-IW7AgentBankIsolation $mainRoot $candidateRoot
    $mainTransaction=Save-IW7BaseTransaction ([pscustomobject]@{GameRoot=$mainRoot;MutableFiles=@();ProfileDirectory='iw7-mod/players2';ProfileDirectories=@()}) (Join-Path $outputRoot 'main-audit')
    $imageRelative='iw7-paris-collision-probe.exe';$configRelative='iw7-mod/server_collision_test.cfg'
    $scriptRelative='iw7-mod/custom_scripts/cp/collision_zero_client_probe.gsc'
    $transaction=Save-IW7BaseTransaction ([pscustomobject]@{GameRoot=$candidateRoot;MutableFiles=@($imageRelative,$configRelative,$scriptRelative);
        ProfileDirectory='iw7-mod/players2';ProfileDirectories=@('iw7-mod/custom_scripts/cp','iw7-mod/players2','iw7-mod/lab-appdata','mods/paris_beta/bank')}) (Join-Path $outputRoot 'candidate-backup')
    $cp=Resolve-IW7BasePath $candidateRoot 'iw7-mod/custom_scripts/cp'
    [IO.Directory]::CreateDirectory($cp)|Out-Null
    foreach($file in @(Get-ChildItem -LiteralPath $cp -File|Where-Object Extension -in @('.gsc','.gscbin'))){Remove-Item -LiteralPath $file.FullName}
    Copy-Item -LiteralPath $fixture -Destination (Resolve-IW7BasePath $candidateRoot $scriptRelative)
    $serverImage=Resolve-IW7BasePath $candidateRoot $imageRelative
    Copy-Item -LiteralPath (Resolve-IW7BasePath $packageRoot 'iw7-paris-voice.exe') -Destination $serverImage
    $imageGuard=[IO.File]::Open($serverImage,'Open','Read','Read')
    if([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($imageGuard)) -cne $expectedImage){throw 'Staged native changed.'}
    $token=[guid]::NewGuid().ToString('N');$password=[guid]::NewGuid().ToString('N')
    $config=@"
set net_ip 127.0.0.1
set g_password "$password"
set sv_lanOnly 1
set fs_game ""
set g_gametype zombie
set g_inactivity 0
set sv_cheats 0
set developer_script 1
set paris_isolated_lab 1
set paris_collision_test 1
set paris_collision_probe_arm 0
set paris_collision_probe_token "$token"
set paris_mod_voice 0
set paris_mod_doom 0
set paris_mod_rush 0
set paris_mod_loadout 0
set paris_join_loadout_test 0
set sv_mapRotation "gametype zombie map cp_zmb"
set sv_mapRotationCurrent ""
"@
    [IO.File]::WriteAllText((Resolve-IW7BasePath $candidateRoot $configRelative),$config,[Text.UTF8Encoding]::new($false))
    if(!('IW7LabProcess' -as [type])){Add-Type -Path (Join-Path $helperRoot 'ops/native/LabProcess.cs')}
    $stdout=Join-Path $outputRoot 'server.stdout.log';$stderr=Join-Path $outputRoot 'server.stderr.log'
    $dumps=Resolve-IW7BasePath $candidateRoot 'minidumps';$beforeDumps=@()
    if(Test-Path -LiteralPath $dumps){$beforeDumps=@(Get-ChildItem -LiteralPath $dumps -Filter '*.zip' -File|ForEach-Object FullName)}
    $desktop='IW7ParisLab_'+[guid]::NewGuid().ToString('N')
    $arguments='-dedicated -allow_root_io -noupdate -nosteam -cpMode -stdout -paris-server-test -paris-isolated-lab -paris-collision-provider +set sv_lanOnly 1 +set net_ip 127.0.0.1 +set net_port 27116 +exec server_collision_test.cfg +map_rotate'
    $server=[IW7LabProcess]::StartOwned($serverImage,$arguments,$candidateRoot,$stdout,$stderr,$desktop,$false)
    [pscustomobject]@{PID=$server.Id;Image=$serverImage;LeaseToken=$lease.Token;Desktop=$desktop;Arguments=$arguments}|
        ConvertTo-Json|Set-Content -LiteralPath (Join-Path $outputRoot 'server.launch.local.json')
    $kernel=$server.ReadIdentity()
    $identity=[pscustomobject]@{PID=$kernel.PID;Image=$kernel.Image;CreationFileTime=$kernel.CreationFileTime;
        CreatedUtc=[datetime]::FromFileTimeUtc($kernel.CreationFileTime).ToString('o');SHA256=$expectedImage;Stdout=$stdout;DesktopName=$desktop}
    $identity|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $outputRoot 'server.identity.local.json')
    $null=Add-IW7ResourceProcess -Token $lease.Token -ProcessId $server.Id
    $deadline=[Environment]::TickCount64+120000;$private=$null;$ready=$null
    do{
        Assert-CollisionOriginal
        $crash=Get-IW7AgentNewCrash -CandidateRoot $candidateRoot -Identity $identity -Before $beforeDumps -OutputRoot $outputRoot -Cache $crashCache
        if($crash -and $crash.ConfirmedFatal){throw 'Fresh correlated fatal dedicated exception.'}
        $log=Read-IW7BaseLog $stdout
        if($log -match '(?i)script compile error|unknown function|MAX_CANONICAL_STRING'){throw 'Fresh collision script startup failed.'}
        $ready=Read-IW7CollisionProbeResult $log $token
        $private=$null
        try{$observation=Read-CollisionPrivateInfo;if($observation.Info.sv_running -ceq '1' -and $observation.Info.mapname -ceq 'cp_zmb' -and
            (Test-IW7AgentPrivacyObservation $log $observation.Info)){$private=$observation}}catch{if($server.HasExited){throw}}
        if($ready.Ready -and $private){break}
        Start-Sleep -Milliseconds 250
    }while([Environment]::TickCount64 -lt $deadline)
    if(!$private -or !$ready.Ready){throw 'Fresh private protocol2 and collision READY were not established.'}
    $private|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $outputRoot 'private-protocol2.local.json')
    $null=Read-CollisionPrivateInfo
    $armTick=[Environment]::TickCount64
    & python (Join-Path $helperRoot 'ops/Send-ServerCommand.py') --module-client $server.Id 'set paris_collision_probe_arm 1' | Out-Null
    if($LASTEXITCODE){throw 'Owned arm dispatch failed.'}
    $deadline=[Environment]::TickCount64+15000
    do{
        Assert-CollisionOriginal;$null=Read-CollisionPrivateInfo
        $measurement=Read-IW7CollisionProbeResult (Read-IW7BaseLog $stdout) $token
        if($measurement.Complete){break}
        Start-Sleep -Milliseconds 100
    }while([Environment]::TickCount64 -lt $deadline)
    if(!$measurement.Complete){throw 'Collision measurements incomplete.'}
    [pscustomobject]@{ArmRequestedTick=$armTick;Token=$token;Measurements=$measurement}|ConvertTo-Json -Depth 7|Set-Content -LiteralPath (Join-Path $outputRoot 'measurements.local.json')
}catch{$failure=$_.Exception.Message}
finally{
    if($lease){
        $closure.Crash=$crash
        # Repeat the existing guarded stages on a transient failure. Keep this
        # original host, handle, backups and lease alive on uncertain closure.
        do{
            try{
                Invoke-IW7AgentCleanupStages -StopClient {} -StopCandidate {
                    if($server -and !$server.HasExited){
                        Assert-CollisionOriginal
                        if(!$closure.Crash -or !$closure.Crash.ConfirmedFatal){$observedCrash=Get-IW7AgentNewCrash -CandidateRoot $candidateRoot -Identity $identity -Before $beforeDumps -OutputRoot $outputRoot -Cache $crashCache;if($observedCrash){$closure.Crash=$observedCrash}}
                        if($closure.Crash -and $closure.Crash.ConfirmedFatal -and (Read-IW7BaseLog $identity.Stdout) -notmatch 'Setting client \d+ XUID'){
                            foreach($entry in $transaction.Files|Where-Object {$_.Existed -and $_.Path.StartsWith('mods/paris_beta/bank/')}){
                                if((Get-FileHash -LiteralPath (Resolve-IW7BasePath $transaction.BackupRoot $entry.Path)).Hash -cne $entry.SHA256){throw 'Fatal recovery bank backup changed.'}
                            }
                            Assert-CollisionOriginal;$server.Terminate(3758096385)
                            if(!$server.WaitForExit(5000)){throw 'Exact fatal dedicated closure unconfirmed.'}
                            $closure.Crash|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $outputRoot 'fatal-recovery.local.json')
                        }else{
                            $emptySince=$null;$stopDeadline=[Environment]::TickCount64+70000
                            do{
                                $null=Read-CollisionPrivateInfo $false
                                if(!$emptySince){$emptySince=[Environment]::TickCount64}
                                if([Environment]::TickCount64-$emptySince -ge 30000){break}
                                if([Environment]::TickCount64 -ge $stopDeadline){throw 'Continuous empty UDP stop window not established.'}
                                Start-Sleep -Milliseconds 1000
                            }while($true)
                            Assert-CollisionOriginal
                            $closure.Stop=Invoke-IW7OwnedStop -Handle $server -TimeoutMs 10000 -StopAction {
                                & python (Join-Path $helperRoot 'ops/Send-ServerCommand.py') --module-client $server.Id 'quit'|Out-Null
                                if($LASTEXITCODE){throw 'Owned dedicated quit failed.'}
                            }
                        }
                    }
                } -AssertClosed {
                    if($server -and !$server.HasExited){throw 'Original dedicated still alive.'}
                    Assert-IW7AgentCandidateVacant -CandidateRoot $candidateRoot -Ports @(27116)
                    if($isolation){$null=New-IW7AgentBankIsolation $mainRoot $candidateRoot}
                    if($imageGuard){$imageGuard.Dispose()}
                } -RestoreOwned @({if($transaction){Restore-IW7BaseTransaction $transaction}},{
                    if($mainTransaction){$null=Restore-IW7AgentMainTransaction $mainTransaction $isolation}
                }) -Release {Exit-IW7ResourceLease -Token $lease.Token;$closure.Restored=$true}
            }catch{
                $pending=$_.Exception.Message
                Write-Warning "Collision cleanup pending; original host $PID and lease retained: $pending"
                if(Test-Path -LiteralPath $outputRoot){[pscustomobject]@{HostPID=$PID;Token=$lease.Token;Pending=$pending}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $outputRoot 'cleanup-pending.local.json')}
                Start-Sleep -Seconds 5
            }
        }while(!$closure.Restored)
    }
    if($server){$exitCode=$server.ExitCode;$server.Dispose()}
}
$restored=$closure.Restored;$stop=$closure.Stop
$passed=!$failure -and $measurement -and $measurement.Complete -and $restored -and $exitCode -eq 0 -and $stop -and $stop.Kind -ceq 'clean'
$result=[pscustomobject]@{Schema='iw7.collision-probe-result/1';Passed=[bool]$passed;Failure=$failure;Measurements=$measurement;
    ServerExitCode=$exitCode;Stop=$stop;ManagedRestored=$restored;LeaseReleased=$restored;OriginalHostExitObserved=$false;
    Host=$lease.OwnerIdentity;LeaseToken=$lease.Token;Server=$identity;
    CompiledCommit=$expectedCommit;NativeSHA256=$expectedImage;ClientStarted=$false;MainDeployed=$false;OwnerAccepted=$false;OutputRoot=$outputRoot}
$result|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $outputRoot 'result.local.json')
$result|ConvertTo-Json -Depth 8
if(!$passed){throw 'Collision probe failed; retained measurements and cleanup facts remain separate.'}
