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
import collections
import json
import os
import re
import sqlite3
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import state_sites as ss  # noqa: E402

BASE = ss.BASE
CH_RVA = 0x6756180      # image relative address of the stock child table
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
VM_CALLS = (0x140BFE000, 0x140C11090)   # the variable system API (to the end of FUN_140C10E60, 0x140C11087; a64: the range ended inside that function): calls in here pass a segment base or an id
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


# ------------------------------------------------------------------------------------------------ hash buckets (a62)
# The child hash table (HASH, 4 segments x 2^B u16 heads; stock B = 14, 0x20000 bytes) never grew with the children (a60: load factor 2.7 at 200 alive,
# 3.3 at 280). `buckets` finds every site that depends on B and prints the data flow evidence of each one; with -o it writes variable-buckets.json
# (`emit-buckets` turns it into script_variables_buckets.inc). Sites:
#   mask   `and r,0x3FFF` whose operand holds `parent * 0x65 + name` (imul by 0x65 reaches it) -> (1 << B) - 1
#   shl    `shl r,0xE` of `parent & 3` (the segment) that is added to a mask result and indexes the table -> B
#   ref    a rip, image relative or register relative field that names the table (the six stage 1 rows `[P8 + 0xA5000]` and the new ones) -> follows the table
#   half   `add rax,0x52800` (distance P8 -> HASH in units of 2 bytes; the stage 1 `hash_half` rows)
#   clear  `mov r8d,0x20000` after `lea rcx,[rip + HASH]` (the initialiser's memset) -> 8 << B
BUCKET_STOCK_BITS = 14
HASH_BASE, HASH_BYTES = REGIONS['HASH']
TABLES_FOR_DISTANCE = ('A', 'B', 'P8', 'P4', 'CH', 'BLOCK0', 'IMG')
LABEL_CLASSES = ('imul', 'mov', 'movzx', 'movsx', 'movsxd', 'add', 'sub', 'or', 'lea', 'and', 'shl', 'shr', 'sar', 'inc', 'dec', 'xor', 'neg', 'not',
                 'cmovne', 'cmove', 'cmovb', 'cmova')


def _regs_rw(ins):
    try:
        r, w = ins.regs_access()
    except Exception:
        return [], []
    return [FULL[ins.reg_name(x)] for x in r if ins.reg_name(x) in FULL], [FULL[ins.reg_name(x)] for x in w if ins.reg_name(x) in FULL]


def bucket_flow(ins_list, mask_at, shl_at):
    """Linear forward label propagation over one function: labels ('H', imul address) from `imul x,y,0x65`, ('G', address) from `and r,3`, ('M', address) at every
    `and r,0x3FFF` whose operand carries an H label, ('S', address) at every `shl r,0xE` whose operand carries a G label. A load clears the destination, except from a
    stack slot `[rsp + d]` (no index): the loop of FUN_140C04D80 spills the multiply and the shifted segment and reads them back, so a slot keeps the labels of what was stored.
    -> ({site address: [consumers]}, {site address: provenance of its operand})"""
    from capstone import x86_const as X
    lab = {}
    slots = {}
    out = {}
    trail = {}
    for ins in ins_list:
        rd, wr = _regs_rw(ins)
        mn = ins.mnemonic
        mem = next((o for o in ins.operands if o.type == X.X86_OP_MEM), None)
        # a consumer: a memory operand whose index register holds an M label and an S label, scale 2
        if mem is not None and mem.mem.index != 0 and mem.mem.scale == 2:
            idx = FULL.get(ins.reg_name(mem.mem.index))
            ls = lab.get(idx, set())
            ms = [a for k, a in ls if k == 'M']
            ss_ = [a for k, a in ls if k == 'S']
            if ms and ss_:
                for a in ms + ss_:
                    out.setdefault(a, []).append(dict(consumer=ins.address, text=ins.mnemonic + ' ' + ins.op_str, with_m=ms, with_s=ss_))
        imm = ins.operands[1].imm if len(ins.operands) == 2 and ins.operands[1].type == X.X86_OP_IMM else None
        new = set()
        for r in rd:
            new |= lab.get(r, set())
        slot = mem.mem.disp if mem is not None and mem.mem.base == X.X86_REG_RSP and mem.mem.index == 0 else None
        if slot is not None and mn == 'mov' and ins.operands[0].type == X.X86_OP_MEM and ins.operands[1].type == X.X86_OP_REG:
            src = FULL.get(ins.reg_name(ins.operands[1].reg))
            if lab.get(src):
                slots[slot] = set(lab[src])
            else:
                slots.pop(slot, None)
            continue
        if slot is not None and mn not in ('lea',) and ins.operands[0].type != X.X86_OP_MEM:
            new = new | slots.get(slot, set())
        is_load = mem is not None and mn in ('mov', 'movzx', 'movsx', 'movsxd') and ins.operands[0].type == X.X86_OP_REG and slot is None
        if mn == 'imul' and len(ins.operands) == 3 and ins.operands[2].type == X.X86_OP_IMM and ins.operands[2].imm == 0x65:
            new = {('H', ins.address)}
        elif mn == 'and' and imm == 3 and ins.operands[0].type == X.X86_OP_REG:
            new = {('G', ins.address)}
        elif mn == 'and' and imm == 0x3FFF and ins.operands[0].type == X.X86_OP_REG:
            r0 = FULL.get(ins.reg_name(ins.operands[0].reg))
            have_h = any(k == 'H' for k, _ in lab.get(r0, set()))
            if ins.address in mask_at:
                trail[ins.address] = dict(h=sorted(a for k, a in lab.get(r0, set()) if k == 'H'), ok=have_h)
            new = {('M', ins.address)} if have_h else set()
        elif mn == 'shl' and imm == 0xE and ins.operands[0].type == X.X86_OP_REG:
            r0 = FULL.get(ins.reg_name(ins.operands[0].reg))
            have_g = any(k == 'G' for k, _ in lab.get(r0, set()))
            if ins.address in shl_at:
                trail[ins.address] = dict(g=sorted(a for k, a in lab.get(r0, set()) if k == 'G'), ok=have_g)
            new = {('S', ins.address)} if have_g else set()
        elif is_load or (mn == 'xor' and len(ins.operands) == 2 and ins.operands[0].type == X.X86_OP_REG and ins.operands[1].type == X.X86_OP_REG
                         and ins.operands[0].reg == ins.operands[1].reg):
            new = set()
        elif mn == 'call':
            for r in ('rax', 'rcx', 'rdx', 'r8', 'r9', 'r10', 'r11'):
                lab.pop(r, None)
            continue
        elif mn not in LABEL_CLASSES:
            new = set()
        for w in wr:
            if w == 'rsp':
                continue
            if new:
                lab[w] = set(new)
            else:
                lab.pop(w, None)
    return out, trail


def il_slice(il, k, back):
    return il[max(0, k - back):k]


