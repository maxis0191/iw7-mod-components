# Pure helpers for Invoke-VoiceCertify.ps1. Dot-sourcing this file starts no process.

# Names the test component (voice_test.cpp) writes to events.jsonl. Aliases are
# accepted so a field rename there does not silently break the harness.
$script:VcEventNames = @{
    Start     = @('start', 'ready', 'init', 'voicetest_start')
    Snapshot  = @('snapshot')
    PlayStart = @('play_start')
    PlayEnd   = @('play_end')
    Recv      = @('recv')
    Encoded   = @('encoded')
    Error     = @('error', 'play_error')
    Connection = @('connection')
}
$script:VcFieldNames = @{
    ClientNum = @('clientNum', 'client_num', 'clientnum')
    Rate      = @('rate', 'sampleRate', 'sample_rate', 'nativeRate', 'native_rate', 'captureRate', 'capture_rate')
    Talker    = @('talker')
    Encoded   = @('encoded')
    State     = @('state', 'connection_state')
}

# Cumulative decoded samples a client snapshot reports for one talker ("recv": {"0": n, ...}).
function Get-VcRecvTotal($Snapshot, [int]$Talker) {
    if (!$Snapshot -or !$Snapshot.PSObject.Properties['recv'] -or !$Snapshot.recv) { return $null }
    $value = $Snapshot.recv.PSObject.Properties[[string]$Talker]
    if ($value) { [long]$value.Value } else { 0L }
}

function Get-VcField($Event, [string[]]$Names) {
    foreach ($name in $Names) {
        $property = $Event.PSObject.Properties[$name]
        if ($property) { return $property.Value }
    }
    $null
}

function Test-VcEvent($Event, [string]$Kind) {
    $Event -and $Event.PSObject.Properties['event'] -and ($script:VcEventNames[$Kind] -contains [string]$Event.event)
}

# Reads the complete lines appended to a file since $Offset. A line still being
# written is left for the next call. Returns the lines and the new offset.
function Read-VcNewLines([string]$Path, [long]$Offset) {
    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { return [pscustomobject]@{ Lines = @(); Offset = $Offset } }
    $stream = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try {
        if ($stream.Length -lt $Offset) { throw "File shrank while being followed: $Path" }
        $count = [int][math]::Min($stream.Length - $Offset, 64MB)
        $buffer = [byte[]]::new($count)
        $stream.Position = $Offset
        $read = 0
        while ($read -lt $count) {
            $n = $stream.Read($buffer, $read, $count - $read)
            if ($n -le 0) { break }
            $read += $n
        }
    } finally { $stream.Dispose() }
    $end = [Array]::LastIndexOf($buffer, [byte]10, $read - 1)
    if ($read -eq 0 -or $end -lt 0) { return [pscustomobject]@{ Lines = @(); Offset = $Offset } }
    $text = [Text.Encoding]::UTF8.GetString($buffer, 0, $end + 1)
    [pscustomobject]@{ Lines = @($text -split "`r?`n" | Where-Object { $_ -ne '' }); Offset = $Offset + $end + 1 }
}

function ConvertFrom-VcEventLine([string]$Line) {
    try { $Line | ConvertFrom-Json -ErrorAction Stop }
    catch { [pscustomobject]@{ event = 'malformed'; raw = $Line } }
}

function Get-VcFileLength([string]$Path) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) { (Get-Item -LiteralPath $Path).Length } else { 0L }
}

# "[voicecert] hb t=.. mode=cp map=cp_zmb gt=zombie n=2 p=0,allies,playing,1,100,0 p=1,..."
function ConvertFrom-VcHeartbeat([string]$Line) {
    if ($Line -notmatch '\[voicecert\] hb (.*)$') { return $null }
    $result = [ordered]@{ Map = ''; Gametype = ''; Mode = ''; Count = -1; Players = @{} }
    foreach ($token in ($Matches[1] -split '\s+')) {
        $pair = $token -split '=', 2
        if ($pair.Count -ne 2) { continue }
        switch ($pair[0]) {
            'map'  { $result.Map = $pair[1] }
            'gt'   { $result.Gametype = $pair[1] }
            'mode' { $result.Mode = $pair[1] }
            'n'    { $result.Count = [int]$pair[1] }
            'p'    {
                $f = $pair[1] -split ','
                if ($f.Count -ge 6 -and $f[0] -match '^\d+$') {
                    $result.Players[[string][int]$f[0]] = [pscustomobject]@{
                        Team = $f[1]; State = $f[2]; Alive = ($f[3] -eq '1'); Health = $f[4]; Extra = $f[5] }
                }
            }
        }
    }
    [pscustomobject]$result
}

