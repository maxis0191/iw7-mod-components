"""Replicated scriptable state: every instruction field that depends on the state budget (a39, 15 Nov 2026).

The server keeps the state of reserved scriptable instances in one block (ScriptableSv, 0x1460A8BE0, 0x17E8 bytes):
`u16 fixed count | dwords[1016] | u16 instance count | u16 entnum+1[512] | u16 start dword[512] | pad`, a list table of
4,064 six-byte entries (0x1460AC3A0, one per state BYTE) and copies of the block in rings, a snapshot member and client statics.
The budget is 1,016 dwords (4 one-byte part states each); see docs/AGENT-CAPACITY-ENGINE.md "Replicated state budget".

    python -B ops/engine/state_sites.py find  -o ops/engine/state-sites.json    # engine database + analysed image (RE lab)
    python -B ops/engine/state_sites.py check ops/engine/state-sites.json       # decode every row against the image
    python -B ops/engine/state_sites.py emit  ops/engine/state-sites.json -o src/native/agent_capacity_state.inc

A row is one 4-byte instruction field:
  value rows (form 0): the field holds a constant that is a function of the budget (`op`);
  rip rows   (form 1): rip-relative displacement to a relocated block, `stock` = the stock absolute target, `tail` = bytes after the field;
  rva rows   (form 2): image-base relative disp32 to a relocated block, `stock` = the stock displacement.
`op` names are the `state_op` enumerators of src/native/agent_capacity.cpp.
"""
import argparse
import json
import os
import sqlite3
import struct
import sys

BASE = 0x140000000

# structure -> (stock base, stock size incl. any trailer) of the relocated objects
STRUCTS = {
    'A': (0x1460A8BE0, 0x17E8),     # server live block
    'C': (0x1460AC3A0, 0x5F4E),     # server byte list table (+ heads at +0x5F40)
    'A1': (0x146030250, 0x17F0),    # client static block 1 (+ 8 byte trailer of 4 u16 at +0x17E8)
    'A2': (0x146031A40, 0x17F0),    # client static block 2
    'X': (0x1421EDA70, 0x17E8),     # client static empty block
}
OPS = ['shift', 'state_bytes', 'state_bytes_less6', 'budget', 'budget4', 'budget4x2', 'c_bytes', 'c_heads', 'copies', 'snap_member',
       'ref_A', 'ref_C', 'ref_A1', 'ref_A2', 'ref_X']

# function ranges that were read: everything in them that holds one of the constants is listed by `find`
RANGES = [(0x140BD0000, 0x140BDB000), (0x140BF3000, 0x140BFB000), (0x140C60000, 0x140C72000), (0x140992000, 0x1409B9000),
          (0x140873000, 0x140874000), (0x14034F000, 0x14034F400), (0x140857000, 0x140858000)]
SERVER_WIRE = (0x140BF6230, 0x140BF6C00)      # reader FUN_140bf6230, FUN_140bf6640, FUN_140bf6760
LINK = (0x140BF96A0, 0x140BF9A70)             # ScriptableSv_LinkReservedScriptable
CLIENT_APPLY = (0x140BD537D, 0x140BD5600)     # FUN_140bd5280
LIST_CODE = (0x140BF7700, 0x140BF8800)        # init and the list helpers of the C table
DISP_SHIFT = {0xFE4, 0xFE6, 0x13E6}
# the unrolled 0x80 byte struct copies (47 loops of 0x80 plus a 0x68 tail = 0x17E8 bytes)
COPY_LOOPS = {0x140993595, 0x140993606, 0x140BD1E17, 0x140BD3607, 0x140C625FC, 0x140C639F9, 0x140C63ECF, 0x140C648F9}
EXCLUDED = {
    0x140C70C84: 'save-game serializer FUN_140c70a50 (a fixed slot of DAT_146b4df48): not supported, copies the stock size',
    0x140BFA3B0: 'FUN_140bfa3a0: capacity of the FIXED parts (0xFE0 / 0x7E0), not the instance budget',
    0x140BFA3B5: 'FUN_140bfa3a0: capacity of the FIXED parts',
}


def image_path():
    lab = os.environ.get('IW7_RE_LAB', os.path.join(os.path.expanduser('~'), 'Documents', 'IW7-RE-Lab'))
    return os.path.join(lab, 'engine', 'image', 'iw7_ship_live.exe'), os.path.join(lab, 'engine', 'iw7-engine.sqlite')


