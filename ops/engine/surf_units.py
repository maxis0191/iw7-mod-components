#!/usr/bin/env python3
"""Unit change plan of the scene surface buffer (engine-crowd-overhaul, 21 Nov 2026): what must change so that the u16 index of the buffer counts 16 byte units (1 MB) instead of 4 byte units (256 KB).

    python -B ops/engine/surf_units.py [--json out.json]

The scene surface buffer (warning 0x0D) is addressed through a 16 bit index of 4 byte units: in the surface records (+6, FUN_140E147E0), in FUN_140DE2390's records and in the low 16 bits of the draw
surface sort key (FUN_140E2D000 and sisters). A u16 of 4 byte units addresses 256 KB, and the demand at 183 agents in view is 430 KB (run stage0d), about 2.35 KB an agent: 300 in view need about
700 KB, so 8 byte units (512 KB, one scale bit in place) are not enough and the unit must be 16 bytes. x86 has no scale 16, so the plan scales the index once where it enters a register (the ROOT,
`movzx r32, r16` of a key or a record field): root * 4 then stays a valid operand for every `[base + reg*4 + d]` after it, which then addresses base + 16 idx + d. That is only correct when EVERY use of
the root's value is such a scaled operand, an `add reg, D/4` / `lea r, [reg + D/4]` whose result is again only used scaled by 4, or a 64 bit copy tracked the same way. Anything else (a compare with
the value, a store of it, an unscaled base, a call argument, a branch out of the analysed code) is UNRESOLVED: the plan is incomplete and nothing may be built from it.

For every site of ops/engine/surf_sites.py (buffer 1) the tool finds the root of the index register (backwards in the same function, through the kind 1 add/lea and copies), then walks forward from each
root over the function's branches until the value dies, classifying every use. Sites without an index register (a base that already holds frame + 4 idx) are listed as pointer sites: their pointer
is made by a scaled lea that must be found the same way. It prints roots, uses, pointer sites and the unresolved list; --json writes it all. Exit 0 = complete plan, 2 = work left (the lists).
"""
import argparse
import collections
import json
import os
import re
import sqlite3
import sys

import capstone
from capstone import x86_const as X

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import surf_sites  # noqa: E402

TV = surf_sites.TV
VOLATILE = {'rax', 'rcx', 'rdx', 'r8', 'r9', 'r10', 'r11'}
ARGS = ('rcx', 'rdx', 'r8', 'r9')
NAMES = {'eax': 'rax', 'ax': 'rax', 'al': 'rax', 'ah': 'rax', 'ebx': 'rbx', 'bx': 'rbx', 'bl': 'rbx', 'ecx': 'rcx', 'cx': 'rcx', 'cl': 'rcx', 'edx': 'rdx', 'dx': 'rdx', 'dl': 'rdx',
         'esi': 'rsi', 'si': 'rsi', 'sil': 'rsi', 'edi': 'rdi', 'di': 'rdi', 'dil': 'rdi', 'ebp': 'rbp', 'bp': 'rbp', 'bpl': 'rbp', 'esp': 'rsp'}
PURE_WRITES = ('mov', 'movzx', 'movsxd', 'movsx', 'lea', 'pop', 'sete', 'setne', 'movd', 'movq')


class Image:
    def __init__(self):
        self.text = open(os.path.join(surf_sites.REF, 'unpacked-text.bin'), 'rb').read()
        self.md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
        self.md.detail = True
        self.con = sqlite3.connect(surf_sites.DB)
        self.cache = {}

    def full(self, r):
        if not r:
            return None
        n = self.md.reg_name(r)
        if n in NAMES:
            return NAMES[n]
        m = re.match(r'(r\d+)[dwb]?$', n)
        return m.group(1) if m else n

    def fragment(self, a):
        return self.con.execute('select begin,end from fragments where begin<=? and end>?', (a, a)).fetchone()

    def insns(self, frag):
        if frag not in self.cache:
            b, e = frag
            L = list(self.md.disasm(self.text[b - TV:e - TV], b))
            self.cache[frag] = (L, {i.address: k for k, i in enumerate(L)})
        return self.cache[frag]


