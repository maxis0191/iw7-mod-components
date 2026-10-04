param([ValidateSet('A','B','C','D')][string]$Sender='A',[ValidateSet('VoiceProbe','VoiceReleasedProbe','VoiceCodecProbe')][string]$Probe='VoiceProbe',[ValidatePattern('^[a-zA-Z0-9_-]{1,64}$')][string]$Label='signal',[ValidateSet('Present','Absent')][string]$Expected='Present')
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$helper=Join-Path $repo 'ops/Voice-BaseTest.ps1'
function Read-Shared([string]$path) {
    $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    $reader=[IO.StreamReader]::new($stream)
    try {$reader.ReadToEnd()} finally {$reader.Dispose()}
}
function Snapshot {
    $state=Get-Content "$repo/runtime/voice-base-test.json" -Raw | ConvertFrom-Json
    $result=[ordered]@{}
    foreach($kind in @('Client','ClientB','ClientC','ClientD','Server')) {
        if (!$state.$kind) { continue }
        $text=Read-Shared $state.$kind.Stdout
        $line=[regex]::Matches($text,'(?m)^\[voice-relay\] version=2[^\r\n]*native_mask=\d+\r*\n') | Select-Object -Last 1
        $counts=[ordered]@{}
        if($line) { foreach($m in [regex]::Matches($line.Value,'(\w+)=(\d+)')) {$counts[$m.Groups[1].Value]=[long]$m.Groups[2].Value} }
        $native=[regex]::Matches($text,'(?m)^\[paris-voice-native\] mode=[^\r\n]*\r*\n') | Select-Object -Last 1
        if($native) { foreach($m in [regex]::Matches($native.Value,'(decoded|queued_bytes|encoded)=(\d+)')) {$counts['native_'+$m.Groups[1].Value]=[long]$m.Groups[2].Value} }
        $witness=[regex]::Matches($text,'(?m)^\[paris-voice-witness\][^\r\n]*\r*\n') | Select-Object -Last 1
        if($witness -and $witness.Value -match 'decoded_target_frames=(\d+)') {$counts['native_target_frames']=[long]$Matches[1]}
        $codec=[regex]::Matches($text,'(?m)^\[paris-voice-native\] Codec control=\d.*$') | Select-Object -Last 1
        if($codec) { foreach($m in [regex]::Matches($codec.Value,'(encoded_bytes_delta|tiny_frames_delta)=(\d+)')) {$counts[$m.Groups[1].Value]=[long]$m.Groups[2].Value} }
        $result[$kind]=$counts
    }
    return $result
}
$state=Get-Content "$repo/runtime/voice-base-test.json" -Raw | ConvertFrom-Json
$slots=@('A','B','C','D' | Where-Object { $kind=if($_ -eq 'A') {'Client'} else {'Client'+$_}; $state.$kind })
if($slots.Count -lt 2 -or $Sender -notin $slots) {throw 'Sender and at least one owned peer required.'}
foreach($slot in $slots) { & $helper -Action Verify -ClientSlot $slot }
$before=Snapshot
$output="$repo/runtime/voice-control-$Label-output.txt"
$errorOutput="$repo/runtime/voice-control-$Label-output.stderr.txt"
$observer=Start-Process "$repo/runtime/audio-output-probe.exe" -ArgumentList @('15','997') -WindowStyle Hidden -PassThru -RedirectStandardOutput $output -RedirectStandardError $errorOutput
Start-Sleep -Milliseconds 500
& $helper -Action $Probe -ClientSlot $Sender
if(!$observer.WaitForExit(20000)) {throw 'Output observer exceeded its bounded interval.'}
$observer.Refresh()
$exitCode=$observer.ExitCode
foreach($slot in $slots) { & $helper -Action Verify -ClientSlot $slot }
$after=Snapshot
$measurement=Read-Shared $output
$record=[ordered]@{Label=$Label;Sender=$Sender;ClientSlots=$slots;Map=$state.Map;SourceCommit=$state.SourceCommit;HelperCommit=(git -C $repo rev-parse HEAD);SHA256=$state.Build.SHA256;ObserverSHA256=(Get-FileHash "$repo/runtime/audio-output-probe.exe").Hash;Probe=$Probe;Expected=$Expected;ObserverExit=$exitCode;Output=$measurement.Trim();Before=$before;After=$after}
$record | ConvertTo-Json -Depth 7 | Set-Content "$repo/runtime/voice-control-$Label.json"
Write-Output $measurement.Trim()
if($exitCode -gt 1 -or ($Expected -eq 'Present' -and $exitCode -ne 0) -or ($Expected -eq 'Absent' -and $exitCode -ne 1)) {throw 'Output presence/absence expectation failed; preserve the measurement.'}
