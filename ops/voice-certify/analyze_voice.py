"""Voice certification analyzer (offline; run with python -I).

Reads analysis-input.json written by Invoke-VoiceCertify.ps1: one entry per
measurement window, naming the receiver's recv_<talker>.wav and the byte range
recorded during the window. Judges every window:

  heard  : decoded audio from the talker, speech-band energy for >= 60 % of the
           source phrase's speech, and faster-whisper recognizes >= 75 % of the
           phrase's words. Without ASR the window is INCONCLUSIVE, never PASS.
  silent : zero decoded samples from the talker and no recv event, while the
           talker provably injected and encoded speech (otherwise INCONCLUSIVE).

Usage: python -I analyze_voice.py analysis-input.json [--output analysis.json]
       [--table verdict.md] [--model small] [--no-asr] [--require-xcorr]
Exit code 0 when the analysis was written (whatever the verdict), 2 on bad input.
"""
import argparse
import json
import math
import os
import re
import site
import struct
import sys
from pathlib import Path


def _add_user_site():
    # -I also drops the per-user site-packages, where numpy (and faster-whisper,
    # when installed) live on this machine. Re-adding exactly that directory keeps
    # what -I is for here: nothing is imported from the script or working directory.
    path = site.getusersitepackages()
    if os.path.isdir(path) and path not in sys.path:
        site.addsitedir(path)


_add_user_site()
import numpy as np  # noqa: E402

MIN_WORD_RECALL = 0.75
MIN_SPEECH_COVERAGE = 0.60
MIN_XCORR = 0.5
FRAME_SECONDS = 0.02
SPEECH_BAND = (300.0, 3400.0)
ABSOLUTE_FLOOR_DB = -50.0
ASR_RATE = 16000


class Audio:
    def __init__(self, rate, samples):
        self.rate = int(rate)
        self.samples = np.asarray(samples, dtype=np.int16)

    @property
    def seconds(self):
        return len(self.samples) / float(self.rate) if self.rate else 0.0


def _looks_like_chunk(raw, position):
    if position + 8 > len(raw):
        return False
    name = raw[position:position + 4]
    size = struct.unpack_from('<I', raw, position + 4)[0]
    return all(65 <= c <= 90 or 97 <= c <= 122 or c == 32 for c in name) and position + 8 + size <= len(raw)


