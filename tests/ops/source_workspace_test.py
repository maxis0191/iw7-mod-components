import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('workspace', Path(__file__).parents[2] / 'ops/source_workspace.py')
w = importlib.util.module_from_spec(spec)
spec.loader.exec_module(w)

class WorkspaceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='iw7 source paths ')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / 'product source'
        self.repo.mkdir()
        self.run_git('init', '-q')
        self.run_git('config', 'user.name', 'Synthetic fixture')
        self.run_git('config', 'user.email', 'fixture@example.invalid')
        (self.repo / 'hello.py').write_text('print("synthetic fixture")\n')
        self.contract = dict(schema='iw7.product/1', id='fixture', exports=['hello.py'], dependencies=[])

    def run_git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.repo), *args], text=True).strip()

    def commit(self):
        (self.repo / 'product.json').write_text(json.dumps(self.contract))
        self.run_git('add', '.')
        self.run_git('-c', 'commit.gpgsign=false', 'commit', '-qm', 'Synthetic inputs')
        return self.run_git('rev-parse', 'HEAD')

    def test_spaces_and_byte_identity(self):
        sha = self.commit()
        output = self.root / 'generated package with spaces'
        result = w.prepare(self.repo, sha, {}, output)
        self.assertFalse(result['runtime_qualified'])
        self.assertEqual((output / 'hello.py').read_bytes(), (self.repo / 'hello.py').read_bytes())
        self.assertEqual(w.verify(output)['revisions'], {'fixture': sha})

    def test_dirty_source_refused_before_output(self):
        sha = self.commit()
        (self.repo / 'hello.py').write_text('changed input\n')
        with self.assertRaisesRegex(ValueError, 'Dirty source'):
            w.prepare(self.repo, sha, {}, self.root / 'out')
        self.assertFalse((self.root / 'out').exists())

    def test_missing_dependency_refused(self):
        self.contract['dependencies'] = [dict(id='missing', revision='a'*40, files=['dep.py'])]
        sha = self.commit()
        with self.assertRaisesRegex(ValueError, 'Missing dependency'):
            w.prepare(self.repo, sha, {}, self.root / 'out')

    def test_different_dependency_revision_refused(self):
        self.contract['dependencies'] = [dict(id='different', revision='a'*40, files=['dep.py'])]
        sha = self.commit()
        with self.assertRaisesRegex(ValueError, 'revision differs'):
            w.prepare(self.repo, sha, {'different':self.repo}, self.root / 'out')

    def test_incomplete_checkout_refused(self):
        self.contract['exports'].append('missing.py')
        sha = self.commit()
        with self.assertRaisesRegex(ValueError, 'absent declared'):
            w.prepare(self.repo, sha, {}, self.root / 'out')

    def test_forbidden_binary_refused(self):
        (self.repo / 'candidate.exe').write_text('synthetic')
        self.contract['exports'].append('candidate.exe')
        sha = self.commit()
        with self.assertRaisesRegex(ValueError, 'payload refused'):
            w.prepare(self.repo, sha, {}, self.root / 'out')

    def test_existing_output_preserved(self):
        sha = self.commit()
        out = self.root / 'out'
        out.mkdir()
        (out / 'important.txt').write_text('preserve')
        with self.assertRaisesRegex(ValueError, 'Fresh output'):
            w.prepare(self.repo, sha, {}, out)
        self.assertEqual((out / 'important.txt').read_text(), 'preserve')

    def test_duplicate_owner_refused(self):
        self.contract['exports'].append('hello.py')
        sha = self.commit()
        with self.assertRaisesRegex(ValueError, 'Multiple canonical owners'):
            w.prepare(self.repo, sha, {}, self.root / 'out')

    def test_path_escape_refused(self):
        for value in ('../hello.py', 'C:/hello.py', '/hello.py', 'a/../hello.py', 'a\\hello.py', 'runtime/hello.py'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                w.safe_relative(value)

    def test_corrupt_or_incomplete_package_fails_verification(self):
        sha = self.commit()
        out = self.root / 'out'
        w.prepare(self.repo, sha, {}, out)
        (out / 'hello.py').write_text('corruption')
        with self.assertRaisesRegex(ValueError, 'Generated source changed'):
            w.verify(out)
        (out / 'hello.py').unlink()
        with self.assertRaises(FileNotFoundError):
            w.verify(out)

if __name__ == '__main__':
    unittest.main()
