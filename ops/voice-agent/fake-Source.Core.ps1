Set-StrictMode -Version Latest

function Open-IW7FakeCaptureSource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedSha256
    )
    # No capture activation. Keep this exact source handle alive until both COM
    # objects have been released; deny replacement and writes in that interval.
    $stream = $null
    try {
        $resolved = [IO.Path]::GetFullPath($Path)
        $stream = [IO.FileStream]::new($resolved, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        if ($stream.Length -lt 44 -or $stream.Length -gt 480102) { throw 'Fake capture source exceeds the bounded WAV size.' }
        $bytes = [byte[]]::new([int]$stream.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $count = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($count -le 0) { throw 'Fake capture source ended before its retained size.' }
            $offset += $count
        }
        if ($stream.ReadByte() -ne -1) { throw 'Fake capture source changed size.' }
        $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        if ($hash -cne $ExpectedSha256) { throw 'Fake capture source hash mismatch.' }
        # Native create() independently hashes and parses the same bytes. This
        # result is source identity evidence, never proof of audio transmission.
        return [pscustomobject]@{ Path = $resolved; Handle = $stream; Bytes = $bytes; Sha256 = $hash; Length = $bytes.Length }
    } catch {
        if ($null -ne $stream) { $stream.Dispose() }
        throw
    }
}
