$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. "$repo/ops/Lab-Paths.ps1"
$root = Join-Path $repo ('runtime/lab-path-test-' + [guid]::NewGuid().ToString('N'))
$inside = Join-Path $root 'inside'
$outside = Join-Path $root 'outside'
$null = New-Item -ItemType Directory -Path $inside,$outside
$sentinel = Join-Path $outside 'sentinel.txt'
[IO.File]::WriteAllText($sentinel,'preserve')
$link = Join-Path $inside 'junction'
try {
    $null = Assert-IW7LabPath (Join-Path $inside 'ordinary/new') $inside
    $null = New-Item -ItemType Junction -Path $link -Target $outside
    foreach ($path in @((Join-Path $link 'new/file'),(Join-Path $outside 'new/file'))) {
        $refused = $false
        try { $null = Assert-IW7LabPath $path $inside } catch { $refused = $true }
        if (!$refused) { throw 'Boundary/junction escape accepted.' }
    }
    if ([IO.File]::ReadAllText($sentinel) -ne 'preserve') { throw 'Path validation altered external content.' }
} finally {
    # Only unlink the exact test junction; never recurse into its target.
    if (Test-Path -LiteralPath $link) { Remove-Item -LiteralPath $link -Force }
}
Write-Output 'PASS: missing child paths, container boundary and intermediate junction refusal.'
