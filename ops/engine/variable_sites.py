"""Script variable pools: every instruction field and constant that depends on the size of the child and parent tables (a46, 15 Nov 2026).

The GSC variable system (scr_VarGlob, docs/SCRIPT-VARIABLES.md) is one contiguous block of static tables, indexed by the parent id or by the
child index of a segment:

    0x14665A180  A         u16 a parent id      (0xDC00 entries, 0x1B800 bytes)   save/restore numbering
    0x146675980  B         u16 a parent id      (0x1B800)                         save/restore numbering
    0x146691180  P8        8 bytes a parent id  (0x6E000)
    0x1466FF180  P4        4 bytes a parent id  (0x37000)                         first / last child
    0x146736180  HASH      4 segments x 0x4000 u16 buckets (0x20000)              not touched
    0x146756180  CH        4 segments x 0xA000 entries of 0x18 bytes (0x3C0000)

with the counters and a few scalars in front, at 0x14665A100 (not touched). The stage 1 change (this tool) grows the segments to 0x10000 child
entries (index 1..0xFFFF) and the parent ids to 0x10000 (ids 0..3 are the list heads): A, B, P8, P4 and CH move to component storage, the code
that names them is edited in place:

  ref     a 4 byte field (rip displacement, or a displacement from a register that holds a known table address): `target` (stock absolute address)
          and `base` (the stock absolute value the register holds, 0 for a rip field). New value = new(target) - new(base).
  seg_lea `lea r,[s+s*4]` (3 or 4 bytes) -> `mov r,s` + nops: with the `shl r,0xd` that follows (seg_shl: the imm8 becomes 0x10) the segment base
          changes from s * 0xA000 to s * 0x10000.
  imm     a 4 byte constant that is a function of the table size: child_bound 0xA000, parent_bound 0xDC00, name_bound 0x4DC00 (object key names are
          0x40000 + parent id), recip 0xCCCCCCCD (the counter segment base / 0xA000 as a reciprocal multiply, shr 15), p4_bytes 0x37000 and
          p2_bytes 0x1B800 (memset / copy sizes), idiom16 `lea r,[r+0xC500]` (the distance P8 -> CH divided by 16, the next lea multiplies by 3 and
          the access by 8).

    python -B ops/engine/variable_sites.py find  -o ops/engine/variable-sites.json     # analysed image + instruction index (RE lab)
    python -B ops/engine/variable_sites.py check ops/engine/variable-sites.json        # decode every row against the image
    python -B ops/engine/variable_sites.py emit  ops/engine/variable-sites.json -o src/native/script_variables_sites.inc

Completeness: the candidate functions come from the instruction index of the whole image (every rip target, displacement and immediate): all
functions that name an address of 0x14665A100..0x146B16180 (rip or image relative), a displacement that is the distance between two of the tables,
or a `shl r,0xd` (the segment base); then each function is decoded and the register provenance of its base registers is followed (a `lea r,[rip+X]`
or `lea r,[img+disp]` gives the register a known table address; copies and `lea` with an index keep it). A field whose displacement is one of the
table distances but whose base register is not known is reported as `unresolved` and the run fails.
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
# name -> (stock base, stock bytes)
REGIONS = {
    'A': (0x14665A180, 0x1B800),
    'B': (0x146675980, 0x1B800),
    'P8': (0x146691180, 0x6E000),
    'P4': (0x1466FF180, 0x37000),
    'HASH': (0x146736180, 0x20000),
    'CH': (0x146756180, 0x3C0000),
    'BLOCK0': (0x14665A100, 0x80),     # counters (0x14665A134..) and scalars: stays
    'IMG': (BASE, 1),                  # image base register
}
# fields whose base register is defined on another path than the one the linear walk follows; the register was read by eye (a46)
OVERRIDES = {0x140C051CC: 'P8'}     # FindVariable: rbx = P8 + bucket * 2 (the bucket write-back of the move-to-front)
MOVED = ('A', 'B', 'P8', 'P4', 'CH')
VM_CALLS = (0x140BFE000, 0x140C11000)   # the variable system API: calls in here pass a segment base or an id
LO, HI = 0x14665A100, 0x146B16180

# register names -> hardware number, and any width -> the 64-bit name
HW, HW64, FULL = {}, set(), {}
for _n, _b in enumerate(['ax', 'cx', 'dx', 'bx', 'sp', 'bp', 'si', 'di']):
    _full = 'r' + _b
    HW64.add(_full)
    for _name in (_full, 'e' + _b, _b):
        HW[_name] = _n
        FULL[_name] = _full
FULL.update({'al': 'rax', 'cl': 'rcx', 'dl': 'rdx', 'bl': 'rbx', 'spl': 'rsp', 'bpl': 'rbp', 'sil': 'rsi', 'dil': 'rdi'})
for _n in range(8, 16):
    _full = 'r%d' % _n
    HW64.add(_full)
    for _name in (_full, _full + 'd', _full + 'w', _full + 'b'):
        HW[_name] = _n
        FULL[_name] = _full


def region_of(addr):
    for name, (b, n) in REGIONS.items():
        if name == 'IMG':
            continue
        if b <= addr < b + n:
            return name
    return None


def scaled_distances():
    """imm / disp values equal to the distance between two tables divided by 1, 2, 4, 8 or 16 (a lea / add idiom that folds a distance into a count of
    entries): any such constant in related code that no row classifies stops the run."""
    names = [n for n in REGIONS if n not in ('IMG',)]
    out = {}
    for a in names:
        for b in names:
            if a == b:
                continue
            d = REGIONS[b][0] - REGIONS[a][0]
            for k in (1, 2, 4, 8, 16):
                for ext in (0, 8, 0x10):
                    v = d + ext
                    if v > 0 and v % k == 0 and v // k >= 0x1000:
                        out.setdefault(v // k, '%s->%s /%d' % (a, b, k))
    return out


SCALED_DISTANCES = {}


def family_ranges():
    """Displacements that can be the distance from the base register's table to another table (a base register holds a stock table address)."""
    out = []
    names = [n for n in REGIONS if n != 'IMG']
    for b in names:
        for t in names:
            if b == t:
                continue
            d0 = REGIONS[t][0] - REGIONS[b][0]
            out.append((d0, d0 + REGIONS[t][1], b, t))
    return out