class Image:
    def __init__(self, path):
        self.data = open(path, 'rb').read()
        off = struct.unpack_from('<I', self.data, 0x3C)[0]
        count = struct.unpack_from('<H', self.data, off + 6)[0]
        opt = struct.unpack_from('<H', self.data, off + 20)[0]
        table = off + 24 + opt
        self.sections = [struct.unpack_from('<8sIIII', self.data, table + 40 * i) for i in range(count)]

    def offset(self, va):
        for _, vsize, rva, rsize, raw in self.sections:
            if BASE + rva <= va < BASE + rva + min(vsize, rsize):
                return raw + va - BASE - rva
        return None

    def read(self, va, n):
        o = self.offset(va)
        return None if o is None else self.data[o:o + n]


def cs():
    import capstone
    md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
    md.detail = True
    return md


def struct_of(target):
    for name, (base, size) in STRUCTS.items():
        if base <= target < base + size:
            return name, target - base
    return None, None


def disp_field(md, ins, mem):
    """Offset of the 4-byte displacement inside the instruction, or None. capstone reports disp_size 2 for some 0x66-prefixed forms, so the
    field is found by value and confirmed by re-decoding the instruction with that field changed."""
    from capstone import x86_const as X
    raw, want = bytes(ins.bytes), mem.disp & 0xFFFFFFFF
    probe = (mem.disp + 0x01010101) & 0xFFFFFFFF
    for p in range(len(raw) - 3):
        if struct.unpack_from('<I', raw, p)[0] != want:
            continue
        changed = bytearray(raw)
        struct.pack_into('<I', changed, p, probe)
        other = next(md.disasm(bytes(changed), ins.address), None)
        if other is None or other.size != ins.size:
            continue
        om = next((o.mem for o in other.operands if o.type == X.X86_OP_MEM), None)
        if om is not None and (om.disp & 0xFFFFFFFF) == probe:
            return p
    return None


def fields(ins, md=None):
    """[(kind, field address, value, tail, mem)]: the 4-byte memory displacement and the 4-byte immediate of an instruction."""
    from capstone import x86_const as X
    md = md or cs()
    out, enc = [], ins.encoding
    mem = next((o.mem for o in ins.operands if o.type == X.X86_OP_MEM), None)
    if mem is not None and (mem.disp > 0x7F or mem.disp < -0x80 or mem.base == X.X86_REG_RIP):
        p = disp_field(md, ins, mem)
        if p is not None:
            out.append(('rip' if mem.base == X.X86_REG_RIP else 'disp', ins.address + p, mem.disp, ins.size - (p + 4), mem))
    if enc.imm_size == 4:
        out.append(('imm', ins.address + enc.imm_offset, struct.unpack_from('<I', ins.bytes, enc.imm_offset)[0], 0, None))
    return out


def inside(at, span):
    return span[0] <= at < span[1]


def classify(ins, f):
    """-> row dict (op, form, stock, tail) or None."""
    kind, field, value, tail, mem = f
    at = ins.address
    if at in EXCLUDED:
        return None
    if kind == 'imm':
        if value == 0x17E8:
            return dict(op='state_bytes', form=0, stock=value, tail=0)
        if value == 0x17E2:
            return dict(op='state_bytes_less6', form=0, stock=value, tail=0)
        if value == 0x3F8 and ins.mnemonic == 'mov' and (inside(at, SERVER_WIRE) or inside(at, LINK)):
            return dict(op='budget', form=0, stock=value, tail=0)
        if value == 0xFE0 and ins.mnemonic == 'mov' and inside(at, LIST_CODE):
            return dict(op='budget4', form=0, stock=value, tail=0)
        if value == 0xFE00FE0:
            return dict(op='budget4x2', form=0, stock=value, tail=0)
        if value == 0x5F4E:
            return dict(op='c_bytes', form=0, stock=value, tail=0)
        if value == 0x2F and at in COPY_LOOPS:
            return dict(op='copies', form=0, stock=value, tail=0)
        return None
    if kind == 'disp':
        if value in DISP_SHIFT and (inside(at, SERVER_WIRE) or inside(at, CLIENT_APPLY)):
            return dict(op='shift', form=0, stock=value, tail=0)
        if value == 0x5F40 and inside(at, (0x140BF7B00, 0x140BF8000)):
            return dict(op='c_heads', form=0, stock=value, tail=0)
        if value == 0x3AF38:
            return dict(op='snap_member', form=0, stock=value, tail=0)
        if value >= 0x100000:
            name, _ = struct_of(BASE + value)
            if name:
                return dict(op='ref_' + name, form=2, stock=value, tail=0)
        return None
    if kind == 'rip':
        target = (at + ins.size + value) & 0xFFFFFFFFFFFFFFFF
        name, _ = struct_of(target)
        if name:
            return dict(op='ref_' + name, form=1, stock=target, tail=tail)
    return None


