"""Offline tests of ops/voice-certify/analyze_voice.py. No game is involved.

Phrases come from the orchestrator's own generator (New-VcPhraseSet, Windows SAPI
through PowerShell) at native-like rates; "received" audio is simulated by
narrowband filtering, an 8 kHz round trip, mu-law quantization, noise and VAD
gating. Silence and wrong-phrase controls must fail. ASR tests skip when
faster-whisper (or its cached model) is unavailable.

Run: python -I tests/voice-certify/test_analyze_voice.py -v
"""
import json
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
HARNESS = REPO / 'ops' / 'voice-certify'
sys.path.insert(0, str(HARNESS))
import analyze_voice as av  # noqa: E402  (also re-adds the user site for numpy)
import numpy as np  # noqa: E402

BANK = json.loads((HARNESS / 'phrases.json').read_text(encoding='utf-8'))['phrases']
TEXT = {p['id']: p['text'] for p in BANK}
RATES = (8000, 16000)
USED = ('P01', 'P02', 'P03')
_ASR = None


def recognizer():
    global _ASR
    if _ASR is None:
        _ASR = av.Recognizer('small')
    return _ASR


def write_wav(path, rate, samples, declared=None):
    data = np.asarray(samples, dtype='<i2').tobytes()
    size = len(data) if declared is None else declared
    header = b'RIFF' + struct.pack('<I', 36 + size) + b'WAVEfmt ' + struct.pack('<IHHIIHH', 16, 1, 1, rate, rate * 2, 2, 16)
    Path(path).write_bytes(header + b'data' + struct.pack('<I', size) + data)


def synthesize(directory, rate, ids):
    """Runs the orchestrator's SAPI generator; returns {id: path}."""
    shell = shutil.which('pwsh') or shutil.which('powershell')
    if not shell:
        raise unittest.SkipTest('PowerShell not available for SAPI')
    command = (". '{core}'; $bank = @((Get-Content -LiteralPath '{bank}' -Raw | ConvertFrom-Json).phrases | "
               "Where-Object {{ $_.id -in @({ids}) }}); New-VcPhraseSet '{out}' {rate} $bank | ConvertTo-Json -Depth 4").format(
        core=HARNESS / 'VoiceCertify.Core.ps1', bank=HARNESS / 'phrases.json',
        ids=','.join("'%s'" % i for i in ids), out=directory, rate=rate)
    run = subprocess.run([shell, '-NoProfile', '-NonInteractive', '-Command', command], capture_output=True, text=True, timeout=180)
    if run.returncode != 0:
        raise unittest.SkipTest('SAPI phrase generation failed: ' + (run.stderr or run.stdout)[-400:])
    manifest = json.loads(run.stdout)
    assert manifest['rate'] == rate
    return {p['id']: Path(p['wav']) for p in manifest['phrases']}


# ---- simulated transmission

def narrowband(x, rate):
    spectrum = np.fft.rfft(np.asarray(x, dtype=np.float64))
    freqs = np.fft.rfftfreq(len(x), 1.0 / rate)
    spectrum[(freqs < 300) | (freqs > 3400)] = 0
    return np.fft.irfft(spectrum, len(x))


def mulaw(x):
    y = np.clip(np.asarray(x, dtype=np.float64) / 32768.0, -1, 1)
    q = np.round(np.sign(y) * np.log1p(255 * np.abs(y)) / np.log1p(255) * 127) / 127
    return np.sign(q) * ((1 + 255) ** np.abs(q) - 1) / 255 * 32768.0


def noise(x, snr_db, seed=7):
    x = np.asarray(x, dtype=np.float64)
    speech = x[np.abs(x) > 50]
    rms = np.sqrt(np.mean(speech ** 2)) if len(speech) else 1000.0
    return x + np.random.default_rng(seed).normal(0, rms / (10 ** (snr_db / 20.0)), len(x))


def vad_gate(x, rate, threshold=200):
    """Keeps only 20 ms frames whose peak exceeds the threshold, as a VAD-gated stream would."""
    hop = int(rate * 0.02)
    frames = [x[i:i + hop] for i in range(0, len(x) - hop + 1, hop)]
    kept = [f for f in frames if np.max(np.abs(f)) > threshold]
    return np.concatenate(kept) if kept else np.zeros(0)


