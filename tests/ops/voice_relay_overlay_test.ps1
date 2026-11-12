# Offline test of ops/Voice-RelayOverlay.Core.ps1: apply, exact removal, resumed
# removal, refusal of tampering, of leftovers and of receipt rows without the original
# header bytes, the certification probe overlay, the image folder, the
# voice-certify-build.json contract read by ops/voice-certify/Invoke-VoiceCertify.ps1
# and the refusal of checkouts that still carry the retired private voice relay.
# It builds nothing and starts no game. -ReferenceRepo (an iw7-mod clone containing
# the native pin) also checks the real pinned patch against the real pinned headers.
param([string]$ReferenceRepo)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. "$repo/ops/Voice-RelayOverlay.Core.ps1"
$script:checks = 0
function Assert([bool]$Condition, [string]$Message) { if (!$Condition) { throw $Message }; $script:checks++ }
function Refuses([scriptblock]$Action, [string]$Pattern, [string]$Message) {
    $refused = $false
    try { & $Action } catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw "$Message (unexpected error: $($_.Exception.Message))" }
        $refused = $true
    }
    if (!$refused) { throw $Message }
    $script:checks++
}
function Invoke-Git { & git @args | Out-Null; if ($LASTEXITCODE) { throw "git $($args -join ' ') failed" } }
function Get-Bytes([string]$Path) { , [IO.File]::ReadAllBytes($Path) }
function Get-Hash([string]$Path) { (Get-FileHash -LiteralPath $Path).Hash }
function Same([byte[]]$A, [byte[]]$B) { [Convert]::ToHexString($A) -ceq [Convert]::ToHexString($B) }

