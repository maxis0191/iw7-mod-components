"""frame_grow.py (cave_plan.py frame-grow): every change kind, every refusal, the self-check and the generated table.
Hand-built functions and a fake exception directory; no game, no engine image, no database."""
import copy
import importlib.util
import json
import os
import struct
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ENGINE = os.path.join(HERE, '..', '..', 'ops', 'engine')
sys.path.insert(0, ENGINE)
import cave_plan as cp  # noqa: E402
import frame_grow as fg  # noqa: E402
import unwind_info as uw  # noqa: E402

BASE = 0x140000000
CODE = 0x140001000
PDATA = 0x140100000
XDATA = 0x140200000
HANDLER = 0x140300000

# ---- tiny encoders ------------------------------------------------------------------------------------------------
MOV_R11_RSP = bytes.fromhex('4c8bdc')
PUSH_RBP, PUSH_RBX, POP_RBX, POP_RBP, RET = b'\x55', b'\x53', b'\x5b', b'\x5d', b'\xc3'
XOR_RAX_RSP = bytes.fromhex('4833c4')
CALL = bytes.fromhex('e800000000')


def i32(v):
    return struct.pack('<i', v)


def lea_rbp_r11(d):
    return bytes.fromhex('498dab') + i32(d)


def lea_rbp_r11_8(d):
    return bytes.fromhex('498d6b') + struct.pack('<b', d)


def sub_rsp(n):
    return bytes.fromhex('4881ec') + struct.pack('<I', n)


def sub_rsp8(n):
    return bytes.fromhex('4883ec') + bytes([n])


def add_rsp(n):
    return bytes.fromhex('4881c4') + struct.pack('<I', n)


def store_rbp(d):          # mov [rbp+d32], rax
    return bytes.fromhex('488985') + i32(d)


def store_rbp8(d):         # mov [rbp+d8], rax
    return bytes.fromhex('488945') + struct.pack('<b', d)


def load_rbp(d):           # mov rax, [rbp+d32]
    return bytes.fromhex('488b85') + i32(d)


def load_rbp_rcx(d):       # mov rcx, [rbp+d32]
    return bytes.fromhex('488b8d') + i32(d)


def movaps_load_rsp(d):    # movaps xmm6, [rsp+d32]
    return bytes.fromhex('0f28b424') + i32(d)


def movaps_load_rsp8(d):   # movaps xmm6, [rsp+d8]
    return bytes.fromhex('0f28742400'.replace('00', '', 1)[:8]) if False else bytes.fromhex('0f287424') + struct.pack('<b', d)


def movaps_save_r11(d8):   # movaps [r11+d8], xmm6
    return bytes.fromhex('410f2973') + struct.pack('<b', d8)


def store_rsp(d8, reg=b'\x48\x89\x4c\x24'):   # mov [rsp+d8], rcx
    return reg + bytes([d8])


def lea_rdx_rsp(d):
    return bytes.fromhex('488d9424') + i32(d)


def lea_rdx_rsp_idx(d):    # lea rdx, [rsp+rax*8+d32]
    return bytes.fromhex('488d94c4') + i32(d)


def mov_rbx_rsp():
    return bytes.fromhex('488bdc')


def store_rsp_idx(d):      # mov [rsp+rax*8+d32], rcx
    return bytes.fromhex('488984c4') + i32(d)


# ---- unwind records ----------------------------------------------------------------------------------------------
def code_push(off, reg):
    return bytes([off, 0x00 | (reg << 4)])