def buckets(args):
    from capstone import x86_const as X
    global MOVED
    MOVED = ('A', 'B', 'P8', 'P4', 'CH', 'HASH')
    image_file, db_file = ss.image_path()
    img, md = ss.Image(image_file), ss.cs()
    here = os.path.dirname(os.path.abspath(__file__))
    stage1 = json.load(open(os.path.join(here, 'variable-sites.json')))
    stage1_refs = {r['field']: r for r in stage1['refs'] if r['region'] == 'HASH'}
    stage1_half = {r['field']: r for r in stage1['imms'] if r['op'] == 'hash_half'}
    ranges = complete_ranges(img, md, db_file)
    problems = []
    masks, shls, clears = [], [], []
    by_func = {}
    for s, il in ranges:
        for k, ins in enumerate(il):
            imm = ins.operands[1].imm if len(ins.operands) == 2 and ins.operands[1].type == X.X86_OP_IMM else None
            if ins.mnemonic == 'and' and imm == 0x3FFF and ins.operands[0].type == X.X86_OP_REG:
                masks.append((ins, s))
            elif ins.mnemonic == 'shl' and imm == 0xE and ins.operands[0].type == X.X86_OP_REG:
                shls.append((ins, s))
            elif imm == 0x20000:
                clears.append((ins, s, k))
        by_func[s] = il
    print('variable system range %X..%X decoded byte by byte: %d instructions in %d pieces' % (VM_CALLS[0], VM_CALLS[1], sum(len(il) for _, il in ranges), len(ranges)))
    mask_at, shl_at = {i.address for i, _ in masks}, {i.address for i, _ in shls}
    consumers, trails = {}, {}
    for s, il in ranges:
        c, t = bucket_flow(il, mask_at, shl_at)
        for a, lst in c.items():
            consumers.setdefault(a, []).extend(lst)
        trails.update(t)
    print('\nmask sites (and r,0x3FFF): %d' % len(masks))
    mask_rows = []
    for ins, s in masks:
        t, c = trails.get(ins.address, {}), consumers.get(ins.address, [])
        ok = bool(t.get('ok')) and bool(c)
        field = ins.address + ins.encoding.imm_offset
        print('  %X  %-16s %-22s function %X  imul 0x65 at %s  index %s' % (
            ins.address, ins.bytes.hex(), ins.mnemonic + ' ' + ins.op_str, s, ','.join('%X' % a for a in t.get('h', [])) or '-',
            ('%X %s (with shl at %s)' % (c[0]['consumer'], c[0]['text'], ','.join('%X' % a for a in c[0]['with_s']))) if c else 'NOT REACHED'))
        if not ok:
            problems.append('mask %X not proven on the bucket path' % ins.address)
        mask_rows.append(dict(at=ins.address, field=field, func=s, text=ins.mnemonic + ' ' + ins.op_str, bytes=ins.bytes.hex(),
                              imul=t.get('h', []), consumer=c[0]['consumer'] if c else 0, consumer_text=c[0]['text'] if c else ''))
    print('\nsegment shift sites (shl r,0xE): %d' % len(shls))
    shl_rows = []
    for ins, s in shls:
        t, c = trails.get(ins.address, {}), consumers.get(ins.address, [])
        ok = bool(t.get('ok')) and bool(c)
        field = ins.address + ins.encoding.imm_offset
        print('  %X  %-16s %-22s function %X  segment (and r,3) at %s  index %s' % (
            ins.address, ins.bytes.hex(), ins.mnemonic + ' ' + ins.op_str, s, ','.join('%X' % a for a in t.get('g', [])) or '-',
            ('%X %s (with mask at %s)' % (c[0]['consumer'], c[0]['text'], ','.join('%X' % a for a in c[0]['with_m']))) if c else 'NOT REACHED'))
        if not ok:
            problems.append('shl %X not proven on the bucket path' % ins.address)
        shl_rows.append(dict(at=ins.address, field=field, func=s, text=ins.mnemonic + ' ' + ins.op_str, bytes=ins.bytes.hex(),
                             segment=t.get('g', []), consumer=c[0]['consumer'] if c else 0, consumer_text=c[0]['text'] if c else ''))
    # the clear: every 0x20000 immediate of the range; the one after `lea r,[rip + HASH]` is the table's memset
    print('\n0x20000 immediates in the range: %d' % len(clears))
    clear_rows = []
    for ins, s, k in clears:
        near = [i for i in il_slice(by_func[s], k, 6) if i.mnemonic == 'lea' and i.operands[1].mem.base == X.X86_REG_RIP
                and HASH_BASE <= i.address + i.size + i.operands[1].mem.disp < HASH_BASE + HASH_BYTES]
        txt = ins.mnemonic + ' ' + ins.op_str
        if near:
            print('  %X  %-18s %-24s function %X  the table memset: lea at %X names HASH' % (ins.address, ins.bytes.hex(), txt, s, near[0].address))
            clear_rows.append(dict(at=ins.address, field=ins.address + ins.encoding.imm_offset, func=s, text=txt, bytes=ins.bytes.hex(), lea=near[0].address))
        else:
            print('  %X  %-18s %-24s function %X  not the table: no reference to HASH in the 6 instructions before it' % (ins.address, ins.bytes.hex(), txt, s))
    if len(clear_rows) != 1:
        problems.append('expected exactly one table clear, found %d' % len(clear_rows))
    # every reference to the table: the walker with HASH among the moved tables, on the whole range and on every candidate function outside it
    SCALED_DISTANCES.update({v: w for v, w in scaled_distances().items()})
    walker = Walker(img, md)
    rows, unresolved, halves = {}, [], {}

    def walk_piece(start, ins_list):
        res = walker.walk(ins_list, '')
        for r in res['rows']:
            if r['region'] == 'HASH':
                r['func'] = start
                rows.setdefault(r['field'], r)
        for u in res['unresolved']:
            u['func'] = start
            unresolved.append(u)
        for r in imm_rows(ins_list, res, md, True):
            if r['op'] == 'hash_half':
                r['func'] = start
                halves[r['field']] = r
    for s, il in ranges:
        walk_piece(s, il)
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
    outside = set()
    for fn, items in candidates(None).items():
        for at, why in items:
            f = func_of(at)
            if not (VM_CALLS[0] <= f[0] < VM_CALLS[1]):
                outside.add(f)
    for s, e in sorted(outside):
        il = walker.decode_range(s, e)
        if il:
            walk_piece(s, il)
    print('\ncandidate functions outside the variable system walked: %d' % len(outside))
    real = {f: r for f, r in rows.items() if r['target'] - HASH_BASE <= 0x1F}
    junk = {f: r for f, r in rows.items() if f not in real}
    print('references to the table: %d (stage 1 rows: %d, new: %d); rejected as a constant that only looks like an address (deeper than the first entry): %d' % (
        len(real), len([f for f in real if f in stage1_refs]), len([f for f in real if f not in stage1_refs]), len(junk)))
    for f, r in sorted(real.items()):
        inside = VM_CALLS[0] <= r['func'] < VM_CALLS[1]
        print('  %X  field %X  %-5s %-48s function %X%s%s' % (r['at'], f, r['form'], r['text'], r['func'], '' if inside else '  OUTSIDE THE VARIABLE SYSTEM', '  [stage 1 row]' if f in stage1_refs else ''))
        if not inside:
            problems.append('reference to the table outside the variable system at %X' % r['at'])
    for f, r in sorted(junk.items()):
        print('  rejected %X  %s  (target %X is %#x into the table)' % (r['at'], r['text'], r['target'], r['target'] - HASH_BASE))
        if VM_CALLS[0] <= r['func'] < VM_CALLS[1]:
            problems.append('rejected reference inside the variable system at %X' % r['at'])
    for f in stage1_refs:
        if f not in real:
            problems.append('stage 1 hash row %X not found again' % f)
    for u in unresolved:
        print('  UNRESOLVED %X %s: %s' % (u['at'], u['text'], u['why']))
        problems.append('unresolved reference at %X' % u['at'])
    print('\nhash_half (add rax,imm = (HASH - P8) / 2): %d' % len(halves))
    for f, r in sorted(halves.items()):
        print('  %X  field %X  stage 1 row: %s' % (r['at'], f, f in stage1_half))
    if set(halves) != set(stage1_half):
        problems.append('hash_half rows differ from stage 1')
    # distances from every other table to the hash table, plain and folded by 2, 4, 8, 16: any instruction of the range that holds one and that no row classifies
    known = set(real) | set(halves) | {m['field'] for m in mask_rows} | {m['field'] for m in shl_rows} | {c['field'] for c in clear_rows}
    # a stage 1 row (reference, constant, segment base pair) already classifies the field: the stock tables are laid out so that the distance from A to HASH / 2 is also the
    # size of P8, and so on; such a constant is the other table's own and its stage 1 row is checked by `check`
    for kind in ('refs', 'imms'):
        known |= {r['field'] for r in stage1[kind]}
    known |= {r['field'] for r in stage1['pairs'] if 'field' in r}
    folded = {}
    for t in TABLES_FOR_DISTANCE:
        d = HASH_BASE - REGIONS[t][0]
        for k in (1, 2, 4, 8, 16):
            if d % k == 0 and d // k >= 0x1000:
                for ext in range(0, 0x20, 2):
                    folded.setdefault(d // k + ext // k, '%s -> HASH / %d (+%#x)' % (t, k, ext))
    hits = []
    for s, il in ranges:
        for ins in il:
            for kind, field, value, tail, m in ss.fields(ins, md):
                v = value & 0xFFFFFFFF
                if v in folded and field not in known and kind in ('imm', 'disp'):
                    hits.append((ins, field, v, folded[v]))
    print('\nconstants of the range equal to a table distance to HASH (plain or folded by 2, 4, 8, 16) that no row classifies: %d' % len(hits))
    for ins, field, v, why in hits:
        print('  %X  %-28s %#x  %s' % (ins.address, ins.mnemonic + ' ' + ins.op_str, v, why))
        problems.append('unclassified distance constant at %X' % ins.address)
    # the same instructions elsewhere in the image: not in any function that names the table
    c = sqlite3.connect('file:' + index_path().replace('\\', '/') + '?mode=ro', uri=True)
    idx_masks = [(a, f) for a, f in c.execute("select at,func from insn where kind='imm' and value=16383 and text like 'and %'").fetchall() if not VM_CALLS[0] <= a < VM_CALLS[1]]
    idx_shl = [(a, f) for a, f in c.execute("select at,func from insn where kind='imm' and value=14 and text like 'shl %'").fetchall() if not VM_CALLS[0] <= a < VM_CALLS[1]]
    related_outside = {f for f in {r['func'] for r in rows.values()} if not VM_CALLS[0] <= f < VM_CALLS[1]}
    print('\n`and r,0x3FFF` outside the variable system: %d, `shl r,0xE`: %d; those in a function that names HASH (none expected): %d' % (
        len(idx_masks), len(idx_shl), len([1 for a, f in idx_masks + idx_shl if f in related_outside])))
    if any(f in related_outside for a, f in idx_masks + idx_shl):
        problems.append('a mask or shift outside the variable system sits in a function that names the table')
    # windows (code replaced by a jump) that cover a field
    caves = open(os.path.join(here, '..', '..', 'src', 'native', 'script_variables_caves.inc'), encoding='utf-8').read()
    windows = []
    for m in re.finditer(r'\{0x([0-9a-f]+)ull, \{([^}]*)\}', caves):
        windows.append((int(m.group(1), 16), len([x for x in m.group(2).split(',') if x.strip()])))
    entries = [0x140C04650, 0x140C04910, 0x140C05C50, 0x140C08E70, 0x140C09200, 0x140C08C30, 0x140C043A0, 0x140C04580, 0x140C05100]
    windows += [(a, 5) for a in entries] + [(0x140C05D70, 45)]
    fields_all = ([(f, 4, 'ref') for f in real] + [(f, 4, 'half') for f in halves] + [(m['field'], 4, 'mask') for m in mask_rows]
                  + [(m['field'], 1, 'shl') for m in shl_rows] + [(c['field'], 4, 'clear') for c in clear_rows])
    over = [(f, w, what) for f, n, what in fields_all for w, ln in windows if f < w + ln and f + n > w]
    print('\nfields inside a window that is replaced by a jump (a cave, an entry stub): %d' % len(over))
    for f, w, what in over:
        print('  %s field %X in the window at %X' % (what, f, w))
        problems.append('%s field %X lies in a replaced window at %X' % (what, f, w))
    print('\nsummary: %d masks, %d shifts, %d references (%d new), %d hash_half, %d clear; problems: %d' % (
        len(masks), len(shls), len(real), len([f for f in real if f not in stage1_refs]), len(halves), len(clear_rows), len(problems)))
    for p in problems:
        print('  PROBLEM:', p)
    if args.o and not problems:
        data = dict(schema='iw7.variable-buckets/1', stock_bits=BUCKET_STOCK_BITS, stock_hash=[hex(HASH_BASE), hex(HASH_BYTES)], masks=mask_rows, shls=shl_rows, clear=clear_rows,
                    refs=[dict(at=r['at'], field=f, op='ref', form=r['form'], base=r['base'], target=r['target'], tail=r['tail'], text=r['text'], bytes=r['bytes'], func=r['func'],
                               stage1=f in stage1_refs) for f, r in sorted(real.items())],
                    hash_half=[dict(at=r['at'], field=f) for f, r in sorted(halves.items())],
                    rejected=[dict(at=r['at'], text=r['text'], target=r['target']) for r in junk.values()])
        json.dump(data, open(args.o, 'w'), indent=1)
        print('wrote', args.o)
    return 1 if problems else 0


def emit_buckets(args):
    data = json.load(open(args.file))
    lines = ['// Generated by ops/engine/variable_sites.py emit-buckets from variable-buckets.json; do not edit.',
             '// BUCKET_REFS: the references to the hash table that stage 1 did not list ({field, form (0 disp, 1 rip), base, target, tail}); the six `[P8 + 0xA5000]` rows are in script_variables_sites.inc',
             '// BUCKET_MASKS: imm32 of `and r,0x3FFF` -> (1 << bits) - 1; BUCKET_SHLS: imm8 of `shl r,0xE` -> bits; BUCKET_CLEAR: imm32 of the table memset -> 8 << bits']
    refs = ['{0x%Xull, %d, 0x%Xull, 0x%Xull, %d},' % (r['field'], 1 if r['form'] == 'rip' else 0, r['base'], r['target'], r['tail']) for r in data['refs'] if not r['stage1']]
    masks = ['{0x%Xull},' % m['field'] for m in sorted(data['masks'], key=lambda m: m['field'])]
    shls = ['{0x%Xull},' % m['field'] for m in sorted(data['shls'], key=lambda m: m['field'])]
    clear = ['{0x%Xull},' % m['field'] for m in data['clear']]
    with open(args.o, 'w', newline='\n') as out:
        out.write('\n'.join(lines) + '\n')
        for name, body in (('REFS', refs), ('MASKS', masks), ('SHLS', shls), ('CLEAR', clear)):
            out.write('#ifdef SCRIPT_VARIABLES_BUCKET_%s\n' % name + '\n'.join(body) + '\n#endif\n')
    print('wrote', len(refs), 'refs', len(masks), 'masks', len(shls), 'shifts', len(clear), 'clear to', args.o)



# ------------------------------------------------------------------------------------------------ child capacity census (a64)
# `segments` and `links` count what a larger child capacity touches in the shipped image, from every byte of the variable system's range (complete_ranges),
# the stage 1 rows (variable-sites.json) and the engine database's call table. Nothing is edited: the output is the work estimate and the list of sites.
#   segments  Option C: more than 4 child segments (segment = parent id & 7, ids 8 x local + segment). Every `and r,3` of a segment, the segment base pairs, the hash
#             shift, the counters, the id <-> local index conversions, the C++ of the component that names 4.
#   links     Option D: wider child links (the u16 local child index of the fields +8 hash next, +0x10 / +0x12 siblings, the free list, first / last child, the bucket
#             heads), so that one segment can exceed 65,535 entries; and the holders of a child index outside the variable system.
SEGMENT_INIT_FUNCS = (0x140C08C30, 0x140C09200, 0x140C09280)    # list rebuild, parent list initialiser, child list initialiser: loops over 4 segments
HOLDER_CALLEES = {      # what the callees with a 16-bit use of their result return (read from their code, a64)
    0x140C0ACD0: 'Scr_ExecThread: thread id (a56 list)', 0x140C068B0: 'Scr_AllocArray: client array id (a56 list, +0x9F352)',
    0x140C09050: 'Scr_GetEntityIdRef: entity number and class read from P8 +2 / +4, not a variable id',
    0x140C0B710: 'script parameter getter of an entity number (type checked)',
    0x140C0B060: 'script parameter getter of an asset handle (u16 asset index in bits 16..31; the callers keep it in u16 fields of the player struct +0x1B38..)',
    0x140C0B950: 'Scr_GetInt: an integer parameter',
    0x140BFE7B0: 'class struct getter: u16 table of struct ids, allocates through FUN_140C04550 (the low pool site 0x140C04559), stored in client+0x9F352',
    0x140C0A750: 'false positive: a tail jump of GScr_getmissileowner, the bytes after the call belong to another function',
}
CHILD_API = {0x140C05080: 'first child of a parent (P4 +0, u16)', 0x140C050E0: 'child field read (u16)', 0x140C04FE0: 'FindVariable family', 0x140C05070: 'FindVariable family', 0x140C05090: 'FindVariable family', 0x140C050B0: 'FindVariable family',
             0x140C05100: 'FindVariable', 0x140C05A70: 'GetVariable family', 0x140C05B80: 'GetVariable family', 0x140C05660: 'GetNewVariable'}


def segment_uses(il, k, maxn=40):
    """What the segment value of `and r,3` at il[k] is used for (forward taint through register copies): segbase5 (`lea d,[r+r*4]`, the segment base pair),
    shlN (the hash shift), index*S (a table indexed by the segment), other mnemonics."""
    from capstone import x86_const as X
    taint = {FULL[il[k].reg_name(il[k].operands[0].reg)]}
    out = []
    for j in range(k + 1, min(len(il), k + 1 + maxn)):
        ins = il[j]
        mn = ins.mnemonic
        rd, wr = _regs_rw(ins)
        hit = [x for x in rd if x in taint]
        if hit:
            mem = next((o for o in ins.operands if o.type == X.X86_OP_MEM), None)
            if mn == 'lea' and mem is not None and mem.mem.base == mem.mem.index and mem.mem.scale == 4 and mem.mem.disp == 0:
                out.append('segbase5')
            elif mn == 'shl' and ins.operands[1].type == X.X86_OP_IMM:
                out.append('shl%d' % ins.operands[1].imm)
            elif mem is not None and mem.mem.index != 0 and FULL.get(ins.reg_name(mem.mem.index)) in taint:
                out.append('index*%d' % mem.mem.scale)
            elif mn == 'mov' and ins.operands[0].type == X.X86_OP_REG and ins.operands[1].type == X.X86_OP_REG:
                taint.add(FULL[ins.reg_name(ins.operands[0].reg)])
                continue
            elif mn in ('movzx', 'movsxd', 'movsx'):
                taint.add(FULL[ins.reg_name(ins.operands[0].reg)])
                continue
            else:
                out.append(mn)
        for w in wr:
            if w in taint and not (hit and mn == 'mov'):
                taint.discard(w)
        if mn == 'call':
            for r in ('rax', 'rcx', 'rdx', 'r8', 'r9', 'r10', 'r11'):
                taint.discard(r)
        if not taint:
            break
    return out


def segment_origin(il, k, reg, depth=60):
    """The writer of `reg` before il[k]: 'and3', or what else it is (a segment that does not come from `and r,3`)."""
    from capstone import x86_const as X
    r = reg
    for j in range(k - 1, max(-1, k - depth), -1):
        ins = il[j]
        rd, wr = _regs_rw(ins)
        if r in wr:
            if ins.mnemonic == 'and' and ins.operands[-1].type == X.X86_OP_IMM:
                return 'and%d' % ins.operands[-1].imm, ins.address
            if ins.mnemonic in ('mov', 'movzx') and ins.operands[1].type == X.X86_OP_REG:
                r = FULL[ins.reg_name(ins.operands[1].reg)]
                continue
            return ins.mnemonic, ins.address
        if ins.mnemonic == 'call' and r in ('rax', 'rcx', 'rdx', 'r8', 'r9', 'r10', 'r11'):
            return 'call', ins.address
    return 'live-in', 0


def counter_refs(img, md, db_file):
    """Instructions that name the counters (BLOCK0 + 0x34..0x43) and the scalars behind them (BLOCK0 + 0x44..0x53, where counters 4..7 would sit), by the
    stage 1 walker with BLOCK0 as the tracked table, over the whole variable system and every function the instruction index lists for BLOCK0."""
    global MOVED
    import bisect
    keep, MOVED = MOVED, ('BLOCK0',)
    try:
        bounds = func_bounds(db_file)
        starts = [b[0] for b in bounds]

        def func_of(at):
            i = bisect.bisect_right(starts, at) - 1
            if i >= 0 and bounds[i][0] <= at < bounds[i][1]:
                return bounds[i]
            return (bounds[i][1] if i >= 0 else at, bounds[i + 1][0] if i + 1 < len(bounds) else at + 0x400)

        c = sqlite3.connect('file:' + index_path().replace('\\', '/') + '?mode=ro', uri=True)
        b0 = REGIONS['BLOCK0'][0]
        rows = c.execute("select at from insn where kind='addr' and value>=? and value<?", (b0, b0 + 0x80)).fetchall()
        rows += c.execute("select at from insn where kind='disp' and value>=? and value<?", (b0 - BASE, b0 + 0x80 - BASE)).fetchall()
        # a67: the variable system's range is decoded byte by byte (complete_ranges: the database's functions swallow code and leave gaps; a45's count of the
        # counters and the scalars behind them missed 0x140C0A1C0 because it followed the database's bounds); only the functions outside the range come from the database
        funcs = {func_of(a) for (a,) in rows if not VM_CALLS[0] <= a < VM_CALLS[1]}
        w = Walker(img, md)
        found = {}
        pieces = [(s, il) for s, il in complete_ranges(img, md, db_file) if il] + [(s, il) for s, e in sorted(funcs) for il in [w.decode_range(s, e)] if il]
        for s, il in pieces:
            for r in w.walk(il, '')['rows']:
                if r['region'] == 'BLOCK0':
                    found[(r['field'], r['target'] - b0)] = dict(at=r['at'], func=s, text=r['text'], form=r['form'], base=r['base'], target=r['target'], tail=r['tail'],
                                                                 bytes=r['bytes'])
    finally:
        MOVED = keep
    return found


def segments(args):
    """Option C census: every site that names the number of child segments (4) or the id <-> (segment, local) conversion."""
    from capstone import x86_const as X
    image_file, db_file = ss.image_path()
    img, md = ss.Image(image_file), ss.cs()
    here = os.path.dirname(os.path.abspath(__file__))
    sites = json.load(open(os.path.join(here, 'variable-sites.json')))
    ranges = complete_ranges(img, md, db_file)
    print('variable system range %X..%X decoded byte by byte: %d instructions in %d pieces' % (VM_CALLS[0], VM_CALLS[1], sum(len(il) for _, il in ranges), len(ranges)))
    kinds, in_vm = collections.Counter(), []
    for s, il in ranges:
        for k, ins in enumerate(il):
            if ins.mnemonic == 'and' and len(ins.operands) == 2 and ins.operands[1].type == X.X86_OP_IMM and ins.operands[1].imm == 3 and ins.operands[0].type == X.X86_OP_REG:
                u = segment_uses(il, k)
                kind = 'segment base pair' if 'segbase5' in u else 'hash shift only' if any(x.startswith('shl') for x in u) else 'list head index' if any(x.startswith('index') for x in u) else 'other'
                kinds[kind] += 1
                in_vm.append(dict(at=ins.address, field=ins.address + ins.encoding.imm_offset, func=s, kind=kind, uses=u, bytes=ins.bytes.hex()))
    print('\n`and r,3` in the variable system: %d  %s' % (len(in_vm), dict(kinds)))
    for r in in_vm:
        if r['kind'] != 'segment base pair':
            print('  %X  f%X  %-18s %s' % (r['at'], r['func'], r['kind'], ' '.join(r['uses'])))
    bounds = dict(func_bounds(db_file))
    pairs = [p for p in sites['pairs'] if p['op'] == 'seg_lea']
    outside = [p for p in pairs if not (VM_CALLS[0] <= p['func'] < VM_CALLS[1])]
    origins, out_and, in_origins, odd = collections.Counter(), {}, collections.Counter(), []
    pieces = [(l[0].address, l[-1].address, l) for _, l in ranges if l]
    for p in pairs:
        if VM_CALLS[0] <= p['func'] < VM_CALLS[1]:
            il = next((l for lo_, hi_, l in pieces if lo_ <= p['at'] <= hi_), None)
        else:
            f = p['func']
            il = list(md.disasm(img.read(f, bounds.get(f, f + 0x800) - f), f))
        k = next((i for i, x in enumerate(il or []) if x.address == p['at']), None)
        inside = VM_CALLS[0] <= p['func'] < VM_CALLS[1]
        if k is None:
            (in_origins if inside else origins)['pair not found'] += 1
            continue
        src = FULL[il[k].reg_name(il[k].operands[1].mem.base)]
        o, at = segment_origin(il, k, src)
        (in_origins if inside else origins)[o] += 1
        if o == 'and3' and not inside:
            ins = next(x for x in il if x.address == at)
            out_and[at] = dict(at=at, field=at + ins.encoding.imm_offset, func=p['func'])
        elif o != 'and3':
            odd.append((p['at'], p['func'], o, at, il[k].op_str))
    print('\nsegment base pairs `lea r,[s+s*4]; shl r,0x10` (stage 1 rows, no byte change for more segments): %d in %d functions; outside the variable system %d in %d functions'
          % (len(pairs), len({p['func'] for p in pairs}), len(outside), len({p['func'] for p in outside})))
    print('  origin of the segment of the %d pairs inside: %s; of the %d outside: %s; distinct `and r,3` outside: %d' % (len(pairs) - len(outside), dict(in_origins), len(outside), dict(origins), len(out_and)))
    for a, f, o, at, t in odd:
        print('  pair %X (function %X) takes its segment from `%s` at %X: %s (a loop counter over the 4 segments)' % (a, f, o, at, t))
    init_loops = []
    for f in SEGMENT_INIT_FUNCS:
        end = bounds.get(f, f + 0x400)
        for ins in md.disasm(img.read(f, end - f), f):
            if ins.mnemonic == 'cmp' and len(ins.operands) == 2 and ins.operands[1].type == X.X86_OP_IMM and ins.operands[1].imm == 4 and ins.operands[0].type == X.X86_OP_REG:
                init_loops.append((ins.address, f, ins.mnemonic + ' ' + ins.op_str))
    print('\nloops over the 4 segments (`cmp r,4`) in the initialisers and the list rebuild: %d' % len(init_loops))
    for a, f, t in init_loops:
        print('  %X  f%X  %s' % (a, f, t))
    refs = counter_refs(img, md, db_file)
    cn = {k: v for k, v in refs.items() if 0x34 <= k[1] < 0x44}
    behind = {k: v for k, v in refs.items() if 0x44 <= k[1] < 0x54}
    print('\ncounters (children in use a segment, BLOCK0 + 0x34..0x43): %d instructions in %d functions; scalars behind them (BLOCK0 + 0x44..0x53), %d instructions: eight counters do not fit in place' %
          (len(cn), len({v['func'] for v in cn.values()}), len(behind)))
    for k, v in sorted(cn.items(), key=lambda x: x[1]['at']):
        print('  %X  f%X  +0x%X  %s' % (v['at'], v['func'], k[1], v['text']))
    builders, reads, holders, scanned = parent_sites(img, md, db_file)
    print('\nid <-> (segment, local): key builders `shr r,2` before `shl r,0x10`: %d (caves, the shift count 2 -> 3); the read back of a parent id `4 x local + segment`: %d (cave, scale 4 -> 8)' % (len(builders), len(reads)))
    inc = collections.Counter(r['op'] for r in sites['imms'])
    print('constants that follow the table sizes (stage 1 rows, new values only): %s' % dict(inc))
    reg = collections.Counter(r['region'] for r in sites['refs'])
    print('table references that follow the new tables (stage 1 rows, same count): %d  %s' % (len(sites['refs']), dict(reg)))
    root = os.path.abspath(os.path.join(here, '..', '..'))
    pat = re.compile(r'&\s*3u?\b|>>\s*2\b|<<\s*2\b|\[4\]|<\s*4\b|\bsegments\b|% 4|/ 4\b')
    cxx = {}
    for rel in ('src/native/script_parent_pools.hpp', 'src/native/script_variables.cpp', 'src/native/script_variables.hpp', 'src/native/script_var_layout.hpp'):
        path = os.path.join(root, rel.replace('/', os.sep))
        if os.path.exists(path):
            cxx[rel] = [i + 1 for i, line in enumerate(open(path, encoding='utf-8', errors='replace')) if pat.search(line) and not line.lstrip().startswith('//')]
    print('\nthe component C++ that names 4 segments (code lines matching & 3, >> 2, << 2, [4], < 4, segments):')
    for rel, hits in cxx.items():
        print('  %-40s %d lines  %s' % (rel, len(hits), ','.join(map(str, hits[:40]))))
    out = dict(and3_in_vm=in_vm, and3_outside=sorted(out_and.values(), key=lambda r: r['at']), and3_kinds=dict(kinds), pairs=len(pairs), pairs_outside=len(outside),
               origins=dict(origins), in_origins=dict(in_origins), init_loops=[dict(at=a, func=f, text=t) for a, f, t in init_loops], counters=len(cn), counters_functions=len({v['func'] for v in cn.values()}),
               scalars_behind=len(behind), key_builders=len(builders), parent_reads=len(reads), imms=dict(inc), refs=dict(reg), cxx={k: len(v) for k, v in cxx.items()})
    if args.o:
        json.dump(out, open(args.o, 'w'), indent=1)
        print('wrote', args.o)
    return 0


# ------------------------------------------------------------------------------------------------ more than 4 child segments (a67)
# The rows of the segment count (S = 4, 8 or 16 chosen at run time, docs/SCRIPT-VARIABLES.md "Segments"): every `and r,3` that selects a segment
# (imm -> S - 1), the loops over the segments (`cmp r,4` -> S) and the counters of the children in use (moved to a table of S ints of the component).
# `segment-rows` writes variable-segments.json from the census above (it fails when the census does not add up); `emit-segments` writes the .inc.
SEGMENT_MASK_FUNCS_DEAD = ()    # `and r,3` that index the four list heads sit in code the component replaces (AllocVariable's free list functions): not patched


def segment_rows(img, md, db_file):
    from capstone import x86_const as X
    sites = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'variable-sites.json')))
    ranges = complete_ranges(img, md, db_file)
    masks, heads, problems = {}, [], []
    for s, il in ranges:
        for k, ins in enumerate(il):
            if ins.mnemonic == 'and' and len(ins.operands) == 2 and ins.operands[1].type == X.X86_OP_IMM and ins.operands[1].imm == 3 and ins.operands[0].type == X.X86_OP_REG:
                u = segment_uses(il, k)
                kind = 'pair' if 'segbase5' in u else 'hash' if any(x.startswith('shl') for x in u) else 'head' if any(x.startswith('index') for x in u) else 'other'
                if kind == 'other':
                    problems.append('and r,3 at %X is no segment: %s' % (ins.address, ' '.join(u)))
                row = dict(at=ins.address, field=ins.address + ins.encoding.imm_offset, width=ins.encoding.imm_size, func=s, kind=kind, outside=False, bytes=ins.bytes.hex())
                if kind == 'head':
                    heads.append(row)
                else:
                    masks[row['field']] = row
    bounds = dict(func_bounds(db_file))
    pairs = [p for p in sites['pairs'] if p['op'] == 'seg_lea']
    pieces = [(l[0].address, l[-1].address, l) for _, l in ranges if l]
    for p in pairs:
        if VM_CALLS[0] <= p['func'] < VM_CALLS[1]:
            continue
        f = p['func']
        il = list(md.disasm(img.read(f, bounds.get(f, f + 0x800) - f), f))
        k = next((i for i, x in enumerate(il) if x.address == p['at']), None)
        if k is None:
            problems.append('pair %X not found in its function' % p['at'])
            continue
        o, at = segment_origin(il, k, FULL[il[k].reg_name(il[k].operands[1].mem.base)])
        if o != 'and3':
            problems.append('pair %X outside the system takes its segment from %s' % (p['at'], o))
            continue
        ins = next(x for x in il if x.address == at)
        field = at + ins.encoding.imm_offset
        masks[field] = dict(at=at, field=field, width=ins.encoding.imm_size, func=f, kind='outside', outside=True, bytes=ins.bytes.hex())
    loops = []
    for f in SEGMENT_INIT_FUNCS:
        for ins in md.disasm(img.read(f, bounds.get(f, f + 0x400) - f), f):
            if ins.mnemonic == 'cmp' and len(ins.operands) == 2 and ins.operands[1].type == X.X86_OP_IMM and ins.operands[1].imm == 4 and ins.operands[0].type == X.X86_OP_REG:
                loops.append(dict(at=ins.address, field=ins.address + ins.encoding.imm_offset, width=ins.encoding.imm_size, func=f, bytes=ins.bytes.hex()))
    refs = counter_refs(img, md, db_file)
    counters = [dict(at=v['at'], field=r_field, form=v['form'], base=v['base'], target=v['target'], tail=v['tail'], func=v['func'], offset=k[1], text=v['text'])
                for k, v in sorted(refs.items(), key=lambda x: x[1]['at']) for r_field in [k[0]] if 0x34 <= k[1] < 0x44]
    for m in masks.values():
        raw = bytes.fromhex(m['bytes'])
        if m['width'] != 1 or raw[m['field'] - m['at']] != 3:
            problems.append('and r,3 at %X: immediate is not an imm8 of 3 (%s)' % (m['at'], m['bytes']))
    return dict(masks=sorted(masks.values(), key=lambda r: r['field']), heads=heads, loops=loops, counters=counters, problems=problems)


