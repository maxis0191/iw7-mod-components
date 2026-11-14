"""cave_plan.py: encoder, window, fixups, every refusal rule, merging and the self-check. No game, no engine database."""
import copy
import importlib.util
import json
import os
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, '..', '..', 'ops', 'engine', 'cave_plan.py')
spec = importlib.util.spec_from_file_location('cave_plan', TOOL)
cp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cp)

BASE = 0x140001000


def image(code, pad=0x40, data=b''):
    """`code` after `pad` nops at BASE; an optional read-only data region at 0x141000000."""
    body = b'\x90' * pad + code + b'\x90' * 0x40
    regions = [(BASE, body, True)]
    if data:
        regions.append((0x141000000, data, False))
    return cp.PlainImage(regions), BASE + pad


def req(address, **kw):
    r = {'address': address, 'kind': 'disp'}
    r.update(kw)
    return r


def refused(test, requests, img, *needles):
    with test.assertRaises(cp.Refusal) as ctx:
        cp.plan(requests, img)
    text = ' | '.join(ctx.exception.reasons)
    for n in needles:
        test.assertIn(n, text)
    return text


def one(code, kw, pad=0x40):
    img, at = image(code, pad)
    (cave,) = cp.plan([req(at, **kw)], img)
    return cave, at


class Encoder(unittest.TestCase):
    def test_disp8_to_disp32_no_sib(self):
        cave, at = one(bytes.fromhex('8b4310') + b'\x90\x90', {'new_disp': 0x3F08})  # mov eax,[rbx+0x10]
        self.assertEqual(cave['cave_bytes'], '8b83083f0000' + '9090')
        self.assertEqual(cave['window_len'], 5)
        self.assertEqual(cave['return_address'], hex(at + 5))

    def test_disp8_to_disp32_with_sib(self):
        cave, _ = one(bytes.fromhex('8b4c1a18'), {'new_disp': 0x3F10, 'force32': True})  # mov ecx,[rdx+rbx+0x18] (4 bytes)
        self.assertEqual(cave['cave_bytes'], '8b8c1a103f0000' + '90')
        self.assertEqual(cave['window_len'], 5)

    def test_rex_and_trailing_immediate(self):
        cave, _ = one(bytes.fromhex('41807c3f1000'), {'new_disp': 0x3F08})  # cmp byte [r15+rdi+0x10],0
        self.assertEqual(cave['cave_bytes'], '4180bc3f083f000000')
        cave, _ = one(bytes.fromhex('837c1a2400'), {'new_disp': 0x3F1C})  # cmp dword [rdx+rbx+0x24],0
        self.assertEqual(cave['cave_bytes'], '83bc1a1c3f000000')
        self.assertEqual(cave['window_len'], 5)

    def test_disp8_stays_8_bit_when_it_fits(self):
        cave, _ = one(bytes.fromhex('8b4310') + b'\x90\x90', {'new_disp': 0x20})
        self.assertEqual(cave['cave_bytes'], '8b4320' + '9090')

    def test_equal_disp_with_force32_means_the_same(self):
        cave, _ = one(bytes.fromhex('8b4c1a14'), {'new_disp': 0x14, 'force32': True})
        self.assertEqual(cave['cave_bytes'], '8b8c1a14000000' + '90')

    def test_no_displacement_becomes_disp8_or_disp32(self):
        cave, _ = one(bytes.fromhex('8b03') + b'\x90\x90\x90', {'new_disp': 0x10})            # mov eax,[rbx]
        self.assertEqual(cave['cave_bytes'][:6], '8b4310')
        cave, _ = one(bytes.fromhex('8b03') + b'\x90\x90\x90', {'new_disp': 0x10, 'force32': True})
        self.assertEqual(cave['cave_bytes'][:12], '8b8310000000')
        cave, _ = one(bytes.fromhex('8b041a') + b'\x90\x90', {'new_disp': 0x1000})            # mov eax,[rdx+rbx] (SIB)
        self.assertEqual(cave['cave_bytes'][:14], '8b841a00100000')

    def test_every_modrm_form_decodes_to_the_same_operand(self):
        """The ModRM/SIB mod 01 -> 10 encoder against capstone, over rex x opcode x mod x rm x sib x displacement."""
        checked = refusals = 0
        for rex in (b'', b'\x41', b'\x42', b'\x4c', b'\x49'):
            for opcode in (b'\x8b', b'\x89', b'\x3b', b'\x0f\xb6'):
                for mod in (0, 1, 2):
                    for rm in range(8):
                        for sib in (range(256) if rm == 4 else (None,)):
                            for d in (0, 0x24, -4, 0x7F, 0x1000):
                                if mod == 1 and not -128 <= d <= 127:
                                    continue
                                body = bytes([(mod << 6) | (2 << 3) | rm]) + (bytes([sib]) if sib is not None else b'')
                                if mod == 1:
                                    body += struct.pack('<b', d)
                                elif mod == 2 or (mod == 0 and ((rm == 5) or (sib is not None and sib & 7 == 5))):
                                    body += struct.pack('<i', d)
                                raw = rex + opcode + body + b'\x90' * 5
                                ins = next(cp.MD.disasm(raw, 0x1000, 1))
                                if ins.size != len(raw) - 5:
                                    continue
                                for new in (0x3F1C, -0x100, 5):
                                    for f32 in (False, True):
                                        try:
                                            out = cp.reencode_disp(bytes(ins.bytes), ins, new, f32)
                                        except cp.Refusal:
                                            refusals += 1
                                            continue
                                        n = next(cp.MD.disasm(out + b'\x90' * 8, 0x1000, 1))
                                        self.assertEqual(n.size, len(out), (raw.hex(), out.hex()))
                                        a, b = cp._operand_key(ins, True), cp._operand_key(n, True)
                                        want = [o[:5] + (new,) + o[6:] if o[0] == 'm' else o for o in a[2]]
                                        self.assertEqual((a[0], a[1], tuple(want)), b, (raw.hex(), out.hex()))
                                        checked += 1
        self.assertGreater(checked, 5000)
        self.assertGreater(refusals, 100)  # rip-relative and register forms refuse