def read_wav(path, start=None, end=None):
    """Reads a PCM16 mono WAV. The live recorder rewrites its header lazily, so the
    declared data size is ignored when the file holds more (or the size is 0).
    start/end are absolute file byte offsets; the slice is clamped to the data
    chunk and aligned to whole samples."""
    raw = Path(path).read_bytes()
    if len(raw) < 12 or raw[:4] != b'RIFF' or raw[8:12] != b'WAVE':
        raise ValueError('not a RIFF/WAVE file: %s' % path)
    position, fmt = 12, None
    while position + 8 <= len(raw):
        chunk, size = raw[position:position + 4], struct.unpack_from('<I', raw, position + 4)[0]
        body = position + 8
        if chunk == b'fmt ':
            tag, channels, rate = struct.unpack_from('<HHI', raw, body)
            bits = struct.unpack_from('<H', raw, body + 14)[0]
            fmt = (tag, channels, rate, bits)
        elif chunk == b'data':
            if fmt is None or fmt[0] != 1 or fmt[1] != 1 or fmt[3] != 16:
                raise ValueError('expected PCM16 mono: %s' % path)
            declared_end = body + size
            if size in (0, 0xFFFFFFFF) or declared_end > len(raw):
                data_end = len(raw)
            elif declared_end < len(raw) and not _looks_like_chunk(raw, declared_end + (size & 1)):
                data_end = len(raw)  # samples appended after the last header update
            else:
                data_end = declared_end
            lo = body if start is None else min(max(int(start), body), data_end)
            hi = data_end if end is None else min(max(int(end), lo), data_end)
            lo = body + ((lo - body) // 2) * 2
            hi = body + ((hi - body) // 2) * 2
            return Audio(fmt[2], np.frombuffer(raw[lo:hi], dtype='<i2').copy())
        position = body + size + (size & 1)
    raise ValueError('no data chunk: %s' % path)


def resample(samples, rate, target):
    x = np.asarray(samples, dtype=np.float64)
    if rate == target or len(x) == 0:
        return x
    try:
        from scipy.signal import resample_poly
        g = math.gcd(int(rate), int(target))
        return resample_poly(x, int(target) // g, int(rate) // g)
    except ImportError:
        n = int(round(len(x) * target / float(rate)))
        return np.interp(np.linspace(0, len(x) - 1, n), np.arange(len(x)), x)


def band_levels_db(audio):
    """Speech-band (300-3400 Hz) level of each 20 ms frame, in dB full scale."""
    hop = max(1, int(round(audio.rate * FRAME_SECONDS)))
    count = len(audio.samples) // hop
    if count == 0:
        return np.zeros(0)
    frames = audio.samples[:count * hop].astype(np.float64).reshape(count, hop) / 32768.0
    spectrum = np.abs(np.fft.rfft(frames * np.hanning(hop), axis=1)) ** 2
    freqs = np.fft.rfftfreq(hop, 1.0 / audio.rate)
    band = (freqs >= SPEECH_BAND[0]) & (freqs <= min(SPEECH_BAND[1], audio.rate / 2.0))
    window_power = np.sum(np.hanning(hop) ** 2)
    power = np.sum(spectrum[:, band], axis=1) * 2.0 / (window_power * hop)
    return 10.0 * np.log10(power + 1e-12)


def speech_threshold(source):
    """Level above which a frame counts as speech: 25 dB under the source phrase's
    loud frames (90th percentile), never below -50 dBFS. The same absolute
    threshold is applied to the source and the recording; the recording cannot
    supply its own floor because VAD gating leaves it almost no silence."""
    levels = band_levels_db(source)
    if len(levels) == 0:
        return ABSOLUTE_FLOOR_DB
    return max(ABSOLUTE_FLOOR_DB, float(np.percentile(levels, 90)) - 25.0)


def speech_seconds(audio, threshold):
    levels = band_levels_db(audio)
    return float(np.count_nonzero(levels > threshold)) * FRAME_SECONDS


def envelope_xcorr(source, received):
    """Best normalized cross-correlation of the two speech-band envelopes over all
    lags. Levels are floored at the speech threshold so the depth of the silences
    (digital zero in the source, codec noise in the recording) does not dominate."""
    floor = speech_threshold(source)
    a = np.maximum(band_levels_db(source), floor)
    b = np.maximum(band_levels_db(received), floor)
    if len(a) < 5 or len(b) < 5:
        return 0.0
    a = (a - a.mean()) / (a.std() + 1e-9)
    b = (b - b.mean()) / (b.std() + 1e-9)
    corr = np.correlate(b, a, mode='full')
    overlap = np.correlate(np.ones(len(b)), np.ones(len(a)), mode='full')
    valid = overlap >= min(len(a), len(b)) * 0.5
    return float(np.max(corr[valid] / overlap[valid])) if np.any(valid) else 0.0


def words(text):
    return re.findall(r"[a-z]+", (text or '').lower().replace("'", ''))


def _base(word):
    return word[:-1] if len(word) > 3 and word.endswith('s') else word


def word_recall(expected, recognized):
    """Share of the expected words present in the transcript; a plural/singular
    difference ('lantern' / 'lanterns') still counts as recognized."""
    want = words(expected)
    if not want:
        return 0.0
    heard = {_base(w) for w in words(recognized)}
    return sum(1 for w in want if _base(w) in heard) / float(len(want))


class Recognizer:
    """faster-whisper on CPU (int8) from the local Hugging Face cache only."""

    def __init__(self, model='small'):
        self.model_name = model
        self.model = None
        self.reason = ''
        os.environ.setdefault('HF_HUB_OFFLINE', '1')
        try:
            from faster_whisper import WhisperModel
        except ImportError as error:
            self.reason = 'faster_whisper is not installed (%s)' % error
            return
        try:
            self.model = WhisperModel(model, device='cpu', compute_type='int8', local_files_only=True)
        except Exception as error:  # model missing from the cache, bad files...
            self.reason = 'could not load model %r from the local cache: %s' % (model, error)

    @property
    def available(self):
        return self.model is not None

    def transcribe(self, audio):
        x = resample(audio.samples, audio.rate, ASR_RATE).astype(np.float32) / 32768.0
        segments, _ = self.model.transcribe(x, language='en', beam_size=5, temperature=0.0,
                                            condition_on_previous_text=False, vad_filter=False,
                                            without_timestamps=True)
        return ' '.join(segment.text.strip() for segment in segments).strip()


def judge(window, recorded, source, recognizer, require_xcorr=False):
    """Returns (verdict, reasons, metrics) for one window."""
    reasons, metrics = [], {}
    samples = len(recorded.samples) if recorded is not None else 0
    metrics['samples'] = samples
    metrics['seconds'] = round(recorded.seconds, 3) if recorded is not None else 0.0
    metrics['recv_events'] = int(window.get('listener_recv_events', 0) or 0)
    metrics['encoded_events'] = int(window.get('talker_encoded_events', 0) or 0)
    # cumulative counters from the snapshots around the window (None when not reported)
    metrics['encoded_frames'] = window.get('talker_encoded_frames')
    metrics['recv_samples'] = window.get('listener_recv_samples')
    captured = metrics['encoded_events'] > 0 or (metrics['encoded_frames'] or 0) > 0
    leaked_counter = (metrics['recv_samples'] or 0) > 0
    injected = bool(window.get('inject', True))
    played = bool(window.get('play_started')) and bool(window.get('play_ended'))

    if window.get('expect') == 'silent':
        if injected and not played:
            return 'INCONCLUSIVE', ['injection not confirmed (play_start/play_end missing)'], metrics
        if injected and not captured:
            return 'INCONCLUSIVE', ['talker capture not proven (no encoded frame): silence proves nothing'], metrics
        if samples == 0 and metrics['recv_events'] == 0 and not leaked_counter:
            return 'PASS', ['no decoded audio from the talker'], metrics
        reasons.append('%d decoded samples (%.2f s), %d recv events, recv counter +%s from the talker' % (
            samples, metrics['seconds'], metrics['recv_events'], metrics['recv_samples'] or 0))
        if samples and recognizer is not None and recognizer.available and source is not None:
            text = recognizer.transcribe(recorded)
            metrics['asr_text'] = text
            leaked = sorted(set(words(window['phrase']['text'])) & set(words(text)))
            metrics['leaked_words'] = leaked
            if leaked:
                reasons.append('phrase words leaked: ' + ', '.join(leaked))
        return 'FAIL', reasons, metrics

    if not played:
        return 'INCONCLUSIVE', ['injection not confirmed (play_start/play_end missing)'], metrics
    if samples == 0:
        return 'FAIL', ['no decoded audio from the talker'], metrics
    threshold = speech_threshold(source)
    source_speech = speech_seconds(source, threshold)
    received_speech = speech_seconds(recorded, threshold)
    coverage = received_speech / source_speech if source_speech > 0 else 0.0
    metrics.update(source_speech_seconds=round(source_speech, 3), speech_seconds=round(received_speech, 3),
                   speech_coverage=round(coverage, 3), xcorr=round(envelope_xcorr(source, recorded), 3))
    verdict = 'PASS'
    if coverage < MIN_SPEECH_COVERAGE:
        verdict = 'FAIL'
        reasons.append('speech-band energy covers %.0f%% of the phrase (< %.0f%%)' % (coverage * 100, MIN_SPEECH_COVERAGE * 100))
    if require_xcorr and metrics['xcorr'] <= MIN_XCORR:
        verdict = 'FAIL'
        reasons.append('envelope correlation %.2f <= %.2f' % (metrics['xcorr'], MIN_XCORR))
    if recognizer is None or not recognizer.available:
        reasons.append('ASR unavailable: ' + (recognizer.reason if recognizer is not None else 'disabled'))
        return ('FAIL' if verdict == 'FAIL' else 'INCONCLUSIVE'), reasons, metrics
    text = recognizer.transcribe(recorded)
    recall = word_recall(window['phrase']['text'], text)
    metrics.update(asr_text=text, word_recall=round(recall, 3))
    if recall < MIN_WORD_RECALL:
        verdict = 'FAIL'
        reasons.append('ASR recognized %.0f%% of the phrase (< %.0f%%): %r' % (recall * 100, MIN_WORD_RECALL * 100, text))
    if verdict == 'PASS':
        reasons.append('ASR %.0f%%, speech coverage %.0f%%' % (recall * 100, coverage * 100))
    return verdict, reasons, metrics


def analyze(document, base, recognizer, require_xcorr=False):
    results = []
    for window in document['windows']:
        recording = window.get('recording') or {}
        recorded = Audio(8000, [])
        path = base / recording['wav'] if recording.get('wav') else None
        start, end = int(recording.get('start', 0)), int(recording.get('end', 0))
        if path is not None and path.exists() and end > start:
            recorded = read_wav(path, start, end)
        source = None
        if window.get('phrase'):
            source = read_wav(base / window['phrase']['wav'])
            if recorded.rate != source.rate and len(recorded.samples) == 0:
                recorded = Audio(source.rate, [])
        verdict, reasons, metrics = judge(window, recorded, source, recognizer, require_xcorr)
        results.append(dict(id=window['id'], mode=window.get('mode'), title=window.get('title'),
                            expect=window.get('expect'), talker=window.get('talker'), listener=window.get('listener'),
                            verdict=verdict, reasons=reasons, metrics=metrics))
    counts = {v: sum(1 for r in results if r['verdict'] == v) for v in ('PASS', 'FAIL', 'INCONCLUSIVE')}
    overall = 'FAIL' if counts['FAIL'] else ('INCONCLUSIVE' if counts['INCONCLUSIVE'] or not results else 'PASS')
    if not document.get('complete', True) and overall == 'PASS':
        overall = 'INCONCLUSIVE'
    return dict(schema='iw7.voice-certify.analysis/1',
                asr=dict(available=bool(recognizer and recognizer.available),
                         model=recognizer.model_name if recognizer else None,
                         reason=recognizer.reason if recognizer else 'disabled by --no-asr'),
                criteria=dict(min_word_recall=MIN_WORD_RECALL, min_speech_coverage=MIN_SPEECH_COVERAGE,
                              speech_band_hz=list(SPEECH_BAND), xcorr_required=require_xcorr, min_xcorr=MIN_XCORR),
                windows=results, summary=dict(counts, verdict=overall, complete=document.get('complete', True)))


def table(analysis):
    lines = ['| Window | Mode | Expect | Talker > listener | Verdict | Evidence |', '|---|---|---|---|---|---|']
    for r in analysis['windows']:
        m = r['metrics']
        detail = '%s samples' % m.get('samples', 0)
        if 'word_recall' in m:
            detail += ', ASR %.0f%%' % (m['word_recall'] * 100)
        if 'speech_coverage' in m:
            detail += ', speech %.0f%%' % (m['speech_coverage'] * 100)
        lines.append('| %s | %s | %s | %s > %s | %s | %s; %s |' % (
            r['id'], r['mode'], r['expect'], r['talker'], r['listener'], r['verdict'], detail, '; '.join(r['reasons'])))
    s = analysis['summary']
    lines.append('')
    lines.append('Overall: **%s** (%d pass, %d fail, %d inconclusive). ASR: %s.' % (
        s['verdict'], s['PASS'], s['FAIL'], s['INCONCLUSIVE'],
        analysis['asr']['model'] if analysis['asr']['available'] else 'unavailable - ' + analysis['asr']['reason']))
    return '\n'.join(lines) + '\n'


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('input', type=Path)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--table', type=Path)
    parser.add_argument('--model', default='small')
    parser.add_argument('--no-asr', action='store_true')
    parser.add_argument('--require-xcorr', action='store_true')
    args = parser.parse_args(argv)
    try:
        document = json.loads(args.input.read_text(encoding='utf-8-sig'))
        if document.get('schema') != 'iw7.voice-certify.analysis-input/1':
            raise ValueError('unexpected schema %r' % document.get('schema'))
    except (OSError, ValueError) as error:
        print('bad input: %s' % error, file=sys.stderr)
        return 2
    recognizer = None if args.no_asr else Recognizer(args.model)
    analysis = analyze(document, args.input.parent, recognizer, args.require_xcorr)
    output = args.output or args.input.with_name('analysis.json')
    output.write_text(json.dumps(analysis, indent=2), encoding='utf-8')
    text = table(analysis)
    if args.table:
        args.table.write_text(text, encoding='utf-8')
    print(text, end='')
    return 0


if __name__ == '__main__':
    sys.exit(main())
