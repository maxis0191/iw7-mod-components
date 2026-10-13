# Pure evidence checks, shared by one-shot verification and the lab supervisor.
function Assert-IW7LabGraphics([string]$Log, [int]$Picmip, [long]$SinceTickMs, [long]$NowTicks = [Environment]::TickCount64) {
    $samples = [regex]::Matches($Log, '\[Paris lab graphics\] picmip=(-?\d+); bump=(-?\d+); spec=(-?\d+); tick_ms=(\d+)')
    if (!$samples.Count) { throw 'Actual client graphics evidence is missing.' }
    $last = $samples[$samples.Count - 1]
    $tick = [long]$last.Groups[4].Value
    if ($tick -lt $SinceTickMs -or $tick -gt $NowTicks -or $NowTicks - $tick -gt 15000 -or
        [int]$last.Groups[1].Value -ne $Picmip -or [int]$last.Groups[2].Value -ne $Picmip -or [int]$last.Groups[3].Value -ne $Picmip) {
        throw 'Capture graphics differ from the reserved profile or evidence is stale.'
    }
}
function Assert-IW7LabSupervisor($Snapshot, $Record, [long]$NowTicks = [Environment]::TickCount64) {
    if (!$Snapshot -or !$Record -or !$Record.Token -or !$Record.PID -or $null -eq $Snapshot.TickMs) { throw 'Lab supervisor evidence is missing.' }
    $age = $NowTicks - [long]$Snapshot.TickMs
    if ($Snapshot.Token -ne $Record.Token -or $Snapshot.PID -ne $Record.PID -or
        $Snapshot.Failure -or $age -lt 0 -or $age -gt 10000) { throw 'Lab supervisor heartbeat is stale or failed.' }
}
function Assert-IW7LabHeartbeat([string]$Log, [string]$Map, [int]$Port,
    [int]$ExpectedClients, [long]$NowTicks = [Environment]::TickCount64) {
    if ($ExpectedClients -lt 1 -or $ExpectedClients -gt 4 -or $NowTicks -lt 0) { throw 'Invalid heartbeat expectation.' }
    $loads = [regex]::Matches($Log, 'Starting map: ([a-z0-9_]+)')
    if ($loads.Count) {
        $lastLoad = $loads[$loads.Count - 1]
        if ($lastLoad.Groups[1].Value -ne $Map) { throw 'Heartbeat belongs to a different map load.' }
        $Log = $Log.Substring($lastLoad.Index)
    }
    if ($Log -match '\[Paris (?:lab|test) protection failure\]') { throw 'Native/fixture protection failed during this map run.' }
    $pattern = '\[Paris lab heartbeat\] game_time_ms=(\d+); map=([a-z0-9_]+); port=(\d+); slot=(\d+); tick_ms=(\d+); protected=(-?\d+); bound=(-?\d+); godmode=(-?\d+); inactivity=(-?\d+); cheats=(-?\d+); failed=(-?\d+)'
    $latest = @{}
    foreach ($sample in [regex]::Matches($Log, $pattern)) { $latest[$sample.Groups[4].Value] = $sample }
    if ($latest.Count -ne $ExpectedClients) { throw 'Fresh native protection for every expected client is required.' }
    foreach ($sample in $latest.Values) {
        $age = $NowTicks - [long]$sample.Groups[5].Value
        if ($sample.Groups[2].Value -ne $Map -or [int]$sample.Groups[3].Value -ne $Port -or
            [int]$sample.Groups[4].Value -ge 4 -or $age -lt 0 -or $age -gt 5000 -or
            $sample.Groups[6].Value -ne '1' -or $sample.Groups[7].Value -ne '1' -or
            $sample.Groups[8].Value -ne '1' -or $sample.Groups[9].Value -ne '0' -or
            $sample.Groups[10].Value -ne '0' -or $sample.Groups[11].Value -ne '0') {
            throw 'Protection heartbeat is stale, mismatched or unsafe.'
        }
    }
    [pscustomobject]@{Map=$Map;Port=$Port;ProtectedClients=$latest.Count;CheckedTickMs=$NowTicks}
}
