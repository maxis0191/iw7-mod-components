$ErrorActionPreference='Stop'
# Opt-in overlays for the upstream-shaped voice relay and the lab-only voice
# certification probe. Both follow the owner-cheats receipt convention: a local
# receipt in the native root records the original bytes and the expected result
# hashes, every build first restores those exact bytes, and changed files are
# preserved and refused. See docs/VOICE.md.

function Get-IW7VoiceRelayPin {
    # The relay is the local feature/voice-chat commit fbf1753 on auroramod
    # develop 85ada7c. The patch file in ops/voice-relay is its durable copy
    # (git format-patch -1 fbf1753 --no-signature). A rebase, a new commit or a
    # ServerModules pin bump changes these constants; re-record all of them.
    [pscustomobject]@{
        UpstreamCommit='fbf17531a4be72a31f1637dba38091c74f49cde0'
        UpstreamBase='85ada7c61e2b8722e9d3a704db490b909bb23ccb'
        UpstreamBranch='feature/voice-chat'
        NativeCommit='81e32f7a15139d7b92fdad2e5dbb5989149259cb'
        PatchPath='ops/voice-relay/0001-Relay-voice-chat-through-the-server.patch'
        PatchSHA256='C705EC499172261C96F7A8736AD6EBC2C5D681B90F89930B116F7E5A3E2680A6'
        # Hashes of LF text. Native checkouts made with core.autocrlf=true hold
        # CRLF copies; they are compared after CRLF to LF normalisation.
        Files=@(
            [pscustomobject]@{Path='src/client/component/voice.cpp';BaseSHA256=$null;AfterSHA256='0A5536325AB1B211F68AACA0AD49009469EF74CB2BE94231EC3119367214AC65'}
            [pscustomobject]@{Path='src/client/game/structs.hpp';BaseSHA256='C8B934A33631DAD43365071E4E350911BF2628A03681395BAE6ACADDF95A198B';AfterSHA256='DDB496C2F32B5BBD973728B7C5D703E7A7E6318556BA3A1D8A200AE86ED62B62'}
            [pscustomobject]@{Path='src/client/game/symbols.hpp';BaseSHA256='00749680108A094A3EFC3A02E9148EB4E76168E6CF80A0E0B657A804B6C8B2C9';AfterSHA256='0BC1D65F541B524DABF08838EF017C4FDBA037428F59D5C1204EBCF2948EAAB2'}
        )
    }
}

$script:IW7VoiceRelayPaths=@('src/client/component/voice.cpp','src/client/game/structs.hpp','src/client/game/symbols.hpp')
$script:IW7VoiceCertifyPath='src/client/component/voice_test.cpp'
# Files the overlays create. Every other overlay path is a tracked engine header,
# and its receipt row must hold the original bytes.
$script:IW7VoiceCreatedPaths=@('src/client/component/voice.cpp',$script:IW7VoiceCertifyPath)

function Get-IW7VoiceHash([byte[]]$Bytes) { [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)) }

function ConvertTo-IW7VoiceLf([byte[]]$Bytes) {
    # Latin-1 maps every byte to one char and back, so only CRLF pairs change.
    ,[Text.Encoding]::Latin1.GetBytes([Text.Encoding]::Latin1.GetString($Bytes).Replace("`r`n","`n"))
}

# Raw blob bytes; PowerShell's native-command pipeline would re-encode text.
function Read-IW7VoiceGitBlob([string]$Root,[string]$Spec) {
    $info=[Diagnostics.ProcessStartInfo]::new('git')
    foreach($argument in @('-C',$Root,'cat-file','blob',$Spec)){$info.ArgumentList.Add($argument)}
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;$info.UseShellExecute=$false
    $process=[Diagnostics.Process]::Start($info)
    try {
        $buffer=[IO.MemoryStream]::new()
        $errors=$process.StandardError.ReadToEndAsync()
        $process.StandardOutput.BaseStream.CopyTo($buffer)
        $process.WaitForExit()
        $null=$errors.Result
        if($process.ExitCode){return $null}
        ,$buffer.ToArray()
    } finally {$process.Dispose()}
}

