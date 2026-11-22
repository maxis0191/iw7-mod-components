# Free ports of the private lab range for a runner that was not given its ports (Invoke-NetLab, Invoke-GameLabHeadless,
# Invoke-Soak). A runner takes a fixed default port, and a busy machine (other sessions' labs and servers) then fails it
# for a reason that is not the code. A port is taken here only when (1) no process holds it (Get-NetUDPEndpoint, one call),
# (2) a real UDP bind succeeds, and (3) this process holds the reservation file of that port, which another runner picking at the
# same moment cannot get (a file opened with no sharing; the OS releases it when the runner ends, crashed or not).
# The ports a caller names itself stay strictly checked by the runner: only a port left at 0 is chosen here.
$script:IW7LabPortLocks = @()
function Get-IW7FreeLabPort {
    param([int[]]$Exclude = @())
    # The ports bench roots refuse: the product's ops/bench/reserved-ports.json next to this file in a workspace, else this copy
    # (22 Nov 2026: the five-port list let a NetLab run pick 27957, a retained private test server's, and its bench refused it).
    $reserved = 27016, 27116, 27117, 27216, 27217, 27956, 27957, 27958, 27959, 27963
    $list = Join-Path $PSScriptRoot '../bench/reserved-ports.json'
    if (Test-Path -LiteralPath $list) { try { $reserved = @((Get-Content -LiteralPath $list -Raw | ConvertFrom-Json).ports | ForEach-Object { [int]$_ }) } catch { } }
    $base = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { [IO.Path]::GetTempPath() }
    $dir = Join-Path $base 'IW7\lab-port-locks'
    [IO.Directory]::CreateDirectory($dir) | Out-Null
    $bound = [Collections.Generic.HashSet[int]]::new()
    foreach ($e in @(Get-NetUDPEndpoint -ErrorAction SilentlyContinue)) { [void]$bound.Add([int]$e.LocalPort) }
    foreach ($port in (27100..27999 | Get-Random -Count 900)) {
        if ($port -in $reserved -or $port -in $Exclude -or $bound.Contains($port)) { continue }
        $lock = $null
        try { $lock = [IO.File]::Open((Join-Path $dir "$port.lock"), 'OpenOrCreate', 'ReadWrite', 'None') } catch { continue }
        try { $probe = [Net.Sockets.UdpClient]::new($port); $probe.Close() } catch { $lock.Dispose(); continue }
        $script:IW7LabPortLocks += $lock
        return $port
    }
    throw 'No free port left in the lab range 27100 to 27999.'
}
