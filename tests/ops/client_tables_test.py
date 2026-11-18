"""The client's per-character table of 0xC0 byte rows (a76): where it lives for every accepted agent count, and its one instruction field.

`cg + 0x70950 + n * 0xC0` (FUN_140945FD0) holds 42 rows in the stock game and ends at cg + 0x728D0, where the next member of the client object starts. With
-agent-capacity the character number reaches C - 1 = n + 17, so the component moves the table to the tail of cg (after the flags). Offline, for n = 24..320:
  - the table starts after the flags, is aligned to 16 and ends inside the object (client_size), whatever n;
  - at 24 agents the table has the 42 stock rows and the object grew by less than 0x30 bytes before it;
  - the one instruction field (`add rdx, 0x70950` at 0x140946FD0) is the shipped one, holds the stock offset, and is the only instruction of the image that
    names an offset of the stock rows (ops/engine/client-tables.json agrees with the image);
  - agent_capacity.cpp patches exactly that field with the layout's offset; the formulas of the hpp are pinned.
The image checks skip when the analysed image of docs/ENGINE.md is not on the machine.
"""
import importlib.util
import json
import os
import re
import struct
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
HPP = os.path.join(ROOT, 'src', 'native', 'agent_capacity.hpp')
CPP = os.path.join(ROOT, 'src', 'native', 'agent_capacity.cpp')
ROWS = os.path.join(ROOT, 'ops', 'engine', 'client-tables.json')
sys.path.insert(0, os.path.join(ROOT, 'ops', 'engine'))
import state_sites as ss  # noqa: E402

SITE_FIELD = 0x140946FD3


def layout(n):
    """agent_capacity.hpp, in Python: the pieces the table offset depends on."""
    c = 18 + n
    growth = (c - 42) * 0x2CA0
    flags = 0xFDEA8 + growth
    table = (flags + c + 15) & ~15
    return dict(characters=c, flags=flags, table=table, size=(table + c * 0xC0 + 15) & ~15)


def image_or_skip(test):
    path, _ = ss.image_path()
    if not os.path.exists(path):
        test.skipTest('no analysed image (docs/ENGINE.md)')
    return ss.Image(path)


class ClientTable(unittest.TestCase):
    def test_the_hpp_formulas_are_the_mirror(self):
        hpp = open(HPP, encoding='utf-8').read()
        self.assertIn('constexpr std::uint32_t client_char_table() const { return (client_flags() + characters + 15) & ~15u; }', hpp)
        self.assertIn('constexpr std::uint32_t client_size() const { return (client_char_table() + characters * 0xC0 + 15) & ~15u; }', hpp)

    def test_the_table_lies_behind_the_flags_inside_the_object(self):
        for n in range(24, 321, 4):
            l = layout(n)
            self.assertEqual(l['table'] % 16, 0, n)
            self.assertGreaterEqual(l['table'], l['flags'] + l['characters'], n)
            self.assertGreaterEqual(l['size'], l['table'] + l['characters'] * 0xC0, n)
            self.assertLess(l['size'] - (l['table'] + l['characters'] * 0xC0), 16, n)

    def test_at_24_agents_the_object_grew_by_the_flags_and_the_rows_only(self):
        l = layout(24)
        self.assertEqual(l['characters'], 42)
        self.assertEqual(l['table'] - 0xFDEA8, 0x38)       # the 42 flag bytes, aligned
        self.assertEqual(l['size'] - l['table'], 42 * 0xC0)

    def test_the_stock_rows_end_where_another_member_starts(self):
        self.assertEqual(0x70950 + 42 * 0xC0, 0x728D0)
        # the reach of the old layout: row n writes 16 bytes at +0x24 of 0xC0 byte rows
        self.assertEqual(0x70950 + 76 * 0xC0, 0x74250)
        self.assertEqual(0x70950 + 76 * 0xC0 + 0x24 + 4, 0x74278)

    def test_the_cpp_patches_the_field_with_the_layout_offset(self):
        cpp = open(CPP, encoding='utf-8').read()
        self.assertIn('add(0x%X, 0x70950, l.client_char_table());' % SITE_FIELD, cpp)

    def test_the_json_names_one_field_and_the_image_agrees(self):
        data = json.load(open(ROWS))
        self.assertEqual([t['name'] for t in data['tables']], ['char_c0'])
        sites = data['tables'][0]['sites']
        self.assertEqual([s['field'] for s in sites], [SITE_FIELD])
        img = image_or_skip(self)
        s = sites[0]
        self.assertEqual(img.read(s['at'], len(s['bytes']) // 2).hex(), s['bytes'])
        self.assertEqual(struct.unpack('<I', img.read(SITE_FIELD, 4))[0], 0x70950)

    def test_no_other_instruction_names_the_stock_rows(self):
        image_or_skip(self)
        import sqlite3
        db = os.path.join(os.path.dirname(os.path.dirname(ss.image_path()[0])), 'iw7-insn-index.sqlite')
        if not os.path.exists(db):
            self.skipTest('no instruction index (ops/engine/engine.py index)')
        c = sqlite3.connect('file:%s?mode=ro' % db, uri=True)
        # every displacement and immediate in the 42 rows (0x70950..0x728D0) in the whole image. Besides the table's own field, read one by one: 0x71E48 is the
        # `lea` of the renderer object's destructor FUN_1405EA6A0, 0x71E58 nine times the server's entity handle tables (FUN_14043xxxx, `[r+rax*8+0x71E58]`), 0x72073 a constant, 0x714E8 a `test eax` mask in the packer's code (0x14128AC36), 0x71E0C a negative displacement in the protector span (0x14C1473AE), 0x72000 a `lea` of the server (FUN_140AC0FA0)
        rows = c.execute("select value, text from insn where value between ? and ? and kind in ('disp', 'imm')", (0x70950, 0x728CF)).fetchall()
        got = sorted(r[0] for r in rows)
        self.assertEqual(got, [0x70950, 0x714E8, 0x71E0C, 0x71E48] + [0x71E58] * 9 + [0x72000, 0x72073], [(hex(r[0]), r[1]) for r in rows])
        self.assertEqual([r[1] for r in rows if r[0] == 0x70950], ['add rdx, 0x70950'])


if __name__ == '__main__':
    unittest.main()
