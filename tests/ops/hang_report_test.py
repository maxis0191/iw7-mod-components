"""Unit tests for ops/engine-map/iw7_hang.py on synthetic freeze reports (no real recorded data)."""
import contextlib
import gc
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
import warnings

ROOT = Path(__file__).resolve().parents[2]


def load_module(name, rel):
    spec = importlib.util.spec_from_file_location(name, ROOT / rel)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


emt = load_module("engine_map_test_fixture", "tests/ops/engine_map_test.py")
hang = load_module("iw7_hang_under_test", "ops/engine-map/iw7_hang.py")

A, B, C = emt.A, emt.B, emt.C             # A is named Foo, B is named Multi, C has no name (sub_<hex>)
TEXT_BEGIN, TEXT_END = 0x140001000, 0x140100000
NTDLL, D3D = 0x7FF800000000, 0x7FF700000000


def hx(*values):
    return ';'.join('%X' % v for v in values)


def report(samples, others=None, **extra):
    doc = {'schema': 'iw7.hang/1', 'pid': 1, 'process': 'client', 'began_utc': '2026-11-10T10:00:00Z', 'frozen_ms': 5000, 'threshold_ms': 2000,
           'still_frozen': False,
           'image': {'base': '140000000', 'text_begin': '%X' % TEXT_BEGIN, 'text_end': '%X' % TEXT_END, 'unwind': True, 'functions': 3},
           'main_thread': 100, 'samples': samples, 'others': others if others is not None else [],
           'modules': [{'base': '%X' % NTDLL, 'size': 0x100000, 'name': 'ntdll.dll'}, {'base': '%X' % D3D, 'size': 0x100000, 'name': 'd3d11.dll'}]}
    doc.update(extra)
    return doc


def run(*argv):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        rc = hang.main(list(argv))
    return rc, out.getvalue(), err.getvalue()


class HangReportTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        warnings.simplefilter('ignore', ResourceWarning)
        cls.tmp = tempfile.TemporaryDirectory(ignore_cleanup_errors=True)
        cls.addClassCleanup(lambda: (gc.collect(), cls.tmp.cleanup()))
        cls.dir = Path(cls.tmp.name)
        ref = cls.dir / 'ref'
        ref.mkdir()
        for k, v in zip(('text', 'rdata', 'pdata'), emt.make_sections()):
            (ref / ('unpacked-%s.bin' % k)).write_bytes(v)
        symbols = cls.dir / 'symbols.hpp'
        symbols.write_text(emt.SYMBOLS_HPP, encoding='utf-8')
        cls.map_path = str(cls.dir / 'map.sqlite')
        with contextlib.redirect_stdout(io.StringIO()):
            emt.em.main(['build', '--db', cls.map_path, '--reference-root', str(ref), '--symbols', str(symbols), '--workers', '1'])

    def write(self, name, doc):
        path = self.dir / (name + '.json')
        path.write_text(doc if isinstance(doc, str) else json.dumps(doc), encoding='utf-8')
        return str(path)

    def report_json(self, name, doc, *extra):
        rc, out, err = run('report', self.write(name, doc), '--map', self.map_path, '--json', *extra)
        self.assertEqual((rc, err), (0, ''))
        return json.loads(out)

    # 1. one stack
    def test_one_stack_is_reported_once_at_100_percent(self):
        # three different addresses inside the same two functions: one named stack
        doc = report([[0, hx(A + 4, B + 1), ''], [500, hx(A + 8, B + 2), ''], [1000, hx(A + 0x10, B), ''], [1500, hx(A, B + 4), '']])
        data = self.report_json('one', doc)
        self.assertEqual(len(data['stacks']), 1)
        stack = data['stacks'][0]
        self.assertEqual(stack['frames'], ['Foo', 'Multi'])
        self.assertEqual((stack['samples'], stack['share'], stack['from_ms'], stack['to_ms']), (4, 1.0, 0, 1500))
        self.assertTrue(stack['stuck_here'])
        self.assertEqual(data['signature'], 'freeze in Foo < Multi')
        rc, text, _err = run('report', self.write('one_text', doc), '--map', self.map_path)
        self.assertEqual(rc, 0)
        self.assertIn('100.0%  4 samples  0-1500 ms   <- stuck here', text)
        self.assertEqual(text.count('<- stuck here'), 1)
        self.assertIn('signature: freeze in Foo < Multi', text)
        self.assertIn('freeze of the client: 5000 ms (threshold 2000 ms)', text)
        self.assertIn('main thread 100, 4 samples', text)

    # 2. a freeze that moves
    def test_freeze_that_moves_between_two_stacks(self):
        doc = report([[0, hx(A, B), ''], [500, hx(A, B), ''], [1000, hx(A, B), ''], [1500, hx(C + 1, B), ''], [2000, hx(C + 2, B), '']])
        data = self.report_json('moves', doc)
        by_leaf = {s['frames'][0]: s for s in data['stacks']}
        self.assertEqual(set(by_leaf), {'Foo', 'sub_%X' % C})
        self.assertEqual((by_leaf['Foo']['samples'], by_leaf['Foo']['share'], by_leaf['Foo']['from_ms'], by_leaf['Foo']['to_ms']), (3, 0.6, 0, 1000))
        self.assertEqual((by_leaf['sub_%X' % C]['samples'], by_leaf['sub_%X' % C]['share'], by_leaf['sub_%X' % C]['from_ms']), (2, 0.4, 1500))
        self.assertTrue(by_leaf['Foo']['stuck_here'])
        self.assertFalse(by_leaf['sub_%X' % C]['stuck_here'])
        self.assertEqual(data['stacks'][0]['frames'][0], 'Foo')          # the stuck stack comes first
        self.assertEqual(data['signature'], 'freeze in Foo < Multi')
        _rc, text, _err = run('report', self.write('moves_text', doc), '--map', self.map_path)
        self.assertEqual(text.count('<- stuck here'), 1)
        self.assertIn(' 60.0%  3 samples', text)
        self.assertIn(' 40.0%  2 samples', text)

    def test_top_limits_the_stacks_printed(self):
        doc = report([[0, hx(A), ''], [500, hx(A), ''], [1000, hx(B), '']])
        _rc, text, _err = run('report', self.write('top', doc), '--map', self.map_path, '--top', '1')
        self.assertIn('(1 more stack not shown)', text)

    # 3. a leaf in the system
    def test_system_leaf_shows_the_nearest_game_code(self):
        doc = report([[0, hx(NTDLL + 0x10), hx(B + 5, A + 2)], [500, hx(NTDLL + 0x20), hx(B + 6, A + 3)]])
        data = self.report_json('system', doc)
        self.assertEqual(len(data['stacks']), 1)                          # two ntdll addresses, one named stack
        self.assertEqual(data['stacks'][0]['frames'], ['[ntdll.dll]', 'Multi', 'Foo'])
        self.assertEqual(data['signature'], 'freeze in [ntdll.dll] < Multi < Foo')
        _rc, text, _err = run('report', self.write('system_text', doc), '--map', self.map_path)
        self.assertIn('[ntdll.dll]', text)

    def test_system_leaf_without_scan_and_unknown_module(self):
        doc = report([[0, hx(D3D + 0x20), ''], [500, hx(0x1000), '']])
        data = self.report_json('driver', doc)
        self.assertEqual(sorted(s['frames'] for s in data['stacks']), [['[d3d11.dll]'], ['[unknown]']])
        self.assertEqual(data['signature'], 'freeze in [d3d11.dll]' if data['stacks'][0]['frames'] == ['[d3d11.dll]'] else 'freeze in [unknown]')

    def test_signature_keeps_two_game_frames_and_drops_offsets(self):
        # an unmapped game address is 'game+<rva>'; a name that carries an offset loses it
        self.assertEqual(hang.plain('Foo+0x10'), 'Foo')
        self.assertEqual(hang.plain('sub_140001080+0xA4'), 'sub_140001080')
        self.assertEqual(hang.plain('game+50000'), 'game+50000')
        doc = report([[0, hx(A + 4, B + 3, C + 1, A + 9), '']])
        data = self.report_json('sig', doc)
        self.assertEqual(data['stacks'][0]['frames'], ['Foo', 'Multi', 'sub_%X' % C, 'Foo'])
        self.assertEqual(data['signature'], 'freeze in Foo < Multi < sub_%X' % C)
        self.assertNotIn('+', data['signature'])
        self.assertNotIn('0x', data['signature'])

    def test_frames_are_limited_to_twelve(self):
        doc = report([[0, hx(*[(A, B)[i % 2] + 1 for i in range(16)]), '']])
        self.assertEqual(len(self.report_json('twelve', doc)['stacks'][0]['frames']), 12)

    # 4. other threads
    def test_other_threads_are_listed(self):
        others = [[7, hx(NTDLL + 1), hx(B + 5)], [8, hx(A + 2, B), ''], [9, hx(D3D + 1), '']]
        doc = report([[0, hx(A), '']], others)
        data = self.report_json('others', doc)
        self.assertEqual(data['others'], [{'thread': 7, 'leaf': '[ntdll.dll]', 'first_game_frame': 'Multi'},
                                          {'thread': 8, 'leaf': 'Foo', 'first_game_frame': 'Multi'},
                                          {'thread': 9, 'leaf': '[d3d11.dll]', 'first_game_frame': None}])
        _rc, text, _err = run('report', self.write('others_text', doc), '--map', self.map_path)
        self.assertIn('Other threads at the start: 3', text)
        self.assertIn('thread 7: [ntdll.dll]  <-  Multi', text)
        self.assertIn('thread 8: Foo  <-  Multi', text)
        self.assertIn('thread 9: [d3d11.dll]\n', text)

    # 5. json, server, still frozen
    def test_json_has_the_header_and_the_signature(self):
        doc = report([[0, hx(A), '']], process='server', server_pipeline_frozen=True, still_frozen=True, frozen_ms=120500)
        data = self.report_json('json', doc)
        self.assertEqual((data['process'], data['frozen_ms'], data['threshold_ms'], data['still_frozen'], data['samples']), ('server', 120500, 2000, True, 1))
        self.assertTrue(data['server_pipeline_frozen'])
        self.assertEqual(data['main_thread'], 100)
        self.assertEqual(data['signature'], 'freeze in Foo')
        _rc, text, _err = run('report', self.write('json_text', doc), '--map', self.map_path)
        self.assertIn('server pipeline frozen: yes', text)
        self.assertIn('still frozen when written', text)

    def test_report_without_samples_does_not_crash(self):
        data = self.report_json('empty', report([]))
        self.assertEqual((data['stacks'], data['samples']), ([], 0))
        self.assertEqual(data['signature'], 'freeze (no sample of the main thread)')
        rc, text, _err = run('report', self.write('empty_text', report([])), '--map', self.map_path)
        self.assertEqual(rc, 0)
        self.assertIn('no sample', text)

    # 6. no map
    def test_without_a_map_only_addresses_are_shown(self):
        doc = report([[0, hx(A + 4, B), ''], [500, hx(NTDLL + 1), hx(B + 5)]])
        path = self.write('nomap', doc)
        rc, out, err = run('report', path, '--json')
        self.assertEqual((rc, err), (0, ''))
        data = json.loads(out)
        frames = {tuple(s['frames']) for s in data['stacks']}
        self.assertIn(('game+%X' % (A + 4 - 0x140000000), 'game+%X' % (B - 0x140000000)), frames)   # no map: one name per address
        self.assertIn(('[ntdll.dll]', 'game+%X' % (B + 5 - 0x140000000)), frames)
        rc, text, _err = run('report', path)
        self.assertEqual(rc, 0)
        self.assertIn('signature: freeze in game+', text)

    # 7. bad files
    def test_wrong_schema_exits_2(self):
        doc = report([[0, hx(A), '']])
        doc['schema'] = 'iw7.hang/2'
        rc, out, err = run('report', self.write('schema', doc), '--map', self.map_path)
        self.assertEqual((rc, out), (2, ''))
        self.assertIn('not a hang report', err)
        doc['schema'] = 'iw7.perf-window/1'
        self.assertEqual(run('report', self.write('schema_perf', doc))[0], 2)

    def test_truncated_file_exits_2(self):
        text = json.dumps(report([[0, hx(A), ''], [500, hx(A), '']]))
        rc, out, err = run('report', self.write('truncated', text[:len(text) // 2]))
        self.assertEqual((rc, out), (2, ''))
        self.assertIn('truncated', err)
        self.assertEqual(run('report', self.write('empty_file', ''))[0], 2)

    def test_incomplete_and_missing_files_exit_2(self):
        doc = report([[0, hx(A), '']])
        del doc['others']
        rc, _out, err = run('report', self.write('missing_key', doc))
        self.assertEqual(rc, 2)
        self.assertIn('others', err)
        doc = report([[0, hx(A)]])                                     # a sample of two fields
        self.assertEqual(run('report', self.write('bad_row', doc))[0], 2)
        rc, _out, err = run('report', str(self.dir / 'does-not-exist.json'))
        self.assertEqual(rc, 2)
        self.assertIn('cannot be read', err)
        self.assertEqual(run('report', self.write('a_list', '[1, 2]'))[0], 2)


if __name__ == '__main__':
    unittest.main()