class Fixups(unittest.TestCase):
    def test_rip_relative_neighbour_becomes_a_fixup(self):
        # mov eax,[rbx+0x10] ; lea rcx,[rip+0x100]
        code = bytes.fromhex('8b4310') + bytes.fromhex('488d0d00010000')
        cave, at = one(code, {'new_disp': 0x3F08})
        lea_at = at + 3
        (fx,) = cave['fixups']
        self.assertEqual(fx['size'], 4)
        self.assertEqual(fx['offset'], 6 + 3)             # after the 6-byte re-encoded mov and the 3 opcode bytes
        self.assertEqual(fx['end'], 6 + 7)
        self.assertEqual(int(fx['target'], 0), lea_at + 7 + 0x100)
        self.assertEqual(cave['window_len'], 10)
        # applied for another cave address the target is the same absolute address
        b = cp.apply_fixups(bytes.fromhex(cave['cave_bytes']), cave['fixups'], 0x150002000)
        ins = cp.decode(b, 0x150002000)[1]
        self.assertEqual(ins.address + ins.size + ins.operands[1].mem.disp, lea_at + 7 + 0x100)

    def test_fixup_end_is_past_a_trailing_immediate(self):
        # mov eax,[rbx+0x10] ; cmp dword [rip+0x40],5   (disp32 followed by an imm8)
        code = bytes.fromhex('8b4310') + bytes.fromhex('833d4000000005')
        cave, at = one(code, {'new_disp': 0x3F08})
        (fx,) = cave['fixups']
        self.assertEqual(fx['end'], fx['offset'] + 4 + 1)
        self.assertEqual(int(fx['target'], 0), at + 3 + 7 + 0x40)

    def test_other_rip_relative_forms_become_fixups(self):
        code = bytes.fromhex('8b4310') + bytes.fromhex('8b0520000000')  # mov eax,[rip+0x20]
        cave, at = one(code, {'new_disp': 0x3F08})
        self.assertEqual(len(cave['fixups']), 1)
        self.assertEqual(int(cave['fixups'][0]['target'], 0), at + 3 + 6 + 0x20)


