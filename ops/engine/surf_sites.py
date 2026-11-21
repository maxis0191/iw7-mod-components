#!/usr/bin/env python3
"""Site table of the scene surface buffer base (a90, 20 Nov 2026): every instruction of the unpacked code that addresses the buffer 1 base, by form.

    python -B ops/engine/surf_sites.py [--range LO HI] [--emit-inc out.inc] [--json out.json]

The scene surface buffer (0x40000 bytes, counter [[0x148F73088]+0x18A0]) sits at +0xB5580 of the frame data (two structs of 0x5BD280 bytes in the .bss at 0x148F73100). Its readers address it in two
encodings: a displacement 0xB5580 + k (k a record field) and the frame viewed as an array of dwords, base 0x2D560 + k/4 added to a unit index that a later instruction scales by 4. This tool decodes every
instruction of every code fragment of the engine map, takes the ones whose displacement or immediate lies in those ranges, checks the form against the instructions that follow, and writes the table
(address, offset of the 32 bit field inside the instruction, old value, kind): kind 0 = byte base (new = old + delta), kind 1 = dword base (new = old + delta / 4), kind 2 = the base as a modulus (0xAA80 = -0xB5580 mod 0x40000, the unit index of a key: new = (-O) mod 0x40000). A site whose form is not one of the proven
ones is listed as UNRESOLVED and is not emitted: the native code (agent_capacity.cpp section 3g) refuses to start the relocation while the unresolved list is not empty in the table it was built from.
"""
import argparse
import collections
import json
import os
import sqlite3
import sys

import struct

import capstone
from capstone import x86_const as X

REF = os.environ.get('IW7_REFERENCE_ROOT', 'C:/Users/ezvalo/Documents/IW7-Paris-Server/tools/references/')
DB = os.environ.get('IW7_ENGINE_MAP_DB', 'C:/Users/ezvalo/Documents/IW7-Runtime/enginelab/engine-map/iw7-engine-map.sqlite')
TV = 0x140001000
BASE, BASE4, SPAN = 0xB5580, 0x2D560, 0x700   # fields of a record lie within SPAN bytes of the base
WRAP = (-BASE) & 0x3FFFF   # 0xAA80: the key's unit index is ((pointer + WRAP - frame) >> 2) & 0xFFFF, the base as a modulus of the 18 bit span (kind 2: new = (-O) mod 0x40000)
# --buffer 2: the second scene buffer (the motion blur surfaces, warning 0x77): 0x10000 bytes at +0x577180 of each frame, counter [[0x148F73088]+0x18A4], u16 index in 4 byte units at
# record +0x3E; readers go through the accessor FUN_140E34000 (frame + 0x577180 + 4 idx) or one inlined cmp. The fields at +0x587180 (just past the 64 KB) are other frame data: SPAN 0x100 stops before them.
BUFFERS = {1: (0xB5580, 0x700), 2: (0x577180, 0x100)}


def disp32(i, value):
    """The 32 bit field of the displacement, or None. capstone reports disp_size 2 for an instruction with the operand size prefix 0x66 and a disp32 (cmp ax,[rsi+0xB55BC] at 0x140E752D4:
    66 3B 86 BC550B00, missed by the first table): the field is taken when the four bytes at disp_offset are the displacement."""
    if i.disp_offset and len(i.bytes) >= i.disp_offset + 4 and struct.unpack_from('<I', bytes(i.bytes), i.disp_offset)[0] == value:
        return i.disp_offset
    return None


def in_bytes(v):
    return BASE <= v < BASE + SPAN


def in_dwords(v):
    return BASE4 <= v < BASE4 + SPAN // 4


def regs_of(op):
    return {op.mem.base, op.mem.index} - {0}


def check_dword_form(ins_list, k, reg):
    """After `add reg, D/4` or `lea reg,[x + D/4]` the register is a dword index: within the next 14 instructions an operand must use it as index with scale 4."""
    for j in range(k + 1, min(len(ins_list), k + 15)):
        for op in ins_list[j].operands:
            if op.type == X.X86_OP_MEM and op.mem.index == reg and op.mem.scale == 4:
                return True
        # the register is overwritten before use: the form is not proven
        first = ins_list[j].operands[0] if ins_list[j].operands else None
        if first is not None and first.type == X.X86_OP_REG and first.reg == reg and ins_list[j].mnemonic in ('mov', 'xor', 'movzx', 'lea') and not any(
                o.type == X.X86_OP_MEM and reg in regs_of(o) for o in ins_list[j].operands[1:]):
            return False
    return False