def index_path():
    lab = os.environ.get('IW7_RE_LAB', os.path.join(os.path.expanduser('~'), 'Documents', 'IW7-RE-Lab'))
    return os.path.join(lab, 'engine', 'iw7-insn-index.sqlite')


def candidates(image_dbs):
    """Function addresses (and gap start for instructions outside any known function) that hold a candidate instruction."""
    c = sqlite3.connect('file:' + index_path().replace('\\', '/') + '?mode=ro', uri=True)
    hits = {}
    def add(rows, why):
        for at, fn in rows:
            hits.setdefault(fn or 0, set()).add((at, why))
    add(c.execute("select at,func from insn where kind='addr' and value>=? and value<?", (LO, HI)).fetchall(), 'addr')
    add(c.execute("select at,func from insn where kind='disp' and value>=? and value<?", (LO - BASE, HI - BASE)).fetchall(), 'rva')
    for d0, d1, b, t in family_ranges():
        for lo, hi in ((d0, d1), (d0 + 0x100000000, d1 + 0x100000000)):
            if lo < 0 or hi - lo > 0x400000:
                continue
            add(c.execute("select at,func from insn where kind='disp' and value>=? and value<?", (lo, hi)).fetchall(), 'rel')
    add(c.execute("select at,func from insn where kind='imm' and value=13 and text like 'shl %, 0xd'").fetchall(), 'shl')
    return hits


def func_bounds(db_file):
    db = sqlite3.connect('file:' + db_file.replace('\\', '/') + '?mode=ro', uri=True)
    num = lambda x: x if isinstance(x, int) else int(x, 16)
    return sorted((num(a), num(e)) for a, e in db.execute('select addr,end from functions'))


def regs(ins):
    try:
        r, w = ins.regs_access()
        return list(r), list(w)
    except Exception:
        return [], []


def canon(md, ins, reg):
    return FULL.get(ins.reg_name(reg))