class Refusals(unittest.TestCase):
    def test_ret(self):
        img, at = image(bytes.fromhex('8b4310') + b'\xc3')
        refused(self, [req(at, new_disp=0x3F08)], img, 'return')

    def test_int3(self):
        img, at = image(bytes.fromhex('8b4310') + b'\xcc\x90')
        refused(self, [req(at, new_disp=0x3F08)], img, 'int3')

    def test_relative_jmp_jcc_call_loop(self):
        for tail, name in ((b'\xeb\x05', 'jmp'), (b'\x74\x05', 'je'), (b'\xe9\x10\x00\x00\x00', 'jmp'),
                           (b'\x0f\x84\x10\x00\x00\x00', 'je'), (b'\xe2\xfe', 'loop')):
            img, at = image(bytes.fromhex('8b4310') + tail)
            refused(self, [req(at, new_disp=0x3F08)], img, 'relative ' + name)

    def test_no_call_of_any_form(self):
        """A call leaves a return address in cave memory (no unwind data): refused, relative or through a register or memory."""
        for tail in ('e810000000', 'ffd0', 'ff1520000000', 'ff5008', '41ffd3'):
            img, at = image(bytes.fromhex('8b4310') + bytes.fromhex(tail))
            refused(self, [req(at, new_disp=0x3F08)], img, 'call', 'unwind')
        img, at = image(bytes.fromhex('ff5008') + bytes.fromhex('909090'))
        refused(self, [req(at, new_disp=0x3F08)], img, 'call')
        img, at = image(bytes.fromhex('8b4310') + bytes.fromhex('9090'))
        refused(self, [req(at, kind='bytes', new_bytes='ffd0')], img, 'position independent')

    def test_dry_run_reports_each_site_alone(self):
        code = bytes.fromhex('8b4310') + bytes.fromhex('90' * 10) + bytes.fromhex('8b4310') + bytes.fromhex('ffd0')
        img, at = image(code)
        rows = cp.dry_run([req(at, new_disp=0x3F08), req(at + 13, new_disp=0x3F08)], img)
        self.assertEqual([r['status'] for r in rows], ['accepted', 'refused'])
        self.assertIn('call', ' '.join(rows[1]['reasons']))

    def test_interior_target_by_rel8_rel32_and_jump_table(self):
        code = bytes.fromhex('8b4310') + b'\x90\x90\x90'  # interior instruction at at+3
        for label, build in (
                ('rel8', lambda at: b'\xeb' + bytes([(at + 3 - (at + 0x20 + 2)) & 0xFF])),
                ('rel32', lambda at: b'\xe9' + struct.pack('<i', at + 4 - (at + 0x20 + 5))),
                ('rel32', lambda at: b'\x0f\x85' + struct.pack('<i', at + 3 - (at + 0x20 + 6)))):
            img, at = image(code + b'\x90' * (0x20 - len(code)) + build(BASE + 0x40))
            refused(self, [req(at, new_disp=0x3F08)], img, label, 'inside the window')
        img, at = image(code, data=struct.pack('<I', at_rva(BASE + 0x40 + 3)))
        refused(self, [req(at, new_disp=0x3F08)], img, 'rva32')
        img, at = image(code, data=struct.pack('<Q', BASE + 0x40 + 3))
        refused(self, [req(at, new_disp=0x3F08)], img, 'abs64')

    def test_interior_target_from_the_database(self):
        class Db:
            def into(self, lo, hi):
                return [('db:refs/code', 0x140009999, lo + 1)] if lo <= BASE + 0x43 < hi else []
        img, at = image(bytes.fromhex('8b4310') + b'\x90\x90\x90')
        with self.assertRaises(cp.Refusal) as ctx:
            cp.plan([req(at, new_disp=0x3F08)], img, Db())
        self.assertIn('db:refs/code', str(ctx.exception))

    def test_a_byte_that_only_looks_like_a_branch_is_dropped_with_the_function_decode(self):
        # shl rdx,6 is 48 c1 e2 06: `e2 06` read as a loop lands inside the next instruction's window
        code = bytes.fromhex('48c1e206') + bytes.fromhex('2b4c1a14') + bytes.fromhex('83e964') + bytes.fromhex('90909090')
        img, at = image(code, pad=0)

        class Db:
            def function_range(self, address):
                return (BASE, BASE + len(code) + 0x40)

            def into(self, lo, hi):
                return []
        refused(self, [req(BASE + 4, new_disp=0x14, force32=True)], img, 'rel8', 'inside the window')
        (cave,) = cp.plan([req(BASE + 4, new_disp=0x14, force32=True)], img, Db())
        self.assertEqual(cave['cave_bytes'][:14], '2b8c1a14000000')

        class Desync(Db):  # a function range that does not start on an instruction of the window: no trust
            def function_range(self, address):
                return (BASE + 1, BASE + len(code) + 0x40)
        refused(self, [req(BASE + 4, new_disp=0x14, force32=True)], img, 'rel8')

    def test_a_branch_to_the_window_start_is_fine(self):
        code = bytes.fromhex('8b4310') + b'\x90\x90\x90' + b'\x90' * 0x1D + b'\xe9' + struct.pack('<i', -(0x23 + 5))
        img, at = image(code)
        (cave,) = cp.plan([req(at, new_disp=0x3F08)], img)
        self.assertEqual(cave['window_len'], 5)

    def test_duplicate_request(self):
        img, at = image(bytes.fromhex('8b4310') + b'\x90\x90')
        refused(self, [req(at, new_disp=0x3F08), req(at, new_disp=0x3F0C)], img, 'same instruction')

    def test_operand_forms(self):
        img, at = image(bytes.fromhex('89d8') + b'\x90' * 4)                  # mov eax,ebx: register
        refused(self, [req(at, new_disp=8)], img, 'ModRM')
        img, at = image(bytes.fromhex('8b0500010000') + b'\x90')               # rip-relative
        refused(self, [req(at, new_disp=8)], img, 'rip-relative')
        img, at = image(bytes.fromhex('b801000000') + b'\x90' * 4)             # no memory operand
        refused(self, [req(at, new_disp=8)], img, 'memory operand')
        img, at = image(bytes.fromhex('62f17c48108310') + b'\x90' * 4)         # EVEX
        refused(self, [req(at, new_disp=8)], img, '')

    def test_bytes_kind_must_be_position_independent(self):
        img, at = image(bytes.fromhex('8b4310') + b'\x90\x90')
        refused(self, [req(at, kind='bytes', new_bytes='e800000000')], img, 'position independent')
        refused(self, [req(at, kind='bytes', new_bytes='488d0d00000000')], img, 'position independent')
        refused(self, [req(at, kind='bytes', new_bytes='ff')], img, 'decode')

    def test_displacement_out_of_range(self):
        img, at = image(bytes.fromhex('8b4310') + b'\x90\x90')
        refused(self, [req(at, new_disp=0x80000000)], img, '32 bits')

    def test_not_at_an_instruction_boundary_of_a_merged_window(self):
        img, at = image(bytes.fromhex('8b4310') + bytes.fromhex('8b4318'))
        refused(self, [req(at, new_disp=0x3F08), req(at + 1, new_disp=0x3F08)], img, 'boundary')


