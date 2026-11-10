"""Unit tests for ops/engine-map/iw7_engine_map.py on small hand-assembled sections (no real program bytes)."""
import contextlib
import gc
import importlib.util
import io
import json
from pathlib import Path
import shutil
import sqlite3
import struct
import tempfile
import unittest
import warnings
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("iw7_engine_map", ROOT / "ops/engine-map/iw7_engine_map.py")
em = importlib.util.module_from_spec(spec)
spec.loader.exec_module(em)

BASE = 0x140000000
TEXT_VA = 0x140001000
RDATA_VA = 0x141435000
TEXT_SIZE = 0x600
RDATA_SIZE = 0x200
OUTSIDE_DATA = 0x150000000          # in neither section

A, B, C, D, E, E2, P = (TEXT_VA + o for o in (0x000, 0x040, 0x080, 0x0C0, 0x100, 0x200, 0x400))
GAP = TEXT_VA + 0x300               # junk bytes that are not padding, then padding
LEAF = TEXT_VA + 0x310              # a leaf function: no directory entry, called directly from A
S1, SHORT, S2 = RDATA_VA + 0x100, RDATA_VA + 0x120, RDATA_VA + 0x130
FAR_ENTRY = BASE + 0x20000          # directory entry beyond the code section
NAMED_DATA = RDATA_VA + 0x150


class Asm:
    """Just enough x86-64 to hand-assemble the fixtures; relative displacements are computed here and checked through the tool."""

    def __init__(self, va):
        self.va, self.buf = va, bytearray()

    @property
    def pc(self):
        return self.va + len(self.buf)

    def raw(self, *b):
        self.buf += bytes(b)
        return self

    def sub(self):
        return self.raw(0x48, 0x83, 0xEC, 0x28)

    def add(self):
        return self.raw(0x48, 0x83, 0xC4, 0x28)

    def ret(self):
        return self.raw(0xC3)

    def nop(self):
        return self.raw(0x90)

    def call(self, target):
        return self.raw(0xE8).rel(target, 4)

    def jmp(self, target):
        return self.raw(0xE9).rel(target, 4)

    def lea(self, target):
        return self.raw(0x48, 0x8D, 0x0D).rel(target, 4)

    def rel(self, target, size):
        self.buf += struct.pack('<i', target - (self.pc + size))
        return self

    def at(self, va):
        assert self.pc == va, (hex(self.pc), hex(va))
        return self


def functions():
    a = Asm(A).sub().call(B).call(LEAF).at(A + 0x0E).lea(S1).lea(SHORT).lea(OUTSIDE_DATA).jmp(A + 0x28).at(A + 0x28).add().ret()
    b = Asm(B).sub().lea(S1).call(C).call(C).add().ret()
    c = Asm(C).sub().lea(S2).jmp(C + 0x11).nop().at(C + 0x11).add().jmp(D)
    d = Asm(D).ret()
    e = Asm(E).sub().add().ret()
    e2 = Asm(E2).add().call(D).ret()
    gap = Asm(GAP).raw(0x48, 0x89, 0xC0)                 # mov rax, rax: not padding
    leaf = Asm(LEAF).raw(0x48, 0x31, 0xC0).ret()        # xor rax, rax ; ret
    p = Asm(P).nop().raw(0x06).nop().ret()               # 0x06 does not decode in 64-bit mode
    return [a, b, c, d, e, e2, gap, leaf, p]


