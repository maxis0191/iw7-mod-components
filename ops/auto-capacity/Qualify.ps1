param([Parameter(Mandatory)][string]$CandidateRoot,[Parameter(Mandatory)][string]$GameRoot,
      [Parameter(Mandatory)][string]$ServerPackage,[Parameter(Mandatory)][string]$ClientPackage,
      [Parameter(Mandatory)][string]$DeliveryRoot)
$ErrorActionPreference='Stop'
$ops=Split-Path $PSScriptRoot -Parent;$source=Split-Path $ops -Parent
. "$ops/Base-Client.Core.ps1"
. "$ops/Resource-Scheduler.Core.ps1"
. "$ops/Agent-LabCrash.Core.ps1"
$CandidateRoot=(Resolve-Path -LiteralPath $CandidateRoot).Path.TrimEnd('\','/')
$GameRoot=(Resolve-Path -LiteralPath $GameRoot).Path.TrimEnd('\','/')
$marker=Resolve-IW7BasePath $CandidateRoot 'iw7-mod/paris-isolated-lab.marker'
if(!(Test-Path -LiteralPath $marker) -or [IO.File]::ReadAllText($marker) -cne 'iw7-paris-isolated-lab-v1' -or
   (Test-Path (Join-Path $CandidateRoot 'STOCK-ASSETS-REMOVED.json'))){throw 'A retained complete marked private dedicated is required.'}
$serverManifest=Get-Content (Join-Path $ServerPackage 'build-manifest.json') -Raw|ConvertFrom-Json
$clientManifest=Get-Content (Join-Path $ClientPackage 'build-manifest.json') -Raw|ConvertFrom-Json
$delivery=Get-Content (Join-Path $DeliveryRoot 'delivery.json') -Raw|ConvertFrom-Json
if(!$serverManifest.IsolatedLab -or !$serverManifest.Debugger -or !$serverManifest.ServerModules -or
   $serverManifest.CapacityWireContract -cne '64-v2' -or
   (Get-FileHash (Join-Path $ServerPackage 'iw7-paris-voice.exe')).Hash -cne $serverManifest.SHA256){throw 'Qualified private capacity/protection server package required.'}
if(!$clientManifest.AutomaticProfiles -or !$clientManifest.Capacity64Capability -or
   $clientManifest.OwnerCheatsEnabled -ne $false -or
   (Get-FileHash (Join-Path $ClientPackage 'iw7-mod.exe')).Hash -cne $clientManifest.SHA256 -or
   $delivery.ClientSHA256 -cne $clientManifest.SHA256 -or
   (Get-FileHash (Join-Path $DeliveryRoot 'IW7-Paris.exe')).Hash -cne $delivery.SHA256){throw 'Exact one-file managed delivery and matching build required.'}
foreach($name in @('auto_capacity.cpp','auto_capacity.hpp','auto_capacity_policy.hpp')){
    $rows=@($clientManifest.AutoProfileOverlay.Added|Where-Object Path -CEQ ('src/client/component/'+$name))
    if($rows.Count -ne 1 -or (Get-FileHash "$source/src/native/$name").Hash -cne $rows[0].SHA256){throw 'Managed client source differs.'}
}
Assert-IW7BaseVacant $GameRoot
Assert-IW7AgentCandidateVacant -CandidateRoot $CandidateRoot -Ports @(27946,27947,27948)
if(Test-Path (Join-Path $GameRoot 'iw7-mod/server-profiles')){throw 'Fresh feature-cache qualification requires no existing server-profiles folder; preserve it.'}
$case=Join-Path $source ('runtime/auto-capacity/'+[datetime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff')+'-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($case)|Out-Null
$lease=$null;$serverTransaction=$null;$clientTransaction=$null;$servers=@();$clients=@();$bootstrap=$null;$failure=$null;$cleanup=$null;$restored=$false;$released=$false;$events=@();$passed=$false;$expandedProtected=$false;$standardProtected=$false
$password=[guid]::NewGuid().ToString('N');$secret=[guid]::NewGuid().ToString('N')+[guid]::NewGuid().ToString('N')
function Capture-Identity($Handle,[string]$Image,[string]$Hash) {
    $r=$Handle.ReadIdentity()
    [pscustomobject]@{PID=$r.PID;Image=$Image;SHA256=$Hash;CreatedUtc=[datetime]::FromFileTimeUtc($r.CreationFileTime).ToString('o')}
}
function Server-Info($Server) {
    Assert-IW7BaseIdentity $Server.Identity $Server.Handle
    if($Server.Handle.HasExited){throw 'Owned qualification dedicated exited.'}
    $bound=@(Get-NetUDPEndpoint -LocalPort $Server.Port -ErrorAction Stop|Where-Object OwningProcess -EQ $Server.Identity.PID)
    if($bound.Count -ne 1 -or $bound[0].LocalAddress -cne '127.0.0.1'){throw 'Qualification private UDP ownership changed.'}
    $info=& "$ops/Get-ServerInfo.ps1" -Port $Server.Port
    if($info.paris_capacity -cne $Server.Wire -or $info.mapname -cne 'cp_zmb' -or $info.sv_running -cne '1' -or $info.isPrivate -cne '1'){throw 'Qualification dedicated identity changed.'}
    $info
}
function Send-Private($Server,[string]$Command) {
    if($Command -cne 'quit'){throw 'Qualification lifecycle only permits quit.'}
    Assert-IW7BaseIdentity $Server.Identity $Server.Handle
    $udp=[Net.Sockets.UdpClient]::new()
    try{$udp.Connect('127.0.0.1',$Server.Port);$packet=[byte[]]([byte[]](255,255,255,255)+[Text.Encoding]::ASCII.GetBytes('rcon '+$secret+' '+$Command));$null=$udp.Send($packet,$packet.Length)}finally{$udp.Dispose()}
}
function Read-Events {
    $path=Join-Path $GameRoot 'iw7-mod/server-profiles/auto-capacity.events.jsonl'
    if(!(Test-Path -LiteralPath $path)){return @()}
    $stream=[IO.File]::Open($path,'Open','Read','ReadWrite');$reader=[IO.StreamReader]::new($stream)
    try{$text=$reader.ReadToEnd()}finally{$reader.Dispose();$stream.Dispose()}
    $end=$text.LastIndexOf("`n");if($end -lt 0){return @()}
    @($text.Substring(0,$end).Split("`n")|Where-Object Length -GT 0|ForEach-Object{$_|ConvertFrom-Json})
}
try {
    $lease=Enter-IW7ResourceLease -Scope $CandidateRoot -Kind Runtime -PhysicalBytes 14GB -CommitBytes 16GB -Owner 'Fresh one-file automatic 24 to64-v2 to24 real-engine client' -RequireNewLease
    Assert-IW7BaseVacant $GameRoot
    Assert-IW7AgentCandidateVacant -CandidateRoot $CandidateRoot -Ports @(27946,27947,27948)
    $stage=[pscustomobject]@{GameRoot=$CandidateRoot;MutableFiles=@('iw7-auto-expanded-server.exe','iw7-auto-standard-server.exe','iw7-auto-onboard.exe','iw7-mod/auto_expanded.cfg','iw7-mod/auto_standard.cfg');ProfileDirectory='iw7-mod/players2';ProfileDirectories=@('iw7-mod/custom_scripts/cp','iw7-mod/players2','iw7-mod/lab-appdata','mods/paris_beta/bank','mods/paris_beta/stats','auto-client-cache')}
    $serverTransaction=Save-IW7BaseTransaction $stage (Join-Path $case 'server-backup')
    $stage=[pscustomobject]@{GameRoot=$GameRoot;MutableFiles=@();ProfileDirectory='iw7-mod/players2';ProfileDirectories=@('iw7-mod/players2','iw7-mod/server-profiles')}
    $clientTransaction=Save-IW7BaseTransaction $stage (Join-Path $case 'client-backup')
    foreach($f in $serverTransaction.Files|Where-Object {$_.Path.StartsWith('iw7-mod/custom_scripts/cp/') -and $_.Path -match '\.(gsc|gscbin)$'}){Remove-Item -LiteralPath (Resolve-IW7BasePath $CandidateRoot $f.Path)}
    Copy-Item -LiteralPath "$source/tests/fixtures/capacity_pool.gsc" -Destination (Resolve-IW7BasePath $CandidateRoot 'iw7-mod/custom_scripts/cp/capacity_pool.gsc')
    if(!('IW7LabProcess' -as [type])){Add-Type -Path "$ops/native/LabProcess.cs"}
    foreach($role in @(@{Name='expanded';Port=27946;Wire='64-v2';Capacity=64;Flags=' -paris-capacity-64'},@{Name='standard';Port=27947;Wire='24';Capacity=24;Flags=''})) {
        $image=Resolve-IW7BasePath $CandidateRoot ('iw7-auto-'+$role.Name+'-server.exe')
        Copy-Item -LiteralPath (Join-Path $ServerPackage 'iw7-paris-voice.exe') -Destination $image
        $cfg=@"
set sv_hostname "Private automatic profile qualification"
set sv_maxclients 4
set g_gametype "zombie"
set scr_zombie_maxagents $($role.Capacity)
set paris_isolated_lab 1
set paris_capacity_pool_probe 0
set paris_capacity_client_probe 1
set sv_lanOnly 1
set net_ip 127.0.0.1
set g_password "$password"
set rcon_password "$secret"
set fs_game ""
set sv_cheats 0
set g_inactivity 0
"@
        [IO.File]::WriteAllText((Join-Path $CandidateRoot ('iw7-mod/auto_'+$role.Name+'.cfg')),$cfg,[Text.UTF8Encoding]::new($false))
        $log=Join-Path $case ($role.Name+'.stdout.log')
        $args="-nosteam -noupdate -dedicated -cpMode -stdout -allow_root_io -paris-isolated-lab -paris-debugger -paris-server-test$($role.Flags) +set sv_lanOnly 1 +set net_ip 127.0.0.1 +set net_port $($role.Port) +exec auto_$($role.Name).cfg +map cp_zmb"
        $handle=[IW7LabProcess]::StartOwned($image,$args,$CandidateRoot,$log,(Join-Path $case ($role.Name+'.stderr.log')),('IW7ParisLab_'+[guid]::NewGuid().ToString('N')),$false)
        $server=[pscustomobject]@{Handle=$handle;Identity=(Capture-Identity $handle $image $serverManifest.SHA256);Port=$role.Port;Wire=$role.Wire;Log=$log}
        $servers+=$server;Add-IW7ResourceProcess -Token $lease.Token -ProcessId $server.Identity.PID
        $deadline=[datetime]::UtcNow.AddSeconds(150);$ready=$false
        do {
            Assert-IW7BaseIdentity $server.Identity $handle;if($handle.HasExited){throw 'Private server failed during startup.'}
            try{$info=Server-Info $server;$ready=$info.clients -ceq '0'}catch{$ready=$false}
            if(!$ready){Start-Sleep -Milliseconds 500}
        }until($ready -or [datetime]::UtcNow -ge $deadline)
        if(!$ready){throw 'Private server did not become ready.'}
    }
    $image=Resolve-IW7BasePath $CandidateRoot 'iw7-auto-onboard.exe';Copy-Item (Join-Path $DeliveryRoot 'IW7-Paris.exe') $image
    $cache=Join-Path $CandidateRoot 'auto-client-cache'
    $args='--game-root "'+$GameRoot+'" --connect 127.0.0.1:27946 --qualification-cache "'+$cache+'" --qualification-password '+$password+' --qualification-return 127.0.0.1:27947'
    $bootstrap=[IW7LabProcess]::StartOwned($image,$args,$GameRoot,(Join-Path $case 'onboard.stdout.log'),(Join-Path $case 'onboard.stderr.log'),('IW7ParisLab_'+[guid]::NewGuid().ToString('N')),$false)
    $bootstrapIdentity=Capture-Identity $bootstrap $image $delivery.SHA256
    Add-IW7ResourceProcess -Token $lease.Token -ProcessId $bootstrapIdentity.PID
    $deadline=[datetime]::UtcNow.AddMinutes(8);$seen=@{};$bootstrapClientSeen=$false
    do {
        foreach($server in $servers){$null=Server-Info $server}
        $initial=Join-Path $cache 'initial-client.json'
        if(!$bootstrapClientSeen -and (Test-Path -LiteralPath $initial)) {
            $r=Get-Content -LiteralPath $initial -Raw|ConvertFrom-Json
            if($r.sha256 -cne $clientManifest.SHA256){throw 'Onboarding installed another client.'}
            $clientImage=Join-Path $cache ($clientManifest.SHA256+'/iw7-paris-auto.exe')
            $h=[IW7LabProcess]::OpenOwned($r.pid,$clientImage,$r.creation)
            $identity=Capture-Identity $h $clientImage $clientManifest.SHA256
            $clients+=@{Handle=$h;Identity=$identity};$seen[[int]$r.pid]=$true;$bootstrapClientSeen=$true
            Add-IW7ResourceProcess -Token $lease.Token -ProcessId $identity.PID
        }
        $events=@(Read-Events)
        foreach($e in @($events|Where-Object event -CEQ 'handoff')) {
            if(!$seen.ContainsKey([int]$e.pid)){throw 'Unknown parent in profile handoff.'}
            if(!$seen.ContainsKey([int]$e.child)) {
                $h=[IW7LabProcess]::OpenOwned([int]$e.child,$clientImage,[long]$e.child_creation)
                $identity=Capture-Identity $h $clientImage $clientManifest.SHA256
                $clients+=@{Handle=$h;Identity=$identity};$seen[[int]$e.child]=$true
                Add-IW7ResourceProcess -Token $lease.Token -ProcessId $identity.PID
            }
        }
        foreach($client in $clients){Assert-IW7BaseIdentity $client.Identity $client.Handle}
        $active=@($events|Where-Object event -CEQ 'active')
        $expandedProtected=(Read-IW7BaseLog $servers[0].Log) -match '\[Paris capacity heartbeat\].*protected=1;.*godmode=1; inactivity=0; cheats=0; failed=0'
        $standardProtected=(Read-IW7BaseLog $servers[1].Log) -match '\[Paris capacity heartbeat\].*protected=1;.*godmode=1; inactivity=0; cheats=0; failed=0'
        $passed=@($active|Where-Object wire -CEQ '64-v2').Count -ge 1 -and @($active|Where-Object wire -CEQ '24').Count -ge 1 -and $expandedProtected -and $standardProtected -and $clients.Count -eq 3
        if(!$passed){Start-Sleep -Milliseconds 250}
    }until($passed -or [datetime]::UtcNow -ge $deadline)
    if(!$passed){throw 'Fresh-cache automatic 24/64-v2/24 protected round trip did not complete.'}
    if(!($clients[0].Handle.HasExited -and $clients[1].Handle.HasExited)){throw 'Prior client process closure was not confirmed.'}
    $events|ConvertTo-Json -Depth 5|Set-Content (Join-Path $case 'events.local.json')
}catch{$failure=$_.Exception.Message}
finally {
    try {
        foreach($client in @($clients|Sort-Object {$_.Identity.PID} -Descending)) {
            if(!$client.Handle.HasExited) {
                Assert-IW7BaseIdentity $client.Identity $client.Handle
                & python -B "$ops/Send-OwnedConsole.py" $client.Identity.PID quit
                if($LASTEXITCODE -or !$client.Handle.WaitForExit(15000)){throw 'Owned client quit not confirmed; preserve transaction and lease.'}
            }
        }
        if($bootstrap -and !$bootstrap.WaitForExit(15000)){throw 'Onboarding process exit not confirmed.'}
        foreach($server in $servers) {
            if(!$server.Handle.HasExited) {
                $since=$null;$deadline=[datetime]::UtcNow.AddSeconds(180)
                do {
                    $info=Server-Info $server
                    if($info.clients -ceq '0'){if(!$since){$since=[datetime]::UtcNow}}else{$since=$null}
                    if($since -and ([datetime]::UtcNow-$since).TotalSeconds -ge 30){break}
                    Start-Sleep -Seconds 1
                }while([datetime]::UtcNow -lt $deadline)
                if(!$since -or ([datetime]::UtcNow-$since).TotalSeconds -lt 30){throw 'Fresh continuous vacancy not confirmed.'}
                Send-Private $server quit
                if(!$server.Handle.WaitForExit(15000)){throw 'Owned dedicated quit not confirmed.'}
            }
        }
        if($lease){
            Assert-IW7AgentCandidateVacant -CandidateRoot $CandidateRoot -Ports @(27946,27947,27948)
            Assert-IW7BaseVacant $GameRoot
            if($serverTransaction){Restore-IW7BaseTransaction $serverTransaction}
            if($clientTransaction){Restore-IW7BaseTransaction $clientTransaction}
            $restored=$true
            Exit-IW7ResourceLease -Token $lease.Token;$released=$true
        }
    }catch{$cleanup=$_.Exception.Message}
    foreach($client in $clients){if($client.Handle.HasExited){$client.Handle.Dispose()}}
    foreach($server in $servers){if($server.Handle.HasExited){$server.Handle.Dispose()}}
    if($bootstrap -and $bootstrap.HasExited){$bootstrap.Dispose()}
    @{Schema='iw7.automatic-capacity-qualification/1';Passed=$passed;Failure=$failure;CleanupError=$cleanup;Restored=$restored;LeaseReleased=$released;NativeClientSHA256=$clientManifest.SHA256;DeliverySHA256=$delivery.SHA256;ClientProcesses=$clients.Count;FeatureCacheInitiallyAbsent=$true;ExpandedProtected=$expandedProtected;StandardProtected=$standardProtected;MainDeployed=$false;InitialCommunityClientUpdateStillRequired=$true;Output=$case}|ConvertTo-Json -Depth 5|Set-Content (Join-Path $case 'result.local.json')
}
if(!$passed -or $failure -or $cleanup){throw "Automatic profile qualification failed: $failure; cleanup=$cleanup; evidence=$case"}
"Fresh one-file onboarding and automatic protected 24/64-v2/24 round trip PASS; restored; evidence=$case"
