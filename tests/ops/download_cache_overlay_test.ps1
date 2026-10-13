param([string]$NativeRoot)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../../ops/Download-CacheOverlay.Core.ps1"
function Assert([bool]$Condition, [string]$Message) { if (!$Condition) { throw $Message } }
function Refuses([scriptblock]$Action) {
    $rejected = $false
    try { & $Action } catch { $rejected = $true }
    Assert $rejected 'Expected refusal.'
}
# Distinct server and client uses make accidental global cache removal observable.
$source = @'
std::string get_file_hash(const std::string& file) { return hash_cache.at(file); }
bool check_download_mod() {
    const auto hash = get_file_hash(file_path);
}
void server_info() { const auto hash = get_file_hash(server_path); }
'@ + "`n"
$expected = $source.Replace('const auto hash = get_file_hash(file_path);', 'const auto hash = utils::hash::get_file_hash(file_path);')
$actual = Convert-IW7DownloadCacheSource $source
Assert ($actual -ceq $expected) 'Transformation touched content outside the client hash call.'
Assert ($actual.Contains('get_file_hash(server_path)')) 'Server cache changed.'
Refuses { Convert-IW7DownloadCacheSource $actual }
Refuses { Convert-IW7DownloadCacheSource ($source + 'const auto hash = get_file_hash(file_path);') }
Refuses { Convert-IW7DownloadCacheSource ($source.Replace('file_path', 'other_path')) }
Assert-IW7DownloadCacheOwned $source $source $actual
Assert-IW7DownloadCacheOwned $actual $source $actual
Refuses { Assert-IW7DownloadCacheOwned ($actual + '// foreign edit') $source $actual }
Refuses { Assert-IW7DownloadCachePin $source $IW7DownloadCacheCommit }
Refuses { Assert-IW7DownloadCachePin $source '36f7afedb9e4c8c665b6e29227e3f5c660ed63d6' }
if ($NativeRoot) {
    $lines = @(git -C $NativeRoot show ($IW7DownloadCacheCommit + ':src/client/component/party.cpp'))
    if ($LASTEXITCODE) { throw 'Real pinned source unavailable.' }
    $base = ($lines -join "`n") + "`n"
    Assert-IW7DownloadCachePin $base $IW7DownloadCacheCommit
    $transformed = Convert-IW7DownloadCacheSource $base
    Assert ((Get-IW7DownloadSourceHash $transformed) -ne $IW7DownloadCacheBaseSHA256) 'Real source was unchanged.'
    Refuses { Assert-IW7DownloadCachePin ($base + '// modified') $IW7DownloadCacheCommit }
    Assert-IW7DownloadCacheOwned $transformed $base $transformed
    # Execute the actual file writer in a disposable root, supplying immutable git
    # source through a mock. Never edit the retained native build checkout.
    $testRoot = Join-Path ([IO.Path]::GetTempPath()) ('iw7-download-overlay-' + [guid]::NewGuid().ToString('N'))
    $targetDirectory = Join-Path $testRoot 'src/client/component'
    New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
    $target = Join-Path $targetDirectory 'party.cpp'
    $mockGitLines = $lines
    Set-Item Function:git -Value { $global:LASTEXITCODE = 0; $mockGitLines }.GetNewClosure()
    try {
        [IO.File]::WriteAllText($target, $base.Replace("`n", "`r`n"), [Text.UTF8Encoding]::new($false))
        $record = & "$PSScriptRoot/../../ops/Apply-DownloadCacheOverlay.ps1" -NativeRoot $testRoot -Commit $IW7DownloadCacheCommit
        Assert ([IO.File]::ReadAllText($target) -ceq $transformed) 'Actual writer failed to apply exact overlay.'
        Assert ($record.AppliedFileSHA256 -eq (Get-FileHash -LiteralPath $target).Hash) 'Manifest differs from actual written bytes.'
        $second = & "$PSScriptRoot/../../ops/Apply-DownloadCacheOverlay.ps1" -NativeRoot $testRoot -Commit $IW7DownloadCacheCommit
        Assert ($second.AppliedFileSHA256 -eq $record.AppliedFileSHA256) 'Repeat application changed overlay.'
        [IO.File]::AppendAllText($target, '// owned by another task')
        $foreignHash = (Get-FileHash -LiteralPath $target).Hash
        Refuses { & "$PSScriptRoot/../../ops/Apply-DownloadCacheOverlay.ps1" -NativeRoot $testRoot -Commit $IW7DownloadCacheCommit }
        Assert ((Get-FileHash -LiteralPath $target).Hash -eq $foreignHash) 'Refusal overwrote foreign edits.'
    } finally {
        Remove-Item Function:git
        # This exact GUID directory was created above; no shared/runtime root is touched.
        $absolute = [IO.Path]::GetFullPath($testRoot)
        $temporary = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
        if (!$absolute.StartsWith($temporary+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or
            (Split-Path $absolute -Leaf) -notmatch '^iw7-download-overlay-[a-f0-9]{32}$') { throw 'Test cleanup containment refused.' }
        Remove-Item -LiteralPath $absolute -Recurse -Force
    }
}
Write-Output 'PASS download-cache overlay ownership, markers, server preservation and pins.'
