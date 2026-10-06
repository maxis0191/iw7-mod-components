$ErrorActionPreference='Stop'
. "$PSScriptRoot/../../ops/voice-agent/PTT-Contract.Core.ps1"
$snapshot=[pscustomobject]@{ExactProcessIdentity=$true;OwnedSessionMatch=$true;IsolatedBuild=$true;ClientTestFlag=$true;IsolatedFlag=$true;MarkerVerified=$true;EngineProtected=$true;CgameInitialized=$true;NoInputCatchers=$true;VoiceEnabled=$false;VoiceAudioInitialized=$false;CaptureInterfacePresent=$false;NativeAudioProbeActive=$false;PTTActive=$false;Mode='CP';TestPort=27116;SafetyAgeMs=[long]50;TalkKey0=[int]0;TalkKey1=[int]0}
function Refuse($observation) { $refused=$false;try {New-IW7OrdinaryPTTPlan $observation | Out-Null}catch{$refused=$true};if(!$refused){throw 'Unowned/stale/audio PTT plan accepted.'} }
$plan=New-IW7OrdinaryPTTPlan $snapshot
if ($plan.PressBinding -ne 81 -or $plan.ReleaseBinding -ne 82 -or $plan.PhysicalKey -ne 222 -or !$plan.ReleaseOnAllExits -or $plan.ActionPerformed -or $plan.AudioActivated -or $plan.DvarChanged) { throw 'Plan must use ordinary bindings with owned release and no action.' }
$snapshot.Mode='MP';New-IW7OrdinaryPTTPlan $snapshot | Out-Null;$snapshot.Mode='CP'
foreach($name in @('ExactProcessIdentity','OwnedSessionMatch','IsolatedBuild','ClientTestFlag','IsolatedFlag','MarkerVerified','EngineProtected','CgameInitialized','NoInputCatchers')) {$snapshot.$name=$false;Refuse $snapshot;$snapshot.$name=$true}
foreach($name in @('VoiceEnabled','VoiceAudioInitialized','CaptureInterfacePresent','NativeAudioProbeActive','PTTActive')) {$snapshot.$name=$true;Refuse $snapshot;$snapshot.$name=$false}
$snapshot.SafetyAgeMs=[long]501;Refuse $snapshot;$snapshot.SafetyAgeMs=[long]50
$snapshot.TestPort=27016;Refuse $snapshot;$snapshot.TestPort=27116
$snapshot.TalkKey1=[int]86;Refuse $snapshot;$snapshot.TalkKey1=[int]0
$snapshot.VoiceEnabled=0;Refuse $snapshot;$snapshot.VoiceEnabled=$false
$snapshot.PSObject.Properties.Remove('CaptureInterfacePresent');Refuse $snapshot
'PASS ordinary CP/MP PTT dry contract; owner-held key, unknown audio state, enabled capture, wrong identity/UI/protection/port or stale safety refused; no dispatch/audio/dvar action.'
