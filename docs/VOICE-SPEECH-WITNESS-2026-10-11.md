# Protected two-client speech witness - 2026-10-11

Issue [4](https://github.com/maxis0191/iw7-paris-server/issues/4) stays open.
This continues [PR126's recorder/PTT recovery](VOICE-E2E-RECOVERY.md) after
the owner closes their game and authorizes the actual two-client tests.

## Laboratory and scope

Reuse the complete retained agent-debugger dedicated stock. A uses the base
game client; B needs an independent identity/profile because both clients run
simultaneously. Its reviewed retail files are read-only NTFS hardlinks, not a
second full game copy. The dedicated uses UDP 27116, A 27117 and B 27118. Main's
UDP 27016, native binary, scripts, settings and bank are preserved.

The reviewed runner admits one audio-enabled 20/20 GiB runtime group. Both
clients require fresh actual engine godmode, inactivity=0 and sv_cheats=0.
There is no live debugger. The isolated executable includes the debugger
component for build checks, but its activation flag is absent.

The source is the pinned four-second PCM16 mono16kHz fixture saying
`Alpha seven. Blue lantern.` (SHA256
`c2d4b48b6b9a1b7e267e8bb90e492bb336e35bd11c952a8421184a5f86e1289b`).
B's injected capture source remains silence. Software input enters the actual
IDirectSoundCapture interface, then ordinary native PTT, codec, server relay
and receiver playback. It does not exercise a physical microphone or two
independent computers/WAN paths.

The recorder uses Windows process-tree WASAPI for the original B kernel
process, pinned by PID, creation time, kernel image and immutable executable
hash. Its original child handle, final exit, producer EOF, WAV format/hash and
cleanup are checked. No default audio endpoint fallback is allowed.

## Failures and corrections retained in history

1. The full build's checkpoint guard rejected the pinned Windows newline
   form. `a8c617c` accepts only exact known canonical bytes after CRLF-to-LF
   conversion and one missing terminal newline. Extra whitespace, bare CR,
   extra lines and unknown source still fail. The24-case regression passes.
2. The first actual pair protected A, then StrictMode found an uninitialized
   PairNonce property. `c8da13c` initializes it in the real context constructor;
   the real file-publication regression and context tests pass.
3. B's Windows console companion made the recorder refuse its process tree.
   `3c225f2` retains and verifies the one direct System32 conhost child and
   reports the process-tree scope. Other, nested, changed or disappeared
   descendants still fail. Real process-tree recordings subsequently complete.
4. Ownership audits made a cached server sample falsely stale. `e6cad2f`
   completes those audits before reading the current publications. A regression
   with two 300 ms audits passes without increasing the 500 ms freshness limit.
5. Descriptor preflight consumed the recorder's one-shot readiness window.
   `42c7484` performs preflight before recorder start and reads the latest native
   record by exact line prefix. Regressions retain the original readiness tick
   through a slow preflight and reject embedded lookalike prefixes.
6. The first complete voice path began the source clock about 1.5 seconds before
   actual PTT down, potentially clipping the phrase prefix. `1bd9759` keeps
   capture ARM silent and starts source sample 0 only after the original native
   key dispatch and a fresh actual talk/protection snapshot. A real COM-buffer
   regression drains 1.5 seconds of silence, then verifies the complete source;
   stale/future source starts fail. Production microphone behavior is unchanged.
7. Full ownership polling after recorder resume could age its one-shot Ready
   past 500 ms. `9037fb1` adds an ARM-only boundary using the original A/B/server
   kernel handles, retained immutable executable streams/FileIds, the locked
   current 20/20 GiB lease and fresh native STATE/SAMPLE. Full audits remain before
   recorder start and ordinary PTT. `8ac4ba0` retains both original server sample
   ticks and bounds publication by their deadlines and the original Ready tick.
   No timestamp is renewed and no freshness limit is relaxed. Actual Windows
   handle/image/exit tests and slow-audit/stale-ready/protection regressions pass.

`3bcd2d1` supports B-to-A with original role slots preserved and independent
PTT/source/counter/recorder bindings. `387236b` provides an explicit restored
quiet-dialogue/music measurement option, default off; effects/master/microphone
devices remain unchanged. Neither option itself establishes intelligibility.
The first quiet attempt still contains NPC dialogue: launch options alone do
not certify the final mix. `871b87c` replaces them with a private isolated flag;
after actual join/UI/protection, the engine main thread sets only those three
float dvars to zero and publishes their observed state. Providers require fresh
original PID/nonce/generation AUDIO proof, bound to the same 500 ms ARM deadline.
Profiles are restored after process exit. This verifies the dvars, not that all
NPC sound follows those categories; the final WAV is the acoustic authority.

A later recorder refusal is retained separately: a protected Windows process
predated B by several hours but its old parent PID matched B's reused PID.
The conservative tree guard refused before ARM. No unrelated process was
terminated and no ancestry exception was added; a fresh pair is used.

The source-clock rebuild first refused six stale generated capture overlays.
Each matched the previous successful build manifest before file-level retirement
into a verified ignored backup. Unknown-source guards remain enabled.

## Actual recordings and independent word checks

The pre-ARM baseline recorder completes with 11.95 seconds of PCM16 stereo 48 kHz,
SHA256 `FCA4792656AAD5328A915FBC2A9998142E8EC312E835D57357B643F5F94089D3`.
No speech was sent. Offline dictation recognizes game dialogue, not the target
phrase. This prevents treating game audio alone as a successful voice test.

Before source-clock synchronization, an ordinary four-second PTT cycle and
capture/relay/playback path complete. The receiver WAV is 11.98 seconds, SHA256
`9446311BDA6793DFB2F79AB36322E90D850C22E88A1C92728D01759EB945B266`.
Observed counters are 205 encoded/sent/relayed frames, 175 accepted native playback
calls and 21714 nonzero capture-lock bytes. These counters do not prove words or
establish that their sampling windows are identical. Envelope correlation 0.574
is only a diagnostic heuristic. Offline dictation does not recover the complete
target phrase on either channel; intelligibility is not accepted for that run.

The synchronized A-to-B recording completes with 11.97 seconds, SHA256
`592242F720968AE75FB214F5203C3BFB30BFF8F1C63046E622C5758959E89623`.
Source start follows actual native PTT. Counters report 205 encoded/sent/relayed
frames and 201 playback calls; envelope correlation rises to 0.809. Independent
dictation passes the source/silence controls but still does not recover all four
words in either receiver channel amid game dialogue. This run is also not
accepted as intelligible speech. A subsequent quiet attempt fails before ARM
when full ownership polling consumes the recorder Ready window; no speech is
sent in that failed attempt. Its exact Ready timestamp and cleanup are retained.

The first completed launch-only quiet recording is 11.98 seconds, SHA256
`A97788A45B04A8BA4B9B7D7FE7DC0B14B1E09A630E21CF6292AD2E8F6D8CA8F0`.
The pair/restoration pass, with 204 encoded/sent/relayed and 202 playback calls,
but SAPI again does not recover all four words. Independent unprompted CPU
whisper.cpp finds `Blue Lantern` on the left amid NPC dialogue; its silence
control falsely emits `You`, invalidating word acceptance for that recognition
run. All negative raw results are retained; no recognizer is supplied the target
phrase as a prompt. The verified post-profile quiet measurement follows.

With both clients' actual post-profile dvars verified at zero, another A-to-B
recording completes 11.97 seconds, SHA256
`6A5A68FE09C7448B00A0F72CF7A842B75ACFB19933B9C9CCD1A6EB7AA1D6635D`.
The WAV still contains recognized intro dialogue and the complete target words
are not recovered by SAPI, despite valid source/silence controls. Thus these
three dvars are insufficient to prove acoustic isolation. `6fca8f1` adds an
explicit bounded pre-recording settle wait, continually verifying both original
clients' protection/ownership/reservation. It does not extend the 29-second
witness or 500 ms ARM windows. The first 90-second attempt is refused before ARM:
client A's 120-second preparation scope starts before client B finishes loading,
so the combined preparation and settling exhausts it. No speech is sent in that
attempt, and both clients, profiles, stock and reservation are restored.
`82e12ca` limits the optional settling to 60 seconds, retaining the existing
preparation, witness and freshness limits. The next measurement uses 60 seconds
before recorder readiness and source/PTT activation.

That 60-second measurement completes and restores both clients and the candidate.
The authentic receiver WAV is 11.97 seconds, SHA256
`BA3E5DA5681F7DC9E77FB127CB28A95224DFCD965A68257D15F502AE32F94CA5`.
Ordinary PTT and the post-PTT source clock are observed; the actual capture reports
21714 nonzero lock bytes. Counter deltas have separate windows and cannot establish
a loss ratio. With valid SAPI source/silence controls, the receiver is recognized
as `FFO has left the FF FF` / `FFFL that if the lead of the FA`, not the four target
words. CPU Whisper outputs `Alpha-Shivok, Blue-Lendering.` on the left, but its
silence control again hallucinates `You`; its results remain diagnostic only.
Intro settling therefore removes one confounder without proving intelligibility.

## Actual received PCM isolation

`9da6368` adds an opt-in receiver PCM witness only to the isolated fake-capture
laboratory. The ordinary transport still validates roster, speaker incarnation,
mute and frame limits. The witness forwards the original native incoming call,
copies the actual successful decoder output, then records only the prefix the
original enqueue accepted. It never copies the sender fixture into receiver output.

Reverse engineering of retained retail sections establishes synchronous decode
and enqueue before incoming returns. Exact entry, callsite, tail jump and buffer
layout bytes guard this assumption before hooks install. The real DirectSound
buffer supplies GetFormat and GetFrequency, rather than assuming a sample rate.
Decoded and submitted streams independently have a 256 KiB bound and a 15-second
scope, tied to original receiver PID/nonce/generation, shared recorder challenge
and one exact remote speaker incarnation. Fresh protection, same engine thread,
bounded time and immutable source/process admission remain required. Loss of scope
invalidates the witness before early return; neither original call is suppressed.

Its receiver-only mailbox uses the receiver's own silence source hash. This does
not arm receiver capture. Decoded/submitted WAVs and the native receipt must close
before the exact PCM_CLOSED acknowledgement; PowerShell verifies scope, actual WAV
headers, hashes and NTFS identities. Final WASAPI recording remains independent.
The PCM witness does not itself establish playback or intelligibility.

The first build exposes a missing seventh file in the synthetic copy regression;
`bb6ac9a` corrects that fixture. The full compiler then finds a DWORD/unsigned
template mismatch in frequency min/max; `c36213e` normalizes the observed value.
Portable PCM scope/identity/freshness/truncation tests and actual NTFS receipt/WAV
boundary tests pass. A subsequent complete build links successfully with SHA256
`AA2E566246031C8441D19CBB166FB05FDC6F5847D1F73C66398566ABEB016FF7`,
pinned Aurora `77e6d4d24e918ee363b3feee3735c3b889dff7d7`.

Passive getter-only telemetry records the codec state on the first actual encoded
speech frame. Retail narrowband maps quality 0..10 to modes
`1,8,2,3,3,4,4,5,5,6,7`; mode 8 represents quality 1. The old manually controlled
quality3/cache3/mode8 tuple is historical and cannot describe this run. No codec
setting is changed by this measurement.

### Run 13: codec and queue separated from final playback

The restored run records 205 actual remote frames: 65,600 decoded bytes and
65,600 accepted enqueue bytes, with no truncated frames. Both native WAVs have
SHA256 `A04099E4DC09B71A858868CA6805F72E719686BCD4EA554F2F56E10449DE6EBC`.
Actual DirectSound format and observed frequency are 8192 Hz. Codec quality,
cached quality and configured mode are all 3; the measurement writes no controls.

Ordinary SAPI passes source/silence controls but misrecognizes the native and
final audio. A second independent pipeline uses pinned CPU whisper.cpp b5454,
base.en and official Silero VAD v6.2.0 with its default 0.5 threshold. Without
VAD, earlier silence produces a spurious word, so that pipeline cannot establish
intelligibility. With default VAD, source recognizes `Alpha 7, Blue Lantern.`
and silence recognizes no words before any receiver analysis is admitted.
Raw results are frozen before post-hoc normalization of numeric 7 to seven;
no prompt, reference grammar or expected vocabulary reaches the recognizer.

The actual native decoded and submitted files both recognize
`Alpha 7, Blue Lantern`. Final receiver left recognizes
`Alpha 7. We're my nerd.` and right recognizes `How do you ever do that?`.
This supports intelligible decoder and queue input for this controlled case,
while final playback remains unproven. It does not prove that the DirectSound
buffer played or that a player heard the phrase. All pair processes close,
profiles/stock/bank restore and the exclusive resource lease releases before ASR.

Retail incoming only decodes/enqueues; a separate engine manager starts and
maintains DirectSound playback. `317d467` adds getter-only surface diagnostics
(playing status, volume, pan, buffer size and play/write cursors) after original
incoming returns. It changes no playback control. A separately opt-in quality10
comparison changes only the admitted source encoder's mode and requires verified
restoration before source cancellation completes. Both remain laboratory-only.
The full surface build links successfully with SHA256
`9A5107C7A2628B4D0A5D5A62F00773012C820EB0CCA5FDFF2BB5B84B0E599C9B`.

Run 14 cannot establish a quality comparison: the native PTT binding refuses
source start before any CODEC_QUALITY event, and the parent then rejects missing
fresh STATE. Received PCM has zero frames; the recording contains no admitted
phrase. The codec was not observed to change. Cleanup completes with Restored=true
and no CleanupError. Subsequent trials use the ordinary codec.

Independent waveform comparison of run13's pinned submitted-PCM conversion with
the actual pinned final left/right conversions finds the same 1791.5625 ms offset
in both channels. Correlations are 0.638/0.528 and least-squares gains 0.995/1.009.
Speech RMS is 1903; residual mix RMS is 2286/3092. Voiced 200 ms windows reach
0.96/0.97 left and 0.88 right. This locates real speech in final playback but
does not establish word recognition. The environmental mix is louder than speech.

Retail registration at 0x140C997E0 identifies snd_volume as the game's float0..1
master volume. The engine gain path at 0x140CA1D2D multiplies by its current value;
UI preferences can restore it later at 0x1409C2860. The examined voice DirectSound
incoming/queue/tick paths do not reference this dvar. `273a51b` maintains and
verifies snd_volume=0 alongside the three prior category volumes on the admitted
protected laboratory main thread. The actual process closes and original player
profile restores afterwards. This is a test-only mix change; preserving received
voice still requires actual surface and final recording evidence.

Run15 uses source `273a51b`, full executable SHA256
`9AA6BD87F87920F64EF6A513D97E939E4DB032E6D2F908F925423369399CAC9C`.
Native suites and full Release link pass. Actual PTT sends/relays/dispatches207
frames and final process-loopback WAV closes successfully (11.97 seconds,
SHA256 `24027BE15B311644444EC5DEBC62E602E37D83D1CC4CC41B740DEF217CCAD42D`).
The additional PCM observer invalidates before source begins: the aggregate
binding readiness briefly becomes false, then recovers. Its failed zero-frame
receipt cannot prove any decoder, queue or surface measurement for this run.
The wrapper still forwards ordinary incoming; it does not suppress207 actual
playback calls. Parent rejects missing successful PCM closure, then restores
all files/processes with no CleanupError. This is a failed observer trial.

After original restoration, the independent final-WAV recognizers pass their
source/silence controls but still hear long NPC narration interspersed with parts
of the source phrase. Four verified zero-volume dvars do not establish a quiet
rendered mix. `test_readiness` requires native registered/voiceRegistered/xuid
for both peers; retail state can clear these between250ms reconciliations.
Current STATE logs publish aggregate `voice_test_binding::current`, so the
specific transient missing bit is not proven by this trace.

Retained retail references establish a separate Bink audio path using
`bink2w64.dll!BinkSetSpeakerVolumes`. The wrapper at0x140DD5D60 receives the live
movie handle, five-track array and float gain. Current movie handle is
`*[0x1483D4560]`, not the earlier investigated4558 address; tracks are1483D4BEC.
Movie mute/pause setters have extra state effects and are not suitable blind
calls. A scoped wrapper experiment must preserve handle/tracks and native flags,
prove current owner/lifetime before applying/restoring gain, and retain actual
final-WAV verification. This remains an isolation hypothesis until measured.

The first guarded wrapper candidate (`50f955d`, executable SHA256
`D299A92A9DCA0899CFD011BCDAD15788C7A02C34ACC3DE469F58E0E39DF79475`)
passes full native suites and Release link. Run16 ends before recorder readiness
with an unexpected process descendant refusal, no ARM/source and no WAV.
Restored=true, CleanupError=null. Its observed movie owner is a cinematic worker,
distinct from main; after the60-second settle the published movie is absent.
It does not prove suppression or received speech. The recorder now preserves
refused descendant identities for the next trial, keeping its scope guard.

The lifetime audit finds both BinkClose calls zero the global after freeing it,
under retail critical section31. A main-thread pointer check alone cannot protect
that window. The correction (`29ed2e1`) intercepts only the verified cinematic
worker manager call between Enter/Leave31. Main publishes a deadline from the
original protected sample and reads a fresh worker publication; all Bink calls
remain on the observed worker under retail31, then movie_mutex. The actual
opening increments the lifetime epoch, including reused addresses. Expiry or
admission withdrawal restores the current retail requested gain in normal worker
operation. pre_destroy only disables admission, because ExitProcess may follow
engine teardown. No engine mute/pause flags are modified. The initial main-owner
restriction and its correction remain in Git history. Final audio evidence is
still required to establish that the game narration follows this path.

Run17 uses source29ed2e1, executable SHA256
`17D9086838129969EFAA451523B6825211C2469C5DB8BAD7583F761D0179840E`,
full native suites/Release link and source checks passing. The recorder verifies
one original System32 console companion and closes its real11.97-second WAV
with no discontinuities/timestamp errors; SHA256
`6030D01070BA0E3B08A93CEDBD13610B065DE581FE1CC2FA15484A79EAB0E489`.
The receiver's successful PCM receipt contains206 frames/65920bytes, decoded and
submitted WAV SHA256
`08C6DA4658FF1BF656E6E46EB234B2A31F689D1D5DA865398C54CFF3634D650F`.
Actual8192Hz frequency,206 valid surface samples,185 playing samples, volume0dB,
pan0,51200-byte buffer and advancing cursors have no surface failures/truncation.
Incoming original calls are forwarded and the receiver does not read the phrase
source. Counters are sampled independently:196 encoded/sent,206 relayed/native
calls,282 diagnostic packets. These are not interchangeable frame totals.
The worker reports no active movie during the witness, so this run cannot prove
active movie suppression. Complete original restoration succeeds with no
CleanupError. Independent unprompted Whisper/default VAD passes source/silence
controls and reads "Alpha seven, blue lantern." from both actual native WAVs.
The final left/right transcripts remain incomplete. Waveform matching finds
1781.5625ms in both channels, gain0.991/0.992, correlations0.541/0.647 and
residual RMS2898/2198 versus native1881. Real received speech is present in final
output, with a louder residual mix. This is not full final-word acceptance.

Review identifies an observation-age boundary in29ed2e1: main must publish the
original cinematic worker timestamp rather than refreshing it when logging
AUDIO. The parent already carries the minimum native query/audio tick to ARM;
preserving the worker tick there prevents granting another500ms to an already
aged observation. `589bccb` carries that original clock; `a4b9cc6` also revalidates
quiet, presence/mute and the timestamp under the same publication lock, avoiding
a worker update between measurement and logging. `1a609a3` includes the verified
retail effects category gain in the scoped mix. Its actual voice DirectSound
surface and final-output words still require the next trial. Run17 remains
recording evidence, with the earlier clock publication limitation retained.

Word analysis uses the retained offline SAPI tool with the current merged
resource scheduler, built and staged only in ignored runtime. FFmpeg 8.1.2
derives independent left/right PCM16 mono16kHz files under an Analysis 2/3 GiB
lease. Original WAV identity/hash, retained converter handles, exit/EOF and
conversion receipts are preserved. A fresh isolated worker uses the ordinary
en-US dictation grammar with adaptation disabled; no reference words, microphone
or network input enter recognition. The source control must recognize all four
words and the silence control must recognize none before receiver analysis.
Both controls pass for the baseline and first speech recording. References are
compared only after raw recognition results are frozen and hashed.

## Full build and remaining acceptance

The fresh complete game build at code head
`1bd975914490316c723759338f305824c0f090fb`, pinned Aurora
`77e6d4d24e918ee363b3feee3735c3b889dff7d7`, has executable SHA256
`FAC0C1E4894A1BBC4ACE3DA69F17FEA46EAD24E18ABF6B4B1ADBCE034C7933A2`.
Its native suites and full Release link pass. Source checks pass, including
supplied-original hashes, PowerShell/GSC parsing and the 17-script/910-identifier
catalog. Generated overlays, game assets, binaries, raw logs, process identities,
nonces, audio, bank data and backups remain outside Git.

The subsequent full post-profile quiet build uses source head
`871b87c646074bb77c7b42d22861e84613f2863e`, executable SHA256
`E95571427D67BDB5E5A2ACF936DB993F98A57D1C0A1271B62089C1E8A5FCC249`.
All native suites and the Release link pass again; source checks still verify
the unchanged17-script catalog. No live debugger activation is used.

The synchronized actual speech recording is being evaluated. Reverse direction,
released-PTT negative controls, mute/reconnect/map behavior, real microphones,
remote PCs, Multiplayer and ordinary player compatibility remain unaccepted.
No build is promoted to Main and no accepted voice tag is justified.
