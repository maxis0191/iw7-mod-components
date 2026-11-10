"""Unit tests for ops/engine-map/iw7_watch.py on synthetic memory recordings (no real recorded data)."""
import contextlib
import gc
import importlib.util
import io
import json
from pathlib import Path
import random
import struct
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


def load_module(name, rel):
    spec = importlib.util.spec_from_file_location(name, ROOT / rel)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


watch = load_module("iw7_watch_under_test", "ops/engine-map/iw7_watch.py")

ADDRESS = 0x141FA6C88
SIZE = 8192
COUNT = 50
HZ = 10_000_000
INTERVAL_MS = 100
PAGE_1 = slice(0x1000, 0x2000)
HOLE_SAMPLE = 17


def walk():
    rnd = random.Random(7)
    value, out = 10.0, []
    for _ in range(COUNT):
        out.append(value)
        value += rnd.choice((-0.3, 0.3, 0.1, -0.1, 0.5))
    return out


WALK = walk()


def make_block(freeze_first=False, extra=False, hole=True, odd=True):
    """COUNT samples of a block of SIZE bytes. The fields (offsets are of 4-byte fields unless noted):
    0x100 counter +3 per sample (30 a second at 100 ms), 0x108 slow counter, 0x10C counter +2, 0x110 counter +4,
    0x200 millisecond clock, 0x300 constant, 0x400 float random walk, 0x500 a counter that drops once,
    0x1200 counter in page 1 (which is zero-filled in sample 17 when `hole`), 0x1301 an unaligned counter,
    0x1400 a 64-bit counter (its low half is a 4-byte counter too), 0x700 changes only when `extra`; with `freeze_first` 0x100 does not move."""
    samples, unreadable = [], []
    for i in range(COUNT):
        b = bytearray(SIZE)
        struct.pack_into('<i', b, 0x100, 1000 + (0 if freeze_first else 3 * i))
        struct.pack_into('<i', b, 0x108, 50 + i // 5)
        struct.pack_into('<i', b, 0x10C, 70 + 2 * i)
        struct.pack_into('<i', b, 0x110, 90 + 4 * i)
        struct.pack_into('<i', b, 0x200, 5_000_000 + 100 * i)
        struct.pack_into('<I', b, 0x300, 0xDEADBEEF)
        struct.pack_into('<f', b, 0x400, WALK[i])
        struct.pack_into('<i', b, 0x500, 100 + 3 * i - (50 if i >= 25 else 0))
        struct.pack_into('<i', b, 0x1200, 7 + 3 * i)
        if odd:
            struct.pack_into('<i', b, 0x1301, 7 + 3 * i)
        struct.pack_into('<q', b, 0x1400, 4_000_000_000 + 3 * i)
        if extra:
            struct.pack_into('<i', b, 0x700, 9 + 4 * i)
        holes = 0
        if hole and i == HOLE_SAMPLE:
            b[PAGE_1] = bytes(0x1000)
            holes = 1
        samples.append(bytes(b))
        unreadable.append(holes)
    return samples, unreadable


def write_recording(path, samples, unreadable, spacing_ms=100, address=ADDRESS, schema=watch.SCHEMA, cut=0, interval_ms=INTERVAL_MS, **header_extra):
    size = len(samples[0])
    stamps = [5_000_000_000 + i * spacing_ms * HZ // 1000 for i in range(len(samples))]
    header = {'schema': schema, 'address': '%X' % address, 'size': size, 'count': len(samples), 'interval_ms': interval_ms, 'qpc_hz': HZ,
              'timestamps': stamps, 'unreadable_pages': unreadable, 'pid': 4242}
    header.update(header_extra)
    data = json.dumps(header).encode('utf-8') + b'\n' + b''.join(samples)
    Path(path).write_bytes(data[:len(data) - cut] if cut else data)


def run(*argv):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        try:
            rc = watch.main(list(argv))
        except SystemExit as exit_:
            rc = exit_.code
    return rc, out.getvalue(), err.getvalue()


class MemoryWatchTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(lambda: (gc.collect(), cls.tmp.cleanup()))
        cls.dir = Path(cls.tmp.name)
        samples, unreadable = make_block()
        cls.main_file = str(cls.dir / 'a.bin')
        write_recording(cls.main_file, samples, unreadable)

    def find(self, *args, file=None):
        rc, out, err = run('find', file or self.main_file, *args, '--json')
        self.assertEqual((rc, err), (0, ''), out)
        return json.loads(out)

    def offsets(self, *args, file=None):
        return [c['offset'] for c in self.find(*args, file=file)['candidates']]

    # kinds
    def test_counter(self):
        got = self.find('--kind', 'counter')
        self.assertEqual(sorted(c['offset'] for c in got['candidates']), [0x100, 0x108, 0x10C, 0x110, 0x1200, 0x1400])
        first = {c['offset']: c for c in got['candidates']}[0x100]
        self.assertEqual(first['address'], '%X' % (ADDRESS + 0x100))
        self.assertEqual((first['first'], first['last'], first['changes']), (1000, 1147, 48))  # sample 17 is left out: 49 samples, 48 changes
        self.assertAlmostEqual(first['total_change_per_second'], 30.0, places=6)
        self.assertAlmostEqual(first['mean_step'], 147 / 48, places=6)
        self.assertEqual((first['min_step'], first['max_step']), (3, 6))
        self.assertEqual(got['header']['samples'], COUNT)
        self.assertEqual(got['header']['samples_used'], COUNT - 1)
        self.assertEqual(got['header']['dropped_samples'], [HOLE_SAMPLE])
        self.assertEqual(got['header']['address'], '%X' % ADDRESS)

    def test_counter_with_unreadable_zeros_needs_the_sample_left_out(self):
        self.assertIn(0x1200, self.offsets('--kind', 'counter'))
        got = self.find('--kind', 'counter', '--keep-unreadable')
        self.assertNotIn(0x1200, [c['offset'] for c in got['candidates']])  # the zero fill is a drop to 0 and a rise back
        self.assertEqual(got['header']['dropped_samples'], [])
        self.assertIn(0x1200, self.offsets('--kind', 'changing', '--keep-unreadable'))

    def test_a_hole_present_in_every_sample_is_not_a_reason_to_drop_any(self):
        samples, _ = make_block(hole=False)
        path = str(self.dir / 'steady_hole.bin')
        write_recording(path, samples, [1] * COUNT)
        got = self.find('--kind', 'counter', file=path)
        self.assertEqual((got['header']['samples_used'], got['header']['dropped_samples']), (COUNT, []))
        self.assertIn(0x1200, [c['offset'] for c in got['candidates']])

    def test_clock(self):
        got = self.find('--kind', 'clock')
        self.assertEqual([c['offset'] for c in got['candidates']], [0x200])
        self.assertAlmostEqual(got['candidates'][0]['total_change_per_second'], 1000.0, places=6)
        self.assertEqual(self.offsets('--kind', 'clock', '--rate-max', '500'), [])
        self.assertEqual(self.offsets('--kind', 'clock', '--rate-min', '900', '--rate-max', '1100'), [0x200])

    def test_constant_is_a_count(self):
        got = self.find('--kind', 'constant')
        self.assertNotIn('candidates', got)
        self.assertEqual(got['aligned_offsets'], SIZE // 4)
        self.assertEqual(got['constant_offsets'], SIZE // 4 - 10)  # ten aligned fields change: see make_block
        rc, out, _err = run('find', self.main_file, '--kind', 'constant')
        self.assertEqual(rc, 0)
        self.assertIn('constant (never changed): %d of %d' % (SIZE // 4 - 10, SIZE // 4), out)

    def test_changing(self):
        offsets = self.offsets('--kind', 'changing', '--top', '100')
        self.assertEqual(offsets, sorted(offsets))
        self.assertEqual(offsets, [0x100, 0x108, 0x10C, 0x110, 0x200, 0x400, 0x500, 0x1200, 0x1300, 0x1400])
        self.assertNotIn(0x300, offsets)
        self.assertNotIn(0x700, offsets)

    def test_a_field_that_decreases_once_is_changing_but_not_a_counter(self):
        self.assertIn(0x500, self.offsets('--kind', 'changing'))
        self.assertNotIn(0x500, self.offsets('--kind', 'counter'))

    def test_float(self):
        rows = {c['offset']: c for c in self.find('--kind', 'float', '--rate-min', '0.001', '--rate-max', '100', '--top', '100')['candidates']}
        self.assertEqual(sorted(rows), [0x400])
        row = rows[0x400]
        self.assertAlmostEqual(row['first'], WALK[0], places=5)
        self.assertAlmostEqual(row['last'], WALK[-1], places=5)
        self.assertAlmostEqual(row['total_change_per_second'], (WALK[-1] - WALK[0]) / 4.9, places=3)
        self.assertIn(0x400, self.offsets('--kind', 'float', '--top', '100'))  # small integers read as tiny floats are listed too
        rc, _out, err = run('find', self.main_file, '--kind', 'float', '--width', '8')
        self.assertEqual(rc, 2)
        self.assertIn('--width 4', err)

    # filters, widths, sorting
    def test_rate_filter_is_total_change_per_second(self):
        self.assertEqual(sorted(self.offsets('--kind', 'counter', '--rate-min', '25', '--rate-max', '35')), [0x100, 0x1200, 0x1400])
        self.assertEqual(self.offsets('--kind', 'counter', '--rate-min', '35'), [0x110])
        self.assertEqual(self.offsets('--kind', 'counter', '--rate-max', '3'), [0x108])
        self.assertEqual(self.offsets('--kind', 'counter', '--rate-min', '1000'), [])

    def test_sorted_by_distance_from_the_middle_of_the_range_else_by_offset(self):
        # 30 a second at 0x100, 0x1200 and 0x1400, 20 at 0x10C, 40 at 0x110
        self.assertEqual(self.offsets('--kind', 'counter', '--rate-min', '15', '--rate-max', '45'), [0x100, 0x1200, 0x1400, 0x10C, 0x110])
        self.assertEqual(self.offsets('--kind', 'counter', '--rate-min', '19', '--rate-max', '21'), [0x10C])
        self.assertEqual(self.offsets('--kind', 'counter', '--rate-min', '21'), [0x100, 0x1200, 0x1400, 0x110])  # nearest to 21 first
        self.assertEqual(self.offsets('--kind', 'counter'), [0x100, 0x108, 0x10C, 0x110, 0x1200, 0x1400])

    def test_step_filters(self):
        # sample 17 is left out, so the step across it is the sum of two steps: 0x10C moves 2 or 4, 0x110 moves 4 or 8
        self.assertEqual(self.offsets('--kind', 'counter', '--step-max', '2'), [0x108])
        self.assertEqual(self.offsets('--kind', 'counter', '--step-max', '4'), [0x108, 0x10C])
        self.assertEqual(self.offsets('--kind', 'counter', '--step-min', '3'), [0x100, 0x110, 0x1200, 0x1400])
        self.assertEqual(self.offsets('--kind', 'counter', '--step-min', '4', '--step-max', '8'), [0x110])
        self.assertEqual(self.offsets('--kind', 'counter', '--step-max', '100', '--step-min', '1', '--rate-min', '90'), [])

    def test_top_limits_the_list_and_json_keeps_the_match_count(self):
        got = self.find('--kind', 'counter', '--top', '2')
        self.assertEqual((got['matches'], len(got['candidates'])), (6, 2))
        rc, out, _err = run('find', self.main_file, '--kind', 'counter', '--top', '2')
        self.assertIn('6 match(es), showing 2', out)
        rc, _out, err = run('find', self.main_file, '--top', '0')
        self.assertEqual(rc, 2)

    def test_alignment_and_width(self):
        self.assertNotIn(0x1301, self.offsets('--kind', 'counter'))  # an unaligned field is not read at the default alignment
        self.assertIn(0x1301, self.offsets('--kind', 'counter', '--align', '1'))
        wide = {c['offset']: c for c in self.find('--kind', 'counter', '--width', '8', '--step-max', '8')['candidates']}
        self.assertEqual((wide[0x1400]['first'], wide[0x1400]['last']), (4_000_000_000, 4_000_000_000 + 3 * 49))
        self.assertIn(0x100, self.offsets('--kind', 'counter', '--width', '2'))
        self.assertIn(0x108, self.offsets('--kind', 'counter', '--width', '1', '--align', '1', '--step-min', '1', '--step-max', '1'))

    def test_the_rate_comes_from_the_timestamps(self):
        samples, unreadable = make_block(hole=False)
        slow = str(self.dir / 'slow.bin')
        write_recording(slow, samples, unreadable, spacing_ms=200)  # the header still says 100 ms
        row = {c['offset']: c for c in self.find('--kind', 'counter', file=slow)['candidates']}[0x100]
        self.assertAlmostEqual(row['total_change_per_second'], 15.0, places=6)
        self.assertAlmostEqual(row['changes_per_second'], 49 / 9.8, places=6)

    def test_text_output(self):
        rc, out, err = run('find', self.main_file, '--kind', 'counter', '--rate-min', '25', '--rate-max', '35')
        self.assertEqual((rc, err), (0, ''))
        self.assertIn('block 141FA6C88', out)
        self.assertIn('0x100', out)
        self.assertIn(' 256 ', out)
        self.assertIn('141FA6D88', out)
        self.assertIn('Note: The rate a recording can show is limited by its sampling interval', out)
        self.assertIn('samples 17 have more unreadable pages', out)
        rc, out, _err = run('find', self.main_file, '--kind', 'counter', '--rate-min', '9999')
        self.assertEqual(rc, 0)
        self.assertIn('no field matches', out)

    # diff and show
    def test_diff_lists_offsets_whose_behaviour_class_differs(self):
        samples, unreadable = make_block(freeze_first=True, extra=True, hole=False)
        other = str(self.dir / 'b.bin')
        write_recording(other, samples, unreadable)
        rc, out, err = run('diff', self.main_file, other, '--json')
        self.assertEqual((rc, err), (0, ''))
        got = json.loads(out)
        rows = {r['offset']: r for r in got['offsets']}
        self.assertEqual(sorted(rows), [0x100, 0x700])
        self.assertEqual((rows[0x100]['a'], rows[0x100]['b']), ('counter', 'constant'))
        self.assertEqual((rows[0x700]['a'], rows[0x700]['b']), ('constant', 'counter'))
        self.assertEqual(rows[0x700]['address'], '%X' % (ADDRESS + 0x700))
        self.assertIsNone(rows[0x700]['a_values'])
        self.assertEqual(got['differing'], 2)
        rc, text, _err = run('diff', self.main_file, other)
        self.assertEqual(rc, 0)
        self.assertIn('2 offset(s) differ', text)
        rc, text, _err = run('diff', self.main_file, self.main_file)
        self.assertIn('no offset behaves differently', text)

    def test_diff_of_two_different_blocks_is_refused(self):
        samples, unreadable = make_block()
        other = str(self.dir / 'elsewhere.bin')
        write_recording(other, samples, unreadable, address=ADDRESS + 0x1000)
        rc, _out, err = run('diff', self.main_file, other)
        self.assertEqual(rc, 2)
        self.assertIn('different blocks', err)

    def test_show(self):
        rc, out, err = run('show', self.main_file, '--offset', '0x100', '--width', '4', '--count', '3', '--json')
        self.assertEqual((rc, err), (0, ''))
        got = json.loads(out)
        self.assertEqual(got['address'], '%X' % (ADDRESS + 0x100))
        self.assertEqual(len(got['rows']), COUNT)
        self.assertEqual(got['rows'][0]['values'], [1000, 0, 50])
        self.assertEqual(got['rows'][5]['values'], [1015, 0, 51])
        self.assertAlmostEqual(got['rows'][5]['seconds'], 0.5, places=6)
        rc, text, _err = run('show', self.main_file, '--offset', '0x1200', '--count', '1')
        self.assertEqual(rc, 0)
        lines = text.splitlines()
        self.assertEqual(len(lines), 2 + COUNT)
        self.assertEqual(lines[2 + HOLE_SAMPLE].split()[:3], [str(HOLE_SAMPLE), '1.700', '1'])
        self.assertEqual(lines[2 + HOLE_SAMPLE].split()[3], '0')
        rc, text, _err = run('show', self.main_file, '--offset', '0x300', '--count', '1', '--hex')
        self.assertIn('DEADBEEF', text)
        rc, text, _err = run('show', self.main_file, '--offset', '1024', '--count', '1', '--float')
        self.assertEqual(rc, 0)
        self.assertIn('%.4f' % WALK[0], text)
        for argv in (('--offset', str(SIZE - 2)), ('--offset', '-4')):
            self.assertEqual(run('show', self.main_file, *argv)[0], 2)

    # refusals
    def test_truncated_file_is_refused(self):
        samples, unreadable = make_block()
        cut = str(self.dir / 'cut.bin')
        write_recording(cut, samples, unreadable, cut=100)
        for argv in (('find', cut), ('show', cut, '--offset', '0'), ('diff', cut, self.main_file)):
            rc, out, err = run(*argv)
            self.assertEqual(rc, 2)
            self.assertEqual(out, '')
            self.assertIn('truncated', err)
        longer = str(self.dir / 'longer.bin')
        write_recording(longer, samples, unreadable)
        with open(longer, 'ab') as f:
            f.write(b'xx')
        self.assertIn('longer than its header says', run('find', longer)[2])
        nohead = self.dir / 'nohead.bin'
        nohead.write_bytes(b'{"schema":"iw7.memory-watch/1"')
        rc, _out, err = run('find', str(nohead))
        self.assertEqual(rc, 2)
        self.assertIn('no header line', err)

    def test_wrong_schema_and_bad_headers_are_refused(self):
        samples, unreadable = make_block()
        bad = str(self.dir / 'schema.bin')
        write_recording(bad, samples, unreadable, schema='iw7.memory-watch/2')
        for argv in (('find', bad), ('show', bad, '--offset', '0'), ('diff', self.main_file, bad)):
            rc, out, err = run(*argv)
            self.assertEqual(rc, 2)
            self.assertEqual(out, '')
            self.assertIn('is not a memory recording', err)
        short = str(self.dir / 'stamps.bin')
        write_recording(short, samples, unreadable, timestamps=[1, 2, 3])
        self.assertIn('invalid header', run('find', short)[2])
        gone = run('find', str(self.dir / 'missing.bin'))
        self.assertEqual(gone[0], 2)
        self.assertIn('cannot be read', gone[2])
        text = self.dir / 'text.bin'
        text.write_bytes(b'not json\nrest')
        rc, _out, err = run('find', str(text))
        self.assertEqual(rc, 2)
        self.assertIn('not JSON', err)

    def test_usage_errors_exit_2(self):
        self.assertEqual(run('find', self.main_file, '--width', '3')[0], 2)
        self.assertEqual(run('find', self.main_file, '--kind', 'nothing')[0], 2)
        self.assertEqual(run('find', self.main_file, '--align', '0')[0], 2)


if __name__ == '__main__':
    unittest.main()
