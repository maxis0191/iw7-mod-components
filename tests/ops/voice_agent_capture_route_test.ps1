$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. "$repo/ops/voice-agent/Capture-Route.Core.ps1"
$guid='{12345678-1234-4321-abcd-123456789abc}'
function New-RouteInventory {
    [pscustomobject]@{
        Endpoints=@([pscustomobject]@{Id='explicit-test-id';Flow='capture';State=1;Name='CABLE Output (VB-Audio Virtual Cable)';EndpointGuid=$guid})
        DirectSoundCapture=@([pscustomobject]@{Guid=$guid;Description='CABLE Output (VB-Audio Virtual Cable)';DefaultAlias=$false})
    }
}
$inventory=New-RouteInventory
$result=Resolve-IW7VoiceCaptureRoute $inventory 'explicit-test-id'
if ($result.EndpointGuid -cne $guid -or $result.OriginalDeviceArgument -ne 'NULL' -or $result.NativeAdapterIntegrated -or $result.CapturedMicrophone -or $result.ChangedAudioDefaults) { throw 'Route plan changed boundary/defaults or selected wrong GUID.' }
function Refuse-Route($value) {
    $refused=$false;try { Resolve-IW7VoiceCaptureRoute $value 'explicit-test-id' | Out-Null } catch { $refused=$true }
    if (!$refused) { throw 'Invalid or ambiguous virtual capture selection accepted.' }
}
$bad=New-RouteInventory;$bad.Endpoints[0].State=4;Refuse-Route $bad
$bad=New-RouteInventory;$bad.Endpoints[0].Flow='render';Refuse-Route $bad
$bad=New-RouteInventory;$bad.Endpoints[0].Name='Personal microphone';Refuse-Route $bad
$bad=New-RouteInventory;$bad.Endpoints[0].EndpointGuid=[guid]::Empty.ToString();Refuse-Route $bad
$bad=New-RouteInventory;$bad.DirectSoundCapture[0].DefaultAlias=$true;Refuse-Route $bad
$bad=New-RouteInventory;$bad.DirectSoundCapture[0].Guid=[guid]::NewGuid().ToString();Refuse-Route $bad
$bad=New-RouteInventory;$bad.DirectSoundCapture+= $bad.DirectSoundCapture[0];Refuse-Route $bad
$bad=New-RouteInventory;$bad.Endpoints+= $bad.Endpoints[0];Refuse-Route $bad
'PASS capture route: exact CoreAudio/DirectSound GUID correlation; inactive/render/personal/default/mismatched/ambiguous selection refused. Pure snapshots only, no device activation.'