def code_alloc_large(off, size):
    return bytes([off, 0x01]) + struct.pack('<H', size // 8)


def code_alloc_small(off, size):
    return bytes([off, 0x02 | (((size - 8) // 8) << 4)])


def code_save_xmm(off, xmm, offset):
    return bytes([off, 0x08 | (xmm << 4)]) + struct.pack('<H', offset // 16)


def unwind(codes, prolog, flags=3, handler=HANDLER, data=0x2C0, chain=None, version=1, frame=0):
    raw = b''.join(codes)
    count = sum(len(c) // 2 for c in codes)
    out = bytearray([version | (flags << 3), prolog, count, frame]) + raw
    if len(out) % 4:
        out += b'\x00' * (4 - len(out) % 4)
    if flags & 4:
        out += struct.pack('<III', *chain)
    elif flags & 3:
        out += struct.pack('<I', handler - BASE)
        if data is not None:
            out += struct.pack('<I', data)
    return bytes(out)


class Fn:
    """A function and its unwind data in a fake image. Frame 0x300 (2 pushes), cookie slot at S+0x2C0, array below it."""

    def __init__(self, body=None, frame=0x300, unwind_codes=None, prolog=None, handler_data=0x2C0, flags=3, chunks=None, handler=HANDLER,
                 version=1):
        self.frame = frame
        parts = body if body is not None else self.default_body(frame)
        self.code = b''.join(parts)
        self.addr = CODE
        self.end = CODE + len(self.code)
        self.unwind_codes = unwind_codes
        self.flags, self.handler_data, self.handler, self.version = flags, handler_data, handler, version
        self.prolog = prolog
        self.chunks = chunks

    @staticmethod
    def default_body(frame):
        # S = r11 - 0x10 - frame; rbp = S + 0x100
        return [MOV_R11_RSP, PUSH_RBP, PUSH_RBX, lea_rbp_r11(-(0x10 + frame - 0x100)), sub_rsp(frame),
                store_rbp(0x1C0), movaps_save_r11(-0x28),
                store_rsp(0x30), load_rbp_rcx(-0x40), CALL, load_rbp(0x1C0), XOR_RAX_RSP, movaps_load_rsp(0x2E0), load_rbp(0x1C0),
                add_rsp(frame), POP_RBX, POP_RBP, RET]

    def image(self, patch_unwind=None):
        # prologue offsets of the default body: mov r11 (3), push (1), push (1), lea (7), sub (7)
        sub_end = 3 + 1 + 1 + 7 + 7
        codes = self.unwind_codes
        if codes is None:
            codes = [code_save_xmm(sub_end + 7 + 5, 6, 0x2E0), code_alloc_large(sub_end, self.frame), code_push(5, 3), code_push(4, 5)]
        prolog = self.prolog if self.prolog is not None else sub_end + 12
        records = [unwind(codes, prolog, self.flags, self.handler, self.handler_data, version=self.version)]
        entries = [(self.addr - BASE, self.end - BASE, 0)]
        if self.chunks:
            records, entries = self.chunks(self, records)
        xdata = b''
        offsets = []
        for r in records:
            offsets.append(len(xdata))
            xdata += r + b'\x00' * (-len(r) % 4)
        pdata = b''.join(struct.pack('<III', b, e, (XDATA - BASE) + (offsets[u] if isinstance(u, int) and u < len(offsets) else u))
                         for b, e, u in entries)
        img = cp.PlainImage([(CODE, self.code + b'\xcc' * 0x20, True), (PDATA, pdata, False), (XDATA, xdata + b'\x00' * 64, False),
                             (HANDLER, b'\xc3' * 16, True)], BASE)
        img.exception_directory = (PDATA, len(entries))
        return img


def plan(fn, extra=0x40, max_extra=None, top=0x2C0, image=None, **kw):
    img = image or fn.image()
    return fg.plan_frame_grow(img, fn.addr, top, extra, max_extra, gs_handlers=(HANDLER,), **kw), img


def refused(test, fn, *needles, extra=0x40, max_extra=None, top=0x2C0, image=None):
    with test.assertRaises(cp.Refusal) as ctx:
        plan(fn, extra, max_extra, top, image)
    text = ' | '.join(ctx.exception.reasons)
    for n in needles:
        test.assertIn(n, text)
    return text


class Plan(unittest.TestCase):
    def test_every_change_kind_and_the_self_check(self):
        doc, img = plan(Fn(), 0x40)
        roles = [f['role'] for f in doc['fields']]
        self.assertEqual(roles.count('frame-base'), 1)
        self.assertEqual(roles.count('frame-sub'), 1)
        self.assertEqual(roles.count('epilogue-add'), 1)
        self.assertEqual(roles.count('access-high'), 4)         # cookie store + 2 cookie loads + the movaps [rsp+0x2E0]
        self.assertEqual(roles.count('unwind-alloc'), 1)
        self.assertEqual(roles.count('unwind-gs-cookie'), 1)
        self.assertEqual(roles.count('unwind-save'), 1)
        self.assertIsNone(doc['cave'])
        by = {f['role']: f for f in doc['fields']}
        self.assertEqual((by['frame-sub']['stock'], by['frame-sub']['width'], by['frame-sub']['sign']), (0x300, 4, 1))
        self.assertEqual((by['frame-base']['stock'], by['frame-base']['sign']), ((-0x210) & 0xFFFFFFFF, -1))
        self.assertEqual((by['unwind-alloc']['stock'], by['unwind-alloc']['unit']), (0x60, 8))
        self.assertEqual((by['unwind-save']['stock'], by['unwind-save']['unit']), (0x2E, 16))
        self.assertEqual((by['unwind-gs-cookie']['stock'], by['unwind-gs-cookie']['width']), (0x2C0, 4))
        # no field touches the stack accesses below the array top ([rsp+0x30], [rbp-0x40], the r11-based xmm save)
        addrs = {int(f['address'], 0) for f in doc['fields']}
        self.assertNotIn(CODE + len(Fn.default_body(0x300)[0]), addrs)

    def test_apply_matches_the_arithmetic_of_the_run_time(self):
        doc, img = plan(Fn(), 0x40)
        code, patches, cave = fg.apply_plan(img, doc, 0x40)
        ins = cp.decode(code, CODE)
        sub = next(i for i in ins if i.mnemonic == 'sub')
        add = next(i for i in ins if i.mnemonic == 'add')
        self.assertEqual((sub.operands[1].imm, add.operands[1].imm), (0x340, 0x340))
        lea = next(i for i in ins if i.mnemonic == 'lea')
        self.assertEqual(lea.operands[1].mem.disp, -0x210 - 0x40)
        self.assertEqual(sorted(i.operands[0].mem.disp for i in ins if i.mnemonic == 'movaps' and i.operands[0].type == cp.CS_OP_MEM), [-0x28])
        alloc = next(f for f in doc['fields'] if f['role'] == 'unwind-alloc')
        self.assertEqual(int.from_bytes(patches[int(alloc['address'], 0)], 'little'), 0x68)
        gs = next(f for f in doc['fields'] if f['role'] == 'unwind-gs-cookie')
        self.assertEqual(int.from_bytes(patches[int(gs['address'], 0)], 'little'), 0x300)
        # another X from the same plan (the table carries base values)
        code2, patches2, _ = fg.apply_plan(img, doc, 0x100)
        self.assertEqual(next(i for i in cp.decode(code2, CODE) if i.mnemonic == 'sub').operands[1].imm, 0x400)
        fg.self_check(img, doc, extras=(16, 0x40, 0x100, 0x1230))

    def test_page_probe_cave_when_the_new_frame_passes_a_page(self):
        doc, img = plan(Fn(), 0x400, max_extra=0x2000)
        cave = doc['cave']
        self.assertEqual(cave['probes'], 3)                     # 0x300 + 0x2000 = 0x2300 -> three 0x1000 steps
        self.assertEqual(cave['window_start'], '%#x' % (CODE + 3 + 1 + 1 + 7))
        self.assertEqual(cave['window_len'], 7)
        self.assertEqual(cave['old_bytes'], sub_rsp(0x300).hex())
        body = cp.decode(bytes.fromhex(cave['cave_bytes']), 0x150000000)
        self.assertEqual([i.mnemonic for i in body], ['test', 'test', 'test', 'sub'])
        self.assertEqual([i.operands[0].mem.disp for i in body[:3]], [-0x1000, -0x2000, -0x3000])
        self.assertEqual(body[3].operands[1].imm, 0x300 + 0x2000)
        self.assertEqual(cave['imm_offset'], 27)
        self.assertNotIn('frame-sub', [f['role'] for f in doc['fields']])   # the sub is in the cave, not a field
        # the run time patches the immediate for the X it chose
        _, _, cave_bytes = fg.apply_plan(img, doc, 0x400)
        self.assertEqual(cp.decode(cave_bytes, 0x150000000)[-1].operands[1].imm, 0x700)
        # an X above the planned maximum is refused by the planner's own arithmetic check (probes stop short)
        with self.assertRaises(cp.Refusal):
            fg.self_check(img, doc, extras=(0x2400,))

    def test_no_cave_below_a_page(self):
        doc, _ = plan(Fn(), 0x40, max_extra=0xC00)
        self.assertIsNone(doc['cave'])                          # 0x300 + 0xC00 = 0xF00 < 0x1000
        doc, _ = plan(Fn(), 0x40, max_extra=0xD00)
        self.assertEqual(doc['cave']['probes'], 1)              # 0x1000 exactly is the first size that needs a probe step

    def test_emitted_tables(self):
        doc, _ = plan(Fn(), 0x400, max_extra=0x2000)
        text = fg.emit_cpp(doc, 'x.json')
        lines = [l for l in text.splitlines() if l.startswith('{')]
        self.assertEqual(len(lines), len(doc['fields']))
        self.assertIn('{%#xull, 4, 0x%xu, 1, -1, true},' % (CODE + 3 + 1 + 1 + 3, (-0x210) & 0xFFFFFFFF), lines[0])
        self.assertTrue(all(l.endswith(', false},') for l in lines if 'ull, 2,' in l))   # unwind data is not code
        cave = fg.emit_cave_cpp(doc, 'x.json')
        self.assertIn('{%#xull,' % int(doc['cave']['window_start'], 0), cave)
        self.assertIn(', 27, 0x300u, 0x2000u, 3},', cave)

    def test_two_epilogues_and_an_rax_copy_of_the_entry_stack_pointer(self):
        body = Fn.default_body(0x300)
        body += [load_rbp(0x1C0), movaps_load_rsp(0x2E0), add_rsp(0x300), POP_RBX, POP_RBP, RET]    # a second return path
        body[0] = bytes.fromhex('488bc4')                                                          # mov rax, rsp instead of r11
        body[3] = bytes.fromhex('488da8') + i32(-0x210)                                            # lea rbp, [rax-0x210]
        body[6] = bytes.fromhex('0f2970d8')                                                        # movaps [rax-0x28], xmm6
        doc, img = plan(Fn(body=body), 0x40)
        self.assertEqual([f['role'] for f in doc['fields']].count('epilogue-add'), 2)
        self.assertEqual([f['role'] for f in doc['fields']].count('access-high'), 6)
        fg.self_check(img, doc, extras=(16, 0x40, 0x500))

    def test_chained_chunks_and_save_offsets_below_the_top_stay(self):
        # the xmm save moves into a second chunk chained to the first; one SAVE below the array top is not changed
        def build(fn_, _records):
            split = CODE + 3 + 1 + 1 + 7 + 7 + 7
            first = unwind([code_alloc_large(19, fn_.frame), code_push(5, 3), code_push(4, 5)], 26, 3, HANDLER, 0x2C0)
            second = unwind([code_save_xmm(5, 6, 0x2E0), code_save_xmm(9, 7, 0x40)], 0x14, 4, chain=(CODE - BASE, split - BASE, XDATA - BASE))
            return [first, second], [(CODE - BASE, split - BASE, 0), (split - BASE, fn_.end - BASE, 1)]
        fn = Fn(chunks=build)
        doc, img = plan(fn, 0x40)
        saves = [f for f in doc['fields'] if f['role'] == 'unwind-save']
        self.assertEqual([f['stock'] for f in saves], [0x2E])   # only the one at or above the array top
        self.assertEqual(len(doc['unwind_chunks']), 2)
        fg.self_check(img, doc, extras=(16, 0x40))


class Refusals(unittest.TestCase):
    def test_a_displacement_field_of_8_bits_that_must_change(self):
        body = Fn.default_body(0x300)
        body[5] = store_rbp8(0x7F)                                        # rbp+0x7F = S+0x17F
        plan(Fn(body=body), 0x40)                                         # below the array top: nothing to change
        refused(self, Fn(body=body), 'displacement field is 1 bytes', top=0x40)   # at or above it: cannot hold +X

    def test_sub_and_add_with_an_8_bit_immediate(self):
        body = Fn.default_body(0x70)
        body[4] = bytes.fromhex('4883ec70')
        refused(self, Fn(body=body, frame=0x70), 'allocation has an 8-bit immediate', top=0x20)
        body = Fn.default_body(0x70)
        body[14] = bytes.fromhex('4883c470')
        refused(self, Fn(body=body, frame=0x70), 'epilogue add has an 8-bit immediate', top=0x20)

    def test_dynamic_stack_adjustment(self):
        body = Fn.default_body(0x300)
        body[4] = bytes.fromhex('4829c4')                                   # sub rsp, rax
        refused(self, Fn(body=body), 'dynamic stack adjustment')
        body = Fn.default_body(0x300)
        body.insert(6, bytes.fromhex('4881ec10000000'))                     # a second sub rsp
        refused(self, Fn(body=body), 'a second stack allocation')
        body = Fn.default_body(0x300)
        body.insert(6, PUSH_RBX)
        refused(self, Fn(body=body), 'push in the body')
        body = Fn.default_body(0x300)
        body[14] = bytes.fromhex('488be5')                                  # mov rsp, rbp
        refused(self, Fn(body=body), 'writes rsp')
        body = Fn.default_body(0x300)
        body[14] = b'\xc9'                                                  # leave
        refused(self, Fn(body=body), 'leave')

    def test_the_address_of_stack_memory_at_or_above_the_top(self):
        body = Fn.default_body(0x300)
        body.insert(8, lea_rdx_rsp(0x2E0))
        refused(self, Fn(body=body), 'pointer would escape')
        body = Fn.default_body(0x300)
        body.insert(8, lea_rdx_rsp(0x2C0 - 0x20))                           # below the top: fine
        plan(Fn(body=body), 0x40)

    def test_indexed_copied_and_straddling_accesses(self):
        body = Fn.default_body(0x300)
        body.insert(8, store_rsp_idx(0x40))
        refused(self, Fn(body=body), 'indexed stack access')
        body = Fn.default_body(0x300)
        body.insert(8, mov_rbx_rsp())
        refused(self, Fn(body=body), 'copies a stack pointer')
        body = Fn.default_body(0x300)
        body.insert(8, store_rbp(0x1BC))                                    # an 8-byte store at S+0x2BC..0x2C4: straddles 0x2C0
        refused(self, Fn(body=body), 'straddles')

    def test_rbp_without_a_frame_base(self):
        body = Fn.default_body(0x300)
        del body[3]                                                         # no lea rbp
        refused(self, Fn(body=body), 'rbp is not a known frame base')

    def test_x_must_be_a_multiple_of_16(self):
        refused(self, Fn(), 'multiple of 16', extra=0x48)
        refused(self, Fn(), 'at least --extra', extra=0x40, max_extra=0x20)

    def test_unwind_forms_not_handled(self):
        sub_end = 19
        base = [code_save_xmm(sub_end + 12, 6, 0x2E0), code_alloc_large(sub_end, 0x300), code_push(5, 3), code_push(4, 5)]
        refused(self, Fn(unwind_codes=[code_save_xmm(31, 6, 0x2E0), code_alloc_small(sub_end, 0x80), code_push(5, 3), code_push(4, 5)]), 'ALLOC_SMALL')
        refused(self, Fn(unwind_codes=base, handler=HANDLER + 0x100), 'not a known GS handler')
        refused(self, Fn(unwind_codes=base, handler_data=0x2C1), 'flag bits')
        refused(self, Fn(unwind_codes=base, handler_data=0x2D0), 'is not accessed by the code')
        refused(self, Fn(unwind_codes=base, version=2), 'version')
        refused(self, Fn(unwind_codes=[code_save_xmm(31, 6, 0x2E0), code_alloc_large(sub_end + 2, 0x300), code_push(5, 3), code_push(4, 5)]),
                'prolog offset')
        refused(self, Fn(unwind_codes=[code_save_xmm(31, 6, 0x2E0), code_alloc_large(sub_end, 0x200), code_push(5, 3), code_push(4, 5)]),
                'differs from the frame size')
        refused(self, Fn(unwind_codes=[code_save_xmm(31, 6, 0x2E0), code_push(5, 3), code_push(4, 5)]), 'no ALLOC_LARGE')
        # the 16-bit size operand cannot hold the result
        refused(self, Fn(), 'cannot hold', extra=0x7FFF0, max_extra=0x7FFF0)

    def test_no_unwind_data(self):
        fn = Fn()
        img = fn.image()
        img.exception_directory = (PDATA, 0)
        refused(self, fn, 'not the start of a function with unwind data', image=img)

    def test_chunks_that_do_not_chain_to_the_primary(self):
        def build(fn_, _records):
            split = CODE + 3 + 1 + 1 + 7 + 7 + 7
            first = unwind([code_alloc_large(19, fn_.frame), code_push(5, 3), code_push(4, 5)], 26, 3, HANDLER, 0x2C0)
            second = unwind([code_save_xmm(5, 6, 0x2E0)], 0x14, 4, chain=(CODE - BASE + 16, split - BASE, XDATA - BASE))
            return [first, second], [(CODE - BASE, split - BASE, 0), (split - BASE, fn_.end - BASE, 1)]
        fn = Fn(chunks=build)
        with self.assertRaises(cp.Refusal) as ctx:
            plan(fn, 0x40, end=fn.end)
        self.assertIn('chains to something other than the primary chunk', ' '.join(ctx.exception.reasons))


class SelfCheck(unittest.TestCase):
    def test_a_missing_field_is_found(self):
        doc, img = plan(Fn(), 0x40)
        bad = copy.deepcopy(doc)
        bad['fields'] = [f for f in bad['fields'] if f['role'] != 'epilogue-add']
        with self.assertRaises(cp.Refusal) as ctx:
            fg.self_check(img, bad)
        self.assertIn('self-check', ' '.join(ctx.exception.reasons))

    def test_a_wrong_sign_is_found(self):
        doc, img = plan(Fn(), 0x40)
        bad = copy.deepcopy(doc)
        next(f for f in bad['fields'] if f['role'] == 'frame-base')['sign'] = 1
        with self.assertRaises(cp.Refusal):
            fg.self_check(img, bad)

    def test_an_unlisted_unwind_change_is_found(self):
        doc, img = plan(Fn(), 0x40)
        bad = copy.deepcopy(doc)
        bad['fields'] = [f for f in bad['fields'] if f['role'] != 'unwind-gs-cookie']
        with self.assertRaises(cp.Refusal):
            fg.self_check(img, bad)

    def test_a_field_changed_in_the_wrong_unit_is_found(self):
        doc, img = plan(Fn(), 0x40)
        bad = copy.deepcopy(doc)
        next(f for f in bad['fields'] if f['role'] == 'unwind-alloc')['unit'] = 16
        with self.assertRaises(cp.Refusal):
            fg.self_check(img, bad)


class CommandLine(unittest.TestCase):
    def test_a_missing_image_is_a_clean_failure(self):
        r = subprocess.run([sys.executable, '-B', os.path.join(ENGINE, 'cave_plan.py'), 'frame-grow', '--function', '0x140001000',
                            '--array-top', '0x2c0', '--extra', '64', '--image', os.path.join(tempfile.gettempdir(), 'no-such-image.exe')],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 2)
        self.assertIn('cannot plan', r.stderr)

    def test_the_old_command_line_still_works(self):
        r = subprocess.run([sys.executable, '-B', os.path.join(ENGINE, 'cave_plan.py'), '--help'], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0)
        self.assertIn('frame-grow', r.stdout)


if __name__ == '__main__':
    unittest.main()
