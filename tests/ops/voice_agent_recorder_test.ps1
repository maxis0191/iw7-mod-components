param([string]$WorkerPath)
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$tool=Join-Path $repo 'ops/voice-agent/Record-Receiver.ps1'
. "$repo/ops/voice-agent/Recording.Core.ps1"
$self=Get-Process -Id $PID
try { $image=$self.Path;$created=[uint64]$self.StartTime.ToFileTimeUtc() } finally { $self.Dispose() }
$root=Join-Path $repo ('runtime/voice-agent/recorder-dry-'+[guid]::NewGuid().ToString('N'))
$fixtureArguments=@{ProbePath=$image;ProcessId=$PID;CreationFileTime=$created;ExpectedImage=$image;ExpectedSHA256=(Get-FileHash -LiteralPath $image).Hash;OutputRoot=$root;Seconds=5;SyntheticFixture=$true;DryRun=$true}
$plan=& $tool @fixtureArguments
if ($plan.ProcessId -ne $PID -or $plan.CreationFileTime -ne $created -or $plan.MaximumPCMBytes -ne 960000 -or $plan.DeviceFallback -or $plan.MicrophoneCaptured -or $plan.Scope -notlike '*PROCESS_TREE*' -or (Test-Path -LiteralPath $root)) { throw 'DryRun identity/scope/bounds or no-mutation invariant failed.' }
function Assert-Refused($change) {
    $bad=$fixtureArguments.Clone();foreach ($key in $change.Keys) { $bad[$key]=$change[$key] }
    $refused=$false;try { & $tool @bad | Out-Null } catch { $refused=$true }
    if (!$refused -or (Test-Path -LiteralPath $root)) { throw 'Invalid recording identity/config accepted or output mutated.' }
}
Assert-Refused @{CreationFileTime=$created+1}
Assert-Refused @{ExpectedSHA256=('0'*64)}
Assert-Refused @{ExpectedImage=$image+'.foreign'}
Assert-Refused @{SyntheticFixture=$false}
Assert-Refused @{Seconds=61}
Assert-Refused @{OutputRoot=$repo}
$tokens=$null;$errors=$null
$null=[Management.Automation.Language.Parser]::ParseFile($tool,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw 'Recorder wrapper parse failed.' }
$unitRoot=Join-Path $repo ('runtime/voice-agent/recorder-wav-unit-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory $unitRoot | Out-Null
$unitPath=Join-Path $unitRoot 'fixture.wav'
$validWAV=[Convert]::FromHexString('524946462800000057415645666D7420100000000100020080BB000000EE020004001000646174610400000000000000')
[IO.File]::WriteAllBytes($unitPath,$validWAV)
$validation=Assert-IW7ReceiverWAV -Path $unitPath -Seconds 1
if ($validation.PCMBytes -ne 4 -or $validation.Frames -ne 1) { throw 'Independent standard PCM fixture parsed incorrectly.' }
foreach ($offset in @(0,4,8,16,20,22,24,28,32,34,36,40)) {
    $broken=[byte[]]$validWAV.Clone();$broken[$offset]=$broken[$offset] -bxor 1
    [IO.File]::WriteAllBytes($unitPath,$broken)
    $refused=$false;try { Assert-IW7ReceiverWAV -Path $unitPath -Seconds 1 | Out-Null } catch { $refused=$true }
    if (!$refused) { throw "Malformed PCM/RIFF field accepted at offset $offset." }
}
[IO.File]::WriteAllBytes($unitPath,$validWAV[0..46])
$refused=$false;try { Assert-IW7ReceiverWAV -Path $unitPath -Seconds 1 | Out-Null } catch { $refused=$true }
if (!$refused) { throw 'Truncated PCM payload accepted.' }
$overBound=[byte[]]::new(192048);[IO.File]::WriteAllBytes($unitPath,$overBound)
$refused=$false;try { Assert-IW7ReceiverWAV -Path $unitPath -Seconds 1 | Out-Null } catch { $refused=$true }
if (!$refused) { throw 'Requested-duration WAV bound exceeded.' }
'PASS independent WAV fixtures: valid one-frame PCM, malformed RIFF/format/channels/rate/average/alignment/bits/data fields, truncated payload and oversize refused.'
if ($WorkerPath) {
    $worker=[IO.Path]::GetFullPath($WorkerPath)
    $good=$fixtureArguments.Clone();$good.DryRun=$false;$good.ProbePath=$worker;$good.Seconds=1
    $good.OutputRoot=Join-Path $repo ('runtime/voice-agent/recorder-mock-valid-'+[guid]::NewGuid().ToString('N'))
    $completed=& $tool @good
    if (!$completed.Completed -or $completed.WAVValidation.PCMBytes -ne 4) { throw 'Actual non-audio worker valid WAV was not verified.' }
    $bad=$good.Clone();$bad.Seconds=2;$bad.OutputRoot=Join-Path $repo ('runtime/voice-agent/recorder-mock-truncated-'+[guid]::NewGuid().ToString('N'))
    $refused=$false;try { & $tool @bad | Out-Null } catch { $refused=$true }
    $manifest=Get-Content -LiteralPath (Join-Path $bad.OutputRoot 'manifest.local.json') -Raw | ConvertFrom-Json
    if (!$refused -or $manifest.Completed -or $manifest.ExitCode -ne 0 -or !$manifest.Error) { throw 'Exit0 malformed WAV incorrectly reported completed or failure evidence absent.' }
    $watchRoot=Join-Path $repo ('runtime/voice-agent/recorder-mock-timeout-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory $watchRoot | Out-Null
    $result=[IW7.VoiceAgent.OwnedProbe]::Run($worker,(Get-FileHash -LiteralPath $worker).Hash,[string[]]@('--sleep'),(Join-Path $watchRoot 'out.log'),(Join-Path $watchRoot 'error.log'),1)
    if (!$result.TimedOut -or $result.ElapsedMs -gt 2500 -or $result.PID -eq $PID -or (Get-Process -Id $result.PID -ErrorAction SilentlyContinue) -or !(Get-Process -Id $PID -ErrorAction SilentlyContinue)) { throw 'Owned-probe watchdog failed or affected its parent.' }
    'PASS non-audio workers: valid WAV finalized; exit0 truncated WAV refused with retained manifest; one-second watchdog stopped exact spawned probe and preserved parent.'
}
'PASS receiver recorder: real self PID/FILETIME/path/hash DryRun, foreign creation/hash/image rejected, fixture/size/output gates, no capture activation.'
