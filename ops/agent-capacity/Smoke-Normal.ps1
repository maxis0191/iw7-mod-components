param([Parameter(Mandatory)][string]$CandidateRoot,[Parameter(Mandatory)][string]$PackageRoot,
      [ValidateRange(27100,27999)][int]$ServerPort=27946)
$ErrorActionPreference='Stop'
$ops=Split-Path $PSScriptRoot -Parent;$source=Split-Path $ops -Parent
. "$ops/Base-Client.Core.ps1"
. "$ops/Resource-Scheduler.Core.ps1"
. "$ops/Agent-LabCrash.Core.ps1"
$CandidateRoot=(Resolve-Path -LiteralPath $CandidateRoot).Path.TrimEnd('\','/')
$marker=Resolve-IW7BasePath $CandidateRoot 'iw7-mod/paris-isolated-lab.marker'
if(!(Test-Path $marker) -or [IO.File]::ReadAllText($marker) -cne 'iw7-paris-isolated-lab-v1' -or
   (Test-Path (Join-Path $CandidateRoot 'STOCK-ASSETS-REMOVED.json'))){throw 'Retained complete marked dedicated required.'}
$m=Get-Content (Join-Path $PackageRoot 'build-manifest.json') -Raw|ConvertFrom-Json
$binary=Join-Path $PackageRoot 'iw7-paris-voice.exe'
if($m.BuildProfile -cne 'server-only' -or $m.ServerModules -ne $true -or $m.IsolatedLab -ne $false -or
   $m.Debugger -ne $false -or $m.Capacity64Production -ne $true -or $m.CapacityWireContract -cne '64-v1' -or
   $m.CapacityPeerOverlay.Schema -cne 'iw7.capacity-peer-overlay/1' -or
   (Get-FileHash -LiteralPath $binary).Hash -cne $m.SHA256){throw 'Normal capacity package provenance differs.'}
foreach($f in @('paris_agent_capacity.cpp','paris_agent_capacity.hpp')){
    $row=@($m.SourceHashes|Where-Object File -CEQ $f)
    if($row.Count -ne 1 -or (Get-FileHash (Join-Path $source ('src/native/'+$f))).Hash -cne $row[0].SHA256){throw 'Normal capacity Source differs.'}
}
foreach($f in $m.CapacityPeerOverlay.Files){
    $row=@($m.NativeSourceHashes|Where-Object File -CEQ ('src/client/component/'+$f.Name))
    if($row.Count -ne 1 -or $row[0].SHA256 -cne $f.AfterSHA256){throw 'Normal admission source binding differs.'}
}
$case=Join-Path $source ('runtime/agent-capacity/normal-smoke-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($case)|Out-Null
$lease=$null;$transaction=$null;$server=$null;$identity=$null;$restored=$false;$released=$false;$failure=$null;$cleanup=$null;$checks=@()
function Assert-NormalOwned {
    Assert-IW7BaseIdentity $identity $server
    if($server.HasExited){throw 'Owned normal server exited.'}
    $leases=@((Get-IW7ResourceStatus).Leases|Where-Object Token -CEQ $lease.Token)
    $registered=@($leases.Processes|Where-Object PID -EQ $identity.PID)
    if($leases.Count -ne 1 -or $leases[0].Scope -ine $CandidateRoot -or $registered.Count -ne 1 -or
       $registered[0].Image -ine $identity.Image){throw 'Normal smoke registration differs.'}
    $endpoint=@(Get-NetUDPEndpoint -LocalPort $ServerPort -ErrorAction Stop|Where-Object OwningProcess -EQ $identity.PID)
    if($endpoint.Count -ne 1 -or $endpoint[0].LocalAddress -cne '127.0.0.1'){throw 'Exact private UDP owner absent.'}
}
function Read-NormalInfo {
    Assert-NormalOwned
    $info=& "$ops/Get-ServerInfo.ps1" -Address 127.0.0.1 -Port $ServerPort
    if($info.clients -cne '0' -or $info.dedicated -cne '1' -or $info.sv_running -cne '1' -or
       $info.mapname -cne 'cp_zmb' -or $info.paris_capacity -cne '64-v1'){throw 'Private vacant normal capacity identity differs.'}
    $info
}
try{
    $lease=Enter-IW7ResourceLease -Scope $CandidateRoot -Kind Runtime -PhysicalBytes 6GB -CommitBytes 7GB -Owner 'Normal capacity constructor and legacy-peer rejection smoke' -RequireNewLease
    Assert-IW7AgentCandidateVacant -CandidateRoot $CandidateRoot -Ports @($ServerPort)
    $transaction=Save-IW7BaseTransaction ([pscustomobject]@{GameRoot=$CandidateRoot;MutableFiles=@('iw7-capacity-normal-server.exe','iw7-mod/capacity_normal.cfg');ProfileDirectory='iw7-mod/players2';ProfileDirectories=@('iw7-mod/custom_scripts/cp','iw7-mod/lab-appdata','mods/paris_beta/bank','iw7-mod/players2')}) (Join-Path $case 'backup')
    foreach($f in $transaction.Files|Where-Object {$_.Path.StartsWith('iw7-mod/custom_scripts/cp/') -and $_.Path -match '\.(gsc|gscbin)$'}){
        $p=Resolve-IW7BasePath $CandidateRoot $f.Path
        if((Get-FileHash $p).Hash -cne $f.SHA256){throw 'Saved script changed.'}
    }
    foreach($f in $transaction.Files|Where-Object {$_.Path.StartsWith('iw7-mod/custom_scripts/cp/') -and $_.Path -match '\.(gsc|gscbin)$'}){Remove-Item -LiteralPath (Resolve-IW7BasePath $CandidateRoot $f.Path)}
    Copy-Item -LiteralPath "$source/tests/fixtures/capacity_pool.gsc" -Destination (Resolve-IW7BasePath $CandidateRoot 'iw7-mod/custom_scripts/cp/capacity_pool.gsc')
    $image=Resolve-IW7BasePath $CandidateRoot 'iw7-capacity-normal-server.exe';Copy-Item -LiteralPath $binary -Destination $image
    if((Get-FileHash $image).Hash -cne $m.SHA256){throw 'Normal staged image differs.'}
    $secret=[guid]::NewGuid().ToString('N')+[guid]::NewGuid().ToString('N');$password=[guid]::NewGuid().ToString('N')
    $cfg=@"
set sv_hostname "IW7 Capacity Normal Smoke"
set sv_maxclients 4
set g_gametype "zombie"
set scr_zombie_maxagents 64
set paris_isolated_lab 1
set paris_capacity_pool_probe 1
set paris_capacity_client_probe 0
set sv_lanOnly 1
set net_ip 127.0.0.1
set g_password "$password"
set rcon_password "$secret"
set fs_game ""
set sv_cheats 0
set g_inactivity 0
set sv_mapRotation "gametype zombie map cp_zmb"
set sv_mapRotationCurrent ""
"@
    [IO.File]::WriteAllText((Resolve-IW7BasePath $CandidateRoot 'iw7-mod/capacity_normal.cfg'),$cfg,[Text.UTF8Encoding]::new($false))
    if(!('IW7LabProcess' -as [type])){Add-Type -Path "$ops/native/LabProcess.cs"}
    $server=[IW7LabProcess]::StartOwned($image,"-nosteam -dedicated -cpMode -stdout -allow_root_io -noupdate -paris-capacity-64 -paris-capacity-production +set net_ip 127.0.0.1 +set net_port $ServerPort +exec capacity_normal.cfg +map_rotate",$CandidateRoot,"$case/server.stdout.log","$case/server.stderr.log",('IW7ParisLab_'+[guid]::NewGuid().ToString('N')))
    $p=Get-Process -Id $server.Id
    try{$identity=[pscustomobject]@{PID=$server.Id;Image=$image;CreatedUtc=$p.StartTime.ToUniversalTime().ToString('o');SHA256=$m.SHA256}}finally{$p.Dispose()}
    $identity|ConvertTo-Json|Set-Content "$case/server.identity.local.json"
    Add-IW7ResourceProcess -Token $lease.Token -ProcessId $server.Id
    $deadline=[datetime]::UtcNow.AddSeconds(120);$ready=$false
    do{
        Assert-IW7BaseIdentity $identity $server
        if($server.HasExited){throw 'Normal server exited during startup.'}
        try{$null=Read-NormalInfo;$log=Read-IW7BaseLog "$case/server.stdout.log";$ready=$log.Contains('[Paris capacity pool] READY native=64 initialized=64 unique=64 bounded=82; combat=0')}catch{$ready=$false}
        if($ready){break};Start-Sleep -Milliseconds 500
    }while([datetime]::UtcNow -lt $deadline)
    if(!$ready){throw 'Normal 64-agent constructor did not become ready.'}
    foreach($contract in @('','24','unknown')){
        $null=Read-NormalInfo
        $userinfo='\name\CapacityPeerProbe\xuid\1\challenge\capacity_probe'
        if($contract){$userinfo+='\paris_capacity\'+$contract}
        $packet=[byte[]]([byte[]](255,255,255,255)+[Text.Encoding]::ASCII.GetBytes('connect 0 "'+$userinfo+'"'+[char]0))
        $udp=[Net.Sockets.UdpClient]::new();$udp.Client.ReceiveTimeout=3000
        try{$udp.Connect('127.0.0.1',$ServerPort);$null=$udp.Send($packet,$packet.Length);$remote=[Net.IPEndPoint]::new([Net.IPAddress]::Any,0);$answer=[Text.Encoding]::ASCII.GetString($udp.Receive([ref]$remote))}finally{$udp.Dispose()}
        if(!$answer.Contains('This server requires the Paris 48-zombie client update.')){throw 'Incompatible peer was not rejected by the capacity admission gate.'}
        $null=Read-NormalInfo
        $checks+=@{Peer=$(if($contract){$contract}else{'legacy-empty'});CapacityErrorReceived=$true;AuthoritativeClients=0}
    }
}catch{$failure=$_.Exception.Message}
finally{
    try{
        if($server -and !$server.HasExited){
            for($i=0;$i -le 30;$i++){$null=Read-NormalInfo;if($i -lt 30){Start-Sleep -Seconds 1}}
            $udp=[Net.Sockets.UdpClient]::new()
            try{$udp.Connect('127.0.0.1',$ServerPort);$packet=[byte[]]([byte[]](255,255,255,255)+[Text.Encoding]::ASCII.GetBytes('rcon '+$secret+' quit'));$null=$udp.Send($packet,$packet.Length)}finally{$udp.Dispose()}
            if(!$server.WaitForExit(10000)){throw 'Normal owned quit did not complete; preserve reservation.'}
        }
        if($server -and !$server.HasExited){throw 'Normal owned exit not confirmed.'}
        Assert-IW7AgentCandidateVacant -CandidateRoot $CandidateRoot -Ports @($ServerPort)
        if($transaction){Restore-IW7BaseTransaction $transaction}
        $restored=$true
        if($lease){Exit-IW7ResourceLease -Token $lease.Token;$released=$true}
    }catch{$cleanup=$_.Exception.Message}
    if($server -and $server.HasExited){$server.Dispose()}
    @{Schema='iw7.capacity-normal-smoke/1';Failure=$failure;CleanupError=$cleanup;Restored=$restored;LeaseReleased=$released;NormalConstructor64=$ready;PeerRejections=$checks;NativeSHA256=$m.SHA256;MainDeployed=$false;ClientLaunched=$false;OutputRoot=$case}|ConvertTo-Json -Depth 5|Set-Content "$case/result.local.json"
}
if($failure -or $cleanup){throw "Normal smoke failed: $failure; cleanup=$cleanup; evidence=$case"}
"Normal capacity constructor and incompatible-peer admission PASS; restored; evidence=$case"