def segment_rows_cmd(args):
    image_file, db_file = ss.image_path()
    img, md = ss.Image(image_file), ss.cs()
    md.detail = True
    d = segment_rows(img, md, db_file)
    kinds = collections.Counter(m['kind'] for m in d['masks'])
    print('and r,3 patched: %d %s (list head indexes in replaced code, not patched: %d); loops cmp r,4: %d; counter instructions: %d in %d functions' %
          (len(d['masks']), dict(kinds), len(d['heads']), len(d['loops']), len(d['counters']), len({c['func'] for c in d['counters']})))
    for p in d['problems']:
        print('  PROBLEM:', p)
    if args.o and not d['problems']:
        json.dump(dict(schema='iw7.variable-segments/1', **d), open(args.o, 'w'), indent=1)
        print('wrote', args.o)
    return 1 if d['problems'] else 0


def emit_segments(args):
    d = json.load(open(args.file))
    lines = ['// Generated by ops/engine/variable_sites.py emit-segments from variable-segments.json; do not edit.',
             '// SEG_MASKS: imm8 of `and r,3` (a segment of a parent id) -> segments - 1; SEG_LOOPS: imm8 of `cmp r,4` (loop over the segments) -> segments;',
             '// SEG_COUNTERS: the instructions that name the counters of the children in use ({field, form (0 disp, 1 rip), base, target, tail}) -> the counter table of the component']
    masks = ['{0x%Xull},' % m['field'] for m in d['masks']]
    loops = ['{0x%Xull},' % m['field'] for m in d['loops']]
    ctr = ['{0x%Xull, %d, 0x%Xull, 0x%Xull, %d},' % (c['field'], 1 if c['form'] == 'rip' else 0, c['base'], c['target'], c['tail']) for c in d['counters']]
    with open(args.o, 'w', newline='\n') as out:
        out.write('\n'.join(lines) + '\n')
        for name, body in (('MASKS', masks), ('LOOPS', loops), ('COUNTERS', ctr)):
            out.write('#ifdef SCRIPT_VARIABLES_SEG_%s\n' % name + '\n'.join(body) + '\n#endif\n')
    print('wrote', len(masks), 'masks', len(loops), 'loops', len(ctr), 'counter references to', args.o)