class Walker:
    def __init__(self, img, md):
        self.img, self.md = img, md

    def decode_range(self, start, end):
        raw = self.img.read(start, end - start)
        return list(self.md.disasm(raw, start)) if raw else []

    def walk(self, ins_list, name):
        """-> dict(rows, pairs, unpaired, unresolved, regions, vmcalls)"""
        from capstone import x86_const as X
        md = self.md
        prov = {}
        rows, unresolved = [], []
        pairs, unpaired = [], []
        has_region, vmcalls = False, 0
        shl_seen = []
        for k, ins in enumerate(ins_list):
            text = ins.mnemonic + ' ' + ins.op_str
            mem = next((o.mem for o in ins.operands if o.type == X.X86_OP_MEM), None)
            for kind, field, value, tail, m in ss.fields(ins, md):
                if kind == 'imm':
                    continue
                sv = value if value < 0x80000000 else value - 0x100000000
                if kind == 'rip':
                    target = (ins.address + ins.size + sv) & 0xFFFFFFFFFFFFFFFF
                    rt = region_of(target)
                    if rt:
                        has_region = True
                        if rt in MOVED:
                            rows.append(dict(at=ins.address, field=field, op='ref', form='rip', base=0, target=target, tail=tail, region=rt,
                                             text=text, bytes=ins.bytes.hex()))
                    continue
                # a displacement field with a base register (or none)
                assumed = False
                if m.base != 0:
                    breg = canon(md, ins, m.base)
                    pv = prov.get(breg)
                    assumed = False
                    if pv is None and m.index != 0 and m.scale == 1:
                        pv = prov.get(canon(md, ins, m.index))      # `[r12 + r13 + disp]`: either register can be the table pointer
                    if pv is None and ins.address in OVERRIDES:
                        pv = REGIONS[OVERRIDES[ins.address]][0]
                    if pv is None and LO - BASE <= sv < HI - BASE:
                        pv = BASE                       # an image relative table address: the base register is the image base (loaded on another path)
                    if pv is None and (0xA5000 <= sv < 0xA5000 + 0x20 or 0xC5000 <= sv < 0xC5000 + 0x20 or 0x6E000 <= sv < 0x6E000 + 0x20):
                        pv, assumed = REGIONS['P8'][0], True    # a distance from the parent table to another table: the register points into P8
                    if pv is None:
                        fam = [1 for d0, d1, b, t in family_ranges() if d0 <= sv < d1 or d0 <= sv - 0x100000000 < d1]
                        if fam and any(sv == s for s in (0xA5000, 0xC5000, 0x6E000, 0x6E002, 0x1B880)):
                            unresolved.append(dict(at=ins.address, field=field, text=text, why='base register not known'))
                        continue
                    b0 = pv
                else:
                    if sv < 0x1000000:
                        continue
                    b0 = BASE
                target = b0 + sv
                rb, rt = region_of(b0), region_of(target)
                if rt:
                    has_region = True
                if (rt in MOVED) or (rb in MOVED and rt is not None) or (rb in MOVED and rt is None and 0 <= sv < 0x500000):
                    if rt is None:
                        unresolved.append(dict(at=ins.address, field=field, text=text, why='base in a moved table, target outside every table'))
                        continue
                    rows.append(dict(at=ins.address, field=field, op='ref', form='disp', base=b0, target=target, tail=0, region=rt,
                                     text=text, bytes=ins.bytes.hex(), assumed=assumed))
            # provenance after the instruction
            mn = ins.mnemonic
            read, write = regs(ins)
            if mn == 'lea' and len(ins.operands) == 2 and ins.operands[0].type == X.X86_OP_REG:
                dst = canon(md, ins, ins.operands[0].reg)
                m = ins.operands[1].mem
                new = None
                if m.base == X.X86_REG_RIP:
                    new = (ins.address + ins.size + m.disp) & 0xFFFFFFFFFFFFFFFF
                elif m.base != 0 and canon(md, ins, m.base) in prov and ins.reg_name(ins.operands[0].reg) in HW64:
                    new = prov[canon(md, ins, m.base)] + m.disp
                elif m.base == 0 and m.index != 0 and m.disp > 0x1000000 and ins.reg_name(ins.operands[0].reg) in HW64:
                    new = None
                if new is not None:
                    prov[dst] = new
                else:
                    prov.pop(dst, None)
            elif mn == 'mov' and len(ins.operands) == 2 and ins.operands[0].type == X.X86_OP_REG and ins.operands[1].type == X.X86_OP_REG \
                    and ins.reg_name(ins.operands[0].reg) in HW64:
                dst, src = canon(md, ins, ins.operands[0].reg), canon(md, ins, ins.operands[1].reg)
                if src in prov:
                    prov[dst] = prov[src]
                else:
                    prov.pop(dst, None)
            elif mn in ('add', 'sub') and len(ins.operands) == 2 and ins.operands[0].type == X.X86_OP_REG and ins.operands[1].type == X.X86_OP_IMM:
                pass     # a constant added to a table pointer: keep the base (the unknown / constant part is added by the field)
            else:
                for r in write:
                    nm = ins.reg_name(r)
                    if nm in FULL:
                        prov.pop(FULL[nm], None)
            if mn == 'call':
                for r in ('rax', 'rcx', 'rdx', 'r8', 'r9', 'r10', 'r11'):
                    prov.pop(r, None)
                if ins.operands and ins.operands[0].type == X.X86_OP_IMM and VM_CALLS[0] <= ins.operands[0].imm < VM_CALLS[1]:
                    vmcalls += 1
            if mn == 'shl' and len(ins.operands) == 2 and ins.operands[1].type == X.X86_OP_IMM and ins.operands[1].imm == 0xD \
                    and ins.operands[0].type == X.X86_OP_REG:
                shl_seen.append(k)
        # segment base pairs
        for k in shl_seen:
            shl = ins_list[k]
            r = shl.operands[0].reg
            rname = canon(md, shl, r)
            found = None
            for j in range(k - 1, max(-1, k - 14), -1):
                p = ins_list[j]
                rd, wr = regs(p)
                wrote = any(canon(md, p, w) == rname for w in wr if p.reg_name(w) in FULL)
                if wrote:
                    if p.mnemonic == 'lea' and p.operands[0].type == X.X86_OP_REG and canon(md, p, p.operands[0].reg) == rname:
                        m = p.operands[1].mem
                        if m.base != 0 and m.base == m.index and m.scale == 4 and m.disp == 0:
                            found = j
                    break
                if any(canon(md, p, w) == rname for w in rd if p.reg_name(w) in FULL):
                    break
            if found is None:
                unpaired.append(dict(at=shl.address, text=shl.mnemonic + ' ' + shl.op_str))
                continue
            lea = ins_list[found]
            pairs.append(dict(lea=lea, shl=shl, mid=[ins_list[j] for j in range(found + 1, k)]))
        return dict(rows=rows, pairs=pairs, unpaired=unpaired, unresolved=unresolved, has_region=has_region, vmcalls=vmcalls)