def make_sections():
    text = bytearray(b'\xCC' * TEXT_SIZE)
    for asm in functions():
        text[asm.va - TEXT_VA:asm.va - TEXT_VA + len(asm.buf)] = asm.buf
    rdata = bytearray(RDATA_SIZE)
    rva = lambda off: RDATA_VA - BASE + off
    u4, u0, chain = rva(0), rva(4), rva(0x10)
    rdata[0:4] = bytes([1, 4, 0, 0])                                         # unwind info, prolog 4
    rdata[4:8] = bytes([1, 0, 0, 0])                                         # unwind info, prolog 0
    rdata[0x10:0x14] = bytes([1 | (4 << 3), 0, 0, 0])                        # chained
    rdata[0x14:0x20] = struct.pack('<III', E - BASE, E - BASE + 0x10, u4)    # the parent entry
    for va, s in ((S1, b'hello engine'), (SHORT, b'abc'), (S2, b'com_maxfps')):
        rdata[va - RDATA_VA:va - RDATA_VA + len(s) + 1] = s + b'\0'
    entries = [(A, A + 0x30, u4), (B, B + 0x20, u4), (C, C + 0x20, u4), (D, D + 0x10, u0), (E, E + 0x10, u4),
               (E2, E2 + 0x10, chain), (P, P + 0x10, u0), (FAR_ENTRY, FAR_ENTRY + 0x10, u0)]
    pdata = b''.join(struct.pack('<III', b - BASE, e - BASE, i) for b, e, i in entries) + struct.pack('<III', 0, 0, 0)
    return bytes(text), bytes(rdata), pdata


SYMBOLS_HPP = """namespace game {
	WEAK symbol<void(int)> Foo{ 0x140001000 };
	WEAK symbol<int(
		int a,
		int b)> Multi{
		0x140001040 };
}
"""
LIST_CSV = 'name,address\nCsvB,0x140001040\nInnerA,140001008\nCsvC,0x140001080\nSomeData,0x141435150\nbad,xyz\nshort,0x12\n'
OVERLAY = {'schema': 'iw7.engine-map-names/1', 'names': [{'address': '140001080', 'name': 'AnalystC', 'source': 'unit'},
                                                          {'address': '140001040', 'name': 'AnalystB', 'source': 'unit'}]}
TABLES = ('meta', 'functions', 'fragments', 'gaps', 'calls', 'refs', 'strings', 'names')


def run(*argv, stdin=None):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        if stdin is None:
            rc = em.main(list(argv))
        else:
            with mock.patch('sys.stdin', io.StringIO(stdin)):
                rc = em.main(list(argv))
    return rc, out.getvalue()


def dump(db_path):
    db = sqlite3.connect(db_path)
    try:
        out = {}
        for t in TABLES:
            width = len(db.execute('select * from %s limit 0' % t).description)
            out[t] = db.execute('select * from %s order by %s' % (t, ', '.join(str(i + 1) for i in range(width)))).fetchall()
        return out
    finally:
        db.close()


class EngineMapTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        warnings.simplefilter('ignore', ResourceWarning)   # the tool reads its input files with bare open().read()
        cls.tmp = tempfile.TemporaryDirectory(ignore_cleanup_errors=True)
        cls.addClassCleanup(lambda: (gc.collect(), cls.tmp.cleanup()))
        cls.dir = Path(cls.tmp.name)
        cls.ref = cls.dir / 'ref'
        cls.ref.mkdir()
        text, rdata, pdata = make_sections()
        for k, v in (('text', text), ('rdata', rdata), ('pdata', pdata)):
            (cls.ref / ('unpacked-%s.bin' % k)).write_bytes(v)
        cls.symbols = cls.dir / 'symbols.hpp'
        cls.symbols.write_text(SYMBOLS_HPP, encoding='utf-8')
        cls.csv = cls.dir / 'names.csv'
        cls.csv.write_text(LIST_CSV, encoding='utf-8')
        cls.overlay = cls.dir / 'overlay.json'
        cls.overlay.write_text(json.dumps(OVERLAY), encoding='utf-8')
        cls.db_path = str(cls.dir / 'map.sqlite')
        cls.build_args = ['build', '--db', cls.db_path, '--reference-root', str(cls.ref), '--symbols', str(cls.symbols),
                          '--names', str(cls.csv), '--names-file', str(cls.overlay), '--workers', '1']
        cls.build_rc, cls.build_out = run(*cls.build_args)
        cls.map = em.Map(cls.db_path)
        cls.addClassCleanup(cls.map.db.close)
        cls.meta = {k: int(v) if v.lstrip('-').isdigit() else v for k, v in cls.map.meta.items()}

    def cli(self, *argv, stdin=None):
        return run(argv[0], '--db', self.db_path, *argv[1:], stdin=stdin)

    # 1. boundaries
    def test_build_command_prints_counts(self):
        self.assertEqual(self.build_rc, 0)
        self.assertIn('functions          7', self.build_out)
        self.assertIn('fragments          8', self.build_out)
        self.assertIn('input_text_sha256', '\n'.join(self.map.meta))

    def test_function_boundaries_from_directory(self):
        rows = self.map.db.execute('select start, end, size, fragments, prolog, partial from functions order by start').fetchall()
        self.assertEqual(rows, [(A, A + 0x30, 0x30, 1, 4, 0), (B, B + 0x20, 0x20, 1, 4, 0), (C, C + 0x20, 0x20, 1, 4, 0),
                                (D, D + 0x10, 0x10, 1, 0, 0), (E, E + 0x10, 0x20, 2, 4, 0), (LEAF, LEAF + 4, 4, 1, 0, 0), (P, P + 0x10, 0x10, 1, 0, 1)])

    def test_at_start_inside_and_padding(self):
        start, inside, pad = self.map.at(A), self.map.at(A + 0x0C), self.map.at(A + 0x35)
        self.assertEqual((start['where'], start['offset'], start['function'], start['size']), ('function start', 0, '%X' % A, 0x30))
        self.assertEqual((inside['where'], inside['offset'], inside['name']), ('inside', 0x0C, 'Foo+0xC'))
        self.assertIsNone(pad['function'])
        self.assertEqual(pad['where'], 'outside the mapped code')
        self.assertEqual(self.map.at(OUTSIDE_DATA)['where'], 'outside the mapped code')
        self.assertEqual(self.map.at(OUTSIDE_DATA)['name'], '%X' % OUTSIDE_DATA)

    def test_at_command_text_and_json(self):
        rc, out = self.cli('at', '0x%X' % (A + 4))
        self.assertEqual(rc, 0)
        self.assertEqual(out.strip(), '%X  Foo+0x4  inside  size 48, 1 fragment(s)' % (A + 4))
        rc, out = self.cli('at', '+0x1040', 'iw7+1080', 'sub_1400010C0', 'AnalystC', '--json')
        data = json.loads(out)
        self.assertEqual([r['function'] for r in data], ['%X' % x for x in (B, C, D, C)])

    def test_address_forms(self):
        for text in ('0x140001040', '140001040', '+0x1040', 'iw7+1040', 'sub_140001040', 'Multi'):
            self.assertEqual(self.map.addr(text), B, text)
        with self.assertRaises(SystemExit) as ctx:
            self.map.addr('NoSuchName')
        self.assertIn('not an address or a known name', str(ctx.exception))
        with self.assertRaises(SystemExit) as ctx:
            em.Map(str(self.dir / 'missing.sqlite'))
        self.assertIn('run "build" first', str(ctx.exception))

    # 2. chained fragment
    def test_chained_fragment(self):
        self.assertEqual(self.map.db.execute('select begin, end, func from fragments where func = ? order by begin', (E,)).fetchall(), [(E, E + 0x10, E), (E2, E2 + 0x10, E)])
        self.assertEqual(self.map.db.execute('select fragments, size from functions where start = ?', (E,)).fetchone(), (2, 0x20))
        self.assertEqual(self.map.db.execute('select count(*) from functions where start = ?', (E2,)).fetchone()[0], 0)
        for va in (E2, E2 + 5):
            r = self.map.at(va)
            self.assertEqual((r['where'], r['function'], r['fragments'], r['offset']), ('chained fragment', '%X' % E, 2, va - E))
        self.assertEqual(self.map.at(E)['where'], 'function start')

    # 3. leaf function
    def test_leaf_function_is_discovered_and_junk_stays_a_gap(self):
        self.assertGreaterEqual(self.meta['leaf_functions'], 1)
        self.assertEqual(self.meta['leaf_functions'], 1)
        self.assertEqual(self.map.func(LEAF), LEAF)
        self.assertEqual(self.map.func(LEAF + 3), LEAF)
        self.assertEqual(self.map.db.execute('select * from calls where src = ? and kind = ? and target = ?', (A, 'call', LEAF)).fetchone()[3], LEAF)
        self.assertEqual(self.map.db.execute('select begin, end, after from gaps').fetchall(), [(GAP, LEAF, E)])
        r = self.map.at(GAP + 1)
        self.assertIsNone(r['function'])
        self.assertEqual(r['where'], 'gap after sub_%X' % E)

    # 4. call edges
    def test_call_edges_and_counts(self):
        rows = self.map.db.execute('select src, site, target, dst, kind from calls order by src, site').fetchall()
        self.assertEqual(rows, [(A, A + 4, B, B, 'call'), (A, A + 9, LEAF, LEAF, 'call'), (B, B + 0x0B, C, C, 'call'), (B, B + 0x10, C, C, 'call'),
                                (C, C + 0x15, D, D, 'tail'), (E, E2 + 4, D, D, 'call')])
        self.assertEqual((self.meta['calls'], self.meta['tail_calls']), (5, 1))

    def test_callers_and_callees_with_depth(self):
        self.assertEqual(self.map.callers(C), [(B, 2, 'call')])
        self.assertEqual(self.map.callees(A), [(B, 1, 'call'), (LEAF, 1, 'call')])
        rc, out = self.cli('callers', 'AnalystC')
        self.assertEqual(out.splitlines(), ['Multi  x2'])
        rc, out = self.cli('callers', 'AnalystC', '--depth', '2')
        self.assertEqual(out.splitlines(), ['Multi  x2', '  Foo  x1'])
        rc, out = self.cli('callees', 'Foo', '--depth', '2')
        self.assertEqual(out.splitlines(), ['Multi  x1', '  AnalystC  x2', 'sub_%X  x1' % LEAF])
        rc, out = self.cli('callees', 'Foo', '--depth', '3')
        self.assertEqual(out.splitlines(), ['Multi  x1', '  AnalystC  x2', '    sub_%X  x1 (tail)' % D, 'sub_%X  x1' % LEAF])
        rc, out = self.cli('callers', 'Foo')
        self.assertIn('none known', out)
        rc, out = self.cli('callees', 'Foo', '--depth', '3', '--max', '2')
        self.assertEqual(out.splitlines(), ['Multi  x1', '  AnalystC  x2', '... 2 more'])

    def test_callers_from_a_chained_fragment_belong_to_the_root(self):
        rc, out = self.cli('callers', 'sub_%X' % D)
        self.assertEqual(out.splitlines(), ['AnalystC  x1 (tail)', 'sub_%X  x1' % E])
        self.assertEqual(self.map.db.execute('select src, site from calls where target = ? and kind = ? and src = ?', (D, 'call', E)).fetchone(), (E, E2 + 4))

    def test_command_on_an_address_outside_functions_exits(self):
        with self.assertRaises(SystemExit) as ctx:
            self.cli('callers', '0x%X' % (A + 0x35))
        self.assertIn('is not inside a mapped function', str(ctx.exception))

    # 5. tail calls
    def test_tail_call_and_internal_jump(self):
        kinds = self.map.db.execute('select kind, target from calls where src = ?', (C,)).fetchall()
        self.assertEqual(kinds, [('tail', D)])
        self.assertEqual(self.map.db.execute("select count(*) from calls where kind in ('jmp', 'jcc')").fetchone()[0], 0)
        self.assertEqual(self.map.db.execute('select count(*) from calls where src = ? and target in (?, ?)', (A, A + 0x28, C + 0x11)).fetchone()[0], 0)
        self.assertEqual(self.map.db.execute('select count(*) from calls where target = ?', (C + 0x11,)).fetchone()[0], 0)

    # 6. strings
    def test_strings_of_a_function_and_find_string(self):
        self.assertEqual(self.map.db.execute('select addr, text from strings order by addr').fetchall(), [(S1, 'hello engine'), (S2, 'com_maxfps')])
        rc, out = self.cli('strings', 'Foo')
        self.assertEqual(out.splitlines(), ['%X  "hello engine"' % (A + 0x0E)])
        rc, out = self.cli('strings', 'AnalystC', '--json')
        self.assertEqual(json.loads(out), [dict(site='%X' % (C + 4), address='%X' % S2, text='com_maxfps')])
        rc, out = self.cli('strings', 'sub_%X' % D)
        self.assertEqual(out.strip(), 'no string reference')
        rc, out = self.cli('find-string', 'HELLO')
        self.assertEqual(out.splitlines(), ['%X  "hello engine"' % S1, '    Foo  at %X' % (A + 0x0E), '    Multi  at %X' % (B + 4)])
        rc, out = self.cli('find-string', '^com_', '--regex')
        self.assertEqual(out.splitlines(), ['%X  "com_maxfps"' % S2, '    AnalystC  at %X' % (C + 4)])
        rc, out = self.cli('find-string', 'o', '--max', '1')
        self.assertEqual(out.splitlines()[-1], '... 1 more strings')
        rc, out = self.cli('find-string', 'abc')
        self.assertIn('no such string is referenced', out)

    def test_short_string_is_not_recorded(self):
        self.assertEqual(self.map.db.execute('select count(*) from strings where addr = ?', (SHORT,)).fetchone()[0], 0)
        self.assertEqual(self.map.db.execute('select region from refs where target = ?', (SHORT,)).fetchone()[0], 'rdata')
        image = em.Image(*make_sections())
        self.assertIsNone(image.string(SHORT))
        self.assertEqual(image.string(S1), 'hello engine')
        self.assertEqual(image.string(SHORT, least=3), 'abc')
        self.assertIsNone(image.string(RDATA_VA))                      # unwind bytes are not text

    # 7. reference outside both sections
    def test_reference_outside_sections_is_data(self):
        self.assertEqual(self.map.db.execute('select src, site, region, mnem from refs where target = ?', (OUTSIDE_DATA,)).fetchall(), [(A, A + 0x1C, 'data', 'lea')])
        self.assertEqual(self.meta['refs'], 5)
        rc, out = self.cli('refs', '0x%X' % OUTSIDE_DATA)
        self.assertEqual(out.splitlines(), ['Foo  at %X  (lea)' % (A + 0x1C)])
        rc, out = self.cli('refs', 'sub_%X' % LEAF)
        self.assertEqual(out.splitlines(), ['Foo  at %X  (call)' % (A + 9)])
        rc, out = self.cli('refs', '0x150000010')
        self.assertIn('no direct reference', out)

    # 8. names
    def test_names_table_and_labels(self):
        rows = self.map.db.execute('select addr, name, source, func, off from names order by addr, name').fetchall()
        self.assertEqual(rows, [(A, 'Foo', 'symbols.hpp', A, 0), (A + 8, 'InnerA', 'list:names.csv', A, 8),
                                (B, 'AnalystB', 'analyst:unit', B, 0), (B, 'CsvB', 'list:names.csv', B, 0), (B, 'Multi', 'symbols.hpp', B, 0),
                                (C, 'AnalystC', 'analyst:unit', C, 0), (C, 'CsvC', 'list:names.csv', C, 0), (NAMED_DATA, 'SomeData', 'list:names.csv', None, None)])
        self.assertEqual((self.meta['names'], self.meta['names_at_start'], self.meta['names_inside'], self.meta['names_outside']), (8, 6, 1, 1))
        self.assertEqual(self.map.db.execute('select signature from names where name = ?', ('Multi',)).fetchone()[0], 'int( int a, int b)')
        self.assertEqual(self.map.db.execute('select signature from names where name = ?', ('Foo',)).fetchone()[0], 'void(int)')
        self.assertEqual(self.map.label(A + 8), 'InnerA')
        self.assertEqual(self.map.label(A + 0x0C), 'Foo+0xC')
        self.assertEqual(self.map.label(B), 'Multi')                     # symbols.hpp beats the analyst name and the list
        self.assertEqual(self.map.label(C), 'AnalystC')                  # the analyst name beats the list
        self.assertEqual(self.map.label(C + 3), 'AnalystC+0x3')
        self.assertEqual(self.map.label(D), 'sub_%X' % D)
        self.assertEqual(self.map.label(D + 2), 'sub_%X+0x2' % D)
        self.assertEqual(self.map.label(OUTSIDE_DATA), '%X' % OUTSIDE_DATA)
        self.assertEqual(self.map.at(A)['names'], ['Foo'])

    def test_names_command(self):
        rc, out = self.cli('names', '--like', 'csv')
        self.assertEqual(out.splitlines(), ['%X  %-44s %s' % (B, 'CsvB', 'list:names.csv'),'%X  %-44s %s' % (C, 'CsvC', 'list:names.csv')])
        rc, out = self.cli('names', '--like', 'Inner')
        self.assertIn('(+0x8 inside a function)', out)
        rc, out = self.cli('names', '--like', 'SomeData')
        self.assertIn('(not in code)', out)
        rc, out = self.cli('names', '--like', 'Foo', '--json')
        self.assertEqual(json.loads(out), [dict(address='%X' % A, name='Foo', source='symbols.hpp', offset=0)])

    def test_parse_names_sources_directly(self):
        sym = em.parse_names(str(self.symbols))
        self.assertEqual([(a, n, s) for a, n, s, _g in sym], [(A, 'Foo', 'symbols.hpp'), (B, 'Multi', 'symbols.hpp')])
        self.assertEqual(em.parse_names(str(self.dir / 'absent.hpp')), [])
        native = self.dir / 'native'
        native.mkdir(exist_ok=True)
        (native / 'hooks.cpp').write_text('constexpr auto kFoo = 0x140001000;\nint x = 0x1400010;\n', encoding='utf-8')
        (native / 'skip.txt').write_text('0x140001040', encoding='utf-8')
        self.assertEqual([(a, n, s) for a, n, s, _g in em.parse_names(native_src=str(native))], [(A, 'hook:hooks.cpp:1:kFoo', 'native-src')])

    # 9. aggregation
    def test_at_stdin_aggregates_by_function(self):
        text = '0x140001004 10\n140001010,5\n\n0x1400010C4 3\n0x140001035 7\n+0x1000\n'
        rc, out = self.cli('at', '--stdin', stdin=text)
        self.assertEqual(rc, 0)
        self.assertEqual(out.splitlines(), ['      16   61.5%  Foo', '       7   26.9%  (not in a mapped function)', '       3   11.5%%  sub_%X' % D])
        rc, out = self.cli('at', '--stdin', '--json', '--top', '2', stdin=text)
        data = json.loads(out)
        self.assertEqual(data, [dict(count=16, share=0.6154, function='Foo', start='%X' % A),
                                dict(count=7, share=0.2692, function='(not in a mapped function)', start=None)])

    # 10. name command
    def test_name_command_adds_refuses_and_replaces(self):
        db = str(self.dir / 'copy-name.sqlite')
        shutil.copy(self.db_path, db)
        names_file = self.dir / 'mine.json'
        base = ['--db', db, '--source', 'unit', '--names-file', str(names_file)]
        rc, out = run('name', '0x%X' % D, 'MyName', *base)
        self.assertEqual((rc, out.strip()), (0, '%X is now MyName' % D))
        doc = json.loads(names_file.read_text(encoding='utf-8'))
        self.assertEqual(doc, dict(schema='iw7.engine-map-names/1', names=[dict(address='%X' % D, name='MyName', source='unit')]))
        self.assertTrue(names_file.read_bytes().endswith(b'\n'))
        self.assertNotIn(b'\r', names_file.read_bytes())
        m = em.Map(db)
        self.assertEqual(m.db.execute('select addr, source, func, off from names where name = ?', ('MyName',)).fetchall(), [(D, 'analyst:unit', D, 0)])
        self.assertEqual(m.label(D + 1), 'MyName+0x1')
        m.db.close()
        with self.assertRaises(SystemExit) as ctx:
            run('name', '0x%X' % A, 'MyName', *base)                     # used in the names file at another address
        self.assertIn('already belongs to another address', str(ctx.exception))
        with self.assertRaises(SystemExit):
            run('name', '0x%X' % D, 'Foo', *base)                        # used in the database (symbols.hpp) at another address
        self.assertEqual(json.loads(names_file.read_text(encoding='utf-8'))['names'][0]['address'], '%X' % D)
        rc, _out = run('name', '0x%X' % D, 'MyName', *base)              # the same name at the same address is not a clash
        self.assertEqual(rc, 0)
        rc, _out = run('name', '0x%X' % A, 'MyName', '--replace', *base)
        self.assertEqual(rc, 0)
        doc = json.loads(names_file.read_text(encoding='utf-8'))
        self.assertEqual(doc['names'], [dict(address='%X' % A, name='MyName', source='unit')])
        m = em.Map(db)
        self.assertEqual(m.db.execute('select addr from names where name = ?', ('MyName',)).fetchall(), [(A,)])
        self.assertEqual(m.label(D), 'sub_%X' % D)
        m.db.close()

    # 11. bytes that do not decode
    def test_undecodable_bytes_mark_the_function_partial(self):
        self.assertEqual(self.meta['decode_failures'], 1)
        self.assertEqual(self.meta['partial_functions'], 1)
        self.assertEqual(self.map.db.execute('select start from functions where partial = 1').fetchall(), [(P,)])
        calls, refs, failed = em.scan((make_sections()[0], TEXT_VA, [(P, P + 0x10, P)]))
        self.assertEqual((calls, refs, failed), ([], [], [(P, P + 1)]))

    # 12. determinism
    def test_build_is_deterministic(self):
        image = em.Image(*make_sections())
        names = em.parse_names(str(self.symbols), [str(self.csv)], None, str(self.overlay))
        a, b = str(self.dir / 'det-a.sqlite'), str(self.dir / 'det-b.sqlite')
        em.build(image, a, names, workers=1)
        em.build(image, b, names, workers=1)
        da, db = dump(a), dump(b)
        for table in TABLES:
            self.assertTrue(da[table], table)
            self.assertEqual(da[table], db[table], table)
        self.assertEqual(dump(self.db_path)['functions'], da['functions'])

    def test_rebuild_replaces_an_existing_database(self):
        image = em.Image(*make_sections())
        path = str(self.dir / 'again.sqlite')
        em.build(image, path, [], workers=1)
        em.build(image, path, [], workers=1)
        self.assertEqual(dump(path)['names'], [])

    # 13. selftest and the byte invariant
    def test_selftest_passes_and_byte_invariant_holds(self):
        rc, out = self.cli('selftest')
        self.assertEqual(rc, 0)
        self.assertIn('selftest passed', out)
        self.assertIn('direct calls 5: 5 to a function start, 0 inside a function, 0 outside mapped functions', out)
        self.assertIn('names 8: 6 at a function start, 1 inside a function, 1 not in code', out)
        m = self.meta
        self.assertEqual(m['text_bytes'], TEXT_SIZE)
        self.assertEqual(m['covered_bytes'] + m['padding_bytes'] + m['gap_bytes'], m['text_bytes'])
        self.assertEqual((m['covered_bytes'], m['gap_bytes'], m['padding_bytes']), (0xB4, 0x10, TEXT_SIZE - 0xB4 - 0x10))
        self.assertEqual(self.map.db.execute('select sum(end - begin) from fragments').fetchone()[0], m['covered_bytes'])
        self.assertEqual(self.map.db.execute('select sum(end - begin) from gaps').fetchone()[0], m['gap_bytes'])

    def test_selftest_fails_on_a_broken_invariant(self):
        db = str(self.dir / 'broken.sqlite')
        shutil.copy(self.db_path, db)
        con = sqlite3.connect(db)
        con.execute("update meta set v = '1' where k = 'gap_bytes'")
        con.commit()
        con.close()
        rc, out = run('selftest', '--db', db)
        self.assertEqual(rc, 1)
        self.assertIn('FAIL covered + padding + gaps differs from the code size', out)
        self.assertIn('selftest FAILED', out)

    # 14. directory entry in another section
    def test_entry_outside_the_code_section_is_counted(self):
        self.assertEqual(self.meta['entries_in_other_sections'], 1)
        self.assertEqual(self.meta['unwind_outside'], 0)
        self.assertEqual(self.map.db.execute('select count(*) from fragments where begin >= ?', (FAR_ENTRY,)).fetchone()[0], 0)

    def test_unwind_info_outside_rdata_makes_a_standalone_function(self):
        text, rdata, _pdata = make_sections()
        pdata = struct.pack('<III', A - BASE, A - BASE + 0x30, 0x5000)         # unwind rva is not in rdata
        frags, prolog, outside, elsewhere = em.read_functions(em.Image(text, rdata, pdata))
        self.assertEqual((frags, outside, elsewhere), ([(A, A + 0x30, A)], 1, 0))
        self.assertEqual(prolog, {A: 0})

    def test_chain_to_a_missing_parent_stands_alone(self):
        text, rdata, _pdata = make_sections()
        pdata = struct.pack('<III', E2 - BASE, E2 - BASE + 0x10, RDATA_VA - BASE + 0x10)   # chained to E, but E has no entry here
        frags, _prolog, _outside, _elsewhere = em.read_functions(em.Image(text, rdata, pdata))
        self.assertEqual(frags, [(E2, E2 + 0x10, E2)])

    # remaining commands
    def test_stats_and_disasm(self):
        rc, out = self.cli('stats')
        self.assertEqual(rc, 0)
        self.assertIn('functions          7', out)
        self.assertNotIn('input_text_sha256', out)
        self.assertIn('functions with no direct caller (entry points, callbacks, table targets): 3', out)
        self.assertIn('       2 sites  AnalystC', out)
        rc, out = self.cli('disasm', 'Foo', '--reference-root', str(self.ref))
        lines = out.splitlines()
        self.assertEqual(lines[0], 'Foo:')
        self.assertTrue(any('call' in l and l.endswith('; Multi') for l in lines))
        self.assertTrue(any('lea' in l and l.endswith('; "hello engine"') for l in lines))
        self.assertTrue(any('lea' in l and l.endswith('; data %X' % OUTSIDE_DATA) for l in lines))
        self.assertTrue(any('jmp' in l and ';' not in l for l in lines))
        rc, out = self.cli('disasm', 'Foo', '--reference-root', str(self.ref), '--max', '3')
        self.assertEqual(len(out.splitlines()), 5)
        self.assertIn('... cut at 3 lines', out)

    def test_build_refuses_missing_input(self):
        with self.assertRaises(SystemExit) as ctx:
            run('build', '--db', str(self.dir / 'x.sqlite'), '--reference-root', str(self.dir / 'nothing'))
        self.assertIn('missing input', str(ctx.exception))


if __name__ == '__main__':
    unittest.main()