def links(args):
    """Option D census: the u16 child links of the variable system and the holders of a child index outside it."""
    from capstone import x86_const as X
    image_file, db_file = ss.image_path()
    img, md = ss.Image(image_file), ss.cs()
    here = os.path.dirname(os.path.abspath(__file__))
    sites = json.load(open(os.path.join(here, 'variable-sites.json')))
    ranges = complete_ranges(img, md, db_file)
    chf = {r['func'] for r in sites['refs'] if r['region'] == 'CH'}
    pairf = {p['func'] for p in sites['pairs']}
    ch0 = REGIONS['CH'][0]
    P8CH, P8P4, P8HASH = 0xC5000, 0x6E000, 0xA5000
    FIELDS = {0: 'value/free link', 2: 'value/free link', 4: 'value', 6: 'value', 8: 'hash next', 0xA: 'type', 0xC: 'name hi', 0xE: 'parent', 0x10: 'prev sibling', 0x12: 'next sibling'}
    LINK = {'hash next', 'prev sibling', 'next sibling'}
    rows = []
    for s, il in ranges:
        evid = s in chf or s in pairf or any(i.mnemonic == 'lea' and len(i.operands) == 2 and i.operands[1].type == X.X86_OP_MEM and i.operands[1].mem.base != 0
                                              and i.operands[1].mem.base == i.operands[1].mem.index and i.operands[1].mem.scale == 2 and i.operands[1].mem.disp == 0 for i in il)
        for ins in il:
            mem = next((o for o in ins.operands if o.type == X.X86_OP_MEM), None)
            if mem is None or mem.mem.base in (X.X86_REG_RSP, X.X86_REG_RBP) or ins.mnemonic in ('lea', 'nop'):
                continue
            d = mem.mem.disp & 0xFFFFFFFF
            if mem.mem.base == X.X86_REG_RIP:
                t = (ins.address + ins.size + mem.mem.disp) & 0xFFFFFFFFFFFFFFFF
                rg = region_of(t)
                if rg == 'CH':
                    rows.append((ins.address, s, 'CH', (t - ch0) % 0x18, mem.size, 'rip', ins))
                elif rg in ('P4', 'HASH'):
                    rows.append((ins.address, s, rg, (t - REGIONS[rg][0]) % (4 if rg == 'P4' else 2), mem.size, 'rip', ins))
                continue
            if CH_RVA <= d < CH_RVA + 0x20:
                rows.append((ins.address, s, 'CH', d - CH_RVA, mem.size, 'image relative', ins))
            elif P8CH <= d < P8CH + 0x20:
                rows.append((ins.address, s, 'CH', d - P8CH, mem.size, 'P8 relative', ins))
            elif P8P4 <= d < P8P4 + 4:
                rows.append((ins.address, s, 'P4', d - P8P4, mem.size, 'P8 relative', ins))
            elif P8HASH <= d < P8HASH + 2:
                rows.append((ins.address, s, 'HASH', d - P8HASH, mem.size, 'P8 relative', ins))
            elif d in (8, 0x10, 0x12) and mem.mem.base != 0 and (evid or mem.size == 2):
                rows.append((ins.address, s, 'CH', d, mem.size, 'child pointer (function handles children)' if evid else 'child pointer? (word access at a link offset, function names no table)', ins))
    by = collections.Counter()
    detail = collections.defaultdict(list)
    for at, s, rg, off, size, how, ins in rows:
        name = FIELDS.get(off, 'off 0x%X' % off) if rg == 'CH' else {0: 'first child' if rg == 'P4' else 'bucket head', 2: 'last child'}.get(off, 'off %d' % off)
        proven = not how.startswith('child pointer')
        if size == 2:
            kind = 'word'
        elif size > 2 and proven and (name in LINK or name == 'value/free link'):
            kind = 'wide, through a stage 1 table'
        elif size > 2:
            kind = 'ambiguous (4 or 8 byte access through a pointer: stack value tags, or paired links)'
        else:
            kind = 'byte'
        by[(rg, name, kind)] += 1
        detail[(rg, name, kind)].append((at, s, how, ins.mnemonic + ' ' + ins.op_str))
    print('accesses to the child entry and the link tables in the variable system (stage 1 tables: rip, image relative, P8 relative; pointer ones only in functions that handle children):')
    for (rg, name, kind), n in sorted(by.items()):
        if name in ('type', 'name hi', 'parent', 'value') or name.startswith('off'):
            continue
        print('  %-5s %-16s %-52s %d' % (rg, name, kind, n))
    words = [k for k in detail if k[2] == 'word' and (k[1] in LINK or k[0] in ('P4', 'HASH') or k[1] == 'value/free link')]
    wide = [k for k in detail if k[2].startswith('wide') and k[1] in LINK | {'value/free link'}]
    amb = [k for k in detail if k[2].startswith('ambiguous') and k[1] in LINK]
    n_words, n_wide, n_amb = (sum(len(detail[k]) for k in g) for g in (words, wide, amb))
    link_total = n_words + n_wide
    print('u16 child index accesses (hash next, siblings, free list link, first / last child, bucket head): %d word accesses in %d functions; %d wider accesses of paired links through a stage 1 table; %d ambiguous (not counted)' %
          (n_words, len({s for k in words for _, s, _, _ in detail[k]}), n_wide, n_amb))
    for key in sorted(words):
        how = collections.Counter(h for _, _, h, _ in detail[key])
        print('    %-5s %-16s %d  (%s)' % (key[0], key[1], len(detail[key]), ', '.join('%s %d' % kv for kv in how.items())))
    db = sqlite3.connect('file:' + db_file.replace('\\', '/') + '?mode=ro', uri=True)
    num = lambda x: x if isinstance(x, int) else int(x, 16)
    ext = collections.defaultdict(list)
    for src, dst, at in db.execute('select src_func, dst, at from calls').fetchall():
        try:
            src, dst = num(src), num(dst)
        except Exception:
            continue
        if at is not None and VM_CALLS[0] <= dst < VM_CALLS[1] and not (VM_CALLS[0] <= src < VM_CALLS[1]):
            ext[dst].append((src, at))
    holders = collections.defaultdict(list)
    for dst, lst in ext.items():
        for src, at in lst:
            taint, k = {'rax'}, 0
            for ins in md.disasm(img.read(at + 5, 120), at + 5):
                k += 1
                if k > 16:
                    break
                ops = ins.operands
                if ins.mnemonic == 'mov' and len(ops) == 2 and ops[0].type == X.X86_OP_MEM and ops[1].type == X.X86_OP_REG and ops[0].size == 2 and FULL.get(ins.reg_name(ops[1].reg)) in taint:
                    holders[dst].append((at, src, 'store16 ' + ins.op_str))
                if ins.mnemonic == 'movzx' and len(ops) == 2 and ops[1].type == X.X86_OP_REG and ops[1].size == 2 and FULL.get(ins.reg_name(ops[1].reg)) in taint:
                    holders[dst].append((at, src, 'trunc16 ' + ins.op_str))
                if ins.mnemonic in ('ret', 'jmp', 'call') or ins.mnemonic.startswith('j'):
                    break
                if ins.mnemonic == 'mov' and len(ops) == 2 and ops[0].type == X.X86_OP_REG and ops[1].type == X.X86_OP_REG and ops[0].size >= 4 and FULL.get(ins.reg_name(ops[1].reg)) in taint:
                    taint.add(FULL.get(ins.reg_name(ops[0].reg)))
                    continue
                try:
                    for r in ins.regs_access()[1]:
                        taint.discard(FULL.get(ins.reg_name(r)))
                except Exception:
                    pass
                if not taint:
                    break
    print('\nexternal call sites into the variable system: %d in %d callees; with a 16-bit store or truncation of the result in the next 16 instructions: %d in %d callees' %
          (sum(len(v) for v in ext.values()), len(ext), sum(len(v) for v in holders.values()), len(holders)))
    for dst in sorted(holders):
        print('  callee %X: %d sites   [%s]' % (dst, len(holders[dst]), HOLDER_CALLEES.get(dst, CHILD_API.get(dst, 'not identified'))))
    print('callees that return a child index (FindVariable / GetVariable families, first child 0x140C05080, child field 0x140C050E0): %d sites outside, %d with a 16-bit store or truncation in a 16 instruction straight-line window' %
          (sum(len(ext.get(d, [])) for d in CHILD_API), sum(len(holders.get(d, [])) for d in CHILD_API)))
    outside = [r for r in sites['refs'] if not (VM_CALLS[0] <= r['func'] < VM_CALLS[1])]
    print('functions outside the variable system that name a table: %s' % ', '.join('%X (%s)' % (r['func'], r['region']) for r in outside))
    out = dict(by={'%s|%s|%s' % k: v for k, v in by.items()}, link_total=link_total, external_sites=sum(len(v) for v in ext.values()), external_callees=len(ext),
               holders={'%X' % d: len(v) for d, v in holders.items()}, child_api_sites=sum(len(ext.get(d, [])) for d in CHILD_API),
               child_api_holders=sum(len(holders.get(d, [])) for d in CHILD_API))
    if args.o:
        json.dump(out, open(args.o, 'w'), indent=1)
        print('wrote', args.o)
    return 0