def mov_bytes(lea, md):
    """`lea d,[s+s*4]` -> `mov d,s` padded with 1-byte nops to the same length."""
    from capstone import x86_const as X
    dst, src = lea.operands[0], lea.operands[1].mem
    dn, sn = lea.reg_name(dst.reg), lea.reg_name(src.base)
    wide = dn in HW64
    dh, sh = HW[dn], HW[sn]
    rex = 0x40 | (8 if wide else 0) | ((sh >> 3) << 2) | (dh >> 3)
    raw = bytes([rex]) if rex != 0x40 else b''
    raw += bytes([0x89, 0xC0 | ((sh & 7) << 3) | (dh & 7)])
    if len(raw) > lea.size:
        raise SystemExit('mov longer than lea at %X' % lea.address)
    raw += b'\x90' * (lea.size - len(raw))
    check = list(md.disasm(raw, lea.address))
    ok = (len(check) >= 1 and check[0].mnemonic == 'mov' and len(check[0].operands) == 2
          and HW.get(check[0].reg_name(check[0].operands[0].reg)) == dh and HW.get(check[0].reg_name(check[0].operands[1].reg)) == sh
          and (check[0].reg_name(check[0].operands[0].reg) in HW64) == wide and check[0].size + sum(c.size for c in check[1:]) == lea.size
          and all(c.mnemonic == 'nop' for c in check[1:]))
    if not ok:
        raise SystemExit('re-encoded lea at %X is not mov %s, %s: %s' % (lea.address, dn, sn, [c.mnemonic + ' ' + c.op_str for c in check]))
    return raw


def imm_rows(ins_list, walk, md, vm_function):
    """Constants that are a function of the table sizes, in a function that holds the variable system's tables or calls into it."""
    out = []
    from capstone import x86_const as X
    for k, ins in enumerate(ins_list):
        for kind, field, value, tail, m in ss.fields(ins, md):
            if kind == 'imm':
                mn = ins.mnemonic
                if value == 0xA000 and mn == 'cmp':
                    out.append(dict(at=ins.address, field=field, op='child_bound', stock=value))
                elif value == 0xDC00 and mn == 'cmp':
                    out.append(dict(at=ins.address, field=field, op='parent_bound', stock=value))
                elif value == 0x52800 and mn == 'add' and ins.operands[0].type == X.X86_OP_REG:
                    out.append(dict(at=ins.address, field=field, op='hash_half', stock=value))
                elif value == 0x4DC00 and mn == 'cmp':
                    out.append(dict(at=ins.address, field=field, op='name_bound', stock=value))
                elif value == 0x37000 and mn == 'mov':
                    out.append(dict(at=ins.address, field=field, op='p4_bytes', stock=value))
                elif value == 0x1B800 and mn == 'mov':
                    out.append(dict(at=ins.address, field=field, op='p2_bytes', stock=value))
                elif value == 0xFB23FF and mn == 'cmp':
                    out.append(dict(at=ins.address, field=field, op='int_high', stock=value))
                elif value == 0xCCCCCCCD and mn == 'mov':
                    nxt = ' | '.join(i.mnemonic + ' ' + i.op_str for i in ins_list[k + 1:k + 8])
                    if 'mul' in nxt and 'shr edx, 0xf' in nxt:
                        out.append(dict(at=ins.address, field=field, op='recip', stock=value))
            elif kind == 'disp' and value == 0x7B2400 and ins.mnemonic == 'lea' and m.base != 0 and m.index == 0:
                # integer key range check `lea eax,[rdx+0x7B2400]; cmp eax,0xFB23FF; ja`: integer key names n + 0x800000 start at the object key bound
                out.append(dict(at=ins.address, field=field, op='int_low', stock=value))
            elif kind == 'disp' and value == 0xC500 and ins.mnemonic == 'lea' and m.base != 0 and m.index == 0:
                nxt = ins_list[k + 1] if k + 1 < len(ins_list) else None
                if nxt is not None and nxt.mnemonic == 'lea' and '*2' in nxt.op_str:
                    out.append(dict(at=ins.address, field=field, op='idiom16', stock=value))
    known = {r['field'] for r in out}
    for k, ins in enumerate(ins_list):
        for kind, field, value, tail, m in ss.fields(ins, md):
            if kind in ('imm', 'disp') and field not in known and value in SCALED_DISTANCES and value >= 0x1000                     and not (kind == 'disp' and m is not None and m.base != 0 and value in (0x1B880,)):
                out.append(dict(at=ins.address, field=field, op='UNCLASSIFIED', stock=value, why=SCALED_DISTANCES[value]))
    for r in out:
        r['text'] = ''
    return out


