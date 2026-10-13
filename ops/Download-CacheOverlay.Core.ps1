$IW7DownloadCacheCommit = '77e6d4d24e918ee363b3feee3735c3b889dff7d7'
$IW7DownloadCacheBaseSHA256 = '62599BFC6F3C10AB1DC68C432AD4F60CC70ED76D6270B73A465C9D8CB1819360'

function Get-IW7DownloadSourceHash([string]$Source) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($Source)))).Replace('-', '') }
    finally { $algorithm.Dispose() }
}

function Assert-IW7DownloadCachePin([string]$Source, [string]$Commit) {
    if ($Commit -cne $IW7DownloadCacheCommit) { throw 'Unsupported download-cache upstream revision.' }
    if ((Get-IW7DownloadSourceHash $Source) -cne $IW7DownloadCacheBaseSHA256) {
        throw 'Pinned download-cache source hash changed.'
    }
}

function Convert-IW7DownloadCacheSource([string]$Source) {
    $marker = 'const auto hash = get_file_hash(file_path);'
    if (($Source.Split([string[]]@($marker), [StringSplitOptions]::None)).Count -ne 2) {
        throw 'Client download-cache marker missing or ambiguous.'
    }
    $Source.Replace($marker, 'const auto hash = utils::hash::get_file_hash(file_path);')
}

function Assert-IW7DownloadCacheOwned([string]$Current, [string]$Base, [string]$Overlay) {
    if ($Current -cne $Base -and $Current -cne $Overlay) {
        throw 'Unowned party.cpp edits; preserve them and use an isolated native checkout.'
    }
}
