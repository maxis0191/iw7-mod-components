"""Renderer parameter list overflow (a52): the two rewritten overflow branches against the shipped code.

FUN_140E2D9D0 and FUN_140E2FF80 reserve 1 or 2 records of 32 bytes (`lock xadd` on 0x149FF3E18) from a list of 1,024 at 0x149FF3E1C. The stock full-list
branch calls the renderer warning and goes on with a null buffer (a client crash at about 1,170 records) and leaves the count past 0x400. The patch
(agent_capacity.cpp `plan_render_list`) gives the reservation back, raises the same warning and returns by a short jump to a `jmp` of the stock lights overflow
branch, which ends at the function's epilogue. Offline: the shipped window is the one the patch names, the new bytes decode to the intended instructions,
every target is where the shipped code has it, nothing the epilogue reloads is left unwritten, and the patch overlaps no other row.
Skipped when neither the unpacked code files nor the analysed image exist on the machine.
"""
import importlib.util
import os
import re
import struct
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
CPP = os.path.join(ROOT, 'src', 'native', 'agent_capacity.cpp')

spec = importlib.util.spec_from_file_location('sites_test', os.path.join(HERE, 'agent_capacity_sites_test.py'))
st = importlib.util.module_from_spec(spec)
spec.loader.exec_module(st)
cp = st.cp

COUNT, LIST, HOOK = 0x149FF3E18, 0x149FF3E1C, 0x140E4B0B0
SITES = {
    # window start, stock length, function entry, jump target (the stock `jmp` of the lights overflow), that jump's own target (the epilogue)
    0x140E2DAA0: dict(length=31, func=0x140E2D9D0, short_to=0x140E2DB09, epilogue=0x140E2DE30, stores_r12=False),
    0x140E30046: dict(length=30, func=0x140E2FF80, short_to=0x140E300BE, epilogue=0x140E3031C, stores_r12=True),
}


def parse_blocks(text):
    out = {}
    for m in re.finditer(r'block\(\s*(0x[0-9A-Fa-f]+),\s*std::array<std::uint8_t,\s*(\d+)>\{([^}]*)\},\s*std::array<std::uint8_t,\s*\d+>\{([^}]*)\}', text):
        a = int(m.group(1), 16)
        out[a] = (bytes(int(x, 16) for x in re.findall(r'0x[0-9A-Fa-f]+', m.group(3))), bytes(int(x, 16) for x in re.findall(r'0x[0-9A-Fa-f]+', m.group(4))))
    return out


