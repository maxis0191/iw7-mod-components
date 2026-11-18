"""The write census diff (ops/engine/census_diff.py) classifies writers of two censuses on synthetic files."""
import os
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
TOOL = os.path.join(ROOT, 'ops', 'engine', 'census_diff.py')
HEAD = '# census agents=%d faults=1 outside=0 released_pages=0 sites=3 lost=0\n# region 0 cg base=0x1000 size=0x1000\nregion\trip\tcount\tmain\tdistinct\tmin\tmax\tstride\tsample\n'


def census(agents, lines):
    f = tempfile.NamedTemporaryFile('w', suffix='.tsv', delete=False)
    f.write(HEAD % agents + ''.join(lines))
    f.close()
    return f.name


class Diff(unittest.TestCase):
    def test_classes(self):
        small = census(24, ['cg\t0x100\t10\t10\t42\t0x70974\t0x72814\t0xC0\t0x70974\n', 'cg\t0x200\t5\t5\t3\t0x10\t0x20\t0x8\t0x10\n', 'cg\t0x300\t7\t7\t1\t0x40\t0x40\t0x0\t0x40\n'])
        big = census(264, ['cg\t0x100\t900\t900\t282\t0x70974\t0x7DC34\t0xC0\t0x70974\n', 'cg\t0x200\t5\t5\t3\t0x10\t0x20\t0x8\t0x10\n', 'cg\t0x400\t50\t50\t40\t0x1000\t0x2000\t0x20\t0x1000\n'])
        try:
            out = subprocess.run([sys.executable, '-I', '-B', TOOL, small, big, '--db', os.path.join(tempfile.gettempdir(), 'none.sqlite')], capture_output=True, text=True, check=True).stdout
        finally:
            os.unlink(small); os.unlink(big)
        lines = {l.split('\t')[2]: l for l in out.splitlines() if l.startswith(('only_big', 'reaches', 'only_small'))}
        self.assertTrue(lines['0x100'].startswith('reaches') and lines['0x100'].endswith('TABLE?'))
        self.assertTrue(lines['0x400'].startswith('only_big') and lines['0x400'].endswith('TABLE?'))
        self.assertTrue(lines['0x300'].startswith('only_small'))
        self.assertNotIn('0x200', lines)
        self.assertIn('# totals: only_big 1, reaches 1, only_small 1, same 1', out)


if __name__ == '__main__':
    unittest.main()
