"""ops/compile_check_exports.py: the export and build-list gate of the fast compile check (ops/Compile-Check.ps1)."""
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
sys.path.insert(0, os.path.join(ROOT, 'ops'))
import compile_check_exports as cce  # noqa: E402


def git(repo, *args):
    subprocess.check_call(['git', '-C', repo, '-c', 'user.name=t', '-c', 'user.email=t@t', *args], stdout=subprocess.DEVNULL)


class Closure(unittest.TestCase):
    def test_agent_capacity_closure_is_ok(self):
        if not os.path.exists(os.path.join(ROOT, 'product.json')):
            self.skipTest('a prepared source workspace has no product.json; the repository run (checks.ps1 boundary gate) covers it')
        problems, files = cce.check(ROOT, ['src/native/agent_capacity.cpp'])
        self.assertEqual(problems, [])
        for name in ('agent_capacity.cpp', 'agent_capacity.hpp', 'agent_capacity_caves_wide.inc', 'agent_capacity_frame_cave.inc'):
            self.assertIn(name, files)

    def test_unexported_and_unlisted_include_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            os.makedirs(os.path.join(tmp, 'src', 'native'))
            os.makedirs(os.path.join(tmp, 'ops'))
            with open(os.path.join(tmp, 'product.json'), 'w') as f:
                f.write('{"exports": ["src/native/a.cpp", "ops/Build-Voice.ps1"]}')
            with open(os.path.join(tmp, 'ops', 'Build-Voice.ps1'), 'w') as f:
                f.write("$x = @('a.cpp')")
            with open(os.path.join(tmp, 'src', 'native', 'a.cpp'), 'w') as f:
                f.write('#include <vector>\n#include "b.inc"\n#include "../native/c.hpp"\n')
            with open(os.path.join(tmp, 'src', 'native', 'b.inc'), 'w') as f:
                f.write('#include "c.hpp"\n')
            with open(os.path.join(tmp, 'src', 'native', 'c.hpp'), 'w') as f:
                f.write('')
            subprocess.check_call(['git', 'init', '-q', tmp])
            problems, files = cce.check(tmp, ['src/native/a.cpp'])
            self.assertEqual(sorted(files), ['a.cpp', 'b.inc', 'c.hpp'])
            text = '\n'.join(problems)
            for name in ('b.inc', 'c.hpp'):
                self.assertIn('src/native/%s: not in product.json "exports"' % name, text)
                self.assertIn('src/native/%s: not listed in ops/Build-Voice.ps1' % name, text)
            self.assertNotIn('a.cpp:', text)

    def test_missing_include_file_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            os.makedirs(os.path.join(tmp, 'src', 'native'))
            os.makedirs(os.path.join(tmp, 'ops'))
            with open(os.path.join(tmp, 'product.json'), 'w') as f:
                f.write('{"exports": []}')
            with open(os.path.join(tmp, 'ops', 'Build-Voice.ps1'), 'w') as f:
                f.write('')
            subprocess.check_call(['git', 'init', '-q', tmp])
            problems, _ = cce.check(tmp, ['src/native/none.cpp'])
            self.assertTrue(any('does not exist' in p for p in problems))


if __name__ == '__main__':
    unittest.main()
