# Offline tests of the voice certification orchestrator: the pure helpers, the
# base transaction's bench exclusion, and dry runs against throw-away fake roots
# that must start no process and write nothing.
# Run: pwsh -NoProfile -File tests/voice-certify/test_voicecertify.ps1
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$harness = Join-Path $repo 'ops\voice-certify'
. "$harness\VoiceCertify.Core.ps1"
. "$repo\ops\Base-Client.Core.ps1"
$failures = 0; $passed = 0
function Check([string]$Name, [scriptblock]$Test) {
    try { if (!(& $Test)) { throw 'returned false' }; $script:passed++; "ok   $Name" }
    catch { $script:failures++; "FAIL $Name : $($_.Exception.Message)" }
}

# ---- helpers

Check 'scenario matrix' {
    $cp = @(Get-VcScenarios -Mode CP); $mp = @(Get-VcScenarios -Mode MP); $mp3 = @(Get-VcScenarios -Mode MP -IncludeEndOfGame)
    ($cp.Id -join ',') -eq 'C0,C1,C2,C3a,C3b,C4a,C4b,C5,C6a,C6b' -and ($mp.Id -join ',') -eq 'M0,M1a,M1b,M2a,M2b,M4a,M4b' -and
    ($mp3.Id -join ',') -eq 'M0,M1a,M1b,M2a,M2b,M3,M4a,M4b' -and @($cp | Where-Object Expect -EQ 'silent').Count -eq 3 -and
    @($cp[0].Directions).Count -eq 2 -and !$cp[0].Inject -and ($mp3 | Where-Object Id -EQ 'M3').StaleOk
}
Check 'heartbeat parsing' {
    $hb = ConvertFrom-VcHeartbeat 'x [voicecert] hb t=9 mode=mp map=mp_frontier gt=war n=2 p=0,allies,playing,1,100,allies p=3,axis,dead,0,0,axis'
    $hb.Map -eq 'mp_frontier' -and $hb.Gametype -eq 'war' -and $hb.Count -eq 2 -and $hb.Players['0'].Alive -and
    !$hb.Players['3'].Alive -and $hb.Players['3'].Team -eq 'axis' -and !(ConvertFrom-VcHeartbeat '[voicecert] armed mode=cp')
}
Check 'ack parsing' { $a = ConvertFrom-VcAck '[voicecert] ack 7 teams fail timeout'; $a.Seq -eq '7' -and $a.Verb -eq 'teams' -and $a.Result -eq 'fail timeout' }
Check 'fatal server lines' { (Test-VcFatalServerLine '******* script compile error *******') -and (Test-VcFatalServerLine '[voicecert] refused: x') -and !(Test-VcFatalServerLine '[voicecert] hb t=1') }
Check 'command placeholders' {
    $ok = (Resolve-VcCommand 'voicetest_mute {A}' @{ A = 2; B = 5 }) -eq 'voicetest_mute 2'
    $unresolved = try { Resolve-VcCommand 'voicetest_mute {C}' @{ A = 2 }; $false } catch { $true }
    $multiline = try { Resolve-VcCommand "quit`nmap x" @{}; $false } catch { $true }
    $ok -and $unresolved -and $multiline
}
Check 'event fields and aliases' {
    $e = ConvertFrom-VcEventLine '{"t":5,"event":"snapshot","client_num":3}'
    (Test-VcEvent $e 'Snapshot') -and (Get-VcField $e $script:VcFieldNames.ClientNum) -eq 3 -and
    (ConvertFrom-VcEventLine '{broken').event -eq 'malformed'
}
Check 'last connection state' {
    $events = [Collections.Generic.List[object]]::new()
    $none = Get-VcLastConnectionState $events
    foreach ($line in '{"event":"connection","state":0}', '{"event":"snapshot","client_num":-1}', '{"event":"connection","state":7}', '{"event":"encoded"}') { $events.Add((ConvertFrom-VcEventLine $line)) }
    $null -eq $none -and (Get-VcLastConnectionState $events) -eq 7 -and (Get-VcLastConnectionState @($events[0], $events[1])) -eq 0
}
Check 'join resend timing' {
    # first ask after the delay whatever the state; later asks every 10 s, never while joining (3..8);
    # 9 does not block (live run 1: a client at 9 in its own front end, clientNum -1)
    !(Test-VcJoinResendDue 19 $null 20 10 $null) -and (Test-VcJoinResendDue 20 $null 20 10 5) -and
    (Test-VcJoinResendDue 40 10 20 10 0) -and !(Test-VcJoinResendDue 40 9.9 20 10 0) -and
    !(Test-VcJoinResendDue 60 30 20 10 3) -and !(Test-VcJoinResendDue 60 30 20 10 8) -and (Test-VcJoinResendDue 60 30 20 10 9) -and
    (Test-VcJoinResendDue 60 30 20 10 $null) -and (Test-VcJoinResendDue 0 $null 0 10 9)
}
Check 'server XUID, ready and connection lines' {
    $x = ConvertFrom-VcServerXuid '[33mSetting client 1 XUID to c99a303fd5e99710[0m'
    $x.Slot -eq 1 -and $x.Xuid -eq 'C99A303FD5E99710' -and !(ConvertFrom-VcServerXuid 'Setting client XUID') -and
    (ConvertFrom-VcReadyLine '[Paris module client] Ready loopback join to UDP 27416.') -eq 27416 -and $null -eq (ConvertFrom-VcReadyLine 'Request connect dispatched') -and
    (Test-VcServerConnectionLine 'Client 0 timed out') -and (Test-VcServerConnectionLine 'voicecertA disconnected') -and
    !(Test-VcServerConnectionLine '[voicecert] hb t=1 n=2') -and !(Test-VcServerConnectionLine '[Paris test privacy] private=1')
}
Check 'on our server needs the heartbeat slot and the same XUID on both sides' {
    $hb = ConvertFrom-VcHeartbeat '[voicecert] hb t=9 mode=cp map=cp_zmb gt=zombie n=1 p=0,allies,playing,1,100,0'
    $users = @([pscustomobject]@{ slot = 0; xuid = 'D468DB20EB6EAC3D' }, [pscustomobject]@{ slot = 1; xuid = '0000000000000000' })
    $snap = [pscustomobject]@{ event = 'snapshot'; client_num = 0; users = $users }
    $local = [pscustomobject]@{ event = 'snapshot'; client_num = -1; users = $users }
    $other = [pscustomobject]@{ event = 'snapshot'; client_num = 0; users = @([pscustomobject]@{ slot = 0; xuid = '1111111111111111' }) }
    (Test-VcOnServer $snap $hb @{ '0' = 'D468DB20EB6EAC3D' }) -and !(Test-VcOnServer $local $hb @{ '0' = 'D468DB20EB6EAC3D' }) -and
    !(Test-VcOnServer $other $hb @{ '0' = 'D468DB20EB6EAC3D' }) -and !(Test-VcOnServer $snap $hb @{}) -and
    !(Test-VcOnServer ([pscustomobject]@{ event = 'snapshot'; client_num = 1; users = $users }) $hb @{ '1' = 'X' })
}
Check 'request line format' {
    $line = New-VcRequestLine 4242 'connect'
    $bad = try { New-VcRequestLine 0 'connect'; $false } catch { $true }
    $badNonce = try { New-VcRequestLine 1 'connect' 'XYZ'; $false } catch { $true }
    $line -cmatch '^4242 [0-9a-f]{32} connect$' -and $bad -and $badNonce
}
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('vc-test-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($tmp) | Out-Null
try {
    Check 'line follower leaves a partial line for later' {
        $path = Join-Path $tmp 'events.jsonl'
        [IO.File]::WriteAllText($path, "{`"event`":`"a`"}`n{`"event`":`"b`"")
        $first = Read-VcNewLines $path 0
        [IO.File]::AppendAllText($path, "}`n")
        $second = Read-VcNewLines $path $first.Offset
        $first.Lines.Count -eq 1 -and $second.Lines.Count -eq 1 -and $second.Lines[0] -eq '{"event":"b"}' -and (Read-VcNewLines (Join-Path $tmp 'none') 0).Lines.Count -eq 0
    }
    Check 'WAV write/read round trip' {
        $pcm = [byte[]](1..200 | ForEach-Object { $_ % 256 })
        Write-VcWav (Join-Path $tmp 'a.wav') 8000 $pcm
        $back = Read-VcWavPcm (Join-Path $tmp 'a.wav') 8000
        (Get-Item (Join-Path $tmp 'a.wav')).Length -eq 244 -and [Convert]::ToHexString($back) -eq [Convert]::ToHexString($pcm)
    }
    Check 'link count and link guard' {
        $one = Join-Path $tmp 'single.bin'; [IO.File]::WriteAllText($one, 'x')
        $two = Join-Path $tmp 'linked.bin'; New-Item -ItemType HardLink -Path $two -Target $one | Out-Null
        $alone = Join-Path $tmp 'alone.bin'; [IO.File]::WriteAllText($alone, 'y')
        $problems = @(Get-VcLinkProblems $tmp @('linked.bin', 'alone.bin', 'missing.bin'))
        $result = (Get-VcLinkCount $two) -eq 2 -and (Get-VcLinkCount $alone) -eq 1 -and (Get-VcLinkCount (Join-Path $tmp 'missing.bin')) -eq 0 -and
            $problems.Count -eq 1 -and $problems[0].Contains('linked.bin') -and $problems[0].Contains('2 names')
        Remove-Item -LiteralPath $one, $two, $alone
        $result
    }
    Check 'bench transaction leaves the copied updater data out but keeps keys and scripts' {
        $root = Join-Path $tmp 'txroot'
        foreach ($d in 'iw7-mod\lab-appdata\cdata\custom_scripts\cp', 'iw7-mod\lab-appdata\cdata\zone', 'iw7-mod\players2') { [IO.Directory]::CreateDirectory((Join-Path $root $d)) | Out-Null }
        [IO.File]::WriteAllText((Join-Path $root 'iw7_ship.exe'), 'ship')
        [IO.File]::WriteAllText((Join-Path $root 'iw7-mod\lab-appdata\iw7-public1.key'), 'key')
        [IO.File]::WriteAllText((Join-Path $root 'iw7-mod\lab-appdata\cdata\zone\big.ff'), 'big')
        [IO.File]::WriteAllText((Join-Path $root 'iw7-mod\lab-appdata\cdata\custom_scripts\cp\patches.gsc'), 'gsc')
        $plan = [pscustomobject]@{ GameRoot = $root; MutableFiles = @('iw7-voicecert.exe'); ProfileDirectory = 'iw7-mod/players2'
            ProfileDirectories = @('iw7-mod/players2', 'iw7-mod/lab-appdata', 'iw7-mod/lab-appdata/cdata/custom_scripts'); ExcludeDirectories = @('iw7-mod/lab-appdata/cdata') }
        $backup = Join-Path $tmp 'txbackup'
        $t = Save-IW7BaseTransaction $plan $backup
        $saved = @($t.Files | ForEach-Object Path)
        Remove-Item -LiteralPath (Join-Path $root 'iw7-mod\lab-appdata\cdata\custom_scripts\cp\patches.gsc')
        [IO.File]::WriteAllText((Join-Path $root 'iw7-mod\lab-appdata\iw7-public1.key'), 'changed')
        [IO.File]::WriteAllText((Join-Path $root 'iw7-mod\lab-appdata\new-run.txt'), 'run')
        [IO.File]::WriteAllText((Join-Path $root 'iw7-mod\lab-appdata\cdata\zone\cache.bin'), 'game wrote this')
        [IO.File]::WriteAllText((Join-Path $root 'iw7-voicecert.exe'), 'staged')
        $null = Restore-IW7BaseTransaction $t
        $ok = ($saved -notcontains 'iw7-mod/lab-appdata/cdata/zone/big.ff') -and ($saved -contains 'iw7-mod/lab-appdata/iw7-public1.key') -and
            ($saved -contains 'iw7-mod/lab-appdata/cdata/custom_scripts/cp/patches.gsc') -and
            !(Test-Path (Join-Path $backup 'iw7-mod\lab-appdata\cdata\zone\big.ff')) -and
            [IO.File]::ReadAllText((Join-Path $root 'iw7-mod\lab-appdata\iw7-public1.key')) -eq 'key' -and
            (Test-Path (Join-Path $root 'iw7-mod\lab-appdata\cdata\custom_scripts\cp\patches.gsc')) -and
            !(Test-Path (Join-Path $root 'iw7-mod\lab-appdata\new-run.txt')) -and !(Test-Path (Join-Path $root 'iw7-voicecert.exe')) -and
            (Test-Path (Join-Path $root 'iw7-mod\lab-appdata\cdata\zone\cache.bin')) -and (Test-Path (Join-Path $root 'iw7-mod\lab-appdata\cdata\zone\big.ff'))
        Remove-Item -LiteralPath $root, $backup -Recurse -Force
        $ok
    }
    Check 'transaction without exclusions is unchanged' {
        $root = Join-Path $tmp 'txplain'
        [IO.Directory]::CreateDirectory((Join-Path $root 'iw7-mod\lab-appdata\cdata')) | Out-Null
        [IO.File]::WriteAllText((Join-Path $root 'iw7-mod\lab-appdata\cdata\x.txt'), 'x')
        $plan = [pscustomobject]@{ GameRoot = $root; MutableFiles = @(); ProfileDirectory = 'iw7-mod/lab-appdata'; ProfileDirectories = @('iw7-mod/lab-appdata') }
        $t = Save-IW7BaseTransaction $plan (Join-Path $tmp 'txplainbackup')
        $ok = @($t.Files | ForEach-Object Path) -contains 'iw7-mod/lab-appdata/cdata/x.txt' -and @($t.ExcludeDirectories).Count -eq 0
        Remove-Item -LiteralPath $root, (Join-Path $tmp 'txplainbackup') -Recurse -Force
        $ok
    }

    # ---- dry runs against fake sibling roots

    $scope = Join-Path $tmp 'scope'
    $server = Join-Path $scope 'server'; $clientA = Join-Path $scope 'a'; $clientB = Join-Path $scope 'b'; $out = Join-Path $tmp 'evidence'
    $ports = @{ $server = 27416; $clientA = 27417; $clientB = 27418 }
    foreach ($root in @($server, $clientA, $clientB)) {
        [IO.Directory]::CreateDirectory((Join-Path $root 'iw7-mod')) | Out-Null
        [IO.File]::WriteAllText((Join-Path $root 'iw7_ship.exe'), 'x')
        [IO.File]::WriteAllText((Join-Path $root 'iw7-mod\paris-isolated-lab.marker'), 'iw7-paris-isolated-lab-v1')
        foreach ($map in @('cp_zmb', 'cp_rave', 'mp_frontier')) { [IO.File]::WriteAllText((Join-Path $root "$map.ff"), 'x') }
        # a synthetic bench manifest: what the harness itself checks (the stub core below stands in for the real check)
        [pscustomobject]@{ schema = 'iw7.bench-root/1'; root = $root; rootIdentity = 'x'; stockRoot = 'x'; entries = @()
            identity = [pscustomobject]@{ name = (Split-Path $root -Leaf); port = $ports[$root]; isolatedLab = $true } } |
            ConvertTo-Json -Depth 4 | Set-Content (Join-Path $root 'paris-bench-root.json')
    }
    $stubCore = Join-Path $tmp 'Stub-Bench.Core.ps1'
    Set-Content -LiteralPath $stubCore -Value @'
function Test-IW7BenchRoot([string]$Root) {
    $m = Get-Content -LiteralPath (Join-Path $Root 'paris-bench-root.json') -Raw | ConvertFrom-Json
    $problems = @(); if ($m.identity.name -eq 'broken') { $problems += 'SHARED DATA WAS WRITTEN (date changed): stock\z1.ff' }
    [pscustomobject]@{ Ok = !$problems.Count; Problems = $problems; Links = 3; Copies = 1; RunFiles = 0; ForeignLinkedFiles = 0; ExtraDiskBytes = 0 }
}
'@
    $build = Join-Path $tmp 'build'; [IO.Directory]::CreateDirectory($build) | Out-Null
    $image = Join-Path $build 'iw7-mod.exe'; [IO.File]::WriteAllText($image, 'lab image')
    [pscustomobject]@{ schema = 'iw7.voice-certify-build/1'; sha256 = (Get-FileHash $image).Hash
        overlays = [pscustomobject]@{ voiceTest = $true; voiceRelay = $true; isolatedAppData = $true; testPrivacy = $true } } | ConvertTo-Json | Set-Content (Join-Path $build 'voice-certify-build.json')
    function Get-TreeState { @(Get-ChildItem $tmp -Recurse -Force | ForEach-Object { if ($_.PSIsContainer) { $_.FullName } else { $_.FullName + '|' + $_.Length + '|' + $_.LastWriteTimeUtc.Ticks } }) }
    $before = Get-TreeState
    $childrenBefore = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$PID" | ForEach-Object ProcessId)
    $common = @{ ServerRoot = $server; ClientARoot = $clientA; ClientBRoot = $clientB; LabImage = $image; OutputRoot = $out; DryRun = $true }

    # Directory times are compared by presence only: NTFS updates them lazily.
    # Any attempt to start a process from the dry run path throws.
    $blocked = @('python', 'py', 'git', 'pwsh', 'powershell', 'cmd', 'Start-Process', 'Start-Job')
    foreach ($name in $blocked) { Set-Item "Function:global:$name" -Value ([scriptblock]::Create("throw 'dry run attempted to start: $name'")) }
    try {
        $output = & "$harness\Invoke-VoiceCertify.ps1" @common -IncludeEndOfGame
        $benchOutput = & "$harness\Invoke-VoiceCertify.ps1" @common -BenchCore $stubCore -Modes CP
        $diagOutput = & "$harness\Invoke-VoiceCertify.ps1" @common -Modes CP -Diagnostics
    } finally {
        foreach ($name in $blocked) { Remove-Item "Function:global:$name" }
    }
    $text = $output -join "`n"
    $benchText = $benchOutput -join "`n"
    Check 'dry run: preflight passes on three sibling roots' { $text.Contains('Preflight: ok') -and $text.Contains("Lease scope: $scope") }
    Check 'dry run: lists every process, scenario and the analysis' {
        $ids = @(Get-VcScenarios -Mode CP) + @(Get-VcScenarios -Mode MP -IncludeEndOfGame) | ForEach-Object Id
        @($ids | Where-Object { !$text.Contains("-- $_ (") }).Count -eq 0 -and
        ([regex]::Matches($text, '\[start\] server: ')).Count -eq 2 -and ([regex]::Matches($text, '\[start\] client [AB]: ')).Count -eq 4 -and
        $text.Contains('voicetest_mute {A}') -and $text.Contains('teams opposite') -and $text.Contains('analyze_voice.py')
    }
    Check 'dry run: client backups include the lab fixture files and both clients'' dcache' {
        $fixture = @('iw7-mod/paris-agent.session', 'iw7-mod/paris-agent.request', 'iw7-mod/paris-agent.response', 'iw7-mod/paris-agent.safety',
            'iw7-mod/paris-server-client.request', 'iw7-mod/paris-server-client.response', 'iw7-mod/paris-isolated-lab.marker', 'main/data0.dcache', 'main/toc1.dcache')
        $lines = @($output | Where-Object { $_ -match '^\[backup\] (A|B) root: ' })
        $lines.Count -eq 2 -and @($lines | Where-Object { $line = $_; @($fixture | Where-Object { !$line.Contains($_) }).Count }).Count -eq 0
    }
    Check 'dry run: no marker is written at run time' { !$text.Contains('write iw7-mod\paris-isolated-lab.marker') -and !($text -match '\[stage\][^\n]*marker') }
    Check 'dry run: shareable reservation on the lease scope, retried while busy' {
        $text.Contains("Enter-IW7ResourceLease -Scope $scope -Kind Runtime -Shareable, 11 GB physical, 24 GB commit") -and $text.Contains('for up to 3600 s') -and !$text.Contains('BaseClientImage')
    }
    Check 'dry run: privacy flags, root io, lab port and redaction' {
        $text.Contains('-dedicated -allow_root_io -noupdate') -and $text.Contains('+set sv_lanOnly 1 +set net_ip 127.0.0.1 +set net_port 27416') -and
        $text.Contains('set g_password "<redacted>"') -and $text.Contains('+set password "<redacted>"') -and
        ([regex]::Matches($text, '\+set paris_lab_server_port 27416')).Count -eq 4 -and !$text.Contains('27016') -and !$text.Contains('connect 127.0.0.1:27416   ')
    }
    Check 'dry run: CP joins through the request file, MP through the console, with the stall budget' {
        $cpJoins = @($output | Where-Object { $_ -match '^\[join [AB]\] write .*paris-server-client\.request' })
        $mpJoins = @($output | Where-Object { $_ -match '^\[join [AB]\] \[command\] connect 127\.0\.0\.1:27416' })
        $stalls = @($output | Where-Object { $_ -match '^\[join [AB]\] not in game 120 s after the launch: stop it .* at most 2 time' })
        $cpJoins.Count -eq 2 -and $mpJoins.Count -eq 2 -and $stalls.Count -eq 4 -and $text.Contains("$clientA\iw7-mod\paris-server-client.request") -and
        @($output | Where-Object { $_ -match '^\[command [AB]\] connect' }).Count -eq 0
    }
    Check 'dry run: logs collected before the restore; -Diagnostics adds the console dvars' {
        $diagText = $diagOutput -join "`n"
        $text.Contains('[collect] from each root, before the restore: iw7-mod/logs/*.log') -and $text.Contains('[diagnostics] off') -and
        !$text.Contains('+set developer 1') -and $diagText.Contains('[diagnostics] on') -and
        @($diagOutput | Where-Object { $_ -match '^\[start\] ' -and $_.Contains('+set developer 1 +set logfile 1 +set g_consoleLog iw7-mod/logs/console.log') }).Count -eq 3 -and
        @($diagOutput | Where-Object { $_ -match '^\[start\] client' -and $_.Contains('+set cl_noprint 0 +set cl_lessprint 0') }).Count -eq 2
    }
    Check 'dry run: the join proof and the early stall are stated' {
        $text.Contains("server's last 'Setting client N XUID to X' equals the client's own session XUID") -and
        ([regex]::Matches($text, "no 'Ready loopback join' line in the client's console 40 s later")).Count -eq 2
    }
    Check 'dry run: without a bench core the updater data is backed up' { !$text.Contains('disposable bench copy') -and $text.Contains('[bench check] none') }
    Check 'dry run with a bench core: manifests and bench checks pass, cdata left out' {
        $benchText.Contains('Preflight: ok') -and ([regex]::Matches($benchText, '\[bench check\] (Server|A|B): ok')).Count -eq 3 -and
        ([regex]::Matches($benchText, 'not \[iw7-mod/lab-appdata/cdata\] \(disposable bench copy\)')).Count -eq 3 -and
        $benchText.Contains('iw7-mod/lab-appdata/cdata/custom_scripts]') -and $benchText.Contains('the read-only bench check again')
    }
    Check 'dry runs: nothing written, no process started, no runtime loaded' {
        $after = Get-TreeState
        $childrenAfter = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$PID" | ForEach-Object ProcessId)
        if (Test-Path $out) { throw 'evidence directory was created' }
        if (Compare-Object $before $after) { throw ('files changed: ' + ((Compare-Object $before $after | ForEach-Object InputObject) -join ', ')) }
        if (Compare-Object $childrenBefore $childrenAfter) { throw 'child process set changed' }
        if ('IW7LabProcess' -as [type]) { throw 'process launcher type was loaded' }
        if (Get-Command Enter-IW7ResourceLease -ErrorAction SilentlyContinue) { throw 'resource scheduler was loaded' }
        $true
    }
    Check 'the harness never carries the whole isolated-lab flag in its source' {
        # the scheduler counts a process whose command line carries the flag as a laboratory
        (Get-Content -LiteralPath "$harness\Invoke-VoiceCertify.ps1" -Raw) -notmatch '(?:^|[\s''"])-paris-isolated-lab(?:[\s''"]|$)'
    }

    Check 'every command the harness calls exists (static: the run path cannot be run offline)' {
        $sources = @("$harness\Invoke-VoiceCertify.ps1", "$harness\VoiceCertify.Core.ps1", "$repo\ops\Base-Client.Core.ps1",
            "$repo\ops\Resource-Scheduler.Core.ps1", "$repo\ops\Lab-Lifecycle.ps1")
        $defined = @{}
        foreach ($file in $sources) {
            $ast = [Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$null)
            foreach ($f in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) { $defined[$f.Name] = $true }
        }
        $ast = [Management.Automation.Language.Parser]::ParseFile("$harness\Invoke-VoiceCertify.ps1", [ref]$null, [ref]$null)
        $missing = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } |
            Where-Object { $_ -and $_ -notmatch '[\\/]' -and !$defined[$_] -and $_ -notin 'python', 'git', 'Test-IW7BenchRoot' -and !(Get-Command $_ -ErrorAction SilentlyContinue) } | Select-Object -Unique)
        if ($missing.Count) { throw ('unknown: ' + ($missing -join ', ')) }
        $true
    }

    # ---- refusals (each dry run reports what a real run would refuse)

    function Get-DryText([hashtable]$Change) {
        $arguments = $common.Clone(); foreach ($key in $Change.Keys) { $arguments[$key] = $Change[$key] }
        (& "$harness\Invoke-VoiceCertify.ps1" @arguments) -join "`n"
    }
    Check 'refused: missing roots' {
        $t = Get-DryText @{ ServerRoot = (Join-Path $scope 'nowhere') }
        $t.Contains('Server root has no game files') -and $t.Contains('Server root is not a marked isolated lab root')
    }
    Check 'refused: a root inside another root' {
        $nested = Join-Path $server 'peer'
        $t = Get-DryText @{ ClientBRoot = $nested }
        $t2 = Get-DryText @{ ClientBRoot = $nested; LeaseScope = $scope }
        $t.Contains('The Server and B roots must be separate folders') -and $t.Contains('The three roots must be siblings') -and
            $t2.Contains('The B root must be a direct child of the lease scope')
    }
    Check 'refused: roots that are not siblings' {
        $t = Get-DryText @{ ClientARoot = (Join-Path $tmp 'elsewhere\a') }
        $t.Contains('The three roots must be siblings in one folder (or pass -LeaseScope)')
    }
    Check 'refused: missing marker on client A' {
        $markerA = Join-Path $clientA 'iw7-mod\paris-isolated-lab.marker'
        Move-Item -LiteralPath $markerA -Destination "$markerA.off"
        try { $t = Get-DryText @{} } finally { Move-Item -LiteralPath "$markerA.off" -Destination $markerA }
        $t.Contains('A root is not a marked isolated lab root.') -and !$t.Contains('Preflight: ok')
    }
    Check 'refused: bench port differs from the harness port' {
        $t = Get-DryText @{ BenchCore = $stubCore; ClientBPort = 27419 }
        $t.Contains('B bench port is 27418, the harness uses 27419 for it.') -and !$t.Contains('Preflight: ok')
    }
    Check 'refused: bench check problem and a missing bench manifest' {
        $manifestA = Join-Path $clientA 'paris-bench-root.json'
        $saved = [IO.File]::ReadAllText($manifestA)
        $m = $saved | ConvertFrom-Json; $m.identity.name = 'broken'; $m | ConvertTo-Json -Depth 4 | Set-Content $manifestA
        try { $t1 = Get-DryText @{ BenchCore = $stubCore } } finally { [IO.File]::WriteAllText($manifestA, $saved) }
        $manifestB = Join-Path $clientB 'paris-bench-root.json'
        Move-Item -LiteralPath $manifestB -Destination "$manifestB.off"
        try { $t2 = Get-DryText @{ BenchCore = $stubCore } } finally { Move-Item -LiteralPath "$manifestB.off" -Destination $manifestB }
        $t1.Contains('A bench: SHARED DATA WAS WRITTEN') -and $t2.Contains('B root is not a bench root (no paris-bench-root.json).')
    }
    Check 'refused: a file the run would write has several names' {
        $shared = Join-Path $tmp 'shared-profile.bin'; [IO.File]::WriteAllText($shared, 'shared')
        $players = Join-Path $clientA 'iw7-mod\players2'; [IO.Directory]::CreateDirectory($players) | Out-Null
        $linked = Join-Path $players 'shared.bin'; New-Item -ItemType HardLink -Path $linked -Target $shared | Out-Null
        $stagedTarget = Join-Path $clientB 'iw7-voicecert.exe'; New-Item -ItemType HardLink -Path $stagedTarget -Target $shared | Out-Null
        try { $t = Get-DryText @{} } finally { Remove-Item -LiteralPath $linked, $stagedTarget, $shared; Remove-Item -LiteralPath $players }
        $t.Contains("iw7-mod/players2/shared.bin in $clientA has 3 names") -and $t.Contains("iw7-voicecert.exe in $clientB has 3 names") -and !$t.Contains('Preflight: ok')
    }
    Check 'Main port 27016 is refused at binding' {
        try { & "$harness\Invoke-VoiceCertify.ps1" @common -ServerPort 27016 | Out-Null; $false }
        catch { $_.Exception.Message -match '27016|range' }
    }
} finally { Remove-Item -LiteralPath $tmp -Recurse -Force }

"$passed passed, $failures failed"
if ($failures) { throw "$failures check(s) failed" }
'all checks passed'
