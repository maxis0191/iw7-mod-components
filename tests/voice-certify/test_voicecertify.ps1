# Offline tests of the voice certification orchestrator: the pure helpers, and a
# dry run against throw-away fake roots that must start no process and write nothing.
# Run: pwsh -NoProfile -File tests/voice-certify/test_voicecertify.ps1
$ErrorActionPreference = 'Stop'
$harness = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'ops\voice-certify'
. "$harness\VoiceCertify.Core.ps1"
$failures = 0
function Check([string]$Name, [scriptblock]$Test) {
    try { if (!(& $Test)) { throw 'returned false' }; "ok   $Name" }
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

    # ---- dry run against fake roots

    $server = Join-Path $tmp 'server'; $peer = Join-Path $server 'agent-peer'; $clientA = Join-Path $tmp 'base'; $out = Join-Path $tmp 'evidence'
    foreach ($root in @($server, $peer, $clientA)) { [IO.Directory]::CreateDirectory((Join-Path $root 'iw7-mod')) | Out-Null; [IO.File]::WriteAllText((Join-Path $root 'iw7_ship.exe'), 'x') }
    foreach ($root in @($server, $peer)) { [IO.File]::WriteAllText((Join-Path $root 'iw7-mod\paris-isolated-lab.marker'), 'iw7-paris-isolated-lab-v1') }
    foreach ($map in @('cp_zmb', 'cp_rave', 'mp_frontier')) { [IO.File]::WriteAllText((Join-Path $server "$map.ff"), 'x') }
    $build = Join-Path $tmp 'build'; [IO.Directory]::CreateDirectory($build) | Out-Null
    $image = Join-Path $build 'iw7-mod.exe'; [IO.File]::WriteAllText($image, 'lab image')
    [pscustomobject]@{ schema = 'iw7.voice-certify-build/1'; sha256 = (Get-FileHash $image).Hash
        overlays = [pscustomobject]@{ voiceTest = $true; voiceRelay = $true; isolatedAppData = $true; testPrivacy = $true } } | ConvertTo-Json | Set-Content (Join-Path $build 'voice-certify-build.json')
    $before = @(Get-ChildItem $tmp -Recurse -Force | ForEach-Object { if ($_.PSIsContainer) { $_.FullName } else { $_.FullName + '|' + $_.Length + '|' + $_.LastWriteTimeUtc.Ticks } })
    $childrenBefore = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$PID" | ForEach-Object ProcessId)

    # Directory times are compared by presence only: NTFS updates them lazily.
    # Any attempt to start a process from the dry run path throws.
    foreach ($name in @('python', 'py', 'git', 'pwsh', 'powershell', 'cmd', 'Start-Process', 'Start-Job')) {
        Set-Item "Function:global:$name" -Value ([scriptblock]::Create("throw 'dry run attempted to start: $name'"))
    }
    try {
        $output = & "$harness\Invoke-VoiceCertify.ps1" -ServerRoot $server -ClientARoot $clientA -LabImage $image -OutputRoot $out -IncludeEndOfGame -DryRun
    } finally {
        foreach ($name in @('python', 'py', 'git', 'pwsh', 'powershell', 'cmd', 'Start-Process', 'Start-Job')) { Remove-Item "Function:global:$name" }
    }
    $text = $output -join "`n"
    Check 'dry run: preflight passes on complete fake roots' { $text.Contains('Preflight: ok') }
    Check 'dry run: lists every process, scenario and the analysis' {
        $ids = @(Get-VcScenarios -Mode CP) + @(Get-VcScenarios -Mode MP -IncludeEndOfGame) | ForEach-Object Id
        @($ids | Where-Object { !$text.Contains("-- $_ (") }).Count -eq 0 -and
        ([regex]::Matches($text, '\[start\] server: ')).Count -eq 2 -and ([regex]::Matches($text, '\[start\] client [AB]: ')).Count -eq 4 -and
        $text.Contains('voicetest_mute {A}') -and $text.Contains('teams opposite') -and $text.Contains('analyze_voice.py')
    }
    Check 'dry run: client backups include the lab fixture files' {
        $fixture = @('iw7-mod/paris-agent.session', 'iw7-mod/paris-agent.request', 'iw7-mod/paris-agent.response', 'iw7-mod/paris-agent.safety',
            'iw7-mod/paris-server-client.request', 'iw7-mod/paris-server-client.response')
        $lines = @($output | Where-Object { $_ -match '^\[backup\] (A|B) root: ' })
        $lines.Count -eq 2 -and @($lines | Where-Object { $line = $_; @($fixture | Where-Object { !$line.Contains($_) }).Count }).Count -eq 0
    }
    Check 'dry run: privacy flags and redaction' {
        $text.Contains('+set sv_lanOnly 1 +set net_ip 127.0.0.1 +set net_port 27416') -and $text.Contains('set g_password "<redacted>"') -and
        $text.Contains('+set password "<redacted>"') -and !$text.Contains('27016')
    }
    Check 'dry run: nothing written, no process started, no runtime loaded' {
        $after = @(Get-ChildItem $tmp -Recurse -Force | ForEach-Object { if ($_.PSIsContainer) { $_.FullName } else { $_.FullName + '|' + $_.Length + '|' + $_.LastWriteTimeUtc.Ticks } })
        $childrenAfter = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$PID" | ForEach-Object ProcessId)
        if (Test-Path $out) { throw 'evidence directory was created' }
        if (Compare-Object $before $after) { throw ('files changed: ' + ((Compare-Object $before $after | ForEach-Object InputObject) -join ', ')) }
        if (Compare-Object $childrenBefore $childrenAfter) { throw 'child process set changed' }
        if ('IW7LabProcess' -as [type]) { throw 'process launcher type was loaded' }
        if (Get-Command Enter-IW7ResourceLease -ErrorAction SilentlyContinue) { throw 'resource scheduler was loaded' }
        $true
    }
    Check 'dry run: reports missing roots' {
        $bad = & "$harness\Invoke-VoiceCertify.ps1" -ServerRoot (Join-Path $tmp 'nowhere') -ClientARoot $clientA -LabImage $image -OutputRoot $out -DryRun
        $badText = $bad -join "`n"
        $badText.Contains('Server root has no game files') -and $badText.Contains('B root is not a marked isolated lab root')
    }
    Check 'Main port 27016 is refused at binding' {
        try { & "$harness\Invoke-VoiceCertify.ps1" -ServerRoot $server -ClientARoot $clientA -LabImage $image -OutputRoot $out -ServerPort 27016 -DryRun | Out-Null; $false }
        catch { $_.Exception.Message -match '27016|range' }
    }
} finally { Remove-Item -LiteralPath $tmp -Recurse -Force }

if ($failures) { throw "$failures check(s) failed" }
'all checks passed'
