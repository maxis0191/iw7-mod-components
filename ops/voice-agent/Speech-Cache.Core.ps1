# Freeze the first original synthesis for a descriptor. Reuse verified original
# bytes; do not assume that repeating a Windows speech-engine call is bit exact.
function Get-IW7FrozenSpeechFixture {
    param([Parameter(Mandatory)][string]$CacheParent,[Parameter(Mandatory)][string]$DescriptorHash,
        [Parameter(Mandatory)][string]$VoiceTokenId,[Parameter(Mandatory)][Collections.IDictionary]$Phrases,
        [Parameter(Mandatory)][scriptblock]$Synthesize)
    if($DescriptorHash -cnotmatch '^[A-F0-9]{64}$' -or $Phrases.Count -ne 2 -or
        @($Phrases.Keys|Where-Object {$_ -cnotin @('ptt','reconnect')}).Count){throw 'Exact speech descriptor and two fixed stimuli required.'}
    $parent=[IO.Path]::GetFullPath($CacheParent)
    [IO.Directory]::CreateDirectory($parent)|Out-Null
    if((Get-Item -LiteralPath $parent).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Redirected speech cache refused.'}
    $cache=Join-Path $parent $DescriptorHash
    $lock=[IO.FileStream]::new((Join-Path $parent ($DescriptorHash+'.lock')),'OpenOrCreate','ReadWrite','None')
    try {
        $created=!(Test-Path -LiteralPath $cache)
        $manifestPath=Join-Path $cache 'manifest.local.json'
        if($created){
            [IO.Directory]::CreateDirectory($cache)|Out-Null
            $files=@(foreach($entry in $Phrases.GetEnumerator()){
                $path=Join-Path $cache ($entry.Key+'.wav')
                & $Synthesize $path ([string]$entry.Value)
                [pscustomobject]@{Name=$entry.Key;File=$entry.Key+'.wav';Text=$entry.Value;
                    SHA256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash;Bytes=(Get-Item -LiteralPath $path).Length}
            })
            $manifest=[ordered]@{Schema='iw7.frozen-speech/1';DescriptorSHA256=$DescriptorHash;VoiceTokenId=$VoiceTokenId;
                SynthesizedUtc=[datetime]::UtcNow.ToString('o');Files=$files}
            $encoded=[Text.UTF8Encoding]::new($false).GetBytes(($manifest|ConvertTo-Json -Depth 6))
            $output=[IO.FileStream]::new($manifestPath,'CreateNew','Write','None')
            try{$output.Write($encoded)}finally{$output.Dispose()}
        }
        if((Get-Item -LiteralPath $cache).Attributes -band [IO.FileAttributes]::ReparsePoint -or
            !(Test-Path -LiteralPath $manifestPath -PathType Leaf)){throw 'Speech cache is incomplete or redirected; preserve it for diagnosis.'}
        $manifestGuard=[IO.FileStream]::new($manifestPath,'Open','Read','Read')
        try {
            if($manifestGuard.Length -gt 64KB){throw 'Speech cache manifest exceeds bound.'}
            $reader=[IO.StreamReader]::new($manifestGuard,[Text.Encoding]::UTF8,$true,4096,$true)
            try{$manifest=$reader.ReadToEnd()|ConvertFrom-Json}finally{$reader.Dispose()}
            if($manifest.Schema -cne 'iw7.frozen-speech/1' -or $manifest.DescriptorSHA256 -cne $DescriptorHash -or
                $manifest.VoiceTokenId -cne $VoiceTokenId -or $manifest.Files.Count -ne 2){throw 'Frozen speech descriptor differs.'}
            $payloads=@{}
            foreach($entry in $Phrases.GetEnumerator()){
                $rows=@($manifest.Files|Where-Object Name -CEQ $entry.Key)
                if($rows.Count -ne 1 -or $rows[0].File -cne ($entry.Key+'.wav') -or $rows[0].Text -cne $entry.Value -or
                    $rows[0].SHA256 -cnotmatch '^[A-F0-9]{64}$' -or $rows[0].Bytes -le 44 -or $rows[0].Bytes -gt 16MB){throw 'Frozen speech file contract differs.'}
                $path=Join-Path $cache $rows[0].File
                if((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Redirected frozen speech file refused.'}
                $guard=[IO.FileStream]::new($path,'Open','Read','Read')
                try {
                    if($guard.Length -ne $rows[0].Bytes){throw 'Frozen speech length differs.'}
                    $bytes=[byte[]]::new([int]$guard.Length);$guard.ReadExactly($bytes)
                    if([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)) -cne $rows[0].SHA256){throw 'Frozen speech hash differs; never regenerate over it.'}
                    if([Text.Encoding]::ASCII.GetString($bytes,0,4) -cne 'RIFF' -or
                        [Text.Encoding]::ASCII.GetString($bytes,8,4) -cne 'WAVE' -or
                        [BitConverter]::ToUInt32($bytes,4)+8 -ne $bytes.Length){throw 'Frozen speech is not a complete RIFF/WAVE.'}
                    $payloads[$entry.Key]=$bytes
                }finally{$guard.Dispose()}
            }
            [pscustomobject]@{Created=$created;Cache=$cache;SynthesizedUtc=$manifest.SynthesizedUtc;Files=$manifest.Files;Payloads=$payloads}
        }finally{$manifestGuard.Dispose()}
    }finally{$lock.Dispose()}
}