class Merging(unittest.TestCase):
    def test_two_changed_instructions_in_one_window(self):
        img, at = image(bytes.fromhex('8b4310') + bytes.fromhex('8b4b18') + b'\x90' * 4)
        cave = cp.plan([req(at, new_disp=0x3F08), req(at + 3, new_disp=0x3F10)], img)
        self.assertEqual(len(cave), 1)
        c = cave[0]
        self.assertEqual(len(c['changes']), 2)
        self.assertEqual(c['window_len'], 6)
        self.assertEqual(c['cave_bytes'], '8b83083f0000' + '8b8b103f0000')
        self.assertEqual(c['return_address'], hex(at + 6))

    def test_overlapping_windows_merge_but_separate_ones_do_not(self):
        code = bytes.fromhex('8b4310') + bytes.fromhex('8b4b18') + b'\x90' * 4 + bytes.fromhex('8b4310') + b'\x90\x90'
        img, at = image(code)
        caves = cp.plan([req(at + 3, new_disp=0x3F10), req(at, new_disp=0x3F08), req(at + 10, new_disp=0x3F08)], img)
        self.assertEqual([c['window_start'] for c in caves], [hex(at), hex(at + 10)])
        self.assertEqual(len(caves[0]['changes']), 2)

    def test_window_that_needs_a_third_instruction_to_cover_both(self):
        img, at = image(bytes.fromhex('8b4310') + bytes.fromhex('8b4b18') + bytes.fromhex('90909090'))
        caves = cp.plan([req(at, new_disp=0x3F08), req(at + 3, new_disp=0x3F10)], img)
        self.assertEqual(caves[0]['window_len'], 6)


class SelfCheck(unittest.TestCase):
    def entry(self):
        img, at = image(bytes.fromhex('8b4310') + bytes.fromhex('488d0d00010000'))
        (cave,) = cp.plan([req(at, new_disp=0x3F08)], img)
        win = cp._window(img, at)
        return cave, win

    def test_good_entry_passes(self):
        cave, win = self.entry()
        cp.self_check(cave, win)

    def test_wrong_displacement_is_caught(self):
        cave, win = self.entry()
        bad = copy.deepcopy(cave)
        bad['cave_bytes'] = '8b83093f0000' + bad['cave_bytes'][12:]
        with self.assertRaises(cp.Refusal) as ctx:
            cp.self_check(bad, win)
        self.assertIn('displacement', str(ctx.exception))

    def test_wrong_register_and_wrong_opcode_are_caught(self):
        cave, win = self.entry()
        for wrong in ('8b8b083f0000', '8b83083f00', '8b93083f0000', '8a83083f0000'):
            bad = copy.deepcopy(cave)
            bad['cave_bytes'] = wrong + bad['cave_bytes'][12:]
            with self.assertRaises(cp.Refusal):
                cp.self_check(bad, win)

    def test_missing_or_wrong_fixup_is_caught(self):
        cave, win = self.entry()
        bad = copy.deepcopy(cave)
        bad['fixups'] = []
        with self.assertRaises(cp.Refusal):
            cp.self_check(bad, win)
        bad = copy.deepcopy(cave)
        bad['fixups'][0]['target'] = hex(int(bad['fixups'][0]['target'], 0) + 4)
        with self.assertRaises(cp.Refusal):
            cp.self_check(bad, win)

    def test_extra_instruction_is_caught(self):
        cave, win = self.entry()
        bad = copy.deepcopy(cave)
        bad['cave_bytes'] += '90'
        with self.assertRaises(cp.Refusal):
            cp.self_check(bad, win)


