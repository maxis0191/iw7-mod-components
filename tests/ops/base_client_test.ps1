$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. "$repo/ops/Base-Client.Core.ps1"
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('iw7-base-test-'+[guid]::NewGuid().ToString('N'))
$game=Join-Path $testRoot 'game';$backup=Join-Path $testRoot 'backup'
[IO.Directory]::CreateDirectory("$game/iw7-mod/players2") | Out-Null
function Assert-Test($Condition,[string]$Message) { if (!$Condition) { throw $Message } }
function Assert-Refused([scriptblock]$Body,[string]$Message) {
    $refused=$false;try { & $Body | Out-Null } catch { $refused=$true };Assert-Test $refused $Message
}
try {
    [IO.File]::WriteAllText("$game/iw7-mod/players2/config.cfg",'owner profile')
    $ownerWindowProfile="seta vid_width `"1879`"`nseta vid_height `"1057`"`nseta r_fullscreenWindow `"1`"`n"
    [IO.File]::WriteAllText("$game/iw7-mod/players2/config_mp.cfg",$ownerWindowProfile)
    [IO.File]::WriteAllText("$game/iw7-mod/paris-server-client.request",'owner mailbox')
    [IO.File]::WriteAllText("$game/iw7-mod/server_spaceland.cfg",'Main configuration')
    $realExe=(Get-Process -Id $PID).MainModule.FileName
    Copy-Item -LiteralPath $realExe -Destination "$game/test-client.exe"
    $plan=New-IW7BaseClientPlan -GameRoot $game -ClientImage "$game/test-client.exe" -ServerPort 27116 -ClientPort 27117 -GraphicsProfile Reduced
    Assert-Test ($plan.RunPlan.PhysicalBytes -eq 12GB -and $plan.RunPlan.CommitBytes -eq 12GB) 'Full server/client budget absent.'
    $debug=New-IW7BaseClientPlan -GameRoot $game -ClientImage "$game/test-client.exe" -ServerPort 27116 -ClientPort 27117 -Debugger
    Assert-Test ($debug.RunPlan.PhysicalBytes -eq 18GB -and $debug.RunPlan.CommitBytes -eq 19GB) 'Debugger overhead omitted.'
    # A cfg on disk cannot prove startup applies authentication or latched
    # graphics. Verify the actual launch boundary uses one explicit value per
    # setting, independently of any existing owner config or exec search path.
    $fixturePassword=[guid]::NewGuid().ToString('N')
    $launch=Get-IW7BaseClientArguments $plan $fixturePassword
    Assert-Test (!$plan.BO3HUDPrivate -and $launch -notmatch 'bo3_zombies_hud') 'Ordinary client enabled the private HUD.'
    $legacyPlan=$plan.PSObject.Copy();$legacyPlan.PSObject.Properties.Remove('BO3HUDPrivate')
    Assert-Test ((Get-IW7BaseClientArguments $legacyPlan $fixturePassword) -ceq $launch) 'Legacy arguments changed without a HUD field.'
    $hudPlan=New-IW7BaseClientPlan -GameRoot $game -ClientImage "$game/test-client.exe" -ServerPort 27116 -ClientPort 27117 -GraphicsProfile Reduced -BO3HUDPrivate
    $hudLaunch=Get-IW7BaseClientArguments $hudPlan $fixturePassword
    Assert-Test ($hudPlan.BO3HUDPrivate -and $hudLaunch -ceq ($launch+' +set bo3_zombies_hud_enable 1 +set bo3_zombies_hud_private 1')) 'Private HUD startup did not add exactly the two opt-ins.'
    Assert-Test ($hudLaunch -notmatch '\+exec\s|-wincon|-paris-rig') 'HUD startup acquired exec or rig behavior.'
    foreach($badHUD in @('true','1 +set sv_cheats 1',1,$null,@($true,$false))){
        $invalidHUD=$plan.PSObject.Copy();$invalidHUD.BO3HUDPrivate=$badHUD
        Assert-Refused { Get-IW7BaseClientArguments $invalidHUD $fixturePassword } 'Nonboolean private HUD input accepted.'
    }
    Assert-Refused { New-IW7BaseClientPlan -GameRoot $game -ClientImage "$game/test-client.exe" -ServerPort 27116 -ClientPort 27117 -BO3HUDPrivate -OriginalRigConsole } 'HUD and rig plan combined.'
    $invalidHUD=$hudPlan.PSObject.Copy();$invalidHUD.OriginalRigConsole=$true
    Assert-Refused { Get-IW7BaseClientArguments $invalidHUD $fixturePassword } 'Mutated HUD and rig argument plan combined.'
    foreach ($setting in @{'password'=('"'+$fixturePassword+'"');'r_picmip'='2';'r_picmip_bump'='2';'r_picmip_spec'='2';'r_fullscreen'='0';'r_fullscreenWindow'='0';'vid_width'='1280';'vid_height'='720';'r_mode'='1280x720';'r_vsync'='1';'com_maxfps'='30';'net_ip'='127.0.0.1';'net_port'='27117';'paris_lab_server_port'='27116'}.GetEnumerator()) {
        $matches=[regex]::Matches($launch,('\+set\s+'+[regex]::Escape($setting.Key)+'\s+("[^"]*"|\S+)'))
        Assert-Test ($matches.Count -eq 1 -and $matches[0].Groups[1].Value -eq $setting.Value) ('Startup setting absent/ambiguous: '+$setting.Key)
    }
    Assert-Test ($launch -notmatch '\+exec\s' -and $launch -notmatch '-paris-debugger') 'Launch still depends on client exec or unreserved debugger.'
    Assert-Test ($launch -notmatch 'cl_yawspeed|cl_pitchspeed') 'Ordinary profile changed keyboard look speeds.'
    $combatYaw=New-IW7BaseClientPlan -GameRoot $game -ClientImage "$game/test-client.exe" -ServerPort 27116 -ClientPort 27117 -GraphicsProfile Reduced -KeyboardYawDegreesPerSecond 35
    $yawLaunch=Get-IW7BaseClientArguments $combatYaw $fixturePassword
    Assert-Test ($combatYaw.KeyboardYawDegreesPerSecond -eq 35 -and [regex]::Matches($yawLaunch,'\+set cl_yawspeed 35(?:\s|$)').Count -eq 1 -and $yawLaunch -notmatch 'cl_pitchspeed') 'Combat yaw was not explicit or changed pitch.'
    foreach($badYaw in @('35',$true,19,141,-1,[double]::NaN,[double]::PositiveInfinity)){
        Assert-Refused { New-IW7BaseClientPlan -GameRoot $game -ClientImage "$game/test-client.exe" -ServerPort 27116 -ClientPort 27117 -KeyboardYawDegreesPerSecond $badYaw } 'Invalid keyboard yaw accepted.'
    }
    $nullYaw=New-IW7BaseClientPlan -GameRoot $game -ClientImage "$game/test-client.exe" -ServerPort 27116 -ClientPort 27117 -KeyboardYawDegreesPerSecond $null
    Assert-Test ((Get-IW7BaseClientArguments $nullYaw $fixturePassword) -notmatch 'cl_yawspeed') 'Null yaw unexpectedly overrode owner profile.'
    $combatLook=New-IW7BaseClientPlan -GameRoot $game -ClientImage "$game/test-client.exe" -ServerPort 27116 -ClientPort 27117 -GraphicsProfile Reduced -KeyboardYawDegreesPerSecond 35 -KeyboardPitchDegreesPerSecond 35
    $lookLaunch=Get-IW7BaseClientArguments $combatLook $fixturePassword
    Assert-Test ($combatLook.KeyboardPitchDegreesPerSecond -eq 35 -and [regex]::Matches($lookLaunch,'\+set cl_pitchspeed 35(?:\s|$)').Count -eq 1 -and [regex]::Matches($lookLaunch,'\+set cl_yawspeed 35(?:\s|$)').Count -eq 1) 'Combat yaw/pitch not explicit exactly once.'
    foreach($badPitch in @('35',$true,19,141,-1,[double]::NaN,[double]::PositiveInfinity)){
        Assert-Refused { New-IW7BaseClientPlan -GameRoot $game -ClientImage "$game/test-client.exe" -ServerPort 27116 -ClientPort 27117 -KeyboardPitchDegreesPerSecond $badPitch } 'Invalid keyboard pitch accepted.'
    }
    $nullPitch=New-IW7BaseClientPlan -GameRoot $game -ClientImage "$game/test-client.exe" -ServerPort 27116 -ClientPort 27117 -KeyboardPitchDegreesPerSecond $null
    Assert-Test ((Get-IW7BaseClientArguments $nullPitch $fixturePassword) -notmatch 'cl_pitchspeed') 'Null pitch unexpectedly overrode owner profile.'
    $fullLaunch=Get-IW7BaseClientArguments $debug $fixturePassword
    Assert-Test ($fullLaunch -match '\+set r_picmip 0(?:\s|$)' -and $fullLaunch -match '-paris-debugger(?:\s|$)') 'Full/debug reserved profile changed.'
    Assert-Refused { Get-IW7BaseClientArguments $plan 'unsafe" +set sv_cheats 1' } 'Startup password injection accepted.'
    Assert-Refused { Resolve-IW7BasePath $game '../outside' } 'Traversal accepted.'
    Assert-Refused { New-IW7BaseClientPlan -GameRoot $game -ClientImage $realExe -ServerPort 27116 -ClientPort 27117 } 'External image accepted.'
    Assert-Refused { New-IW7BaseClientPlan -GameRoot $game -ClientImage "$game/test-client.exe" -ServerPort 27016 -ClientPort 27117 } 'Main port accepted.'
    # Windows CI puts TEMP below hidden AppData. Existence does not imply
    # Get-Item can inspect a hidden ancestor without Force.
    $hiddenParent=Join-Path $testRoot 'hidden-parent'
    [IO.Directory]::CreateDirectory("$hiddenParent/game/iw7-mod/players2") | Out-Null
    $hiddenItem=Get-Item -LiteralPath $hiddenParent -Force
    $hiddenItem.Attributes=$hiddenItem.Attributes -bor [IO.FileAttributes]::Hidden
    Copy-Item -LiteralPath $realExe -Destination "$hiddenParent/game/test-client.exe"
    [IO.File]::WriteAllText("$hiddenParent/game/iw7-mod/players2/config.cfg",'hidden-parent owner profile')
    Assert-Test ((Get-Item -LiteralPath $hiddenParent -Force).Attributes -band [IO.FileAttributes]::Hidden) 'Hidden-parent regression was not established.'
    $hiddenPlan=New-IW7BaseClientPlan -GameRoot "$hiddenParent/game" -ClientImage "$hiddenParent/game/test-client.exe" -ServerPort 27116 -ClientPort 27117 -GraphicsProfile Reduced
    $hiddenTransaction=Save-IW7BaseTransaction $hiddenPlan (Join-Path $testRoot 'hidden-backup')
    [IO.File]::WriteAllText("$hiddenParent/game/iw7-mod/players2/config.cfg",'temporary modification')
    Restore-IW7BaseTransaction $hiddenTransaction
    Assert-Test ([IO.File]::ReadAllText("$hiddenParent/game/iw7-mod/players2/config.cfg") -eq 'hidden-parent owner profile') 'Hidden-ancestor transaction failed.'
    $server=[pscustomobject]@{PID=123;Image=(Join-Path $testRoot 'dedicated/test.exe');CreatedUtc=[datetime]::UtcNow.ToString('o')}
    $lease=[pscustomobject]@{Kind='Runtime';Scope=(Join-Path $testRoot 'dedicated');BaseClientImage=$plan.Image;PhysicalBytes=12GB;CommitBytes=12GB;Processes=@($server)}
    Assert-IW7BaseLease $lease $plan $server
    $lease.CommitBytes=8GB
    Assert-Refused { Assert-IW7BaseLease $lease $plan $server } 'Client-only commitment accepted.'
    $lease.CommitBytes=12GB;$lease.BaseClientImage=$realExe
    Assert-Refused { Assert-IW7BaseLease $lease $plan $server } 'Changed base image declaration accepted.'
    $lease.BaseClientImage=$plan.Image
    $wrongServer=[pscustomobject]@{PID=123;Image=$plan.Image;CreatedUtc=$server.CreatedUtc}
    Assert-Refused { Assert-IW7BaseLease $lease $plan $wrongServer } 'Main/base dedicated identity accepted.'
    $wrongServer=[pscustomobject]@{PID=123;Image=$server.Image;CreatedUtc=([datetime]::UtcNow.AddDays(-1)).ToString('o')}
    Assert-Refused { Assert-IW7BaseLease $lease $plan $wrongServer } 'Stale registered server identity accepted.'
    $ownerYawCfg="set cl_yawspeed 140`nset cl_pitchspeed 91`n"
    [IO.File]::WriteAllText("$game/iw7-mod/agent-base-client.cfg",$ownerYawCfg)
    $transaction=Save-IW7BaseTransaction $combatLook $backup
    [IO.File]::WriteAllText("$game/iw7-mod/agent-base-client.cfg","set cl_yawspeed 35`nset cl_pitchspeed 35`n")
    [IO.File]::WriteAllText("$game/iw7-mod/players2/config.cfg",'test modified profile')
    [IO.File]::WriteAllText("$game/iw7-mod/players2/config_mp.cfg",'temporary windowed dimensions')
    [IO.File]::WriteAllText("$game/iw7-mod/players2/new.dat",'test generated profile')
    [IO.File]::WriteAllText("$game/iw7-mod/paris-server-client.request",'test mailbox')
    [IO.File]::WriteAllText("$game/iw7-mod/paris-agent.session",'test native session')
    [IO.Directory]::CreateDirectory("$game/iw7-mod/lab-appdata/nested") | Out-Null
    [IO.File]::WriteAllText("$game/iw7-mod/lab-appdata/nested/profile.json",'isolated generated state')
    [IO.File]::WriteAllText("$game/iw7-mod/paris-isolated-lab.marker",'iw7-paris-isolated-lab-v1')
    [IO.File]::WriteAllText("$backup/iw7-mod/paris-server-client.request",'corrupted backup')
    Assert-Refused { Restore-IW7BaseTransaction $transaction } 'Corrupt backup accepted.'
    Assert-Test ([IO.File]::ReadAllText("$game/iw7-mod/players2/config.cfg") -eq 'test modified profile') 'Partial restore occurred before backup preflight.'
    [IO.File]::WriteAllText("$backup/iw7-mod/paris-server-client.request",'owner mailbox')
    Restore-IW7BaseTransaction $transaction
    Assert-Test ([IO.File]::ReadAllText("$game/iw7-mod/agent-base-client.cfg") -ceq $ownerYawCfg) 'Explicit combat yaw did not restore owner yaw/pitch config bytes.'
    Assert-Test ([IO.File]::ReadAllText("$game/iw7-mod/players2/config.cfg") -eq 'owner profile') 'Profile bytes not restored.'
    Assert-Test ([IO.File]::ReadAllText("$game/iw7-mod/players2/config_mp.cfg") -eq $ownerWindowProfile) 'Owner window dimensions/borderless profile not restored byte-for-byte.'
    Assert-Test ([IO.File]::ReadAllText("$game/iw7-mod/paris-server-client.request") -eq 'owner mailbox') 'Existing mailbox not restored.'
    Assert-Test (!(Test-Path "$game/iw7-mod/players2/new.dat") -and !(Test-Path "$game/iw7-mod/paris-agent.session")) 'Generated files survived restoration.'
    Assert-Test (!(Test-Path "$game/iw7-mod/lab-appdata") -and !(Test-Path "$game/iw7-mod/paris-isolated-lab.marker")) 'Isolated profile/marker not restored to absent state.'
    # Server staging tracks new fixtures both explicitly and via the CP profile
    # tree. Restoration must delete the same created file only once.
    $overlapPath='iw7-mod/custom_scripts/cp/agent_actions_fixture.gsc'
    $overlapPlan=[pscustomobject]@{GameRoot=$game;MutableFiles=@($overlapPath);ProfileDirectory='iw7-mod/custom_scripts/cp';ProfileDirectories=@('iw7-mod/custom_scripts/cp')}
    $overlap=Save-IW7BaseTransaction $overlapPlan (Join-Path $testRoot 'overlap-backup')
    [IO.Directory]::CreateDirectory("$game/iw7-mod/custom_scripts/cp") | Out-Null
    [IO.File]::WriteAllText((Join-Path $game $overlapPath),'staged fixture')
    Restore-IW7BaseTransaction $overlap
    Assert-Test ($overlap.Restored -and !(Test-Path (Join-Path $game $overlapPath)) -and !(Test-Path "$game/iw7-mod/custom_scripts/cp")) 'Overlapping explicit/profile restoration failed.'
    Assert-Test ([IO.File]::ReadAllText("$game/iw7-mod/server_spaceland.cfg") -eq 'Main configuration') 'Main changed during restore.'
    [IO.File]::WriteAllText("$game/iw7-mod/server_spaceland.cfg",'unexpected Main modification')
    Assert-Refused { Restore-IW7BaseTransaction $transaction } 'Main integrity change unnoticed.'
    $process=Get-Process -Id $PID
    $identity=[pscustomobject]@{PID=$PID;Image=$process.MainModule.FileName;CreatedUtc=$process.StartTime.ToUniversalTime().ToString('o');SHA256=(Get-FileHash $process.MainModule.FileName).Hash}
    Assert-IW7BaseIdentity $identity
    $identity.CreatedUtc=([datetime]::UtcNow.AddDays(-1)).ToString('o')
    Assert-Refused { Assert-IW7BaseIdentity $identity } 'Reused/stale creation identity accepted.'
    $identity.CreatedUtc=$process.StartTime.ToUniversalTime().ToString('o');$identity.SHA256='0'*64
    Assert-Refused { Assert-IW7BaseIdentity $identity } 'Wrong image hash accepted.'
    $process.Dispose()
    $context=[pscustomobject]@{StartedTick=1000L;LastHeartbeatTick=0L;LastHeartbeatUtc=$null;PendingLog='';Protected=$false}
    Update-IW7BaseProtection $context 'slot=0; tick_ms=1100; protected=1; bound=1; godmode=1; inactivity=0; cheats=0; failed=' -NowTick 1200
    Assert-Test (!$context.Protected) 'Partial line counted as protection.'
    Update-IW7BaseProtection $context "0`n" -NowTick 1300
    Assert-Test $context.Protected 'Partial-line continuation lost protection evidence.'
    Assert-Refused { Update-IW7BaseProtection $context '' -NowTick 12000 } 'Expired protection accepted.'
    $context.Protected=$false;$context.LastHeartbeatTick=0
    Update-IW7BaseProtection $context "slot=0; tick_ms=500; protected=1; bound=1; godmode=1; inactivity=0; cheats=0; failed=0`n" -NowTick 1500
    Assert-Test (!$context.Protected) 'Prelaunch heartbeat accepted.'
    Assert-Refused { Update-IW7BaseProtection $context "[Paris test protection failure]`n" -NowTick 1600 } 'Protection failure unnoticed.'
    Assert-Refused { Send-IW7BaseRequest $context 'arbitrary;command' } 'Command injection accepted.'
    Assert-Refused { Send-IW7BaseRequest $context 'capture' -AllowUnprotected } 'Gameplay action bypassed protection.'
    'PASS base-client: path/Main refusal, whole budget, transactional preflight/restore, Main integrity, real process identity, fresh/partial/stale protection, typed mailbox.'
} finally {
    # Exact generated temporary directory only; resolve containment before deletion.
    $resolved=[IO.Path]::GetFullPath($testRoot)
    if (!$resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -notlike 'iw7-base-test-*') { throw 'Test cleanup containment failed.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
