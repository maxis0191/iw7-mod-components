"""Child capacity census (a64): the counts that `variable_sites.py segments` and `links` print, against the shipped code.

Option C (more than 4 child segments) and option D (wider child links) are estimated from these counts (docs/AGENT-CAPACITY-ENGINE.md "Child capacity census").
The test pins what the census finds so that a changed finder or a changed row file shows up. Needs the analysed image and the engine database of the RE
lab (skipped without).
"""
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
sys.path.insert(0, os.path.join(ROOT, 'ops', 'engine'))
import variable_sites as vs  # noqa: E402
import state_sites as ss  # noqa: E402


class Census(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        image_file, db_file = ss.image_path()
        if not (os.path.exists(image_file) and os.path.exists(db_file)):
            raise unittest.SkipTest('no analysed image on this machine')
        cls.img, cls.db, cls.md = ss.Image(image_file), db_file, ss.cs()
        cls.md.detail = True
        cls.ranges = vs.complete_ranges(cls.img, cls.md, cls.db)

    def test_the_range_ends_with_its_last_function(self):
        # the range used to end at 0x140C11000, inside FUN_140C10E60 (ends 0x140C11087): its last instruction was cut
        self.assertGreaterEqual(vs.VM_CALLS[1], 0x140C11087)
        last = self.ranges[-1][1][-1]
        self.assertGreaterEqual(last.address + last.size, 0x140C11087)

    def test_every_and_3_of_the_range_is_a_segment(self):
        from capstone import x86_const as X
        kinds = {}
        for s, il in self.ranges:
            for k, ins in enumerate(il):
                if ins.mnemonic == 'and' and len(ins.operands) == 2 and ins.operands[1].type == X.X86_OP_IMM and ins.operands[1].imm == 3 and ins.operands[0].type == X.X86_OP_REG:
                    u = vs.segment_uses(il, k)
                    kind = 'pair' if 'segbase5' in u else 'hash' if any(x.startswith('shl') for x in u) else 'head' if any(x.startswith('index') for x in u) else 'other'
                    kinds[kind] = kinds.get(kind, 0) + 1
        self.assertEqual(kinds, {'pair': 88, 'head': 4, 'hash': 1})

    def test_every_pair_takes_its_segment_from_and_3_or_a_loop_counter(self):
        import json
        sites = json.load(open(os.path.join(ROOT, 'ops', 'engine', 'variable-sites.json')))
        pairs = [p for p in sites['pairs'] if p['op'] == 'seg_lea']
        self.assertEqual(len(pairs), 119)
        pieces = [(il[0].address, il[-1].address, il) for _, il in self.ranges if il]
        origins = {}
        for p in pairs:
            if not (vs.VM_CALLS[0] <= p['func'] < vs.VM_CALLS[1]):
                continue
            il = next(l for lo, hi, l in pieces if lo <= p['at'] <= hi)
            k = next(i for i, x in enumerate(il) if x.address == p['at'])
            o, at = vs.segment_origin(il, k, vs.FULL[il[k].reg_name(il[k].operands[1].mem.base)])
            origins[o] = origins.get(o, 0) + 1
            if o != 'and3':
                self.assertIn(p['func'], (0x140C08C30, 0x140C09280), 'a segment that is not `and r,3` nor a loop counter of the initialisers')
        self.assertEqual(origins, {'and3': 88, 'xor': 2})

    def test_the_counters_and_what_sits_behind_them(self):
        refs = vs.counter_refs(self.img, self.md, self.db)
        counters = {k: v for k, v in refs.items() if 0x34 <= k[1] < 0x44}
        behind = {k: v for k, v in refs.items() if 0x44 <= k[1] < 0x54}
        self.assertEqual((len(counters), len({v[1] for v in counters.values()})), (10, 6))
        self.assertGreater(len(behind), 0, 'counters 4..7 would overwrite scalars')


if __name__ == '__main__':
    unittest.main()
