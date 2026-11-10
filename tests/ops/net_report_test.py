"""Unit tests for ops/engine-map/iw7_net.py on synthetic client documents and synthetic server trace lines (no real recorded data)."""
import contextlib
import gc
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


def load_module(name, rel):
    spec = importlib.util.spec_from_file_location(name, ROOT / rel)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


net = load_module("iw7_net_under_test", "ops/engine-map/iw7_net.py")


def client_doc(gaps_ms, steps, ahead, seconds, passes, longest, skipped=0, **extra):
    doc = {'schema': 'iw7.net-client/1', 'pid': 4242, 'seconds': seconds, 'passes': passes, 'updates': len(gaps_ms),
           'skipped_updates': skipped, 'longest_passes_without_update': longest,
           'gaps_us': [int(g * 1000) for g in gaps_ms], 'server_time_steps_ms': steps, 'ahead_ms': ahead,
           'first_snapshot_num': 10, 'last_snapshot_num': 10 + len(gaps_ms) + skipped, 'truncated': False,
           'source': 'cg.latestSnapshotNum, cg.latestSnapshotTime, cg.predictedPlayerState.commandTime'}
    doc.update(extra)
    return doc


def steady():
    return client_doc([33.0] * 100, [33] * 100, [50] * 98 + [40, 70], 3.3, 400, 6)


def late_and_stall():
    return client_doc([33.0] * 95 + [70.0] * 4 + [200.0], [33] * 98 + [66, 99], [100] * 100, 3.5, 420, 9)


def with_skips():
    return client_doc([33.0] * 45 + [66.0] * 5, [33] * 45 + [66] * 5, [60] * 50, 1.8, 200, 4, skipped=5)


def empty():
    return {'schema': 'iw7.net-client/1', 'pid': 1, 'seconds': 0.0, 'passes': 0, 'updates': 0, 'skipped_updates': 0,
            'longest_passes_without_update': 0, 'gaps_us': [], 'server_time_steps_ms': [], 'ahead_ms': [],
            'first_snapshot_num': 0, 'last_snapshot_num': 0, 'truncated': False}


def sample(slot, **fields):
    """One per-client line as paris_incident.cpp writes it once a second (type reliable_window)."""
    row = {'schema': 'iw7.incident.native/1', 'type': 'reliable_window', 'utc': '2026-11-10T10:00:00.000Z', 'tick_ms': 1000,
           'pid': 77, 'thread': 5, 'slot': slot, 'state': 5, 'server_time': 5000, 'sequence': 12, 'ack': 12, 'sent': 12, 'pending': 0,
           'message_ack': 3, 'last_packet_time': 4990, 'last_usercmd_time': 4980, 'arrivals': 30, 'raw_acks': 30, 'negative_acks': 0,
           'ack_backlog_gate': 0, 'ack_ahead_of_sequence': 0, 'last_raw_ack': 12, 'move_calls': 30, 'moves_without_immediate_advance': 0,
           'text_calls': 1, 'binary_calls': 2, 'requested_command_bytes': 100, 'maximum_pending': 0, 'last_text_caller': 0,
           'last_binary_caller': 0, 'opcodes': {'3': 30}}
    row.update(fields)
    return row


def lines(*rows):
    return ''.join((r if isinstance(r, str) else json.dumps(r)) + '\n' for r in rows)


def run(*argv):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        rc = net.main(list(argv))
    return rc, out.getvalue(), err.getvalue()


def cells(text, label):
    """The value columns of one row of the compare table."""
    for line in text.splitlines():
        if line.startswith(label + ' '):
            return line[32:].split()
    raise AssertionError('no row %r in %r' % (label, text))


class NetReportTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(ignore_cleanup_errors=True)
        cls.addClassCleanup(lambda: (gc.collect(), cls.tmp.cleanup()))
        cls.dir = Path(cls.tmp.name)

    def write(self, name, doc):
        path = self.dir / (name + '.json')
        path.write_text(json.dumps(doc), encoding='utf-8')
        return str(path)

    def trace_dir(self):
        folder = self.dir / 'trace'
        folder.mkdir(exist_ok=True)
        (folder / 'native-77-1000-0.jsonl').write_text(lines(
            {'schema': 'iw7.incident.native/1', 'type': 'segment', 'part': 1},
            {'schema': 'iw7.incident.native/1', 'type': 'health', 'packets': 900, 'server_callbacks': 60},
            sample(0, ping=10, pending=0, maximum_pending=1),
            sample(1, state=4, pending=3, maximum_pending=3),
            'this line is not json',
            {'type': 'reliable_window', 'pending': 9},                         # no slot: not a per-client sample
            sample(0, ping=12, pending=2, maximum_pending=3, server_time=5000, oldest_pending_time=4900, ps_command_time=5010),
            {'schema': 'iw7.incident.native/1', 'type': 'client_drop', 'slot': 0, 'reason': 'x'}), encoding='utf-8')
        (folder / 'native-77-1000-1.jsonl').write_text(lines(
            sample(0, ping=20, pending=1, maximum_pending=2, server_time=7000, oldest_pending_time=6990),
            sample(1, state=4, pending=1, maximum_pending=2)), encoding='utf-8')
        (folder / 'notes.txt').write_text(lines(sample(5, ping=999)), encoding='utf-8')   # not a trace file: ignored
        return str(folder)

    # 1. client numbers
    def test_steady_stream(self):
        s = net.client_stats(steady())
        self.assertEqual(s['updates'], 100)
        self.assertEqual(s['updates_per_second'], round(100 / 3.3, 3))
        self.assertEqual(s['gap_ms'], {'median': 33.0, 'p95': 33.0, 'max': 33.0})
        self.assertEqual((s['late_updates'], s['stalls'], s['skipped_updates']), (0, 0, 0))
        self.assertEqual(s['server_step_ms_median'], 33)
        self.assertEqual(s['ahead_ms'], {'median': 50, 'min': 40, 'max': 70})
        self.assertEqual(s['longest_passes_without_update'], 6)
        self.assertEqual(s['passes'], 400)
        rc, text, _err = run('report', self.write('steady', steady()))
        self.assertEqual(rc, 0)
        self.assertEqual(text.splitlines(), [
            'client: 3.3 s active, 100 updates (30.30 a second), 400 passes of the main pipeline',
            'gap between updates (ms): median 33.000  95th percentile 33.000  max 33.000',
            'late updates (gap over twice the median): 0   stalls (gap over five times the median): 0',
            'skipped updates (snapshot number jumps): 0',
            'server time step between updates (ms), median: 33.000',
            'predicted time ahead of the latest server time (ms): median 50.000  min 40  max 70',
            'longest run of passes without a new update: 6'])

    def test_late_updates_and_a_stall(self):
        s = net.client_stats(late_and_stall())
        self.assertEqual(s['gap_ms'], {'median': 33.0, 'p95': 70.0, 'max': 200.0})
        self.assertEqual(s['late_updates'], 5)        # four of 70 ms and the stall, all over 66 ms
        self.assertEqual(s['stalls'], 1)              # only 200 ms is over 165 ms
        self.assertEqual(s['updates_per_second'], round(100 / 3.5, 3))
        self.assertEqual(s['ahead_ms'], {'median': 100, 'min': 100, 'max': 100})
        _rc, text, _err = run('report', self.write('late', late_and_stall()))
        self.assertIn('gap between updates (ms): median 33.000  95th percentile 70.000  max 200.000', text)
        self.assertIn('late updates (gap over twice the median): 5   stalls (gap over five times the median): 1', text)

    def test_gap_exactly_twice_the_median_is_not_late(self):
        s = net.client_stats(client_doc([33.0] * 90 + [66.0] * 10, [33] * 100, [0] * 100, 4.0, 100, 1))
        self.assertEqual((s['late_updates'], s['stalls']), (0, 0))

    def test_skipped_updates(self):
        s = net.client_stats(with_skips())
        self.assertEqual(s['skipped_updates'], 5)
        self.assertEqual(s['updates'], 50)
        self.assertEqual(s['server_step_ms_median'], 33)
        _rc, text, _err = run('report', self.write('skips', with_skips()))
        self.assertIn('skipped updates (snapshot number jumps): 5', text)

    def test_empty_document(self):
        s = net.client_stats(empty())
        self.assertIsNone(s['gap_ms'])
        self.assertIsNone(s['updates_per_second'])
        self.assertIsNone(s['ahead_ms'])
        self.assertIsNone(s['server_step_ms_median'])
        rc, text, _err = run('report', self.write('empty', empty()))
        self.assertEqual(rc, 0)
        self.assertIn('no updates recorded', text)
        self.assertNotIn('gap between updates', text)
        # arrays missing altogether
        bare = {'schema': 'iw7.net-client/1', 'seconds': 1.0, 'updates': 3}
        rc, text, _err = run('report', self.write('bare', bare))
        self.assertEqual(rc, 0)
        self.assertIn('no updates recorded', text)

    def test_truncated_and_discontinuities_are_stated(self):
        doc = steady()
        doc['truncated'] = True
        doc['discontinuities'] = 2
        _rc, text, _err = run('report', self.write('trunc', doc))
        self.assertIn('numbering went backwards 2 time(s)', text)
        self.assertIn('the arrays reached their cap', text)

    # 2. json output
    def test_report_json(self):
        rc, text, _err = run('report', self.write('j', late_and_stall()), '--json')
        self.assertEqual(rc, 0)
        got = json.loads(text)
        self.assertIsNone(got['trace'])
        c = got['client']
        self.assertEqual(c['updates'], 100)
        self.assertEqual(c['gap_ms'], {'median': 33.0, 'p95': 70.0, 'max': 200.0})
        self.assertEqual((c['late_updates'], c['stalls']), (5, 1))
        self.assertEqual(c['ahead_ms'], {'median': 100, 'min': 100, 'max': 100})
        self.assertEqual(c['longest_passes_without_update'], 9)
        self.assertEqual(c['server_step_ms_median'], 33)

    # 3. server trace
    def test_trace_per_slot(self):
        t = net.trace_stats([self.trace_dir()])
        self.assertEqual((t['files'], t['samples']), (2, 5))
        self.assertEqual(sorted(t['slots']), ['0', '1'])
        slot0 = t['slots']['0']
        self.assertEqual(slot0['samples'], 3)
        self.assertEqual(slot0['ping'], {'median': 12, 'min': 10, 'max': 20, 'samples': 3})
        self.assertEqual(slot0['fields']['pending'], {'median': 1, 'max': 2})
        self.assertEqual(slot0['fields']['maximum_pending'], {'median': 2, 'max': 3})
        self.assertEqual(slot0['fields']['arrivals'], {'median': 30, 'max': 30})
        # server_time minus oldest_pending_time: 5000 - 4900 and 7000 - 6990
        self.assertEqual(slot0['fields']['server_time_minus_oldest_pending_time'], {'median': 55.0, 'max': 100})
        slot1 = t['slots']['1']
        self.assertEqual(slot1['samples'], 2)
        self.assertIsNone(slot1['ping'])
        self.assertEqual(slot1['fields']['pending'], {'median': 2.0, 'max': 3})
        self.assertNotIn('server_time_minus_oldest_pending_time', slot1['fields'])

    def test_trace_single_file_and_text(self):
        folder = Path(self.trace_dir())
        one = str(folder / 'native-77-1000-0.jsonl')
        t = net.trace_stats([one])
        self.assertEqual((t['files'], t['samples']), (1, 3))
        self.assertEqual(t['slots']['0']['ping'], {'median': 11.0, 'min': 10, 'max': 12, 'samples': 2})
        rc, text, _err = run('report', self.write('with_trace', steady()), '--trace', str(folder))
        self.assertEqual(rc, 0)
        self.assertIn('server trace: 5 per-client samples from 2 file(s)', text)
        self.assertIn('  slot 0: 3 samples', text)
        self.assertIn('    ping (ms): median 12  min 10  max 20  (3 samples)', text)
        self.assertIn('    pending: median 1  max 2', text)
        self.assertIn('    ping: not in this trace', text)
        self.assertIn('client: 3.3 s active', text)

    def test_trace_json(self):
        rc, text, _err = run('report', self.write('tj', steady()), '--trace', self.trace_dir(), '--json')
        self.assertEqual(rc, 0)
        got = json.loads(text)
        self.assertEqual(got['trace']['samples'], 5)
        self.assertEqual(got['trace']['slots']['0']['ping'], {'median': 12, 'min': 10, 'max': 20, 'samples': 3})
        self.assertEqual(got['client']['updates'], 100)

    def test_trace_without_samples(self):
        folder = self.dir / 'trace_none'
        folder.mkdir(exist_ok=True)
        (folder / 'native-1-1-0.jsonl').write_text(lines({'type': 'health', 'packets': 1}, {'type': 'segment'}), encoding='utf-8')
        _rc, text, _err = run('report', self.write('tn', steady()), '--trace', str(folder))
        self.assertIn('server trace: no per-client samples in 1 file(s)', text)

    # 4. compare
    def test_compare_text(self):
        a, b = self.write('cmp_a', steady()), self.write('cmp_b', late_and_stall())
        rc, text, _err = run('compare', a, b)
        self.assertEqual(rc, 0)
        self.assertEqual(text.splitlines()[0].split(), ['A', 'B', 'B', 'minus', 'A'])
        expected = {
            'seconds': ['3.300', '3.500', '0.200'],
            'updates': ['100', '100', '0'],
            'updates per second': ['30.303', '28.571', '-1.732'],
            'gap median (ms)': ['33.000', '33.000', '0.000'],
            'gap 95th percentile (ms)': ['33.000', '70.000', '37.000'],
            'gap max (ms)': ['33.000', '200.000', '167.000'],
            'late updates': ['0', '5', '5'],
            'stalls': ['0', '1', '1'],
            'skipped updates': ['0', '0', '0'],
            'server time step median (ms)': ['33.000', '33.000', '0.000'],
            'ahead median (ms)': ['50.000', '100.000', '50.000'],
            'ahead min (ms)': ['40', '100', '60'],
            'ahead max (ms)': ['70', '100', '30'],
            'longest passes without update': ['6', '9', '3'],
        }
        for label, values in expected.items():
            self.assertEqual(cells(text, label), values, label)

    def test_compare_json_and_an_empty_side(self):
        rc, text, _err = run('compare', self.write('ca', steady()), self.write('cb', empty()), '--json')
        self.assertEqual(rc, 0)
        got = json.loads(text)
        rows = {r['what']: r for r in got['rows']}
        self.assertEqual(rows['updates'], {'what': 'updates', 'a': 100, 'b': 0, 'difference': -100})
        self.assertEqual(rows['gap max (ms)'], {'what': 'gap max (ms)', 'a': 33.0, 'b': None, 'difference': None})
        _rc, text, _err = run('compare', self.write('cc', steady()), self.write('cd', empty()))
        self.assertIn('B: no updates recorded', text)
        self.assertNotIn('A: no updates recorded', text)
        self.assertEqual(cells(text, 'gap max (ms)'), ['33.000', '-', '-'])

    # 5. refusals
    def test_another_schema_is_refused(self):
        doc = steady()
        doc['schema'] = 'iw7.net-client/2'
        bad = self.write('schema', doc)
        for argv in (('report', bad), ('compare', bad, self.write('ok', steady()))):
            rc, out, err = run(*argv)
            self.assertEqual(rc, 2)
            self.assertEqual(out, '')
            self.assertIn('is not a net client document', err)
        rc, _out, err = run('report', self.write('perf', {'schema': 'iw7.perf-window/1'}))
        self.assertEqual(rc, 2)
        self.assertIn('not a net client document', err)

    def test_unreadable_files_are_refused(self):
        rc, _out, err = run('report', str(self.dir / 'missing.json'))
        self.assertEqual(rc, 2)
        self.assertIn('cannot be read', err)
        broken = self.dir / 'broken.json'
        broken.write_text('{not json', encoding='utf-8')
        self.assertEqual(run('report', str(broken))[0], 2)
        rc, _out, err = run('report', self.write('fine', steady()), '--trace', str(self.dir / 'no_such_trace.jsonl'))
        self.assertEqual(rc, 2)
        self.assertIn('cannot be read', err)


if __name__ == '__main__':
    unittest.main()
