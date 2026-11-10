"""Unit tests for ops/engine-map/iw7_perf.py on synthetic recorder windows (no real recorded data)."""
import contextlib
import gc
import importlib.util
import io
import json
from pathlib import Path
import random
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
perf = load_module("iw7_perf_under_test", "ops/engine-map/iw7_perf.py")

A, B, C = emt.A, emt.B, emt.C             # A is named Foo, B is named Multi, C has no name (sub_<hex>)
TEXT_BEGIN, TEXT_END = 0x140001000, 0x140100000
NTDLL, D3D, UNMAPPED_GAME = 0x7FF800000000, 0x7FF700000000, 0x140050000


def hx(*values):
    return ';'.join('%X' % v for v in values)


def default_stacks():
    return [
        [0, 10, hx(A + 4, B + 1), ''],                                  # leaf Foo (inside the function), caller Multi
        [0, 3, hx(B + 2, A + 0x10, B), ''],                             # Multi twice on one stack (recursion)
        [0, 4, hx(NTDLL + 0x10), hx(B + 5)],                            # system leaf, nearest game code Multi
        [0, 2, hx(D3D + 0x20), ''],                                     # driver leaf, no game code found
        [0, 1, hx(UNMAPPED_GAME, A), ''],                               # game range, no mapped function
        [0, 1, hx(0x1000), hx(A)],                                      # in no module
        [1, 5, hx(C + 1), ''],                                          # render thread
        [2, 7, hx(A), ''],                                              # an "other" thread
    ]


def window(name='w', frames=None, stacks=None, threads=None, seconds=2.0):
    threads = threads if threads is not None else [
        {'id': 1, 'role': 'main', 'user_ms': 100.0, 'kernel_ms': 50.0, 'samples': 21, 'failures': 0},
        {'id': 2, 'role': 'render', 'user_ms': 200.0, 'kernel_ms': 20.0, 'samples': 5, 'failures': 0},
        {'id': 3, 'role': 'other', 'user_ms': 10.0, 'kernel_ms': 5.0, 'samples': 7, 'failures': 0},
        {'id': 4, 'role': 'other', 'user_ms': 20.0, 'kernel_ms': 5.0, 'samples': 0, 'failures': 0}]
    return {'schema': 'iw7.perf-window/1', 'name': name, 'pid': 1, 'seconds': seconds, 'qpc_hz': 10000000,
            'image': {'base': '140000000', 'text_begin': '%X' % TEXT_BEGIN, 'text_end': '%X' % TEXT_END, 'unwind': True, 'functions': 3},
            'frames_us': frames if frames is not None else [5000] * 99 + [20000], 'threads': threads,
            'sampler': {'ticks': 1200, 'hz': 600.0, 'samples': 33, 'dropped': 0, 'others_per_tick': 3},
            'stacks': stacks if stacks is not None else default_stacks(),
            'modules': [{'base': '%X' % NTDLL, 'size': 0x100000, 'name': 'ntdll.dll'}, {'base': '%X' % D3D, 'size': 0x100000, 'name': 'd3d11.dll'}],
            'memory': {'working_set': 300 * 2 ** 20, 'private': 200 * 2 ** 20}}


def run(*argv):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        rc = perf.main(list(argv))
    return rc, out.getvalue()


def noisy(n, scale=1.0, seed=1):
    rng = random.Random(seed)
    return [int((4000 + rng.random() * 2000) * scale) for _ in range(n)]


