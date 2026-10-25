param([Parameter(Mandatory)][string]$CandidateRoot,[Parameter(Mandatory)][string]$ProtectedGameRoot,[Parameter(Mandatory)][string]$Output,[switch]$Effects,[switch]$Moderation)
$Source=Split-Path $PSScriptRoot -Parent
$ErrorActionPreference='Stop'
$root=(Resolve-Path -LiteralPath $CandidateRoot).Path.TrimEnd('\','/')
$protected=(Resolve-Path -LiteralPath $ProtectedGameRoot).Path.TrimEnd('\','/')
if($root -ieq $protected -or $root.StartsWith($protected+'\',[StringComparison]::OrdinalIgnoreCase) -or $protected.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Separate retained stock required; preserve Main'}
if(Test-Path -LiteralPath $Output){throw 'Fresh witness output required'}
if($Effects -and $Moderation){throw 'Run Effects and Moderation separately.'}
if(!(Test-Path "$root/iw7-mod/paris-isolated-lab.marker") -or (Test-Path "$root/STOCK-ASSETS-REMOVED.json")){throw 'Complete retained stock and lab marker required'}
if(@(Get-CimInstance Win32_Process|Where-Object{$_.ExecutablePath -and $_.ExecutablePath.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)}).Count){throw 'Retained candidate is occupied'}
if(Get-NetUDPEndpoint -LocalPort 27946,27948 -ErrorAction SilentlyContinue){throw 'Witness ports occupied'}
. "$Source/ops/Resource-Scheduler.Core.ps1"
. "$Source/ops/Base-Client.Core.ps1"
[IO.Directory]::CreateDirectory($Output)|Out-Null
$result=[ordered]@{Passed=$false;Restored=$false;Closed=$false;ServerHash=(Get-FileHash "$Source/runtime/voice-package/iw7-paris-voice.exe").Hash;Reason='Owner base client occupied: one bounded separate observer uses retained private server stock, with an isolated Aurora profile; no game assets copied.';Checks=@()}
$lease=$null;$transaction=$null;$server=$null;$client=$null;$serverId=$null;$clientId=$null
$console=Join-Path $Source 'ops/Send-OwnedConsole.py'
function Send-Console($Process,$Identity,[string]$Command){Assert-IW7BaseIdentity $Identity $Process; & python $console $Process.Id $Command; if($LASTEXITCODE){throw 'Console delivery failed'}}
function Text([string]$Path){if(Test-Path -LiteralPath $Path){Read-IW7BaseLog $Path}else{''}}
function Wait-For([scriptblock]$Check,[int]$Seconds,[string]$Failure){$until=[datetime]::UtcNow.AddSeconds($Seconds);while([datetime]::UtcNow -lt $until){if(& $Check){return};Start-Sleep -Milliseconds 500};throw $Failure}
function Identity($Process,[string]$Image){[pscustomobject]@{PID=$Process.Id;Image=$Image;CreatedUtc=$Process.StartTime.ToUniversalTime().ToString('o');SHA256=(Get-FileHash -LiteralPath $Image).Hash}}
function Stop-Owned($Process,$Record){if(!$Process){return};if(!$Process.HasExited){Assert-IW7BaseIdentity $Record $Process;$Process.Kill();if(!$Process.WaitForExit(15000)){throw 'Owned process closure failed'}}}
function Reply([string]$Command,[string]$Expected,$Process=$client,$Record=$clientId){
    $offset=(Text "$Output/server.stdout.log").Length
    Send-Console $Process $Record $Command
    Wait-For {(Text "$Output/server.stdout.log").Substring($offset).Contains('[Owner moderation] slot=0 result='+$Expected)} 10 "Moderation reply missing: $Command"
    $result.Checks+=@{Command=$Command;Reply=$Expected}
}
function Angles {
    $offset=(Text "$Output/server.stdout.log").Length
    Send-Console $client $clientId 'cmd getviewang'
    Wait-For {[regex]::IsMatch((Text "$Output/server.stdout.log").Substring($offset),'(?m)^(-?\d+\.\d+), (-?\d+\.\d+), (-?\d+\.\d+)\s*$')} 5 'Native angle query unavailable'
    $m=[regex]::Matches((Text "$Output/server.stdout.log").Substring($offset),'(?m)^(-?\d+\.\d+), (-?\d+\.\d+), (-?\d+\.\d+)\s*$')|Select-Object -Last 1
    @($m.Groups[1].Value,$m.Groups[2].Value,$m.Groups[3].Value)
}
try{
    $lease=Enter-IW7ResourceLease -Scope $root -Kind Runtime -PhysicalBytes 12GB -CommitBytes 16GB -Owner 'Private owner-cheats positive and wrong-key native console witness'
    $plan=[pscustomobject]@{GameRoot=$root;MutableFiles=@('iw7-owner-witness.exe','iw7-mod/owner-witness.cfg','iw7-mod/paris-server-client.request','iw7-mod/paris-server-client.response','iw7-mod/paris-agent.session','iw7-mod/paris-agent.request','iw7-mod/paris-agent.response','iw7-mod/paris-agent.safety','iw7-mod/owner-bans.txt');ProfileDirectory='iw7-mod/custom_scripts/cp';ProfileDirectories=@('iw7-mod/custom_scripts/cp','iw7-mod/owner-cheats','iw7-mod/players2','iw7-mod/lab-appdata','mods/paris_beta/bank')}
    $transaction=Save-IW7BaseTransaction $plan (Join-Path $Output 'backup')
    & "$Source/ops/New-OwnerCheatsKit.ps1" -OutputDirectory (Join-Path $Output 'keys')
    & "$Source/ops/New-OwnerCheatsKit.ps1" -OutputDirectory (Join-Path $Output 'wrong-keys')
    [IO.Directory]::CreateDirectory("$root/iw7-mod/owner-cheats")|Out-Null
    foreach($side in @('client','server')){Get-ChildItem "$Output/keys/$side/iw7-mod/owner-cheats" -File|ForEach-Object{Copy-Item -LiteralPath $_.FullName -Destination "$root/iw7-mod/owner-cheats/$($_.Name)"}}
    Copy-Item -LiteralPath "$Source/runtime/voice-package/iw7-paris-voice.exe" -Destination "$root/iw7-owner-witness.exe"
    $fixture=@'
init()
{
    if (!getdvarint("dedicated") || !getdvarint("paris_test_probe") || getdvarint("net_port") != 27946) return;
    level thread connections();
    print("[Owner witness] private protection armed");
}
connections()
{
    for (;;)
    {
        level waittill("connected", player);
        if (isdefined(player)) player thread protection();
    }
}
protection()
{
    self endon("disconnect");
    for (;;)
    {
        if (!self paris_test_protect()) { print("[Owner witness] protection refused"); return; }
        print("[Owner witness] " + self paris_test_safety_snapshot());
        wait 0.5;
    }
}
'@
    [IO.File]::WriteAllText("$root/iw7-mod/custom_scripts/cp/owner_witness.gsc",$fixture)
    # A synthetic persisted ban proves load, listing, unban and rewrite.
    if($Moderation){[IO.File]::WriteAllText("$root/iw7-mod/owner-bans.txt","0123456789abcdef`tSeed Player`n",[Text.UTF8Encoding]::new($false))}
    $password=[guid]::NewGuid().ToString('N')
    $cfg="set sv_hostname PrivateOwnerCheats`nset g_password $password`nset sv_maxclients 4`nset sv_lanOnly 1`nset sv_cheats 0`nset g_inactivity 0`nset paris_test_probe 1`nset paris_isolated_lab 1`nset g_gametype zombie`nset fs_game `"`"`nset logfile 2`n"
    [IO.File]::WriteAllText("$root/iw7-mod/owner-witness.cfg",$cfg)
    $image="$root\iw7-owner-witness.exe"
    $server=Start-Process -FilePath $image -WorkingDirectory $root -ArgumentList '-noupdate -nosteam -dedicated -cpMode -stdout -paris-isolated-lab -paris-server-test -allow_root_io +set sv_lanOnly 1 +set net_ip 127.0.0.1 +set net_port 27946 +set fs_game "" +exec owner-witness.cfg +map cp_zmb' -WindowStyle Hidden -RedirectStandardOutput "$Output/server.stdout.log" -RedirectStandardError "$Output/server.stderr.log" -PassThru
    $serverId=Identity $server $image; Add-IW7ResourceProcess $lease.Token $server.Id
    Wait-For {if($server.HasExited){throw 'Private dedicated exited'};try{$info=& "$Source/ops/Get-ServerInfo.ps1" -Port 27946; $info.isPrivate -eq '1' -and $info.clients -eq '0' -and $info.mapname -eq 'cp_zmb'}catch{$false}} 90 'Private startup timeout'
    Wait-For {(Text "$Output/server.stdout.log") -match 'heartbeat_suppressed=1' -and (Text "$Output/server.stdout.log") -match '\[Owner cheats\] configured=1; dedicated=1'} 20 'Native privacy/key setup unavailable'
    $phases=if($Effects){@('owner','wrong-key')}else{@('owner','wrong-key','owner-reconnect')}
    foreach($phase in $phases){
        $keySource=if($phase -eq 'wrong-key'){"$Output/wrong-keys/client/iw7-mod/owner-cheats/client-private.blob"}else{"$Output/keys/client/iw7-mod/owner-cheats/client-private.blob"}
        Copy-Item -LiteralPath $keySource -Destination "$root/iw7-mod/owner-cheats/client-private.blob" -Force
        $arguments="-noupdate -nosteam -cpMode -stdout -paris-server-client-test -paris-isolated-lab +set net_ip 127.0.0.1 +set net_port 27948 +set paris_lab_server_port 27946 +set password $password +set r_fullscreen 0 +set r_fullscreenWindow 0 +set vid_width 960 +set vid_height 540 +set com_maxfps 20 +set r_picmip 4 +set r_picmip_bump 4 +set r_picmip_spec 4"
        $client=Start-Process -FilePath $image -WorkingDirectory $root -ArgumentList $arguments -WindowStyle Hidden -RedirectStandardOutput "$Output/$phase.stdout.log" -RedirectStandardError "$Output/$phase.stderr.log" -PassThru
        $clientId=Identity $client $image; Add-IW7ResourceProcess $lease.Token $client.Id
        [IO.File]::WriteAllText("$root/iw7-mod/paris-server-client.request","$($client.Id) $([guid]::NewGuid().ToString('N')) connect",[Text.Encoding]::ASCII)
        $offset=(Text "$Output/server.stdout.log").Length
        Wait-For {if($client.HasExited){throw 'Witness client exited'};(Text "$Output/server.stdout.log").Substring($offset) -match '\[Owner witness\].*protected=1.*godmode=1.*inactivity=0.*cheats=0'} 100 'Fresh engine protection unavailable'
        if($phase -ne 'wrong-key'){
            Wait-For {(Text "$Output/server.stdout.log").Substring($offset) -match '\[Owner cheats\] Authenticated console access; slot=0'} 25 'Owner proof was not accepted'
        }else{Start-Sleep -Seconds 12;if((Text "$Output/server.stdout.log").Substring($offset) -match '\[Owner cheats\] Authenticated console access'){throw 'Wrong private key was authorized'}}
        if($Effects){
            $before=@(Angles)
            Send-Console $client $clientId 'cmd setviewang 23 34 45'
            Start-Sleep -Milliseconds 300
            $after=@(Angles)
            if($phase -eq 'owner'){
                if($after.Count -ne 3 -or [math]::Abs([double]$after[0]-23) -gt 0.01 -or [math]::Abs([double]$after[1]-34) -gt 0.01 -or [math]::Abs([double]$after[2]-45) -gt 0.01){throw 'Authenticated native command did not execute'}
                Send-Console $client $clientId ('cmd setviewang '+($before -join ' '))
            }else{if(($before -join ',') -cne ($after -join ',')){throw 'Wrong-key client executed a native cheat command'}}
            $result.Checks+=@{Phase=$phase;NativeCommand='setviewang';Before=$before;After=$after;Allowed=($phase -eq 'owner')}
        }
        if($Moderation){
            if($phase -eq 'owner'){
                Reply 'banlist' 'Ban #1: Seed Player (0123456789abcdef)'
                Reply 'kick #1' 'Choose another player.'
                Reply 'kickClient 0' 'Choose another player.'
                Reply 'ban #4' 'No unique player found. Use .players and #ID.'
                Reply 'unban #1' 'Unbanned Seed Player.'
                if((Get-Content -LiteralPath "$root/iw7-mod/owner-bans.txt" -Raw) -ne ''){throw 'Unban was not persisted'}
            }elseif($phase -eq 'wrong-key'){
                $offset=(Text "$Output/server.stdout.log").Length
                Send-Console $client $clientId 'banlist'
                Start-Sleep -Seconds 2
                if((Text "$Output/server.stdout.log").Substring($offset).Contains('[Owner moderation]')){throw 'Unauthenticated client relayed moderation'}
                Reply 'cmd owner_kick "#1"' 'Owner authentication required.'
            }else{Reply 'banlist' 'No bans.'}
        }
        $queryOffset=(Text "$Output/server.stdout.log").Length
        Send-Console $server $serverId 'owner_cheats_status'
        Send-Console $server $serverId 'sv_cheats'
        Wait-For {(Text "$Output/server.stdout.log").Substring($queryOffset) -match ('slot=0 allowed='+[int]($phase -ne 'wrong-key'))} 10 'Server authorization query mismatch'
        if((Text "$Output/server.stdout.log").Substring($queryOffset) -notmatch '"sv_cheats" is: "0"'){Start-Sleep -Seconds 1;if((Text "$Output/server.stdout.log").Substring($queryOffset) -notmatch '"sv_cheats" is: "0"'){throw 'Global cheats was not zero'}}
        $result.Checks+=@{Phase=$phase;FreshProtection=$true;Allowed=($phase -ne 'wrong-key');GlobalCheats=0}
        Write-Output "Witness passed: $phase; sv_cheats=0"
        Send-Console $client $clientId 'disconnect'
        Wait-For {try{(& "$Source/ops/Get-ServerInfo.ps1" -Port 27946).clients -eq '0'}catch{$false}} 15 'Disconnect not observed'
        Send-Console $client $clientId 'quit'; if(!$client.WaitForExit(10000)){throw 'Client did not close cleanly'}; $client.Dispose();$client=$null
    }
    $result.Passed=$true
}catch{$result.Error=$_.Exception.Message;throw}
finally{
    try{Stop-Owned $client $clientId;Stop-Owned $server $serverId;$result.Closed=$true;if($transaction){Restore-IW7BaseTransaction $transaction;$result.Restored=$transaction.Restored};if($lease){Exit-IW7ResourceLease $lease.Token}}finally{$result|ConvertTo-Json -Depth 8|Set-Content "$Output/result.local.json"}
}