def find(args):
    image_file, db_file = image_path()
    img = Image(image_file)
    db = sqlite3.connect('file:' + db_file.replace('\\', '/') + '?mode=ro', uri=True)
    num = lambda x: x if isinstance(x, int) else int(x, 16)
    funcs = sorted((num(a), num(e), n) for a, e, n in db.execute('select addr,end,name from functions'))
    md = cs()
    rows, seen = [], set()

    def scan(raw, start, name):
        for ins in md.disasm(raw, start):
            if ins.address in seen:
                continue
            seen.add(ins.address)
            for f in fields(ins, md):
                row = classify(ins, f)
                if row:
                    row.update(at=ins.address, field=f[1], func=name, text=ins.mnemonic + ' ' + ins.op_str, bytes=ins.bytes.hex())
                    rows.append(row)

    for a, e, name in funcs:
        if any(lo <= a < hi for lo, hi in RANGES):
            raw = img.read(a, e - a)
            if raw is not None:
                scan(raw, a, name)
    scan(img.read(0x140873E70, 7), 0x140873E70, 'snapshot block getter (data-referenced stub)')
    rows.sort(key=lambda r: r['field'])
    json.dump({'schema': 'iw7.state-sites/1', 'excluded': {hex(k): v for k, v in EXCLUDED.items()}, 'rows': rows},
              open(args.o, 'w'), indent=1)
    by = {}
    for r in rows:
        by[r['op']] = by.get(r['op'], 0) + 1
    print(len(rows), 'rows', by)


def check(args):
    image_file, _ = image_path()
    img, md = Image(image_file), cs()
    data = json.load(open(args.file))
    bad = 0
    for r in data['rows']:
        raw = img.read(r['at'], len(r['bytes']) // 2)
        ins = next(md.disasm(raw, r['at']))
        if raw.hex() != r['bytes'] or ins.size != len(raw):
            print('MISMATCH', hex(r['at']), raw.hex(), r['bytes'])
            bad += 1
            continue
        got = struct.unpack_from('<I', img.read(r['field'], 4))[0]
        want = ((r['stock'] - (r['field'] + 4 + r['tail'])) & 0xFFFFFFFF) if r['form'] == 1 else r['stock']
        if got != want:
            print('FIELD', hex(r['field']), hex(got), hex(want))
            bad += 1
    print('checked', len(data['rows']), 'rows,', bad, 'bad')
    return 1 if bad else 0


def emit(args):
    data = json.load(open(args.file))
    lines = ['// Generated by ops/engine/state_sites.py emit from state-sites.json; do not edit.',
             '// Each row: field address, form (0 value, 1 rip, 2 rva), stock value (form 1: the stock absolute target), tail bytes after a rip field, state_op.']
    for r in data['rows']:
        stock = '0x%Xull' % r['stock'] if r['form'] == 1 else '0x%Xu' % r['stock']
        lines.append('{0x%Xull, %d, %s, %d, state_op::%s},' % (r['field'], r['form'], stock, r['tail'], r['op']))
    with open(args.o, 'w', newline='\n') as out:
        out.write('\n'.join(lines) + '\n')
    print('wrote', len(data['rows']), 'rows to', args.o)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('find'); p.add_argument('-o', required=True); p.set_defaults(fn=find)
    p = sub.add_parser('check'); p.add_argument('file'); p.set_defaults(fn=check)
    p = sub.add_parser('emit'); p.add_argument('file'); p.add_argument('-o', required=True); p.set_defaults(fn=emit)
    args = ap.parse_args()
    sys.exit(args.fn(args) or 0)


if __name__ == '__main__':
    main()