# ------------------------------------------------------------------------------------------------ thread ids and the thread self beyond u16 (a79)
# A thread id is returned by the Scr_ExecThread family as a u16 (`movzx eax,bx`), narrowed again by 42 callers and by Scr_FreeThread (`movzx ecx,cx`) and stored in two game structs
# as a word. With ids of 19 bits (8 segments) all of these must hold 32 bits: `thread-rows` finds them (the callers by a taint scan of the value returned in eax over the next
# 20 straight-line instructions, the two struct fields by every word access of their displacement), `emit-threads` writes the rows of script_variables_threads.inc:
# {address, length, stock bytes, new bytes} (little endian in a uint64). The widening is one byte for one byte: `0F B7 /r` (movzx r32, r/m16) -> `90 8B /r` (nop ; mov r32, r/m32),
# `66 [REX] 39|89 /r` (cmp / mov word) -> `90 [REX] 39|89 /r`. The thread self (P8 +2) and the dead entity chain are not rows: caves and replacements in script_variables.cpp.
THREAD_CALLEES = (0x140B516C0, 0x140B516F0, 0x140B51730, 0x140C0AC80, 0x140C0ACD0, 0x140C0AF90)       # return a thread id in eax (wrappers of Scr_ExecThread / Scr_ExecEntThread)
THREAD_RETURNS = (0x140C0AD41, 0x140C0B017)          # `movzx eax,bx` / `movzx eax,di` of the two executors
FREE_THREAD = 0x140C0B050                            # `movzx ecx,cx ; jmp RemoveRefToObject`
CHAIN_HEAD_READ = 0x140C08DF1                       # `movzx eax, word [BLK0 + 0x2C]`: the head of the dead entity chain is a dword
THREAD_FIELDS = (0x1C70, 0x1A24)                     # word fields of two game structs (client think state) that keep a thread id


