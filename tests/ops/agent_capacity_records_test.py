"""Reserved scriptable records and part links (a42): the formulas of agent_capacity.hpp, mirrored, for every allowed count 24..232.

The component rebuilds the MapEnts scriptable block at load (agent_capacity.cpp section 4c): R(n) = max(200, n + 56) reserved records,
d = R - 200 copies of reserved record 0 inserted after the stock reserved ones, the fixed records shifted by d. Offline checks:
  - the text of the formulas in the hpp is pinned (a change there fails here until this mirror agrees);
  - for every allowed n the moved block is a permutation-with-copies of the old one: [0, 200) unchanged, [200, 200 + d) copies of record 0,
    [200 + d, total + d) the old records from 200 on (indexes of the fixed ones shift by d);
  - the three counts after the move: reserved R, server end 414 + d, total 523 + d; the entity field 0x78 (10 bits, index + 1) holds the total;
  - the part link default grows with n, never below 8,192, never above the u16 links' 65,535.
"""
import os
import re
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
HPP = os.path.join(HERE, '..', '..', 'src', 'native', 'agent_capacity.hpp')
CPP = os.path.join(HERE, '..', '..', 'src', 'native', 'agent_capacity.cpp')

COUNTS = list(range(24, 233, 4))
STOCK_RESERVED, STOCK_SERVER_END, STOCK_TOTAL, STOCK_AGENTS, MARGIN = 200, 414, 523, 24, 32
ENTITY_FIELD_BITS = 10   # entity type 6, descriptor offset 0x78 (net field list 0x141BB6480): index + 1 of a fixed scriptable


def reserved_records(n):
    return max(STOCK_RESERVED, STOCK_AGENTS + n + MARGIN)


def moved_source(i, reserved, added):
    return i if i < reserved else (0 if i < reserved + added else i - added)


