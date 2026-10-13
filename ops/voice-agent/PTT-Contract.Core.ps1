function New-IW7OrdinaryPTTPlan {
    param([Parameter(Mandatory)]$Snapshot,[ValidateRange(200,255)][int]$OwnedPhysicalKey=222)
    # Pure plan. Never dispatches, changes a dvar, activates audio or opens a device.
    $required=@('ExactProcessIdentity','OwnedSessionMatch','IsolatedBuild','ClientTestFlag','IsolatedFlag','MarkerVerified','EngineProtected','CgameInitialized','NoInputCatchers','VoiceEnabled','VoiceAudioInitialized','CaptureInterfacePresent','NativeAudioProbeActive','PTTActive')
    foreach ($name in $required) {
        if (!$Snapshot.PSObject.Properties[$name] -or $Snapshot.$name -isnot [bool]) { throw "Missing typed native observation: $name." }
    }
    foreach ($name in @('ExactProcessIdentity','OwnedSessionMatch','IsolatedBuild','ClientTestFlag','IsolatedFlag','MarkerVerified','EngineProtected','CgameInitialized','NoInputCatchers')) {
        if (!$Snapshot.$name) { throw "Ordinary PTT test refused: $name." }
    }
    foreach ($name in @('VoiceEnabled','VoiceAudioInitialized','CaptureInterfacePresent','NativeAudioProbeActive','PTTActive')) {
        if ($Snapshot.$name) { throw "State-only PTT bench requires absent audio/owner input: $name." }
    }
    if ($Snapshot.Mode -cnotin @('CP','MP') -or $Snapshot.TestPort -isnot [int] -or $Snapshot.TestPort -lt 27100 -or $Snapshot.TestPort -gt 27999 -or
        $Snapshot.SafetyAgeMs -isnot [long] -or $Snapshot.SafetyAgeMs -lt 0 -or $Snapshot.SafetyAgeMs -gt 500 -or
        $Snapshot.TalkKey0 -isnot [int] -or $Snapshot.TalkKey1 -isnot [int] -or $Snapshot.TalkKey0 -ne 0 -or $Snapshot.TalkKey1 -ne 0) { throw 'Fresh protected CP/MP test port and vacant exact talk key slots required.' }
    [pscustomobject]@{
        Kind='ordinary_ptt_state_only_plan';Mode=$Snapshot.Mode;Entry='0x14032A3B0';PressBinding=81;ReleaseBinding=82
        ABI='ECX local_client=0, EDX binding, R8D exact_owned_physical_key, R9D fresh engine timestamp; early talk branch uses global timestamp'
        PhysicalKey=$OwnedPhysicalKey;LocalClient=0;PressMilliseconds=200;ReleaseOnAllExits=$true
        Getter='0x14036FE40';KeyBase='0x141FE5B4C';ActiveByte='0x141FE5B5C';LocalStride='0x460'
        Evidence=@('Fresh typed baseline getter0 and two empty key slots','Same PID/session/seq-step press ACK plus getter1 within200ms','Matching owned-key release ACK plus getter0; no foreign key release')
        ContinuousGuards='Exact process/session, native500ms protection, active game/UI, audio still absent; stop on any lost/unknown observation'
        ActionPerformed=$false;AudioActivated=$false;PCMInjected=$false;DvarChanged=$false
        RuntimeDriverIntegrated=$false
    }
}
