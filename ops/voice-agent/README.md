# Private ordinary-audio bench

These tools prepare original synthetic speech and observe separate audio stages.
They are not a player package. Generated executables, WAVs, endpoint inventories,
manifests and logs belong under the repository's ignored `runtime/voice-agent/`
directory (greyed out in the source tree). Never commit those machine artifacts.

Current phase: passive preparation. VB-CABLE is not installed, no defaults or
volume have changed and no live microphone/output stream has been activated by
these tools. The full isolated game build passed on source `38e15c9`, with the
capture selector inactive; this does not prove explicit GUID initialization or
audio transport. Ordinary PTT/audio acceptance remains pending. The separate
SoundVolumeView execution was rejected by automatic review (`blocked by policy`);
do not reroute/retry it or install a driver before restitution is resolved.

From an isolated repository, PowerShell 7.4 and the existing VS2022 C++ toolchain:

```powershell
./ops/voice-agent/Build-Render.ps1 -OutputRoot "$PWD/runtime/voice-agent/render-tools-FRESH"
./tests/ops/voice_agent_render_test.ps1
```

Build-Render uses a fresh output directory, `/W4 /WX /RTC1` and lean Windows
macros. It compiles `render_wave_test.cpp`, runs only its pure RIFF/conversion
tests, compiles `render_wave.cpp`, and runs pure PowerShell tests. It never runs
the playback executable. `build.local.json`, `build.log` and
`powershell-test.log` retain hashes and actual results.

Inventory and file-only speech generation are described in
[`VOICE-AGENT-PLAN.md`](../../docs/VOICE-AGENT-PLAN.md). The render helper accepts
only PCM16 mono 16000 Hz, at most 15 seconds, with exact WAV SHA-256. The wrapper
and helper independently validate the RIFF/frame bound; both retain the source
file without write/delete sharing. Only an explicit active endpoint named exactly
`CABLE Input (VB-Audio Virtual Cable)` with correlated nonzero GUID is accepted.
No default query/fallback, SetVolume, SetMute or Listen path exists.

Future coordinated render command, after the endpoint and ordinary-capture route
are actually available (do not execute during the current passive phase):

```powershell
$tool = Get-Content ./runtime/voice-agent/render-tools-FRESH/build.local.json -Raw | ConvertFrom-Json
./ops/voice-agent/Play-Source.ps1 `
  -ProbePath "$PWD/runtime/voice-agent/render-tools-FRESH/render-wave.exe" `
  -ExpectedProbeSHA256 $tool.ExecutableSHA256 `
  -EndpointId 'EXACT-CABLE-INPUT-ENDPOINT-ID-FROM-FRESH-INVENTORY' `
  -SourceWAV "$PWD/runtime/voice-agent/speech-FRESH/sender-a.wav" `
  -OutputRoot "$PWD/runtime/voice-agent/render-FRESH" -SyntheticFixture -DryRun
# Removing -DryRun is a real audio operation; coordinate that runtime first.
```

The helper negotiates the actual shared WASAPI mix format (mono/stereo PCM16 or
float32, 8..192 kHz) and performs explicit linear interpolation from the original
16 kHz mono clip. The known-sample tests verify conversion and stereo duplication.
Unsupported formats fail. No codec, PCM hook or PTT/VAD override is involved.
The submitted source lasts <=15 seconds; its render loop has a 20-second deadline
and wrapper watchdog a 25-second total deadline. The watchdog retains the helper
image and original process handle and stops only that exact helper on failure.
Its stdout/stderr are created exclusively, bounded and retained. A fresh output
directory prevents reusing a prior completion log or overwriting unrelated files.

`manifest.local.json` reports completion only after exit0 and a unique fresh
completion record whose negotiated format/converted frame count matches the
source. This is render-buffer submission/drain evidence, not receiver audibility.
The stages requiring separate witnesses are OS capture, encoding, transport,
decoding and receiver render. Distinct phrases A-to-B then B-to-A can later test
PTT/reconnect, but synthetic speech never counts as a human conversation.

Pure test coverage includes malformed/truncated RIFF, PCM format/frame/duration
bounds, known-sample conversion, personal/inactive/ambiguous render endpoints,
missing/stale/duplicate completion records, wrong converted frames and fallback
markers. The existing `voice_agent_recorder_test.ps1 -WorkerPath ...` exercises the
shared exact owned-process watchdog with a non-audio worker; the renderer's live
WASAPI behavior is deliberately not claimed by these tests.