def scriptable_parts(n):
    need = 0x800 + 32 * n + 1024
    return max(8192, (need + 1023) // 1024 * 1024)


def remapped_record_index(index, reserved, added, total):
    return index + added if reserved <= index < total else index


def turns_into_record(index, added, total):
    return total <= index < total + added


class Records(unittest.TestCase):
    def test_hpp_text_is_pinned(self):
        text = open(HPP, encoding='utf-8').read()
        self.assertIn('constexpr std::uint32_t stock_reserved_records = 200, reserved_record_margin = 32, record_bytes = 0x1D0;', text)
        self.assertIn('const auto need = stock_agents + agents + reserved_record_margin;', text)
        self.assertIn('return need > stock_reserved_records ? need : stock_reserved_records;', text)
        self.assertIn('return index < reserved ? index : (index < reserved + added ? 0 : index - added);', text)
        self.assertIn('const auto need = stock_parts + 32 * agents + 1024;', text)
        self.assertIn('const auto rounded = (need + 1023) / 1024 * 1024;', text)
        self.assertIn('return rounded > 8192 ? rounded : 8192;', text)

    def test_cpp_uses_the_formulas_and_the_guards(self):
        text = open(CPP, encoding='utf-8').read()
        self.assertIn('link_mapents_hook.create(0x1403B8610, link_mapents_stub);', text)
        self.assertIn('scriptable_parts(agents)', text)
        for needle in ('map ents guard a', 'map ents guard c', 'map ents link: call', 'moved_record_source(i, reserved, added)',
                       'reserved_records(L.agents)'):
            self.assertIn(needle, text)

    def test_reserved_count_every_allowed_n(self):
        for n in COUNTS:
            r = reserved_records(n)
            self.assertGreaterEqual(r, STOCK_RESERVED)
            self.assertGreaterEqual(r, STOCK_AGENTS + n + MARGIN)
            if n <= 144:
                self.assertEqual(r, STOCK_RESERVED, n)   # inert while the stock room is enough
        self.assertEqual(reserved_records(232), 288)
        self.assertEqual(reserved_records(100), 200)
        self.assertEqual(reserved_records(148), 204)

    def test_move_is_an_exact_rearrangement_every_allowed_n(self):
        old = list(range(STOCK_TOTAL))   # old record i is "i"
        for n in COUNTS:
            added = max(0, reserved_records(n) - STOCK_RESERVED)
            new = [old[moved_source(i, STOCK_RESERVED, added)] for i in range(STOCK_TOTAL + added)]
            self.assertEqual(len(new), STOCK_TOTAL + added)
            self.assertEqual(new[:STOCK_RESERVED], old[:STOCK_RESERVED])
            self.assertEqual(new[STOCK_RESERVED:STOCK_RESERVED + added], [0] * added)
            self.assertEqual(new[STOCK_RESERVED + added:], old[STOCK_RESERVED:])
            # every old record keeps exactly one place, record 0 additionally the added ones
            for k in range(1, STOCK_TOTAL):
                self.assertEqual(new.count(k), 1, (n, k))
            self.assertEqual(new.count(0), 1 + added)
            self.assertEqual(new.index(STOCK_SERVER_END - 1) - (STOCK_SERVER_END - 1), added)
            # counts after the move
            reserved, server_end, total = STOCK_RESERVED + added, STOCK_SERVER_END + added, STOCK_TOTAL + added
            self.assertEqual(reserved, max(STOCK_RESERVED, reserved_records(n)))
            self.assertLessEqual(reserved, server_end)
            self.assertLessEqual(server_end, total)
            self.assertLess(total, 1 << ENTITY_FIELD_BITS, n)

    def test_remap_text_is_pinned(self):
        hpp = open(HPP, encoding='utf-8').read()
        self.assertIn('return index >= reserved && index < total ? index + added : index;', hpp)
        self.assertIn('return index >= total && index < total + added;', hpp)
        self.assertIn('part_entry_bytes = 0x70, part_entry_type_offset = 0, part_entry_record_offset = 0x4C, part_type_record_link = 3, part_type_record_event = 4;', hpp)
        cpp = open(CPP, encoding='utf-8').read()
        for needle in ('remap_part_records(s, old_reserved, added, old_total, remap)', 'map ents remap: map', 'stale pointers into the old array',
                       '-agent-capacity-no-record-remap', 'S + 0x178 + 8 * group'.replace('S + 0x178 + 8 * group', 'base = *reinterpret_cast<std::uint8_t**>(s + 0x178 + 8 * group)'),
                       'std::uint16_t*>(entry + part_entry_record_offset)', 'guard d'):
            self.assertIn(needle, cpp)

    def test_remap_follows_the_move_every_allowed_n(self):
        # a stored index names the same old record after the move as before: the record at the new index is the old record the index meant
        for total, reserved in ((STOCK_TOTAL, STOCK_RESERVED), (60, 58)):   # cp_zmb and the frontend zone
            old = list(range(total))
            for n in COUNTS:
                added = max(0, reserved_records(n) - reserved)
                new = [old[moved_source(i, reserved, added)] for i in range(total + added)]
                for stored in range(total):
                    moved = remapped_record_index(stored, reserved, added, total)
                    self.assertLess(moved, total + added)
                    if stored >= reserved:
                        self.assertEqual(new[moved], stored, (total, n, stored))   # the same record
                        self.assertGreaterEqual(moved, reserved + added)           # never an inserted blank
                    else:
                        self.assertEqual(moved, stored)                            # a reserved record stays
                        self.assertEqual(new[moved], stored)
                # values at or above the old total are not records: they stay, and none may turn into one
                for stored in (total, total + 1, 0xFFFE, 0xFFFF):
                    self.assertEqual(remapped_record_index(stored, reserved, added, total), stored)
                if added:
                    self.assertTrue(turns_into_record(total, added, total))
                    self.assertTrue(turns_into_record(total + added - 1, added, total))
                    self.assertFalse(turns_into_record(total - 1, added, total))
                    self.assertFalse(turns_into_record(total + added, added, total))
                    self.assertFalse(turns_into_record(0xFFFF, added, total))
                else:
                    self.assertFalse(turns_into_record(total, 0, total))

    def test_old_a43_fault_without_the_remap(self):
        # the frontend zone: 58 reserved, 2 fixed (58, 59), n = 232 inserts 230 blanks; the stored 58 / 59 name blanks without the remap
        total, reserved, added = 60, 58, reserved_records(232) - 58
        self.assertEqual(added, 230)
        for stored in (58, 59):
            self.assertTrue(reserved <= stored < reserved + added)
            self.assertGreaterEqual(remapped_record_index(stored, reserved, added, total), reserved + added)

    def test_parts_default(self):
        previous = 0
        for n in COUNTS:
            p = scriptable_parts(n)
            self.assertGreaterEqual(p, 8192)
            self.assertLessEqual(p, 0xFFFF)
            self.assertEqual(p % 1024, 0)
            self.assertGreaterEqual(p, 0x800 + 31 * n + 1024)   # 31 links a zombie on top of the stock pool and a margin
            self.assertGreaterEqual(p, previous)
            previous = p
        self.assertEqual(scriptable_parts(24), 8192)
        self.assertEqual(scriptable_parts(100), 8192)
        self.assertEqual(scriptable_parts(164), 9216)
        self.assertEqual(scriptable_parts(232), 11264)


if __name__ == '__main__':
    unittest.main()
