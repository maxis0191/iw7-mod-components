"""ops/build/Test-BuildInputs.py: a build needs a file that is not in the prepared workspace -> refused before any build."""
import json
import os
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TOOL = os.path.join(ROOT, 'ops', 'build', 'Test-BuildInputs.py')


def run(root):
    return subprocess.run([sys.executable, '-B', TOOL, root], capture_output=True, text=True)


class BuildInputsTest(unittest.TestCase):
    def make(self, listed):
        d = tempfile.mkdtemp()
        os.makedirs(os.path.join(d, 'ops', 'sub'))
        with open(os.path.join(d, 'ops', 'Build-Voice.ps1'), 'w') as f:
            f.write('. "$PSScriptRoot/Apply-A.ps1"\n$x = "$repo/src/native/b.cpp"\n')
        with open(os.path.join(d, 'ops', 'Apply-A.ps1'), 'w') as f:
            f.write('. "$PSScriptRoot/sub/Core.ps1"\n')
        with open(os.path.join(d, 'ops', 'sub', 'Core.ps1'), 'w') as f:
            f.write('# nothing\n')
        files = [{'path': p} for p in listed]
        with open(os.path.join(d, 'source-workspace.json'), 'w') as f:
            json.dump({'files': files}, f)
        return d

    def test_everything_listed_passes(self):
        d = self.make(['ops/Build-Voice.ps1', 'ops/Apply-A.ps1', 'ops/sub/Core.ps1', 'src/native/b.cpp'])
        r = run(d)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_a_missing_file_fails_and_is_named(self):
        d = self.make(['ops/Build-Voice.ps1', 'ops/Apply-A.ps1', 'src/native/b.cpp'])
        r = run(d)
        self.assertEqual(r.returncode, 1)
        self.assertIn('ops/sub/Core.ps1', r.stdout)

    def test_a_missing_native_source_fails(self):
        d = self.make(['ops/Build-Voice.ps1', 'ops/Apply-A.ps1', 'ops/sub/Core.ps1'])
        r = run(d)
        self.assertEqual(r.returncode, 1)
        self.assertIn('src/native/b.cpp', r.stdout)

    def test_the_real_workspace_when_the_judge_runs_in_one(self):
        if not os.path.isfile(os.path.join(ROOT, 'source-workspace.json')):
            self.skipTest('not a prepared workspace')
        r = run(ROOT)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)


if __name__ == '__main__':
    unittest.main()