def scan(lo, hi):
    md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
    md.detail = True
    text = open(os.path.join(REF, 'unpacked-text.bin'), 'rb').read()
    con = sqlite3.connect(DB)
    frs = con.execute('select begin,end from fragments where begin>=? and end<=? order by begin', (lo, hi)).fetchall()
    sites, unresolved = [], []
    for b, e in frs:
        ins_list = list(md.disasm(text[b - TV:e - TV], b))
        for k, i in enumerate(ins_list):
            for op in i.operands:
                kind = value = off = None
                if op.type == X.X86_OP_MEM and op.mem.base != X.X86_REG_RIP and disp32(i, op.mem.disp & 0xFFFFFFFF) is not None:
                    # rip-relative operands are addresses in the image, not frame offsets (lea r8,[rip+0xB5B9E] at 0x1413935DB was a false site)
                    d = op.mem.disp & 0xFFFFFFFF
                    if in_bytes(d):
                        kind, value, off = 0, d, disp32(i, d)
                    elif in_dwords(d):
                        kind, value, off = 1, d, disp32(i, d)
                elif op.type == X.X86_OP_IMM and i.imm_size == 4 and i.mnemonic in ('add', 'sub', 'lea'):
                    v = op.imm & 0xFFFFFFFF
                    if v == WRAP and BASE == BUFFERS[1][0]:
                        kind, value, off = 2, v, i.imm_offset
                        sites.append({'address': i.address, 'size': i.size, 'field_offset': off, 'old': value, 'kind': 2, 'text': '%s %s' % (i.mnemonic, i.op_str)})
                        continue
                    if in_bytes(v):
                        kind, value, off = 0, v, i.imm_offset
                    elif in_dwords(v):
                        kind, value, off = 1, v, i.imm_offset
                if kind is None:
                    continue
                rec = {'address': i.address, 'size': i.size, 'field_offset': off, 'old': value, 'kind': kind, 'text': '%s %s' % (i.mnemonic, i.op_str)}
                ok = True
                if kind == 1:
                    # dword base: the destination register becomes the index
                    dest = i.operands[0].reg if i.operands and i.operands[0].type == X.X86_OP_REG else None
                    ok = dest is not None and check_dword_form(ins_list, k, dest)
                if ok:
                    sites.append(rec)
                else:
                    unresolved.append(rec)
    return sites, unresolved


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--range', nargs=2, default=['0x140001000', '0x141435000'])
    ap.add_argument('--json')
    ap.add_argument('--emit-inc')
    ap.add_argument('--buffer', type=int, choices=sorted(BUFFERS), default=1)
    a = ap.parse_args(argv)
    global BASE, BASE4, SPAN
    BASE, SPAN = BUFFERS[a.buffer]
    BASE4 = BASE // 4
    lo, hi = int(a.range[0], 16), int(a.range[1], 16)
    sites, unresolved = scan(lo, hi)
    hist = collections.Counter((s['kind'], s['text'].split()[0]) for s in sites)
    print('%d sites, %d unresolved' % (len(sites), len(unresolved)))
    for key, n in sorted(hist.items(), key=lambda x: -x[1]):
        print('  kind %d %-6s %d' % (key[0], key[1], n))
    for u in unresolved:
        print('UNRESOLVED %#x %s (value %#x kind %d)' % (u['address'], u['text'], u['old'], u['kind']))
    if a.json:
        with open(a.json, 'w') as f:
            json.dump({'sites': sites, 'unresolved': unresolved}, f, indent=0)
    if a.emit_inc:
        with open(a.emit_inc, 'w', newline='\n') as f:
            if a.buffer == 1:
                f.write('// generated by ops/engine/surf_sites.py: {instruction address, offset of the 32 bit field, old value, kind (0 byte base, 1 dword base)}\n')
            else:
                f.write('// generated by ops/engine/surf_sites.py --buffer 2: the second scene buffer (+0x577180, the motion blur surfaces). {instruction address, offset of the 32 bit field, old value, kind 0 (byte base)}\n')
            for s in sites:
                f.write('{0x%X, %d, 0x%X, %d},\n' % (s['address'], s['field_offset'], s['old'], s['kind']))
            f.write('// unresolved: %d\n' % len(unresolved))
    return 0 if not unresolved else 2


if __name__ == '__main__':
    sys.exit(main())
