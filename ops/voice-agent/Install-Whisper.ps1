[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. "$repo/ops/Resource-Scheduler.Core.ps1"
$root=Join-Path $repo 'tools/whisper-cpp'
Invoke-IW7ResourceJob -Scope $root -Kind Extract -PhysicalBytes 1GB -CommitBytes 2GB -Owner 'Pinned local CPU speech recognizer installation' -Body {
    [IO.Directory]::CreateDirectory($root)|Out-Null
    $archive=Join-Path $root 'whisper-bin-x64-b5454.zip'
    $archiveHash='6BA69E3482D7826214F90A6A9C84CA07782AEC1E1D0C6A7C30C994FD5D816CCB'
    if(!(Test-Path -LiteralPath $archive)){Invoke-WebRequest 'https://github.com/ggml-org/whisper.cpp/releases/download/b5454/whisper-bin-x64.zip' -OutFile $archive -TimeoutSec 180}
    if((Get-FileHash -LiteralPath $archive).Hash -cne $archiveHash){throw 'Official whisper CPU archive digest differs.'}
    $binaryRoot=Join-Path $root 'b5454'
    if(!(Test-Path -LiteralPath $binaryRoot)){
        $zip=[IO.Compression.ZipFile]::OpenRead($archive)
        try {
            $total=0L
            foreach($entry in $zip.Entries){
                $target=[IO.Path]::GetFullPath((Join-Path $binaryRoot $entry.FullName))
                if(!$target.StartsWith($binaryRoot+'\',[StringComparison]::OrdinalIgnoreCase) -or ($entry.ExternalAttributes -shr 16 -band 0xF000) -eq 0xA000){throw 'Redirected recognizer archive entry refused.'}
                $total+=$entry.Length
            }
            if($zip.Entries.Count -gt 200 -or $total -gt 256MB){throw 'Recognizer archive extraction exceeds bound.'}
        }finally{$zip.Dispose()}
        Expand-Archive -LiteralPath $archive -DestinationPath $binaryRoot
    }
    $zip=[IO.Compression.ZipFile]::OpenRead($archive)
    try {
        foreach($entry in $zip.Entries){
            if(!$entry.Name){continue}
            $target=[IO.Path]::GetFullPath((Join-Path $binaryRoot $entry.FullName))
            if(!$target.StartsWith($binaryRoot+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Recognizer archive path escaped root.'}
            $source=$entry.Open();$hash=[Security.Cryptography.SHA256]::Create()
            try{$expected=[Convert]::ToHexString($hash.ComputeHash($source))}finally{$source.Dispose();$hash.Dispose()}
            if(!(Test-Path -LiteralPath $target -PathType Leaf) -or (Get-FileHash -LiteralPath $target).Hash -cne $expected){throw 'Extracted recognizer differs from the pinned archive; preserve it.'}
        }
    }finally{$zip.Dispose()}
    $model=Join-Path $root 'ggml-base.en.bin'
    $modelHash='A03779C86DF3323075F5E796CB2CE5029F00EC8869EEE3FDFB897AFE36C6D002'
    if(!(Test-Path -LiteralPath $model)){Invoke-WebRequest 'https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-base.en.bin' -OutFile $model -TimeoutSec 180}
    if((Get-Item -LiteralPath $model).Length -ne 147964211 -or (Get-FileHash -LiteralPath $model).Hash -cne $modelHash){throw 'Pinned official English base model differs.'}
    $files=@(Get-ChildItem -LiteralPath $binaryRoot -Recurse -File | ForEach-Object {[pscustomobject]@{Relative=$_.FullName.Substring($root.Length+1);SHA256=(Get-FileHash -LiteralPath $_.FullName).Hash}})
    [pscustomobject]@{Release='b5454';UpstreamCommit='d1be6fde11ac6e0407606b4e42fe72d34add8037';ArchiveSHA256=$archiveHash;ModelRevision='5359861c739e955e79d9a303bcbc70fb988958b1';ModelSHA256=$modelHash;Files=$files;CPUOnly=$true}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $root 'provenance.local.json')
    [pscustomobject]@{Root=$root;Release='b5454';ModelSHA256=$modelHash}
}