def is_d4(v):
    return surf_sites.in_dwords(v & 0xFFFFFFFF)


def text(i):
    return '%s %s' % (i.mnemonic, i.op_str)


def reads(img, i, reg):
    out = []
    for n, op in enumerate(i.operands):
        if op.type == X.X86_OP_REG and img.full(op.reg) == reg:
            if n == 0 and i.mnemonic in PURE_WRITES and (len(i.operands) > 1 or i.mnemonic == 'pop'):
                continue
            if i.mnemonic == 'xor' and len(i.operands) == 2 and all(o.type == X.X86_OP_REG and img.full(o.reg) == reg for o in i.operands):
                return []   # xor r,r: a write of zero, the value is not read
            out.append(('reg', op, n))
        elif op.type == X.X86_OP_MEM:
            if img.full(op.mem.index) == reg:
                out.append(('index', op, n))
            if img.full(op.mem.base) == reg:
                out.append(('base', op, n))
    return out


def writes(img, i, reg):
    if not i.operands:
        return False
    op = i.operands[0]
    if op.type == X.X86_OP_REG and img.full(op.reg) == reg and i.mnemonic not in ('cmp', 'test', 'push', 'bt'):
        return True
    return i.mnemonic == 'xchg' and any(o.type == X.X86_OP_REG and img.full(o.reg) == reg for o in i.operands)


def walk(img, frag, start_k, reg, seen, uses, bad, depth=0):
    """forward from instruction start_k (exclusive) of the fragment, `reg` holding the index value"""
    L, at = img.insns(frag)
    work = [(start_k + 1, reg)]
    while work:
        k, r = work.pop()
        while k < len(L):
            i = L[k]
            if (i.address, r) in seen:
                break
            seen.add((i.address, r))
            rd = reads(img, i, r)
            kept_by_add = False
            for kind, op, n in rd:
                if kind == 'index' and op.mem.scale == 4:
                    uses.append({'address': i.address, 'text': text(i), 'use': 'scaled'})
                elif kind == 'reg' and n == 0 and i.mnemonic == 'add' and i.operands[1].type == X.X86_OP_IMM and is_d4(i.operands[1].imm):
                    uses.append({'address': i.address, 'text': text(i), 'use': 'add D/4'})
                    kept_by_add = True
                elif kind == 'base' and i.mnemonic == 'lea' and n == 1 and not op.mem.index and is_d4(op.mem.disp):
                    dst = img.full(i.operands[0].reg)
                    uses.append({'address': i.address, 'text': text(i), 'use': 'lea D/4 -> %s' % dst})
                    work.append((k + 1, dst))
                elif kind == 'reg' and n == 1 and i.mnemonic == 'mov' and i.operands[0].type == X.X86_OP_REG and i.operands[0].size == 8 and op.size == 8:
                    dst = img.full(i.operands[0].reg)
                    uses.append({'address': i.address, 'text': text(i), 'use': 'copy -> %s' % dst})
                    work.append((k + 1, dst))
                else:
                    bad.append({'address': i.address, 'text': text(i), 'reg': r, 'why': '%s read' % kind})
            if writes(img, i, r) and not kept_by_add:
                break
            m = i.mnemonic
            if m == 'call':
                if r in ARGS:
                    bad.append({'address': i.address, 'text': text(i), 'reg': r, 'why': 'live in an argument register at a call'})
                if r in VOLATILE:
                    break
            if m == 'ret' or m == 'int3':
                break
            if m.startswith('j'):
                op = i.operands[0]
                target = op.imm if op.type == X.X86_OP_IMM else None
                if target is None:
                    bad.append({'address': i.address, 'text': text(i), 'reg': r, 'why': 'indirect jump with the value live'})
                    break
                if target in at:
                    if m == 'jmp':
                        k = at[target]
                        continue
                    work.append((at[target], r))
                else:
                    tf = img.fragment(target)
                    if tf and depth < 3:
                        L2, at2 = img.insns(tf)
                        if target in at2:
                            walk(img, tf, at2[target] - 1, r, seen, uses, bad, depth + 1)
                        else:
                            bad.append({'address': i.address, 'text': text(i), 'reg': r, 'why': 'branch into the middle of an instruction'})
                    else:
                        bad.append({'address': i.address, 'text': text(i), 'reg': r, 'why': 'branch out of the analysed code'})
                    if m == 'jmp':
                        break
            k += 1


