#Requires -Version 7
<#
.SYNOPSIS
Voice certification: tests the upstream voice component on real game processes,
in Zombies and Multiplayer, including the cases where a player must NOT hear.
Not yet run against a game process.

.DESCRIPTION
Known speech is injected at the start of client A's (or B's) native capture
pipeline by the private test component (voice_test.cpp, -voicetest) and the
decoded PCM is recorded per talker at the receiver's native playback enqueue.
Everything in between is unmodified production code.

The three game roots (server, client A, client B) are disposable bench roots,
siblings under one -LeaseScope folder (the server repository's
ops/voicecert/Invoke-VoiceCertifyBench.ps1 makes and removes them). -DryRun
prints every process, file change, command and assertion and starts nothing.
See docs/VOICE-CERTIFY.md.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ServerRoot,
    [Parameter(Mandatory)][string]$ClientARoot,
    [Parameter(Mandatory)][string]$ClientBRoot,
    # Folder whose direct children are the three roots; the resource reservation scope. Default: their common parent.
    [string]$LeaseScope,
    # The server repository's ops/bench/Bench-Root.Core.ps1: every root must then be a valid isolated-lab bench.
    [string]$BenchCore,
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
    # A client not in game this long after its launch is stopped (owned handle) and launched again.
    [ValidateRange(30, 600)][int]$JoinTimeoutSeconds = 120,
    [ValidateRange(0, 3)][int]$JoinRetries = 2,
    # Busy refusals of the shareable reservation are retried until this many seconds have passed.
    [ValidateRange(0, 14400)][int]$WaitForSlotSeconds = 3600,
    # Declared memory of the session: one dedicated and two clients.
    [ValidateRange(1, 256)][double]$LeasePhysicalGB = 11,
    [ValidateRange(1, 512)][double]$LeaseCommitGB = 24,
    [string]$OutputRoot,
    # Base image without the relay: the "before" run. Every window must then be silent.
    [switch]$Baseline,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/VoiceCertify.Core.ps1"
$opsRoot = Split-Path $PSScriptRoot -Parent
$repo = Split-Path $opsRoot -Parent
# Pure path and transaction helpers (Save-IW7BaseTransaction, Get-IW7BaseFiles); dot-sourcing starts nothing.
. "$opsRoot/Base-Client.Core.ps1"

$ImageName = 'iw7-voicecert.exe'
$Marker = 'iw7-paris-isolated-lab-v1'
# Built in two pieces: the scheduler reads running command lines, and a runner whose
# own command line carried the whole flag would count as a foreign laboratory.
$LabFlag = '-paris-' + 'isolated-lab'
$CdataDir = 'iw7-mod/lab-appdata/cdata'
$SettleSeconds = 1.5; $TailSeconds = 2.5; $IdleSeconds = 5
$ConnectFirstSeconds = @{ CP = 20; MP = 25 }; $ConnectEverySeconds = 10
$bank = @((Get-Content -LiteralPath "$PSScriptRoot/phrases.json" -Raw | ConvertFrom-Json).phrases)

