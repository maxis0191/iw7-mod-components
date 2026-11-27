"""Lazy commit of the engine allocator segments (LZ, 27 Nov 2026): the sites and the policy, checked offline.

  - the engine addresses of src/native/lazy_commit.cpp are the ones docs/LAZY-COMMIT.md names, and the component is on by default (off by -no-lazy-commit or IW7_LAZY_COMMIT=0; a dedicated server stays off unless -lazy-commit),
  - it patches exactly two VirtualAlloc call sites (both verified before either is patched), wraps the segment growth and the release, and
    installs one vectored handler,
  - the policy header (tests/native/lazy_commit_test.cpp) compiles and its checks pass, when a Visual Studio C++ compiler is installed.
"""
import os
import re
import subprocess
import tempfile
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
CPP = open(os.path.join(ROOT, 'src', 'native', 'lazy_commit.cpp'), encoding='utf-8').read()
HPP = open(os.path.join(ROOT, 'src', 'native', 'lazy_commit_policy.hpp'), encoding='utf-8').read()
DOC = open(os.path.join(ROOT, 'docs', 'LAZY-COMMIT.md'), encoding='utf-8').read()


class LazyCommitSource(unittest.TestCase):
    def test_addresses_match_the_doc(self):
        for name in ('create_site', 'grow_site', 'grow_function', 'release_function'):
            value = re.search(name + r'\s*=\s*0x([0-9A-Fa-f]+)', CPP)
            self.assertTrue(value, name)
            self.assertIn(value.group(1).upper(), DOC.upper(), name)

    def test_default_on_and_switches(self):
        self.assertIn('has_flag("no-lazy-commit")', CPP)
        self.assertIn('IW7_LAZY_COMMIT', CPP)
        self.assertIn('has_flag("lazy-commit")', CPP)
        self.assertIn('is_dedi()', CPP)
        self.assertEqual(CPP.count('if (!enabled()) return;'), 2)   # post_start and post_unpack
        self.assertNotIn('alloc-census', CPP)
        self.assertIn('has_flag("alloc-census")', open(os.path.join(ROOT, 'src', 'native', 'alloc_census.cpp'), encoding='utf-8').read())
        for word in ('no-lazy-commit', 'IW7_LAZY_COMMIT'):
            self.assertIn(word, DOC)

    def test_hooks(self):
        self.assertEqual(CPP.count('AddVectoredExceptionHandler'), 1)
        self.assertEqual(len(re.findall(r'patch_call\(\w+_site', CPP)), 2)
        self.assertEqual(len(re.findall(r'check_call\(\w+_site', CPP)), 2)
        self.assertIn('grow_hook.create', CPP)
        self.assertIn('release_hook.create', CPP)
        self.assertLess(CPP.index('if (!enabled()) return;'), CPP.index('patch_call(create_site'))
        self.assertLess(CPP.index('check_call(grow_site)'), CPP.index('patch_call(create_site'))

    def test_policy_constants(self):
        def const(name):
            m = re.search(r'\b' + name + r'\s*=\s*([^;/]+)', HPP)
            self.assertTrue(m, name)
            return eval(m.group(1).replace('kb', '1024').replace('mb', '(1024*1024)'), {})
        self.assertEqual(const('pad') % 65536, 0)            # one allocation granularity: no merge with a neighbour
        self.assertGreater(const('pad'), 0)
        self.assertEqual(const('head_commit') % 4096, 0)
        self.assertEqual(const('tail_commit') % 4096, 0)
        self.assertGreater(const('head_commit'), 0x3c0 + 0x10 + 0x48)   # the mstate and the top chunk's header fit
        self.assertEqual(const('grow_step') % 4096, 0)
        self.assertGreaterEqual(const('min_lazy'), const('head_commit') + const('tail_commit') + const('grow_step'))


class LazyCommitPolicy(unittest.TestCase):
    def test_native_policy(self):
        vswhere = os.path.join(os.environ.get('ProgramFiles(x86)', ''), 'Microsoft Visual Studio', 'Installer', 'vswhere.exe')
        if not os.path.exists(vswhere):
            self.skipTest('no Visual Studio installer')
        vs = subprocess.run([vswhere, '-products', '*', '-version', '[17.0,18.0)', '-requires', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
                             '-property', 'installationPath'], capture_output=True, text=True).stdout.strip().splitlines()
        if not vs:
            self.skipTest('no VS2022 C++ tools')
        with tempfile.TemporaryDirectory() as scratch:
            exe = os.path.join(scratch, 'lazy-commit-test.exe')
            batch = os.path.join(scratch, 'compile.cmd')
            with open(batch, 'w') as f:
                f.write('@echo off\r\ncall "%s\\VC\\Auxiliary\\Build\\vcvars64.bat" >nul\r\n' % vs[0])
                f.write('cl /nologo /std:c++20 /EHsc /W4 /Fe:"%s" /Fo:"%s\\\\" "%s"\r\n' % (exe, scratch, os.path.join(ROOT, 'tests', 'native', 'lazy_commit_test.cpp')))
                f.write('if errorlevel 1 exit /b 1\r\n"%s"\r\n' % exe)
            run = subprocess.run(['cmd', '/d', '/c', batch], capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn('lazy commit policy checks passed', run.stdout)


if __name__ == '__main__':
    unittest.main()
