"""The script variable accessors of the client project (a48): the overlay edits against the pinned sources and against the layout header.

Offline checks:
  - ops/script-variables/accessor-edits.json is well formed and every edit text has the number of matches it declares in the pinned file
    (needs a checkout of the pinned iw7-mod: IW7_NATIVE_ROOT or tools/iw7-mod-native; skipped without);
  - after the edits no file reads scr_VarGlob or a fixed 0xA000 segment stride;
  - every layout function the new text calls exists in src/native/script_var_layout.hpp;
  - the overlay script is wired into the build, the header is copied with the other native sources, and the script variables component installs
    the three relocated tables with its own sizes.
"""
import json
import os
import re
import subprocess
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
EDITS = os.path.join(ROOT, 'ops', 'script-variables', 'accessor-edits.json')
HPP = os.path.join(ROOT, 'src', 'native', 'script_var_layout.hpp')
CPP = os.path.join(ROOT, 'src', 'native', 'script_variables.cpp')
BUILD = os.path.join(ROOT, 'ops', 'Build-Voice.ps1')
PIN = 'cfca45b11ee14641945b9a264a95638387f48a4a'


def read(path):
    with open(path, encoding='utf-8') as f:
        return f.read().replace('\r\n', '\n')


def pinned(path):
    candidates = [os.environ.get('IW7_NATIVE_ROOT'), os.path.join(ROOT, 'tools', 'iw7-mod-native')]
    for root in candidates:
        if root and os.path.isdir(os.path.join(root, '.git')):
            r = subprocess.run(['git', '-C', root, 'show', PIN + ':' + path], capture_output=True)
            if r.returncode == 0:
                return r.stdout.decode('utf-8').replace('\r\n', '\n')
    return None


class Edits(unittest.TestCase):
    spec = json.loads(read(EDITS))

    def test_shape(self):
        self.assertEqual(self.spec['schema'], 'iw7.script-var-accessor-edits/1')
        self.assertEqual(self.spec['pin'], PIN)
        paths = [f['path'] for f in self.spec['files']]
        self.assertEqual(sorted(paths), sorted(set(paths)))
        self.assertEqual(sorted(p.rsplit('/', 1)[1] for p in paths), ['array.cpp', 'execution.cpp', 'script_value.cpp', 'script_value.hpp'])
        for f in self.spec['files']:
            self.assertTrue(f['edits'])
            for e in f['edits']:
                self.assertGreaterEqual(e['count'], 1)
                self.assertNotEqual(e['old'], e['new'])
                self.assertNotIn('scr_VarGlob', e['new'])
                self.assertNotIn('0xA000', e['new'])

    def test_new_text_uses_only_header_functions(self):
        header = read(HPP)
        used = set()
        for f in self.spec['files']:
            for e in f['edits']:
                used.update(re.findall(r'script_var_layout::(\w+)', e['new']))
        used.discard('')
        self.assertTrue(used)
        for name in used:
            self.assertRegex(header, r'\b' + name + r'\b', name)
        self.assertEqual(sorted(used), ['child', 'object', 'object_children'])

    def test_every_file_includes_the_header(self):
        for f in self.spec['files']:
            joined = ''.join(e['new'] for e in f['edits'])
            self.assertIn('#include "component/script_var_layout.hpp"', joined, f['path'])

    def test_pinned_sources(self):
        checked = 0
        for f in self.spec['files']:
            text = pinned(f['path'])
            if text is None:
                continue
            checked += 1
            out = text
            for e in f['edits']:
                self.assertEqual(out.count(e['old']), e['count'], (f['path'], e['old'][:70]))
                out = out.replace(e['old'], e['new'])
            self.assertNotIn('scr_VarGlob', out, f['path'])
            self.assertNotIn('0xA000', out, f['path'])
            self.assertNotIn('segment_offset', out)
        if not checked:
            self.skipTest('no checkout of the pinned iw7-mod (IW7_NATIVE_ROOT)')


class Wiring(unittest.TestCase):
    def test_build_applies_the_overlay_and_copies_the_header(self):
        text = read(BUILD)
        self.assertIn("Apply-ScriptVarAccessorOverlay.ps1", text)
        self.assertIn("'script_var_layout.hpp'", text)
        self.assertIn('script_var_layout_test.cpp', text)
        self.assertLess(text.index("Copy-Item -LiteralPath @($nativeSources"), text.index('Apply-ScriptVarAccessorOverlay.ps1'))

    def test_component_installs_the_relocated_tables(self):
        text = read(CPP)
        self.assertIn('script_var_layout::install({regions[2].storage.data, regions[3].storage.data, regions[4].storage.data, parent_ids_now(), child_entries, true, seg_in_use});', text)
        self.assertLess(text.index('script_var_layout::install'), text.index('active = true;'))
        # after the code patches: an install before a failed write would leave the accessors on tables that were not used
        self.assertLess(text.index('write(plan[applied], false)'), text.index('script_var_layout::install'))

    def test_refusal_text_is_one_line(self):
        # a string literal broken by a raw newline stops the compile (a48 build 1)
        for line in read(CPP).splitlines():
            if 'accessor refused' in line:
                self.assertTrue(line.rstrip().endswith('};'), line)

    def test_header_stock_row_is_the_engines(self):
        header = read(HPP)
        self.assertIn('stock{0x146691180ull, 0x1466FF180ull, 0x146756180ull, 0xDC00, 0xA000, false}', header)

    def test_overlay_script_is_exact(self):
        text = read(os.path.join(ROOT, 'ops', 'Apply-ScriptVarAccessorOverlay.ps1'))
        for needle in ('Unowned edits', 'Pinned accessor text changed', 'scr_VarGlob', 'accessor-edits.json'):
            self.assertIn(needle, text)


if __name__ == '__main__':
    unittest.main()