# "[voicecert] ack <seq> <verb> <result...>"
function ConvertFrom-VcAck([string]$Line) {
    if ($Line -notmatch '\[voicecert\] ack (\S+) (\S+) (.*)$') { return $null }
    [pscustomobject]@{ Seq = $Matches[1]; Verb = $Matches[2]; Result = $Matches[3].Trim() }
}

function Test-VcFatalServerLine([string]$Line) {
    $Line -match '(?i)script compile error|unknown function|\[voicecert\] refused'
}

# The scenario matrix. Each scenario: optional setup actions, then one
# measurement window per direction. Inject=$false is an idle control.
function Get-VcScenarios {
    param([ValidateSet('CP', 'MP')][string]$Mode, [string]$CpSecondMap = 'cp_rave',
        [string]$MpMap = 'mp_frontier', [switch]$IncludeEndOfGame)
    $ab = , @('A', 'B'); $ba = , @('B', 'A')
    # StaleOk: the window may outlive the fixture (end of game rotates the map)
    function S($Id, $Title, $Expect, $Directions, $Actions = @(), [bool]$Inject = $true, [bool]$RequireAlive = $false, [bool]$StaleOk = $false) {
        [pscustomobject]@{ Id = $Id; Title = $Title; Expect = $Expect; Directions = $Directions; Actions = @($Actions)
            Inject = $Inject; RequireAlive = $RequireAlive; StaleOk = $StaleOk }
    }
    function Client($Role, $Command) { [pscustomobject]@{ Kind = 'client'; Role = $Role; Command = $Command } }
    function Request($Verb) { [pscustomobject]@{ Kind = 'request'; Verb = $Verb } }
    function ServerCmd($Command) { [pscustomobject]@{ Kind = 'server'; Command = $Command } }
    function AwaitMap($Map, $Gametype, $Fallback) { [pscustomobject]@{ Kind = 'awaitmap'; Map = $Map; Gametype = $Gametype; Fallback = $Fallback } }
    function Reconnect($Role) { [pscustomobject]@{ Kind = 'reconnect'; Role = $Role } }
    function Delay($Seconds) { [pscustomobject]@{ Kind = 'pause'; Seconds = $Seconds } }

    if ($Mode -eq 'CP') {
        return @(
            (S 'C0' 'idle control: nobody injects' 'silent' (@('A', 'B'), @('B', 'A')) -Inject $false)
            (S 'C1' 'A talks, B hears' 'heard' $ab)
            (S 'C2' 'B talks, A hears' 'heard' $ba)
            (S 'C3a' 'B mutes A' 'silent' $ab @((Client 'B' 'voicetest_mute {A}')))
            (S 'C3b' 'B unmutes A' 'heard' $ab @((Client 'B' 'voicetest_unmute {A}')))
            (S 'C4a' 'B sets cl_voice 0' 'silent' $ab @((Client 'B' 'cl_voice 0')))
            (S 'C4b' 'B sets cl_voice 1 again' 'heard' $ab @((Client 'B' 'cl_voice 1')))
            (S 'C5' 'A disconnects and reconnects' 'heard' $ab @((Reconnect 'A')))
            (S 'C6a' "map change to $CpSecondMap, A talks" 'heard' $ab @((ServerCmd "map $CpSecondMap"), (AwaitMap $CpSecondMap 'zombie' '')))
            (S 'C6b' "after the map change, B talks" 'heard' $ba)
        )
    }

    $scenarios = @(
        (S 'M0' 'idle control, same team' 'silent' (@('A', 'B'), @('B', 'A')) @((Request 'teams same')) -Inject $false -RequireAlive $true)
        (S 'M1a' 'same team, A talks' 'heard' $ab -RequireAlive $true)
        (S 'M1b' 'same team, B talks' 'heard' $ba -RequireAlive $true)
        (S 'M2a' 'opposite teams, both alive, A talks' 'silent' $ab @((Request 'teams opposite')) -RequireAlive $true)
        (S 'M2b' 'opposite teams, both alive, B talks' 'silent' $ba -RequireAlive $true)
    )
    if ($IncludeEndOfGame) {
        # the post-game rotation lands on FFA for M4
        $scenarios += S 'M3' 'end of game (everyone hears everyone)' 'heard' $ab @(
            (ServerCmd "sv_mapRotation `"gametype dm map $MpMap`""), (ServerCmd 'sv_mapRotationCurrent ""'),
            (Request 'endgame'), (Delay 3)) -StaleOk $true
        $toFfa = @((AwaitMap $MpMap 'dm' 'map_rotate'))
    } else {
        $toFfa = @((ServerCmd 'g_gametype dm'), (ServerCmd "map $MpMap"), (AwaitMap $MpMap 'dm' ''))
    }
    $scenarios += S 'M4a' 'free-for-all, A talks' 'heard' $ab $toFfa -RequireAlive $true
    $scenarios += S 'M4b' 'free-for-all, B talks' 'heard' $ba -RequireAlive $true
    $scenarios
}

# The last connection state a client reported (voice_test emits "connection" with
# "state" on every change; 9 = active). $null when it reported none yet.
function Get-VcLastConnectionState($Events, [int]$From = 0) {
    if ($null -eq $Events) { return $null }
    for ($i = $Events.Count - 1; $i -ge $From; $i--) {
        $item = $Events[$i]
        if (Test-VcEvent $item 'Connection') {
            $state = Get-VcField $item $script:VcFieldNames.State
            if ($null -ne $state) { return [int]$state }
        }
    }
    $null
}

# Whether a join should ask the client to connect now. The first ask comes
# $FirstDelaySeconds after the launch (the front end must be up); later asks every
# $EverySeconds, but never while the client reports a joining state (3..8 in the
# retail order disconnected, cinematic, logo, connecting, challenging, connected,
# sending stats, loading, primed, active) or the active state 9: a new connect
# would restart a join that is still progressing. A join stuck in such a state is
# the join-stall budget's job (stop and relaunch), not a resend's.
function Test-VcJoinResendDue([double]$SinceLaunchSeconds, $SinceLastSendSeconds, [double]$FirstDelaySeconds, [double]$EverySeconds, $ConnectionState) {
    if ($SinceLaunchSeconds -lt $FirstDelaySeconds) { return $false }
    if ($null -eq $SinceLastSendSeconds) { return $true }
    if ($null -ne $ConnectionState -and [int]$ConnectionState -ge 3) { return $false }
    [double]$SinceLastSendSeconds -ge $EverySeconds
}

# The request line of the lab fixture's file channel (paris_test_fixture.cpp):
# "<pid> <32 lowercase hex nonce> <action>", one line, no newline.
function New-VcRequestLine([int]$ProcessId, [string]$Action, [string]$Nonce = ([guid]::NewGuid().ToString('N'))) {
    if ($ProcessId -le 0 -or $Nonce -cnotmatch '^[0-9a-f]{32}$' -or $Action -notmatch '^\S+$') { throw 'A request needs a process id, a 32-hex nonce and one action word.' }
    "$ProcessId $Nonce $Action"
}

# Number of names (hard links) of a file; 0 when it does not exist. Opens the
# file for attributes only and never follows a reparse point.
function Get-VcLinkCount([string]$Path) {
    if (!('VcLinkCount' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class VcLinkCount {
    [StructLayout(LayoutKind.Sequential)]
    struct Info { public uint Attributes, CL, CH, AL, AH, WL, WH, VolumeSerial, SizeHigh, SizeLow, Links, IndexHigh, IndexLow; }
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetFileInformationByHandle(SafeFileHandle handle, out Info info);
    public static long Get(string path) {
        string name = path.StartsWith(@"\\") ? path : @"\\?\" + path;
        using (var handle = CreateFileW(name, 0x80, 7, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero)) {
            if (handle.IsInvalid) {
                int code = Marshal.GetLastWin32Error();
                if (code == 2 || code == 3) return 0;
                throw new Win32Exception(code, "open " + path);
            }
            Info info;
            if (!GetFileInformationByHandle(handle, out info)) throw new Win32Exception(Marshal.GetLastWin32Error(), "read " + path);
            return info.Links;
        }
    }
}
'@
    }
    [VcLinkCount]::Get([IO.Path]::GetFullPath($Path))
}

# Link guard: every file a run writes, restores or replaces in a game root must be
# absent or have exactly one name. A file with more names shares its data with
# another folder (a bench root links the retained stock), so writing it would
# change that folder too. Returns one problem line per refused file.
function Get-VcLinkProblems([string]$Root, [string[]]$Relatives) {
    foreach ($relative in @($Relatives | Where-Object { $_ } | Select-Object -Unique)) {
        $path = Join-Path $Root $relative
        $links = Get-VcLinkCount $path
        if ($links -gt 1) { "$relative in $Root has $links names (shared data); it is never written." }
    }
}

# Bench manifest checks the harness makes itself (the bench core's own check runs
# separately): schema, the folder it describes, the isolated-lab identity and the
# port this root plays. Returns problem lines.
function Get-VcBenchManifestProblems([string]$Root, [string]$Name, [int]$Port) {
    $path = Join-Path $Root 'paris-bench-root.json'
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) { return "$Name root is not a bench root (no paris-bench-root.json)." }
    try { $manifest = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json } catch { return "$Name bench manifest is not readable JSON." }
    if ($manifest.schema -ne 'iw7.bench-root/1') { "$Name bench manifest schema is '$($manifest.schema)', not iw7.bench-root/1." }
    if (![string]::Equals(([string]$manifest.root).TrimEnd('\', '/'), $Root, [StringComparison]::OrdinalIgnoreCase)) { "$Name bench manifest describes another folder ($($manifest.root))." }
    if (!$manifest.identity -or $manifest.identity.isolatedLab -ne $true) { "$Name bench was not made with -IsolatedLab." }
    elseif ([int]$manifest.identity.port -ne $Port) { "$Name bench port is $($manifest.identity.port), the harness uses $Port for it." }
}

function Resolve-VcCommand([string]$Command, [hashtable]$ClientNums) {
    $result = $Command
    foreach ($role in $ClientNums.Keys) { $result = $result.Replace('{' + $role + '}', [string]$ClientNums[$role]) }
    if ($result -match '[\r\n]' -or $result -match '\{[A-Z]\}') { throw "Unresolved or multi-line command: $result" }
    $result
}

# Writes a canonical 44-byte-header PCM16 mono WAV (the test component reads WAVs).
function Write-VcWav([string]$Path, [int]$Rate, [byte[]]$Pcm) {
    $header = [byte[]]::new(44)
    [Text.Encoding]::ASCII.GetBytes('RIFF').CopyTo($header, 0)
    [BitConverter]::GetBytes([uint32](36 + $Pcm.Length)).CopyTo($header, 4)
    [Text.Encoding]::ASCII.GetBytes('WAVEfmt ').CopyTo($header, 8)
    [BitConverter]::GetBytes([uint32]16).CopyTo($header, 16)
    [BitConverter]::GetBytes([uint16]1).CopyTo($header, 20)
    [BitConverter]::GetBytes([uint16]1).CopyTo($header, 22)
    [BitConverter]::GetBytes([uint32]$Rate).CopyTo($header, 24)
    [BitConverter]::GetBytes([uint32]($Rate * 2)).CopyTo($header, 28)
    [BitConverter]::GetBytes([uint16]2).CopyTo($header, 32)
    [BitConverter]::GetBytes([uint16]16).CopyTo($header, 34)
    [Text.Encoding]::ASCII.GetBytes('data').CopyTo($header, 36)
    [BitConverter]::GetBytes([uint32]$Pcm.Length).CopyTo($header, 40)
    $stream = [IO.File]::Open($Path, 'CreateNew', 'Write', 'None')
    try { $stream.Write($header, 0, 44); $stream.Write($Pcm, 0, $Pcm.Length) } finally { $stream.Dispose() }
}

# Returns the PCM bytes of a PCM16 mono WAV, walking its chunks.
function Read-VcWavPcm([string]$Path, [int]$ExpectedRate) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ([Text.Encoding]::ASCII.GetString($bytes, 0, 4) -ne 'RIFF' -or [Text.Encoding]::ASCII.GetString($bytes, 8, 4) -ne 'WAVE') { throw "Not a WAV: $Path" }
    $position = 12; $format = $null
    while ($position + 8 -le $bytes.Length) {
        $id = [Text.Encoding]::ASCII.GetString($bytes, $position, 4)
        $size = [BitConverter]::ToUInt32($bytes, $position + 4)
        if ($id -eq 'fmt ') {
            $format = @{ Tag = [BitConverter]::ToUInt16($bytes, $position + 8); Channels = [BitConverter]::ToUInt16($bytes, $position + 10)
                Rate = [BitConverter]::ToUInt32($bytes, $position + 12); Bits = [BitConverter]::ToUInt16($bytes, $position + 22) }
        } elseif ($id -eq 'data') {
            if (!$format -or $format.Tag -ne 1 -or $format.Channels -ne 1 -or $format.Bits -ne 16 -or $format.Rate -ne $ExpectedRate) { throw "Unexpected WAV format in $Path" }
            $length = [int][math]::Min($size, $bytes.Length - $position - 8)
            $pcm = [byte[]]::new($length); [Array]::Copy($bytes, $position + 8, $pcm, 0, $length)
            return $pcm
        }
        $position += 8 + $size + ($size -band 1)
    }
    throw "No data chunk in $Path"
}

# Synthesizes the phrase bank with Windows SAPI (System.Speech, in process) at the
# native capture rate, padded with 250 ms of digital silence on both sides.
function New-VcPhraseSet([string]$Directory, [int]$Rate, [object[]]$Phrases, [string]$Voice = '') {
    Add-Type -AssemblyName System.Speech
    [IO.Directory]::CreateDirectory($Directory) | Out-Null
    $format = [System.Speech.AudioFormat.SpeechAudioFormatInfo]::new($Rate, [System.Speech.AudioFormat.AudioBitsPerSample]::Sixteen, [System.Speech.AudioFormat.AudioChannel]::Mono)
    $pad = [byte[]]::new([int]($Rate / 4) * 2)
    $items = @(); $voiceName = ''
    foreach ($phrase in $Phrases) {
        $raw = Join-Path $Directory ($phrase.id + '.sapi.wav')
        $synth = [System.Speech.Synthesis.SpeechSynthesizer]::new()
        try {
            $installed = @($synth.GetInstalledVoices() | Where-Object { $_.Enabled } | ForEach-Object { $_.VoiceInfo })
            $chosen = if ($Voice) { $installed | Where-Object Name -EQ $Voice | Select-Object -First 1 }
                      else { $installed | Where-Object { $_.Culture.Name -eq 'en-US' } | Select-Object -First 1 }
            if (!$chosen) { throw 'No installed en-US SAPI voice (or the requested voice is missing).' }
            $synth.SelectVoice($chosen.Name); $voiceName = $chosen.Name
            $synth.Rate = 0
            $synth.SetOutputToWaveFile($raw, $format)
            $synth.Speak([string]$phrase.text)
            $synth.SetOutputToNull()
        } finally { $synth.Dispose() }
        $pcm = Read-VcWavPcm $raw $Rate
        Remove-Item -LiteralPath $raw
        $path = Join-Path $Directory ($phrase.id + '.wav')
        Write-VcWav $path $Rate ([byte[]]($pad + $pcm + $pad))
        $items += [pscustomobject]@{ id = $phrase.id; text = $phrase.text; wav = $path; rate = $Rate
            seconds = [math]::Round(($pcm.Length + 2 * $pad.Length) / 2.0 / $Rate, 3); sha256 = (Get-FileHash -LiteralPath $path).Hash }
    }
    [pscustomobject]@{ rate = $Rate; voice = $voiceName; generator = 'System.Speech'; phrases = $items }
}
