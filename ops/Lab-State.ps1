# Shared by the lab state and its supervisor heartbeat. Caller serializes writers.
. "$PSScriptRoot/Lab-Paths.ps1"
function Write-IW7LabJson([string]$Path, $Value, [string]$Container) {
    $null = Assert-IW7LabPath $Path $Container
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    $backup = $temporary + '.previous'
    [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    # PowerShell binds a null String argument as an empty path here. Supply an
    # actual, unique same-directory backup so repeated writes work on Windows.
    # If replacement fails, retain old destination and recovery files.
    if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary, $Path, $backup) }
    else { [IO.File]::Move($temporary, $Path) }
    if ([IO.File]::Exists($backup)) { [IO.File]::Delete($backup) }
}