class PerfWindowTest(unittest.TestCase):
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
        cls.map = perf.iw7_engine_map.Map(cls.map_path)
        cls.addClassCleanup(cls.map.db.close)

    def write(self, name, doc):
        path = self.dir / (name + '.json')
        path.write_text(json.dumps(doc), encoding='utf-8')
        return str(path)

    def namer(self, doc=None):
        return perf.Namer(doc or window(), self.map)

    # 1. frame statistics
    def test_frame_stats_known_list(self):
        s = perf.frame_stats([5000] * 99 + [20000])
        self.assertEqual(s['frames'], 100)
        self.assertEqual(s['seconds'], 0.515)
        self.assertEqual(s['fps'], round(100 / 0.515, 2))          # frames over total time
        self.assertNotEqual(s['fps'], round((99 * 200.0 + 50.0) / 100, 2))   # not the mean of the per-frame rates
        self.assertEqual(s['median_ms'], 5.0)
        self.assertEqual(s['p99_ms'], 20.0)
        self.assertEqual(s['max_ms'], 20.0)
        self.assertEqual(s['low_1pct_fps'], 50.0)
        self.assertEqual(s['over_2x_median'], 1)

    def test_frame_stats_empty_is_none(self):
        self.assertIsNone(perf.frame_stats([]))

    # 2. names
    def test_namer(self):
        n = self.namer()
        self.assertEqual(n.name(A), 'Foo')
        self.assertEqual(n.name(A + 0x0C), 'Foo')                  # inside the function: the function's name
        self.assertEqual(n.name(B), 'Multi')
        self.assertEqual(n.name(C), 'sub_%X' % C)
        self.assertEqual(n.name(UNMAPPED_GAME), 'game+%X' % (UNMAPPED_GAME - 0x140000000))
        self.assertEqual(n.name(NTDLL + 5), '[ntdll.dll]')
        self.assertEqual(n.name(0x1000), '[unknown]')
        self.assertTrue(n.game(A))
        self.assertFalse(n.game(NTDLL))

    def test_namer_without_a_map_uses_game_form(self):
        n = perf.Namer(window(), None)
        self.assertEqual(n.name(A), 'game+%X' % (A - 0x140000000))

    # 3. profile
    def test_profile_main(self):
        p = perf.profile(window(), self.namer(), 'main')
        self.assertEqual((p['threads'], p['samples']), (1, 21))
        self.assertEqual(dict(p['self']), {'Foo': 10, 'Multi': 3, '[ntdll.dll]': 4, '[d3d11.dll]': 2,
                                           'game+%X' % (UNMAPPED_GAME - 0x140000000): 1, '[unknown]': 1})
        self.assertEqual(p['self'][0], ('Foo', 10))                # sorted by descending count
        self.assertEqual(dict(p['inclusive']), {'Foo': 14, 'Multi': 13, 'game+%X' % (UNMAPPED_GAME - 0x140000000): 1})   # recursion counts the stack once
        self.assertEqual(dict(p['via']), {('[ntdll.dll]', 'Multi'): 4, ('[unknown]', 'Foo'): 1})
        self.assertEqual(p['waiting_share'], round(4 / 21, 4))     # only ntdll; the driver and the unknown address do not wait
        self.assertEqual(p['cpu_ms'], 150.0)

    def test_roles_are_separate_and_cpu_sums_threads(self):
        n, doc = self.namer(), window()
        render, other = perf.profile(doc, n, 'render'), perf.profile(doc, n, 'other')
        self.assertEqual((render['samples'], dict(render['self'])), (5, {'sub_%X' % C: 5}))
        self.assertEqual(render['cpu_ms'], 220.0)
        self.assertEqual((other['threads'], other['samples'], dict(other['self'])), (2, 7, {'Foo': 7}))
        self.assertEqual(other['cpu_ms'], 40.0)                    # 15 + 25 over two threads
        self.assertNotIn('sub_%X' % C, dict(perf.profile(doc, n, 'main')['self']))

    def test_profile_of_a_role_without_samples(self):
        doc = window(stacks=[[0, 3, hx(A), '']])
        p = perf.profile(doc, self.namer(doc), 'render')
        self.assertEqual((p['samples'], p['waiting_share'], p['self']), (0, 0, []))

    # 4. report
    def test_report_text_and_json(self):
        path = self.write('report', window('scene'))
        rc, text = run('report', path, '--map', self.map_path)
        self.assertEqual(rc, 0)
        self.assertIn('window scene: 2.0 s', text)
        self.assertIn('frames 100  194.2 fps  median 5.000 ms', text)
        self.assertIn('main thread: 1, CPU 150 ms (8% of one core), 21 samples, 19% of them waiting', text)
        self.assertIn('Foo', text)
        self.assertIn('[ntdll.dll]  <-  Multi', text)
        rc, js = run('report', path, '--map', self.map_path, '--json')
        data = json.loads(js)
        self.assertEqual(data['name'], 'scene')
        self.assertEqual(data['frames']['fps'], 194.17)
        main = data['roles'][0]
        self.assertEqual((main['role'], main['samples'], main['cpu_ms']), ('main', 21, 150.0))
        self.assertEqual(main['self'][0], ['Foo', 10])
        self.assertEqual(main['via'][0], ['[ntdll.dll]', 'Multi', 4])
        self.assertEqual([r['role'] for r in data['roles']], ['main', 'render', 'other'])

    def test_report_top_limits_rows(self):
        path = self.write('top', window())
        _rc, text = run('report', path, '--map', self.map_path, '--top', '1')
        self_block = text.split('self time')[1].split('inclusive time')[0]
        self.assertIn('Foo', self_block)
        self.assertNotIn('Multi', self_block)

    # 5. compare
    def test_compare_faster(self):
        base = self.write('cb', window('b', noisy(1000)))
        cand = self.write('cc', window('c', noisy(1000, 0.9)))           # same frames, each 10 % shorter
        _rc, text = run('compare', base, cand, '--json')
        rows = {r['what']: r for r in json.loads(text)['rows']}
        for what in ('mean frame time', 'median frame time'):
            r = rows[what]
            self.assertEqual(r['verdict'], 'faster', what)
            self.assertLess(r['high'], 0)
            self.assertLess(r['low'], r['change'])
            self.assertAlmostEqual(r['change'], -0.1, delta=0.01)
        _rc, plain = run('compare', base, cand)
        self.assertIn('faster', plain)

    def test_compare_identical_and_slower(self):
        base = self.write('ib', window('b', noisy(1000)))
        same = self.write('ic', window('c', noisy(1000)))
        _rc, text = run('compare', base, same, '--json')
        for r in json.loads(text)['rows'][:2]:
            self.assertEqual(r['verdict'], 'no difference shown', r)
            self.assertLess(r['low'], 0)
            self.assertGreater(r['high'], 0)
        _rc, plain = run('compare', base, same)
        self.assertIn('no difference shown', plain)
        slow = self.write('is', window('c', noisy(1000, 1.1)))
        _rc, text = run('compare', base, slow, '--json')
        rows = {r['what']: r for r in json.loads(text)['rows']}
        for what in ('mean frame time', 'median frame time'):
            self.assertEqual(rows[what]['verdict'], 'slower')
            self.assertGreater(rows[what]['low'], 0)

    def test_compare_too_few_frames_exits(self):
        ok = self.write('few_ok', window(frames=noisy(1000)))
        few = self.write('few', window(frames=noisy(199)))
        for args in ((ok, few), (few, ok)):
            with self.assertRaises(SystemExit) as ctx:
                run('compare', *args)
            self.assertIn('too few frames', str(ctx.exception))

    def test_compare_pools_repeats_and_prints_the_spread(self):
        b1 = self.write('p1', window(frames=noisy(300, 1.0, 1)))
        b2 = self.write('p2', window(frames=noisy(300, 1.05, 3)))
        cand = self.write('pc', window(frames=noisy(300, 1.0, 4)))
        _rc, text = run('compare', b1 + ',' + b2, cand, '--json')
        data = json.loads(text)
        self.assertEqual((data['base_windows'], data['candidate_windows']), (2, 1))
        self.assertIsNotNone(data['base_run_to_run_spread'])
        _rc, plain = run('compare', b1 + ',' + b2, cand)
        self.assertIn('base 2 window(s)', plain)
        self.assertIn('repeats of the base differ by', plain)
        self.assertNotIn('frame-to-frame noise only', plain)
        total = 600 / (sum(noisy(300, 1.0, 1)) / 1e6 + sum(noisy(300, 1.05, 3)) / 1e6)
        self.assertAlmostEqual(data['base_fps'], total, delta=0.05)     # pooled frames over pooled time

    def test_compare_single_windows_say_noise_only(self):
        base = self.write('sb', window(frames=noisy(1000)))
        cand = self.write('sc', window(frames=noisy(1000, 1.0, 2)))
        _rc, plain = run('compare', base, cand)
        self.assertIn('covers frame-to-frame noise only', plain)
        self.assertNotIn('repeats of the base differ', plain)

    # 6. determinism
    def test_compare_is_deterministic(self):
        base = self.write('db', window(frames=noisy(1000)))
        cand = self.write('dc', window(frames=noisy(1000, 0.95, 2)))
        self.assertEqual(run('compare', base, cand), run('compare', base, cand))

    # 7. folded
    def test_folded(self):
        doc = window(stacks=[[0, 4, hx(B + 1, A + 2), ''], [0, 6, hx(B + 3, A + 9), ''], [1, 5, hx(C + 1, B), ''], [2, 2, hx(A), '']])
        path = self.write('folded', doc)
        rc, text = run('folded', path, '--map', self.map_path)
        self.assertEqual(rc, 0)
        self.assertEqual(text.splitlines(), ['main;Foo;Multi 10', 'render;Multi;sub_%X 5' % C, 'other;Foo 2'])
        _rc, text = run('folded', path, '--map', self.map_path, '--role', 'render')
        self.assertEqual(text.splitlines(), ['render;Multi;sub_%X 5' % C])
        _rc, text = run('folded', path, '--map', self.map_path, '--max', '1')
        self.assertEqual(text.splitlines(), ['main;Foo;Multi 10'])

    # 8. schema
    def test_load_refuses_another_schema(self):
        doc = window()
        doc['schema'] = 'iw7.perf-window/2'
        with self.assertRaises(SystemExit) as ctx:
            perf.load(self.write('schema', doc))
        self.assertIn('not a recorder window', str(ctx.exception))
        self.assertEqual(perf.load(self.write('schema_ok', window()))['name'], 'w')


if __name__ == '__main__':
    unittest.main()
