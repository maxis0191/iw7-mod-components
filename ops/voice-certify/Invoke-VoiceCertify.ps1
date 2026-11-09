#Requires -Version 7
<#
.SYNOPSIS
Voice certification: proves the upstream voice component on real game processes,
in Zombies and Multiplayer, including the cases where a player must NOT hear.

.DESCRIPTION
Known speech is injected at the start of client A's (or B's) native capture
pipeline by the private test component (voice_test.cpp, -voicetest) and the
decoded PCM is recorded per talker at the receiver's native playback enqueue.
Everything in between is unmodified production code.

Never run by agents before the owner allows in-game tests. -DryRun prints every
process, file change, command and assertion and starts nothing. See docs/VOICE-CERTIFY.md.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ServerRoot,
    [Parameter(Mandatory)][string]$ClientARoot,
    [string]$ClientBRoot,
    [Parameter(Mandatory)][string]$LabImage,
    [string]$BuildManifest,
    [string]$CandidateSource,
    [ValidateSet('CP', 'MP')][string[]]$Modes = @('CP', 'MP'),
    [ValidateRange(27100, 27999)][int]$ServerPort = 27416,
    [ValidateRange(27100, 27999)][int]$ClientAPort = 27417,
    [ValidateRange(27100, 27999)][int]$ClientBPort = 27418,
    [ValidatePattern('^cp_[a-z0-9_]+$')][string]$CpMap = 'cp_zmb',
    [ValidatePattern('^cp_[a-z0-9_]+$')][string]$CpSecondMap = 'cp_rave',
    [ValidatePattern('^mp_[a-z0-9_]+$')][string]$MpMap = 'mp_frontier',
    [switch]$IncludeEndOfGame,
    [ValidateSet('Vad', 'Ptt')][string]$CaptureGate = 'Vad',
    [ValidateRange(0, 65536)][double]$MicThreshold = 300,
    [ValidateRange(0, 96000)][int]$CaptureRate = 0,
    [ValidatePattern('^[A-Za-z0-9._-]+$')][string]$AsrModel = 'small',
    [ValidateRange(0, 120)][int]$EmptyStopSeconds = 30,
    [string]$OutputRoot,
    # Base image without the relay: the "before" run. Every window must then be silent.
    [switch]$Baseline,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/VoiceCertify.Core.ps1"

$ImageName = 'iw7-voicecert.exe'
$Marker = 'iw7-paris-isolated-lab-v1'
$SettleSeconds = 1.5; $TailSeconds = 2.5; $IdleSeconds = 5
$opsRoot = Split-Path $PSScriptRoot -Parent
$repo = Split-Path $opsRoot -Parent
$bank = @((Get-Content -LiteralPath "$PSScriptRoot/phrases.json" -Raw | ConvertFrom-Json).phrases)

