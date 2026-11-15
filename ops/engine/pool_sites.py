"""Scriptable stream buffer pools: every instruction field that depends on a pool's address or size (a43, 15 Nov 2026).

ScriptableSv_LinkReservedScriptable (and the client apply, FUN_140bd1450 / FUN_140bd91a0) takes one stream buffer of [scriptable def + 0x40]
bytes for every reserved instance from five static pools (FUN_140BE1770 alloc, FUN_140BE1E50 free, FUN_140BE1B20 class of a pointer,
FUN_140BE1970 class of a size): block sizes 16, 64, 256, 512, 3072; stock counts 128, 128, 64, 32, 32. Each pool is an array of blocks followed
by an 8 byte free-list head (an empty list holds the head's own address). The server has one pool of each class; the client has two slots of
each (flag 0, slot index 0..1, stride = array + 8). The in-use counters (0x146043318 server, 0x1460A8BB8 client) stay where they are.

    python -B ops/engine/pool_sites.py find  -o ops/engine/pool-sites.json     # analysed image (RE lab)
    python -B ops/engine/pool_sites.py check ops/engine/pool-sites.json        # decode every row against the image
    python -B ops/engine/pool_sites.py emit  ops/engine/pool-sites.json -o src/native/agent_capacity_pools.inc

Rows: form 1 = rip field whose stock target is an array base or a head (role by the target address), form 0 = a value (op pool_stride: the slot
stride array + 8; op pool_array: the array bytes, as a displacement, positive or negative); `cls` is the class 0..4.
Completeness: the instruction index of the image (kinds addr, disp, imm: every rip target, displacement and immediate) holds no other field
that names an address of the region 0x146041310..0x1460A8BE0 inside code that runs (the rest are 32-bit constants that happen to look like
addresses, or data decoded as code); there is no 8-byte pointer to the region in any section.
"""
import argparse
import json
import struct
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import state_sites as ss  # noqa: E402

BASE = ss.BASE
CLASS_BYTES = (16, 64, 256, 512, 3072)
STOCK_COUNT = (128, 128, 64, 32, 32)
# stock addresses: (domain, class, kind) -> address
SERVER_BASE = (0x1460A83B0, 0x146041310, 0x146043330, 0x14608C390, 0x1460903A0)
SERVER_HEAD = (0x1460A8BB0, 0x146043310, 0x146047330, 0x146090390, 0x1460A83A0)
CLIENT_BASE = (0x14604F350, 0x146088380, 0x146047340, 0x146080370, 0x146050360)     # slot 0
CLIENT_HEAD = (0x14604FB50, 0x14608A380, 0x14604B340, 0x146084370, 0x146068360)     # slot 0
CLIENT_STRIDE = (0x808, 0x2008, 0x4008, 0x4008, 0x18008)
CLIENT_ARRAY = (0x800, 0x2000, 0x4000, 0x4000, 0x18000)
CLIENT_COUNTERS = 0x1460A8BB8
SERVER_COUNTERS = 0x146043318
for c in range(5):
    assert SERVER_HEAD[c] - SERVER_BASE[c] == STOCK_COUNT[c] * CLASS_BYTES[c]
    assert CLIENT_HEAD[c] - CLIENT_BASE[c] == STOCK_COUNT[c] * CLASS_BYTES[c] == CLIENT_ARRAY[c]
    assert CLIENT_STRIDE[c] == CLIENT_ARRAY[c] + 8

ROLES = {}
for _c in range(5):
    ROLES[SERVER_BASE[_c]] = ('server', _c, 'base')
    ROLES[SERVER_HEAD[_c]] = ('server', _c, 'head')
    ROLES[CLIENT_BASE[_c]] = ('client', _c, 'base')
    ROLES[CLIENT_HEAD[_c]] = ('client', _c, 'head')

# code that holds the fields: the client and the server static initialisers, and the four allocator functions
RANGES = [(0x14001A240, 0x14001A510), (0x140BE1770, 0x140BE1FF8)]
# the in-use counters are addressed `[rax + index*4 + disp]` with rax = image base: stay as they are (not relocated)
COUNTER_DISPS = {SERVER_COUNTERS - BASE, CLIENT_COUNTERS - BASE}


