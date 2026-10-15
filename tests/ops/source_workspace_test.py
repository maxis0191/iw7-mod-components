import importlib.util
import json
import hashlib
from pathlib import Path
import subprocess
import tempfile
import unittest
import zipfile

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

    def test_pinned_attributes_survive_sparse_checkout_and_local_autocrlf(self):
        self.run_git('config', 'core.autocrlf', 'true')  # Fixture-local only.
        (self.repo / '.gitattributes').write_bytes(b'*.cpp text eol=lf\n*.ps1 text eol=crlf\n')
        source = b'// SYNTHETIC SOURCE ONLY\nint fixture = 1;\n'
        script = b'# SYNTHETIC SOURCE ONLY\nWrite-Output fixture\n'
        (self.repo / 'writer.cpp').write_bytes(source)
        (self.repo / 'runner.ps1').write_bytes(script)
        self.contract['exports'] += ['writer.cpp', 'runner.ps1']
        sha = self.commit()
        self.run_git('sparse-checkout', 'set', '--no-cone', '/product.json', '/hello.py', '/writer.cpp', '/runner.ps1')
        self.assertFalse((self.repo / '.gitattributes').exists())
        self.assertEqual(self.run_git('status', '--porcelain'), '')
        output = self.root / 'pinned attribute export'
        result = w.prepare(self.repo, sha, {}, output)
        self.assertEqual((output / 'writer.cpp').read_bytes(), source)
        self.assertEqual((output / 'runner.ps1').read_bytes(), script.replace(b'\n', b'\r\n'))
        row = next(item for item in result['files'] if item['path'] == 'writer.cpp')
        self.assertEqual(row['blob'], self.run_git('rev-parse', sha + ':writer.cpp'))
        self.assertEqual(row['sha256'], hashlib.sha256(source).hexdigest())
        w.verify(output)

    def test_external_owner_uses_its_own_pinned_attribute_tree(self):
        dep = self.root / 'sparse external owner'
        dep.mkdir()
        def dep_git(*args):
            return subprocess.check_output(['git', '-C', str(dep), *args], text=True).strip()
        dep_git('init', '-q')
        dep_git('config', 'core.autocrlf', 'true')  # Fixture-local only.
        (dep / '.gitattributes').write_bytes(b'*.cpp text eol=lf\n')
        source = b'// EXTERNAL SYNTHETIC SOURCE\nint external_fixture = 2;\n'
        (dep / 'writer.cpp').write_bytes(source)
        dep_git('add', '.')
        dep_git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                '-c', 'commit.gpgsign=false', 'commit', '-qm', 'External source attributes')
        revision = dep_git('rev-parse', 'HEAD')
        dep_git('sparse-checkout', 'set', '--no-cone', '/writer.cpp')
        self.assertFalse((dep / '.gitattributes').exists())
        self.contract['dependencies'] = [dict(id='external', revision=revision, files=['writer.cpp'])]
        project_revision = self.commit()
        self.assertNotEqual(project_revision, revision)
        output = self.root / 'external filtered source'
        result = w.prepare(self.repo, project_revision, {'external': dep}, output)
        self.assertEqual((output / 'writer.cpp').read_bytes(), source)
        row = next(item for item in result['files'] if item['path'] == 'writer.cpp')
        self.assertEqual((row['owner'], row['commit']), ('external', revision))
        self.assertEqual(row['sha256'], hashlib.sha256(source).hexdigest())

    def test_identity_refuses_parent_git_revision(self):
        self.commit()
        child = self.repo / 'nested'
        child.mkdir()
        helper = Path(__file__).parents[2] / 'ops/Get-SourceIdentity.ps1'
        run = subprocess.run(['pwsh', '-NoProfile', '-File', str(helper), '-Root', str(child)], capture_output=True)
        self.assertNotEqual(run.returncode, 0)

    def test_identity_uses_composition_product_revision(self):
        for name in ('Get-SourceIdentity.ps1', 'source_workspace.py'):
            target = self.repo / 'ops' / name
            target.parent.mkdir(exist_ok=True)
            target.write_bytes((Path(__file__).parents[2] / 'ops' / name).read_bytes())
            self.contract['exports'].append('ops/' + name)
        sha = self.commit()
        output = self.root / 'source package identity'
        w.prepare(self.repo, sha, {}, output)
        command = "& $args[0] -Root $args[1] | ConvertTo-Json -Depth 5"
        # Use a script adapter so paths are literal arguments, never code.
        adapter = self.root / 'identity.ps1'
        adapter.write_text(command)
        raw = subprocess.check_output(['pwsh', '-NoProfile', '-File', str(adapter), str(output/'ops/Get-SourceIdentity.ps1'), str(output)], text=True)
        identity = json.loads(raw)
        self.assertEqual(identity['Commit'], sha)
        self.assertEqual(identity['Revisions'], {'fixture':sha})
        self.assertFalse(identity['Dirty'])
        self.assertEqual(len(identity['ReceiptSHA256']), 64)

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

    def dependency_archive(self):
        dep = self.root / 'dependency source'
        dep.mkdir()
        (dep / '.gitattributes').write_bytes(b'* text eol=lf\n')
        (dep / 'helper.py').write_bytes(b'print("dependency")\n')
        for args in [('init','-q'), ('add','.'), ('-c','user.name=Fixture','-c','user.email=fixture@example.invalid','-c','commit.gpgsign=false','commit','-qm','Dependency fixture')]:
            subprocess.run(['git','-C',str(dep),*args], check=True, capture_output=True)
        revision = w.git(dep, 'rev-parse', 'HEAD')
        self.contract['dependencies'] = [dict(id='dependency', revision=revision, files=['helper.py'])]
        commit = self.commit()
        stage = self.root / 'qualified inputs'
        w.prepare(self.repo, commit, {'dependency': dep}, stage)
        archive = self.root / 'dependencies.zip'
        lock = w.pack_dependencies(stage, archive)
        (self.repo / 'dependency-package.json').write_text(json.dumps(lock))
        commit = self.commit()
        return archive, lock, commit

    def test_dependency_archive_restores_exact_sources_without_credentials(self):
        archive, _, commit = self.dependency_archive()
        out = self.root / 'from archive'
        result = w.prepare(self.repo, commit, {}, out, package=archive)
        self.assertEqual((out/'helper.py').read_bytes(), b'print("dependency")\n')
        self.assertEqual(len(result['files']), 2)
        self.assertFalse(result['runtime_qualified'])

    def test_dependency_archive_corruption_is_refused_before_output(self):
        archive, _, commit = self.dependency_archive()
        raw = bytearray(archive.read_bytes()); raw[-1] ^= 1; archive.write_bytes(raw)
        with self.assertRaisesRegex(ValueError, 'archive digest differs'):
            w.prepare(self.repo, commit, {}, self.root/'rejected', package=archive)
        self.assertFalse((self.root/'rejected').exists())

    def test_correct_archive_digest_does_not_hide_missing_declared_sources(self):
        archive, lock, _ = self.dependency_archive()
        with zipfile.ZipFile(archive, 'w') as package:
            package.writestr('dependencies.json', json.dumps(dict(schema='iw7.source-dependencies/1',files=[])))
        lock.update(bytes=archive.stat().st_size, sha256=hashlib.sha256(archive.read_bytes()).hexdigest())
        (self.repo/'dependency-package.json').write_text(json.dumps(lock))
        commit = self.commit()
        with self.assertRaisesRegex(ValueError, 'Incomplete'):
            w.prepare(self.repo, commit, {}, self.root/'rejected', package=archive)
        self.assertFalse((self.root/'rejected').exists())

if __name__ == '__main__':
    unittest.main()
