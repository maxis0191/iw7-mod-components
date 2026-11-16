"""Net field widths and the byte of the agent count above 256 characters (a57), checked offline against the analysed image.

  - ops/engine/net_rows.py: the generated table src/native/agent_capacity_net_rows.inc equals the descriptor lists of the image, holds the
    one 8 bit clientNum row of list 32 (0x141BB7C08), no row of the player state lists, and no row the clientNum loops of the component patch;
  - agent_capacity.cpp widens those rows only when layout::wide_net_fields() (more than 256 characters) and checks every row's offset first;
  - the three readers of GameStateInfo +0x546 (SV init, the client snapshot ring, getmaxagents) become `mov r32, imm32 n` of the same length,
    only above 255 agents; the byte itself and the G_GetMaxAgents clamp carry min(n, 255).
Needs the analysed image of the RE lab (IW7_RE_LAB); the text checks run everywhere.
"""
import importlib.util
import os
import re
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
CPP = os.path.join(ROOT, 'src', 'native', 'agent_capacity.cpp')
HPP = os.path.join(ROOT, 'src', 'native', 'agent_capacity.hpp')
INC = os.path.join(ROOT, 'src', 'native', 'agent_capacity_net_rows.inc')
sys.path.insert(0, os.path.join(ROOT, 'ops', 'engine'))
import net_rows  # noqa: E402
import state_sites as ss  # noqa: E402


def read(path):
    with open(path, encoding='utf-8') as f:
        return f.read()


def image():
    path, _ = ss.image_path()
    return ss.Image(path) if os.path.exists(path) else None


def table_rows():
    return [(int(a, 16), int(o, 16), int(b)) for a, o, b in
            re.findall(r'^\{(0x[0-9A-F]+)ull, (0x[0-9A-F]+)u, (\d+)u\},$', read(INC), re.M)]


def net_id_bits(c):
    return 7 if c <= 127 else (8 if c <= 256 else 9)


class NetRowsText(unittest.TestCase):
    def test_the_component_widens_the_rows_only_above_256_characters(self):
        cpp, hpp = read(CPP), read(HPP)
        self.assertIn('constexpr bool wide_net_fields() const { return characters > 256; }', hpp)
        self.assertIn('constexpr std::uint32_t net_id_bits() const { return characters <= 127 ? 7 : (characters <= 256 ? 8 : 9); }', hpp)
        body = cpp[cpp.index('if (l.wide_net_fields()) {'):]
        body = body[:body.index('\n    }\n') + 7]
        self.assertIn('#include "agent_capacity_net_rows.inc"', body)
        self.assertIn('if (d[0] != r.offset) throw', body)
        self.assertIn('add(r.field, r.bits, l.net_id_bits(), 4, false);', body)

    def test_the_table_is_sorted_and_has_no_duplicate(self):
        rows = table_rows()
        self.assertEqual(rows, sorted(rows))
        self.assertEqual(len({r[0] for r in rows}), len(rows))
        self.assertGreaterEqual(len(rows), 80)
        for _, _, bits in rows:
            self.assertTrue(6 <= bits <= 8)

    def test_every_count_has_the_width_its_numbers_need(self):
        for n in range(24, 321, 4):
            c = 18 + n
            self.assertGreaterEqual(1 << net_id_bits(c), c, f'{n} agents: character numbers 0..{c - 1} fit')
            self.assertEqual(c > 256, n >= 240)

    def test_the_gamestate_byte_and_its_readers(self):
        cpp, hpp = read(CPP), read(HPP)
        self.assertIn('constexpr std::uint32_t gamestate_agent_byte(std::uint32_t agents) { return agents < 255 ? agents : 255; }', hpp)
        self.assertIn('unsigned_imm8(gamestate_agent_byte(l.agents))', cpp)
        self.assertIn('add(0x140C18D77, stock_agents, gamestate_agent_byte(l.agents));', cpp)
        self.assertIn('if (l.agents > 255) {', cpp)
        for a in ('0x140C56AF8', '0x1409B266C', '0x140C1DD99'):
            self.assertRegex(cpp, r'block\(' + a + r', std::array<std::uint8_t, [78]>\{')


