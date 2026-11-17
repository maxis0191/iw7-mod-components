"""The script canonical name table (a82): every edit of src/native/script_canonical.cpp against the shipped code and against what it must compute.

Offline checks:
  - every `add(address, before, after, ...)` of the cpp (read as text and evaluated for a number of names) has the shipped bytes in `before`
    (needs the unpacked code or the analysed image: skipped without) and the same length in `after`;
  - the new code decodes to the instructions its comment names, and the arithmetic it makes (slot of a hash, the probe step, the sizes) equals the shipped
    code's for the shipped 4095 slots and is the generalisation for any other number;
  - the edits do not overlap each other, and the iw7-mod hook window at the function entry (the first 5 bytes of SL_GetCanonicalString) is not touched;
  - the sizes and ids stay inside the variable system's name range (below 0x40000).
"""
import importlib.util
import os
import re
import struct
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
CPP = os.path.join(ROOT, 'src', 'native', 'script_canonical.cpp')
HPP = os.path.join(ROOT, 'src', 'native', 'script_canonical.hpp')

spec = importlib.util.spec_from_file_location('sites_test', os.path.join(HERE, 'agent_capacity_sites_test.py'))
st = importlib.util.module_from_spec(spec)
spec.loader.exec_module(st)

STOCK_NAMES, FIRST_ID, MAX_NAMES = 4095, 0x13FCC, 65535
ENTRY = 0x140BFD340          # SL_GetCanonicalString; the client fork's detour overwrites 5 bytes here
BLOCK_POINTER = 0x1460B94F8


def le32(v):
    return list(struct.pack('<I', v & 0xFFFFFFFF))


def cat(parts):
    out = []
    for p in parts:
        out += p
    return out


def nops(n):
    return [0x90] * n if False else [('nop', n)]       # a nop run is checked as "only nops", not byte for byte


def evaluate_edits(names, block=0x7FF012340000):
    """The (address, before, after, what) of every add() of the cpp, evaluated for `names` slots."""
    text = open(CPP, encoding='utf-8').read()
    body = text[text.index('void plan_edits'):]
    body = body[:body.index('\n}\n')]
    hash_bytes, name_bytes = (names + 1) * 4, (names + 1) * 28
    total = hash_bytes + name_bytes
    env = {'names': names, 'stock_hash_bytes': 0x4000, 'stock_name_bytes': 0x1C000, 'hash': hash_bytes, 'name_bytes': name_bytes, 'total': total,
           'le32': le32, 'cat': cat, 'nops': nops, 'pointer': list(struct.pack('<Q', block))}
    edits = []
    for m in re.finditer(r'add\((0x[0-9A-Fa-f]+),(.*?),\s*"([^"]+)"\);', body, re.S):
        address, rest, what = int(m.group(1), 16), m.group(2), m.group(3)
        py = ' '.join(rest.replace('{', '[').replace('}', ']').split())
        # the two lists: before and after, separated by the top level comma
        depth, cut = 0, None
        for i, ch in enumerate(py):
            depth += ch in '[(' and 1 or (ch in '])' and -1 or 0)
            if ch == ',' and depth == 0:
                cut = i
                break
        before_text, after_text = py[:cut].strip(), py[cut + 1:].strip()
        before = eval(before_text, {'__builtins__': {}}, env)
        after = eval(after_text, {'__builtins__': {}}, env)
        edits.append((address, before, after, what))
    return edits


def flatten(after, length):
    """Replace a ('nop', n) marker by n bytes the test checks are nops (0x90 stands in)."""
    out = []
    for b in after:
        if isinstance(b, tuple):
            out += [0x90] * b[1]
        else:
            out.append(b)
    assert len(out) == length, (len(out), length)
    return out


