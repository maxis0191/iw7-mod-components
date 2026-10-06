param([Parameter(Mandatory)][string]$NativeRoot, [Parameter(Mandatory)][string]$Commit)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/Download-CacheOverlay.Core.ps1"
$relative = 'src/client/component/party.cpp'
$path = Join-Path $NativeRoot $relative
$lines = @(git -C $NativeRoot show ($Commit + ':' + $relative))
if ($LASTEXITCODE) { throw 'Pinned download-cache source unavailable.' }
$base = ($lines -join "`n") + "`n"
Assert-IW7DownloadCachePin $base $Commit
$overlay = Convert-IW7DownloadCacheSource $base
if ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
    throw 'Refusing a redirected download-cache source.'
}
$before = (Get-FileHash -LiteralPath $path).Hash
$current = [IO.File]::ReadAllText($path).Replace("`r`n", "`n")
Assert-IW7DownloadCacheOwned $current $base $overlay
if ((Get-FileHash -LiteralPath $path).Hash -ne $before) { throw 'Download-cache source changed during inspection.' }
[IO.File]::WriteAllText($path, $overlay, [Text.UTF8Encoding]::new($false))
$after = (Get-FileHash -LiteralPath $path).Hash
if ($after -ne (Get-IW7DownloadSourceHash $overlay)) { throw 'Download-cache overlay write verification failed.' }
[pscustomobject]@{
    Upstream = $Commit
    File = $relative
    PinnedNormalizedSourceSHA256 = $IW7DownloadCacheBaseSHA256
    PreviousFileSHA256 = $before
    AppliedFileSHA256 = $after
    Transformation = 'client check_download_mod: bypass path hash cache; server cache unchanged'
    HelperSHA256 = (Get-FileHash -LiteralPath $PSCommandPath).Hash
    CoreSHA256 = (Get-FileHash -LiteralPath "$PSScriptRoot/Download-CacheOverlay.Core.ps1").Hash
}
