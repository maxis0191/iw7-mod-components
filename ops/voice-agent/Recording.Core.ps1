function Assert-IW7ReceiverWAV {
    param([Parameter(Mandatory)][string]$Path,[ValidateRange(1,60)][int]$Seconds)
    $file=[IO.File]::Open($Path,'Open','Read','Read')
    try {
        if ($file.Length -lt 48 -or $file.Length -gt 44+$Seconds*192000) { throw 'Receiver WAV length exceeds PCM capture bounds or is empty.' }
        $header=[byte[]]::new(44);$file.ReadExactly($header)
        $ascii=[Text.Encoding]::ASCII
        $pcmBytes=[BitConverter]::ToUInt32($header,40)
        if ($ascii.GetString($header,0,4) -cne 'RIFF' -or $ascii.GetString($header,8,8) -cne 'WAVEfmt ' -or
            $ascii.GetString($header,36,4) -cne 'data' -or [BitConverter]::ToUInt32($header,4) -ne $file.Length-8 -or
            [BitConverter]::ToUInt32($header,16) -ne 16 -or [BitConverter]::ToUInt16($header,20) -ne 1 -or
            [BitConverter]::ToUInt16($header,22) -ne 2 -or [BitConverter]::ToUInt32($header,24) -ne 48000 -or
            [BitConverter]::ToUInt32($header,28) -ne 192000 -or [BitConverter]::ToUInt16($header,32) -ne 4 -or
            [BitConverter]::ToUInt16($header,34) -ne 16 -or !$pcmBytes -or $pcmBytes%4 -or $pcmBytes -ne $file.Length-44) {
            throw 'Receiver WAV is incomplete, malformed or not the bounded PCM16 stereo 48000Hz format.'
        }
        [pscustomobject]@{Bytes=$file.Length;PCMBytes=$pcmBytes;Frames=$pcmBytes/4;AudioSeconds=$pcmBytes/192000.0;Format='PCM16 stereo 48000Hz'}
    } finally { $file.Dispose() }
}
