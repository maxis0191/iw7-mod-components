"""Source tests of ops/engine-map/iw7_sperf.py on synthetic server meter windows (no recorded data)."""
import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, 'ops', 'engine-map'))
import iw7_sperf  # noqa: E402

SCRIPTS = [
    {'file': 'scripts/cp/a', 'functions': [['loop', '1000'], ['work', '1100'], ['__end__', '1200']]},
    {'file': 'custom_scripts/cp/burn', 'functions': [['burn_loop', '2000'], ['burn_work', '2040'], ['__end__', '2100']]},
]


def window(name, burn_samples, frame_ms=0.5, frames=400, ticks=20000, seconds=20.0):
    stacks = [[300, 1, '1000;1150'], [100, 1, '1000'], [5, 0, '1180;5000']]
    if burn_samples:
        stacks.append([burn_samples, 1, '2010;2050'])
    script = sum(s[0] for s in stacks)
    return {'schema': 'iw7.server-perf/1', 'name': name, 'pid': 1, 'seconds': seconds, 'qpc_hz': 10000000,
            'server_thread': 7, 'frame_function': '140B15E20',
            'frames_us': [[i * 50000, int(frame_ms * 1000)] for i in range(frames)],
            'sampler': {'ticks': ticks, 'hz': ticks / seconds, 'script': script, 'frame_no_script': 100, 'idle': ticks - script - 100,
                        'failures': 0, 'dropped': 0},
            'stacks': stacks, 'scripts': SCRIPTS, 'memory': {'working_set': 1, 'private': 1}}


class SperfTest(unittest.TestCase):
    def test_names(self):
        names = iw7_sperf.Scripts(window('a', 0))
        self.assertEqual(names.name(0x1150), 'scripts/cp/a::work')
        self.assertEqual(names.name(0x2050), 'custom_scripts/cp/burn::burn_work')
        self.assertTrue(names.name(0x1500).startswith('unknown@'))  # past a file's end
        self.assertTrue(names.name(0x10).startswith('unknown@'))

    def test_report_ms_per_frame(self):
        r = iw7_sperf.summary(window('burn', 400))
        # 400 samples of 20000 ticks over 20 s and 400 frames: 400/20000*20000 ms/400 = 1.0 ms per frame
        top = r['self'][0]
        self.assertEqual(top['name'], 'custom_scripts/cp/burn::burn_work')
        self.assertAlmostEqual(top['ms_per_frame'], 1.0, places=6)
        threads = {row['name']: row['samples'] for row in r['threads']}
        self.assertEqual(threads['custom_scripts/cp/burn::burn_loop'], 400)
        self.assertEqual(threads['scripts/cp/a::loop'], 400)
        self.assertEqual(r['frames']['frames'], 400)
        self.assertAlmostEqual(r['frames']['median_ms'], 0.5)
        self.assertAlmostEqual(r['frames']['hz'], 20.0)
        incl = {row['name']: row['samples'] for row in r['inclusive']}
        self.assertEqual(incl['scripts/cp/a::loop'], 400)
        self.assertEqual(r['sampler']['script_in_frame'], 800)

    def test_compare_names_the_grown_function(self):
        c = iw7_sperf.compare([window('base', 0)], [window('burn', 400, frame_ms=1.5)])
        self.assertEqual(c['largest_increase']['name'], 'custom_scripts/cp/burn::burn_work')
        self.assertAlmostEqual(c['largest_increase']['delta_ms'], 1.0, places=3)
        self.assertAlmostEqual(c['frame_median_delta_ms'], 1.0)
        unchanged = [r for r in c['self'] if r['name'] == 'scripts/cp/a::work'][0]
        self.assertAlmostEqual(unchanged['delta_ms'], 0.0)

    def test_compare_no_change(self):
        c = iw7_sperf.compare([window('a', 0)], [window('b', 0)])
        self.assertIsNone(c['largest_increase'])

    def test_cli_and_schema(self):
        with tempfile.TemporaryDirectory() as d:
            a, b, bad = os.path.join(d, 'a.json'), os.path.join(d, 'b.json'), os.path.join(d, 'bad.json')
            for path, doc in ((a, window('base', 0)), (b, window('burn', 400)), (bad, {'schema': 'other'})):
                with open(path, 'w', encoding='utf-8') as f:
                    json.dump(doc, f)
            out = io.StringIO()
            with redirect_stdout(out):
                self.assertEqual(iw7_sperf.main(['report', b]), 0)
                self.assertEqual(iw7_sperf.main(['compare', a, b]), 0)
            text = out.getvalue()
            self.assertIn('burn_work', text)
            self.assertIn('largest increase: custom_scripts/cp/burn::burn_work', text)
            with self.assertRaises(SystemExit):
                iw7_sperf.load(bad)


if __name__ == '__main__':
    unittest.main()