function Get-IW7VoiceRelayPatchedFiles {
    # Applies the pinned patch to LF base bytes in a fresh temporary repository
    # outside every other repository, with core.autocrlf off, and verifies each
    # result against the pin. Returns @{<path>=<bytes>}.
    param([Parameter(Mandatory)]$Pin,[Parameter(Mandatory)][string]$PatchFile,[Parameter(Mandatory)][hashtable]$BaseBytes)
    if((Get-IW7VoiceHash ([IO.File]::ReadAllBytes($PatchFile))) -cne $Pin.PatchSHA256){throw 'Voice relay patch differs from its pin.'}
    $temp=Join-Path ([IO.Path]::GetTempPath()) ('iw7-voice-relay-'+[guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($temp)|Out-Null
    try {
        & git -C $temp init -q
        if($LASTEXITCODE){throw 'Temporary patch repository could not be created.'}
        foreach($file in $Pin.Files){
            if($null -eq $file.BaseSHA256){continue}
            $path=Join-Path $temp $file.Path
            [IO.Directory]::CreateDirectory((Split-Path $path))|Out-Null
            [IO.File]::WriteAllBytes($path,(ConvertTo-IW7VoiceLf $BaseBytes[$file.Path]))
        }
        & git -C $temp -c core.autocrlf=false -c core.safecrlf=false -c core.eol=lf apply --whitespace=nowarn $PatchFile
        if($LASTEXITCODE){throw 'The pinned voice relay patch did not apply to the pinned base.'}
        $result=@{}
        foreach($file in $Pin.Files){
            $path=Join-Path $temp $file.Path
            if(!(Test-Path -LiteralPath $path -PathType Leaf)){throw "Patched $($file.Path) is missing."}
            $bytes=[IO.File]::ReadAllBytes($path)
            if((Get-IW7VoiceHash $bytes) -cne $file.AfterSHA256){throw "Patched $($file.Path) differs from the pinned result."}
            $result[$file.Path]=$bytes
        }
        $result
    } finally {Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue}
}

function Add-IW7VoiceRelayOverlay {
    param([Parameter(Mandatory)][string]$NativeRoot,[Parameter(Mandatory)][string]$SourceRoot,[Parameter(Mandatory)][string]$Commit,$Pin)
    if(!$Pin){$Pin=Get-IW7VoiceRelayPin}
    $root=[IO.Path]::GetFullPath($NativeRoot)
    $receiptPath=Join-Path $root 'voice-relay-overlay.local.json'
    if(Test-Path -LiteralPath $receiptPath){throw 'Remove the voice relay overlay before reapplying.'}
    if($Commit -cne $Pin.NativeCommit){throw "The voice relay patch is qualified only for native pin $($Pin.NativeCommit)."}
    if(@($Pin.Files.Path|Sort-Object) -join ',' -cne (@($script:IW7VoiceRelayPaths|Sort-Object) -join ',')){throw 'Voice relay pin covers unexpected paths.'}
    foreach($file in $Pin.Files){
        if(($null -eq $file.BaseSHA256) -ne ($file.Path -cin $script:IW7VoiceCreatedPaths)){throw "Voice relay pin marks $($file.Path) wrongly as new or existing."}
    }
    $patchFile=Join-Path $SourceRoot $Pin.PatchPath
    if((Get-IW7VoiceHash ([IO.File]::ReadAllBytes($patchFile))) -cne $Pin.PatchSHA256){throw 'Voice relay patch differs from its pin.'}
    # Validate every input before the first write.
    $base=@{};$before=@{}
    foreach($file in $Pin.Files){
        $target=Join-Path $root $file.Path
        if($null -eq $file.BaseSHA256){
            if(Test-Path -LiteralPath $target){throw "Unowned $($file.Path) in the native checkout; preserve it."}
            continue
        }
        $blob=Read-IW7VoiceGitBlob $root ($Commit+':'+$file.Path)
        if($null -eq $blob -or (Get-IW7VoiceHash (ConvertTo-IW7VoiceLf $blob)) -cne $file.BaseSHA256){throw "Pinned $($file.Path) differs from the qualified base."}
        if(!(Test-Path -LiteralPath $target -PathType Leaf)){throw "Missing $($file.Path) in the native checkout."}
        $current=[IO.File]::ReadAllBytes($target)
        if((Get-IW7VoiceHash (ConvertTo-IW7VoiceLf $current)) -cne $file.BaseSHA256){throw "Unowned engine header edits in $($file.Path); preserve them."}
        $base[$file.Path]=$blob;$before[$file.Path]=$current
    }
    $after=Get-IW7VoiceRelayPatchedFiles -Pin $Pin -PatchFile $patchFile -BaseBytes $base
    $rows=@($Pin.Files|ForEach-Object{
        $original=$before[$_.Path]
        [ordered]@{Path=$_.Path;Before=$(if($null -ne $original){[Convert]::ToBase64String($original)}else{$null})
            BeforeSHA256=$(if($null -ne $original){Get-IW7VoiceHash $original}else{$null});AfterSHA256=$_.AfterSHA256}
    })
    $receipt=[ordered]@{Schema='iw7.voice-relay-overlay/1';Root=$root;NativeCommit=$Pin.NativeCommit;UpstreamCommit=$Pin.UpstreamCommit;
        UpstreamBase=$Pin.UpstreamBase;PatchSHA256=$Pin.PatchSHA256;Files=$rows}
    # The receipt exists before the first source byte changes.
    $receipt|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $receiptPath -Encoding utf8NoBOM
    foreach($file in $Pin.Files){
        $target=Join-Path $root $file.Path
        [IO.File]::WriteAllBytes($target,$after[$file.Path])
        if((Get-FileHash -LiteralPath $target).Hash -cne $file.AfterSHA256){throw "Written $($file.Path) differs from the pinned result."}
    }
    ConvertTo-IW7VoiceOverlaySummary $receipt
}

function ConvertTo-IW7VoiceOverlaySummary($Receipt) {
    $summary=[ordered]@{}
    foreach($property in $Receipt.Keys){if($property -cne 'Files' -and $property -cne 'Root'){$summary[$property]=$Receipt[$property]}}
    $summary.Files=@($Receipt.Files|ForEach-Object{[ordered]@{Path=$_.Path;BeforeSHA256=$_.BeforeSHA256;AfterSHA256=$_.AfterSHA256}})
    [pscustomobject]$summary
}

function Read-IW7VoiceOverlayReceipt([string]$NativeRoot,[string]$Name,[string]$Schema,[string[]]$Paths,[switch]$AllowRestored) {
    # Every row must hold its pinned result. With -AllowRestored (removal only),
    # a row already back in its original state is also accepted and listed in
    # Restored, so an interrupted apply or removal can finish.
    $root=[IO.Path]::GetFullPath($NativeRoot)
    $receiptPath=Join-Path $root $Name
    if(!(Test-Path -LiteralPath $receiptPath)){return $null}
    $receipt=Get-Content -LiteralPath $receiptPath -Raw|ConvertFrom-Json
    if($receipt.Schema -cne $Schema -or $receipt.Root -cne $root){throw "Invalid voice overlay receipt $Name."}
    $files=@($receipt.Files)
    if($files.Count -ne $Paths.Count -or (@($files.Path|Sort-Object) -join ',') -cne (@($Paths|Sort-Object) -join ',')){throw "Incomplete voice overlay receipt $Name."}
    $restored=@()
    foreach($row in $files){
        $created=$row.Path -cin $script:IW7VoiceCreatedPaths
        if($created -and ($null -ne $row.Before -or $null -ne $row.BeforeSHA256)){throw "Unexpected original bytes for $($row.Path) in $Name."}
        if(!$created -and ($null -eq $row.Before -or $null -eq $row.BeforeSHA256)){throw "Missing original bytes for $($row.Path) in $Name."}
        if(!$created -and (Get-IW7VoiceHash ([Convert]::FromBase64String($row.Before))) -cne $row.BeforeSHA256){throw "Corrupt original bytes in $Name."}
        $target=Join-Path $root $row.Path
        $hash=if(Test-Path -LiteralPath $target -PathType Leaf){(Get-FileHash -LiteralPath $target).Hash}else{$null}
        if($null -ne $hash -and $hash -ceq $row.AfterSHA256){continue}
        $original=if($created){!(Test-Path -LiteralPath $target)}else{$null -ne $hash -and $hash -ceq $row.BeforeSHA256}
        if($AllowRestored -and $original){$restored+=$row.Path;continue}
        throw "Changed voice overlay file $($row.Path); preserve source and receipt."
    }
    [pscustomobject]@{Path=$receiptPath;Receipt=$receipt;Root=$root;Restored=$restored}
}

function Remove-IW7VoiceOverlayFromReceipt($Read) {
    if(!$Read){return}
    foreach($row in @($Read.Receipt.Files)){
        if($row.Path -cin @($Read.Restored)){continue}
        $target=Join-Path $Read.Root $row.Path
        if($null -ne $row.Before){
            [IO.File]::WriteAllBytes($target,[Convert]::FromBase64String($row.Before))
            if((Get-FileHash -LiteralPath $target).Hash -cne $row.BeforeSHA256){throw "Restored $($row.Path) differs from its original bytes."}
        } else {Remove-Item -LiteralPath $target}
    }
    Remove-Item -LiteralPath $Read.Path
}

function Remove-IW7VoiceRelayOverlay([string]$NativeRoot) {
    Remove-IW7VoiceOverlayFromReceipt (Read-IW7VoiceOverlayReceipt $NativeRoot 'voice-relay-overlay.local.json' 'iw7.voice-relay-overlay/1' $script:IW7VoiceRelayPaths -AllowRestored)
}

function Add-IW7VoiceCertifyOverlay {
    param([Parameter(Mandatory)][string]$NativeRoot,[Parameter(Mandatory)][string]$SourceRoot)
    $root=[IO.Path]::GetFullPath($NativeRoot)
    $receiptPath=Join-Path $root 'voice-certify-overlay.local.json'
    if(Test-Path -LiteralPath $receiptPath){throw 'Remove the voice certification overlay before reapplying.'}
    $target=Join-Path $root $script:IW7VoiceCertifyPath
    if(Test-Path -LiteralPath $target){throw 'Unowned voice_test.cpp in the native checkout; preserve it.'}
    $bytes=[IO.File]::ReadAllBytes((Join-Path $SourceRoot 'src/native/voice_test.cpp'))
    $hash=Get-IW7VoiceHash $bytes
    $receipt=[ordered]@{Schema='iw7.voice-certify-overlay/1';Root=$root;SourceSHA256=$hash
        Files=@([ordered]@{Path=$script:IW7VoiceCertifyPath;Before=$null;BeforeSHA256=$null;AfterSHA256=$hash})}
    $receipt|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $receiptPath -Encoding utf8NoBOM
    [IO.File]::WriteAllBytes($target,$bytes)
    if((Get-FileHash -LiteralPath $target).Hash -cne $hash){throw 'Written voice_test.cpp differs from its source.'}
    ConvertTo-IW7VoiceOverlaySummary $receipt
}

function Remove-IW7VoiceCertifyOverlay([string]$NativeRoot) {
    Remove-IW7VoiceOverlayFromReceipt (Read-IW7VoiceOverlayReceipt $NativeRoot 'voice-certify-overlay.local.json' 'iw7.voice-certify-overlay/1' @($script:IW7VoiceCertifyPath) -AllowRestored)
}

function Assert-IW7VoiceOverlayAbsent {
    # Run after the Remove-* calls. Without a receipt, the relay and probe files
    # must match the pinned commit exactly (LF-normalised) or be absent there;
    # otherwise premake would compile an unowned voice.cpp/voice_test.cpp into a
    # build whose manifest says VoiceRelay=false.
    param([Parameter(Mandatory)][string]$NativeRoot,[Parameter(Mandatory)][string]$Commit)
    $root=[IO.Path]::GetFullPath($NativeRoot)
    foreach($name in @('voice-relay-overlay.local.json','voice-certify-overlay.local.json')){
        if(Test-Path -LiteralPath (Join-Path $root $name)){throw "Voice overlay receipt $name is still present; preserve it."}
    }
    foreach($path in @($script:IW7VoiceRelayPaths)+$script:IW7VoiceCertifyPath){
        $target=Join-Path $root $path
        $blob=Read-IW7VoiceGitBlob $root ($Commit+':'+$path)
        if($null -eq $blob){
            if(Test-Path -LiteralPath $target){throw "Unowned voice overlay: $path is not part of $Commit. Preserve it and use a fresh native checkout."}
            continue
        }
        if(!(Test-Path -LiteralPath $target -PathType Leaf) -or
            (Get-IW7VoiceHash (ConvertTo-IW7VoiceLf ([IO.File]::ReadAllBytes($target)))) -cne (Get-IW7VoiceHash (ConvertTo-IW7VoiceLf $blob))){
            throw "Unowned voice overlay: $path differs from $Commit. Preserve it and use a fresh native checkout."
        }
    }
}

# Sources of the retired private relay (v1 paris_voice, v2 voice_relay, fake
# capture, PTT guard) that older Build-Voice versions copied into checkouts.
$script:IW7RetiredVoiceSources=@('paris_voice.cpp','paris_voice_protocol.hpp','paris_voice_test_capture.cpp','paris_voice_test_capture.hpp',
    'voice_capture_adapter.hpp','voice_capture_wire.hpp','voice_inbox.hpp','voice_pcm_witness.hpp','voice_ptt_guard.hpp','voice_relay.cpp',
    'voice_relay.hpp','voice_state.hpp','voice_test_binding.hpp','voice_test_capture.cpp','voice_test_capture.hpp','voice_transport.hpp','voice_wire.hpp')

function Assert-IW7NoRetiredVoiceOverlay {
    # Fail closed and never delete: a reused checkout built by an older
    # Build-Voice still carries the retired relay's copied sources, its
    # flags.cpp player-defaults overlay or its push-to-talk input receipt.
    param([Parameter(Mandatory)][string]$NativeRoot,[Parameter(Mandatory)][string]$Commit)
    $root=[IO.Path]::GetFullPath($NativeRoot)
    $advice='build in a fresh -NativeRoot (prepared workspaces get one per revision).'
    $tracked=@(& git -C $root ls-tree --name-only "$Commit`:src/client/component")
    if($LASTEXITCODE){throw "Pinned component tree of $Commit is unreadable."}
    $found=@($script:IW7RetiredVoiceSources|Where-Object{$_ -cnotin $tracked -and (Test-Path -LiteralPath (Join-Path $root ('src/client/component/'+$_)))})
    if($found.Count){throw "Native checkout carries retired voice sources ($($found -join ', ')); $advice"}
    if(Test-Path -LiteralPath (Join-Path $root 'paris-overlay-receipts')){throw "Native checkout carries the retired push-to-talk input overlay receipt; $advice"}
    $flags='src/common/utils/flags.cpp'
    $blob=Read-IW7VoiceGitBlob $root ($Commit+':'+$flags)
    $target=Join-Path $root $flags
    if($null -eq $blob -or !(Test-Path -LiteralPath $target -PathType Leaf) -or
        (Get-IW7VoiceHash (ConvertTo-IW7VoiceLf ([IO.File]::ReadAllBytes($target)))) -cne (Get-IW7VoiceHash (ConvertTo-IW7VoiceLf $blob))){
        throw "Native checkout carries the retired player-defaults flag overlay (flags.cpp differs from $Commit); $advice"
    }
}

function Get-IW7VoiceOverlayState([string]$NativeRoot) {
    # Manifest flags come from verified receipts, never from the build switches.
    $relay=Read-IW7VoiceOverlayReceipt $NativeRoot 'voice-relay-overlay.local.json' 'iw7.voice-relay-overlay/1' $script:IW7VoiceRelayPaths
    $certify=Read-IW7VoiceOverlayReceipt $NativeRoot 'voice-certify-overlay.local.json' 'iw7.voice-certify-overlay/1' @($script:IW7VoiceCertifyPath)
    $toHashtable={param($object) $table=[ordered]@{}; foreach($p in $object.PSObject.Properties){$table[$p.Name]=$p.Value}; $table}
    [pscustomobject]@{
        VoiceRelay=[bool]$relay
        VoiceRelayOverlay=$(if($relay){ConvertTo-IW7VoiceOverlaySummary (& $toHashtable $relay.Receipt)}else{$null})
        VoiceCertify=[bool]$certify
        VoiceCertifyOverlay=$(if($certify){ConvertTo-IW7VoiceOverlaySummary (& $toHashtable $certify.Receipt)}else{$null})
    }
}

function Publish-IW7VoiceOptInImage {
    # Opt-in images never enter runtime/voice-package, which Main, labs and
    # other tools read. Each image gets its own folder named by its SHA-256.
    param([Parameter(Mandatory)][string]$Runtime,[Parameter(Mandatory)][string]$Executable,[Parameter(Mandatory)][string]$Symbols,[switch]$Certify)
    $hash=(Get-FileHash -LiteralPath $Executable).Hash
    $folder=Join-Path $Runtime ($(if($Certify){'voice-certify-images'}else{'voice-relay-images'})+'/'+$hash)
    if(Test-Path -LiteralPath $folder){throw "Image folder already exists; preserve it: $folder"}
    [IO.Directory]::CreateDirectory($folder)|Out-Null
    $image=Join-Path $folder 'iw7-mod.exe';$pdb=Join-Path $folder 'iw7-mod.pdb'
    Copy-Item -LiteralPath $Executable -Destination $image
    Copy-Item -LiteralPath $Symbols -Destination $pdb
    if((Get-FileHash -LiteralPath $image).Hash -cne $hash){throw 'Copied image hash mismatch.'}
    [pscustomobject]@{Folder=$folder;Image=$image;Symbols=$pdb;SHA256=$hash;SymbolsSHA256=(Get-FileHash -LiteralPath $pdb).Hash}
}

function New-IW7VoiceCertifyBuildRecord {
    # The contract read by ops/voice-certify/Invoke-VoiceCertify.ps1 (preflight):
    # schema, sha256 of the image beside it, and the four overlay booleans.
    param([Parameter(Mandatory)][string]$Image,[Parameter(Mandatory)]$State,[bool]$IsolatedAppData,[bool]$TestPrivacy,
        [string]$Upstream,[string]$ProjectCommit,$ProjectDirty)
    if(!$State.VoiceCertify){throw 'A certification record needs the verified voice_test.cpp overlay.'}
    [ordered]@{
        schema='iw7.voice-certify-build/1'
        sha256=(Get-FileHash -LiteralPath $Image).Hash
        image=[IO.Path]::GetFileName($Image)
        overlays=[ordered]@{voiceTest=$true;voiceRelay=[bool]$State.VoiceRelay;isolatedAppData=$IsolatedAppData;testPrivacy=$TestPrivacy}
        upstream=$Upstream
        relay=$(if($State.VoiceRelay){[ordered]@{upstreamCommit=$State.VoiceRelayOverlay.UpstreamCommit;upstreamBase=$State.VoiceRelayOverlay.UpstreamBase
            patchSHA256=$State.VoiceRelayOverlay.PatchSHA256;files=$State.VoiceRelayOverlay.Files}}else{$null})
        voiceTestSHA256=$State.VoiceCertifyOverlay.Files[0].AfterSHA256
        projectCommit=$ProjectCommit
        projectDirty=$ProjectDirty
        builtUtc=[datetime]::UtcNow.ToString('o')
    }
}
