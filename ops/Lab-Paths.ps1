function Assert-IW7LabPath([string]$Path, [string]$Container) {
    $full = [IO.Path]::GetFullPath($Path)
    $boundary = [IO.Path]::GetFullPath($Container).TrimEnd('\','/')
    if ($full -ne $boundary -and !$full.StartsWith($boundary + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) {
        throw 'Laboratory path escapes its declared container.'
    }
    # Check existing ancestors as well as the final path; a nonexistent child
    # below a junction otherwise passes both prefix and existence checks.
    $cursor = $full
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Laboratory path traverses a reparse point: $cursor" }
        }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
    $full
}