function Get-FullPath([string]$Path) { [IO.Path]::GetFullPath($Path).TrimEnd('\', '/') }
function Test-Under([string]$Path, [string]$Root) { $Path.StartsWith($Root + '\', [StringComparison]::OrdinalIgnoreCase) }
function Test-Same([string]$A, [string]$B) { [string]::Equals($A, $B, [StringComparison]::OrdinalIgnoreCase) }
$ServerRoot = Get-FullPath $ServerRoot
$ClientARoot = Get-FullPath $ClientARoot
$ClientBRoot = Get-FullPath $ClientBRoot
$roots = [ordered]@{ Server = $ServerRoot; A = $ClientARoot; B = $ClientBRoot }
$rolePorts = @{ Server = $ServerPort; A = $ClientAPort; B = $ClientBPort }
if ($LeaseScope) { $LeaseScope = Get-FullPath $LeaseScope }
else {
    $parents = @($roots.Values | ForEach-Object { Split-Path $_ -Parent } | Select-Object -Unique)
    $LeaseScope = if ($parents.Count -eq 1) { $parents[0] } else { '' }
}
$LabImage = Get-FullPath $LabImage
if (!$BuildManifest) { $BuildManifest = Join-Path (Split-Path $LabImage) 'voice-certify-build.json' }
$stamp = [datetime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6)
$OutputRoot = if ($OutputRoot) { Get-FullPath $OutputRoot } else { Join-Path $repo "runtime\voice-certify\$stamp" }
$isBench = [bool]$BenchCore
if ($BenchCore) {
    $BenchCore = Get-FullPath $BenchCore
    # Defines Test-IW7BenchRoot (read-only: it never opens game data and writes nothing).
    if (Test-Path -LiteralPath $BenchCore -PathType Leaf) { . $BenchCore }
}

# ---------------------------------------------------------------- plan

# Clients run with -paris-server-client-test and the isolated-lab flag, so the lab
# fixture (paris_test_fixture.cpp) writes these files in each client root. The
# list matches the base-client transaction in ops/Base-Client.Core.ps1, plus the
# temporary name of the join request.
$fixtureFiles = @('iw7-mod/paris-server-client.request', 'iw7-mod/paris-server-client.request.tmp', 'iw7-mod/paris-server-client.response',
    'iw7-mod/screenshots/server-modules-fixture.bmp', 'iw7-mod/paris-agent.session', 'iw7-mod/paris-agent.request', 'iw7-mod/paris-agent.response',
    'iw7-mod/paris-agent.safety')
$dcache = @('main/data0.dcache', 'main/data1.dcache', 'main/toc0.dcache', 'main/toc1.dcache')
# On a bench, the copied updater data (about 377 MB) is disposable: it is neither
# backed up nor restored. The rest of lab-appdata (keys, players) is. The server's
# updater scripts are still backed up: the run moves them out of the way.
$exclude = if ($isBench) { @($CdataDir) } else { @() }
$serverDirs = @('iw7-mod/players2', 'iw7-mod/lab-appdata', 'iw7-mod/custom_scripts', 'iw7-mod/logs')
if ($isBench) { $serverDirs += "$CdataDir/custom_scripts" }
$transactionPlans = [ordered]@{
    Server = [pscustomobject]@{ GameRoot = $ServerRoot; MutableFiles = @($ImageName, 'iw7-mod/voicecert_server.cfg')
        ProfileDirectory = 'iw7-mod/players2'; ProfileDirectories = $serverDirs; ExcludeDirectories = $exclude }
    A = [pscustomobject]@{ GameRoot = $ClientARoot; MutableFiles = @($ImageName, 'iw7-mod/paris-isolated-lab.marker') + $dcache + $fixtureFiles
        ProfileDirectory = 'iw7-mod/players2'; ProfileDirectories = @('iw7-mod/players2', 'iw7-mod/lab-appdata', 'iw7-mod/logs'); ExcludeDirectories = $exclude }
    B = [pscustomobject]@{ GameRoot = $ClientBRoot; MutableFiles = @($ImageName, 'iw7-mod/paris-isolated-lab.marker') + $dcache + $fixtureFiles
        ProfileDirectory = 'iw7-mod/players2'; ProfileDirectories = @('iw7-mod/players2', 'iw7-mod/lab-appdata', 'iw7-mod/logs'); ExcludeDirectories = $exclude }
}

function Get-RoleDir([string]$Mode, [string]$Role, [int]$Attempt = 0) {
    Join-Path $OutputRoot ("$($Mode.ToLower())\$Role" + $(if ($Attempt) { "-retry$Attempt" } else { '' }))
}

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
    "-dedicated -allow_root_io -noupdate -nosteam ${cp}-stdout -paris-server-test $LabFlag -voicetest $(Get-RoleDir $Mode 'server') " +
    "+set sv_lanOnly 1 +set net_ip 127.0.0.1 +set net_port $ServerPort +exec voicecert_server.cfg +map_rotate"
}

function Get-ClientArguments([string]$Mode, [string]$Role, [string]$Password, [string]$Dir) {
    $cp = if ($Mode -eq 'CP') { '-cpMode ' } else { '' }
    $port = if ($Role -eq 'A') { $ClientAPort } else { $ClientBPort }
    "-noupdate -nosteam ${cp}-stdout -paris-server-client-test $LabFlag -voicetest $Dir " +
    "+set net_ip 127.0.0.1 +set net_port $port +set paris_lab_server_port $ServerPort +set password `"$Password`" +set name voicecert$Role " +
    '+set r_fullscreen 0 +set r_fullscreenWindow 0 +set vid_width 1280 +set vid_height 720 +set r_mode 1280x720 ' +
    '+set com_maxfps 30 +set r_picmip 2 +set r_picmip_bump 2 +set r_picmip_spec 2'
}

# Sent through commands.txt once the component answers. The join itself is not
# here: CP joins through the fixture's request file, MP through a console connect,
# both repeated by the join loop.
function Get-ClientSetupCommands {
    $commands = @('cl_voice 1')
    if ($CaptureGate -eq 'Vad') {
        $commands += @('cl_pushToTalk 0', ('winvoice_mic_threshold ' + $MicThreshold.ToString([Globalization.CultureInfo]::InvariantCulture)))
    }
    $commands
}

function Get-JoinDescription([string]$Mode, [string]$Root) {
    if ($Mode -eq 'CP') {
        "write '<pid> <32 hex nonce> connect' to $Root\iw7-mod\paris-server-client.request (temporary name, then move); read the .response"
    } else { "[command] connect 127.0.0.1:$ServerPort through commands.txt (the fixture's connect forces Zombies, so MP cannot use it)" }
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

# Every file of a root that the run writes, restores or removes: the planned
# mutable files and what the tracked profile directories hold now.
function Get-GuardedFiles($Plan) {
    $files = @($Plan.MutableFiles)
    foreach ($directory in $Plan.ProfileDirectories) {
        $files += @(Get-IW7BaseFiles $Plan.GameRoot $directory | Where-Object { !(Test-IW7BaseExcluded $_ $directory @($Plan.ExcludeDirectories)) })
    }
    @($files | Select-Object -Unique)
}

# The read-only bench check (bench core) on every root. Returns one record per root.
function Invoke-BenchChecks {
    foreach ($name in $roots.Keys) {
        try {
            $check = Test-IW7BenchRoot -Root $roots[$name]
            [pscustomobject]@{ Role = $name; Root = $roots[$name]; Ok = [bool]$check.Ok; Problems = @($check.Problems); Links = $check.Links
                Copies = $check.Copies; RunFiles = $check.RunFiles; ForeignLinkedFiles = $check.ForeignLinkedFiles; ExtraDiskBytes = $check.ExtraDiskBytes; Error = $null }
        } catch {
            [pscustomobject]@{ Role = $name; Root = $roots[$name]; Ok = $false; Problems = @(); Error = $_.Exception.Message }
        }
    }
}

$script:benchBefore = @()
function Get-PreflightProblems {
    $problems = @()
    $ports = @($ServerPort, $ClientAPort, $ClientBPort)
    if (@($ports | Select-Object -Unique).Count -ne 3 -or $ports -contains 27016) { $problems += 'Ports must be distinct test ports, never 27016.' }
    $names = @($roots.Keys)
    for ($i = 0; $i -lt $names.Count; $i++) {
        for ($j = $i + 1; $j -lt $names.Count; $j++) {
            $x = $roots[$names[$i]]; $y = $roots[$names[$j]]
            if ((Test-Same $x $y) -or (Test-Under $x $y) -or (Test-Under $y $x)) { $problems += "The $($names[$i]) and $($names[$j]) roots must be separate folders, neither inside the other." }
        }
    }
    if (!$LeaseScope) { $problems += 'The three roots must be siblings in one folder (or pass -LeaseScope).' }
    else {
        if ($LeaseScope.Length -le 3) { $problems += 'The lease scope cannot be a drive root.' }
        foreach ($name in $roots.Keys) {
            if (!(Test-Same (Split-Path $roots[$name] -Parent) $LeaseScope)) { $problems += "The $name root must be a direct child of the lease scope $LeaseScope." }
        }
    }
    foreach ($name in $roots.Keys) {
        $root = $roots[$name]
        if (!(Test-Path -LiteralPath (Join-Path $root 'iw7_ship.exe') -PathType Leaf)) { $problems += "$name root has no game files: $root" }
        if (Test-Path -LiteralPath (Join-Path $root 'STOCK-ASSETS-REMOVED.json')) { $problems += "$name root is a retired lab: $root" }
        $path = Join-Path $root 'iw7-mod\paris-isolated-lab.marker'
        if (!(Test-Path -LiteralPath $path -PathType Leaf) -or [IO.File]::ReadAllText($path) -cne $Marker) { $problems += "$name root is not a marked isolated lab root." }
    }
    $maps = @()
    if ($Modes -contains 'CP') { $maps += @($CpMap, $CpSecondMap) }
    if ($Modes -contains 'MP') { $maps += $MpMap }
    foreach ($name in $roots.Keys) {
        foreach ($map in $maps) {
            if (!(Test-Path -LiteralPath (Join-Path $roots[$name] "$map.ff")) -and !(Test-Path -LiteralPath (Join-Path $roots[$name] "zone\$map.ff"))) { $problems += "Map $map.ff not found in the $name root." }
        }
    }
    if ($BenchCore) {
        if (!(Get-Command Test-IW7BenchRoot -ErrorAction SilentlyContinue)) { $problems += "The bench core does not define Test-IW7BenchRoot: $BenchCore" }
        else {
            foreach ($name in $roots.Keys) { $problems += @(Get-VcBenchManifestProblems $roots[$name] $name $rolePorts[$name]) }
            $script:benchBefore = @(Invoke-BenchChecks)
            foreach ($check in $script:benchBefore) {
                if ($check.Error) { $problems += "$($check.Role) bench check refused: $($check.Error)" }
                foreach ($problem in $check.Problems) { $problems += "$($check.Role) bench: $problem" }
            }
        }
    }
    foreach ($name in $transactionPlans.Keys) {
        $plan = $transactionPlans[$name]
        if (!(Test-Path -LiteralPath $plan.GameRoot -PathType Container)) { continue }
        try { $problems += @(Get-VcLinkProblems $plan.GameRoot (Get-GuardedFiles $plan)) } catch { $problems += "$name root files cannot be listed: $($_.Exception.Message)" }
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
    foreach ($root in $roots.Values) { if ((Test-Under $OutputRoot $root) -or (Test-Same $OutputRoot $root)) { $problems += 'Evidence must live outside every game root.' } }
    if (!(Get-Command python -ErrorAction SilentlyContinue)) { $problems += 'python is not on PATH (needed for the analysis).' }
    $problems
}

# ---------------------------------------------------------------- dry run

function Write-DryRun {
    "== Voice certification dry run: nothing is started and nothing is written =="
    "Evidence directory: $OutputRoot"
    "Roots: server $ServerRoot | client A $ClientARoot | client B $ClientBRoot"
    "Lease scope: $(if ($LeaseScope) { $LeaseScope } else { '<none: the roots are not siblings>' })"
    $problems = @(Get-PreflightProblems)
    if ($BenchCore) {
        foreach ($check in $script:benchBefore) {
            "[bench check] $($check.Role): $(if ($check.Error) { "refused: $($check.Error)" } elseif ($check.Ok) { "ok ($($check.Links) shared files, $($check.Copies) copies, $($check.RunFiles) run files)" } else { "$(@($check.Problems).Count) problem(s)" })"
        }
    } else { "[bench check] none (no -BenchCore): the roots are not checked as bench roots" }
    if ($problems.Count) { "Preflight problems (a real run refuses to start):"; $problems | ForEach-Object { "  ! $_" } }
    else { "Preflight: ok" }
    "[check] no process this run does not own runs from $LeaseScope; UDP $ServerPort/$ClientAPort/$ClientBPort free"
    "[reserve] Enter-IW7ResourceLease -Scope $LeaseScope -Kind Runtime -Shareable, $LeasePhysicalGB GB physical, $LeaseCommitGB GB commit; busy refusals retried (30 s doubling to 300 s) for up to $WaitForSlotSeconds s"
    foreach ($name in $transactionPlans.Keys) {
        $t = $transactionPlans[$name]
        $skip = if (@($t.ExcludeDirectories).Count) { " not [$($t.ExcludeDirectories -join ', ')] (disposable bench copy)" } else { '' }
        "[backup] $name root: files [$($t.MutableFiles -join ', ')] dirs [$($t.ProfileDirectories -join ', ')]$skip -> $OutputRoot\backups\$name"
    }
    "[guard] every file above and $ImageName must be absent or have exactly one name, before the backup and again before the restore"
    foreach ($name in $roots.Keys) { "[stage] copy $LabImage -> $($roots[$name])\$ImageName (hash verified)" }
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
            "[start] client ${role}: $root\$ImageName $(Get-ClientArguments $mode $role '<redacted>' (Get-RoleDir $mode $role))   (cwd $root, private desktop)"
            "[command $role] voicetest_snapshot   (repeated every 3 s until a snapshot event arrives)"
            if ($mode -eq $Modes[0] -and $role -eq 'A') {
                $rate = if ($CaptureRate) { "$CaptureRate Hz (must equal the start event)" } else { 'the rate in the start event' }
                "[phrases] SAPI phrase bank at $rate -> $OutputRoot\phrases"
            }
            foreach ($command in Get-ClientSetupCommands) { "[command $role] $command" }
            "[join $role] $(Get-JoinDescription $mode $root): first $($ConnectFirstSeconds[$mode]) s after the launch, then every $ConnectEverySeconds s while the client reports no joining state"
            "[join $role] not in game $JoinTimeoutSeconds s after the launch: stop it by its owned handle and launch it again (evidence in $(Get-RoleDir $mode $role 1)), at most $JoinRetries time(s)"
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
                    'reconnect' { "   [command $($action.Role)] disconnect; wait until the heartbeat drops it; [join $($action.Role)] $(Get-JoinDescription $mode $roots[$action.Role]) at once, then every $ConnectEverySeconds s; wait in game" }
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
    if ($BenchCore) { "[bench check] the read-only bench check again on each root; any problem is a cleanup error (checks.json)" }
    "[analysis] python -I $PSScriptRoot\analyze_voice.py $OutputRoot\analysis-input.json --output $OutputRoot\analysis.json --table $OutputRoot\verdict.md --model $AsrModel"
}

if ($DryRun) { Write-DryRun; return }

# ---------------------------------------------------------------- run

$problems = @(Get-PreflightProblems)
if ($problems.Count) { throw ("Refusing to run:`n  " + ($problems -join "`n  ")) }

. "$opsRoot/Resource-Scheduler.Core.ps1"
. "$opsRoot/Lab-Lifecycle.ps1"
if (!('IW7LabProcess' -as [type])) { Add-Type -Path "$opsRoot/native/LabProcess.cs" }

# Other agents' sessions elsewhere on this machine are fine (the shareable
# reservation admits them by memory). Only an iw7 process this run does not own
# whose program lies inside our lease scope is refused.
function Assert-NoForeignGame([int[]]$Owned = @()) {
    foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name LIKE 'iw7%'")) {
        if ($Owned -contains [int]$p.ProcessId) { continue }
        if ($p.ExecutablePath -and (Test-Under $p.ExecutablePath $LeaseScope)) {
            throw "A process this run does not own runs from the lease scope: $($p.ExecutablePath) (pid $($p.ProcessId)); preserve it."
        }
    }
}

$owned = [Collections.Generic.List[object]]::new()
function Get-OwnedPids { @($owned | Where-Object { $_.Handle -and !$_.Handle.HasExited } | ForEach-Object { $_.Handle.Id }) }

function Save-ProcessEvidence {
    $script:identities | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $OutputRoot 'processes.json')
    @($script:joins) | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputRoot 'joins.json')
}

function Start-Owned([string]$Root, [string]$Arguments, $Role, [string]$Password) {
    Assert-NoForeignGame (Get-OwnedPids)
    $image = Join-Path $Root $ImageName
    [IO.Directory]::CreateDirectory($Role.Dir) | Out-Null
    $desktop = 'IW7ParisLab_' + [guid]::NewGuid().ToString('N')
    $Role.Handle = [IW7LabProcess]::StartOwned($image, $Arguments, $Root, $Role.Stdout, $Role.Stderr, $desktop, ($Role.Name -ne 'server'))
    $process = Get-Process -Id $Role.Handle.Id
    try { $created = $process.StartTime.ToUniversalTime().ToString('o') } finally { $process.Dispose() }
    $Role.Identity = [pscustomobject]@{ Mode = $Role.Mode; Role = $Role.Name; Attempt = $Role.Attempt; PID = $Role.Handle.Id; Image = $image; CreatedUtc = $created
        SHA256 = (Get-FileHash -LiteralPath $image).Hash; Arguments = (Hide-Password $Arguments $Password); Desktop = $desktop; Dir = $Role.Dir; JoinResult = $null }
    $owned.Add($Role)
    $null = Add-IW7ResourceProcess -Token $script:lease.Token -ProcessId $Role.Handle.Id
    $script:identities += $Role.Identity
    Save-ProcessEvidence
}

function New-Role([string]$Mode, [string]$Name, [int]$Attempt = 0) {
    $dir = Get-RoleDir $Mode $Name $Attempt
    [pscustomobject]@{ Mode = $Mode; Name = $Name; Attempt = $Attempt; Root = $roots[$(if ($Name -eq 'server') { 'Server' } else { $Name })]; Dir = $dir
        Commands = Join-Path $dir 'commands.txt'; EventsPath = Join-Path $dir 'events.jsonl'
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
# A timeout throws a message that starts with 'Timed out'.
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

function New-JoinRecord($Role, [string]$Kind) {
    $record = [pscustomobject]@{ Mode = $Role.Mode; Role = $Role.Name; Kind = $Kind; Attempt = $Role.Attempt; PID = $(if ($Role.Handle) { $Role.Handle.Id })
        Channel = $(if ($Role.Mode -eq 'CP') { 'request' } else { 'console' }); StartedUtc = [datetime]::UtcNow.ToString('o'); Connects = [Collections.Generic.List[object]]::new()
        Result = $null; Seconds = $null; LastConnectionState = $null; StdoutTail = @(); Stop = $null; StartTick = [Environment]::TickCount64; LastSendTick = $null }
    $script:joins.Add($record)
    $record
}

# One connect ask. CP: the lab fixture's request file (proven by the server
# repository's network lab); MP: a console connect (the fixture's connect forces Zombies).
function Send-Connect($Role, $Join) {
    $at = [Math]::Round(([Environment]::TickCount64 - $Join.StartTick) / 1000.0, 1)
    if ($Role.Mode -eq 'CP') {
        $line = New-VcRequestLine $Role.Handle.Id 'connect'
        $request = Join-Path $Role.Root 'iw7-mod\paris-server-client.request'
        [IO.File]::WriteAllText("$request.tmp", $line, [Text.Encoding]::ASCII)
        Move-Item -LiteralPath "$request.tmp" -Destination $request -Force
        $script:trace.Add(('{0:o} {1}/{2} request {3}' -f [datetime]::UtcNow, $Role.Mode, $Role.Name, $line))
        $Join.Connects.Add([pscustomobject]@{ At = $at; Line = $line; Answered = $false; AnsweredAt = $null })
    } else {
        Send-Command $Role "connect 127.0.0.1:$ServerPort"
        $Join.Connects.Add([pscustomobject]@{ At = $at; Line = "connect 127.0.0.1:$ServerPort"; Answered = $null; AnsweredAt = $null })
    }
    $Join.LastSendTick = [Environment]::TickCount64
}

function Step-Join($Role, $Join) {
    if ($Role.Mode -eq 'CP') {
        $response = Join-Path $Role.Root 'iw7-mod\paris-server-client.response'
        foreach ($connect in @($Join.Connects | Where-Object { !$_.Answered })) {
            try {
                if ((Test-Path -LiteralPath $response) -and [IO.File]::ReadAllText($response).Trim() -eq $connect.Line) {
                    $connect.Answered = $true; $connect.AnsweredAt = [Math]::Round(([Environment]::TickCount64 - $Join.StartTick) / 1000.0, 1)
                }
            } catch {}
        }
    }
    $Join.LastConnectionState = Get-VcLastConnectionState $Role.Events
    $since = ([Environment]::TickCount64 - $Join.StartTick) / 1000.0
    $sinceSend = if ($null -eq $Join.LastSendTick) { $null } else { ([Environment]::TickCount64 - $Join.LastSendTick) / 1000.0 }
    $first = if ($Join.Kind -eq 'reconnect') { 0 } else { $ConnectFirstSeconds[$Role.Mode] }
    if (Test-VcJoinResendDue $since $sinceSend $first $ConnectEverySeconds $Join.LastConnectionState) { Send-Connect $Role $Join }
}

# In game = a snapshot taken after this call reports clientNum N >= 0 and the
# fixture heartbeat lists player N. With $Join, the client is also asked to connect.
function Wait-InGame($Phase, $Role, [double]$TimeoutSeconds = 240, $Join = $null) {
    $from = $Role.Events.Count; $script:lastAsk = 0L
    $num = Wait-For $Phase {
        $snapshot = Get-LastEvent $Role 'Snapshot' $from
        $n = if ($snapshot) { Get-VcField $snapshot $script:VcFieldNames.ClientNum }
        if ($null -ne $n -and [int]$n -ge 0 -and $Phase.Heartbeat -and $Phase.Heartbeat.Players[[string][int]$n]) { [string][int]$n }
    } $TimeoutSeconds "client $($Role.Name) in game" -AllowStaleHeartbeat -Every {
        if ([Environment]::TickCount64 - $script:lastAsk -gt 3000) { Send-Command $Role 'voicetest_snapshot'; $script:lastAsk = [Environment]::TickCount64 }
        if ($Join) { Step-Join $Role $Join }
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
            # The reconnect is the scenario under test: it is asked again but never relaunched.
            $join = New-JoinRecord $role 'reconnect'
            try { Wait-InGame $Phase $role 240 $join; $join.Result = 'joined' }
            catch { $join.Result = 'failed'; throw }
            finally { $join.Seconds = [Math]::Round(([Environment]::TickCount64 - $join.StartTick) / 1000.0, 1); Save-ProcessEvidence }
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
            # The clients follow the map change themselves; no connect is sent here.
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
            talker_attempt = $dir.Talker.Attempt; listener_attempt = $dir.Listener.Attempt
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

function Remove-JoinRequestFiles([string]$Root) {
    foreach ($name in @('paris-server-client.request', 'paris-server-client.request.tmp', 'paris-server-client.response')) {
        $path = Join-Path $Root "iw7-mod\$name"
        if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force }
    }
}

# Launches one client and joins it. A client not in game $JoinTimeoutSeconds
# after its launch is stopped by its owned handle and launched again (a fresh
# evidence folder <role>-retry<n>), at most $JoinRetries times.
function Join-Client($Phase, [string]$Name) {
    for ($attempt = 0; ; $attempt++) {
        $role = if ($attempt -eq 0) { $Phase[$Name] } else { New-Role $Phase.Mode $Name $attempt }
        $Phase[$Name] = $role
        Remove-JoinRequestFiles $role.Root
        $null = Start-Owned $role.Root (Get-ClientArguments $Phase.Mode $Name $script:password $role.Dir) $role $script:password
        $join = New-JoinRecord $role 'launch'
        try {
            $null = Sync-Snapshot $Phase $role $JoinTimeoutSeconds
            $start = Get-LastEvent $role 'Start'
            $rate = if ($start) { Get-VcField $start $script:VcFieldNames.Rate } else { $null }
            if ($null -eq $rate) { if (!$CaptureRate) { throw "Client $Name reported no native capture rate; pass -CaptureRate." }; $rate = $CaptureRate }
            if ($CaptureRate -and [int]$rate -ne $CaptureRate) { throw "Native capture rate $rate differs from -CaptureRate $CaptureRate." }
            if (!$script:phrases) {
                $script:phrases = New-VcPhraseSet (Join-Path $OutputRoot 'phrases') ([int]$rate) $bank
                $script:phrases | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $OutputRoot 'phrases\phrases.json')
            } elseif ([int]$rate -ne $script:phrases.rate) { throw "Client $Name capture rate $rate differs from the phrase rate $($script:phrases.rate)." }
            foreach ($command in Get-ClientSetupCommands) { Send-Command $role $command }
            $left = [Math]::Max(5, $JoinTimeoutSeconds - ([Environment]::TickCount64 - $join.StartTick) / 1000.0)
            Wait-InGame $Phase $role $left $join
            $join.Result = 'joined'; $role.Identity.JoinResult = 'joined'
            return
        } catch {
            if (!$_.Exception.Message.StartsWith('Timed out')) { $join.Result = 'failed'; $role.Identity.JoinResult = 'failed'; throw }
            $join.Result = 'stalled'; $role.Identity.JoinResult = 'stalled'
            $join.StdoutTail = @(Get-Content -LiteralPath $role.Stdout -Tail 20 -ErrorAction SilentlyContinue | ForEach-Object { ($_ -replace "`e\[[0-9;]*m", '').Trim() } |
                Where-Object { $_ } | Select-Object -Last 5 | ForEach-Object { $_.Substring(0, [Math]::Min(200, $_.Length)) })
            Write-Host "[$($Phase.Mode)] client $Name not in game $JoinTimeoutSeconds s after launch $($attempt + 1); stopping it"
            if ($role.Handle.ReadIdentity().Image -ne $role.Identity.Image) { throw "Client $Name identity changed; preserved." }
            $stop = Invoke-IW7OwnedStop -Handle $role.Handle -TimeoutMs 10000 -StopAction { Send-Command $role 'quit' }
            $role.Identity | Add-Member Stop $stop.Kind -Force
            $join.Stop = $stop.Kind
            if ($attempt -ge $JoinRetries) { throw "Client $Name did not join within $JoinTimeoutSeconds s after $($attempt + 1) launch(es)." }
        } finally {
            $join.Seconds = [Math]::Round(([Environment]::TickCount64 - $join.StartTick) / 1000.0, 1)
            Save-ProcessEvidence
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

    foreach ($name in @('A', 'B')) { Join-Client $phase $name }
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
            if (@($owned | Where-Object { $_.Name -ne 'server' -and $_.Handle -and !$_.Handle.HasExited }).Count) { throw 'clients still running' }
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
    Save-ProcessEvidence
    if ($errors.Count) { throw ('Stop incomplete (processes preserved): ' + ($errors -join '; ')) }
}

function Write-Provenance {
    $manifest = Get-Content -LiteralPath $BuildManifest -Raw | ConvertFrom-Json
    $files = @("$PSScriptRoot\Invoke-VoiceCertify.ps1", "$PSScriptRoot\VoiceCertify.Core.ps1", "$PSScriptRoot\analyze_voice.py",
        "$PSScriptRoot\phrases.json", "$PSScriptRoot\fixtures\voicecert_cp.gsc", "$PSScriptRoot\fixtures\voicecert_mp.gsc", "$opsRoot\Base-Client.Core.ps1")
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
        Roots = [pscustomobject]@{ Server = $ServerRoot; A = $ClientARoot; B = $ClientBRoot; LeaseScope = $LeaseScope; BenchCore = $BenchCore
            BenchCoreSHA256 = $(if ($BenchCore) { (Get-FileHash -LiteralPath $BenchCore).Hash }) }
        Options = [pscustomobject]@{ Modes = $Modes; ServerPort = $ServerPort; ClientAPort = $ClientAPort; ClientBPort = $ClientBPort; CpMap = $CpMap
            CpSecondMap = $CpSecondMap; MpMap = $MpMap; IncludeEndOfGame = [bool]$IncludeEndOfGame; CaptureGate = $CaptureGate; MicThreshold = $MicThreshold; AsrModel = $AsrModel
            JoinTimeoutSeconds = $JoinTimeoutSeconds; JoinRetries = $JoinRetries; WaitForSlotSeconds = $WaitForSlotSeconds; LeasePhysicalGB = $LeasePhysicalGB; LeaseCommitGB = $LeaseCommitGB }
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputRoot 'build.json')
}

function Assert-TransactionLinks {
    $found = @()
    foreach ($name in @($transactions.Keys)) {
        $found += @(Get-VcLinkProblems $transactions[$name].GameRoot @($transactions[$name].Files | ForEach-Object Path))
    }
    $script:linkGuard += [pscustomobject]@{ At = [datetime]::UtcNow.ToString('o'); Problems = @($found) }
    if ($found.Count) { throw ('Link guard: ' + ($found -join ' ')) }
}

# Shareable reservation, retried on busy refusals the way the server repository's
# network lab does (30 s, doubling up to 300 s, until -WaitForSlotSeconds).
function Enter-Lease {
    $deadline = [datetime]::UtcNow.AddSeconds($WaitForSlotSeconds); $pause = 30
    while (!$script:lease) {
        try {
            $script:lease = Enter-IW7ResourceLease -Scope $LeaseScope -Kind Runtime -PhysicalBytes ([long]($LeasePhysicalGB * 1GB)) -CommitBytes ([long]($LeaseCommitGB * 1GB)) `
                -Owner 'Voice certification: test dedicated and two clients' -Shareable
        } catch {
            $message = $_.Exception.Message
            if ($message -notmatch 'Resource busy|already reserved|laboratory is running|wait before heavy admission|identity unavailable|lock busy') { throw }
            $script:leaseWaits += [pscustomobject]@{ At = [datetime]::UtcNow.ToString('o'); Refusal = $message.Substring(0, [Math]::Min(300, $message.Length)) }
            if ([datetime]::UtcNow -ge $deadline) { throw "The reservation stayed busy for $WaitForSlotSeconds s: $message" }
            Write-Host "Reservation busy; retrying (waited up to $WaitForSlotSeconds s): $($message.Substring(0, [Math]::Min(160, $message.Length)))"
            Start-Sleep -Seconds ([Math]::Min($pause, [Math]::Max(1, ($deadline - [datetime]::UtcNow).TotalSeconds))); $pause = [Math]::Min(300, $pause * 2)
        }
    }
}

Assert-NoForeignGame
foreach ($port in @($ServerPort, $ClientAPort, $ClientBPort)) {
    if (Get-NetUDPEndpoint -LocalPort $port -ErrorAction SilentlyContinue) { throw "UDP port $port is in use." }
}
foreach ($dir in @('configs', 'backups')) { [IO.Directory]::CreateDirectory((Join-Path $OutputRoot $dir)) | Out-Null }
$script:password = [guid]::NewGuid().ToString('N')
$script:trace = [Collections.Generic.List[string]]::new()
$script:identities = @(); $script:serverInfo = @(); $script:identityKeys = @(); $script:phrases = $null; $script:phase = $null
$script:joins = [Collections.Generic.List[object]]::new(); $script:leaseWaits = @(); $script:linkGuard = @(); $script:benchAfter = @()
$script:lease = $null; $leaseReleased = $false
$windows = [Collections.Generic.List[object]]::new()
$transactions = [ordered]@{}
$failure = $null; $cleanupErrors = [Collections.Generic.List[string]]::new(); $restored = $false
Write-Provenance

try {
    Enter-Lease
    Assert-NoForeignGame
    foreach ($name in $transactionPlans.Keys) { $transactions[$name] = Save-IW7BaseTransaction $transactionPlans[$name] (Join-Path $OutputRoot "backups\$name") }
    Assert-TransactionLinks
    $hash = (Get-FileHash -LiteralPath $LabImage).Hash
    foreach ($root in $roots.Values) {
        $target = Join-Path $root $ImageName
        if ((Get-VcLinkCount $target) -gt 1) { throw "Link guard: $target has several names." }
        Copy-Item -LiteralPath $LabImage -Destination $target -Force
        if ((Get-FileHash -LiteralPath $target).Hash -ne $hash) { throw "Staged image hash mismatch: $target" }
    }
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
        if ($transactions.Count) { Assert-TransactionLinks }
        foreach ($name in @($transactions.Keys)) { $null = Restore-IW7BaseTransaction $transactions[$name] }
        $restored = $true
        if ($script:lease) {
            # 'Reserved process identity unavailable' is transient (a process is starting or exiting): ask again.
            $lastError = $null
            for ($i = 0; $i -lt 8 -and !$leaseReleased; $i++) {
                try { $null = Exit-IW7ResourceLease -Token $script:lease.Token; $leaseReleased = $true }
                catch { $lastError = $_.Exception.Message; if ($lastError -notmatch 'identity unavailable') { break }; Start-Sleep -Seconds 4 }
            }
            if (!$leaseReleased) { throw "Reservation not released: $lastError" }
        }
    } catch { $cleanupErrors.Add($_.Exception.Message) }
    if ($BenchCore) {
        $script:benchAfter = @(Invoke-BenchChecks)
        foreach ($check in $script:benchAfter) {
            if ($check.Error) { $cleanupErrors.Add("$($check.Role) bench check refused after the run: $($check.Error)") }
            foreach ($problem in $check.Problems) { $cleanupErrors.Add("$($check.Role) bench after the run: $problem") }
        }
    }
    foreach ($role in $owned) { if ($role.Handle -and $role.Handle.HasExited) { $role.Handle.Dispose() } }
    $script:trace | Set-Content -LiteralPath (Join-Path $OutputRoot 'commands.log')
    Save-ProcessEvidence
    [pscustomobject]@{ ServerInfo = $script:serverInfo; IdentityKeys = $script:identityKeys; Joins = @($script:joins)
        Lease = [pscustomobject]@{ Scope = $LeaseScope; Shareable = $true; PhysicalBytes = [long]($LeasePhysicalGB * 1GB); CommitBytes = [long]($LeaseCommitGB * 1GB)
            Waits = $script:leaseWaits; Released = $leaseReleased }
        LinkGuard = $script:linkGuard
        BenchChecks = [pscustomobject]@{ Core = $BenchCore; Before = $script:benchBefore; After = $script:benchAfter } } |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputRoot 'checks.json')
}
$cleanupError = if ($cleanupErrors.Count) { $cleanupErrors -join ' | ' } else { $null }

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
