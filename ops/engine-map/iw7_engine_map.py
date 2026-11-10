#!/usr/bin/env python3
"""A queryable map of the game executable's code: functions, calls, references, strings, names.

Built offline from the unpacked code sections kept on the machine (never committed). Function boundaries come from
the x64 exception directory, so an address from a sampling profiler or a crash resolves to the right function.
See docs/ENGINE-MAP.md.
"""
import argparse
import bisect
import csv
import hashlib
import json
import multiprocessing
import os
import re
import sqlite3
import struct
import sys
import time

VERSION = 1
IMAGE_BASE = 0x140000000
TEXT_VA = 0x140001000
RDATA_VA = 0x141435000
PADDING = frozenset((0xCC, 0x90, 0x00))
UNW_CHAININFO = 0x4
RIP = re.compile(r'\[rip ([+-]) (0x[0-9a-f]+|\d+)\]')
HEX = re.compile(r'^0x[0-9a-f]+$')
SYMBOL = re.compile(r'symbol<(.*?)>\s+(\w+)\s*\{\s*(0x[0-9A-Fa-f]+)', re.S)
CONST = re.compile(r'0x14[0-9A-Fa-f]{7}\b')
IDENT = re.compile(r'[A-Za-z_]\w*')
CODE_NAME = re.compile(r'^([A-Z][A-Za-z0-9]*_[A-Za-z0-9_]+)(?=:|\(| failed)')
DVAR_NAME = re.compile(r'^[a-z][a-z0-9]{0,8}_[A-Za-z0-9_]{2,40}$')
LABEL_ORDER = "order by source = 'symbols.hpp' desc, source like 'analyst:%' desc, source like 'auto:%' asc, name"


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(1 << 20), b''):
            h.update(block)
    return h.hexdigest()


def read_bytes(path):
    with open(path, 'rb') as f:
        return f.read()


class Image:
    """The sections we have, addressed by virtual address."""

    def __init__(self, text, rdata, pdata, text_va=TEXT_VA, rdata_va=RDATA_VA, base=IMAGE_BASE):
        self.text, self.rdata, self.pdata = text, rdata, pdata
        self.text_va, self.rdata_va, self.base = text_va, rdata_va, base
        self.text_end, self.rdata_end = text_va + len(text), rdata_va + len(rdata)

    def region(self, va):
        if self.text_va <= va < self.text_end:
            return 'text'
        if self.rdata_va <= va < self.rdata_end:
            return 'rdata'
        return 'data'

    def unwind(self, rva, depth=0):
        """(root begin rva, prolog size) of the unwind info at rva, following chained entries to the root; None if outside."""
        off = self.base + rva - self.rdata_va
        if depth > 32 or off < 0 or off + 4 > len(self.rdata):
            return None
        flags, prolog, codes = self.rdata[off] >> 3, self.rdata[off + 1], self.rdata[off + 2]
        if flags & UNW_CHAININFO:
            at = off + 4 + ((codes + 1) & ~1) * 2
            if at + 12 > len(self.rdata):
                return None
            begin, _end, info = struct.unpack_from('<III', self.rdata, at)
            parent = self.unwind(info, depth + 1)
            if parent and parent[0] is not None:
                return parent                                          # the parent is itself a chained fragment
            return (begin, parent[1] if parent else 0)                 # the parent is the root (or cannot be read)
        return (None, prolog)

    def string(self, va, least=4, most=200):
        off = va - self.rdata_va
        if not 0 <= off < len(self.rdata):
            return None
        end = self.rdata.find(b'\0', off, off + most + 1)
        raw = self.rdata[off:end if end >= 0 else off + most]
        if len(raw) >= least and all(32 <= b < 127 or b in (9, 10, 13) for b in raw):
            return raw.decode('ascii')
        return None


def read_functions(image):
    """Fragments [(begin va, end va, root va)], functions {root: prolog}, and the count of entries whose unwind info is outside."""
    frags, prolog, outside, self_outside = [], {}, 0, 0
    for i in range(0, len(image.pdata) - 11, 12):
        begin, end, info = struct.unpack_from('<III', image.pdata, i)
        if not begin and not end:
            continue
        b, e = image.base + begin, image.base + end
        if not (image.text_va <= b < e <= image.text_end):
            self_outside += 1                                          # code in a section we were not given
            continue
        u = image.unwind(info)
        if u is None:
            outside += 1
            root = b
        else:
            root = b if u[0] is None else image.base + u[0]
            if u[0] is None:
                prolog[b] = u[1]
        frags.append((b, e, root))
    frags.sort()
    starts = {b for b, _e, _r in frags}
    frags = [(b, e, r if r in starts else b) for b, e, r in frags]      # a chain to an entry we do not have: stand alone
    for b, _e, r in frags:
        prolog.setdefault(r, 0)
    return frags, prolog, outside, self_outside