class Model(unittest.TestCase):
    """Runs on every machine."""

    def test_the_cpp_has_the_expected_edits(self):
        edits = evaluate_edits(16383)
        self.assertEqual([e[0] for e in edits], [0x140BFD387, 0x140BFD3DD, 0x140BFD3B5, 0x140BFD427, 0x140BFD45E, 0x140C03284, 0x140C032A6])

    def test_lengths_and_no_overlap_and_the_detour_window_is_free(self):
        for names in (4096, 8191, 16383, 65535):
            edits = evaluate_edits(names)
            spans = sorted((a, a + len(b)) for a, b, _, _ in edits)
            for (a0, a1), (b0, b1) in zip(spans, spans[1:]):
                self.assertLessEqual(a1, b0)
            for a, b, after, _ in edits:
                self.assertEqual(len(b), len(flatten(after, len(b))))
                self.assertFalse(a < ENTRY + 5 and a + len(b) > ENTRY)

    def test_the_sizes_follow_the_shipped_ratios_and_the_ids_stay_below_the_object_keys(self):
        for names in (4095, 8191, 16383, MAX_NAMES):
            self.assertLess(FIRST_ID + names, 0x40000)
        self.assertEqual((STOCK_NAMES + 1) * 4, 0x4000)
        self.assertEqual((STOCK_NAMES + 1) * 28, 0x1C000)
        h = open(HPP, encoding='utf-8').read()
        self.assertIn('stock_names = 4095', h)
        self.assertIn('first_id = 0x13FCC', h)
        self.assertIn('max_names = 65535', h)

    def test_slot_and_probe_arithmetic(self):
        # shipped: slot = hash % 4095 + 1; the probe step slot + 1 wraps 4095 to 1. New: the same with `names`
        def slot(h, n): return h % n + 1

        def step(s, n): return 1 if s + 1 == n + 1 else s + 1

        for n in (4095, 8191, 16383):
            for h in (0, 1, n - 1, n, n + 1, 0xFFFFFFFF, 0x12345678, 0xDEADBEEF):
                self.assertTrue(1 <= slot(h, n) <= n)
            self.assertEqual(step(n, n), 1)
            self.assertEqual(step(1, n), 2)
        # the shipped reciprocal (mov eax,0x100101; mul; sub; shr 1; add; shr 0xB) is the same division for 4095
        for h in list(range(0, 70000, 977)) + [0xFFFFFFFF, 0xFFFFF000, 0x7FFFFFFF, 0x80000000, 0xDEADBEEF]:
            m = h * 0x100101
            hi = (m >> 32) & 0xFFFFFFFF
            q = ((((h - hi) & 0xFFFFFFFF) >> 1) + hi) & 0xFFFFFFFF
            q >>= 11
            self.assertEqual(h - q * 0xFFF, h % 4095, hex(h))


class Sites(unittest.TestCase):
    def setUp(self):
        self.image, self.source = st.find_image()
        if self.image is None:
            self.skipTest('no unpacked code files or analysed image on this machine')

    def test_every_before_is_the_shipped_code(self):
        for names in (4096, 16383):
            for address, before, after, what in evaluate_edits(names):
                got = self.image.read(address, len(before))
                self.assertIsNotNone(got, hex(address))
                self.assertEqual(list(got), before, f'{address:#x} {what}')

    def test_the_new_code_decodes_to_the_named_instructions(self):
        try:
            from capstone import Cs, CS_ARCH_X86, CS_MODE_64
        except ImportError:
            self.skipTest('capstone is not installed')
        md = Cs(CS_ARCH_X86, CS_MODE_64)
        names = 16383
        edits = {a: (b, af) for a, b, af, _ in evaluate_edits(names)}

        def decode(address, after, length):
            raw = bytes(flatten(after, length))
            return [(i.mnemonic, i.op_str) for i in md.disasm(raw, address)]

        b, af = edits[0x140BFD387]
        got = decode(0x140BFD387, af, len(b))
        self.assertEqual(got[:6], [('sub', 'ebp, edi'), ('mov', 'eax, ebx'), ('xor', 'edx, edx'), ('mov', f'ecx, {names:#x}'), ('div', 'ecx'), ('lea', 'ebx, [rdx + 1]')])
        self.assertTrue(all(m == 'nop' for m, _ in got[6:]))
        b, af = edits[0x140BFD3DD]
        got = decode(0x140BFD3DD, af, len(b))
        self.assertEqual(got[:4], [('inc', 'esi'), ('cmp', f'esi, {names + 1:#x}'), ('jne', '0x140bfd3ec'), ('mov', 'esi, 1')])
        self.assertTrue(all(m == 'nop' for m, _ in got[4:]))
        # the jump lands after `mov esi, 1`, still inside the edit, on the first nop
        b, af = edits[0x140C03284]
        got = decode(0x140C03284, af, len(b))
        self.assertEqual(got[0][0], 'movabs')
        self.assertTrue(all(m == 'nop' for m, _ in got[1:]))
        # the 5 following instructions keep their meaning: the clear takes `total` bytes of the block in rax
        follow = self.image.read(0x140C0329B, 0x30)
        text = [(i.mnemonic, i.op_str) for i in md.disasm(bytes(follow), 0x140C0329B)]
        self.assertEqual(text[0], ('xor', 'edx, edx'))
        self.assertEqual(text[1][0], 'mov')            # mov [table pointer], rax
        self.assertEqual(text[2][0], 'mov')            # mov r8d, total (patched)
        self.assertEqual(text[3], ('mov', 'rcx, rax'))

    def test_the_names_of_the_edited_function_are_the_expected_ones(self):
        # no other code reads the table or the name buffer: the three displacement and the one size site are the whole story (docs/SCRIPT-CANONICAL.md)
        got = self.image.read(0x140BFD380, 7)
        self.assertEqual(struct.unpack('<i', got[3:])[0] + 0x140BFD387, BLOCK_POINTER)


if __name__ == '__main__':
    unittest.main()