$sandbox = Join-Path ([IO.Path]::GetTempPath()) ('iw7-voice-overlay-test-' + [guid]::NewGuid().ToString('N'))
try {
    # ---- synthetic native checkout, relay patch and source root
    $native = Join-Path $sandbox 'native'; $source = Join-Path $sandbox 'source'
    $structs = Join-Path $native 'src/client/game/structs.hpp'; $symbols = Join-Path $native 'src/client/game/symbols.hpp'
    $voice = Join-Path $native 'src/client/component/voice.cpp'; $probe = Join-Path $native 'src/client/component/voice_test.cpp'
    [IO.Directory]::CreateDirectory((Split-Path $structs)) | Out-Null
    [IO.Directory]::CreateDirectory((Split-Path $voice)) | Out-Null
    Invoke-Git -C $native init -q
    Invoke-Git -C $native config core.autocrlf false
    [IO.File]::WriteAllText($structs, "namespace game`n{`n`tstruct netadr_s {};`n}`n")
    [IO.File]::WriteAllText($symbols, "namespace game`n{`n`tWEAK symbol<int()> Sys_Milliseconds{ 0x140D58110 };`n}`n")
    [IO.File]::WriteAllText((Join-Path $native 'src/client/component/party.cpp'), "// unrelated`n")
    $flags = Join-Path $native 'src/common/utils/flags.cpp'
    [IO.Directory]::CreateDirectory((Split-Path $flags)) | Out-Null
    [IO.File]::WriteAllText($flags, "namespace utils::flags`n{`n}`n")
    Invoke-Git -C $native add -A
    Invoke-Git -C $native -c user.name=test -c user.email=test@example.invalid commit -q -m base
    $base = (& git -C $native rev-parse HEAD).Trim()
    [IO.File]::AppendAllText($structs, "struct VoicePacket_t { char data[256]; int dataSize; };`n")
    [IO.File]::AppendAllText($symbols, "WEAK symbol<int(int)> CL_ControllerIndexFromClientNum{ 0x140347690 };`n")
    [IO.File]::WriteAllText($voice, "// relay`nnamespace voice {}`n")
    Invoke-Git -C $native add -A
    Invoke-Git -C $native -c user.name=test -c user.email=test@example.invalid commit -q -m relay
    $patchDir = Join-Path $source 'ops/voice-relay'
    [IO.Directory]::CreateDirectory($patchDir) | Out-Null
    Invoke-Git -C $native format-patch -1 HEAD --no-signature -o $patchDir
    $patch = @(Get-ChildItem -LiteralPath $patchDir -Filter '*.patch')[0]
    $after = @{}
    foreach ($path in @('src/client/component/voice.cpp', 'src/client/game/structs.hpp', 'src/client/game/symbols.hpp')) { $after[$path] = Get-Hash (Join-Path $native $path) }
    Invoke-Git -C $native reset -q --hard $base
    # Simulate a core.autocrlf=true checkout: the working tree holds CRLF headers.
    foreach ($path in @($structs, $symbols)) { [IO.File]::WriteAllText($path, [IO.File]::ReadAllText($path).Replace("`n", "`r`n")) }
    $originalStructs = Get-Bytes $structs; $originalSymbols = Get-Bytes $symbols
    $lfHash = { param($path) Get-IW7VoiceHash (ConvertTo-IW7VoiceLf ([IO.File]::ReadAllBytes($path))) }
    $pin = [pscustomobject]@{
        UpstreamCommit = 'a' * 40; UpstreamBase = 'b' * 40; UpstreamBranch = 'feature/test'; NativeCommit = $base
        PatchPath = 'ops/voice-relay/' + $patch.Name; PatchSHA256 = (Get-Hash $patch.FullName)
        Files = @(
            [pscustomobject]@{ Path = 'src/client/component/voice.cpp'; BaseSHA256 = $null; AfterSHA256 = $after['src/client/component/voice.cpp'] }
            [pscustomobject]@{ Path = 'src/client/game/structs.hpp'; BaseSHA256 = (& $lfHash $structs); AfterSHA256 = $after['src/client/game/structs.hpp'] }
            [pscustomobject]@{ Path = 'src/client/game/symbols.hpp'; BaseSHA256 = (& $lfHash $symbols); AfterSHA256 = $after['src/client/game/symbols.hpp'] }
        )
    }
    $receipt = Join-Path $native 'voice-relay-overlay.local.json'
    $untouched = { !(Test-Path $receipt) -and !(Test-Path $voice) -and (Same (Get-Bytes $structs) $originalStructs) -and (Same (Get-Bytes $symbols) $originalSymbols) }

    # ---- the production pin is internally consistent
    $production = Get-IW7VoiceRelayPin
    Assert ((Get-Hash (Join-Path $repo $production.PatchPath)) -ceq $production.PatchSHA256) 'The tracked relay patch differs from its pin.'
    Assert ($production.NativeCommit -ceq 'fa305a1afcf4b7d05bb58eebd394c1a232fc9f5b') 'The relay pin must name the ServerModules native pin.'

    # ---- refusals before any write
    Assert-IW7VoiceOverlayAbsent -NativeRoot $native -Commit $base; $script:checks++
    Refuses { Add-IW7VoiceRelayOverlay -NativeRoot $native -SourceRoot $source -Commit ('c' * 40) -Pin $pin } 'qualified only' 'A different native commit was accepted.'
    Assert (& $untouched) 'A refused commit wrote files.'
    $wrongPatch = $pin.PSObject.Copy(); $wrongPatch.PatchSHA256 = '0' * 64
    Refuses { Add-IW7VoiceRelayOverlay -NativeRoot $native -SourceRoot $source -Commit $base -Pin $wrongPatch } 'differs from its pin' 'A patch hash mismatch was accepted.'
    Assert (& $untouched) 'A refused patch wrote files.'
    [IO.File]::AppendAllText($structs, "// unowned edit`r`n")
    Refuses { Add-IW7VoiceRelayOverlay -NativeRoot $native -SourceRoot $source -Commit $base -Pin $pin } 'Unowned engine header edits' 'An unowned header edit was overwritten.'
    Assert (!(Test-Path $receipt) -and !(Test-Path $voice)) 'A refused header edit wrote files.'
    Refuses { Assert-IW7VoiceOverlayAbsent -NativeRoot $native -Commit $base } 'differs from' 'An unowned header edit passed the leftover check.'
    [IO.File]::WriteAllBytes($structs, $originalStructs)
    [IO.File]::WriteAllText($voice, '// leftover from a manual git apply')
    Refuses { Add-IW7VoiceRelayOverlay -NativeRoot $native -SourceRoot $source -Commit $base -Pin $pin } 'Unowned src/client/component/voice.cpp' 'A leftover voice.cpp was overwritten.'
    Refuses { Assert-IW7VoiceOverlayAbsent -NativeRoot $native -Commit $base } 'not part of' 'A leftover voice.cpp passed the leftover check.'
    Remove-Item -LiteralPath $voice
    Assert (& $untouched) 'Refusal cases changed the checkout.'
    Remove-IW7VoiceRelayOverlay $native; $script:checks++   # no receipt: nothing to do

    # ---- apply and exact removal
    $summary = Add-IW7VoiceRelayOverlay -NativeRoot $native -SourceRoot $source -Commit $base -Pin $pin
    Assert ((Test-Path $receipt) -and (Get-Hash $voice) -ceq $pin.Files[0].AfterSHA256 -and (Get-Hash $structs) -ceq $pin.Files[1].AfterSHA256 -and
        (Get-Hash $symbols) -ceq $pin.Files[2].AfterSHA256) 'The overlay did not produce the pinned result bytes.'
    Assert (($summary | ConvertTo-Json -Depth 6) -notmatch '"Before"') 'The overlay summary leaks original bytes.'
    $state = Get-IW7VoiceOverlayState $native
    Assert ($state.VoiceRelay -and !$state.VoiceCertify -and $state.VoiceRelayOverlay.PatchSHA256 -ceq $pin.PatchSHA256) 'Receipt state differs.'
    Refuses { Add-IW7VoiceRelayOverlay -NativeRoot $native -SourceRoot $source -Commit $base -Pin $pin } 'before reapplying' 'The overlay was applied twice.'
    Refuses { Assert-IW7VoiceOverlayAbsent -NativeRoot $native -Commit $base } 'still present' 'A live receipt passed the leftover check.'
    Remove-IW7VoiceRelayOverlay $native
    Assert (& $untouched) 'Removal did not restore the exact original CRLF bytes.'
    Remove-IW7VoiceRelayOverlay $native; $script:checks++   # idempotent
    Assert-IW7VoiceOverlayAbsent -NativeRoot $native -Commit $base; $script:checks++
    Assert (!(Get-IW7VoiceOverlayState $native).VoiceRelay) 'State reports a removed overlay.'

    # ---- tampering is refused and preserved
    $null = Add-IW7VoiceRelayOverlay -NativeRoot $native -SourceRoot $source -Commit $base -Pin $pin
    $relayed = Get-Bytes $voice
    [IO.File]::AppendAllText($voice, '// local change')
    Refuses { Remove-IW7VoiceRelayOverlay $native } 'Changed voice overlay file' 'A changed relay file was removed.'
    Refuses { Get-IW7VoiceOverlayState $native } 'Changed voice overlay file' 'A changed relay file was reported as owned.'
    Assert ((Test-Path $receipt) -and (Get-Content -LiteralPath $voice -Raw).Contains('// local change')) 'A refused removal lost the change or the receipt.'
    [IO.File]::WriteAllBytes($voice, $relayed)
    $text = Get-Content -LiteralPath $receipt -Raw
    Set-Content -LiteralPath $receipt -Value ($text.Replace('iw7.voice-relay-overlay/1', 'iw7.voice-relay-overlay/0')) -NoNewline
    Refuses { Remove-IW7VoiceRelayOverlay $native } 'Invalid voice overlay receipt' 'A receipt with another schema was trusted.'
    $json = $text | ConvertFrom-Json; $json.Root = Join-Path $sandbox 'elsewhere'
    $json | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $receipt
    Refuses { Remove-IW7VoiceRelayOverlay $native } 'Invalid voice overlay receipt' 'A receipt for another root was trusted.'
    Set-Content -LiteralPath $receipt -Value $text -NoNewline
    Remove-IW7VoiceRelayOverlay $native
    Assert (& $untouched) 'Recovery after refusals did not restore the original bytes.'

    # ---- an interrupted apply keeps a receipt that can restore everything
    $relayedSymbols = $null
    $null = Add-IW7VoiceRelayOverlay -NativeRoot $native -SourceRoot $source -Commit $base -Pin $pin
    $relayedSymbols = Get-Bytes $symbols
    Remove-IW7VoiceRelayOverlay $native
    (Get-Item -LiteralPath $symbols).IsReadOnly = $true
    try { Refuses { Add-IW7VoiceRelayOverlay -NativeRoot $native -SourceRoot $source -Commit $base -Pin $pin } 'denied|read-only|access' 'A failed write was ignored.' }
    finally { (Get-Item -LiteralPath $symbols).IsReadOnly = $false }
    Assert (Test-Path $receipt) 'The receipt must exist before the first source write.'
    Refuses { Get-IW7VoiceOverlayState $native } 'Changed voice overlay file src/client/game/symbols.hpp' 'A partial overlay was reported as owned.'
    # symbols.hpp still holds its original bytes, so removal skips it and restores the rest.
    Remove-IW7VoiceRelayOverlay $native
    Assert (& $untouched) 'The receipt of an interrupted apply did not restore the original bytes.'
    $null = Add-IW7VoiceRelayOverlay -NativeRoot $native -SourceRoot $source -Commit $base -Pin $pin
    [IO.File]::WriteAllBytes($symbols, $relayedSymbols)
    [IO.File]::AppendAllText($symbols, "// local change`r`n")
    Refuses { Remove-IW7VoiceRelayOverlay $native } 'Changed voice overlay file src/client/game/symbols.hpp' 'A header in neither the result nor the original state was overwritten.'
    Assert ((Test-Path $receipt) -and (Test-Path $voice)) 'A refused removal changed other files.'
    [IO.File]::WriteAllBytes($symbols, $relayedSymbols)
    Remove-IW7VoiceRelayOverlay $native
    Assert (& $untouched) 'Recovery after a changed header did not restore the original bytes.'

    # ---- an interrupted removal resumes: rows already restored are skipped
    $null = Add-IW7VoiceRelayOverlay -NativeRoot $native -SourceRoot $source -Commit $base -Pin $pin
    (Get-Item -LiteralPath $structs).IsReadOnly = $true
    try { Refuses { Remove-IW7VoiceRelayOverlay $native } 'denied|read-only|access' 'A failed restore was ignored.' }
    finally { (Get-Item -LiteralPath $structs).IsReadOnly = $false }
    Assert ((Test-Path $receipt) -and !(Test-Path $voice) -and (Get-Hash $structs) -ceq $pin.Files[1].AfterSHA256) 'The interrupted removal left an unexpected state.'
    Refuses { Get-IW7VoiceOverlayState $native } 'Changed voice overlay file src/client/component/voice.cpp' 'A half-removed overlay was reported as owned.'
    Remove-IW7VoiceRelayOverlay $native
    Assert (& $untouched) 'The resumed removal did not restore the original bytes.'

    # ---- receipt rows must match the kind of file: headers keep their original bytes
    $null = Add-IW7VoiceRelayOverlay -NativeRoot $native -SourceRoot $source -Commit $base -Pin $pin
    $text = Get-Content -LiteralPath $receipt -Raw
    foreach ($path in @('src/client/game/structs.hpp', 'src/client/game/symbols.hpp')) {
        $json = $text | ConvertFrom-Json
        $row = @($json.Files | Where-Object Path -ceq $path)[0]; $row.Before = $null; $row.BeforeSHA256 = $null
        $json | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $receipt
        Refuses { Remove-IW7VoiceRelayOverlay $native } "Missing original bytes for $([regex]::Escape($path))" "A $path row without original bytes was trusted."
        Refuses { Get-IW7VoiceOverlayState $native } 'Missing original bytes' "State trusted a $path row without original bytes."
        Assert ((Test-Path $structs) -and (Test-Path $symbols) -and (Test-Path $voice)) "A refused $path row deleted a file."
    }
    $json = $text | ConvertFrom-Json
    $row = @($json.Files | Where-Object Path -ceq 'src/client/component/voice.cpp')[0]
    $row.Before = [Convert]::ToBase64String([byte[]](1, 2)); $row.BeforeSHA256 = Get-IW7VoiceHash ([byte[]](1, 2))
    $json | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $receipt
    Refuses { Remove-IW7VoiceRelayOverlay $native } 'Unexpected original bytes for src/client/component/voice\.cpp' 'A created file row with original bytes was trusted.'
    Assert ((Get-Hash $voice) -ceq $pin.Files[0].AfterSHA256) 'A refused voice.cpp row changed the file.'
    Set-Content -LiteralPath $receipt -Value $text -NoNewline
    Remove-IW7VoiceRelayOverlay $native
    Assert (& $untouched) 'Recovery after invalid receipt rows did not restore the original bytes.'
    $wrongKind = $pin.PSObject.Copy(); $wrongKind.Files = @($pin.Files | ForEach-Object { $_.PSObject.Copy() }); $wrongKind.Files[1].BaseSHA256 = $null
    Refuses { Add-IW7VoiceRelayOverlay -NativeRoot $native -SourceRoot $source -Commit $base -Pin $wrongKind } 'wrongly as new or existing' 'A pin that treats a header as new was accepted.'
    Assert (& $untouched) 'A refused pin wrote files.'

    # ---- certification probe overlay
    [IO.Directory]::CreateDirectory((Join-Path $source 'src/native')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $source 'src/native/voice_test.cpp'), "// lab-only probe`n")
    $certify = Add-IW7VoiceCertifyOverlay -NativeRoot $native -SourceRoot $source
    Assert ((Get-Hash $probe) -ceq (Get-Hash (Join-Path $source 'src/native/voice_test.cpp')) -and $certify.SourceSHA256 -ceq (Get-Hash $probe)) 'The probe overlay differs from its source.'
    Refuses { Add-IW7VoiceCertifyOverlay -NativeRoot $native -SourceRoot $source } 'before reapplying' 'The probe overlay was applied twice.'
    [IO.File]::AppendAllText($probe, '// local change')
    Refuses { Remove-IW7VoiceCertifyOverlay $native } 'Changed voice overlay file' 'A changed probe was removed.'
    [IO.File]::WriteAllText($probe, "// lab-only probe`n")
    Remove-IW7VoiceCertifyOverlay $native
    Assert (!(Test-Path $probe) -and !(Test-Path (Join-Path $native 'voice-certify-overlay.local.json'))) 'The probe overlay was not removed.'
    $null = Add-IW7VoiceCertifyOverlay -NativeRoot $native -SourceRoot $source
    Remove-Item -LiteralPath $probe   # as if a removal stopped after deleting the probe
    Refuses { Get-IW7VoiceOverlayState $native } 'Changed voice overlay file' 'A receipt without its probe was reported as owned.'
    Remove-IW7VoiceCertifyOverlay $native
    Assert (!(Test-Path $probe) -and !(Test-Path (Join-Path $native 'voice-certify-overlay.local.json'))) 'The probe receipt removal did not resume.'
    [IO.File]::WriteAllText($probe, '// leftover')
    Refuses { Add-IW7VoiceCertifyOverlay -NativeRoot $native -SourceRoot $source } 'Unowned voice_test.cpp' 'A leftover probe was overwritten.'
    Refuses { Assert-IW7VoiceOverlayAbsent -NativeRoot $native -Commit $base } 'voice_test.cpp is not part of' 'A leftover probe passed the leftover check.'
    Remove-Item -LiteralPath $probe

    # ---- image folder and the certification record read by Invoke-VoiceCertify
    $null = Add-IW7VoiceRelayOverlay -NativeRoot $native -SourceRoot $source -Commit $base -Pin $pin
    $null = Add-IW7VoiceCertifyOverlay -NativeRoot $native -SourceRoot $source
    $relayState = Get-IW7VoiceOverlayState $native
    Remove-IW7VoiceCertifyOverlay $native; Remove-IW7VoiceRelayOverlay $native
    $null = Add-IW7VoiceCertifyOverlay -NativeRoot $native -SourceRoot $source
    $baseState = Get-IW7VoiceOverlayState $native
    Remove-IW7VoiceCertifyOverlay $native
    Assert (& $untouched) 'Overlay round trips changed the checkout.'
    Assert ($relayState.VoiceRelay -and $relayState.VoiceCertify -and !$baseState.VoiceRelay -and $baseState.VoiceCertify) 'Overlay states differ.'
    Refuses { New-IW7VoiceCertifyBuildRecord -Image $voice -State ([pscustomobject]@{ VoiceCertify = $false }) } 'needs the verified' 'A record without the probe was written.'
    $runtime = Join-Path $sandbox 'runtime'; $built = Join-Path $sandbox 'built'
    [IO.Directory]::CreateDirectory($built) | Out-Null
    $images = @{}
    foreach ($kind in @('relay', 'base')) {
        $exe = Join-Path $built "$kind.exe"; [IO.File]::WriteAllText($exe, "synthetic $kind image")
        [IO.File]::WriteAllText((Join-Path $built "$kind.pdb"), "synthetic $kind symbols")
        $image = Publish-IW7VoiceOptInImage -Runtime $runtime -Executable $exe -Symbols (Join-Path $built "$kind.pdb") -Certify
        Assert ($image.Folder -ceq (Join-Path $runtime ('voice-certify-images/' + (Get-Hash $exe))) -and (Get-Hash $image.Image) -ceq (Get-Hash $exe)) 'Image folder differs.'
        $state = if ($kind -eq 'relay') { $relayState } else { $baseState }
        New-IW7VoiceCertifyBuildRecord -Image $image.Image -State $state -IsolatedAppData $true -TestPrivacy $true -Upstream $base -ProjectCommit ('d' * 40) -ProjectDirty $false |
            ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $image.Folder 'voice-certify-build.json') -Encoding UTF8
        $images[$kind] = $image
    }
    Refuses { Publish-IW7VoiceOptInImage -Runtime $runtime -Executable (Join-Path $built 'base.exe') -Symbols (Join-Path $built 'base.pdb') -Certify } 'already exists' 'An existing image folder was overwritten.'
    $relayOnly = Publish-IW7VoiceOptInImage -Runtime $runtime -Executable (Join-Path $built 'relay.exe') -Symbols (Join-Path $built 'relay.pdb')
    Assert ($relayOnly.Folder -ceq (Join-Path $runtime ('voice-relay-images/' + (Get-Hash (Join-Path $built 'relay.exe'))))) 'Relay-only image folder differs.'
    Assert (!(Test-Path (Join-Path $runtime 'voice-package'))) 'An opt-in image reached runtime/voice-package.'
    $record = Get-Content -LiteralPath (Join-Path $images.relay.Folder 'voice-certify-build.json') -Raw | ConvertFrom-Json
    Assert ($record.relay.patchSHA256 -ceq $pin.PatchSHA256 -and $record.overlays.voiceRelay -eq $true -and $record.voiceTestSHA256 -ceq $relayState.VoiceCertifyOverlay.Files[0].AfterSHA256) 'Relay record content differs.'

    $server = Join-Path $sandbox 'server'; $peer = Join-Path $server 'agent-peer'; $clientA = Join-Path $sandbox 'client'
    foreach ($root in @($server, $peer, $clientA)) { [IO.Directory]::CreateDirectory((Join-Path $root 'iw7-mod')) | Out-Null; [IO.File]::WriteAllText((Join-Path $root 'iw7_ship.exe'), 'x') }
    foreach ($root in @($server, $peer)) { [IO.File]::WriteAllText((Join-Path $root 'iw7-mod\paris-isolated-lab.marker'), 'iw7-paris-isolated-lab-v1') }
    foreach ($map in @('cp_zmb', 'cp_rave', 'mp_frontier')) { [IO.File]::WriteAllText((Join-Path $server "$map.ff"), 'x') }
    $harness = Join-Path $repo 'ops/voice-certify/Invoke-VoiceCertify.ps1'
    foreach ($case in @(@('relay', $false, $true), @('base', $true, $true), @('relay', $true, $false), @('base', $false, $false))) {
        $baseline = [bool]$case[1]
        $output = & $harness -ServerRoot $server -ClientARoot $clientA -LabImage $images[$case[0]].Image -OutputRoot (Join-Path $sandbox 'evidence') -Baseline:$baseline -DryRun
        $problems = @($output | Where-Object { $_ -match '^\s+! .*(manifest|overlay|voice relay|image)' })
        Assert (($problems.Count -eq 0) -eq $case[2]) "Invoke-VoiceCertify preflight decision differs for the $($case[0]) image (Baseline=$($case[1])): $($problems -join ' | ')"
    }

    # ---- checkouts that still carry the retired private relay are refused
    Assert-IW7NoRetiredVoiceOverlay -NativeRoot $native -Commit $base; $script:checks++
    foreach ($name in @('paris_voice.cpp', 'paris_voice_protocol.hpp', 'voice_relay.cpp', 'voice_relay.hpp', 'voice_capture_wire.hpp', 'voice_ptt_guard.hpp', 'voice_test_capture.cpp')) {
        $leftover = Join-Path $native ('src/client/component/' + $name)
        [IO.File]::WriteAllText($leftover, '// copied by an older Build-Voice')
        Refuses { Assert-IW7NoRetiredVoiceOverlay -NativeRoot $native -Commit $base } "retired voice sources \($([regex]::Escape($name))\)" "Retired $name was accepted."
        Assert (Test-Path -LiteralPath $leftover) "The check deleted retired $name."
        Remove-Item -LiteralPath $leftover
    }
    $receipts = Join-Path $native 'paris-overlay-receipts'
    [IO.Directory]::CreateDirectory($receipts) | Out-Null
    Refuses { Assert-IW7NoRetiredVoiceOverlay -NativeRoot $native -Commit $base } 'push-to-talk input overlay receipt' 'A retired PTT receipt was accepted.'
    Remove-Item -LiteralPath $receipts
    $originalFlags = Get-Bytes $flags
    [IO.File]::WriteAllText($flags, "#include `"../../client/component/voice_relay.hpp`"`nnamespace utils::flags`n{`n}`n")
    Refuses { Assert-IW7NoRetiredVoiceOverlay -NativeRoot $native -Commit $base } 'player-defaults flag overlay' 'A retired flags.cpp overlay was accepted.'
    [IO.File]::WriteAllText($flags, [Text.Encoding]::UTF8.GetString($originalFlags).Replace("`n", "`r`n"))
    Assert-IW7NoRetiredVoiceOverlay -NativeRoot $native -Commit $base; $script:checks++   # CRLF checkout of the pinned flags.cpp

    # ---- optional: the real pinned patch on the real pinned headers
    if ($ReferenceRepo) {
        $realBase = @{}
        foreach ($file in $production.Files) {
            if ($null -eq $file.BaseSHA256) { continue }
            $blob = Read-IW7VoiceGitBlob $ReferenceRepo ($production.NativeCommit + ':' + $file.Path)
            Assert ($null -ne $blob -and (Get-IW7VoiceHash (ConvertTo-IW7VoiceLf $blob)) -ceq $file.BaseSHA256) "Reference $($file.Path) differs from the pinned base."
            $realBase[$file.Path] = $blob
        }
        $real = Get-IW7VoiceRelayPatchedFiles -Pin $production -PatchFile (Join-Path $repo $production.PatchPath) -BaseBytes $realBase
        Assert ($real.Count -eq 3) 'The real patch did not produce three files.'
        Write-Output 'Real pinned patch applies to the pinned headers and reproduces the pinned result hashes.'
    } else { Write-Output 'Real pinned patch check skipped (no -ReferenceRepo).' }
} finally {
    if (Test-Path -LiteralPath $sandbox) {
        Get-ChildItem -LiteralPath $sandbox -Recurse -Force -File | ForEach-Object { $_.IsReadOnly = $false }
        Remove-Item -LiteralPath $sandbox -Recurse -Force
    }
}
Write-Output "PASS voice relay overlay: $script:checks checks."