def find_gaps(image, frags):
    """Bytes between fragments: padding count, and gap regions [(begin, end)] that hold something other than padding."""
    gaps, padding, at = [], 0, image.text_va
    for b, e, _r in frags + [(image.text_end, image.text_end, 0)]:
        if b > at:
            raw = image.text[at - image.text_va:b - image.text_va]
            lo, hi = 0, len(raw)
            while lo < hi and raw[lo] in PADDING:
                lo += 1
            while hi > lo and raw[hi - 1] in PADDING:
                hi -= 1
            padding += len(raw) - (hi - lo)
            if hi > lo:
                gaps.append((at + lo, at + hi))
        at = max(at, e)
    return gaps, padding


def scan(job):
    """Disassemble fragments. Returns (calls, refs, failures) with rows (root, site, target, kind) / (root, site, target, mnemonic)."""
    import capstone
    text, text_va, items = job
    md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
    calls, refs, failed = [], [], []
    for b, e, root in items:
        at = b
        while at < e:
            done = at
            for addr, size, mnem, ops in md.disasm_lite(text[at - text_va:e - text_va], at):
                done = addr + size
                if HEX.match(ops):
                    if mnem == 'call':
                        calls.append((root, addr, int(ops, 16), 'call'))
                    elif mnem[0] == 'j':
                        calls.append((root, addr, int(ops, 16), 'jmp' if mnem == 'jmp' else 'jcc'))
                    continue
                m = RIP.search(ops)
                if m:
                    disp = int(m.group(2), 0)
                    refs.append((root, addr, addr + size + (disp if m.group(1) == '+' else -disp), mnem))
            if done >= e:
                break
            failed.append((root, done))
            at = done + 1                                              # skip the byte that does not decode and resume
    return calls, refs, failed


def parse_names(symbols=None, lists=(), native_src=None, overlay=None):
    """[(address, name, source, signature)] from the loader's symbol table, name lists, hook constants and the overlay file."""
    out = []
    if symbols and os.path.isfile(symbols):
        with open(symbols, encoding='utf-8', errors='replace') as f:
            for sig, name, addr in SYMBOL.findall(f.read()):
                out.append((int(addr, 16), name, 'symbols.hpp', ' '.join(sig.split())))
    for path in lists:
        with open(path, encoding='utf-8', errors='replace', newline='') as f:
            for row in csv.reader(f):
                if len(row) >= 2 and re.fullmatch(r'(0x)?[0-9A-Fa-f]{6,16}', row[1].strip()):
                    out.append((int(row[1], 16), row[0].strip(), 'list:' + os.path.basename(path), ''))
    if native_src and os.path.isdir(native_src):
        for name in sorted(os.listdir(native_src)):
            if name.endswith(('.cpp', '.hpp')):
                with open(os.path.join(native_src, name), encoding='utf-8', errors='replace') as f:
                    for n, line in enumerate(f, 1):
                        for m in CONST.finditer(line):
                            words = [w for w in IDENT.findall(line[:m.start()]) if w not in ('constexpr', 'std', 'uintptr_t', 'const', 'auto', 'static', 'inline', 'utils', 'hook')]
                            out.append((int(m.group(), 16), 'hook:%s:%d%s' % (name, n, ':' + words[-1] if words else ''), 'native-src', ''))
    if overlay and os.path.isfile(overlay):
        with open(overlay, encoding='utf-8') as f:
            for row in json.load(f).get('names', []):
                out.append((int(row['address'], 16), row['name'], 'analyst:' + row.get('source', ''), ''))
    return sorted(set(out))


SCHEMA = """
create table meta(k text primary key, v text);
create table functions(start integer primary key, end integer, size integer, fragments integer, prolog integer, partial integer);
create table fragments(begin integer primary key, end integer, func integer);
create table gaps(begin integer primary key, end integer, after integer);
create table calls(src integer, site integer, target integer, dst integer, kind text);
create table refs(src integer, site integer, target integer, region text, mnem text);
create table strings(addr integer primary key, text text);
create table names(addr integer, name text, source text, signature text, func integer, off integer);
create index calls_src on calls(src); create index calls_dst on calls(dst); create index calls_target on calls(target);
create index refs_src on refs(src); create index refs_target on refs(target);
create index names_addr on names(addr); create index names_name on names(name); create index names_func on names(func);
create index fragments_func on fragments(func);
"""


