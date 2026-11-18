"""Reserved scriptable records and part links (a42): the formulas of agent_capacity.hpp, mirrored, for every allowed count 24..320.

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

COUNTS = list(range(24, 321, 4))
STOCK_RESERVED, STOCK_SERVER_END, STOCK_TOTAL, STOCK_AGENTS, MARGIN = 200, 414, 523, 24, 32
ENTITY_FIELD_BITS = 10   # entity type 6, descriptor offset 0x78 (net field list 0x141BB6480): index + 1 of a fixed scriptable


def reserved_records(n, requested=0):
    if requested:
        return max(STOCK_RESERVED, requested)
    return max(STOCK_RESERVED, STOCK_AGENTS + n + MARGIN)


def moved_source(i, reserved, added):
    return i if i < reserved else (0 if i < reserved + added else i - added)


def scriptable_parts(n):
    need = 0x800 + 32 * n + 1024
    return max(8192, (need + 1023) // 1024 * 1024)


def remapped_record_index(index, reserved, added):
    return index + added if index >= reserved and index + added <= 0xFFFF else index


class Records(unittest.TestCase):
    def test_hpp_text_is_pinned(self):
        text = open(HPP, encoding='utf-8').read()
        self.assertIn('constexpr std::uint32_t stock_reserved_records = 200, reserved_record_margin = 32, record_bytes = 0x1D0;', text)
        self.assertIn('constexpr std::uint32_t default_reserved_records(std::uint32_t agents) {', text)
        self.assertIn('const auto need = stock_agents + agents + reserved_record_margin;', text)
        self.assertIn('return need > stock_reserved_records ? need : stock_reserved_records;', text)
        self.assertIn('constexpr std::uint32_t reserved_records(std::uint32_t agents, std::uint32_t requested = 0) {', text)
        self.assertIn('if (!requested) return default_reserved_records(agents);', text)
        self.assertIn('return requested > stock_reserved_records ? requested : stock_reserved_records;', text)
        self.assertIn('constexpr std::uint32_t most_scriptable_records = 700;', text)
        self.assertIn('return index < reserved ? index : (index < reserved + added ? 0 : index - added);', text)
        self.assertIn('const auto need = stock_parts + 32 * agents + 1024;', text)
        self.assertIn('const auto rounded = (need + 1023) / 1024 * 1024;', text)
        self.assertIn('return rounded > 8192 ? rounded : 8192;', text)

    def test_cpp_uses_the_formulas_and_the_guards(self):
        text = open(CPP, encoding='utf-8').read()
        self.assertIn('link_mapents_hook.create(0x1403B8610, link_mapents_stub);', text)
        self.assertIn('scriptable_parts(agents)', text)
        for needle in ('map ents guard a', 'map ents guard c', 'map ents link: call', 'moved_record_source(i, reserved, added)',
                       'const auto want = L.records;', '-scriptable-records', 'IW7_SCRIPTABLE_RECORDS', 'most_scriptable_records',
                       '"-r" + std::to_string(L.records)'):
            self.assertIn(needle, text)

    def test_reserved_count_every_allowed_n(self):
        for n in COUNTS:
            r = reserved_records(n)
            self.assertGreaterEqual(r, STOCK_RESERVED)
            self.assertGreaterEqual(r, STOCK_AGENTS + n + MARGIN)
            if n <= 144:
                self.assertEqual(r, STOCK_RESERVED, n)   # inert while the stock room is enough
        self.assertEqual(reserved_records(232), 288)
        self.assertEqual(reserved_records(320), 376)
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

    def test_requested_records_every_value(self):
        # -scriptable-records N (a89): R = max(200, N) at any agent count; the move is the same rearrangement, the 10 bit field 0x78 holds cp_zmb up to R = 700
        most = 700
        self.assertEqual(STOCK_TOTAL + most - STOCK_RESERVED, (1 << ENTITY_FIELD_BITS) - 1)   # index + 1 of the last record = 1,023
        old = list(range(STOCK_TOTAL))
        for requested in (0, 100, 200, 201, 376, 400, 512, 513, 600, most):
            for n in (24, 100, 232, 320):
                r = reserved_records(n, requested)
                self.assertGreaterEqual(r, STOCK_RESERVED)
                if requested:
                    self.assertEqual(r, max(STOCK_RESERVED, requested))
                added = r - STOCK_RESERVED
                new = [old[moved_source(i, STOCK_RESERVED, added)] for i in range(STOCK_TOTAL + added)]
                self.assertEqual(new[STOCK_RESERVED + added:], old[STOCK_RESERVED:])
                self.assertLessEqual(STOCK_TOTAL + added, (1 << ENTITY_FIELD_BITS) - 1)
        self.assertEqual(reserved_records(320, 512), 512)
        self.assertEqual(reserved_records(100, 300), 300)
        self.assertEqual(reserved_records(320, 50), 200)

    def test_stream_pool_blocks_follow_the_records(self):
        for requested in (200, 376, 512, 513, 640, 700):
            blocks = max(512, reserved_records(24, requested))
            self.assertGreaterEqual(blocks, requested)
        text = open(HPP, encoding='utf-8').read()
        self.assertIn('constexpr std::uint32_t stream_pool_blocks(std::uint32_t records) { return records > stream_pool_min_blocks ? records : stream_pool_min_blocks; }', text)

    def test_remap_text_is_pinned(self):
        hpp = open(HPP, encoding='utf-8').read()
        self.assertIn('return index >= reserved && index + added <= 0xFFFF ? index + added : index;', hpp)
        self.assertIn('part_entry_bytes = 0x70, part_entry_type_offset = 0, part_entry_record_offset = 0x4C, part_type_record_link = 3, part_type_record_event = 4;', hpp)
        cpp = open(CPP, encoding='utf-8').read()
        for needle in ('remap_part_records(s, old_reserved, added, old_total, remap)', 'map ents remap: map', 'stale pointers into the old array',
                       '-agent-capacity-no-record-remap', 'IW7_AGENT_CAPACITY_NO_RECORD_REMAP', 'count_unlinked_targets(s, block, reserved, total)', 'base = *reinterpret_cast<std::uint8_t**>(s + 0x178 + 8 * group)',
                       'std::uint16_t*>(entry + part_entry_record_offset)', 'remapped_record_index(index, reserved, added)'):
            self.assertIn(needle, cpp)

    def test_remap_keeps_every_stored_index_meaning_the_same(self):
        # a stored index names the same old record after the move; "no record" (>= the old total) stays "no record" (>= the new total)
        for total, reserved in ((STOCK_TOTAL, STOCK_RESERVED), (60, 58)):   # cp_zmb and the frontend zone
            old = list(range(total))
            for n in COUNTS:
                added = max(0, reserved_records(n) - reserved)
                new_total = total + added
                new = [old[moved_source(i, reserved, added)] for i in range(new_total)]
                for stored in range(0, total + 40):
                    moved = remapped_record_index(stored, reserved, added)
                    if stored < reserved:
                        self.assertEqual(moved, stored)                                      # a reserved record stays
                        self.assertEqual(new[moved], stored)
                    elif stored < total:
                        self.assertEqual(new[moved], stored, (total, n, stored))             # the same record
                        self.assertGreaterEqual(moved, reserved + added)                     # never an inserted blank
                    else:
                        self.assertGreaterEqual(moved, new_total, (total, n, stored))        # still no record
                for stored in (0xFFFE, 0xFFFF):
                    self.assertEqual(remapped_record_index(stored, reserved, added), stored if added else stored)
                    self.assertGreaterEqual(remapped_record_index(stored, reserved, added), new_total)

    def test_a43_fault_without_the_remap(self):
        # the frontend zone: 58 reserved, 2 fixed (58, 59), total 60; n = 232 inserts 230 blanks. Left as authored, the stored 60 (= no record)
        # is record 60 of 290 (an inserted blank: the crash of a43-p3a, record (0x12ADB79500 - 0x12ADB72840) / 0x1D0 = 60) and 58 / 59 name blanks.
        total, reserved = 60, 58
        added = reserved_records(232) - reserved
        self.assertEqual(added, 230)
        self.assertEqual((0x12ADB79500 - 0x12ADB72840) // 0x1D0, total)
        self.assertEqual((0x12ADB79500 - 0x12ADB72840) % 0x1D0, 0)
        for stored in (58, 59, 60):
            self.assertTrue(reserved <= stored < reserved + added)
        self.assertEqual(remapped_record_index(60, reserved, added), total + added)   # 290 = the new total: no record again
        self.assertEqual(remapped_record_index(58, reserved, added), 58 + added)      # the first fixed record at its new place

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
        self.assertEqual(scriptable_parts(320), 13312)


if __name__ == '__main__':
    unittest.main()
