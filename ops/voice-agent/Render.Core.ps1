function Resolve-IW7VoiceRenderRoute {
    param([Parameter(Mandatory)]$Inventory,[Parameter(Mandatory)][string]$EndpointId)
    $items=@($Inventory.Endpoints | Where-Object Id -CEQ $EndpointId)
    if ($items.Count -ne 1) { throw 'Explicit render endpoint missing or ambiguous.' }
    $endpoint=$items[0]
    if ($endpoint.Flow -cne 'render' -or $endpoint.State -ne 1 -or $endpoint.Name -cne 'CABLE Input (VB-Audio Virtual Cable)') { throw 'Only active exact CABLE Input allowed.' }
    $guid=[guid]::Parse($endpoint.EndpointGuid)
    if ($guid -eq [guid]::Empty -or @($Inventory.Endpoints | Where-Object { $_.EndpointGuid -and [guid]::Parse($_.EndpointGuid) -eq $guid }).Count -ne 1) { throw 'Render GUID is default/ambiguous.' }
    [pscustomobject]@{EndpointId=$endpoint.Id;EndpointGuid=$guid.ToString('B');Name=$endpoint.Name;DefaultFallback=$false}
}
function Assert-IW7SpeechWAV {
    param([Parameter(Mandatory)][string]$Path)
    $size=(Get-Item -LiteralPath $Path -Force).Length
    if ($size -lt 44 -or $size -gt 480102) { throw 'Speech WAV file bound exceeded.' }
    $bytes=[IO.File]::ReadAllBytes($Path);$text=[Text.Encoding]::ASCII
    if ($text.GetString($bytes,0,4) -cne 'RIFF' -or $text.GetString($bytes,8,4) -cne 'WAVE' -or [BitConverter]::ToUInt32($bytes,4) -ne $bytes.Length-8) { throw 'Invalid exact RIFF/WAVE.' }
    $fmt=$false;$data=$false;$frames=0
    for ($i=12;$i -lt $bytes.Length;) {
        if ($bytes.Length-$i -lt 8) { throw 'Truncated WAV chunk.' }
        $length=[BitConverter]::ToUInt32($bytes,$i+4);$start=$i+8;$tag=$text.GetString($bytes,$i,4)
        if ($length -gt $bytes.Length-$start) { throw 'Chunk exceeds WAV.' }
        if ($tag -ceq 'fmt ') {
            if ($fmt -or $length -notin @(16,18) -or [BitConverter]::ToUInt16($bytes,$start) -ne 1 -or [BitConverter]::ToUInt16($bytes,$start+2) -ne 1 -or [BitConverter]::ToUInt32($bytes,$start+4) -ne 16000 -or [BitConverter]::ToUInt32($bytes,$start+8) -ne 32000 -or [BitConverter]::ToUInt16($bytes,$start+12) -ne 2 -or [BitConverter]::ToUInt16($bytes,$start+14) -ne 16 -or ($length -eq 18 -and [BitConverter]::ToUInt16($bytes,$start+16))) { throw 'Original mono PCM16/16000Hz required.' }
            $fmt=$true
        } elseif ($tag -ceq 'data') {
            if (!$fmt -or $data -or !$length -or $length%2 -or $length -gt 480000) { throw 'Invalid speech frame bound.' }
            $data=$true;$frames=$length/2
        }
        $i=$start+$length+($length%2)
        if ($i -gt $bytes.Length) { throw 'Missing chunk pad.' }
    }
    if (!$fmt -or !$data) { throw 'WAV format/data absent.' }
    [pscustomobject]@{SourceFrames=$frames;SourceRate=16000;Channels=1;Bits=16;Seconds=$frames/16000;MaximumSeconds=15}
}
function Assert-IW7RenderCompletion {
    param([Parameter(Mandatory)][string]$Log,[Parameter(Mandatory)][long]$SourceFrames)
    $match=[regex]::Match($Log,'\ARENDER_COMPLETE source_frames=(\d+) submitted_frames=(\d+) mix_rate=(\d+) channels=([12]) bits=(16|32) floating=([01]) default_fallback=0\r?\n\z')
    if (!$match.Success -or $SourceFrames -le 0 -or $SourceFrames -gt 240000 -or [long]$match.Groups[1].Value -ne $SourceFrames) { throw 'Missing/malformed negotiated render completion evidence.' }
    $rate=[long]$match.Groups[3].Value
    if ($rate -lt 8000 -or $rate -gt 192000 -or [long]$match.Groups[2].Value -ne [math]::Ceiling($SourceFrames*$rate/16000) -or ($match.Groups[6].Value -eq '1' -and $match.Groups[5].Value -ne '32') -or ($match.Groups[6].Value -eq '0' -and $match.Groups[5].Value -ne '16')) { throw 'Render frames/encoding inconsistent with source.' }
    $match.Value.Trim()
}