def find(args):
    image_file, _ = ss.image_path()
    img, md = ss.Image(image_file), ss.cs()
    rows = []
    for lo, hi in RANGES:
        raw = img.read(lo, hi - lo)
        for ins in md.disasm(raw, lo):
            for kind, field, value, tail, mem in ss.fields(ins, md):
                if kind == 'rip':
                    target = (ins.address + ins.size + value) & 0xFFFFFFFFFFFFFFFF
                    if target in ROLES:
                        dom, cls, role = ROLES[target]
                        rows.append(dict(at=ins.address, field=field, form=1, stock=target, tail=tail, op='ref_%s_%s' % (dom, role),
                                         cls=cls, text=ins.mnemonic + ' ' + ins.op_str, bytes=ins.bytes.hex()))
                elif kind in ('imm', 'disp'):
                    sv = value if value < 0x80000000 else value - 0x100000000
                    if kind == 'disp' and value in COUNTER_DISPS:
                        continue
                    for name, table in (('pool_stride', CLIENT_STRIDE), ('pool_array', CLIENT_ARRAY)):
                        if abs(sv) in table and (kind == 'imm' or ins.mnemonic in ('lea',)):
                            rows.append(dict(at=ins.address, field=field, form=0, stock=value & 0xFFFFFFFF, tail=0, op=name, cls=-1,
                                             text=ins.mnemonic + ' ' + ins.op_str, bytes=ins.bytes.hex()))
    # class of the value rows: the client rip row (next within 0x10 bytes, else the nearest before); classes 2 and 3 share 0x4008 / 0x4000
    ref = [r for r in rows if r['form'] == 1 and r['op'].startswith('ref_client')]
    for r in rows:
        if r['cls'] != -1:
            continue
        table = CLIENT_STRIDE if r['op'] == 'pool_stride' else CLIENT_ARRAY
        sv = r['stock'] if r['stock'] < 0x80000000 else r['stock'] - 0x100000000
        cands = [c for c in range(5) if table[c] == abs(sv)]
        if len(cands) == 1:
            r['cls'] = cands[0]
            continue
        before = [x for x in ref if 0 < r['field'] - x['field'] <= 0x40 and x['cls'] in cands]
        after = [x for x in ref if 0 < x['field'] - r['field'] <= 0x10 and x['cls'] in cands]
        pick = min(after, key=lambda x: x['field']) if after else (max(before, key=lambda x: x['field']) if before else None)
        if pick is None:
            raise SystemExit('cannot class the field at %X' % r['field'])
        r['cls'] = pick['cls']
    rows.sort(key=lambda r: r['field'])
    json.dump({'schema': 'iw7.pool-sites/1', 'rows': rows}, open(args.o, 'w'), indent=1)
    by = {}
    for r in rows:
        by[r['op']] = by.get(r['op'], 0) + 1
    print(len(rows), 'rows', by)


def check(args):
    image_file, _ = ss.image_path()
    img, md = ss.Image(image_file), ss.cs()
    data = json.load(open(args.file))
    bad = 0
    for r in data['rows']:
        raw = img.read(r['at'], len(r['bytes']) // 2)
        ins = next(md.disasm(raw, r['at']))
        if raw.hex() != r['bytes'] or ins.size != len(raw):
            print('MISMATCH', hex(r['at']))
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
    lines = ['// Generated by ops/engine/pool_sites.py emit from pool-sites.json; do not edit.',
             '// Each row: field address, form (0 value, 1 rip), stock value (form 1: the stock absolute target), tail bytes after a rip field, pool_op, class.']
    for r in data['rows']:
        stock = '0x%Xull' % r['stock'] if r['form'] == 1 else '0x%Xu' % r['stock']
        lines.append('{0x%Xull, %d, %s, %d, pool_op::%s, %d},' % (r['field'], r['form'], stock, r['tail'], r['op'], r['cls']))
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
