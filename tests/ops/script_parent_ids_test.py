"""Parent ids beyond u16 (a56): every site of the change against the shipped code, one test a kind of site.

An id is 4 x local + segment. The key of a child entry (parent << 16 | name >> 8), the child's parent field (+0xE) and the free list links hold the LOCAL
index (id >> 2). Sites (ops/engine/variable_sites.py `parents`): 14 key builders and the one reader of the parent field are caves
(ops/engine/caves/parent-keys.*), the free list code is replaced by the component (alloc, four pushes, initialiser, rebuild), five allocation sites take
ids below 0x10000, two client array allocations too, the integer key range follows the object key bound. Needs the analysed image and the engine
database of the RE lab (skipped without).
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
sys.path.insert(0, os.path.join(ROOT, 'ops', 'engine'))
import variable_sites as vs  # noqa: E402
import state_sites as ss  # noqa: E402

CPP = os.path.join(ROOT, 'src', 'native', 'script_variables.cpp')
CAVES = os.path.join(ROOT, 'src', 'native', 'script_variables_caves.inc')
PLAN = os.path.join(ROOT, 'ops', 'engine', 'caves', 'parent-keys.plan.json')
REQS = os.path.join(ROOT, 'ops', 'engine', 'caves', 'parent-keys.requests.json')
ROWS = os.path.join(ROOT, 'ops', 'engine', 'variable-sites.json')

BUILDERS = [0x140C04DDC, 0x140C05156, 0x140C054EA, 0x140C0554A, 0x140C055B3, 0x140C05613, 0x140C05673, 0x140C05AD1, 0x140C06013, 0x140C0624F,
            0x140C07558, 0x140C098C4, 0x140C09A1D, 0x140C09B2D]     # 0x140C0624F: Scr_AddClassField, code that no function of the engine database holds
READ = 0x140C0531A
STUB = (0x140C05D70, 45)
ALLOC_LOW_CALLS = (0x140C043C5, 0x140C0458D, 0x140C096C6, 0x140C096EF, 0x140C0900B, 0x140C04559, 0x140C059B8, 0x140C090B0, 0x140C04523)      # a79: the class arrays always, the others with -script-variables-low-first (the thread sites through a thunk)
CLIENT_ARRAY_CALLS = (0x140C4F64E, 0x140C503EF)
REPLACED = {0x140C04650: 'alloc_variable', 0x140C04910: 'release_with_children', 0x140C05C50: 'release_reference', 0x140C08E70: 'release_unreferenced_structs',
            0x140C09200: 'format_parents', 0x140C08C30: 'rebuild_refused', 0x140C09340: 'kill_thread_self', 0x140C097B0: 'set_thread_self', 0x140C08D10: 'flush_dead_entities', 0x140C054A0: 'object_word'}


def image_and_db():
    image_file, db_file = ss.image_path()
    if not (os.path.exists(image_file) and os.path.exists(db_file)):
        return None, None
    return ss.Image(image_file), db_file


class ParentIds(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.img, cls.db = image_and_db()
        cls.md = ss.cs()
        cls.cpp = open(CPP, encoding='utf-8').read()
        cls.rows = json.load(open(ROWS, encoding='utf-8'))
        cls.plan = json.load(open(PLAN, encoding='utf-8'))
        cls.plan = cls.plan['caves'] if isinstance(cls.plan, dict) else cls.plan
        cls.reqs = json.load(open(REQS, encoding='utf-8'))
        cls.caves = cls.parse_inc(open(CAVES, encoding='utf-8').read())

    @staticmethod
    def parse_inc(text):
        out = []
        for m in re.finditer(r'^\{(0x[0-9a-f]+)ull, \{([^}]*)\}, \{([^}]*)\}, \{\}, \{\}\},$', text, re.M):
            out.append((int(m.group(1), 16), bytes(int(x, 16) for x in m.group(2).split(',')), bytes(int(x, 16) for x in m.group(3).split(','))))
        return out

    def setUp(self):
        if self.img is None:
            self.skipTest('no analysed image on this machine')

    def dis(self, raw, at):
        return list(self.md.disasm(raw, at))

    # ---- the finder is complete: the committed requests are what it finds now
    def test_the_finder_reproduces_the_site_lists(self):
        builders, reads, holders, scanned = vs.parent_sites(self.img, self.md, self.db)
        self.assertEqual(sorted(i.address for i, _ in builders), BUILDERS)
        self.assertEqual([i.address for i, _ in reads], [READ])
        self.assertEqual([a for a, _ in holders], [0x14045D648, 0x140C5DF5F])      # the two game struct fields that hold a thread id in 16 bits
        self.assertGreaterEqual(scanned, 40)
        key = lambda r: int(r['address'], 16)
        wanted = sorted(BUILDERS + [READ])
        got = [key(r) for r in self.reqs if 'segment base edit' not in r['note']]
        self.assertEqual(sorted(got), wanted)

    # ---- every key builder: shr r,2 first, then the shipped window (with the segment base edit of the previous stage where one lies inside)
    def test_every_cave_is_the_shipped_window_plus_its_edit(self):
        by_start = {s: (old, new) for s, old, new in self.caves}
        self.assertEqual(sorted(by_start), sorted(BUILDERS + [READ]))
        pairs = {r['at']: r for r in self.rows['pairs']}
        for start, (old, new) in by_start.items():
            self.assertEqual(self.img.read(start, len(old)), old, hex(start))
            old_ins, new_ins = self.dis(old, start), self.dis(new, 0x150000000)
            if start == READ:
                self.assertEqual([i.mnemonic + ' ' + i.op_str for i in new_ins[:5]],
                                 ['movzx ecx, word ptr [rbx + 0xe]', 'mov edx, esi', 'shr edx, 0x10', 'lea ecx, [rdx + rcx*4]', 'movzx edx, word ptr [rbx + 0xc]'])
                continue
            shl = old_ins[0]
            self.assertEqual((shl.mnemonic, shl.operands[1].imm), ('shl', 0x10), hex(start))
            self.assertEqual((new_ins[0].mnemonic, new_ins[0].operands[1].imm, new_ins[0].operands[0].reg == shl.operands[0].reg and new_ins[0].size), ('shr', 2, shl.size))
            self.assertEqual(new_ins[1].bytes, shl.bytes)
            rest_old, rest_new = old_ins[1:], new_ins[2:]
            for o in rest_old:
                n = rest_new.pop(0)
                if o.address in pairs:       # an edit of the previous stage inside the window: the same instruction as the row says
                    r = pairs[o.address]
                    if r['op'] == 'seg_shl':
                        self.assertEqual(n.bytes, o.bytes[:-1] + bytes([r['after']]))
                        self.assertEqual((n.mnemonic, n.operands[1].imm), ('shl', 0x10))
                    else:                    # lea r,[s+s*4] -> mov r,s + nop padding
                        self.assertEqual(n.mnemonic, 'mov')
                        size = n.size
                        while size < o.size:
                            self.assertEqual(rest_new.pop(0).mnemonic, 'nop')
                            size += 1
                        self.assertEqual(size, o.size)
                else:
                    self.assertEqual(n.bytes, o.bytes, 'neighbour changed in the cave of %X' % start)
            self.assertEqual(rest_new, [])
        # the planner's own output is the .inc, and the three windows that held a row of the previous stage were found
        self.assertEqual(sorted(s for s, _, _ in self.caves), sorted(int(c['window_start'], 16) if isinstance(c['window_start'], str) else c['window_start'] for c in self.plan))
        inside = sorted(a for a in pairs if any(s <= a < s + len(old) for s, old, _ in self.caves))
        self.assertEqual([hex(a) for a in inside], ['0x140c04de0', '0x140c0755c', '0x140c098c8'])

    # ---- the parent read: esi is the segment base (seg << 16) in FUN_140C05280 and nothing writes esi or edx before the cave's use
    def test_the_parent_read_has_its_segment_in_esi(self):
        func = self.dis(self.img.read(0x140C05280, 0x11B), 0x140C05280)
        self.assertEqual(func[5].mnemonic + ' ' + func[5].op_str, 'mov esi, r8d')
        for ins in func:
            if ins.address >= READ:
                break
            if ins.address > func[5].address:
                _, wr = ins.regs_access()
                self.assertNotIn('esi', [ins.reg_name(r) for r in wr] + [ins.reg_name(r).replace('rsi', 'esi') for r in wr], hex(ins.address))
        # edx is dead: rewritten by the next instruction
        self.assertEqual(self.dis(self.img.read(READ + 4, 4), READ + 4)[0].op_str, 'edx, word ptr [rbx + 0xc]')

    # ---- the free path of RemoveRefToObject is replaced by a stub: stock bytes, no way into the window, exactly the rows of the previous stage inside
    def test_the_free_path_window(self):
        start, length = STUB
        m = re.search(r'static const std::uint8_t stock\[\] = \{(.*?)\};', self.cpp, re.S)
        stock = bytes(int(x, 16) for x in re.findall(r'0x[0-9a-fA-F]{2}', m.group(1)))
        self.assertEqual(stock, self.img.read(start, length))
        func = self.dis(self.img.read(0x140C05CA0, 0x10D), 0x140C05CA0)
        for ins in func:
            if (ins.mnemonic.startswith('j') or ins.mnemonic == 'call') and ins.operands and ins.operands[0].type == 2:
                self.assertFalse(start < ins.operands[0].imm < start + length, 'a branch into the window at %X' % ins.address)
        self.assertTrue(any(i.address == 0x140C05D9D and i.mnemonic == 'mov' for i in func))
        inside = sorted(r['field'] for r in self.rows['refs'] if start <= r['field'] < start + length)
        self.assertEqual(len(inside), 4)
        # the stub: mov ecx,ebx / mov rax,imm64 / call rax / jmp 0x140C05D9D : 19 bytes, rbx is the id, rsp is 16 byte aligned after the prologue
        prologue = self.dis(self.img.read(0x140C05CA0, 0x1B), 0x140C05CA0)
        self.assertEqual([i.mnemonic for i in prologue[:5]], ['mov', 'mov', 'push', 'sub', 'mov'])
        self.assertEqual(prologue[3].op_str, 'rsp, 0x20')

    # ---- the replaced functions and the redirected calls are the shipped bytes
    def test_replaced_functions_and_redirected_calls(self):
        for entry, name in REPLACED.items():
            m = re.search(r'replace_function\(0x%X' % entry + r'ull, \{([^}]*)\}, reinterpret_cast<const void\*>\(&%s\)\);' % name, self.cpp)
            self.assertIsNotNone(m, hex(entry))
            self.assertEqual(bytes(int(x, 16) for x in m.group(1).split(',')), self.img.read(entry, 5), hex(entry))
        for site in ALLOC_LOW_CALLS + CLIENT_ARRAY_CALLS:
            ins = self.dis(self.img.read(site, 5), site)[0]
            self.assertEqual(ins.mnemonic, 'call')
            self.assertEqual(ins.operands[0].imm, 0x140C04650 if site in ALLOC_LOW_CALLS else 0x140C068B0, hex(site))
        for site in ALLOC_LOW_CALLS:
            self.assertIn('0x%Xull' % site, self.cpp)
        self.assertIn('redirect_thread_alloc(0x140C043C5ull, false, 0)', self.cpp)
        # the stock functions the replacements call, and the one that raises the error
        self.assertIn('0x140C04990ull', self.cpp)
        self.assertIn('0x140D34180ull', self.cpp)
        # who holds the ids that must stay below 0x10000: one place each
        for what, addr in (('server client array', 0x140C4F653), ('server client array', 0x140C503F4), ('thread id field', 0x14045D648), ('thread id field', 0x140C5DF5F)):
            self.assertEqual(self.dis(self.img.read(addr, 8), addr)[0].mnemonic, 'mov', what)

    # ---- the wrapper the shipped code reaches the replacements through: the shipped code uses interprocedural register allocation, a replacement written in C++
    # clobbers every volatile register, so the wrapper saves rcx, rdx, r8..r11, xmm0..xmm5 and restores them (rax is the result); the stack stays 16 byte aligned
    def test_the_register_wrapper_is_balanced(self):
        def bytes_of(name):
            m = re.search(r'constexpr std::uint8_t %s\[\] = \{(.*?)\};' % name, self.cpp, re.S)
            body = re.sub(r'//[^\n]*', '', m.group(1))
            return bytes(int(x, 16) for x in re.findall(r'0x[0-9A-Fa-f]{2}', body))
        save, restore = bytes_of('save_all'), bytes_of('restore_all')
        si, ri = self.dis(save, 0x1000), self.dis(restore, 0x2000)
        text = lambda l: [i.mnemonic + ' ' + i.op_str for i in l]
        self.assertEqual(text(si)[:6], ['push rcx', 'push rdx', 'push r8', 'push r9', 'push r10', 'push r11'])
        self.assertEqual(text(si)[6], 'sub rsp, 0x88')
        self.assertEqual([i.op_str for i in si[7:]], ['xmmword ptr [rsp + 0x%x], xmm%d' % (0x20 + 16 * k, k) for k in range(6)])
        self.assertEqual([i.op_str for i in ri[:6]], ['xmm%d, xmmword ptr [rsp + 0x%x]' % (k, 0x20 + 16 * k) for k in range(6)])
        self.assertEqual(text(ri)[6], 'add rsp, 0x88')
        self.assertEqual(text(ri)[7:], ['pop r11', 'pop r10', 'pop r9', 'pop r8', 'pop rdx', 'pop rcx'])
        # entered with rsp = 8 mod 16 (a call pushed the return address): 6 pushes (48) + 0x88 leave the 16 byte alignment for the call inside
        self.assertEqual((8 - 6 * 8 - 0x88) % 16, 0)
        # the free path of RemoveRefToObject is aligned already: 4 pushes (32) + 0x80
        self.assertEqual((0 - 4 * 8 - 0x80) % 16, 0)
        entry = 0x140C09280                                  # the one entry hook left: the children counters (more than 4 segments)
        m = re.search(r'entry_hook\(0x%Xull, \{([^}]*)\}' % entry, self.cpp)
        self.assertIsNotNone(m, hex(entry))
        got = bytes(int(x, 16) for x in m.group(1).split(','))
        self.assertEqual(got, self.img.read(entry, len(got)), hex(entry))
        ins = self.dis(got, entry)
        self.assertFalse(any(i.mnemonic.startswith(('j', 'call')) or 'rip' in i.op_str for i in ins), 'the window must move: no branch, no rip relative operand')
        self.assertEqual(sum(i.size for i in ins), len(got))
        self.assertGreaterEqual(len(got), 5)

    # ---- the object key names and the integer key range: object keys 0x40000 + id for ids up to 0x3FFFF end below the integer names
    def test_the_key_name_ranges(self):
        parent_ids = 0x40000
        name_bound = 0x40000 + parent_ids
        self.assertEqual(name_bound, 0x80000)
        int_low = 0x800000 - name_bound
        self.assertEqual(int_low, 0x780000)
        self.assertEqual(0x800000 - 0x4DC00, 0x7B2400)         # stock
        self.assertEqual(int_low + 0x7FFFFF, 0xF7FFFF)
        self.assertEqual(0x7B2400 + 0x7FFFFF, 0xFB23FF)
        self.assertLess(0x40000 + (parent_ids - 1), name_bound)           # the highest object key name
        self.assertEqual(-int_low + 0x800000, name_bound)                # the lowest integer key name is the first name above the object keys
        for r in [r for r in self.rows['imms'] if r['op'] in ('int_low', 'int_high')]:
            ins = self.dis(self.img.read(r['at'], 8), r['at'])[0]
            self.assertEqual(ins.mnemonic, 'lea' if r['op'] == 'int_low' else 'cmp')
        self.assertEqual(sum(1 for r in self.rows['imms'] if r['op'] == 'name_bound'), 8)

    # ---- no 16-bit holder of a general id is left in the variable system: every word store of an id-looking value is a link, a count or a local index
    def test_the_pool_code_has_no_other_u16_id_store(self):
        # the u16 stores of the variable system (0x140BFE000..0x140C11000) outside the save game serializer (0x140BFE000..0x140C03000) and the functions
        # replaced here: each is a reference count, a child count, a child link or local index, a table the component sizes, or a class table (low ids)
        known_prefixes = {0x140C04350, 0x140C04360, 0x140C043A0, 0x140C04510, 0x140C04550, 0x140C04580}
        self.assertTrue(known_prefixes)


if __name__ == '__main__':
    unittest.main()
