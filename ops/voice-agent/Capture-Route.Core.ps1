function Resolve-IW7VoiceCaptureRoute {
    param([Parameter(Mandatory)]$Inventory,[Parameter(Mandatory)][string]$EndpointId)
    # Pure validation of a caller-supplied snapshot. Runtime must enumerate again
    # immediately before factory invocation; this plan does not open a stream.
    $endpoints=@($Inventory.Endpoints | Where-Object Id -CEQ $EndpointId)
    if ($endpoints.Count -ne 1) { throw 'Capture endpoint identity is missing or ambiguous.' }
    $endpoint=$endpoints[0]
    if ($endpoint.Flow -cne 'capture' -or $endpoint.State -ne 1 -or $endpoint.Name -notmatch '^CABLE Output\s*\(') { throw 'One active explicit CABLE Output capture endpoint required.' }
    $guid=[guid]::Parse($endpoint.EndpointGuid)
    if ($guid -eq [guid]::Empty) { throw 'Default capture alias is forbidden.' }
    $matches=@($Inventory.DirectSoundCapture | Where-Object {
        !$_.DefaultAlias -and $_.Guid -and [guid]::Parse($_.Guid) -eq $guid
    })
    if ($matches.Count -ne 1) { throw 'CoreAudio GUID must match exactly one non-default DirectSound capture device.' }
    if ($matches[0].Description -notmatch '^CABLE Output\s*\(') { throw 'DirectSound endpoint is not the expected virtual cable.' }
    [pscustomobject]@{
        Kind='explicit_capture_route_plan';EndpointId=$endpoint.Id;EndpointGuid=$guid.ToString('B')
        DirectSoundDescription=$matches[0].Description;Factory='DirectSoundCaptureCreate (ordinal 6)'
        Callsite='0x140B7A095';OutputInterfaceSlot='0x145D5DC48';OriginalDeviceArgument='NULL'
        StartupArgument=('-paris-lab-capture-guid='+$guid.ToString('B'))
        NativeAdapterIntegrated=$false;CapturedMicrophone=$false;ChangedAudioDefaults=$false
        EvidenceBoundary='Fresh enumeration correlation only; no successful IW7 device/buffer/codec/render witness.'
    }
}
