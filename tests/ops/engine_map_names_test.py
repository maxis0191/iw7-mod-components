"""Tests for the suggested names and the console-variable listing of ops/engine-map/iw7_engine_map.py (synthetic sections only)."""
import gc
import importlib.util
import json
from pathlib import Path
import shutil
import sqlite3
import struct
import tempfile
import unittest
import warnings

ROOT = Path(__file__).resolve().parents[2]


def load(name, rel):
    spec = importlib.util.spec_from_file_location(name, ROOT / rel)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


base = load('engine_map_test_base', 'tests/ops/engine_map_test.py')
em, Asm, run, dump = base.em, base.Asm, base.run, base.dump
TEXT_VA, RDATA_VA, BASE = base.TEXT_VA, base.RDATA_VA, base.BASE

F1, F2, F3, F4, F5, F6, F7 = (TEXT_VA + o for o in (0x000, 0x040, 0x080, 0x0C0, 0x100, 0x140, 0x180))
STR = {
    'alpha': (0x100, b'Foo_Alpha: bad value %d'),
    'beta': (0x120, b'Foo_Beta failed'),
    'shared1': (0x140, b'Shared_Name: one'),
    'shared2': (0x160, b'Shared_Name(two)'),
    'known': (0x180, b'Known_Func: x'),
    'two1': (0x1A0, b'Two_One: x'),
    'two2': (0x1C0, b'Two_Two: y'),
    'dvar': (0x1E0, b'com_maxfps'),
    'dvar2': (0x1F0, b'r_vsync'),
    'sentence': (0x200, b'this is an ordinary sentence'),
    'lower': (0x230, b'foo_bar: lowercase is no code name'),
}
SA = {k: RDATA_VA + v[0] for k, v in STR.items()}
CODE = {F1: ('alpha', 'dvar'), F2: ('beta',), F3: ('shared1',), F4: ('shared2',), F5: ('known', 'dvar2'), F6: ('two1', 'two2'), F7: ('dvar', 'sentence', 'lower')}
SYMBOLS = 'namespace game {\n\tWEAK symbol<void()> Existing{ 0x%X };\n}\n' % F5


def sections():
    text = bytearray(b'\xCC' * 0x200)
    entries = []
    for va, keys in CODE.items():
        a = Asm(va).sub()
        for k in keys:
            a.lea(SA[k])
        a.add().ret()
        text[va - TEXT_VA:va - TEXT_VA + len(a.buf)] = a.buf
        entries.append((va, va + 0x30, RDATA_VA - BASE))
    rdata = bytearray(0x300)
    rdata[0:4] = bytes([1, 4, 0, 0])
    for off, s in STR.values():
        rdata[off:off + len(s) + 1] = s + b'\0'
    pdata = b''.join(struct.pack('<III', b - BASE, e - BASE, i) for b, e, i in entries) + struct.pack('<III', 0, 0, 0)
    return bytes(text), bytes(rdata), pdata


class NamesTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        warnings.simplefilter('ignore', ResourceWarning)
        cls.tmp = tempfile.TemporaryDirectory(ignore_cleanup_errors=True)
        cls.addClassCleanup(lambda: (gc.collect(), cls.tmp.cleanup()))
        cls.dir = Path(cls.tmp.name)
        cls.ref = cls.dir / 'ref'
        cls.ref.mkdir()
        for k, v in zip(('text', 'rdata', 'pdata'), sections()):
            (cls.ref / ('unpacked-%s.bin' % k)).write_bytes(v)
        cls.symbols = cls.dir / 'symbols.hpp'
        cls.symbols.write_text(SYMBOLS, encoding='utf-8')

    def build(self, name, auto):
        db = str(self.dir / name)
        argv = ['build', '--db', db, '--reference-root', str(self.ref), '--symbols', str(self.symbols), '--workers', '1'] + (['--auto-names'] if auto else [])
        rc, _out = run(*argv)
        self.assertEqual(rc, 0)
        return db

    def rows(self, db, where=''):
        c = sqlite3.connect(db)
        try:
            return c.execute('select addr, name, source, signature from names %s order by addr, name' % where).fetchall()
        finally:
            c.close()

    def test_unique_text_names_its_function(self):
        db = sqlite3.connect(self.build('a.sqlite', False))
        res = em.suggest_names(db)
        got = {s['function']: s for s in res['unique']}
        db.close()
        self.assertEqual(got[F1]['name'], '~Foo_Alpha')
        self.assertEqual(got[F1]['source'], 'text:unique')
        self.assertEqual(got[F1]['string'], SA['alpha'])
        self.assertEqual(got[F2]['name'], '~Foo_Beta')
        self.assertEqual(sorted(got), [F1, F2])

    def test_shared_text_names_neither_and_lists_both(self):
        db = sqlite3.connect(self.build('b.sqlite', False))
        res = em.suggest_names(db)
        db.close()
        self.assertEqual([(s['name'], s['source'], s['functions']) for s in res['shared']], [('~Shared_Name', 'text:shared', [F3, F4])])
        self.assertNotIn(F3, [s['function'] for s in res['unique']])
        self.assertNotIn(F4, [s['function'] for s in res['unique']])

    def test_existing_name_is_not_replaced_and_ignore_mode_measures_the_rule(self):
        db = sqlite3.connect(self.build('c.sqlite', False))
        plain = em.suggest_names(db)
        measured = em.suggest_names(db, ignore_existing=True)
        db.close()
        self.assertNotIn(F5, [s['function'] for s in plain['unique']])
        self.assertEqual({s['function']: s['name'] for s in measured['unique']}[F5], '~Known_Func')

    def test_function_with_two_code_names_is_left_unnamed(self):
        db = sqlite3.connect(self.build('d.sqlite', False))
        res = em.suggest_names(db)
        db.close()
        self.assertEqual(res['ambiguous'], 1)
        self.assertNotIn(F6, [s['function'] for s in res['unique']])

    def test_no_two_functions_share_a_suggested_name(self):
        db = sqlite3.connect(self.build('e.sqlite', False))
        names = [s['name'] for s in em.suggest_names(db)['unique']]
        db.close()
        self.assertEqual(len(names), len(set(names)))

    def test_taken_name_is_not_reused(self):
        db = sqlite3.connect(self.build('f.sqlite', False))
        db.execute("insert into names values(?,?,?,?,?,?)", (0x1, '~Foo_Beta', 'analyst:unit', '', None, None))
        res = em.suggest_names(db)
        db.close()
        self.assertEqual(res['taken'], 1)
        self.assertEqual([s['function'] for s in res['unique']], [F1])

    def test_auto_names_stores_suggestions_and_at_shows_them(self):
        db = self.build('g.sqlite', True)
        auto = self.rows(db, "where source like 'auto:%'")
        self.assertEqual([(a, n, s) for a, n, s, _e in auto], [(F1, '~Foo_Alpha', 'auto:text:unique'), (F2, '~Foo_Beta', 'auto:text:unique')])
        self.assertIn('%X' % SA['alpha'], auto[0][3])
        self.assertIn('Foo_Alpha: bad value', auto[0][3])
        rc, out = run('at', '--db', db, '0x%X' % F2)
        self.assertEqual(rc, 0)
        self.assertIn('~Foo_Beta', out)
        rc, out = run('callers', '--db', db, '~Foo_Beta')
        self.assertEqual(rc, 0)
        self.assertEqual(self.rows(db, "where addr = %d and source = 'symbols.hpp'" % F5)[0][1], 'Existing')
        self.assertEqual(sqlite3.connect(db).execute("select v from meta where k = 'auto_names'").fetchone()[0], '2')

    def test_without_the_flag_nothing_is_stored(self):
        db = self.build('h.sqlite', False)
        self.assertEqual(self.rows(db, "where source like 'auto:%' or name like '~%'"), [])
        rc, out = run('at', '--db', db, '0x%X' % F2)
        self.assertNotIn('~', out)
        self.assertIn('sub_%X' % F2, out)
        self.assertNotIn('auto_names', dict(sqlite3.connect(db).execute('select k, v from meta')))

    def test_suggest_names_command_prints_and_writes_nothing(self):
        db = self.build('i.sqlite', False)
        before = dump(db)
        rc, out = run('suggest-names', '--db', db)
        self.assertEqual(rc, 0)
        self.assertIn('~Foo_Alpha', out)
        self.assertIn('candidate ~Shared_Name', out)
        self.assertIn('text:unique        2', out)
        self.assertIn('text:shared        1', out)
        rc, out = run('suggest-names', '--db', db, '--json', '--max', '1')
        doc = json.loads(out)
        self.assertEqual(doc['counts']['text:unique'], 2)
        self.assertEqual(len(doc['unique']), 1)
        self.assertEqual(dump(db), before)

    def test_label_prefers_symbols_then_analyst_then_other_then_auto(self):
        db = self.build('j.sqlite', False)
        c = sqlite3.connect(db)
        for name, source in (('~Auto', 'auto:text:unique'), ('ListName', 'list:x.csv'), ('AnalystName', 'analyst:unit'), ('SymName', 'symbols.hpp')):
            c.execute('insert into names values(?,?,?,?,?,?)', (F2, name, source, '', F2, 0))
        c.commit()
        c.close()
        m = em.Map(db)
        self.addCleanup(m.db.close)
        self.assertEqual(m.label(F2), 'SymName')
        for gone, expect in (('SymName', 'AnalystName'), ('AnalystName', 'ListName'), ('ListName', '~Auto')):
            m.db.execute('delete from names where name = ?', (gone,))
            self.assertEqual(m.label(F2), expect)
            self.assertEqual(m.label(F2 + 4), expect + '+0x4')

    def test_dvars_lists_variable_texts_with_users_and_ignores_sentences(self):
        db = self.build('k.sqlite', False)
        rc, out = run('dvars', '--db', db)
        self.assertEqual(rc, 0)
        self.assertIn('com_maxfps', out)
        self.assertIn('2 function(s)', out)
        self.assertIn('r_vsync', out)
        for bad in ('ordinary sentence', 'Foo_Alpha', 'foo_bar: lowercase'):
            self.assertNotIn(bad, out)
        rc, out = run('dvars', '--db', db, '--like', 'MAXFPS', '--json')
        doc = json.loads(out)
        self.assertEqual(doc['total'], 1)
        self.assertEqual(doc['dvars'][0]['count'], 2)
        self.assertEqual(sorted(u['site'] for u in doc['dvars'][0]['users']), sorted(['%X' % (F1 + 4 + 7), '%X' % (F7 + 4)]))
        rc, out = run('dvars', '--db', db, '--like', 'nothing-like-it')
        self.assertIn('0 name text(s) match', out)

    def test_build_with_auto_names_is_deterministic(self):
        one = dump(self.build('l1.sqlite', True))
        two = dump(self.build('l2.sqlite', True))
        self.assertEqual(one, two)
        self.assertTrue(any(r[2] == 'auto:text:unique' for r in one['names']))


if __name__ == '__main__':
    unittest.main()