def find(args):
    SCALED_DISTANCES.update({v: w for v, w in scaled_distances().items() if v not in (0x37000, 0x1B800, 0x20000, 0x6E000, 0xC5000, 0xA5000, 0x1B880, 0x37080)})
    image_file, db_file = ss.image_path()
    img, md = ss.Image(image_file), ss.cs()
    bounds = func_bounds(db_file)
    starts = [b[0] for b in bounds]
    import bisect

    def func_of(at):
        i = bisect.bisect_right(starts, at) - 1
        if i >= 0 and bounds[i][0] <= at < bounds[i][1]:
            return bounds[i]
        lo = bounds[i][1] if i >= 0 else at
        hi = bounds[i + 1][0] if i + 1 < len(bounds) else at + 0x400
        return (lo, hi)

    hits = candidates(None)
    funcs = set()
    for fn, items in hits.items():
        for at, why in items:
            funcs.add(func_of(at))
    for s, e in bounds:      # the variable system itself: every function in its address range
        if VM_CALLS[0] <= s < VM_CALLS[1]:
            funcs.add((s, e))
    w = Walker(img, md)
    rows, pair_rows, imms, unres, unpaired, related, skipped_pairs, unclassified = [], [], [], [], [], [], [], []
    for s, e in sorted(funcs):
        ins_list = w.decode_range(s, e)
        if not ins_list:
            continue
        res = w.walk(ins_list, '')
        vm = VM_CALLS[0] <= s < VM_CALLS[1]
        rel = vm or res['has_region'] or res['vmcalls'] > 0
        for r in res['rows']:
            r['func'] = s
            rows.append(r)
        for u in res['unresolved']:
            u['func'] = s
            unres.append(u)
        if rel:
            related.append(s)
            for r in imm_rows(ins_list, res, md, vm):
                r['func'] = s
                (unclassified if r['op'] == 'UNCLASSIFIED' else imms).append(r)
            for p in res['pairs']:
                lea, shl = p['lea'], p['shl']
                new = mov_bytes(lea, md)
                pair_rows.append(dict(at=lea.address, op='seg_lea', len=lea.size, before=lea.bytes.hex(), after=new.hex(), func=s,
                                      text=lea.mnemonic + ' ' + lea.op_str, between=len(p['mid'])))
                pair_rows.append(dict(at=shl.address, op='seg_shl', field=shl.address + shl.encoding.imm_offset, before=0xD, after=0x10, func=s,
                                      text=shl.mnemonic + ' ' + shl.op_str, bytes=shl.bytes.hex()))
            unpaired += [dict(u, func=s) for u in res['unpaired']]
        else:
            skipped_pairs += [dict(at=p['shl'].address, func=s, text=p['lea'].op_str) for p in res['pairs']]
    def dedupe(items, key):
        seen, out = set(), []
        for r in items:
            if key(r) not in seen:
                seen.add(key(r))
                out.append(r)
        return out
    rows = dedupe(rows, lambda r: r['field'])
    # a real reference names a table base or a field of its first entry (offset <= 0x1F); anything deeper into a table is a constant that only
    # looks like an address (data decoded as code, obfuscated code): listed under `rejected`, none may be in the variable system's own code
    rejected = [r for r in rows if r['target'] - REGIONS[r['region']][0] > 0x1F]
    rows = [r for r in rows if r['target'] - REGIONS[r['region']][0] <= 0x1F]
    inside = [r for r in rejected if VM_CALLS[0] <= r['func'] < VM_CALLS[1]]
    if inside:
        raise SystemExit('rejected reference inside the variable system: %s' % [hex(r['at']) for r in inside])
    pair_rows = dedupe(pair_rows, lambda r: (r['at'], r['op']))
    imms = dedupe(imms, lambda r: r['field'])
    unpaired = dedupe(unpaired, lambda r: r['at'])
    rows.sort(key=lambda r: r['field'])
    data = dict(schema='iw7.variable-sites/1', regions={k: [hex(v[0]), hex(v[1])] for k, v in REGIONS.items()},
                refs=rows, rejected=rejected, pairs=pair_rows, imms=imms, unresolved=unres, unclassified=unclassified, unpaired=unpaired, unrelated_pairs=skipped_pairs, functions=sorted(related))
    json.dump(data, open(args.o, 'w'), indent=1)
    byop = {}
    for r in rows:
        byop[(r['form'], r['region'])] = byop.get((r['form'], r['region']), 0) + 1
    print(len(rows), 'refs', byop)
    print(len(pair_rows) // 2, 'segment base pairs in', len({p['func'] for p in pair_rows}), 'functions;', len(skipped_pairs), 'pairs of unrelated functions')
    cnt = {}
    for r in imms:
        cnt[r['op']] = cnt.get(r['op'], 0) + 1
    print('imm', cnt)
    print('constants that look like a halved or scaled table distance, not classified:', sorted({hex(r['stock']) + ' ' + r['why'] for r in unclassified}))
    print(len(unres), 'unresolved,', len(unpaired), 'unpaired shl 0xd in related functions,', len(related), 'functions')
    return 1 if unres else 0


def check(args):
    image_file, _ = ss.image_path()
    img, md = ss.Image(image_file), ss.cs()
    data = json.load(open(args.file))
    bad = 0
    for kind in ('refs', 'imms', 'pairs'):
        for r in data[kind]:
            n = len(r['bytes']) // 2 if 'bytes' in r else r.get('len', 4)
            raw = img.read(r['at'], n)
            if 'bytes' in r and raw.hex() != r['bytes']:
                print('MISMATCH', hex(r['at']))
                bad += 1
                continue
            if r['op'] == 'seg_lea':
                if raw.hex() != r['before']:
                    print('MISMATCH lea', hex(r['at']))
                    bad += 1
                continue
            if r['op'] == 'seg_shl':
                if img.read(r['field'], 1)[0] != 0xD:
                    print('SHL', hex(r['field']))
                    bad += 1
                continue
            got = struct.unpack_from('<I', img.read(r['field'], 4))[0]
            if r['op'] == 'ref':
                if r['form'] == 'rip':
                    want = (r['target'] - (r['field'] + 4 + r['tail'])) & 0xFFFFFFFF
                else:
                    want = (r['target'] - r['base']) & 0xFFFFFFFF
            else:
                want = r['stock']
            if got != want:
                print('FIELD', hex(r['field']), hex(got), hex(want))
                bad += 1
    print('checked', len(data['refs']), 'refs', len(data['imms']), 'imms', len(data['pairs']) // 2, 'pairs,', bad, 'bad')
    return 1 if bad else 0


OPS = ['hash_half', 'child_bound', 'parent_bound', 'name_bound', 'recip', 'p4_bytes', 'p2_bytes', 'idiom16', 'int_low', 'int_high']
REGION_INDEX = {'A': 0, 'B': 1, 'P8': 2, 'P4': 3, 'CH': 4}


def emit(args):
    data = json.load(open(args.file))
    lines = ['// Generated by ops/engine/variable_sites.py emit from variable-sites.json; do not edit.']
    lines.append('// refs: {field, form (0 disp, 1 rip), base (stock absolute value of the base register, 0 for rip), target (stock absolute), tail, region_of_target}')
    ref_lines = []
    for r in data['refs']:
        ref_lines.append('{0x%Xull, %d, 0x%Xull, 0x%Xull, %d},' % (r['field'], 1 if r['form'] == 'rip' else 0, r['base'], r['target'], r['tail']))
    imm_lines = ['{0x%Xull, script_op::%s},' % (r['field'], r['op']) for r in sorted(data['imms'], key=lambda r: r['field'])]
    def le(hexs):
        return ''.join(reversed([hexs[i:i + 2] for i in range(0, len(hexs), 2)]))
    lea_lines = ['{0x%Xull, %d, 0x%s, 0x%s},' % (r['at'], r['len'], le(r['before']), le(r['after']))
                 for r in sorted(data['pairs'], key=lambda r: r['at']) if r['op'] == 'seg_lea']
    shl_lines = ['{0x%Xull},' % r['field'] for r in sorted(data['pairs'], key=lambda r: r['at']) if r['op'] == 'seg_shl']
    with open(args.o, 'w', newline='\n') as out:
        out.write('\n'.join(lines) + '\n')
        out.write('#ifdef SCRIPT_VARIABLES_REFS\n' + '\n'.join(ref_lines) + '\n#endif\n')
        out.write('#ifdef SCRIPT_VARIABLES_IMMS\n' + '\n'.join(imm_lines) + '\n#endif\n')
        out.write('#ifdef SCRIPT_VARIABLES_LEAS\n' + '\n'.join(lea_lines) + '\n#endif\n')
        out.write('#ifdef SCRIPT_VARIABLES_SHLS\n' + '\n'.join(shl_lines) + '\n#endif\n')
    print('wrote', len(ref_lines), 'refs', len(imm_lines), 'imms', len(lea_lines), 'pairs to', args.o)


# ------------------------------------------------------------------------------------------------ parent ids beyond u16 (a56)
# Stage 2: an id is 4 x local + segment (segment = id & 3), 18 bits; the u16 fields that held a whole id hold the LOCAL index (id >> 2) and the
# segment is taken from where the entry lives. `parents` finds every site of the kinds below, prints them, and (with -o) writes the cave requests.
THREAD_FUNCS = (0x140C0ACD0, 0x140C0AF90, 0x140C0AC80, 0x140B516C0, 0x140B516F0, 0x140B51730)   # return a thread id (a u16 holder follows): Scr_ExecThread, Scr_ExecEntThread and its wrappers
ALLOC_CLASSES = {      # allocation sites whose id is held in a u16 outside the pool code: they take ids below 0x10000 (the low pool)
    0x140C043C5: 'AllocThread of FUN_140C043A0 (thread object, id returned as u16 by Scr_ExecEntThread, held in u16 fields of two game structs)',
    0x140C0458D: 'AllocThread (thread object, id returned as u16 by Scr_ExecThread)',
    0x140C096C6: 'FUN_140C096B0 class array (id stored in the u16 table 0x141BBA600)',
    0x140C096EF: 'FUN_140C096B0 class array (id stored in the u16 table 0x141BBA600)',
    0x140C0900B: 'Scr_GetEntityId (entity object; the dead entity chain BLK0+0x2C links them through P8 +2, u16)',
    0x140C04559: 'FUN_140C04550 struct (type 0x13: a thread may run on a struct, its self is a u16 in the thread object)',
    0x140C059B8: 'FUN_140C05990 struct (type 0x13)',
    0x140C090B0: 'FUN_140C09080 struct (type 0x13)',
    0x140C04523: 'FUN_140C04510 entity object with its class (type 0x12; +2 holds the entity number, a thread may run on it)',
}
CLIENT_ARRAY_CALLS = (0x140C4F64E, 0x140C503EF)    # call Scr_AllocArray, result `mov word [client + 0x9F352], ax`
FREE_FUNCS = {0x140C04650: 'AllocVariable (pop)', 0x140C04910: 'release with children (push)', 0x140C05C50: 'release (push)',
              0x140C05CA0: 'RemoveRefToObject (push in its tail 0x140C05D70..0x140C05D9D)', 0x140C08E70: 'release all structs (push)',
              0x140C09200: 'list initialiser', 0x140C08C30: 'list rebuild (save game loading only)'}


def key_builders_in(ins_list):
    """`shl r,0x10` whose register is a copy of a register that is the source of `imul x, parent, 0x65` (the hash) in the same function."""
    from capstone import x86_const as X
    srcs, out = set(), []
    for ins in ins_list:
        if ins.mnemonic == 'imul' and len(ins.operands) == 3 and ins.operands[2].type == X.X86_OP_IMM and ins.operands[2].imm == 0x65 and ins.operands[1].type == X.X86_OP_REG:
            srcs.add(FULL.get(ins.reg_name(ins.operands[1].reg)))
    if not srcs:
        return out
    for k, ins in enumerate(ins_list):
        if ins.mnemonic == 'shl' and len(ins.operands) == 2 and ins.operands[1].type == X.X86_OP_IMM and ins.operands[1].imm == 0x10 and ins.operands[0].type == X.X86_OP_REG:
            r = FULL.get(ins.reg_name(ins.operands[0].reg))
            ok = r in srcs
            for j in range(k - 1, max(-1, k - 16), -1):
                p = ins_list[j]
                if p.mnemonic == 'mov' and len(p.operands) == 2 and p.operands[0].type == X.X86_OP_REG and p.operands[1].type == X.X86_OP_REG \
                        and FULL.get(p.reg_name(p.operands[0].reg)) == r and FULL.get(p.reg_name(p.operands[1].reg)) in srcs:
                    ok = True
                    break
            after = ' | '.join(i.mnemonic + ' ' + i.op_str for i in ins_list[k + 1:k + 60])
            if ok and ' or ' in ' | ' + after:
                out.append(ins)
    return out


def shr2_bytes(shl):
    """`shr r,2` for the register of `shl r,0x10` (same prefix and ModRM register, C1 /5 ib)."""
    raw = bytes(shl.bytes)
    if raw[-1] != 0x10 or raw[-3] != 0xC1 or (raw[-2] & 0xF8) != 0xE0:
        raise SystemExit('unexpected shl encoding at %X: %s' % (shl.address, raw.hex()))
    return raw[:-2] + bytes([0xE8 | (raw[-2] & 7), 2])


def complete_ranges(img, md, db_file):
    """[(start, instructions)] for every byte of the variable system's address range. The engine database holds functions that swallow code (FUN_140C04573 ends
    at 0x14130598A) and leaves code in no function at all (Scr_AddClassField, 0x140C061F5): the ranges run from one function start to the next, and a decode that
    stops at data or at an invalid byte resumes one byte on."""
    starts = sorted({s for s, e in func_bounds(db_file) if VM_CALLS[0] <= s < VM_CALLS[1]} | {VM_CALLS[0]})
    out = []
    for i, a in enumerate(starts):
        end = starts[i + 1] if i + 1 < len(starts) else VM_CALLS[1]
        ins, pos = [], a
        while pos < end:
            got = [x for x in md.disasm(img.read(pos, min(end - pos, 0x4000)), pos) if x.address < end]
            if not got:
                pos += 1
                continue
            ins += got
            pos = got[-1].address + got[-1].size
        out.append((a, ins))
    return out


def parent_sites(img, md, db_file):
    """-> (key builders [(ins, function)], parent reads [(ins, function)], u16 holders of thread ids [(address, text)], thread call sites scanned)"""
    from capstone import x86_const as X
    import sqlite3
    ins_ranges = complete_ranges(img, md, db_file)
    builders, reads = [], []
    for s, ins_list in ins_ranges:
        builders += [(ins, s) for ins in key_builders_in(ins_list)]
        for k, ins in enumerate(ins_list):
            if ins.mnemonic == 'movzx' and len(ins.operands) == 2 and ins.operands[1].type == X.X86_OP_MEM and ins.operands[1].size == 2 \
                    and ins.operands[1].mem.disp == 0xE and ins.operands[1].mem.index == 0 and ins.operands[1].mem.base not in (X.X86_REG_RSP, X.X86_REG_RBP):
                if any(i.mnemonic == 'imul' and i.op_str.endswith('0x65') for i in ins_list[k + 1:k + 8]):
                    reads.append((ins, s))
    db = sqlite3.connect('file:' + db_file.replace('\\', '/') + '?mode=ro', uri=True)
    sites = [(f, a) for f in THREAD_FUNCS for _, a in db.execute('select src_func, at from calls where dst=?', (f,)).fetchall() if a is not None]
    holders = []
    for f, a in sites:
        taint, k = {'rax'}, 0
        for ins in md.disasm(img.read(a + 5, 100), a + 5):
            k += 1
            if k > 14:
                break
            ops = ins.operands
            if ins.mnemonic == 'mov' and len(ops) == 2 and ops[0].type == X.X86_OP_MEM and ops[1].type == X.X86_OP_REG and ops[0].size == 2 \
                    and FULL.get(ins.reg_name(ops[1].reg)) in taint:
                holders.append((ins.address, ins.mnemonic + ' ' + ins.op_str))
            if ins.mnemonic in ('ret', 'jmp', 'call') or ins.mnemonic.startswith('j'):
                break
            if ins.mnemonic == 'mov' and len(ops) == 2 and ops[0].type == X.X86_OP_REG and ops[1].type == X.X86_OP_REG and ops[0].size >= 4 \
                    and FULL.get(ins.reg_name(ops[1].reg)) in taint:
                taint.add(FULL.get(ins.reg_name(ops[0].reg)))
                continue
            try:
                for r in ins.regs_access()[1]:
                    taint.discard(FULL.get(ins.reg_name(r)))
            except Exception:
                pass
            if not taint:
                break
    builders = list({i.address: (i, f) for i, f in builders}.values())
    reads = list({i.address: (i, f) for i, f in reads}.values())
    return builders, reads, sorted(set(holders)), len(sites)


def parents(args):
    image_file, db_file = ss.image_path()
    img, md = ss.Image(image_file), ss.cs()
    builders, reads, holders, scanned = parent_sites(img, md, db_file)
    builders.sort(key=lambda x: x[0].address)
    print('key builders (shl r,0x10 of a copy of the parent id, next to the hash imul 0x65): %d in %d functions' % (len(builders), len({s for _, s in builders})))
    for ins, s in builders:
        print('  %X  %-14s %s %s  (function %X)' % (ins.address, ins.bytes.hex(), ins.mnemonic, ins.op_str, s))
    print('parent id read back from a child entry (+0xE, then the hash again): %d' % len(reads))
    for ins, s in reads:
        print('  %X  %-14s %s %s  (function %X)' % (ins.address, ins.bytes.hex(), ins.mnemonic, ins.op_str, s))
    print('free list code (ids pushed and popped as u16 links, rewritten in the component):')
    for a, why in sorted(FREE_FUNCS.items()):
        print('  %X  %s' % (a, why))
    print('allocation sites whose id is held in a u16 outside the pool code (they take ids below 0x10000):')
    for a, why in sorted(ALLOC_CLASSES.items()):
        print('  %X  [%s]  %s' % (a, img.read(a, 5).hex(), why))
    for a in CLIENT_ARRAY_CALLS:
        print('  %X  [%s]  call Scr_AllocArray, result stored in a u16 of the server client struct (+0x9F352)' % (a, img.read(a, 5).hex()))
    print('word stores of a thread id found after %d call sites of Scr_ExecThread / Scr_ExecEntThread and wrappers:' % scanned)
    for a, t in holders:
        print('  %X  %s' % (a, t))
    if args.o:
        reqs = [dict(address='0x%X' % ins.address, kind='bytes', new_bytes=(shr2_bytes(ins) + bytes(ins.bytes)).hex(),
                     note='key builder in %X: shr r,2 before shl r,0x10 (the key holds the LOCAL parent index, id >> 2)' % s) for ins, s in builders]
        # a cave window copies the stock bytes of its neighbours: an edit of the previous stage (segment base pair) inside a window moves into the cave
        sites = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'variable-sites.json')))
        by_at = {r['at']: r for r in sites['pairs']}
        for ins, s in builders:
            covered, k = 0, ins.address
            while covered < 5:
                nxt = next(md.disasm(img.read(k, 16), k))
                covered += nxt.size
                if k != ins.address and k in by_at:
                    r = by_at[k]
                    after = bytes.fromhex(r['after']) if r['op'] == 'seg_lea' else bytes(nxt.bytes)[:-1] + bytes([r['after']])
                    reqs.append(dict(address='0x%X' % k, kind='bytes', new_bytes=after.hex(), note='segment base edit of the previous stage, inside the window of the key builder at %X' % ins.address))
                k += nxt.size
        for ins, s in reads:
            # movzx ecx,word [rbx+0xE] ; mov edx,esi ; shr edx,0x10 ; lea ecx,[rdx+rcx*4]: id = 4 * local + segment, the segment is the base (seg << 16) in esi
            reqs.append(dict(address='0x%X' % ins.address, kind='bytes', new_bytes=bytes(ins.bytes).hex() + '89f2c1ea108d0c8a',
                             note='FUN_140C05280: the parent id of a child entry is 4 * local + segment (segment = base >> 16, the base is in esi)'))
        json.dump(reqs, open(args.o, 'w'), indent=1)
        print('wrote', len(reqs), 'cave requests to', args.o)
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('find'); p.add_argument('-o', required=True); p.set_defaults(fn=find)
    p = sub.add_parser('check'); p.add_argument('file'); p.set_defaults(fn=check)
    p = sub.add_parser('emit'); p.add_argument('file'); p.add_argument('-o', required=True); p.set_defaults(fn=emit)
    p = sub.add_parser('parents'); p.add_argument('-o', default=None); p.set_defaults(fn=parents)
    args = ap.parse_args()
    sys.exit(args.fn(args) or 0)


if __name__ == '__main__':
    main()
