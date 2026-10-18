import importlib.util
import json
import hashlib
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
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

    def finite_source(self):
        # Exercise the real policy with a test-local row, not a duplicate of the
        # Asset owner's large header. The production row is asserted separately.
        owner, relative, _, _, _ = w._FINITE_SCHEMA_SOURCE
        raw = b'// SYNTHETIC SOURCE ONLY\n' + b' ' * w.MAX_FILE + b'\n'
        path = self.repo / relative
        path.parent.mkdir(parents=True)
        path.write_bytes(raw)
        (self.repo / '.gitattributes').write_bytes(b'* text eol=lf\n')
        self.contract.update(id=owner, exports=[relative, 'hello.py'])
        revision = self.commit()
        blob = self.run_git('rev-parse', revision + ':' + relative)
        return (owner, relative, blob, len(raw), hashlib.sha256(raw).hexdigest()), raw, revision

    def boundary(self):
        spec = importlib.util.spec_from_file_location('boundary', Path(__file__).parents[2] / 'ops/check_boundaries.py')
        module = importlib.util.module_from_spec(spec)
        with mock.patch.dict(sys.modules, source_workspace=w):
            spec.loader.exec_module(module)
        return module

    def test_finite_schema_literal_and_strict_metadata(self):
        row = ('x64-zt-extensions', 'tools-source/asset-bridge/weapon-export/native_pair_body_schema.hpp',
               '8eac8f40be1a306f48d30c0bdfdcbfdc45e0f666', 1073140,
               'dbedd4632d8bb20686c8c1355d4b0200fc2c6149ba141897007f41252f555b75')
        self.assertEqual(w._FINITE_SCHEMA_SOURCE, row)
        self.assertEqual((w.MAX_FILE, w.MAX_TOTAL), (1048576, 33554432))
        self.assertTrue(w.check_source_metadata(*row[:4], sha256=row[4]))
        class StringAlias(str):
            pass
        mutants = [(0, 'other'), (0, StringAlias(row[0])), (1, row[1].upper()),
                   (2, row[2].upper()), (2, None), (3, True), (3, str(row[3])),
                   (3, 0), (3, row[3]-1), (4, None), (4, row[4].upper())]
        for index, value in mutants:
            changed = list(row)
            changed[index] = value
            with self.subTest(index=index, value=value), self.assertRaisesRegex(ValueError, 'identity differs'):
                w.check_source_metadata(*changed[:4], sha256=changed[4])
        with self.assertRaisesRegex(ValueError, 'identity differs'):
            w.check_source_metadata(row[0], row[1].upper(), row[2], 1)

    def test_finite_schema_raw_hash_precedes_utf8_and_generic_cap_remains(self):
        owner, path, blob, size, _ = w._FINITE_SCHEMA_SOURCE
        with self.assertRaisesRegex(ValueError, 'Source bytes differ'):
            w.check_source_bytes(owner, path, blob, b'\xff' * size)
        raw = b'a' * w.MAX_FILE
        self.assertEqual(w.check_source_bytes('fixture', 'small.py', 'a'*40, raw), hashlib.sha256(raw).hexdigest())
        with self.assertRaisesRegex(ValueError, 'Oversized'):
            w.check_source_bytes('fixture', 'small.py', 'a'*40, raw+b'a')
        with self.assertRaisesRegex(ValueError, 'Binary'):
            w.check_source_bytes('fixture', 'small.py', 'a'*40, b'a\x00')
        with self.assertRaises(UnicodeDecodeError):
            w.check_source_bytes('fixture', 'small.py', 'a'*40, b'\xff')

    def test_finite_schema_synthetic_boundary_prepare_archive_roundtrip(self):
        row, raw, revision = self.finite_source()
        with mock.patch.object(w, '_FINITE_SCHEMA_SOURCE', row):
            self.boundary().check(self.repo)
            stage = self.root / 'finite stage'
            result = w.prepare(self.repo, revision, {}, stage)
            self.assertFalse(result['runtime_qualified'])
            self.assertEqual((stage / row[1]).read_bytes(), raw)
            # A consumer package contributes these same exact owned rows.
            result['product'] = 'consumer'
            (stage / 'source-workspace.json').write_text(json.dumps(result))
            archive = self.root / 'finite.zip'
            lock = w.pack_dependencies(stage, archive)
            self.contract.update(id='consumer', exports=[], dependencies=[
                dict(id=row[0], revision=revision, files=[row[1], 'hello.py'])])
            (self.repo / 'dependency-package.json').write_text(json.dumps(lock))
            consumer_revision = self.commit()
            restored = self.root / 'restored finite source'
            w.prepare(self.repo, consumer_revision, {}, restored, package=archive)
            self.assertEqual((restored / row[1]).read_bytes(), raw)
            self.assertFalse(w.verify(restored)['runtime_qualified'])

    def test_finite_schema_prepare_checks_metadata_before_filtered_read(self):
        row, _, _ = self.finite_source()
        self.contract['id'] = 'wrong-owner'
        revision = self.commit()
        original = subprocess.check_output
        with mock.patch.object(w, '_FINITE_SCHEMA_SOURCE', row), mock.patch.object(
                w.subprocess, 'check_output', wraps=original) as calls:
            with self.assertRaisesRegex(ValueError, 'identity differs'):
                w.prepare(self.repo, revision, {}, self.root / 'refused owner')
            self.assertFalse(any('--filters' in call.args[0] for call in calls.call_args_list))
        self.assertFalse((self.root / 'refused owner').exists())

    def test_finite_schema_filtered_line_ending_drift_refused_before_output(self):
        row, _, _ = self.finite_source()
        (self.repo / '.gitattributes').write_bytes(b'* text eol=lf\n' + row[1].encode() + b' text eol=crlf\n')
        revision = self.commit()
        self.assertEqual(self.run_git('rev-parse', revision + ':' + row[1]), row[2])
        with mock.patch.object(w, '_FINITE_SCHEMA_SOURCE', row), self.assertRaisesRegex(ValueError, 'identity differs'):
            w.prepare(self.repo, revision, {}, self.root / 'refused filtered')
        self.assertFalse((self.root / 'refused filtered').exists())

    def test_finite_schema_archive_metadata_precedes_member_read(self):
        row, raw, _ = self.finite_source()
        base = dict(owner=row[0], path=row[1], blob=row[2], bytes=row[3], sha256=row[4], commit='a'*40)
        mutants = [('owner', 'other'), ('path', row[1].upper()), ('blob', 'b'*40),
                   ('bytes', True), ('bytes', 1), ('sha256', None), ('sha256', row[4].upper())]
        original_read = zipfile.ZipFile.read
        for index, (key, value) in enumerate(mutants):
            entry = dict(base, **{key: value})
            archive = self.root / ('bad metadata ' + str(index) + '.zip')
            with zipfile.ZipFile(archive, 'w') as package:
                package.writestr('dependencies.json', json.dumps(dict(schema='iw7.source-dependencies/1', files=[entry])))
                package.writestr(entry['path'], raw)
            lock = dict(bytes=archive.stat().st_size, sha256=hashlib.sha256(archive.read_bytes()).hexdigest())
            product = dict(dependencies=[dict(id=entry['owner'], revision=entry['commit'], files=[entry['path']])])
            reads = []
            def read(package, name, *args, **kwargs):
                reads.append(name.filename if isinstance(name, zipfile.ZipInfo) else name)
                return original_read(package, name, *args, **kwargs)
            with self.subTest(key=key), mock.patch.object(w, '_FINITE_SCHEMA_SOURCE', row), mock.patch.object(
                    w, 'git', return_value=json.dumps(lock)), mock.patch.object(zipfile.ZipFile, 'read', read):
                with self.assertRaisesRegex(ValueError, 'identity differs'):
                    w.read_dependencies(self.repo, 'b'*40, product, archive)
            self.assertEqual(reads, ['dependencies.json'])

    def test_finite_schema_pack_rechecks_metadata_and_actual_bytes_after_verify(self):
        row, raw, revision = self.finite_source()
        original_verify, original_read = w.verify, Path.read_bytes
        with mock.patch.object(w, '_FINITE_SCHEMA_SOURCE', row):
            for change in ('metadata', 'length', 'bytes'):
                stage = self.root / ('pack recheck ' + change)
                manifest = w.prepare(self.repo, revision, {}, stage)
                manifest['product'] = 'consumer'
                (stage / 'source-workspace.json').write_text(json.dumps(manifest))
                reads = []
                def read(path):
                    if path == stage / row[1]:
                        reads.append(path)
                    return original_read(path)
                def verify_then_change(path):
                    data = original_verify(path)
                    entry = next(e for e in data['files'] if e['path'] == row[1])
                    if change == 'metadata':
                        entry['sha256'] = '0'*64
                    else:
                        (stage / row[1]).write_bytes(raw[:-1] if change == 'length' else b'!' + raw[1:])
                    return data
                with self.subTest(change=change), mock.patch.object(w, 'verify', verify_then_change), mock.patch.object(Path, 'read_bytes', read):
                    with self.assertRaises(ValueError):
                        w.pack_dependencies(stage, self.root / ('refused ' + change + '.zip'))
                self.assertEqual(len(reads), 2 if change == 'bytes' else 1)

    def test_finite_schema_boundary_preserves_other_ownership_and_payload_guards(self):
        self.commit()
        boundary = self.boundary()
        boundary.check(self.repo)
        (self.repo / 'migration').mkdir()
        foreign = self.repo / 'migration/foreign-paths.json'
        foreign.write_text(json.dumps(['hello.py']))
        with self.assertRaisesRegex(ValueError, 'Another product owns'):
            boundary.check(self.repo)
        foreign.unlink()
        (self.repo / 'extra.py').write_bytes(b'# unclassified Source\n')
        self.run_git('add', 'extra.py')
        with self.assertRaisesRegex(ValueError, 'Unclassified'):
            boundary.check(self.repo)
        self.contract['exports'].append('extra.py')
        self.commit()
        (self.repo / 'extra.py').write_bytes(b'x' * (w.MAX_FILE + 1))
        with self.assertRaisesRegex(ValueError, 'Oversized'):
            boundary.check(self.repo)
        (self.repo / 'extra.py').write_bytes(b'x\x00')
        with self.assertRaisesRegex(ValueError, 'Binary'):
            boundary.check(self.repo)

    def test_finite_schema_manifest_and_total_caps_remain(self):
        revision = self.commit()
        stage = self.root / 'budget stage'
        manifest = w.prepare(self.repo, revision, {}, stage)
        # A smaller test-local total proves the unchanged cumulative guard
        # without creating a 32MiB payload. Production constants are pinned above.
        with mock.patch.object(w, 'MAX_TOTAL', manifest['bytes'] - 1):
            with self.assertRaisesRegex(ValueError, 'byte budget exceeded'):
                w.prepare(self.repo, revision, {}, self.root / 'over total')
            with self.assertRaisesRegex(ValueError, 'total differs'):
                w.verify(stage)
        self.assertFalse((self.root / 'over total').exists())
        manifest['product'] = 'consumer'
        manifest['files'][0]['unused_metadata'] = 'x' * w.MAX_FILE
        (stage / 'source-workspace.json').write_text(json.dumps(manifest))
        packed = self.root / 'oversized manifest.zip'
        with self.assertRaisesRegex(ValueError, 'manifest too large'):
            w.pack_dependencies(stage, packed)
        self.assertFalse(packed.exists())
        archive = self.root / 'oversized imported manifest.zip'
        with zipfile.ZipFile(archive, 'w') as package:
            package.writestr('dependencies.json', b' ' * (w.MAX_FILE + 1))
        lock = dict(bytes=archive.stat().st_size, sha256=hashlib.sha256(archive.read_bytes()).hexdigest())
        with mock.patch.object(w, 'git', return_value=json.dumps(lock)), self.assertRaisesRegex(ValueError, 'manifest too large'):
            w.read_dependencies(self.repo, revision, dict(dependencies=[]), archive)

if __name__ == '__main__':
    unittest.main()
