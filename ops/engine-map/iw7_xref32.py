"""Every instruction of the unpacked IW7 code that names a global, in any addressing form (capacity work).

The engine map's `refs` lists only rip-relative references. The engine also reaches its big static tables through
the image base held in a register: `[rbx + rax*4 + 0x60B22F2]` where rbx = 0x140000000 (an RVA in a disp32), and
through 4-byte absolute pointers in data. Moving a table means changing every one of them, so this tool finds, for
each asked global (and an optional span after it), every 4-byte field in the code whose value is:
  - rip-relative and lands in [addr, addr+span)       ("rip")
  - an RVA (value - 0x140000000) in [addr, addr+span)  ("rva")
and decodes the instruction that holds the field (capstone), with the function from the engine map when given.

usage: iw7_xref32.py --reference-root <refs> [--db <engine map>] [--extra <base hex>=<dump file> ...]
                     ADDR[:SPAN] [ADDR[:SPAN] ...] [--json]
--extra adds code spans dumped from a live process (the protected spans at 0x14B2B4000 are not in the section files).
"""
import argparse
import json
import os
import sqlite3
import struct
import sys

import capstone
import numpy as np

BASE, TEXT_VA = 0x140000000, 0x140001000


def load_spans(refs, extras):
    spans = [(TEXT_VA, open(os.path.join(refs, 'unpacked-text.bin'), 'rb').read())]
    for item in extras or []:
        base, path = item.split('=', 1)
        spans.append((int(base, 16), open(path, 'rb').read()))
    return spans


def func_of(con, addr):
    if con is None:
        return ''
    try:
        row = con.execute("select func from fragments where begin<=? and end>? order by begin desc limit 1",
                          (addr, addr)).fetchone()
    except sqlite3.Error:
        return ''
    return ('sub_%X' % row[0]) if row else ''


def decode_at(md, data, base, field_off, con=None):
    """The instruction that holds the 4-byte field: linear decode from the start of its engine-map fragment
    (exact), else the shortest back-step whose decode covers the field."""
    field = base + field_off
    if con is not None:
        row = con.execute("select begin from fragments where begin<=? and end>? order by begin desc limit 1",
                          (field, field)).fetchone()
        if row and base <= row[0] < field:
            s = row[0] - base
            for ins in md.disasm(data[s:field_off + 16], row[0]):
                if ins.address <= field < ins.address + ins.size:
                    return ins if field + 4 <= ins.address + ins.size else None
                if ins.address > field:
                    break
    for back in range(1, 16):
        s = field_off - back
        if s < 0:
            break
        for ins in md.disasm(data[s:s + 16], base + s, count=1):
            if ins.address + ins.size >= field + 4:
                return ins
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--reference-root', required=True)
    ap.add_argument('--db')
    ap.add_argument('--extra', action='append')
    ap.add_argument('--json', action='store_true')
    ap.add_argument('targets', nargs='+')
    a = ap.parse_args()
    spans = load_spans(a.reference_root, a.extra)
    con = None
    if a.db:
        con = sqlite3.connect(a.db)
    md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
    md.detail = True
    out = []
    for t in a.targets:
        addr, _, span = t.partition(':')
        lo = int(addr, 16)
        hi = lo + (int(span, 16) if span else 1)
        rlo, rhi = lo - BASE, hi - BASE
        for sbase, data in spans:
            n = len(data)
            hits = {}
            for k in range(4):
                cnt = (n - k) // 4
                arr = np.frombuffer(data, dtype='<i4', count=cnt, offset=k).astype(np.int64)
                offs = k + 4 * np.arange(cnt, dtype=np.int64)
                for o in offs[(arr >= rlo) & (arr < rhi)]:
                    hits[int(o)] = 'rva'
                for tail in (0, 1, 2, 4):
                    tgt = sbase + offs + 4 + tail + arr
                    for o in offs[(tgt >= lo) & (tgt < hi)]:
                        hits.setdefault(int(o), 'rip')
            for off in sorted(hits):
                kind = hits[off]
                ins = decode_at(md, data, sbase, off, con)
                if ins is None:
                    continue
                text = '%s %s' % (ins.mnemonic, ins.op_str)
                ok = False
                for op in ins.operands:
                    if op.type != capstone.x86.X86_OP_MEM:
                        continue
                    m = op.mem
                    if kind == 'rip' and m.base == capstone.x86.X86_REG_RIP:
                        ok = lo <= ins.address + ins.size + m.disp < hi
                    elif kind == 'rva' and m.base != capstone.x86.X86_REG_RIP and (m.base or m.index):
                        ok = rlo <= m.disp < rhi
                    if ok:
                        break
                if not ok:
                    continue
                field = sbase + off
                out.append({'target': '%X' % lo, 'kind': kind, 'field': '%X' % field, 'ins': '%X' % ins.address,
                            'text': text, 'func': func_of(con, ins.address)})
    if a.json:
        json.dump(out, sys.stdout, indent=1)
    else:
        for r in out:
            print('%s %-3s field %s ins %s  %-50s %s' % (r['target'], r['kind'], r['field'], r['ins'], r['text'], r['func']))
        print('%d references' % len(out), file=sys.stderr)


if __name__ == '__main__':
    main()