def received(source):
    """Source phrase as a remote talker's decoded voice might look: the sender's
    VAD drops the pauses, the codec band-limits and quantizes, noise is added."""
    x = vad_gate(np.asarray(source.samples, dtype=np.float64), source.rate)
    x = narrowband(x, source.rate)
    x = av.resample(av.resample(x, source.rate, 8000), 8000, source.rate)
    x = noise(mulaw(x), 25)
    return av.Audio(source.rate, np.clip(np.round(x), -32768, 32767).astype(np.int16))


def window(expect='heard', phrase='P01', inject=True, played=True, encoded=12, recv=3):
    return dict(id='T', mode='CP', expect=expect, inject=inject, talker='A', listener='B',
                phrase=dict(id=phrase, text=TEXT[phrase], wav='unused') if phrase else None,
                play_started=played, play_ended=played, talker_encoded_events=encoded, listener_recv_events=recv)


class NoAsr:
    available = False
    reason = 'disabled in this test'
    model_name = None


class FakeAsr:
    """Stands in for faster-whisper to exercise the verdict logic around ASR."""
    available = True
    reason = ''
    model_name = 'fake'

    def __init__(self, text):
        self.text = text

    def transcribe(self, audio):
        return self.text


# ---- tests

class WavReaderTests(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp(prefix='vc-wav-'))

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def test_stale_zero_size_header_reads_every_sample(self):
        write_wav(self.dir / 'a.wav', 8000, np.arange(1000), declared=0)
        self.assertEqual(len(av.read_wav(self.dir / 'a.wav').samples), 1000)

    def test_samples_appended_after_last_header_update_are_read(self):
        write_wav(self.dir / 'a.wav', 8000, np.arange(1000), declared=500)
        self.assertEqual(len(av.read_wav(self.dir / 'a.wav').samples), 1000)

    def test_byte_window_is_clamped_and_sample_aligned(self):
        write_wav(self.dir / 'a.wav', 8000, np.arange(1000))
        audio = av.read_wav(self.dir / 'a.wav', 44 + 200, 44 + 600)
        self.assertEqual(audio.samples.tolist(), list(range(100, 300)))
        self.assertEqual(av.read_wav(self.dir / 'a.wav', 0, 44 + 21).samples.tolist(), list(range(10)))
        self.assertEqual(len(av.read_wav(self.dir / 'a.wav', 44 + 2000, 99999).samples), 0)

    def test_rejects_non_pcm16_mono(self):
        header = b'RIFF' + struct.pack('<I', 36) + b'WAVEfmt ' + struct.pack('<IHHIIHH', 16, 1, 2, 8000, 32000, 4, 16)
        (self.dir / 'b.wav').write_bytes(header + b'data' + struct.pack('<I', 0))
        with self.assertRaises(ValueError):
            av.read_wav(self.dir / 'b.wav')


class WordTests(unittest.TestCase):
    def test_word_recall_ignores_case_punctuation_and_plurals(self):
        self.assertEqual(av.word_recall('copper lantern burning brightly', 'Copper lanterns, burning brightly.'), 1.0)
        self.assertEqual(av.word_recall('frozen castle behind green hills', 'a frozen castle behind the green hill'), 1.0)
        self.assertEqual(av.word_recall('silver rocket flying north', 'silver pocket'), 0.25)
        self.assertEqual(av.word_recall('silver rocket flying north', ''), 0.0)

    def test_word_recall_accepts_neighbours_written_as_one_word(self):
        # live run cp-relay-4, C6b: correlation 1.02 with the source, scored 60% before
        self.assertEqual(av.word_recall('thunder storm over desert road', 'Thunderstorm over Desert Road.'), 1.0)
        self.assertEqual(av.word_recall('thunder storm over desert road', 'Thunder over desert road.'), 0.8)
        self.assertEqual(av.word_recall('thunder storm over desert road', 'stormthunder'), 0.0)

    def test_phrase_bank_words_are_disjoint(self):
        seen = {}
        for phrase in BANK:
            for word in set(av.words(phrase['text'])):
                self.assertNotIn(word, seen, '%s reuses %r from %s' % (phrase['id'], word, seen.get(word)))
                seen[word] = phrase['id']


class SpeechTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dir = Path(tempfile.mkdtemp(prefix='vc-sapi-'))
        cls.phrases = {}
        for rate in RATES:
            paths = synthesize(cls.dir / str(rate), rate, USED)
            cls.phrases[rate] = {k: av.read_wav(v) for k, v in paths.items()}

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.dir, ignore_errors=True)

    def test_generated_phrases_are_canonical_and_at_the_requested_rate(self):
        for rate in RATES:
            for audio in self.phrases[rate].values():
                self.assertEqual(audio.rate, rate)
                self.assertGreater(audio.seconds, 1.0)
        raw = (self.dir / '8000' / 'P01.wav').read_bytes()
        self.assertEqual(raw[36:40], b'data')  # 44-byte header for the test component

    def test_speech_band_detector(self):
        for rate in RATES:
            source = self.phrases[rate]['P01']
            threshold = av.speech_threshold(source)
            self.assertGreater(av.speech_seconds(source, threshold), 0.8)
            self.assertEqual(av.speech_seconds(av.Audio(rate, np.zeros(rate * 2)), threshold), 0.0)

    def test_simulated_reception_keeps_speech_coverage(self):
        for rate in RATES:
            source = self.phrases[rate]['P01']
            verdict, reasons, metrics = av.judge(window(), received(source), source, NoAsr())
            self.assertEqual(verdict, 'INCONCLUSIVE', reasons)  # never PASS without ASR
            self.assertGreaterEqual(metrics['speech_coverage'], av.MIN_SPEECH_COVERAGE, metrics)

    def test_envelope_correlation_prefers_the_right_phrase(self):
        source = self.phrases[8000]['P01']
        right = av.envelope_xcorr(source, received(source))
        wrong = av.envelope_xcorr(source, received(self.phrases[8000]['P02']))
        self.assertGreater(right, av.MIN_XCORR)
        self.assertGreater(right, wrong)

    def test_silence_control_fails(self):
        source = self.phrases[8000]['P01']
        verdict, reasons, _ = av.judge(window(), av.Audio(8000, []), source, NoAsr())
        self.assertEqual(verdict, 'FAIL', reasons)
        verdict, reasons, metrics = av.judge(window(), av.Audio(8000, np.zeros(16000, dtype=np.int16)), source, NoAsr())
        self.assertEqual(verdict, 'FAIL', reasons)
        self.assertLess(metrics['speech_coverage'], av.MIN_SPEECH_COVERAGE)

    def test_quiet_hiss_fails_coverage_even_without_asr(self):
        source = self.phrases[8000]['P01']
        hiss = np.random.default_rng(3).normal(0, 20, 8000 * 3).astype(np.int16)
        verdict, reasons, _ = av.judge(window(), av.Audio(8000, hiss), source, NoAsr())
        self.assertEqual(verdict, 'FAIL', reasons)

    def test_heard_needs_confirmed_injection(self):
        source = self.phrases[8000]['P01']
        verdict, _, _ = av.judge(window(played=False), received(source), source, NoAsr())
        self.assertEqual(verdict, 'INCONCLUSIVE')

    def test_verdict_logic_around_asr(self):
        source = self.phrases[8000]['P01']
        audio = received(source)
        self.assertEqual(av.judge(window(), audio, source, FakeAsr('Purple elephant, dancing slowly.'))[0], 'PASS')
        self.assertEqual(av.judge(window(), audio, source, FakeAsr('purple elephant dancing'))[0], 'PASS')  # 3/4
        self.assertEqual(av.judge(window(), audio, source, FakeAsr('purple elephant'))[0], 'FAIL')  # 2/4
        verdict, reasons, metrics = av.judge(window('silent', recv=0), audio, source, FakeAsr('purple elephant'))
        self.assertEqual((verdict, metrics['leaked_words']), ('FAIL', ['elephant', 'purple']))

    def test_asr_passes_simulated_reception(self):
        asr = recognizer()
        if not asr.available:
            self.skipTest(asr.reason)
        for rate in RATES:
            for phrase in USED:
                source = self.phrases[rate][phrase]
                verdict, reasons, metrics = av.judge(window(phrase=phrase), received(source), source, asr)
                self.assertEqual(verdict, 'PASS', (rate, phrase, reasons, metrics))

    def test_asr_rejects_the_wrong_phrase(self):
        asr = recognizer()
        if not asr.available:
            self.skipTest(asr.reason)
        source = self.phrases[8000]['P01']
        verdict, reasons, metrics = av.judge(window(phrase='P01'), received(self.phrases[8000]['P02']), source, asr)
        self.assertEqual(verdict, 'FAIL', (reasons, metrics))
        self.assertLess(metrics['word_recall'], av.MIN_WORD_RECALL)