def widen_bytes(raw):
    """The one for one widening of a 16-bit instruction: returns the new bytes (same length) or raises."""
    b = bytearray(raw)
    if b[0] == 0x66:                                         # 66 [REX] op /r (cmp / mov word)
        i = 1 + (1 if 0x40 <= b[1] <= 0x4F else 0)
        if b[i] not in (0x39, 0x89, 0x3B, 0x8B, 0x85):
            raise ValueError('not a word cmp/mov: %s' % raw.hex())
        b[0] = 0x90
        return bytes(b)
    if 0x40 <= b[0] <= 0x4F:                                 # [REX] 0F B7 /r
        if b[1:3] != b'\x0f\xb7':
            raise ValueError('not a movzx word: %s' % raw.hex())
        return bytes([0x90, b[0], 0x8B]) + bytes(b[3:])
    if b[0:2] != b'\x0f\xb7':
        raise ValueError('not a movzx word: %s' % raw.hex())
    return bytes([0x90, 0x8B]) + bytes(b[2:])


def thread_rows(img, md, db_file):
    from capstone import x86_const as X
    db = sqlite3.connect('file:' + db_file.replace('\\', '/') + '?mode=ro', uri=True)
    idx = sqlite3.connect('file:' + index_path().replace('\\', '/') + '?mode=ro', uri=True)
    rows, problems = {}, []

    def add(at, kind, why):
        ins = next(md.disasm(img.read(at, 16), at))
        raw = bytes(ins.bytes)
        try:
            new = widen_bytes(raw)
        except ValueError as e:
            problems.append('%X: %s' % (at, e))
            return
        rows[at] = dict(at=at, kind=kind, why=why, length=len(raw), stock=raw.hex(), new=new.hex(), text=ins.mnemonic + ' ' + ins.op_str)
    for at in THREAD_RETURNS:
        add(at, 'return', 'thread id returned by the executor')
    add(CHAIN_HEAD_READ, 'chain', 'FUN_140C08D90 reads the head of the dead entity chain as a word')
    add(FREE_THREAD, 'free', 'Scr_FreeThread argument')
    for callee in THREAD_CALLEES:
        for (at,) in db.execute('select at from calls where dst=?', (callee,)).fetchall():
            if at is None:
                continue
            taint = {'rax'}
            for k, ins in enumerate(md.disasm(img.read(at + 5, 120), at + 5)):
                if k >= 20:
                    break
                mn, ops = ins.mnemonic, ins.operands
                hit = None
                if mn == 'mov' and len(ops) == 2 and ops[0].type == X.X86_OP_MEM and ops[1].type == X.X86_OP_REG and ops[0].size == 2 and FULL.get(ins.reg_name(ops[1].reg)) in taint:
                    hit = 'store'
                elif mn == 'movzx' and len(ops) == 2 and ops[1].type == X.X86_OP_REG and ops[1].size == 2 and FULL.get(ins.reg_name(ops[1].reg)) in taint:
                    hit = 'caller'
                elif mn in ('cmp', 'test') and len(ops) == 2 and ops[0].type == X.X86_OP_REG and ops[0].size == 2 and FULL.get(ins.reg_name(ops[0].reg)) in taint:
                    hit = 'cmp'
                if hit:
                    add(ins.address, hit, 'after the call at %X' % at)
                if mn in ('ret', 'jmp', 'call') or mn.startswith('j'):
                    break
                if mn == 'mov' and len(ops) == 2 and ops[0].type == X.X86_OP_REG and ops[1].type == X.X86_OP_REG and ops[0].size >= 4 and FULL.get(ins.reg_name(ops[1].reg)) in taint:
                    taint.add(FULL.get(ins.reg_name(ops[0].reg)))
                    continue
                try:
                    for r in ins.regs_access()[1]:
                        taint.discard(FULL.get(ins.reg_name(r)))
                except Exception:
                    pass
                if not taint:
                    break
    for field in THREAD_FIELDS:
        for at, text in idx.execute("select at,text from insn where kind='disp' and value=?", (field,)).fetchall():
            if ' word ptr' in text and 'dword' not in text and 'qword' not in text and 'xmmword' not in text:
                add(at, 'field_%X' % field, 'word access of [+0x%X]' % field)
                ins = next(md.disasm(img.read(at, 16), at))
                if ins.mnemonic == 'movzx' and ins.operands[0].type == X.X86_OP_REG:       # the loaded id must not be narrowed again by a 16-bit test or compare (`test cx,cx`)
                    reg = FULL.get(ins.reg_name(ins.operands[0].reg))
                    for k, nxt in enumerate(md.disasm(img.read(at + ins.size, 40), at + ins.size)):
                        if k >= 4 or nxt.mnemonic in ('call', 'ret', 'jmp') or nxt.mnemonic.startswith('j'):
                            break
                        o = nxt.operands
                        if nxt.mnemonic in ('test', 'cmp') and len(o) == 2 and o[0].type == X.X86_OP_REG and o[0].size == 2 and FULL.get(nxt.reg_name(o[0].reg)) == reg:
                            add(nxt.address, 'field_test', 'a 16-bit test of the id loaded at %X' % at)
    return dict(rows=sorted(rows.values(), key=lambda r: r['at']), problems=problems)


