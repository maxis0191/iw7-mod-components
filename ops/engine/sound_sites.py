"""Character proxy list (the client's "character sound list"): every instruction field that depends on its tables (a47, 15 Nov 2026).

The client keeps, for each local client (only client 0 is reachable: the stock tables hold one client, the next one would overlap the next table), a
list of at most 140 entries. An entry is one distinct client entity (a `centity`: eType 1 player, 18 agent, 20 actor, or 6 with a flag) that has two
physics "character proxies" (worlds 3 * client + 2 and + 4). FUN_1405527E0 appends with no bound (the callers FUN_1402E7230 and FUN_14086CD50 test
FUN_140552DB0 first: one entry a centity), FUN_1405532D0 / FUN_140552DF0 remove the entries whose entity is gone and compact. The stock arrays
(entry counts below are 140 = 0x8C) are consecutive in the data section:

    count   0x144B47820  u32 [4]                                 stays where it is
    T0      0x144B473C0  qword centity pointer                   8 bytes an entry
    T1      0x144B47830  2 x 0x18 byte transform (4 floats + 2 dwords)   0x30
    A       0x144B49270  2 x qword physics object                16   (client stride 0x118 entries: A then B)
    B       0x144B49B30  2 x qword physics object                16
    T3      0x144B4A3F0  2 x u32 proxy id                        8
    T4      0x144B4A850  2 x u32                                 8
    T5      0x144B4ACB0  2 x u32                                 8
    T6      0x144B4B110  2 x u32                                 8

    python -B ops/engine/sound_sites.py find  -o ops/engine/sound-sites.json    # analysed image (RE lab)
    python -B ops/engine/sound_sites.py check ops/engine/sound-sites.json       # decode every row against the image
    python -B ops/engine/sound_sites.py emit  ops/engine/sound-sites.json -o src/native/agent_capacity_sound.inc

Rows: form 1 = rip field naming a table (stock = the stock absolute target, tail = bytes after the field), form 2 = image-base relative disp32 naming a
table (stock = the displacement), form 0 = a value that is a multiple of the entry count 140: `n` (imul / cmp / add 0x8C), `n2` (0x118), `n8` (0x460, the T0
client stride), `n16` (+-0x8C0, A to B). `table` is the table the target lies in (the target is `table base + offset`, offset -4 for the `base - 4` forms).
Completeness: the instruction index of the whole image (kinds addr, disp, imm) holds no other field naming 0x144B473C0..0x144B4B570 in live code (`find`
prints the ones outside the ten functions; the only one is data decoded as code at 0x14C16AE5C); the multiples of 140 are looked for in the same ten
functions only (the callers pass indexes, never a table or a stride).
"""
import argparse
import json
import os
import sqlite3
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import state_sites as ss  # noqa: E402

BASE = ss.BASE
STOCK = 140
# name -> (stock base, bytes an entry); every table holds STOCK entries of one client
TABLES = {
    'T0': (0x144B473C0, 8), 'T1': (0x144B47830, 0x30), 'A': (0x144B49270, 16), 'B': (0x144B49B30, 16),
    'T3': (0x144B4A3F0, 8), 'T4': (0x144B4A850, 8), 'T5': (0x144B4ACB0, 8), 'T6': (0x144B4B110, 8),
}
COUNT = (0x144B47820, 0x144B47830)
END = 0x144B4B570           # stock end of T6 (0x144B4B110 + 140 * 8); the next object belongs to another subsystem
assert TABLES['T0'][0] + STOCK * 8 == COUNT[0]
assert TABLES['T1'][0] + STOCK * 0x30 == TABLES['A'][0] and TABLES['A'][0] + STOCK * 16 == TABLES['B'][0]
assert TABLES['B'][0] + STOCK * 16 == TABLES['T3'][0] and TABLES['T6'][0] + STOCK * 8 == END
VALUES = {0x8C: 'n', 0x118: 'n2', 0x460: 'n8', 0x8C0: 'n16', (-0x8C0) & 0xFFFFFFFF: 'n16'}
# the ten functions that touch the tables, and the stray function FUN_140552DB0 (no function record: a data-referenced stub)
RANGES = [(0x1405527E0, 0x14055281A), (0x140552820, 0x14055294C), (0x140552950, 0x1405529C2), (0x1405529D0, 0x140552A52),
          (0x140552A60, 0x140552D1A), (0x140552D20, 0x140552DAF), (0x140552DB0, 0x140552DEC), (0x140552DF0, 0x14055319F),
          (0x1405531A0, 0x1405532CA), (0x1405532D0, 0x1405539A3)]
# stack displacements and field offsets that equal a multiple of 140 but are not entry counts (the stock decompile names them)
NOT_A_COUNT = {0x140552A88: 'FUN_140552A60: [rsp + 0x118], a stack local', 0x140552EBF: 'FUN_140552DF0: test [rcx + 0x690] (a centity field)',
               0x1405535C9: 'FUN_1405532D0: test [rsi + 0x690] (a centity field)'}