function Get-FullPath([string]$Path) { [IO.Path]::GetFullPath($Path).TrimEnd('\', '/') }
function Test-Under([string]$Path, [string]$Root) { $Path.StartsWith($Root + '\', [StringComparison]::OrdinalIgnoreCase) }
$ServerRoot = Get-FullPath $ServerRoot
$ClientARoot = Get-FullPath $ClientARoot
$ClientBRoot = if ($ClientBRoot) { Get-FullPath $ClientBRoot } else { Join-Path $ServerRoot 'agent-peer' }
$LabImage = Get-FullPath $LabImage
if (!$BuildManifest) { $BuildManifest = Join-Path (Split-Path $LabImage) 'voice-certify-build.json' }
$stamp = [datetime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6)
$OutputRoot = if ($OutputRoot) { Get-FullPath $OutputRoot } else { Join-Path $repo "runtime\voice-certify\$stamp" }
$roots = [ordered]@{ Server = $ServerRoot; A = $ClientARoot; B = $ClientBRoot }

# ---------------------------------------------------------------- plan

# Clients run with -paris-server-client-test -paris-isolated-lab, so the lab
# fixture (paris_test_fixture.cpp) writes these files in each client root. The
# list matches the base-client transaction in ops/Base-Client.Core.ps1.
$fixtureFiles = @('iw7-mod/paris-server-client.request', 'iw7-mod/paris-server-client.response', 'iw7-mod/screenshots/server-modules-fixture.bmp',
    'iw7-mod/paris-agent.session', 'iw7-mod/paris-agent.request', 'iw7-mod/paris-agent.response', 'iw7-mod/paris-agent.safety')
$transactionPlans = [ordered]@{
    Server = [pscustomobject]@{ GameRoot = $ServerRoot; MutableFiles = @($ImageName, 'iw7-mod/voicecert_server.cfg')
        ProfileDirectory = 'iw7-mod/players2'; ProfileDirectories = @('iw7-mod/players2', 'iw7-mod/lab-appdata', 'iw7-mod/custom_scripts', 'iw7-mod/logs') }
    A = [pscustomobject]@{ GameRoot = $ClientARoot; MutableFiles = @($ImageName, 'iw7-mod/paris-isolated-lab.marker') + $fixtureFiles
        ProfileDirectory = 'iw7-mod/players2'; ProfileDirectories = @('iw7-mod/players2', 'iw7-mod/lab-appdata', 'iw7-mod/logs') }
    B = [pscustomobject]@{ GameRoot = $ClientBRoot; MutableFiles = @($ImageName, 'iw7-mod/paris-isolated-lab.marker',
            'main/data0.dcache', 'main/data1.dcache', 'main/toc0.dcache', 'main/toc1.dcache') + $fixtureFiles
        ProfileDirectory = 'iw7-mod/players2'; ProfileDirectories = @('iw7-mod/players2', 'iw7-mod/lab-appdata', 'iw7-mod/logs') }
}

function Get-RoleDir([string]$Mode, [string]$Role) { Join-Path $OutputRoot ("$($Mode.ToLower())\$Role") }

function Get-ServerConfig([string]$Mode, [string]$Password) {
    $lines = @('set sv_lanOnly 1', 'set net_ip 127.0.0.1', "set g_password `"$Password`"", 'set sv_cheats 0',
        'set g_inactivity 0', 'set sv_hostname "voicecert"', 'set fs_game ""', 'set voicecert_enable 1', 'set voicecert_req ""')
    if ($Mode -eq 'CP') {
        $lines += "set sv_mapRotation `"gametype zombie map $CpMap`""
    } else {
        $lines += @('set scr_skipclasschoice 1', 'set scr_player_forcerespawn 1', 'set scr_war_timelimit 0', 'set scr_war_scorelimit 0',
            'set scr_dm_timelimit 0', 'set scr_dm_scorelimit 0', "set sv_mapRotation `"gametype war map $MpMap`"")
    }
    ($lines + 'set sv_mapRotationCurrent ""') -join "`n"
}

function Get-ServerArguments([string]$Mode) {
    $cp = if ($Mode -eq 'CP') { '-cpMode ' } else { '' }
    "-dedicated -noupdate -nosteam ${cp}-stdout -paris-server-test -paris-isolated-lab -voicetest $(Get-RoleDir $Mode 'server') " +
    "+set sv_lanOnly 1 +set net_ip 127.0.0.1 +set net_port $ServerPort +exec voicecert_server.cfg +map_rotate"
}

function Get-ClientArguments([string]$Mode, [string]$Role, [string]$Password) {
    $cp = if ($Mode -eq 'CP') { '-cpMode ' } else { '' }
    $port = if ($Role -eq 'A') { $ClientAPort } else { $ClientBPort }
    "-noupdate -nosteam ${cp}-stdout -paris-server-client-test -paris-isolated-lab -voicetest $(Get-RoleDir $Mode $Role) " +
    "+set net_ip 127.0.0.1 +set net_port $port +set password `"$Password`" +set name voicecert$Role " +
    '+set r_fullscreen 0 +set r_fullscreenWindow 0 +set vid_width 1280 +set vid_height 720 +set r_mode 1280x720 ' +
    '+set com_maxfps 30 +set r_picmip 2 +set r_picmip_bump 2 +set r_picmip_spec 2'
}

function Get-ClientSetupCommands {
    $commands = @('cl_voice 1')
    if ($CaptureGate -eq 'Vad') {
        $commands += @('cl_pushToTalk 0', ('winvoice_mic_threshold ' + $MicThreshold.ToString([Globalization.CultureInfo]::InvariantCulture)))
    }
    $commands + "connect 127.0.0.1:$ServerPort"
}

function Hide-Password([string]$Text, [string]$Password) { if ($Password) { $Text.Replace($Password, '<redacted>') } else { $Text } }

# Phrases are assigned in scenario order across the whole run.
$scenarioPlan = [ordered]@{}
$phraseIndex = 0
foreach ($mode in $Modes) {
    $list = @(Get-VcScenarios -Mode $mode -CpSecondMap $CpSecondMap -MpMap $MpMap -IncludeEndOfGame:$IncludeEndOfGame)
    foreach ($scenario in $list) {
        $phrase = $null
        if ($scenario.Inject) { $phrase = $bank[$phraseIndex % $bank.Count]; $phraseIndex++ }
        $scenario | Add-Member PhraseId $(if ($phrase) { $phrase.id } else { $null })
        $scenario | Add-Member RelayExpect $scenario.Expect
        if ($Baseline) { $scenario.Expect = 'silent' }
    }
    $scenarioPlan[$mode] = $list
}

function Get-PreflightProblems {
    $problems = @()
    $ports = @($ServerPort, $ClientAPort, $ClientBPort)
    if (@($ports | Select-Object -Unique).Count -ne 3 -or $ports -contains 27016) { $problems += 'Ports must be distinct test ports, never 27016.' }
    foreach ($name in $roots.Keys) {
        $root = $roots[$name]
        if (!(Test-Path -LiteralPath (Join-Path $root 'iw7_ship.exe') -PathType Leaf)) { $problems += "$name root has no game files: $root" }
        if (Test-Path -LiteralPath (Join-Path $root 'STOCK-ASSETS-REMOVED.json')) { $problems += "$name root is a retired lab: $root" }
    }
    foreach ($name in @('Server', 'B')) {
        $path = Join-Path $roots[$name] 'iw7-mod\paris-isolated-lab.marker'
        if (!(Test-Path -LiteralPath $path -PathType Leaf) -or [IO.File]::ReadAllText($path) -cne $Marker) { $problems += "$name root is not a marked isolated lab root." }
    }
    if (!(Test-Under $ClientBRoot $ServerRoot) -or (Test-Under $ClientBRoot "$ServerRoot\iw7-mod") -or (Test-Under $ClientBRoot "$ServerRoot\mods")) {
        $problems += 'Client B root must be a peer root inside the server root (the resource reservation scope).' }
    if ((Test-Under $ClientARoot $ServerRoot) -or $ClientARoot -eq $ServerRoot -or (Test-Under $ServerRoot $ClientARoot)) { $problems += 'Client A root must be separate from the server root.' }
    $maps = @()
    if ($Modes -contains 'CP') { $maps += @($CpMap, $CpSecondMap) }
    if ($Modes -contains 'MP') { $maps += $MpMap }
    foreach ($map in $maps) {
        if (!(Test-Path -LiteralPath (Join-Path $ServerRoot "$map.ff")) -and !(Test-Path -LiteralPath (Join-Path $ServerRoot "zone\$map.ff"))) { $problems += "Map $map.ff not found in the server root." }
    }
    if (!(Test-Path -LiteralPath $LabImage -PathType Leaf)) { $problems += "Lab image missing: $LabImage" }
    foreach ($root in $roots.Values) { if (Test-Under $LabImage $root) { $problems += 'The lab image must live outside every game root.' } }
    if (!(Test-Path -LiteralPath $BuildManifest -PathType Leaf)) { $problems += "Build manifest missing: $BuildManifest" }
    elseif (Test-Path -LiteralPath $LabImage -PathType Leaf) {
        $manifest = Get-Content -LiteralPath $BuildManifest -Raw | ConvertFrom-Json
        if ($manifest.schema -ne 'iw7.voice-certify-build/1') { $problems += 'Build manifest schema must be iw7.voice-certify-build/1.' }
        if ([string]$manifest.sha256 -ne (Get-FileHash -LiteralPath $LabImage).Hash) { $problems += 'Lab image hash differs from its build manifest.' }
        foreach ($overlay in @('voiceTest', 'isolatedAppData', 'testPrivacy')) {
            if ($manifest.overlays.$overlay -ne $true) { $problems += "Build manifest does not declare the $overlay overlay." }
        }
        if ($manifest.overlays.voiceRelay -isnot [bool] -or $manifest.overlays.voiceRelay -eq [bool]$Baseline) {
            $problems += $(if ($Baseline) { 'A baseline run needs an image built without the voice relay (overlays.voiceRelay false).' }
                else { 'The image must contain the voice relay (overlays.voiceRelay true); use -Baseline for the base image.' })
        }
    }
    if ($OutputRoot -match '[\s"]') { $problems += 'The evidence path must not contain spaces or quotes (it is passed to -voicetest).' }
    if (Test-Path -LiteralPath $OutputRoot) { $problems += "Evidence directory already exists: $OutputRoot" }
    foreach ($root in $roots.Values) { if (Test-Under $OutputRoot $root) { $problems += 'Evidence must live outside every game root.' } }
    if (!(Get-Command python -ErrorAction SilentlyContinue)) { $problems += 'python is not on PATH (needed for the analysis).' }
    $problems
}

# ---------------------------------------------------------------- dry run

function Write-DryRun {
    $budgetGiB = 4 + 2 * 8
    "== Voice certification dry run: nothing is started and nothing is written =="
    "Evidence directory: $OutputRoot"
    "Roots: server $ServerRoot | client A $ClientARoot | client B $ClientBRoot"
    $problems = @(Get-PreflightProblems)
    if ($problems.Count) { "Preflight problems (a real run refuses to start):"; $problems | ForEach-Object { "  ! $_" } }
    else { "Preflight: ok" }
    "[check] no unowned IW7 client is running; no process runs from the server or B root; UDP $ServerPort/$ClientAPort/$ClientBPort free"
    "[reserve] Enter-IW7ResourceLease -Scope $ServerRoot -Kind Runtime ~${budgetGiB} GiB -BaseClientImage $ClientARoot\$ImageName"
    foreach ($name in $transactionPlans.Keys) {
        $t = $transactionPlans[$name]
        "[backup] $name root: files [$($t.MutableFiles -join ', ')] dirs [$($t.ProfileDirectories -join ', ')] -> $OutputRoot\backups\$name"
    }
    foreach ($name in $roots.Keys) { "[stage] copy $LabImage -> $($roots[$name])\$ImageName (hash verified)" }
    "[stage] client A: write iw7-mod\paris-isolated-lab.marker (its AppData moves to iw7-mod\lab-appdata)"
    "[stage] server: remove every .gsc/.gscbin under iw7-mod\custom_scripts and iw7-mod\lab-appdata\cdata\custom_scripts (restored at the end)"
    foreach ($mode in $Modes) {
        $sub = $mode.ToLower()
        ""
        "==== $mode phase ===="
        "[file] $ServerRoot\iw7-mod\voicecert_server.cfg:"
        (Get-ServerConfig $mode '<redacted>') -split "`n" | ForEach-Object { "         $_" }
        "[file] $PSScriptRoot\fixtures\voicecert_$sub.gsc -> $ServerRoot\iw7-mod\custom_scripts\$sub\voicecert_$sub.gsc"
        "[start] server: $ServerRoot\$ImageName $(Get-ServerArguments $mode)   (cwd $ServerRoot, private desktop)"
        "[assert] server stdout: '[voicecert] armed mode=$sub'; fixture heartbeat younger than 6 s; no script compile error"
        "[assert] getinfo 127.0.0.1:${ServerPort}: isPrivate=1 clients=0 mapname=$(if ($mode -eq 'CP') { $CpMap } else { $MpMap })"
        foreach ($role in @('A', 'B')) {
            $root = $roots[$role]
            "[start] client ${role}: $root\$ImageName $(Get-ClientArguments $mode $role '<redacted>')   (cwd $root, private desktop)"
            "[command $role] voicetest_snapshot   (repeated every 3 s until a snapshot event arrives)"
            if ($mode -eq $Modes[0] -and $role -eq 'A') {
                $rate = if ($CaptureRate) { "$CaptureRate Hz (must equal the start event)" } else { 'the rate in the start event' }
                "[phrases] SAPI phrase bank at $rate -> $OutputRoot\phrases"
            }
            foreach ($command in Get-ClientSetupCommands) { "[command $role] $command" }
            "[assert] snapshot clientNum >= 0 and the fixture heartbeat lists it"
        }
        "[assert] A and B have distinct clientNums and distinct iw7-public*.key files in their own iw7-mod\lab-appdata"
        "[assert] both players alive and playing in the heartbeat (up to 180 s; Zombies plays its intro first)"
        foreach ($scenario in $scenarioPlan[$mode]) {
            ""
            "-- $($scenario.Id) ($($scenario.Expect)): $($scenario.Title)"
            foreach ($action in $scenario.Actions) {
                switch ($action.Kind) {
                    'client'    { "   [command $($action.Role)] $($action.Command)" }
                    'server'    { "   [command server] $($action.Command)" }
                    'request'   { "   [command server] set voicecert_req `"<seq> $($action.Verb)`"   then wait for '[voicecert] ack <seq> ... ok'" }
                    'reconnect' { "   [command $($action.Role)] disconnect; wait until the heartbeat drops it; [command $($action.Role)] connect 127.0.0.1:$ServerPort; wait in game" }
                    'awaitmap'  { "   [assert] heartbeat map=$($action.Map) gt=$($action.Gametype) with both players, then fresh clientNums$(if ($action.Fallback) { " (after 90 s: [command server] $($action.Fallback))" })" }
                    'pause'     { "   [wait] $($action.Seconds) s" }
                }
            }
            if ($scenario.RequireAlive) { "   [assert] both players alive and playing in the heartbeat" }
            "   [command A] voicetest_snapshot; [command B] voicetest_snapshot   (flushes recordings; distinct client numbers)"
            "   [command server] voicetest_snapshot   (engine teams and session states, evidence only)"
            foreach ($dir in $scenario.Directions) {
                "   [window] $($dir[1])\recv_{$($dir[0])}.wav byte length before and after"
            }
            if ($scenario.Inject) {
                $talker = $scenario.Directions[0][0]
                "   [command $talker] voicetest_play $OutputRoot\phrases\$($scenario.PhraseId).wav"
                "   [assert] $talker events: play_start and play_end, encoded frames in the window"
            } else { "   [wait] $IdleSeconds s with no injection" }
            if ($scenario.StaleOk) { "   [wait] $TailSeconds s tail; every owned process alive (the heartbeat may stop: the game is ending)" }
            else { "   [wait] $TailSeconds s tail; fixture heartbeat stays fresh; every owned process alive" }
            "   [command A] voicetest_snapshot; [command B] voicetest_snapshot   (flushes recordings; same client numbers; encoded and recv counters)"
            foreach ($dir in $scenario.Directions) {
                if ($scenario.Expect -eq 'heard') {
                    "   [analysis] $($dir[1]) hears $($dir[0]): ASR >= 75% of '$(($bank | Where-Object id -EQ $scenario.PhraseId).text)', speech-band energy >= 60% of the phrase"
                } else { "   [analysis] $($dir[1]) decodes 0 samples from $($dir[0]) and logs no recv event for it" }
            }
        }
        ""
        "[stop] [command B] quit, [command A] quit (forced only after 20 s, owned handles only)"
        "[stop] getinfo clients=0 for $EmptyStopSeconds s, then [command server] quit"
    }
    ""
    "[restore] the three root backups, verified by hash; then Exit-IW7ResourceLease"
    "[analysis] python -I $PSScriptRoot\analyze_voice.py $OutputRoot\analysis-input.json --output $OutputRoot\analysis.json --table $OutputRoot\verdict.md --model $AsrModel"
}

if ($DryRun) { Write-DryRun; return }

# ---------------------------------------------------------------- run

$problems = @(Get-PreflightProblems)
if ($problems.Count) { throw ("Refusing to run:`n  " + ($problems -join "`n  ")) }

. "$opsRoot/Resource-Scheduler.Core.ps1"
. "$opsRoot/Base-Client.Core.ps1"
. "$opsRoot/Lab-Lifecycle.ps1"
. "$opsRoot/Lab-RunPlan.ps1"
if (!('IW7LabProcess' -as [type])) { Add-Type -Path "$opsRoot/native/LabProcess.cs" }

function Assert-NoForeignGame([int[]]$Owned = @()) {
    foreach ($p in @(Get-CimInstance Win32_Process | Where-Object Name -Match '^iw7.*\.exe$')) {
        if ($Owned -contains [int]$p.ProcessId) { continue }
        if (!$p.CommandLine -or $p.CommandLine -notmatch '(?:^|\s)-dedicated(?:\s|$)') { throw 'An IW7 client this run does not own is running; preserve it and retry later.' }
        if ($p.ExecutablePath -and ((Test-Under $p.ExecutablePath $ServerRoot) -or (Test-Under $p.ExecutablePath $ClientBRoot))) { throw "A process this run does not own runs from a test root: $($p.ExecutablePath)" }
    }
}

$owned = [Collections.Generic.List[object]]::new()
function Get-OwnedPids { @($owned | Where-Object { $_.Handle -and !$_.Handle.HasExited } | ForEach-Object { $_.Handle.Id }) }

function Start-Owned([string]$Root, [string]$Arguments, $Role, [string]$Password) {
    Assert-NoForeignGame (Get-OwnedPids)
    $image = Join-Path $Root $ImageName
    [IO.Directory]::CreateDirectory($Role.Dir) | Out-Null
    $desktop = 'IW7ParisLab_' + [guid]::NewGuid().ToString('N')
    $Role.Handle = [IW7LabProcess]::StartOwned($image, $Arguments, $Root, $Role.Stdout, $Role.Stderr, $desktop, ($Role.Name -ne 'server'))
    $process = Get-Process -Id $Role.Handle.Id
    try { $created = $process.StartTime.ToUniversalTime().ToString('o') } finally { $process.Dispose() }
    $Role.Identity = [pscustomobject]@{ Mode = $Role.Mode; Role = $Role.Name; PID = $Role.Handle.Id; Image = $image; CreatedUtc = $created
        SHA256 = (Get-FileHash -LiteralPath $image).Hash; Arguments = (Hide-Password $Arguments $Password); Desktop = $desktop }
    $owned.Add($Role)
    $null = Add-IW7ResourceProcess -Token $script:lease.Token -ProcessId $Role.Handle.Id
    $script:identities += $Role.Identity
    $script:identities | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $OutputRoot 'processes.json')
}

function New-Role([string]$Mode, [string]$Name) {
    $dir = Get-RoleDir $Mode $Name
    [pscustomobject]@{ Mode = $Mode; Name = $Name; Dir = $dir; Commands = Join-Path $dir 'commands.txt'; EventsPath = Join-Path $dir 'events.jsonl'
        Stdout = Join-Path $dir 'stdout.log'; Stderr = Join-Path $dir 'stderr.log'; Handle = $null; Identity = $null
        EventOffset = 0L; Events = [Collections.Generic.List[object]]::new(); LogOffset = 0L; ClientNum = -1; LastSnapshot = $null }
}

function Send-Command($Role, [string]$Command) {
    if ($Command -match '[\r\n]') { throw 'One command per line.' }
    $bytes = [Text.Encoding]::ASCII.GetBytes($Command + "`n")
    for ($try = 0; ; $try++) {
        try {
            $stream = [IO.File]::Open($Role.Commands, 'Append', 'Write', 'ReadWrite')
            try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
            break
        } catch [IO.IOException] { if ($try -ge 40) { throw }; Start-Sleep -Milliseconds 50 }
    }
    $script:trace.Add(('{0:o} {1}/{2} {3}' -f [datetime]::UtcNow, $Role.Mode, $Role.Name, (Hide-Password $Command $script:password)))
}

# Pulls new events of every role and new server stdout lines.
function Update-Phase($Phase) {
    foreach ($role in @($Phase.A, $Phase.B, $Phase.Server)) {
        $read = Read-VcNewLines $role.EventsPath $role.EventOffset
        $role.EventOffset = $read.Offset
        foreach ($line in $read.Lines) {
            $parsed = ConvertFrom-VcEventLine $line
            $role.Events.Add($parsed)
            if (Test-VcEvent $parsed 'Error') { throw "Test component error in $($role.Mode)/$($role.Name): $line" }
        }
    }
    $read = Read-VcNewLines $Phase.Server.Stdout $Phase.Server.LogOffset
    $Phase.Server.LogOffset = $read.Offset
    foreach ($line in $read.Lines) {
        if (Test-VcFatalServerLine $line) { throw "Server fixture failure: $line" }
        if ($line.Contains('[voicecert] armed')) { $Phase.Armed = $true }
        $hb = ConvertFrom-VcHeartbeat $line
        if ($hb) { $Phase.Heartbeat = $hb; $Phase.HeartbeatTick = [Environment]::TickCount64 }
        $ack = ConvertFrom-VcAck $line
        if ($ack) { $Phase.Acks[$ack.Seq] = $ack }
    }
}

function Assert-Healthy($Phase, [switch]$RequireAlive, [switch]$AllowStaleHeartbeat) {
    foreach ($role in @($Phase.Server, $Phase.A, $Phase.B)) {
        if ($role.Handle -and $role.Handle.HasExited) { throw "$($role.Mode) $($role.Name) exited (code $($role.Handle.ExitCode))." }
    }
    if ($AllowStaleHeartbeat) { return }
    if (!$Phase.Heartbeat -or [Environment]::TickCount64 - $Phase.HeartbeatTick -gt 6000) { throw 'Fixture heartbeat is stale: protection is not proven.' }
    foreach ($role in @($Phase.A, $Phase.B)) {
        if ($role.ClientNum -lt 0) { continue }
        $player = $Phase.Heartbeat.Players[[string]$role.ClientNum]
        if (!$player) { throw "Client $($role.Name) (#$($role.ClientNum)) is missing from the server." }
        if ($RequireAlive -and (!$player.Alive -or $player.State -ne 'playing')) { throw "Client $($role.Name) is not alive and playing." }
    }
}

# Waits until $Condition returns a value, keeping every safety check running.
function Wait-For($Phase, [scriptblock]$Condition, [double]$TimeoutSeconds, [string]$What, [switch]$RequireAlive, [switch]$AllowStaleHeartbeat, [scriptblock]$Every) {
    $deadline = [Environment]::TickCount64 + [long]($TimeoutSeconds * 1000)
    while ($true) {
        Update-Phase $Phase
        Assert-Healthy $Phase -RequireAlive:$RequireAlive -AllowStaleHeartbeat:$AllowStaleHeartbeat
        $result = & $Condition
        if ($result) { return $result }
        if ([Environment]::TickCount64 -gt $deadline) { throw "Timed out after $TimeoutSeconds s waiting for: $What" }
        if ($Every) { & $Every }
        Start-Sleep -Milliseconds 250
    }
}

function Wait-Seconds($Phase, [double]$Seconds, [switch]$RequireAlive, [switch]$AllowStaleHeartbeat) {
    $until = [Environment]::TickCount64 + [long]($Seconds * 1000)
    $null = Wait-For $Phase { [Environment]::TickCount64 -ge $until } ($Seconds + 5) "$Seconds s pause" -RequireAlive:$RequireAlive -AllowStaleHeartbeat:$AllowStaleHeartbeat
}

function Get-LastEvent($Role, [string]$Kind, [int]$From = 0) {
    for ($i = $Role.Events.Count - 1; $i -ge $From; $i--) { if (Test-VcEvent $Role.Events[$i] $Kind) { return $Role.Events[$i] } }
    $null
}

# Asks for a snapshot every 3 s (the component may start reading commands.txt
# late) until one arrives; returns the snapshot's clientNum, or -1.
function Sync-Snapshot($Phase, $Role, [double]$TimeoutSeconds = 15) {
    $from = $Role.Events.Count; $script:lastAsk = 0L
    $snapshot = Wait-For $Phase { Get-LastEvent $Role 'Snapshot' $from } $TimeoutSeconds "snapshot from $($Role.Name)" -AllowStaleHeartbeat -Every {
        if ([Environment]::TickCount64 - $script:lastAsk -gt 3000) { Send-Command $Role 'voicetest_snapshot'; $script:lastAsk = [Environment]::TickCount64 }
    }
    $Role.LastSnapshot = $snapshot
    $num = Get-VcField $snapshot $script:VcFieldNames.ClientNum
    if ($null -eq $num) { -1 } else { [int]$num }
}

# In game = a snapshot taken after this call reports clientNum N >= 0 and the
# fixture heartbeat lists player N.
function Wait-InGame($Phase, $Role, [double]$TimeoutSeconds = 240) {
    $from = $Role.Events.Count; $script:lastAsk = 0L
    $num = Wait-For $Phase {
        $snapshot = Get-LastEvent $Role 'Snapshot' $from
        $n = if ($snapshot) { Get-VcField $snapshot $script:VcFieldNames.ClientNum }
        if ($null -ne $n -and [int]$n -ge 0 -and $Phase.Heartbeat -and $Phase.Heartbeat.Players[[string][int]$n]) { [string][int]$n }
    } $TimeoutSeconds "client $($Role.Name) in game" -AllowStaleHeartbeat -Every {
        if ([Environment]::TickCount64 - $script:lastAsk -gt 3000) { Send-Command $Role 'voicetest_snapshot'; $script:lastAsk = [Environment]::TickCount64 }
    }
    $Role.ClientNum = [int]$num
}

function Test-AllAlive($Phase) {
    $hb = $Phase.Heartbeat
    if (!$hb) { return $false }
    foreach ($role in @($Phase.A, $Phase.B)) {
        $player = $hb.Players[[string]$role.ClientNum]
        if (!$player -or !$player.Alive -or $player.State -ne 'playing') { return $false }
    }
    $true
}

function Invoke-Request($Phase, [string]$Verb) {
    $Phase.Seq++
    $seq = [string]$Phase.Seq
    Send-Command $Phase.Server "set voicecert_req `"$seq $Verb`""
    $ack = Wait-For $Phase { $Phase.Acks[$seq] } 60 "server ack for '$Verb'" -AllowStaleHeartbeat
    if (!$ack.Result.StartsWith('ok')) { throw "Server request '$Verb' failed: $($ack.Result)" }
}

function Get-ClientNums($Phase) { @{ A = $Phase.A.ClientNum; B = $Phase.B.ClientNum } }

function Invoke-Action($Phase, $Action) {
    switch ($Action.Kind) {
        'client'  { Send-Command $Phase[$Action.Role] (Resolve-VcCommand $Action.Command (Get-ClientNums $Phase)) }
        'server'  { Send-Command $Phase.Server $Action.Command }
        'request' { Invoke-Request $Phase $Action.Verb }
        'pause'   { Wait-Seconds $Phase $Action.Seconds -AllowStaleHeartbeat }
        'reconnect' {
            $role = $Phase[$Action.Role]; $gone = [string]$role.ClientNum
            Send-Command $role 'disconnect'
            $null = Wait-For $Phase { !$Phase.Heartbeat.Players[$gone] } 30 "client $($role.Name) gone from the server" -AllowStaleHeartbeat
            $role.ClientNum = -1
            Wait-Seconds $Phase 3
            Send-Command $role "connect 127.0.0.1:$ServerPort"
            Wait-InGame $Phase $role
        }
        'awaitmap' {
            $started = [Environment]::TickCount64; $script:fallbackSent = $false
            $null = Wait-For $Phase {
                $hb = $Phase.Heartbeat
                $Phase.HeartbeatTick -gt $started -and $hb.Map -eq $Action.Map -and $hb.Gametype -eq $Action.Gametype
            } 240 "map $($Action.Map) ($($Action.Gametype))" -AllowStaleHeartbeat -Every {
                if ($Action.Fallback -and !$script:fallbackSent -and [Environment]::TickCount64 - $started -gt 90000) {
                    Send-Command $Phase.Server $Action.Fallback; $script:fallbackSent = $true }
            }
            foreach ($name in @('A', 'B')) { $Phase[$name].ClientNum = -1; Wait-InGame $Phase $Phase[$name] }
        }
    }
}

function Measure-Window($Phase, $Scenario) {
    $health = @{ RequireAlive = $Scenario.RequireAlive; AllowStaleHeartbeat = $Scenario.StaleOk }
    # A snapshot also flushes the component's recordings, so file lengths are exact boundaries.
    foreach ($name in @('A', 'B')) { $Phase[$name].ClientNum = Sync-Snapshot $Phase $Phase[$name] }
    if ($Phase.A.ClientNum -lt 0 -or $Phase.B.ClientNum -lt 0 -or $Phase.A.ClientNum -eq $Phase.B.ClientNum) { throw 'Client numbers are not distinct and valid.' }
    $before = @{ A = $Phase.A.LastSnapshot; B = $Phase.B.LastSnapshot }
    Send-Command $Phase.Server 'voicetest_snapshot'   # engine-side teams and session states, kept as evidence
    Assert-Healthy $Phase @health
    $directions = foreach ($dir in $Scenario.Directions) {
        $talker = $Phase[$dir[0]]; $listener = $Phase[$dir[1]]
        $file = Join-Path $listener.Dir "recv_$($talker.ClientNum).wav"
        [pscustomobject]@{ Talker = $talker; Listener = $listener; File = $file; Start = (Get-VcFileLength $file) }
    }
    $from = @{ A = $Phase.A.Events.Count; B = $Phase.B.Events.Count }
    $phrase = $null
    if ($Scenario.Inject) {
        $phrase = $script:phrases.phrases | Where-Object id -EQ $Scenario.PhraseId
        $talker = $directions[0].Talker
        Send-Command $talker "voicetest_play $($phrase.wav)"
        $null = Wait-For $Phase { Get-LastEvent $talker 'PlayStart' $from[$talker.Name] } 15 "play_start on $($talker.Name)" @health
        $null = Wait-For $Phase { Get-LastEvent $talker 'PlayEnd' $from[$talker.Name] } ($phrase.seconds + 15) "play_end on $($talker.Name)" @health
    } else { Wait-Seconds $Phase $IdleSeconds @health }
    Wait-Seconds $Phase $TailSeconds @health
    $nums = Get-ClientNums $Phase
    foreach ($name in @('A', 'B')) {
        $num = Sync-Snapshot $Phase $Phase[$name]
        if ($num -ne $nums[$name] -and !$Scenario.StaleOk) { throw "Client $name changed its client number during $($Scenario.Id)." }
    }
    $after = @{ A = $Phase.A.LastSnapshot; B = $Phase.B.LastSnapshot }
    function Get-Delta($First, $Second) { if ($null -eq $First -or $null -eq $Second) { $null } else { [long]$Second - [long]$First } }
    foreach ($dir in $directions) {
        $talkerEvents = @($dir.Talker.Events | Select-Object -Skip $from[$dir.Talker.Name])
        $listenerEvents = @($dir.Listener.Events | Select-Object -Skip $from[$dir.Listener.Name])
        $t = $dir.Talker.Name; $l = $dir.Listener.Name
        $encodedFrames = Get-Delta (Get-VcField $before[$t] $script:VcFieldNames.Encoded) (Get-VcField $after[$t] $script:VcFieldNames.Encoded)
        $recvSamples = Get-Delta (Get-VcRecvTotal $before[$l] $dir.Talker.ClientNum) (Get-VcRecvTotal $after[$l] $dir.Talker.ClientNum)
        $recv = @($listenerEvents | Where-Object { (Test-VcEvent $_ 'Recv') -and [string](Get-VcField $_ $script:VcFieldNames.Talker) -eq [string]$dir.Talker.ClientNum })
        $id = if (@($Scenario.Directions).Count -gt 1) { "$($Scenario.Id):$($dir.Talker.Name)>$($dir.Listener.Name)" } else { $Scenario.Id }
        [pscustomobject]@{
            id = $id; mode = $Phase.Mode; title = $Scenario.Title; expect = $Scenario.Expect; inject = $Scenario.Inject
            talker = $dir.Talker.Name; listener = $dir.Listener.Name; talker_client = $dir.Talker.ClientNum; listener_client = $dir.Listener.ClientNum
            phrase = $(if ($phrase) { [pscustomobject]@{ id = $phrase.id; text = $phrase.text; wav = [IO.Path]::GetRelativePath($OutputRoot, $phrase.wav) } })
            recording = [pscustomobject]@{ wav = [IO.Path]::GetRelativePath($OutputRoot, $dir.File); start = $dir.Start; end = (Get-VcFileLength $dir.File) }
            play_started = [bool]($talkerEvents | Where-Object { Test-VcEvent $_ 'PlayStart' })
            play_ended = [bool]($talkerEvents | Where-Object { Test-VcEvent $_ 'PlayEnd' })
            talker_encoded_events = @($talkerEvents | Where-Object { Test-VcEvent $_ 'Encoded' }).Count
            talker_encoded_frames = $encodedFrames
            listener_recv_events = $recv.Count
            listener_recv_samples = $recvSamples
            heartbeat = $Phase.Heartbeat
        }
    }
}

function Start-Phase([string]$Mode) {
    $sub = $Mode.ToLower()
    $phase = @{ Mode = $Mode; Server = (New-Role $Mode 'server'); A = (New-Role $Mode 'A'); B = (New-Role $Mode 'B')
        Seq = 0; Acks = @{}; Heartbeat = $null; HeartbeatTick = 0L; Armed = $false }
    $script:phase = $phase
    [IO.File]::WriteAllText((Join-Path $ServerRoot 'iw7-mod\voicecert_server.cfg'), (Get-ServerConfig $Mode $script:password) + "`n", [Text.UTF8Encoding]::new($false))
    Set-Content -LiteralPath (Join-Path $OutputRoot "configs\$sub-server.cfg") -Value (Get-ServerConfig $Mode '<redacted>')
    foreach ($other in @('cp', 'mp')) {
        $target = Join-Path $ServerRoot "iw7-mod\custom_scripts\$other\voicecert_$other.gsc"
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target }
    }
    [IO.Directory]::CreateDirectory((Join-Path $ServerRoot "iw7-mod\custom_scripts\$sub")) | Out-Null
    Copy-Item -LiteralPath "$PSScriptRoot\fixtures\voicecert_$sub.gsc" -Destination (Join-Path $ServerRoot "iw7-mod\custom_scripts\$sub\voicecert_$sub.gsc")

    $null = Start-Owned $ServerRoot (Get-ServerArguments $Mode) $phase.Server $script:password
    $null = Wait-For $phase { $phase.Armed -and $phase.Heartbeat } 240 'fixture armed with a heartbeat' -AllowStaleHeartbeat
    $info = & "$opsRoot/Get-ServerInfo.ps1" -Port $ServerPort
    $map = if ($Mode -eq 'CP') { $CpMap } else { $MpMap }
    if ($info.isPrivate -ne '1' -or $info.clients -ne '0' -or $info.mapname -ne $map) { throw "Server is not the expected private empty $map dedicated." }
    $script:serverInfo += [pscustomobject]@{ Mode = $Mode; Info = $info }

    foreach ($name in @('A', 'B')) {
        $role = $phase[$name]
        $null = Start-Owned $roots[$name] (Get-ClientArguments $Mode $name $script:password) $role $script:password
        $null = Sync-Snapshot $phase $role 240
        $start = Get-LastEvent $role 'Start'
        $rate = if ($start) { Get-VcField $start $script:VcFieldNames.Rate } else { $null }
        if ($null -eq $rate) { if (!$CaptureRate) { throw "Client $name reported no native capture rate; pass -CaptureRate." }; $rate = $CaptureRate }
        if ($CaptureRate -and [int]$rate -ne $CaptureRate) { throw "Native capture rate $rate differs from -CaptureRate $CaptureRate." }
        if (!$script:phrases) {
            $script:phrases = New-VcPhraseSet (Join-Path $OutputRoot 'phrases') ([int]$rate) $bank
            $script:phrases | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $OutputRoot 'phrases\phrases.json')
        } elseif ([int]$rate -ne $script:phrases.rate) { throw "Client $name capture rate $rate differs from the phrase rate $($script:phrases.rate)." }
        foreach ($command in Get-ClientSetupCommands) { Send-Command $role $command }
        Wait-InGame $phase $role
    }
    if ($phase.A.ClientNum -eq $phase.B.ClientNum) { throw 'Both clients report the same clientNum.' }
    $keys = foreach ($name in @('A', 'B')) {
        $found = @(Get-ChildItem -LiteralPath (Join-Path $roots[$name] 'iw7-mod\lab-appdata') -Filter 'iw7-public*.key' -File -ErrorAction SilentlyContinue)
        if (!$found.Count) { throw "Client $name has no identity in its own iw7-mod\lab-appdata: the isolated AppData overlay is not active." }
        [pscustomobject]@{ Role = $name; Files = @($found.Name); SHA256 = @($found | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName).Hash }) }
    }
    if (@($keys[0].SHA256 | Where-Object { $keys[1].SHA256 -contains $_ }).Count) { throw 'Clients A and B share a public identity.' }
    $script:identityKeys += [pscustomobject]@{ Mode = $Mode; Keys = $keys }
    $phase
}

function Stop-Phase($Phase) {
    $errors = @()
    foreach ($role in @($Phase.B, $Phase.A)) {
        if (!$role.Handle -or $role.Handle.HasExited) { continue }
        try {
            if ($role.Handle.ReadIdentity().Image -ne $role.Identity.Image) { throw 'identity changed' }
            $stop = Invoke-IW7OwnedStop -Handle $role.Handle -TimeoutMs 20000 -StopAction { Send-Command $role 'quit' }
            $role.Identity | Add-Member Stop $stop.Kind -Force
        } catch { $errors += "$($role.Name): $($_.Exception.Message)" }
    }
    $server = $Phase.Server
    if ($server.Handle -and !$server.Handle.HasExited) {
        try {
            if (@($Phase.A, $Phase.B | Where-Object { $_.Handle -and !$_.Handle.HasExited }).Count) { throw 'clients still running' }
            $emptySince = 0L; $deadline = [Environment]::TickCount64 + ($EmptyStopSeconds + 60) * 1000L
            while ([Environment]::TickCount64 - $emptySince -lt $EmptyStopSeconds * 1000L -or !$emptySince) {
                if ([Environment]::TickCount64 -gt $deadline) { throw 'no stable zero-client window; server preserved' }
                $info = & "$opsRoot/Get-ServerInfo.ps1" -Port $ServerPort
                if ($info.clients -ne '0') { $emptySince = 0L } elseif (!$emptySince) { $emptySince = [Environment]::TickCount64 }
                Start-Sleep -Seconds 1
            }
            if ($server.Handle.ReadIdentity().Image -ne $server.Identity.Image) { throw 'identity changed' }
            $stop = Invoke-IW7OwnedStop -Handle $server.Handle -TimeoutMs 20000 -StopAction { Send-Command $server 'quit' }
            $server.Identity | Add-Member Stop $stop.Kind -Force
        } catch { $errors += "server: $($_.Exception.Message)" }
    }
    $script:identities | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $OutputRoot 'processes.json')
    if ($errors.Count) { throw ('Stop incomplete (processes preserved): ' + ($errors -join '; ')) }
}

function Write-Provenance {
    $manifest = Get-Content -LiteralPath $BuildManifest -Raw | ConvertFrom-Json
    $files = @("$PSScriptRoot\Invoke-VoiceCertify.ps1", "$PSScriptRoot\VoiceCertify.Core.ps1", "$PSScriptRoot\analyze_voice.py",
        "$PSScriptRoot\phrases.json", "$PSScriptRoot\fixtures\voicecert_cp.gsc", "$PSScriptRoot\fixtures\voicecert_mp.gsc")
    $candidate = $null
    if ($CandidateSource) {
        $voice = Join-Path $CandidateSource 'src\client\component\voice.cpp'
        $candidate = [pscustomobject]@{ Path = $CandidateSource; Head = (git -C $CandidateSource rev-parse HEAD)
            DiffSHA256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(((git -C $CandidateSource diff) -join "`n"))))
            VoiceCppSHA256 = $(if (Test-Path -LiteralPath $voice) { (Get-FileHash -LiteralPath $voice).Hash }) }
    }
    [pscustomobject]@{
        LabImage = $LabImage; LabImageSHA256 = (Get-FileHash -LiteralPath $LabImage).Hash; BuildManifest = $manifest; Candidate = $candidate
        Harness = [pscustomobject]@{ Head = (git -C $repo rev-parse HEAD); Dirty = @(git -C $repo status --porcelain).Count
            Files = @($files | ForEach-Object { [pscustomobject]@{ File = [IO.Path]::GetRelativePath($repo, $_); SHA256 = (Get-FileHash -LiteralPath $_).Hash } }) }
        Options = [pscustomobject]@{ Modes = $Modes; ServerPort = $ServerPort; ClientAPort = $ClientAPort; ClientBPort = $ClientBPort; CpMap = $CpMap
            CpSecondMap = $CpSecondMap; MpMap = $MpMap; IncludeEndOfGame = [bool]$IncludeEndOfGame; CaptureGate = $CaptureGate; MicThreshold = $MicThreshold; AsrModel = $AsrModel }
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputRoot 'build.json')
}

Assert-NoForeignGame
foreach ($port in @($ServerPort, $ClientAPort, $ClientBPort)) {
    if (Get-NetUDPEndpoint -LocalPort $port -ErrorAction SilentlyContinue) { throw "UDP port $port is in use." }
}
foreach ($dir in @('configs', 'backups')) { [IO.Directory]::CreateDirectory((Join-Path $OutputRoot $dir)) | Out-Null }
$script:password = [guid]::NewGuid().ToString('N')
$script:trace = [Collections.Generic.List[string]]::new()
$script:identities = @(); $script:serverInfo = @(); $script:identityKeys = @(); $script:phrases = $null; $script:phase = $null
$script:lease = $null
$windows = [Collections.Generic.List[object]]::new()
$transactions = [ordered]@{}
$failure = $null; $cleanupError = $null; $restored = $false
Write-Provenance

try {
    $budget = Get-IW7LabRunPlan -PlannedClients 2 -GraphicsProfile Reduced
    $script:lease = Enter-IW7ResourceLease -Scope $ServerRoot -Kind Runtime -PhysicalBytes $budget.PhysicalBytes -CommitBytes $budget.CommitBytes `
        -Owner 'Voice certification: test dedicated and two clients' -BaseClientImage (Join-Path $ClientARoot $ImageName)
    foreach ($name in $transactionPlans.Keys) { $transactions[$name] = Save-IW7BaseTransaction $transactionPlans[$name] (Join-Path $OutputRoot "backups\$name") }
    $hash = (Get-FileHash -LiteralPath $LabImage).Hash
    foreach ($root in $roots.Values) {
        $target = Join-Path $root $ImageName
        Copy-Item -LiteralPath $LabImage -Destination $target -Force
        if ((Get-FileHash -LiteralPath $target).Hash -ne $hash) { throw "Staged image hash mismatch: $target" }
    }
    [IO.File]::WriteAllText((Join-Path $ClientARoot 'iw7-mod\paris-isolated-lab.marker'), $Marker, [Text.UTF8Encoding]::new($false))
    foreach ($dir in @('iw7-mod\custom_scripts', 'iw7-mod\lab-appdata\cdata\custom_scripts')) {
        $path = Join-Path $ServerRoot $dir
        if (Test-Path -LiteralPath $path) { Get-ChildItem -LiteralPath $path -Recurse -File -Include '*.gsc', '*.gscbin' | Remove-Item }
    }
    foreach ($mode in $Modes) {
        $phase = Start-Phase $mode
        # Zombies plays an intro before the first spawn; start once both players are in the world
        $null = Wait-For $phase { Test-AllAlive $phase } 180 'both players alive and playing'
        foreach ($scenario in $scenarioPlan[$mode]) {
            Write-Host "[$mode] $($scenario.Id): $($scenario.Title)"
            foreach ($action in $scenario.Actions) { Invoke-Action $phase $action }
            if ($scenario.RequireAlive) { $null = Wait-For $phase { Test-AllAlive $phase } 60 'both players alive and playing' }
            Wait-Seconds $phase $SettleSeconds -RequireAlive:$scenario.RequireAlive -AllowStaleHeartbeat:$scenario.StaleOk
            foreach ($window in @(Measure-Window $phase $scenario)) { $windows.Add($window) }
            $windows | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputRoot 'windows.json')
        }
        Stop-Phase $phase
        $script:phase = $null
    }
} catch {
    $failure = $_
    [pscustomobject]@{ Message = $_.Exception.Message; Stack = $_.ScriptStackTrace } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputRoot 'failure.json')
} finally {
    try {
        if ($script:phase) { Stop-Phase $script:phase }
        if (@($owned | Where-Object { $_.Handle -and !$_.Handle.HasExited }).Count) { throw 'Owned processes still running; backups and reservation retained.' }
        foreach ($name in @($transactions.Keys)) { $null = Restore-IW7BaseTransaction $transactions[$name] }
        $restored = $true
        if ($script:lease) { $null = Exit-IW7ResourceLease -Token $script:lease.Token }
    } catch { $cleanupError = $_.Exception.Message }
    foreach ($role in $owned) { if ($role.Handle -and $role.Handle.HasExited) { $role.Handle.Dispose() } }
    $script:trace | Set-Content -LiteralPath (Join-Path $OutputRoot 'commands.log')
    [pscustomobject]@{ ServerInfo = $script:serverInfo; IdentityKeys = $script:identityKeys } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputRoot 'checks.json')
}

# ---------------------------------------------------------------- analysis

$verdict = 'INCOMPLETE'
if ($windows.Count) {
    [pscustomobject]@{ schema = 'iw7.voice-certify.analysis-input/1'; complete = (!$failure); windows = $windows } |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputRoot 'analysis-input.json')
    & python -I "$PSScriptRoot\analyze_voice.py" (Join-Path $OutputRoot 'analysis-input.json') --output (Join-Path $OutputRoot 'analysis.json') `
        --table (Join-Path $OutputRoot 'verdict.md') --model $AsrModel
    if (Test-Path -LiteralPath (Join-Path $OutputRoot 'analysis.json')) {
        $analysis = Get-Content -LiteralPath (Join-Path $OutputRoot 'analysis.json') -Raw | ConvertFrom-Json
        $verdict = if ($failure) { 'INCOMPLETE' } else { $analysis.summary.verdict }
        Get-Content -LiteralPath (Join-Path $OutputRoot 'verdict.md')
    }
}
[pscustomobject]@{ Verdict = $verdict; Failure = $(if ($failure) { $failure.Exception.Message }); CleanupError = $cleanupError
    Restored = $restored; Evidence = $OutputRoot; OwnerAcceptance = $false } | Tee-Object -Variable result | ConvertTo-Json |
    Set-Content -LiteralPath (Join-Path $OutputRoot 'result.json')
$result
if ($cleanupError) { throw "Cleanup pending: $cleanupError. Evidence: $OutputRoot" }