class CommandLine(unittest.TestCase):
    def run_tool(self, *args):
        return subprocess.run([sys.executable, '-B', TOOL, *args], capture_output=True, text=True)

    def test_emit_cpp_and_refusal_exit_code(self):
        img, at = image(bytes.fromhex('8b4310') + bytes.fromhex('488d0d00010000'))
        (cave,) = cp.plan([req(at, new_disp=0x3F08)], img)
        with tempfile.TemporaryDirectory() as d:
            plan_path = os.path.join(d, 'plan.json')
            Path(plan_path).write_text(json.dumps({'version': 1, 'caves': [cave]}))
            r = self.run_tool('--emit-cpp', plan_path)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn(f'{at:#x}ull', r.stdout)
            self.assertIn('0x8b,0x83,0x08,0x3f,0x00,0x00', r.stdout)
            self.assertIn(f'{{9,13,{at + 3 + 7 + 0x100:#x}ull}}', r.stdout)
            out = os.path.join(d, 'plan.out.json')
            r = self.run_tool(os.path.join(d, 'nothing.json'), '-o', out, '--image', os.path.join(d, 'no-image.exe'))
            self.assertNotEqual(r.returncode, 0)
            self.assertFalse(os.path.exists(out))

    def test_refusal_writes_nothing(self):
        # drive the real command on a minimal PE image: one section of code with a ret in the window
        code = b'\x90' * 0x40 + bytes.fromhex('8b4310') + b'\xc3' + b'\x90' * 0x40
        pe = bytearray(0x400 + 0x1000)
        pe[0:2] = b'MZ'
        struct.pack_into('<I', pe, 0x3C, 0x80)
        pe[0x80:0x84] = b'PE\0\0'
        struct.pack_into('<H', pe, 0x80 + 6, 1)           # one section
        struct.pack_into('<H', pe, 0x80 + 20, 0xF0)       # optional header size
        struct.pack_into('<Q', pe, 0x80 + 24 + 24, 0x140000000)
        sec = 0x80 + 24 + 0xF0
        pe[sec:sec + 8] = b'.text\0\0\0'
        struct.pack_into('<IIII', pe, sec + 8, 0x1000, 0x1000, 0x1000, 0x400)
        struct.pack_into('<I', pe, sec + 36, 0x60000020)
        pe[0x400:0x400 + len(code)] = code
        with tempfile.TemporaryDirectory() as d:
            exe, rq, out = (os.path.join(d, n) for n in ('image.exe', 'rq.json', 'out.json'))
            Path(exe).write_bytes(bytes(pe))
            Path(rq).write_text(json.dumps([req(0x140001040, new_disp=0x3F08)]))
            r = self.run_tool(rq, '-o', out, '--image', exe, '--db', os.path.join(d, 'none.sqlite'))
            self.assertEqual(r.returncode, 2, r.stderr)
            self.assertIn('return', r.stderr)
            self.assertFalse(os.path.exists(out))
            Path(rq).write_text(json.dumps([req(0x140001040, new_disp=0x3F08)]))
            pe[0x400 + 0x43] = 0x90                       # no ret now: the plan is written
            Path(exe).write_bytes(bytes(pe))
            r = self.run_tool(rq, '-o', out, '--image', exe, '--db', os.path.join(d, 'none.sqlite'))
            self.assertEqual(r.returncode, 0, r.stderr)
            plan = json.loads(Path(out).read_text())
            self.assertEqual(plan['caves'][0]['cave_bytes'][:12], '8b83083f0000')


def at_rva(address):
    return address - 0x140000000


if __name__ == '__main__':
    unittest.main()