def thread_rows_cmd(args):
    image_file, db_file = ss.image_path()
    img, md = ss.Image(image_file), ss.cs()
    md.detail = True
    d = thread_rows(img, md, db_file)
    kinds = collections.Counter(r['kind'] for r in d['rows'])
    print('thread id widening rows: %d %s' % (len(d['rows']), dict(kinds)))
    for p in d['problems']:
        print('  PROBLEM:', p)
    if args.o and not d['problems']:
        json.dump(dict(schema='iw7.variable-threads/1', **d), open(args.o, 'w', newline='\n'), indent=1)
        print('wrote', args.o)
    return 1 if d['problems'] else 0


def emit_threads(args):
    d = json.load(open(args.file))
    lines = ['// Generated by ops/engine/variable_sites.py emit-threads from variable-threads.json; do not edit.',
             '// {address, length, stock bytes, new bytes} (little endian): a 16-bit holder of a thread id widened to 32 bits, one byte for one byte (`movzx` -> `nop ; mov`, the `66` prefix -> `nop`)']
    body = ['{0x%Xull, %d, 0x%Xull, 0x%Xull},' % (r['at'], r['length'], int.from_bytes(bytes.fromhex(r['stock']), 'little'), int.from_bytes(bytes.fromhex(r['new']), 'little')) for r in d['rows']]
    with open(args.o, 'w', newline='\n') as out:
        out.write('\n'.join(lines) + '\n')
        out.write('\n'.join(body) + '\n')
    print('wrote', len(body), 'thread id rows to', args.o)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('find'); p.add_argument('-o', required=True); p.set_defaults(fn=find)
    p = sub.add_parser('check'); p.add_argument('file'); p.set_defaults(fn=check)
    p = sub.add_parser('emit'); p.add_argument('file'); p.add_argument('-o', required=True); p.set_defaults(fn=emit)
    p = sub.add_parser('parents'); p.add_argument('-o', default=None); p.set_defaults(fn=parents)
    p = sub.add_parser('buckets'); p.add_argument('-o', default=None); p.set_defaults(fn=buckets)
    p = sub.add_parser('emit-buckets'); p.add_argument('file'); p.add_argument('-o', required=True); p.set_defaults(fn=emit_buckets)
    p = sub.add_parser('segments'); p.add_argument('-o', default=None); p.set_defaults(fn=segments)
    p = sub.add_parser('links'); p.add_argument('-o', default=None); p.set_defaults(fn=links)
    p = sub.add_parser('segment-rows'); p.add_argument('-o', default=None); p.set_defaults(fn=segment_rows_cmd)
    p = sub.add_parser('emit-segments'); p.add_argument('file'); p.add_argument('-o', required=True); p.set_defaults(fn=emit_segments)
    p = sub.add_parser('thread-rows'); p.add_argument('-o', default=None); p.set_defaults(fn=thread_rows_cmd)
    p = sub.add_parser('emit-threads'); p.add_argument('file'); p.add_argument('-o', required=True); p.set_defaults(fn=emit_threads)
    args = ap.parse_args()
    sys.exit(args.fn(args) or 0)


if __name__ == '__main__':
    main()
