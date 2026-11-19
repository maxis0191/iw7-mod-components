"""Tests for the scheduling of ops/check_product.py (run_checks): parallel, serial, order, failure, exceptions."""
import importlib.util
import os
import sys
import threading
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, 'ops'))
spec = importlib.util.spec_from_file_location('check_product', os.path.join(ROOT, 'ops', 'check_product.py'))
cp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cp)


class Recorder:
    def __init__(self, seconds=1.0, fail=(), raises=()):
        self.seconds = seconds
        self.fail = set(fail)
        self.raises = set(raises)
        self.lock = threading.Lock()
        self.spans = {}

    def __call__(self, check):
        start = time.monotonic()
        if check['id'] in self.raises:
            with self.lock:
                self.spans[check['id']] = (start, start)
            raise RuntimeError('boom ' + check['id'])
        time.sleep(self.seconds)
        end = time.monotonic()
        with self.lock:
            self.spans[check['id']] = (start, end)
        return dict(id=check['id'], command=[], exit_code=1 if check['id'] in self.fail else 0,
                    seconds=end - start, log=check['id'] + '.log')

    def overlap(self, a, b):
        (s1, e1), (s2, e2) = self.spans[a], self.spans[b]
        return s1 < e2 and s2 < e1


def checks(*ids, serial=()):
    return [dict(id=i, command=['x'], serial=True) if i in serial else dict(id=i, command=['x']) for i in ids]


class ScheduleTest(unittest.TestCase):
    def test_parallel_is_faster(self):
        rec = Recorder(1.0)
        started = time.monotonic()
        rows = cp.run_checks(checks(*'abcdef'), 3, rec)
        wall = time.monotonic() - started
        self.assertLess(wall, 4.0)
        self.assertGreaterEqual(wall, 2.0)
        self.assertEqual([r['id'] for r in rows], list('abcdef'))

    def test_serial_never_overlaps(self):
        rec = Recorder(0.4)
        cs = checks('p1', 's1', 'p2', 's2', 'p3', 'p4', serial=('s1', 's2'))
        cp.run_checks(cs, 4, rec)
        for s in ('s1', 's2'):
            for other in ('p1', 'p2', 'p3', 'p4', 's1', 's2'):
                if other != s:
                    self.assertFalse(rec.overlap(s, other), (s, other))
        self.assertTrue(rec.overlap('p1', 'p2'))

    def test_failure_row_and_order(self):
        rec = Recorder(0.1, fail=('b',))
        rows = cp.run_checks(checks('a', 'b', 'c', 'd'), 4, rec)
        self.assertEqual([r['id'] for r in rows], list('abcd'))
        self.assertEqual([r['exit_code'] for r in rows], [0, 1, 0, 0])

    def test_order_whatever_the_finishing_order(self):
        def run_one(check):
            time.sleep({'a': 0.5, 'b': 0.3, 'c': 0.1}[check['id']])
            return dict(id=check['id'], command=[], exit_code=0, seconds=0, log='x')
        finished = []
        rows = cp.run_checks(checks('a', 'b', 'c'), 3, run_one, on_end=lambda c, r: finished.append(c['id']))
        self.assertEqual(finished, ['c', 'b', 'a'])
        self.assertEqual([r['id'] for r in rows], ['a', 'b', 'c'])

    def test_jobs_one_is_strictly_sequential(self):
        rec = Recorder(0.2)
        cs = checks('a', 's', 'b', 'c', serial=('s',))
        cp.run_checks(cs, 1, rec)
        ids = ['a', 'b', 'c', 's']
        for i, x in enumerate(ids):
            for y in ids[i + 1:]:
                self.assertFalse(rec.overlap(x, y), (x, y))

    def test_exception_is_exit_125(self):
        rec = Recorder(0.1, raises=('b',))
        rows = cp.run_checks(checks('a', 'b', 'c'), 2, rec)
        self.assertEqual([r['exit_code'] for r in rows], [0, 125, 0])
        self.assertIn('boom b', rows[1]['error'])

    def test_default_jobs(self):
        old = os.environ.pop('IW7_CHECK_JOBS', None)
        try:
            self.assertGreaterEqual(cp.default_jobs(), 2)
            self.assertLessEqual(cp.default_jobs(), 8)
            os.environ['IW7_CHECK_JOBS'] = '3'
            self.assertEqual(cp.default_jobs(), 3)
        finally:
            os.environ.pop('IW7_CHECK_JOBS', None)
            if old is not None:
                os.environ['IW7_CHECK_JOBS'] = old


if __name__ == '__main__':
    unittest.main()
