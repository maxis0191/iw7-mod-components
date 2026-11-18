"""Client character tables: every cg member that is indexed by a character number with a stock stride and a stock count (a76, 17 Nov 2026).

The Zombies client object `cg` (0xFDEA8 bytes, built by FUN_140240A00, FUN_140161E50) has per-character members: the 42 character records of 0x2CA0
bytes (grown by the capacity component), a flag array, and tables that were never looked at because no crash named them. One of them,
`cg + 0x70950 + n * 0xC0` (FUN_140945FD0, 42 rows, ends at cg + 0x728D0), was written for every character number up to 263 by
FUN_140949810 (a73 write watch): 0xC0 x 240 bytes over the next members of `cg`. This tool lists the candidates by reading the analysed image
(docs/ENGINE.md) and writes the sites of the tables that were moved (plan_client of agent_capacity.cpp patches them: one field for the table of 0xC0 byte rows).

    python -I -B ops/engine/client_tables.py scan   -o client-tables-scan.json     # every function that loads `cg`: every stride-indexed member access
    python -I -B ops/engine/client_tables.py report client-tables-scan.json        # the clusters (stride, rows), what lies after them
    python -I -B ops/engine/client_tables.py find   -o ops/engine/client-tables.json   # the field of every instruction that names a moved table
    python -I -B ops/engine/client_tables.py check  ops/engine/client-tables.json  # decode every row against the image

What `scan` decodes: every byte of every function (database bounds) that loads the `cg` pointer array (`mov r,[rip-relative image + rax*8 + 0x1FA6C88]`,
1,086 functions), plus every function of the database inside the ranges in CLIENT_RANGES that the first set does not cover (the `cg` pointer arrives
as an argument there). A row is one instruction that holds a member offset (a displacement or an `add/lea` immediate in 0x100..0x110000) together with a
stride: a SIB scale, or a register scaled by `imul r,r,S`, `lea r,[r+r*k]`, `shl r,s` in the instructions before it. `report` groups the rows by stride and
by offset and says, for each group, the span of the stock rows (42 characters, 24 agents, 18 players) and whether another member starts inside it.

It is a reading aid, not a proof: a row names where a member is touched, not what indexes it. Every group that could hold a character number is
classified in docs/AGENT-CAPACITY-ENGINE.md, "Client character tables", by reading the callers.
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
CG_ARRAY_DISP = 0x1FA6C88           # `cg` pointer array (0x141FA6C88), image-base relative
CG_ARRAY_ABS = 0x141FA6C88
CG_LOW, CG_HIGH = 0x100, 0x110000   # member offsets looked at
STOCK_ROWS = (42, 24, 18)           # characters, agents, players
# code ranges whose functions get the same reading although they do not load `cg` themselves (the client game and the cgame helpers)
CLIENT_RANGES = [(0x140070000, 0x140A00000)]
LABEL = 'iw7.client-tables/1'

# the tables the capacity component moves: name, stock base (offset in cg), stride, stock rows, the function that returns the row address
TABLES = [
    dict(name='char_c0', base=0x70950, stride=0xC0, rows=42, getter=0x140945FD0,
         note='per-character smoothing record: FUN_140949810 stores 16 bytes at +0x24 of row n for every snapshot character but the local one'),
]


def lab_paths():
    return ss.image_path()


def load():
    image_file, db_file = lab_paths()
    return ss.Image(image_file), sqlite3.connect('file:%s?mode=ro' % db_file, uri=True), ss.cs()


def functions(db):
    return db.execute('select addr, end from functions order by addr').fetchall()


def loads_cg(ins):
    from capstone import x86_const as X
    for op in ins.operands:
        if op.type == X.X86_OP_MEM and op.mem.disp == CG_ARRAY_DISP and op.mem.base != X.X86_REG_RIP:
            return True
        if op.type == X.X86_OP_MEM and op.mem.base == X.X86_REG_RIP and (ins.address + ins.size + op.mem.disp) == CG_ARRAY_ABS:
            return True
    return False


def rows_of(ins_list):
    """Stride-indexed member accesses of one function: [(address, offset, stride, text)]."""
    from capstone import x86_const as X
    scaled, out, image_regs = {}, [], set()
    for k, ins in enumerate(ins_list):
        scaled = {r: v for r, v in scaled.items() if k - v[1] <= 10}
        ops = ins.operands
        # the obfuscated accessors reach their jump tables as `lea r,[rip-X]` (= the image base) and then [r + idx*4 + table]: not a member of cg
        if ins.mnemonic == 'lea' and ops[1].type == X.X86_OP_MEM and ops[1].mem.base == X.X86_REG_RIP                 and ins.address + ins.size + ops[1].mem.disp == BASE:
            image_regs.add(ops[0].reg)
        elif ops and ops[0].type == X.X86_OP_REG and ops[0].reg in image_regs and ins.mnemonic in ('mov', 'lea', 'xor', 'pop'):
            image_regs.discard(ops[0].reg)
        if ins.mnemonic == 'imul' and len(ops) == 3 and ops[2].type == X.X86_OP_IMM and ops[0].type == X.X86_OP_REG:
            scaled[ops[0].reg] = (ops[2].imm, k)
        elif ins.mnemonic == 'lea' and ops[1].type == X.X86_OP_MEM:
            m = ops[1].mem
            if m.index and m.scale > 1 and m.disp == 0 and m.base == m.index:
                scaled[ops[0].reg] = (m.scale + 1, k)
            elif m.index and m.base == 0 and m.scale > 1:
                scaled[ops[0].reg] = (m.scale, k)
        elif ins.mnemonic == 'shl' and ops[-1].type == X.X86_OP_IMM and ops[0].type == X.X86_OP_REG and ops[-1].imm < 16:
            r = ops[0].reg
            scaled[r] = ((scaled[r][0] if r in scaled else 1) << ops[-1].imm, k)
        for op in ops:
            if op.type == X.X86_OP_MEM and CG_LOW <= op.mem.disp < CG_HIGH and op.mem.base != X.X86_REG_RIP                     and op.mem.base not in image_regs and op.mem.index not in image_regs:
                s = 0
                if op.mem.index and op.mem.index in scaled:
                    s = scaled[op.mem.index][0] * op.mem.scale
                elif op.mem.base in scaled:
                    s = scaled[op.mem.base][0]
                elif op.mem.index:
                    s = op.mem.scale
                if s > 1:
                    out.append((ins.address, op.mem.disp, s, ins.mnemonic + ' ' + ins.op_str))
        if ins.mnemonic in ('add', 'lea', 'sub') and ops and ops[-1].type == X.X86_OP_IMM and CG_LOW <= ops[-1].imm < CG_HIGH \
                and ops[0].type == X.X86_OP_REG and ops[0].reg in scaled and scaled[ops[0].reg][0] > 1:
            out.append((ins.address, ops[-1].imm, scaled[ops[0].reg][0], ins.mnemonic + ' ' + ins.op_str))
    return out


def scan(args):
    img, db, md = load()
    funcs = functions(db)
    rows, loaders, decoded, covered = [], 0, 0, 0
    for start, end in funcs:
        in_client = any(lo <= start < hi for lo, hi in CLIENT_RANGES)
        raw = img.read(start, end - start)
        if raw is None or end - start > 0x100000:
            continue
        ins_list = list(md.disasm(raw, start))
        cg_loader = any(loads_cg(i) for i in ins_list)
        if not cg_loader and not in_client:
            continue
        loaders += 1 if cg_loader else 0
        decoded += 1
        covered += len(raw)
        for at, off, stride, text in rows_of(ins_list):
            rows.append(dict(func=start, at=at, offset=off, stride=stride, loads_cg=cg_loader, text=text))
    json.dump(dict(schema=LABEL, loaders=loaders, functions=decoded, bytes=covered, rows=rows), open(args.o, 'w'), indent=0)
    print('%d functions decoded (%d load cg), %d bytes, %d rows' % (decoded, loaders, covered, len(rows)))


def report(args):
    data = json.load(open(args.file))
    rows = [r for r in data['rows'] if r['loads_cg'] or args.all]
    by = {}
    for r in rows:
        by.setdefault(r['stride'], []).append(r)
    members = sorted({r['offset'] for r in data['rows']})
    lines = []
    for stride in sorted(by):
        grp = sorted(by[stride], key=lambda r: r['offset'])
        # one table: offsets within one stride of each other chain up; a gap larger than 4 strides starts the next
        cluster = [grp[0]]
        clusters = []
        for r in grp[1:]:
            if r['offset'] - cluster[-1]['offset'] <= max(stride, 0x40) * 2:
                cluster.append(r)
            else:
                clusters.append(cluster)
                cluster = [r]
        clusters.append(cluster)
        for c in clusters:
            lo = c[0]['offset']
            span = {k: lo + stride * k for k in STOCK_ROWS}
            inside = {k: [m for m in members if lo + stride <= m < span[k]] for k in STOCK_ROWS}
            funcs_ = sorted({r['func'] for r in c})
            lines.append((lo, stride, len(c), len(funcs_), span, inside, funcs_, c[0]['text']))
    lines.sort()
    print('offset   stride  rows funcs  end42    next member inside the 42 rows   funcs')
    for lo, stride, n, nf, span, inside, funcs_, text in lines:
        nxt = inside[42][0] if inside[42] else None
        print('%#08x %#6x %5d %5d  %#08x  %-10s  %s  e.g. %s' % (lo, stride, n, nf, span[42], ('%#x' % nxt) if nxt else '-',
                                                                  ','.join('%X' % f for f in funcs_[:4]), text[:50]))


def table_fields(img, db, md, table):
    lo, hi = table['base'], table['base'] + table['stride'] * table['rows']
    sites = []
    for start, end in functions(db):
        raw = img.read(start, end - start)
        if raw is None:
            continue
        ins_list = list(md.disasm(raw, start))
        if start != table['getter'] and not any(loads_cg(i) for i in ins_list):
            continue
        for ins in ins_list:
            for kind, field, value, tail, mem in ss.fields(ins, md):
                if kind not in ('disp', 'imm'):
                    continue
                sv = value if value < 0x80000000 else value - 0x100000000
                if lo <= sv < hi and (kind == 'disp' or ins.mnemonic in ('add', 'lea', 'sub')):
                    sites.append(dict(at=ins.address, field=field, kind=kind, stock=sv, text=ins.mnemonic + ' ' + ins.op_str,
                                      bytes=ins.bytes.hex(), func=start, offset_in_table=sv - lo))
    return sites


def find(args):
    img, db, md = load()
    out = []
    for t in TABLES:
        sites = table_fields(img, db, md, t)
        out.append(dict(t, sites=sites))
        print(t['name'], len(sites), 'sites', [hex(s['field']) for s in sites])
    json.dump(dict(schema=LABEL, tables=out), open(args.o, 'w'), indent=1)


def check(args):
    img, db, md = load()
    data = json.load(open(args.file))
    bad = 0
    for t in data['tables']:
        for s in t['sites']:
            raw = img.read(s['at'], len(s['bytes']) // 2)
            ins = next(md.disasm(raw, s['at']))
            if raw.hex() != s['bytes'] or ins.size != len(raw):
                print('MISMATCH', hex(s['at']))
                bad += 1
                continue
            got = struct.unpack_from('<I', img.read(s['field'], 4))[0]
            if got != (s['stock'] & 0xFFFFFFFF):
                print('FIELD', hex(s['field']), hex(got), hex(s['stock']))
                bad += 1
    print('checked', sum(len(t['sites']) for t in data['tables']), 'rows,', bad, 'bad')
    return 1 if bad else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('scan'); p.add_argument('-o', required=True); p.set_defaults(fn=scan)
    p = sub.add_parser('report'); p.add_argument('file'); p.add_argument('--all', action='store_true'); p.set_defaults(fn=report)
    p = sub.add_parser('find'); p.add_argument('-o', required=True); p.set_defaults(fn=find)
    p = sub.add_parser('check'); p.add_argument('file'); p.set_defaults(fn=check)
    args = ap.parse_args()
    sys.exit(args.fn(args) or 0)


if __name__ == '__main__':
    main()