@unittest.skipIf(image() is None, 'no analysed image on this machine')
class NetRowsImage(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.img = image()

    def test_the_table_equals_the_image(self):
        self.assertEqual(read(INC), net_rows.emit_text(net_rows.rows(self.img)))

    def test_the_row_offsets_and_bits_are_the_shipped_ones(self):
        for field, offset, bits in table_rows():
            import struct
            d = struct.unpack('<III', self.img.read(field - 4, 12))
            self.assertEqual((d[0], d[1]), (offset, bits), hex(field))

    def test_the_clientnum_rows(self):
        rows = {r[0]: r for r in table_rows()}
        self.assertIn(0x141BB7C08, rows)                            # list 32: clientNum, 8 bits, never patched before a57
        self.assertEqual(rows[0x141BB7C08][1:], (0x9C, 8))
        mine = net_rows.client_num_rows(self.img)
        self.assertEqual(len(mine), 24)
        self.assertFalse(set(mine) & set(rows), 'the 24 rows the clientNum loops patch are not in the table')
        cpp = read(CPP).lower()
        for a in mine:
            self.assertIn('0x%xull' % a, cpp, hex(a))

    def test_no_player_state_row(self):
        lists = net_rows.read_lists(self.img)
        skipped = set()
        for i in net_rows.SKIPPED_LISTS:
            ptr, count = lists[i]
            skipped.update(ptr + 12 * k + 4 for k in range(count))
        self.assertFalse(skipped & {r[0] for r in table_rows()})

    def test_the_three_value_readers_become_immediates_of_the_same_length(self):
        from capstone import Cs, CS_ARCH_X86, CS_MODE_64
        cs = Cs(CS_ARCH_X86, CS_MODE_64)
        cpp = read(CPP)
        sites = {0x140C56AF8: ('movzx', 7, 'edi'), 0x1409B266C: ('movzx', 8, 'r14d'), 0x140C1DD99: ('movzx', 7, 'ecx')}
        for address, (mnemonic, size, reg) in sites.items():
            raw = self.img.read(address, size)
            i, = [x for x in cs.disasm(raw, address)][:1]
            self.assertEqual((i.mnemonic, i.size), (mnemonic, size))
            self.assertTrue(i.op_str.startswith(reg + ', byte ptr [') and i.op_str.endswith('+ 0x546]'), i.op_str)
            m = re.search(r'block\(0x%X, std::array<std::uint8_t, %d>\{([^}]*)\},\s*std::array<std::uint8_t, %d>\{([^}]*)\}' % (address, size, size), cpp)
            self.assertIsNotNone(m, hex(address))
            self.assertEqual(bytes(int(x, 16) for x in m.group(1).split(',')), raw)
            for n in range(256, 321, 4):
                new = {0x140C56AF8: bytes([0xbf, n & 0xff, n >> 8, 0, 0, 0x90, 0x90]),
                       0x1409B266C: bytes([0x41, 0xbe, n & 0xff, n >> 8, 0, 0, 0x90, 0x90]),
                       0x140C1DD99: bytes([0xb9, n & 0xff, n >> 8, 0, 0, 0x90, 0x90])}[address]
                ins = list(cs.disasm(new, address))
                self.assertEqual((ins[0].mnemonic, ins[0].op_str), ('mov', f'{reg}, {n:#x}'), f'{n}')
                self.assertEqual(sum(x.size for x in ins), size)
                self.assertTrue(all(x.mnemonic == 'nop' for x in ins[1:]))
        # the one-byte consumers that stay: only nonzero tests of the byte (cmp byte [+0x546], 0), checked by instruction
        for a in (0x1406E6542, 0x1406E6580, 0x1406E68C7, 0x1406E6917):
            i = next(cs.disasm(self.img.read(a, 7), a))
            self.assertEqual((i.mnemonic, i.op_str.endswith('+ 0x546], 0')), ('cmp', True), hex(a))


if __name__ == '__main__':
    unittest.main()
