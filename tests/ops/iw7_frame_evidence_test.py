"""Tests for ops/iw7_frame_evidence.py on synthetic frames (no game, no assets)."""
import contextlib
import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest

import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
spec = importlib.util.spec_from_file_location('iw7_frame_evidence', os.path.join(ROOT, 'ops', 'iw7_frame_evidence.py'))
fe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fe)

W, H = 160, 90


def scene(seed=0):
    """A textured, mid-grey frame, like a lit in-game view."""
    rng = np.random.default_rng(seed)
    base = np.full((H, W, 3), 0.45, dtype=np.float32)
    return np.clip(base + rng.normal(0, 0.08, (H, W, 3)).astype(np.float32), 0, 1)


def save(path, rgb):
    Image.fromarray(np.round(rgb * 255).astype(np.uint8)).save(path)
    return path


class FrameMetrics(unittest.TestCase):
    def test_black_and_uniform_frames_are_flagged(self):
        black = np.zeros((H, W, 3), np.float32)
        self.assertEqual(fe.frame_metrics(black)['flags'], ['BLACK'])
        grey = np.full((H, W, 3), 0.5, np.float32)
        self.assertEqual(fe.frame_metrics(grey)['flags'], ['UNIFORM'])
        self.assertEqual(fe.frame_metrics(scene())['flags'], [])

    def test_clipped_frame(self):
        white = np.ones((H, W, 3), np.float32)
        white[0, 0] = 0  # not uniform
        self.assertIn('CLIPPED', fe.frame_metrics(white)['flags'])

    def test_hashes_identify_pixels_not_files(self):
        a, b = scene(1), scene(2)
        self.assertEqual(fe.frame_metrics(a)['pixel_sha256'], fe.frame_metrics(a.copy())['pixel_sha256'])
        self.assertNotEqual(fe.frame_metrics(a)['pixel_sha256'], fe.frame_metrics(b)['pixel_sha256'])
        ramp = np.tile(np.linspace(0, 1, W, dtype=np.float32), (H, 1))
        self.assertEqual(fe.dhash64(ramp), 'ffffffffffffffff')
        self.assertEqual(fe.dhash64(ramp[:, ::-1]), '0000000000000000')


class Compare(unittest.TestCase):
    def test_identical_and_static(self):
        a = scene(3)
        out, _ = fe.compare(a, a.copy())
        self.assertTrue(out['identical'])
        self.assertTrue(out['static'])
        self.assertIsNone(out['change_bbox'])

    def test_change_inside_roi_is_measured_exactly(self):
        a = scene(4)
        b = a.copy()
        b[20:30, 40:60] = [1.0, 0.0, 1.0]  # a 20x10 magenta effect
        out, mask = fe.compare(a, b, roi=(30, 10, 50, 40))
        self.assertEqual(out['change_bbox'], [40, 20, 20, 10])
        self.assertAlmostEqual(out['changed_fraction'], 200 / 2000, places=4)
        self.assertFalse(out['static'])
        self.assertEqual(out['changed_mean_rgb_test'], [1.0, 0.0, 1.0])
        self.assertEqual(mask.shape, (40, 50))
        # The same change outside the region is invisible to the measurement.
        out2, _ = fe.compare(a, b, roi=(100, 50, 40, 30))
        self.assertTrue(out2['identical'])

    def test_refusals(self):
        with self.assertRaises(ValueError):
            fe.compare(scene(), scene()[:, :-1])
        with self.assertRaises(ValueError):
            fe.compare(scene(), scene(), roi=(150, 0, 20, 10))