def table_of(target):
    """(table, offset) of a stock absolute address, or None when it names the counts or something else. A displacement `base - 4` names the table
    behind it (the compaction loops address `[table + index * 8 - 4 + 4]`)."""
    if COUNT[0] <= target < COUNT[1]:
        return 'count', target - COUNT[0]
    for name in ('T3', 'T4', 'T5', 'T6'):
        base = TABLES[name][0]
        if base - 4 <= target < base:
            return name, target - base
    for name, (base, size) in TABLES.items():
        if base <= target < base + STOCK * size:
            return name, target - base
    return None


def functions_text(img, md):
    for lo, hi in RANGES:
        raw = img.read(lo, hi - lo)
        yield lo, hi, raw


def find(args):
    image_file, _ = ss.image_path()
    img, md = ss.Image(image_file), ss.cs()
    rows = []
    for lo, hi, raw in functions_text(img, md):
        for ins in md.disasm(raw, lo):
            for kind, field, value, tail, mem in ss.fields(ins, md):
                if kind == 'rip':
                    target = (ins.address + ins.size + value) & 0xFFFFFFFFFFFFFFFF
                    form, stock = 1, target
                elif kind == 'disp' and (value & 0xFFFFFFFF) in VALUES and ins.address not in NOT_A_COUNT:
                    rows.append(dict(at=ins.address, field=field, form=0, stock=value & 0xFFFFFFFF, tail=0, op=VALUES[value & 0xFFFFFFFF],
                                     table='', text=ins.mnemonic + ' ' + ins.op_str, bytes=ins.bytes.hex()))
                    continue
                elif kind == 'disp':
                    form, stock = 2, BASE + value
                elif kind == 'imm' and value in VALUES and ins.address not in NOT_A_COUNT:
                    rows.append(dict(at=ins.address, field=field, form=0, stock=value, tail=0, op=VALUES[value], table='',
                                     text=ins.mnemonic + ' ' + ins.op_str, bytes=ins.bytes.hex()))
                    continue
                else:
                    continue
                hit = table_of(stock)
                if hit is None or hit[0] == 'count':
                    continue
                rows.append(dict(at=ins.address, field=field, form=form, stock=stock if form == 1 else value, tail=tail, op='ref', table=hit[0],
                                 offset=hit[1], text=ins.mnemonic + ' ' + ins.op_str, bytes=ins.bytes.hex()))
    rows.sort(key=lambda r: r['field'])
    # completeness against the instruction index of the whole image
    _, db_file = ss.image_path()
    idx = os.path.join(os.path.dirname(db_file), 'iw7-insn-index.sqlite')
    outside = []
    con = sqlite3.connect('file:' + idx.replace(chr(92), '/') + '?mode=ro', uri=True)
    lo_a, hi_a = COUNT[0] - 0x460, END
    for kind, lo, hi in (('addr', lo_a, hi_a), ('disp', lo_a - BASE, hi_a - BASE), ('imm', lo_a, hi_a)):
        for v, at, func, k, text in con.execute('select value, at, func, kind, text from insn where kind=? and value>=? and value<? order by at', (kind, lo, hi)):
            if not any(a <= at < b for a, b in RANGES):
                outside.append((hex(at), kind, hex(v), text))
    json.dump({'schema': 'iw7.sound-sites/1', 'stock_entries': STOCK, 'tables': {k: [hex(v[0]), v[1]] for k, v in TABLES.items()},
               'outside': outside, 'rows': rows}, open(args.o, 'w'), indent=1)
    by = {}
    for r in rows:
        key = r['op'] + (':' + r['table'] if r['table'] else '')
        by[key] = by.get(key, 0) + 1
    print(len(rows), 'rows', by)
    print('fields outside the ten functions:', len(outside))
    for o in outside:
        print('  ', o)


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
        if r['form'] == 1:
            want = (r['stock'] - (r['field'] + 4 + r['tail'])) & 0xFFFFFFFF
        else:
            want = r['stock']
        if got != want:
            print('FIELD', hex(r['field']), hex(got), hex(want))
            bad += 1
    print('checked', len(data['rows']), 'rows,', bad, 'bad')
    return 1 if bad else 0


def emit(args):
    data = json.load(open(args.file))
    lines = ['// Generated by ops/engine/sound_sites.py emit from sound-sites.json; do not edit.',
             '// Each row: field address, form (0 value, 1 rip, 2 image-base relative), stock value (form 1: the stock absolute target; form 2: the stock',
             '// displacement), tail bytes after a rip field, sound_op, table (sound_table), offset of the target inside the table (-4 .. entry size * 140).']
    for r in data['rows']:
        stock = '0x%Xull' % r['stock'] if r['form'] == 1 else '0x%Xu' % r['stock']
        table = r['table'] or 'none'
        lines.append('{0x%Xull, %d, %s, %d, sound_op::%s, sound_table::%s, %d},' % (r['field'], r['form'], stock, r['tail'], r['op'], table, r.get('offset', 0)))
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