class SilentWindowTests(unittest.TestCase):
    def test_zero_samples_with_proven_capture_passes(self):
        self.assertEqual(av.judge(window('silent', recv=0), av.Audio(8000, []), None, NoAsr())[0], 'PASS')

    def test_any_decoded_audio_fails(self):
        audio = av.Audio(8000, np.full(160, 1000, dtype=np.int16))
        self.assertEqual(av.judge(window('silent', recv=0), audio, None, NoAsr())[0], 'FAIL')
        self.assertEqual(av.judge(window('silent', recv=1), av.Audio(8000, []), None, NoAsr())[0], 'FAIL')

    def test_snapshot_counters_prove_capture_and_catch_leaks(self):
        counted = dict(window('silent', encoded=0, recv=0), talker_encoded_frames=40, listener_recv_samples=0)
        self.assertEqual(av.judge(counted, av.Audio(8000, []), None, NoAsr())[0], 'PASS')
        leaked = dict(counted, listener_recv_samples=160)
        self.assertEqual(av.judge(leaked, av.Audio(8000, []), None, NoAsr())[0], 'FAIL')

    def test_silence_without_capture_proves_nothing(self):
        self.assertEqual(av.judge(window('silent', encoded=0, recv=0), av.Audio(8000, []), None, NoAsr())[0], 'INCONCLUSIVE')
        self.assertEqual(av.judge(window('silent', played=False, recv=0), av.Audio(8000, []), None, NoAsr())[0], 'INCONCLUSIVE')

    def test_idle_control_needs_no_injection(self):
        idle = window('silent', phrase=None, inject=False, played=False, encoded=0, recv=0)
        self.assertEqual(av.judge(idle, av.Audio(8000, []), None, NoAsr())[0], 'PASS')


class CommandLineTests(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp(prefix='vc-cli-'))

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def test_end_to_end_without_asr(self):
        (self.dir / 'phrases').mkdir()
        tone = (np.sin(np.arange(16000) * 2 * np.pi * 440 / 8000) * 8000).astype(np.int16)
        write_wav(self.dir / 'phrases' / 'P01.wav', 8000, tone)
        (self.dir / 'cp' / 'B').mkdir(parents=True)
        # recording: 1000 samples before the window, the phrase, 500 after
        write_wav(self.dir / 'cp' / 'B' / 'recv_0.wav', 8000, np.concatenate([np.zeros(1000), tone, np.zeros(500)]), declared=0)
        start, end = 44 + 2000, 44 + 2000 + len(tone) * 2
        base = dict(mode='CP', talker='A', listener='B', talker_client=0, listener_client=1, inject=True,
                    play_started=True, play_ended=True, talker_encoded_events=5)
        phrase = dict(id='P01', text=TEXT['P01'], wav='phrases/P01.wav')
        rec = lambda s, e: dict(wav='cp/B/recv_0.wav', start=s, end=e)
        document = dict(schema='iw7.voice-certify.analysis-input/1', complete=True, windows=[
            dict(base, id='C1', title='heard', expect='heard', phrase=phrase, recording=rec(start, end), listener_recv_events=4),
            dict(base, id='C3a', title='muted', expect='silent', phrase=phrase, recording=rec(end, end), listener_recv_events=0),
            dict(base, id='C4a', title='leak', expect='silent', phrase=phrase, recording=rec(start, end), listener_recv_events=2),
            dict(base, id='C0:A>B', title='idle', expect='silent', inject=False, phrase=None, play_started=False, play_ended=False,
                 talker_encoded_events=0, recording=rec(44, 44), listener_recv_events=0),
        ])
        (self.dir / 'analysis-input.json').write_text(json.dumps(document), encoding='utf-8')
        code = av.main([str(self.dir / 'analysis-input.json'), '--no-asr', '--table', str(self.dir / 'verdict.md')])
        self.assertEqual(code, 0)
        analysis = json.loads((self.dir / 'analysis.json').read_text(encoding='utf-8'))
        verdicts = {w['id']: w['verdict'] for w in analysis['windows']}
        self.assertEqual(verdicts, {'C1': 'INCONCLUSIVE', 'C3a': 'PASS', 'C4a': 'FAIL', 'C0:A>B': 'PASS'})
        self.assertEqual(analysis['windows'][0]['metrics']['samples'], len(tone))
        self.assertEqual(analysis['summary']['verdict'], 'FAIL')
        self.assertFalse(analysis['asr']['available'])
        table = (self.dir / 'verdict.md').read_text(encoding='utf-8')
        for name in verdicts:
            self.assertIn('| %s |' % name, table)

    def test_bad_schema_is_rejected(self):
        (self.dir / 'x.json').write_text(json.dumps(dict(schema='nope', windows=[])), encoding='utf-8')
        self.assertEqual(av.main([str(self.dir / 'x.json'), '--no-asr']), 2)


if __name__ == '__main__':
    unittest.main()