class Resolver:
    def __init__(self, frags):
        self.begins = [b for b, _e, _r in frags]
        self.frags = frags

    def func(self, va):
        i = bisect.bisect_right(self.begins, va) - 1
        if i >= 0 and va < self.frags[i][1]:
            return self.frags[i][2]
        return None


def suggest_names(db, ignore_existing=False):
    """Names for unnamed functions from the texts they refer to. Returns {'unique': [...], 'shared': [...], 'ambiguous': n, 'taken': n}.

    A text that starts with a code name (`R_RegisterFont: ...`, `Com_Error(`, `Foo_Bar failed`) names the function that refers to it
    when that code name appears in the strings of exactly one function (text:unique). With 2 or 3 such functions the code name is only
    a candidate for each (text:shared). A function whose texts give several different unique code names is left unnamed.
    ignore_existing=True also covers functions that already have a name and names already in use (only for measuring the rule)."""
    users, first = {}, {}                                            # code name -> {function}; (code name, function) -> (string address, text)
    for src, addr, text in db.execute('select distinct r.src, s.addr, s.text from refs r join strings s on s.addr = r.target order by s.addr, r.src'):
        m = CODE_NAME.match(text)
        if m:
            users.setdefault(m.group(1), set()).add(src)
            first.setdefault((m.group(1), src), (addr, text))
    named = set() if ignore_existing else {r[0] for r in db.execute('select func from names where off = 0 and func is not null')}
    used = set() if ignore_existing else {r[0] for r in db.execute('select name from names')}
    per_func, unique, shared, taken = {}, [], [], 0
    for ident in sorted(users):
        funcs = sorted(users[ident])
        if len(funcs) == 1:
            if funcs[0] in named:
                continue
            if ident in used or '~' + ident in used:
                taken += 1
                continue
            per_func.setdefault(funcs[0], []).append(ident)
        elif len(funcs) <= 3:
            left = [f for f in funcs if f not in named]
            if left:
                shared.append(dict(name='~' + ident, source='text:shared', functions=left))
    ambiguous = 0
    for f in sorted(per_func):
        if len(per_func[f]) != 1:
            ambiguous += 1
            continue
        ident = per_func[f][0]
        addr, text = first[(ident, f)]
        unique.append(dict(function=f, name='~' + ident, source='text:unique', string=addr, text=text))
    return dict(unique=unique, shared=shared, ambiguous=ambiguous, taken=taken)