def find_root(img, site):
    frag = img.fragment(site['address'])
    L, at = img.insns(frag)
    k = at[site['address']]
    i = L[k]
    reg = None
    for op in i.operands:
        if op.type == X.X86_OP_MEM and op.mem.index and op.mem.scale == 4:
            reg = img.full(op.mem.index)
    if site['kind'] == 1 and i.mnemonic == 'add':
        reg = img.full(i.operands[0].reg)
    if site['kind'] == 1 and i.mnemonic == 'lea':
        reg = img.full(i.operands[1].mem.base)
    if reg is None:
        return None, 'no scaled index register: the base already holds frame + 4 idx (its scaled lea must be found)'
    j = k - 1
    while j >= 0 and k - j < 200:
        x = L[j]
        if writes(img, x, reg):
            if x.mnemonic == 'movzx' and x.operands[1].size == 2:
                return (x.address, reg, text(x)), None
            if x.mnemonic == 'add' and x.operands[1].type == X.X86_OP_IMM and is_d4(x.operands[1].imm):
                j -= 1
                continue
            if x.mnemonic == 'lea' and x.operands[1].mem.base and not x.operands[1].mem.index and is_d4(x.operands[1].mem.disp):
                reg = img.full(x.operands[1].mem.base)
                j -= 1
                continue
            if x.mnemonic == 'mov' and x.operands[1].type == X.X86_OP_REG and x.operands[1].size == 8:
                reg = img.full(x.operands[1].reg)
                j -= 1
                continue
            return None, 'index defined by %x %s (not a u16 zero extension)' % (x.address, text(x))
        j -= 1
    return None, 'no definition of the index in the 200 instructions before (a branch joins: needs the control flow)'


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--json')
    ap.add_argument('--range', nargs=2, default=['0x140DC0000', '0x140E80000'])
    a = ap.parse_args(argv)
    img = Image()
    sites, _ = surf_sites.scan(int(a.range[0], 16), int(a.range[1], 16))
    roots = collections.OrderedDict()
    pointer_sites = []
    for s in sites:
        if s['kind'] == 2:
            continue
        r, why = find_root(img, s)
        if r is None:
            pointer_sites.append({'site': s['address'], 'text': s['text'], 'why': why})
            continue
        roots.setdefault((r[0], r[1]), {'root': r[0], 'reg': r[1], 'text': r[2], 'sites': []})['sites'].append(s['address'])
    unresolved = []
    for (addr, reg), rec in roots.items():
        frag = img.fragment(addr)
        L, at = img.insns(frag)
        uses, bad = [], []
        walk(img, frag, at[addr], reg, set(), uses, bad)
        rec['uses'], rec['unresolved'] = uses, bad
        unresolved += [dict(x, root=addr) for x in bad]
    print('%d sites: %d roots, %d pointer sites, %d unresolved uses' % (len(sites), len(roots), len(pointer_sites), len(unresolved)))
    for rec in roots.values():
        print('root %x %-22s (%s): %d uses, %d unresolved' % (rec['root'], rec['text'], rec['reg'], len(rec['uses']), len(rec['unresolved'])))
        for x in rec['unresolved']:
            print('    UNRESOLVED %x %-44s %s: %s' % (x['address'], x['text'], x['reg'], x['why']))
    for x in pointer_sites:
        print('pointer site %x %-40s %s' % (x['site'], x['text'], x['why']))
    if a.json:
        with open(a.json, 'w', newline='\n') as f:
            json.dump({'roots': list(roots.values()), 'pointer_sites': pointer_sites, 'unresolved': unresolved}, f, indent=0)
    return 0 if not unresolved and not pointer_sites else 2


if __name__ == '__main__':
    sys.exit(main())