class RenderList(unittest.TestCase):
    def setUp(self):
        self.image, _ = st.find_image()
        if self.image is None:
            self.skipTest('no unpacked code files or analysed image on this machine')
        text = open(CPP, encoding='utf-8').read()
        body = text.split('void plan_render_list()')[1].split('\n}\n')[0]
        self.blocks = parse_blocks(body)
        self.cs = cp._cs()

    def test_both_windows_are_in_the_plan_and_are_the_shipped_bytes(self):
        self.assertEqual(sorted(self.blocks), sorted(SITES))
        for a, spec in SITES.items():
            old, new = self.blocks[a]
            self.assertEqual(len(old), spec['length'])
            self.assertEqual(len(new), spec['length'], 'same length: an in-place patch, no cave')
            self.assertEqual(self.image.read(a, len(old)), old, f'{a:#x} the stock window')
        self.assertIn('plan_render_list();', open(CPP, encoding='utf-8').read().split('plan_snapshot();')[1][:80])

    def test_the_stock_window_is_the_full_list_branch(self):
        """mov rdx,rcx; mov r8d,0x400; shl rdx,5; mov ecx,0x9a; ...; call the warning; jmp over the null branch: reached only by the `ja` after the
        `lock xadd` + `lea eax,[rcx+r..]` + `cmp eax,0x400` of the reservation."""
        for a, spec in SITES.items():
            old, _ = self.blocks[a]
            ins = list(self.cs.disasm(old, a))
            text = [f'{i.mnemonic} {i.op_str}' for i in ins]
            self.assertEqual(text[:4], ['mov rdx, rcx', 'mov r8d, 0x400', 'shl rdx, 5', 'mov ecx, 0x9a'])
            self.assertEqual(ins[-2].mnemonic, 'call')
            self.assertEqual(int(ins[-2].op_str, 16), HOOK)
            self.assertEqual(ins[-1].mnemonic, 'jmp')
        # the reservation: `lock xadd [0x149FF3E18], r32; lea eax,[rcx+r]; cmp eax,0x400; ja window`
        for a, xadd_at, n in ((0x140E2DAA0, 0x140E2DA79, 20), (0x140E30046, 0x140E30022, 18)):
            ins = list(self.cs.disasm(self.image.read(xadd_at, n), xadd_at))
            text = [f'{i.mnemonic} {i.op_str}' for i in ins]
            self.assertEqual(len(text), 4, text)
            self.assertTrue(text[0].startswith('lock xadd dword ptr [rip'), text[0])
            self.assertEqual(ins[0].address + ins[0].size + ins[0].operands[0].mem.disp, COUNT)
            self.assertTrue(text[1].startswith('lea eax, [rcx + r'))
            self.assertEqual(text[2], 'cmp eax, 0x400')
            self.assertEqual(text[3].split(' ')[0], 'ja')
            self.assertEqual(int(text[3].split(' ')[1], 16), a, 'the branch into the window')

    def test_the_new_bytes_give_the_reservation_back_warn_and_leave(self):
        for a, spec in SITES.items():
            _, new = self.blocks[a]
            ins = list(self.cs.disasm(new, a))
            text = [f'{i.mnemonic} {i.op_str}' for i in ins]
            # lock sub dword ptr [rip + disp], ecx: the count 0x149FF3E18 (ecx still holds the record count of the model)
            first = ins[0]
            self.assertEqual(first.bytes[:3].hex(), 'f0290d', 'lock sub [rip+d32], ecx')
            self.assertEqual(first.address + first.size + struct.unpack('<i', first.bytes[3:7])[0], COUNT)
            tail = [t for t in text[1:] if not t.startswith('nop')]
            if spec['stores_r12']:
                self.assertEqual(tail[0], 'mov qword ptr [rsp + 0x78], r12', 'the epilogue reloads r12 from this slot, which the stock code writes later')
                tail = tail[1:]
            else:
                self.assertEqual(tail[:2], ['mov edx, ecx', 'shl edx, 5'])
                tail = tail[2:]
            self.assertEqual(tail[:2], ['mov r8d, 0x400', 'mov ecx, 0x9a'])
            call = ins[-2] if text[-1].startswith('nop') is False else ins[-3]
            jmp = ins[-1] if not text[-1].startswith('nop') else ins[-2]
            self.assertEqual(call.mnemonic, 'call')
            self.assertEqual(int(call.op_str, 16), HOOK, 'the same renderer warning, raised as before')
            self.assertEqual(jmp.mnemonic, 'jmp')
            self.assertEqual(jmp.size, 2, 'a short jump')
            self.assertEqual(int(jmp.op_str, 16), spec['short_to'])
            # no register the stock code needs after the window is written: only rcx/rdx/r8 (volatile) and, in the second function, the slot of r12
            for i in ins:
                for r in ('r14', 'r15', 'rbx', 'rdi', 'rsi', 'rbp'):
                    self.assertNotIn(r, i.op_str, f'{a:#x} {i.mnemonic} {i.op_str}')

    def test_the_short_jump_lands_on_the_lights_overflow_jump_which_ends_at_the_epilogue(self):
        for a, spec in SITES.items():
            land = next(self.cs.disasm(self.image.read(spec['short_to'], 5), spec['short_to']))
            self.assertEqual((land.mnemonic, land.size), ('jmp', 5))
            self.assertEqual(int(land.op_str, 16), spec['epilogue'], f'{a:#x} the lights overflow branch returns by this jump')
            ep = list(self.cs.disasm(self.image.read(spec['epilogue'], 0x48), spec['epilogue']))
            self.assertIn('ret', [i.mnemonic for i in ep])
            # everything the epilogue reloads from the stack is stored before the window (or by the window)
            reloads = {i.op_str.split(', ')[1] for i in ep if i.mnemonic == 'mov' and i.op_str.startswith(('r12, qword ptr [rsp', 'r14, qword ptr [rsp', 'r15, qword ptr [rsp', 'rsi, qword ptr [rsp', 'rbp, qword ptr [rsp'))}
            stores = {i.op_str.split(', ')[0] for i in list(self.cs.disasm(self.image.read(spec['func'], a - spec['func']), spec['func']))
                      if i.mnemonic == 'mov' and i.op_str.startswith('qword ptr [rsp')}
            if spec['stores_r12']:
                stores.add('qword ptr [rsp + 0x78]')
            for slot in reloads:
                self.assertIn(slot, stores, f'{a:#x} the epilogue reloads {slot} which is not stored before the window')

    def test_the_count_and_the_list_are_what_the_comment_says(self):
        """FUN_140E328E0 copies count x 32 bytes from the list; the list holds 0x400 records up to the next table (the light count)."""
        copy = list(self.cs.disasm(self.image.read(0x140E328E0, 0x4D), 0x140E328E0))
        text = [f'{i.mnemonic} {i.op_str}' for i in copy]
        self.assertIn('shl r8, 5', text)
        self.assertIn(0x149FF3E1C, [i.address + i.size + i.operands[1].mem.disp for i in copy if i.mnemonic == 'lea' and i.operands[1].mem.base == 41])
        self.assertEqual(LIST + 0x400 * 0x20, 0x149FFBE1C, 'the next static is the lights count: the list ends exactly at it')


if __name__ == '__main__':
    unittest.main()
