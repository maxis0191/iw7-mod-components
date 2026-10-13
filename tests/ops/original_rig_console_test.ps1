# Transport-only Windows fixture. No game, assets or engine protection is tested.
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Add-Type -Path "$repo/ops/native/LabProcess.cs"
. "$repo/ops/Base-Client.Core.ps1"
. "$repo/ops/Original-RigConsole.Core.ps1"
$shell=(Get-Process -Id $PID).Path
$root=Join-Path $repo ('runtime/rig-console-test-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root)|Out-Null
$scriptPath=Join-Path $root 'echo.ps1'
[IO.File]::WriteAllText($scriptPath,'[Console]::WriteLine("READY"); for($i=0;$i -lt 8;$i++){ $line=[Console]::ReadLine(); if($null -eq $line){exit 92}; [Console]::WriteLine("CONSUMED:"+$line) }; exit 0')
$commands=@('listassetpool 8 paris_doom_skin_two_bone_first_a','listassetpool 8 paris_doom_skin_two_bone_second_a',
    'listassetpool 7 paris_doom_skin_two_bone_first_a_lod0','listassetpool 7 paris_doom_skin_two_bone_second_a_lod0',
    'listassetpool 6 paris_original_probe_bend','listassetpool 10 mopw/character_park_clown_zombie_shoes',
    'set sdk_original_rig_probe_play 1','set sdk_original_rig_probe_stop 1')
$count=0
function Check($condition,[string]$message){if(!$condition){throw $message};$script:count++}
function Refuses([scriptblock]$Action,[string]$message){$failed=$false;try{& $Action|Out-Null}catch{$failed=$true};Check $failed $message}
function Close-Owned($owned){if($owned){if(!$owned.HasExited){$owned.Terminate(66);Check ($owned.WaitForExit(5000)) 'Exact fixture process did not close.'};$owned.Dispose()}}
$flags='-wincon -paris-isolated-lab -dedicated -paris-server-test'
$arguments='-NoLogo -NoProfile -NonInteractive -File "'+$scriptPath+'" '+$flags
$stdout=Join-Path $root 'pipe.stdout'
$owned=$null
try {
    foreach($bad in @('quit','listassetpool 8 *','set sdk_original_rig_probe_play 0',($commands[0]+"`nquit"),$commands[0].ToUpperInvariant())){
        Check (![IW7LabProcess]::IsOriginalRigCommand($bad)) 'Unbounded/injected rig command accepted.'
    }
    Refuses { [IW7LabProcess]::StartOwned($shell,$arguments.Replace('-paris-isolated-lab',''),$root,(Join-Path $root 'bad.stdout'),(Join-Path $root 'bad.stderr'),('IW7ParisLab_'+[guid]::NewGuid().ToString('N')),$false,$true) } 'Unscoped pipe launch accepted.'
    Check (!(Test-Path -LiteralPath (Join-Path $root 'bad.stdout'))) 'Invalid scope created launch output.'
    Check (!(Get-IW7BaseOriginalRigConsole ([pscustomobject]@{}))) 'Absent opt-in changed default input.'
    Refuses { Get-IW7BaseOriginalRigConsole ([pscustomobject]@{OriginalRigConsole='false'}) } 'String opt-in accepted.'
    $plan=[pscustomobject]@{OriginalRigConsole=$false;ClientPort=27117;ServerPort=27116;RunPlan=[pscustomobject]@{Picmip=0;Debugger=$false};KeyboardYawDegreesPerSecond=0;KeyboardPitchDegreesPerSecond=0}
    Check ((Get-IW7BaseClientArguments $plan 'fixture') -notmatch '-wincon') 'Default client received console opt-in.'
    $plan.OriginalRigConsole=$true
    Check (([regex]::Matches((Get-IW7BaseClientArguments $plan 'fixture'),'-wincon')).Count -eq 1) 'Opt-in did not select official wincon exactly once.'
    $owned=[IW7LabProcess]::StartOwned($shell,$arguments,$root,$stdout,(Join-Path $root 'pipe.stderr'),('IW7ParisLab_'+[guid]::NewGuid().ToString('N')),$false,$true)
    Check $owned.OriginalRigConsoleEnabled 'Original pipe handle absent.'
    $identity=$owned.ReadIdentity()
    $nonce='0123456789abcdef0123456789abcdef'
    Refuses {$owned.Dispose()} 'Active getline owner lost its pipe/handle.'
    Refuses {$owned.WriteOriginalRigCommand($commands[0],$identity.Image+'.wrong',$identity.CreationFileTime,$nonce,[Environment]::TickCount64)} 'Different image accepted.'
    Refuses {$owned.WriteOriginalRigCommand($commands[0],$identity.Image,($identity.CreationFileTime+1),$nonce,[Environment]::TickCount64)} 'Different creation accepted.'
    Refuses {$owned.WriteOriginalRigCommand($commands[0],$identity.Image,$identity.CreationFileTime,$nonce,([Environment]::TickCount64-251))} 'Expired permit accepted.'
    Refuses {$owned.WriteOriginalRigCommand($commands[0],$identity.Image,$identity.CreationFileTime,'invalid',[Environment]::TickCount64)} 'Invalid nonce accepted.'
    $written=$owned.WriteOriginalRigCommand($commands[0],$identity.Image,$identity.CreationFileTime,$nonce,[Environment]::TickCount64)
    Check ($written -eq $commands[0].Length+1) 'Actual first write byte count differs.'
    Refuses {$owned.WriteOriginalRigCommand($commands[0],$identity.Image,$identity.CreationFileTime,$nonce,[Environment]::TickCount64)} 'Duplicate command accepted.'
    Refuses {$owned.WriteOriginalRigCommand($commands[1],$identity.Image,$identity.CreationFileTime,('f'*32),[Environment]::TickCount64)} 'Changed native nonce accepted.'
    foreach($command in $commands[1..7]){Check ($owned.WriteOriginalRigCommand($command,$identity.Image,$identity.CreationFileTime,$nonce,[Environment]::TickCount64) -eq $command.Length+1) 'Actual pipe write incomplete.'}
    Check ($owned.WaitForExit(10000)) 'Echo child did not consume all eight bounded lines.'
    Check ($owned.ExitCode -eq 0) 'Echo child failed.'
    Refuses {$owned.WriteOriginalRigCommand($commands[0],$identity.Image,$identity.CreationFileTime,$nonce,[Environment]::TickCount64)} 'Exited original accepted a write.'
    $lines=Get-Content -LiteralPath $stdout
    foreach($command in $commands){Check (@($lines|Where-Object {$_ -ceq ('CONSUMED:'+$command)}).Count -eq 1) 'Exact child consumption absent/duplicated.'}
} finally {Close-Owned $owned}
Refuses {$owned.WriteOriginalRigCommand($commands[0],$identity.Image,$identity.CreationFileTime,$nonce,[Environment]::TickCount64)} 'Disposed original accepted a write.'
# Default NUL must still give EOF; disposal closes only an exited original.
$owned=$null
try {
    $owned=[IW7LabProcess]::StartOwned($shell,('-NoLogo -NoProfile -NonInteractive -File "'+$scriptPath+'"'),$root,(Join-Path $root 'nul.stdout'),(Join-Path $root 'nul.stderr'),('IW7ParisLab_'+[guid]::NewGuid().ToString('N')),$false)
    Check (!$owned.OriginalRigConsoleEnabled) 'Default launch unexpectedly enabled stdin commands.'
    Check ($owned.WaitForExit(10000)) 'Default NUL child did not observe EOF.'
    Check ($owned.ExitCode -eq 92) 'Default NUL input behavior changed.'
} finally {Close-Owned $owned}
# A blocked reader is closed through its original handle, within a fixed deadline.
$owned=$null
try {
    $owned=[IW7LabProcess]::StartOwned($shell,$arguments,$root,(Join-Path $root 'blocked.stdout'),(Join-Path $root 'blocked.stderr'),('IW7ParisLab_'+[guid]::NewGuid().ToString('N')),$false,$true)
    Refuses {$owned.Dispose()} 'Blocked reader was left alive after input disposal.'
    $owned.Terminate(66)
    Check ($owned.WaitForExit(5000)) 'Blocked original reader did not close.'
    Check ($owned.ExitCode -eq 66) 'Original forced fixture exit code lost.'
} finally {Close-Owned $owned}
# The client may enumerate pools, never set the dedicated's play/stop dvars.
$owned=$null
try {
    $clientArguments=$arguments.Replace('-dedicated -paris-server-test','-paris-server-client-test')
    $owned=[IW7LabProcess]::StartOwned($shell,$clientArguments,$root,(Join-Path $root 'client.stdout'),(Join-Path $root 'client.stderr'),('IW7ParisLab_'+[guid]::NewGuid().ToString('N')),$false,$true)
    $identity=$owned.ReadIdentity()
    Refuses {$owned.WriteOriginalRigCommand($commands[6],$identity.Image,$identity.CreationFileTime,$nonce,[Environment]::TickCount64)} 'Client accepted dedicated play control.'
    Check ($owned.WriteOriginalRigCommand($commands[0],$identity.Image,$identity.CreationFileTime,$nonce,[Environment]::TickCount64) -eq $commands[0].Length+1) 'Client pool transport unavailable.'
} finally {Close-Owned $owned}
"$count rig console transport checks passed; no engine/game/protection/asset result claimed. Evidence: $root"
