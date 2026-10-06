"""Synthetic unwind tests: no retail scan, decoder or engine required."""
import struct
import unittest

from xref_owners import IMAGE, RDATA, Owners, ranked_roots, retained_roots
from inspect_retained import INPUTS


class OwnershipTests(unittest.TestCase):
    def fixture(self, cycle=False, missing=False):
        root = (0x1000, 0x1010, RDATA - IMAGE)
        child = (0x1010, 0x1020, RDATA - IMAGE + 16)
        tail = (0x1030, 0x1040, RDATA - IMAGE + 48)
        rdata = bytearray(80)
        rdata[0] = 1
        # One unwind code => the chain structure starts after padded code slots.
        rdata[16:20] = bytes([0x21, 0, 1, 0])
        struct.pack_into('<III', rdata, 24, *(tail if cycle else root))
        rdata[48:52] = bytes([0x21, 0, 0, 0])
        struct.pack_into('<III', rdata, 52, *child)
        records = [child, tail] if missing else [root, child, tail]
        return Owners(b''.join(struct.pack('<III', *r) for r in records), rdata), root

    def test_chain_union_preserves_disjoint_spans(self):
        owners, root = self.fixture()
        self.assertFalse(owners.errors)
        self.assertEqual(owners.spans(root), [[IMAGE + 0x1000, IMAGE + 0x1020],
                                            [IMAGE + 0x1030, IMAGE + 0x1040]])
        self.assertEqual(len(owners.groups[root]), 3)

    def test_cycle_is_rejected(self):
        owners, root = self.fixture(cycle=True)
        self.assertEqual(len(owners.errors), 2)
        self.assertEqual(len(owners.groups[root]), 1)

    def test_missing_parent_is_rejected(self):
        owners, _ = self.fixture(missing=True)
        self.assertEqual(len(owners.errors), 2)
        self.assertFalse(owners.groups)

    def test_uncaptured_unwind_is_rejected(self):
        owners = Owners(struct.pack('<III', 0x1000, 0x1010, 4), b'')
        self.assertEqual(len(owners.errors), 1)

    def test_cached_parents_do_not_bypass_depth_bound(self):
        rows = [(0x1000 + i * 16, 0x1010 + i * 16, RDATA - IMAGE + i * 32) for i in range(34)]
        data = bytearray(len(rows) * 32)
        data[0] = 1
        for i in range(1, len(rows)):
            data[i * 32] = 0x21
            struct.pack_into('<III', data, i * 32 + 4, *rows[i - 1])
        owners = Owners(b''.join(struct.pack('<III', *r) for r in rows), data)
        self.assertEqual(len(owners.errors), 2)
        self.assertEqual(len(owners.groups[rows[0]]), 32)


class SelectionTests(unittest.TestCase):
    def test_pool_and_exact_caller_precede_32_owner_quota(self):
        rows = {i: [{'target': '0x143f9b358', 'access': 'write'}] for i in range(40)}
        rows[100] = [{'target': '0x143c986b0', 'access': 'read'}]
        rows[101] = [{'target': '0x143c986b8', 'access': 'address'}]
        rows[102] = [{'target': '0x143c986c0', 'access': 'write'}]
        rows[103] = [{'target': '0x140c1a190', 'access': 'call'}]
        ranked = ranked_roots(rows)
        self.assertEqual(ranked[:4], [102, 101, 103, 100])
        self.assertTrue(all(root in ranked[:32] for root in (100, 101, 102, 103)))
        self.assertEqual(ranked[4:8], [0, 1, 2, 3])

    def test_exact_caller_cannot_be_starved_by_pool_readers(self):
        rows = {i: [{'target': '0x143c986b8', 'access': 'read'}] for i in range(74)}
        rows[100] = [{'target': '0x140c1a190', 'access': 'call'}]
        self.assertEqual(ranked_roots(rows)[0], 100)

    def test_non_pool_writer_does_not_promote_pool_reader(self):
        rows = {1: [{'target': '0x143c986b8', 'access': 'read'},
                    {'target': '0x143f9b358', 'access': 'write'}],
                2: [{'target': '0x140c1a190', 'access': 'call'}]}
        self.assertEqual(ranked_roots(rows), [2, 1])

    def report(self, count=149):
        return {'schema': 'iw7.agent-capacity-xrefs/1',
                'input_hashes': {name: digest for name, digest in INPUTS.values()},
                'matching_owners': count,
                'selected_owners': [{'root': hex(IMAGE+i*16)} for i in range(min(32,count))],
                'excluded_owners': [{'root': hex(IMAGE+i*16)} for i in range(32,count)]}

    def test_reuse_all_149_without_losing_excluded_owners(self):
        self.assertEqual(len(retained_roots(self.report())), 149)

    def test_refuse_duplicate_coverage_hash_and_bound(self):
        for kind in ('duplicate', 'coverage', 'hash', 'bound', 'schema'):
            report = self.report(257 if kind == 'bound' else 149)
            if kind == 'duplicate': report['excluded_owners'][0] = report['selected_owners'][0]
            if kind == 'coverage': report['matching_owners'] += 1
            if kind == 'hash': report['input_hashes']['unpacked-text.bin'] = '0'*64
            if kind == 'schema': report['schema'] = 'unknown'
            with self.subTest(kind=kind), self.assertRaises(ValueError): retained_roots(report)


if __name__ == '__main__':
    unittest.main()
