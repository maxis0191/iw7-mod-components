$IW7DownloadCacheCommit = '77e6d4d24e918ee363b3feee3735c3b889dff7d7'
$IW7DownloadCacheBaseSHA256 = '62599BFC6F3C10AB1DC68C432AD4F60CC70ED76D6270B73A465C9D8CB1819360'

function Get-IW7DownloadSourceHash([string]$Source) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($Source)))).Replace('-', '') }
    finally { $algorithm.Dispose() }
}

function Assert-IW7DownloadCachePin([string]$Source, [string]$Commit) {
    if ($Commit -cnotin @($IW7DownloadCacheCommit, '993737428781c4357fe21ecd375300e39a29a654', 'cfca45b11ee14641945b9a264a95638387f48a4a', '81e32f7a15139d7b92fdad2e5dbb5989149259cb')) { throw 'Unsupported download-cache upstream revision.' }
    $expectedHash = if ($Commit -ceq $IW7DownloadCacheCommit) { $IW7DownloadCacheBaseSHA256 }
        elseif ($Commit -ceq '993737428781c4357fe21ecd375300e39a29a654') { 'C5D3E6353D87FDB023F3AA41EE662AD4DB1DD0A3BBC8C3209B3CC66594811C55' }
        else { '31FB5DCB2D407B51673DEDF0E2C5054D2A0EDC1BB95D25952517D7B69ACF635E' }
    if ((Get-IW7DownloadSourceHash $Source) -cne $expectedHash) {
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