class Sequences(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def test_frozen_sequence_is_suspect(self):
        frame = scene(5)
        paths = [save(os.path.join(self.dir, 'view%d.png' % i), frame) for i in range(3)]
        report = fe.analyse(paths)
        seq = report['sequences']['frames']
        self.assertEqual(seq['verdict'], 'SUSPECT')
        self.assertEqual(seq['identical_pairs'], 2)
        self.assertEqual(report['duplicate_groups'], [['view0', 'view1', 'view2']])
        self.assertEqual(seq['max_change'], 0.0)

    def test_moving_sequence_is_usable(self):
        paths = [save(os.path.join(self.dir, 'view%d.png' % i), scene(10 + i)) for i in range(3)]
        report = fe.analyse([self.dir])
        seq = list(report['sequences'].values())[0]
        self.assertEqual(seq['verdict'], 'USABLE')
        self.assertGreater(seq['max_change'], 0.5)
        self.assertEqual(report['summary']['suspect_sequences'], 0)

    def test_black_or_missing_frame_makes_sequence_suspect(self):
        a = save(os.path.join(self.dir, 'a.png'), scene(20))
        b = save(os.path.join(self.dir, 'b.png'), np.zeros((H, W, 3), np.float32))
        report = fe.analyse([a, b, os.path.join(self.dir, 'gone.png')])
        seq = report['sequences']['frames']
        self.assertEqual(seq['verdict'], 'SUSPECT')
        self.assertEqual(seq['unusable'], ['b', 'gone'])
        self.assertEqual(report['frames'][2]['flags'], ['MISSING'])

    def test_witness_result_groups_frames_by_scenario(self):
        f = [save(os.path.join(self.dir, n + '.png'), scene(30 + i)) for i, n in enumerate(['idle', 'muzzle', 'r1', 'r2'])]
        doc = {'Schema': 'iw7.bo3wpn-visual/1', 'Frames': [
            {'Scenario': 'bo3wpn-fire', 'Step': 'idle', 'Path': f[0]},
            {'Scenario': 'bo3wpn-fire', 'Step': 'muzzle', 'Path': f[1]},
            {'Scenario': 'bo3wpn-reload', 'Step': 'reload-a', 'Path': f[2]},
            {'Scenario': 'bo3wpn-reload', 'Step': 'reload-b', 'Path': f[2]}]}
        result = os.path.join(self.dir, 'result.local.json')
        with open(result, 'w', encoding='utf-8') as fh:
            json.dump(doc, fh)
        report = fe.analyse([result])
        self.assertEqual(report['sequences']['bo3wpn-fire']['verdict'], 'USABLE')
        self.assertEqual(report['sequences']['bo3wpn-reload']['verdict'], 'SUSPECT')
        self.assertIn('IDENTICAL_TO_PREVIOUS', report['frames'][3]['flags'])
        # Comparisons never cross a scenario boundary.
        self.assertNotIn('vs_previous', report['frames'][2])

    def test_vision_index_input(self):
        p = save(os.path.join(self.dir, 'hall_0.png'), scene(40))
        index = os.path.join(self.dir, 'index.json')
        with open(index, 'w', encoding='utf-8') as fh:
            json.dump([{'name': 'hall_0', 'zone': 'hall', 'full': p, 'quadrants': []}], fh)
        report = fe.analyse([index])
        self.assertEqual(report['frames'][0]['sequence'], 'hall')

    def test_unknown_inputs_are_refused(self):
        bad = os.path.join(self.dir, 'other.json')
        with open(bad, 'w', encoding='utf-8') as fh:
            json.dump({'x': 1}, fh)
        with self.assertRaises(ValueError):
            fe.collect([bad])
        with self.assertRaises(ValueError):
            fe.collect([os.path.join(self.dir, 'notes.txt')])


class Cli(unittest.TestCase):
    def test_diff_cli_writes_mask_and_json(self):
        with tempfile.TemporaryDirectory() as d:
            a = scene(50)
            b = a.copy()
            b[0:10, 0:10] = 1.0
            pa, pb = save(os.path.join(d, 'a.png'), a), save(os.path.join(d, 'b.png'), b)
            mask = os.path.join(d, 'mask.png')
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                code = fe.main(['diff', pa, pb, '--mask', mask])
            self.assertEqual(code, 0)
            out = json.loads(buf.getvalue())
            self.assertEqual(out['schema'], fe.SCHEMA)
            self.assertEqual(out['change_bbox'], [0, 0, 10, 10])
            m = np.asarray(Image.open(mask))
            self.assertEqual(int((m > 0).sum()), 100)

    def test_frames_cli_exit_code_reports_suspect_evidence(self):
        with tempfile.TemporaryDirectory() as d:
            frame = scene(60)
            save(os.path.join(d, 'a.png'), frame)
            save(os.path.join(d, 'b.png'), frame)
            report = os.path.join(d, 'report.json')
            with contextlib.redirect_stdout(io.StringIO()):
                code = fe.main(['frames', d, '--json', report])
            self.assertEqual(code, 1)
            with open(report, encoding='utf-8') as fh:
                self.assertEqual(json.load(fh)['schema'], fe.SCHEMA)
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(fe.main(['frames', os.path.join(d, 'absent.txt')]), 2)


if __name__ == '__main__':
    sys.exit(0 if unittest.main(exit=False).result.wasSuccessful() else 1)