def build(image, db_path, names, workers=None, inputs=None, auto_names=False):
    t0 = time.time()
    frags, prolog, outside, elsewhere = read_functions(image)
    gaps, padding = find_gaps(image, frags)
    res = Resolver(frags)
    workers = workers or max(1, min(8, (os.cpu_count() or 2) - 2))
    step = max(1, len(frags) // (workers * 8) + 1)
    jobs = [(image.text, image.text_va, frags[i:i + step]) for i in range(0, len(frags), step)]
    if workers > 1 and len(frags) > 2000:
        with multiprocessing.Pool(workers) as pool:
            parts = pool.map(scan, jobs)
    else:
        parts = [scan(j) for j in jobs]
    calls, refs, failed = [], [], []
    for c, r, f in parts:
        calls += c
        refs += r
        failed += f
    # Leaf functions carry no unwind data: a gap that direct calls land in is code. Split such gaps at the call targets.
    leaves = 0
    for _round in range(6):
        hit = sorted({t for _s, _a, t, k in calls if k in ('call', 'jmp') and res.func(t) is None})
        new, gi = [], 0
        gap_begins = [b for b, _e in gaps]
        by_gap = {}
        for t in hit:
            gi = bisect.bisect_right(gap_begins, t) - 1
            if gi >= 0 and t < gaps[gi][1]:
                by_gap.setdefault(gi, []).append(t)
        if not by_gap:
            break
        kept = []
        for gi, (b, e) in enumerate(gaps):
            cuts = by_gap.get(gi)
            if not cuts:
                kept.append((b, e))
                continue
            if cuts[0] > b:
                kept.append((b, cuts[0]))
            for i, t in enumerate(cuts):
                new.append((t, cuts[i + 1] if i + 1 < len(cuts) else e, t))
        gaps = kept
        leaves += len(new)
        frags = sorted(frags + new)
        res = Resolver(frags)
        for b, _e, _r in new:
            prolog.setdefault(b, 0)
        c, r, f = scan((image.text, image.text_va, new))
        calls += c
        refs += r
        failed += f
    own = {}
    for b, e, r in frags:
        own.setdefault(r, []).append((b, e))
    edges = []
    for src, site, target, kind in calls:
        inside = any(b <= target < e for b, e in own[src])
        if kind == 'jcc' and inside:
            continue
        if kind == 'jmp':
            if inside:
                continue
            kind = 'tail'
        edges.append((src, site, target, res.func(target), kind))
    partial = {r for r, _a in failed}
    if os.path.exists(db_path):
        os.remove(db_path)
    db = sqlite3.connect(db_path)
    db.executescript(SCHEMA)
    size, count = {}, {}
    for b, e, r in frags:
        size[r] = size.get(r, 0) + e - b
        count[r] = count.get(r, 0) + 1
    ends = {b: e for b, e, r in frags if b == r}
    db.executemany('insert into functions values(?,?,?,?,?,?)', [(r, ends[r], size[r], count[r], prolog.get(r, 0), int(r in partial)) for r in sorted(size)])
    db.executemany('insert into fragments values(?,?,?)', frags)
    db.executemany('insert into gaps values(?,?,?)', [(b, e, res.func(max(image.text_va, b - 1)) or (frags[bisect.bisect_right(res.begins, b) - 1][2] if bisect.bisect_right(res.begins, b) else None)) for b, e in gaps])
    db.executemany('insert into calls values(?,?,?,?,?)', sorted(edges, key=lambda x: (x[0], x[1])))
    db.executemany('insert into refs values(?,?,?,?,?)', sorted(((s, a, t, image.region(t), m) for s, a, t, m in refs), key=lambda x: (x[0], x[1])))
    strings = {}
    for _s, _a, t, _m in refs:
        if t not in strings and image.rdata_va <= t < image.rdata_end:
            text = image.string(t)
            if text:
                strings[t] = text
    db.executemany('insert into strings values(?,?)', sorted(strings.items()))
    rows = []
    for addr, name, source, sig in names:
        f = res.func(addr)
        rows.append((addr, name, source, sig, f, addr - f if f is not None else None))
    db.executemany('insert into names values(?,?,?,?,?,?)', rows)
    auto = 0
    if auto_names:
        extra = [(x['function'], x['name'], 'auto:' + x['source'], 'string %X: %s' % (x['string'], json.dumps(x['text'][:80])), x['function'], 0) for x in suggest_names(db)['unique']]
        db.executemany('insert into names values(?,?,?,?,?,?)', extra)
        rows += extra
        auto = len(extra)
    covered = sum(e - b for b, e, _r in frags)
    meta = dict(version=VERSION, functions=len(size), fragments=len(frags), unwind_outside=outside, entries_in_other_sections=elsewhere, leaf_functions=leaves, gaps=len(gaps),
                text_bytes=len(image.text), covered_bytes=covered, padding_bytes=padding, gap_bytes=sum(e - b for b, e in gaps),
                calls=sum(1 for e in edges if e[4] == 'call'), tail_calls=sum(1 for e in edges if e[4] == 'tail'),
                refs=len(refs), strings=len(strings), names=len(rows), names_at_start=sum(1 for r in rows if r[5] == 0),
                names_inside=sum(1 for r in rows if r[5]), names_outside=sum(1 for r in rows if r[4] is None),
                decode_failures=len(failed), partial_functions=len(partial), text_va=image.text_va, rdata_va=image.rdata_va, base=image.base)
    if auto_names:
        meta['auto_names'] = auto
    meta.update(inputs or {})
    db.executemany('insert into meta values(?,?)', [(k, str(v)) for k, v in sorted(meta.items())])
    db.commit()
    db.close()
    meta['seconds'] = round(time.time() - t0, 1)
    return meta


# ------------------------------------------------------------------------------------------------ queries

class Map:
    def __init__(self, path):
        if not os.path.isfile(path):
            raise SystemExit('no engine map at %s: run "build" first' % path)
        self.db = sqlite3.connect(path)
        self.meta = dict(self.db.execute('select k, v from meta'))
        self.base = int(self.meta['base'])

    def addr(self, text):
        """An address as 0x140C04580, 140C04580, +0xC04580 (offset from the image base), or a known name."""
        t = text.strip()
        m = re.fullmatch(r'(?:iw7)?\+(?:0x)?([0-9A-Fa-f]+)', t)
        if m:
            return self.base + int(m.group(1), 16)
        if re.fullmatch(r'(0x)?[0-9A-Fa-f]{8,16}', t):
            return int(t, 16)
        m = re.fullmatch(r'sub_([0-9A-Fa-f]+)', t)
        if m:
            return int(m.group(1), 16)
        row = self.db.execute('select addr from names where name = ? order by addr', (t,)).fetchall()
        if len(row) == 1:
            return row[0][0]
        raise SystemExit('%s: %s' % (t, 'not an address or a known name' if not row else 'name used at %d addresses' % len(row)))

    def func(self, va):
        row = self.db.execute('select begin, end, func from fragments where begin <= ? order by begin desc limit 1', (va,)).fetchone()
        return row[2] if row and va < row[1] else None

    def label(self, va):
        """The best name for an address: a known name, or sub_<function start>+offset."""
        row = self.db.execute("select name from names where addr = ? " + LABEL_ORDER + " limit 1", (va,)).fetchone()
        if row:
            return row[0]
        f = self.func(va)
        if f is None:
            return '%X' % va
        base = self.db.execute("select name from names where addr = ? " + LABEL_ORDER + " limit 1", (f,)).fetchone()
        return (base[0] if base else 'sub_%X' % f) + ('+0x%X' % (va - f) if va != f else '')

    def at(self, va):
        f = self.func(va)
        out = dict(address='%X' % va, function=None, name=self.label(va))
        if f is None:
            gap = self.db.execute('select begin, end, after from gaps where begin <= ? and end > ?', (va, va)).fetchone()
            out['where'] = 'gap after %s' % self.label(gap[2]) if gap and gap[2] else 'gap' if gap else 'outside the mapped code'
            return out
        start, end, size, nfrag, _prolog, _partial = self.db.execute('select * from functions where start = ?', (f,)).fetchone()
        frag = self.db.execute('select begin from fragments where begin <= ? order by begin desc limit 1', (va,)).fetchone()[0]
        out.update(function='%X' % f, function_name=self.label(f), offset=va - f, size=size, fragments=nfrag, end='%X' % end,
                   where='function start' if va == f else 'chained fragment' if frag != f else 'inside',
                   names=[r[0] for r in self.db.execute('select name from names where func = ? and off = 0 order by name', (f,))])
        return out

    def rank(self, pairs):
        """[(address, count)] -> [(count, function label, function start or None)] sorted by count."""
        total = {}
        for va, n in pairs:
            f = self.func(va)
            total[f] = total.get(f, 0) + n
        rows = [(n, self.label(f) if f is not None else '(not in a mapped function)', f) for f, n in total.items()]
        return sorted(rows, key=lambda r: (-r[0], r[2] or 0))

    def callers(self, f):
        return self.db.execute("select src, count(*), group_concat(distinct kind) from calls where dst = ? and kind in ('call','tail') and src != ? group by src order by count(*) desc, src", (f, f)).fetchall()

    def callees(self, f):
        return self.db.execute("select coalesce(dst, target), count(*), group_concat(distinct kind) from calls where src = ? and kind in ('call','tail') group by coalesce(dst, target) order by count(*) desc, 1", (f,)).fetchall()

    def tree(self, f, depth, callers, seen=None, level=0, out=None):
        out = [] if out is None else out
        seen = set() if seen is None else seen
        for other, n, kind in (self.callers(f) if callers else self.callees(f)):
            out.append('%s%s  x%d%s' % ('  ' * level, self.label(other), n, '' if kind == 'call' else ' (%s)' % kind))
            if level + 1 < depth and other not in seen:
                seen.add(other)
                self.tree(other, depth, callers, seen, level + 1, out)
        return out


def emit(args, obj, lines):
    if args.json:
        print(json.dumps(obj, indent=1))
    else:
        for line in lines:
            print(line)


def cmd_build(args):
    root = args.reference_root
    paths = {k: os.path.join(root, 'unpacked-%s.bin' % k) for k in ('text', 'rdata', 'pdata')}
    for p in paths.values():
        if not os.path.isfile(p):
            raise SystemExit('missing input: %s' % p)
    image = Image(*(read_bytes(paths[k]) for k in ('text', 'rdata', 'pdata')))
    names = parse_names(args.symbols, args.names or (), args.native_src, args.names_file)
    inputs = {'input_%s_sha256' % k: sha256(p) for k, p in paths.items()}
    os.makedirs(os.path.dirname(os.path.abspath(args.db)), exist_ok=True)
    meta = build(image, args.db, names, args.workers, inputs, args.auto_names)
    emit(args, meta, ['%-18s %s' % (k, meta[k]) for k in (
        'functions', 'fragments', 'leaf_functions', 'gaps', 'text_bytes', 'covered_bytes', 'padding_bytes', 'gap_bytes', 'calls', 'tail_calls', 'refs',
        'strings', 'names', 'auto_names', 'names_at_start', 'names_inside', 'names_outside', 'decode_failures', 'partial_functions', 'unwind_outside', 'entries_in_other_sections', 'seconds') if k in meta])
    return 0


def cmd_at(args):
    m = Map(args.db)
    if args.stdin:
        pairs = []
        for line in sys.stdin:
            parts = line.replace(',', ' ').split()
            if parts:
                pairs.append((m.addr(parts[0]), int(parts[1]) if len(parts) > 1 else 1))
        rows = m.rank(pairs)
        total = sum(r[0] for r in rows) or 1
        emit(args, [dict(count=n, share=round(n / total, 4), function=name, start='%X' % f if f is not None else None) for n, name, f in rows[:args.top]],
             ['%8d  %5.1f%%  %s' % (n, 100.0 * n / total, name) for n, name, _f in rows[:args.top]])
        return 0
    found = [m.at(m.addr(a)) for a in args.address]
    emit(args, found, ['%s  %s  %s%s' % (r['address'], r['name'], r['where'], '  size %d, %d fragment(s)' % (r['size'], r['fragments']) if r['function'] else '') for r in found])
    return 0


def start_of(m, text):
    va = m.addr(text)
    f = m.func(va)
    if f is None:
        raise SystemExit('%s is not inside a mapped function' % text)
    return f


def cmd_callers(args):
    m = Map(args.db)
    lines = m.tree(start_of(m, args.func), args.depth, args.cmd == 'callers')
    emit(args, lines, lines[:args.max] + (['... %d more' % (len(lines) - args.max)] if len(lines) > args.max else []) or ['none known (indirect calls are not in the map)'])
    return 0


def cmd_strings(args):
    m = Map(args.db)
    rows = m.db.execute('select distinct r.site, s.addr, s.text from refs r join strings s on s.addr = r.target where r.src = ? order by r.site', (start_of(m, args.func),)).fetchall()
    emit(args, [dict(site='%X' % a, address='%X' % s, text=t) for a, s, t in rows], ['%X  %s' % (a, json.dumps(t)) for a, _s, t in rows] or ['no string reference'])
    return 0


def cmd_find_string(args):
    m = Map(args.db)
    if args.regex:
        pat = re.compile(args.text)
        hits = [(a, t) for a, t in m.db.execute('select addr, text from strings order by addr') if pat.search(t)]
    else:
        hits = m.db.execute("select addr, text from strings where instr(lower(text), lower(?)) order by addr", (args.text,)).fetchall()
    out, lines = [], []
    for addr, text in hits[:args.max]:
        users = m.db.execute('select src, site from refs where target = ? order by site', (addr,)).fetchall()
        out.append(dict(address='%X' % addr, text=text, users=[dict(function=m.label(s), site='%X' % a) for s, a in users]))
        lines.append('%X  %s' % (addr, json.dumps(text)))
        lines += ['    %s  at %X' % (m.label(s), a) for s, a in users[:8]] + (['    ... %d more' % (len(users) - 8)] if len(users) > 8 else [])
    emit(args, out, lines + (['... %d more strings' % (len(hits) - args.max)] if len(hits) > args.max else []) or ['no such string is referenced by mapped code'])
    return 0


def cmd_suggest_names(args):
    m = Map(args.db)
    res = suggest_names(m.db)
    counts = {'text:unique': len(res['unique']), 'text:shared': len(res['shared']), 'ambiguous': res['ambiguous'], 'name already used': res['taken']}
    lines = []
    for s in res['unique'][:args.max]:
        lines.append('%X  %-40s  %s' % (s['function'], s['name'], json.dumps(s['text'][:80])))
    if len(res['unique']) > args.max:
        lines.append('... %d more text:unique' % (len(res['unique']) - args.max))
    for s in res['shared'][:args.max]:
        lines.append('candidate %s  %s' % (s['name'], ', '.join('%X' % f for f in s['functions'])))
    if len(res['shared']) > args.max:
        lines.append('... %d more text:shared' % (len(res['shared']) - args.max))
    lines += ['%-18s %d' % (k, v) for k, v in counts.items()]
    obj = dict(counts=counts,
               unique=[dict(function='%X' % s['function'], name=s['name'], source=s['source'], string='%X' % s['string'], text=s['text']) for s in res['unique'][:args.max]],
               shared=[dict(name=s['name'], source=s['source'], functions=['%X' % f for f in s['functions']]) for s in res['shared'][:args.max]])
    emit(args, obj, lines)
    return 0


def cmd_dvars(args):
    m = Map(args.db)
    hits = [(a, t) for a, t in m.db.execute('select addr, text from strings order by text, addr') if DVAR_NAME.match(t) and (not args.like or args.like.lower() in t.lower())]
    out, lines = [], []
    for addr, text in hits[:args.max]:
        users = m.db.execute('select src, min(site) from refs where target = ? group by src order by src', (addr,)).fetchall()
        out.append(dict(address='%X' % addr, text=text, count=len(users), users=[dict(function=m.label(s), site='%X' % a) for s, a in users]))
        lines.append('%X  %-28s %d function(s)' % (addr, text, len(users)))
        lines += ['    %s  at %X' % (m.label(s), a) for s, a in users[:4]] + (['    ... %d more' % (len(users) - 4)] if len(users) > 4 else [])
    lines.append('%d name text(s) match%s' % (len(hits), '' if len(hits) <= args.max else ', %d shown' % args.max))
    emit(args, dict(total=len(hits), dvars=out), lines)
    return 0


def cmd_refs(args):
    m = Map(args.db)
    va = m.addr(args.address)
    rows = m.db.execute('select src, site, mnem from refs where target = ? union all select src, site, kind from calls where target = ? order by 2', (va, va)).fetchall()
    emit(args, [dict(function=m.label(s), site='%X' % a, how=k) for s, a, k in rows], ['%s  at %X  (%s)' % (m.label(s), a, k) for s, a, k in rows[:args.max]] or ['no direct reference in mapped code'])
    return 0


def cmd_name(args):
    m = Map(args.db)
    va = m.addr(args.address)
    doc = dict(schema='iw7.engine-map-names/1', names=[])
    if os.path.isfile(args.names_file):
        with open(args.names_file, encoding='utf-8') as f:
            doc = json.load(f)
        doc.setdefault('names', [])
    clash = [r for r in doc['names'] if r['name'] == args.name and int(r['address'], 16) != va]
    known = m.db.execute('select addr from names where name = ? and addr != ?', (args.name, va)).fetchall()
    if (clash or known) and not args.replace:
        raise SystemExit('the name %s already belongs to another address; use --replace to move it' % args.name)
    doc['names'] = sorted([r for r in doc['names'] if r['name'] != args.name] + [dict(address='%X' % va, name=args.name, source=args.source)], key=lambda r: (r['address'], r['name']))
    with open(args.names_file, 'w', encoding='utf-8', newline='\n') as f:
        json.dump(doc, f, indent=1)
        f.write('\n')
    f0 = m.func(va)
    m.db.execute('delete from names where name = ?', (args.name,))
    m.db.execute('insert into names values(?,?,?,?,?,?)', (va, args.name, 'analyst:' + args.source, '', f0, va - f0 if f0 is not None else None))
    m.db.commit()
    print('%X is now %s' % (va, args.name))
    return 0


def cmd_names(args):
    m = Map(args.db)
    rows = m.db.execute('select addr, name, source, off from names where name like ? order by addr, name', ('%' + (args.like or '') + '%',)).fetchall()
    emit(args, [dict(address='%X' % a, name=n, source=s, offset=o) for a, n, s, o in rows],
         ['%X  %-44s %s%s' % (a, n, s, '' if o == 0 else '  (not in code)' if o is None else '  (+0x%X inside a function)' % o) for a, n, s, o in rows[:args.max]])
    return 0


def cmd_disasm(args):
    import capstone
    m = Map(args.db)
    f = start_of(m, args.func)
    root = args.reference_root
    text = read_bytes(os.path.join(root, 'unpacked-text.bin'))
    rdata = read_bytes(os.path.join(root, 'unpacked-rdata.bin'))
    image = Image(text, rdata, b'', int(m.meta['text_va']), int(m.meta['rdata_va']), m.base)
    md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
    lines = ['%s:' % m.label(f)]
    for b, e in m.db.execute('select begin, end from fragments where func = ? order by begin', (f,)).fetchall():
        for addr, size, mnem, ops in md.disasm_lite(text[b - image.text_va:e - image.text_va], b):
            note = ''
            if HEX.match(ops) and (mnem == 'call' or mnem[0] == 'j'):
                t = int(ops, 16)
                if not b <= t < e:
                    note = '  ; ' + m.label(t)
            else:
                r = RIP.search(ops)
                if r:
                    t = addr + size + (int(r.group(2), 0) if r.group(1) == '+' else -int(r.group(2), 0))
                    s = image.string(t)
                    note = '  ; %s' % (json.dumps(s) if s else m.label(t) if image.region(t) == 'text' else '%s %X' % (image.region(t), t))
            lines.append('  %X  %-8s %s%s' % (addr, mnem, ops, note))
            if len(lines) > args.max:
                break
    emit(args, lines, lines[:args.max + 1] + (['  ... cut at %d lines' % args.max] if len(lines) > args.max else []))
    return 0


def cmd_stats(args):
    m = Map(args.db)
    lines = ['%-18s %s' % (k, v) for k, v in sorted(m.meta.items()) if not k.startswith('input_')]
    lines.append('largest functions:')
    lines += ['  %7d bytes  %s' % (s, m.label(f)) for f, s in m.db.execute('select start, size from functions order by size desc, start limit 20')]
    lines.append('most called functions:')
    lines += ['  %7d sites  %s' % (n, m.label(f)) for f, n in m.db.execute("select dst, count(*) from calls where dst is not null and kind = 'call' group by dst order by 2 desc, 1 limit 20")]
    alone = m.db.execute("select count(*) from functions where start not in (select dst from calls where dst is not null and kind in ('call','tail'))").fetchone()[0]
    lines.append('functions with no direct caller (entry points, callbacks, table targets): %d' % alone)
    emit(args, dict(meta=m.meta, without_direct_caller=alone), lines)
    return 0


def cmd_selftest(args):
    m = Map(args.db)
    g = lambda k: int(m.meta[k])
    bad = []
    if g('covered_bytes') + g('padding_bytes') + g('gap_bytes') != g('text_bytes'):
        bad.append('covered + padding + gaps differs from the code size')
    if m.db.execute('select count(*) from fragments a join fragments b on b.begin > a.begin and b.begin < a.end').fetchone()[0]:
        bad.append('fragments overlap')
    if m.db.execute('select count(*) from fragments where func not in (select start from functions)').fetchone()[0]:
        bad.append('a fragment belongs to no function')
    if m.db.execute('select count(*) from functions where size <= 0').fetchone()[0]:
        bad.append('a function has no bytes')
    calls = m.db.execute("select count(*), sum(dst = target), sum(dst is null) from calls where kind = 'call'").fetchone()
    print('direct calls %d: %d to a function start, %d inside a function, %d outside mapped functions' % (calls[0], calls[1] or 0, calls[0] - (calls[1] or 0) - (calls[2] or 0), calls[2] or 0))
    print('names %d: %d at a function start, %d inside a function, %d not in code' % (g('names'), g('names_at_start'), g('names_inside'), g('names_outside')))
    for line in bad:
        print('FAIL ' + line)
    print('selftest ' + ('FAILED' if bad else 'passed'))
    return 1 if bad else 0


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    sub = p.add_subparsers(dest='cmd', required=True)

    def add(name, fn, **kw):
        s = sub.add_parser(name, **kw)
        s.add_argument('--db', required=True)
        s.add_argument('--json', action='store_true')
        s.set_defaults(fn=fn)
        return s
    s = add('build', cmd_build)
    s.add_argument('--reference-root', required=True)
    s.add_argument('--symbols')
    s.add_argument('--names', action='append')
    s.add_argument('--native-src')
    s.add_argument('--names-file')
    s.add_argument('--workers', type=int)
    s.add_argument('--auto-names', action='store_true')
    s = add('at', cmd_at)
    s.add_argument('address', nargs='*')
    s.add_argument('--stdin', action='store_true')
    s.add_argument('--top', type=int, default=40)
    for name in ('callers', 'callees'):
        s = add(name, cmd_callers)
        s.add_argument('func')
        s.add_argument('--depth', type=int, default=1)
        s.add_argument('--max', type=int, default=60)
    add('strings', cmd_strings).add_argument('func')
    s = add('find-string', cmd_find_string)
    s.add_argument('text')
    s.add_argument('--regex', action='store_true')
    s.add_argument('--max', type=int, default=20)
    s = add('suggest-names', cmd_suggest_names)
    s.add_argument('--max', type=int, default=60)
    s = add('dvars', cmd_dvars)
    s.add_argument('--like')
    s.add_argument('--max', type=int, default=60)
    s = add('refs', cmd_refs)
    s.add_argument('address')
    s.add_argument('--max', type=int, default=60)
    s = add('name', cmd_name)
    s.add_argument('address')
    s.add_argument('name')
    s.add_argument('--source', required=True)
    s.add_argument('--names-file', required=True)
    s.add_argument('--replace', action='store_true')
    s = add('names', cmd_names)
    s.add_argument('--like')
    s.add_argument('--max', type=int, default=60)
    s = add('disasm', cmd_disasm)
    s.add_argument('func')
    s.add_argument('--reference-root', required=True)
    s.add_argument('--max', type=int, default=120)
    add('stats', cmd_stats)
    add('selftest', cmd_selftest)
    args = p.parse_args(argv)
    return args.fn(args)


if __name__ == '__main__':
    sys.exit(main())
