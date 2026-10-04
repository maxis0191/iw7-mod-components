$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. "$repo/ops/Lab-State.ps1"
$root = Join-Path $repo ('runtime/lab-state-test-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root
foreach ($name in @('lab.json','budget-monitor.json')) {
    $path = Join-Path $root $name
    for ($version = 1; $version -le 3; $version++) {
        Write-IW7LabJson $path ([ordered]@{Token='this-run';TickMs=$version;Nested=@{Value='évidence'}}) $root
        $actual = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if ($actual.Token -ne 'this-run' -or $actual.TickMs -ne $version -or $actual.Nested.Value -ne 'évidence') {
            throw 'Repeated atomic state/heartbeat write did not persist the current value.'
        }
    }
    if (@(Get-ChildItem -LiteralPath $root -Filter '*.previous').Count) { throw 'Successful replacement left a backup behind.' }
    $before = [IO.File]::ReadAllText($path)
    $held = [IO.File]::Open($path, 'Open', 'Read', 'None')
    $refused = $false
    try { Write-IW7LabJson $path @{TickMs=99} $root } catch { $refused = $true } finally { $held.Dispose() }
    if (!$refused -or [IO.File]::ReadAllText($path) -ne $before) { throw 'Blocked replacement corrupted previous state.' }
}
Write-Output 'PASS: repeated state/heartbeat replacement, UTF-8 content and locked-target preservation.'
