"""engine: the IW7 engine as data. One command for every agent; answers in seconds without opening Ghidra.

    python -B ops/engine/engine.py <command> ...        (docs/ENGINE.md has the full page)

Find and read
  find TEXT              functions, labels and strings whose name/text contains TEXT (or an address)
  at ADDR                what is at an address: function, label, section, string, known note
  decomp FUNC            decompiled C of a function (Ghidra, exported once for every function)
  disasm FUNC|ADDR       disassembly (capstone, from the analysed image) with names of targets
  callers FUNC / callees FUNC [--depth N]
  xrefs ADDR [--kind read|write|data] [--range N]  code that reads/writes/points at an address (or a range)
  grep REGEX [--in FUNC]  regex over every decompiled function (one line per hit)
  imm VALUE [--disp] [--in FUNC]  instructions with that immediate (or [reg+VALUE] displacement)
  struct NAME            a structure's layout (Ghidra types and the client fork's structs)
  mem ADDR [--type T] [--count N] [--snapshot S]   the value in a memory snapshot of a running game
Knowledge (written back, committed: ops/engine/knowledge/engine-knowledge.json)
  name ADDR NAME [--note TEXT] [--evidence TEXT]   name a function or a global
  note ADDR TEXT [--tag limit] [--value V] [--evidence TEXT]
  notes [--tag T] [--like TEXT]
Maintenance
  index                  build the instruction index (imm/disp) from the image (about a minute)
  status                 what the database holds and how fresh it is

An address is 0x140C18D00, 140C18D00, sub_140C18D00, FUN_140c18d00 or a known name. Add --json for JSON.
"""
import argparse
import bisect
import datetime
import json
import os
import re
import sqlite3
import struct
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
LAB = os.environ.get("IW7_RE_LAB", os.path.join(os.path.expanduser("~"), "Documents", "IW7-RE-Lab"))
DEFAULT_DB = os.path.join(LAB, "engine", "iw7-engine.sqlite")
DEFAULT_INDEX = os.path.join(LAB, "engine", "iw7-insn-index.sqlite")
DEFAULT_IMAGE = os.path.join(LAB, "engine", "image", "iw7_ship_live.exe")
DEFAULT_SNAPSHOTS = os.path.join(LAB, "engine", "snapshots")
DEFAULT_NAMES = os.path.join(LAB, "engine", "names", "names.json")
KNOWLEDGE = os.environ.get("IW7_ENGINE_KNOWLEDGE") or os.path.join(HERE, "knowledge", "engine-knowledge.json")
BASE = 0x140000000


# ---------------------------------------------------------------- image
class Image:
    def __init__(self, path):
        self.path = path
        self.data = open(path, "rb").read()
        pe = struct.unpack_from("<I", self.data, 0x3C)[0]
        n = struct.unpack_from("<H", self.data, pe + 6)[0]
        opt = struct.unpack_from("<H", self.data, pe + 20)[0]
        self.base = struct.unpack_from("<Q", self.data, pe + 24 + 24)[0]
        self.sections = []
        for i in range(n):
            nm, vs, va, rs, ro = struct.unpack_from("<8sIIII", self.data, pe + 24 + opt + 40 * i)
            ch = struct.unpack_from("<I", self.data, pe + 24 + opt + 40 * i + 36)[0]
            self.sections.append((nm.rstrip(b"\0").decode(), self.base + va, vs, ro, rs, ch))

    def section(self, a):
        for s in self.sections:
            if s[1] <= a < s[1] + max(s[2], s[4]):
                return s
        return None

    def read(self, a, n):
        s = self.section(a)
        if not s:
            return None
        off = a - s[1]
        if off >= s[4]:
            return b"\0" * n
        b = self.data[s[3] + off:s[3] + min(off + n, s[4])]
        return b + b"\0" * (n - len(b))

    def code_sections(self):
        return [s for s in self.sections if s[5] & 0x20000000]


# ---------------------------------------------------------------- engine
class Engine:
    def __init__(self, a):
        self.a = a
        self.db = None
        if os.path.exists(a.db):
            self.db = sqlite3.connect(f"file:{a.db}?mode=ro", uri=True)
        self.kn = load_knowledge()
        self._funcs = None
        self._image = None

    # -- data access
    def need_db(self):
        if not self.db:
            die(f"no engine database at {self.a.db}: run ops/engine/Invoke-EngineAnalysis.ps1 (docs/ENGINE.md)")
        return self.db

    @property
    def image(self):
        if self._image is None:
            if not os.path.exists(self.a.image):
                die(f"no analysed image at {self.a.image} (docs/ENGINE.md, 'Build the database')")
            self._image = Image(self.a.image)
        return self._image

    def funcs(self):
        if self._funcs is None:
            rows = self.need_db().execute("SELECT addr,end,name FROM functions ORDER BY addr").fetchall()
            self._funcs = ([r[0] for r in rows], rows)
        return self._funcs

    def func_at(self, a):
        starts, rows = self.funcs()
        i = bisect.bisect_right(starts, a) - 1
        if i >= 0 and a < rows[i][1]:
            return rows[i]
        # Ghidra function bodies may be split: ask the table for a containing range
        return None

    def label(self, a):
        k = self.kn["by_addr"].get(a)
        if k and k.get("name"):
            return k["name"]
        if self.db:
            r = self.db.execute("SELECT name FROM functions WHERE addr=?", (a,)).fetchone()
            if r:
                return r[0]
            r = self.db.execute("SELECT name FROM labels WHERE addr=? LIMIT 1", (a,)).fetchone()
            if r:
                return r[0]
        return None

    def describe(self, a):
        n = self.label(a)
        if n:
            return n
        if self.db:
            f = self.func_at(a)
            if f:
                return f"{self.label(f[0]) or f[2]}+0x{a - f[0]:X}"
        return f"0x{a:X}"

    def resolve(self, text):
        t = text.strip()
        m = re.fullmatch(r"(?:0x)?([0-9A-Fa-f]{6,16})", t) or re.fullmatch(r"(?:sub_|FUN_|DAT_|LAB_)([0-9A-Fa-f]+)", t)
        if m:
            return int(m.group(1), 16)
        m = re.fullmatch(r"\+0x([0-9A-Fa-f]+)", t)
        if m:
            return BASE + int(m.group(1), 16)
        for e in self.kn["entries"]:
            if e.get("name") == t:
                return int(e["address"], 16)
        if self.db:
            r = self.db.execute("SELECT addr FROM functions WHERE name=?", (t,)).fetchone() or \
                self.db.execute("SELECT addr FROM labels WHERE name=?", (t,)).fetchone()
            if r:
                return r[0]
            r = self.db.execute("SELECT addr,name FROM functions WHERE name LIKE ? LIMIT 2", (f"%{t}%",)).fetchall()
            if len(r) == 1:
                return r[0][0]
        die(f"unknown address or name: {text}")

    def func_start(self, a):
        f = self.func_at(a)
        if not f:
            die(f"0x{a:X} is not inside a known function")
        return f


def load_knowledge():
    data = {"schema": "iw7.engine-knowledge/1", "names": [], "notes": []}
    if os.path.exists(KNOWLEDGE):
        data = json.load(open(KNOWLEDGE, encoding="utf-8"))
    by = {}
    for e in data.get("names", []):
        by[int(e["address"], 16)] = e
    entries = data.get("names", [])
    return {"data": data, "by_addr": by, "entries": entries}


def save_knowledge(data):
    os.makedirs(os.path.dirname(KNOWLEDGE), exist_ok=True)
    data["names"].sort(key=lambda e: int(e["address"], 16))
    data["notes"].sort(key=lambda e: (int(e["address"], 16), e.get("date", "")))
    with open(KNOWLEDGE, "w", encoding="utf-8", newline="\n") as f:
        json.dump(data, f, indent=1, ensure_ascii=False)
        f.write("\n")


def die(msg, code=2):
    print(msg, file=sys.stderr)
    sys.exit(code)


def out(a, obj, text_lines):
    if a.json:
        print(json.dumps(obj, indent=1))
    else:
        for line in text_lines:
            print(line)


# ---------------------------------------------------------------- commands
def cmd_find(e, a):
    res = {"functions": [], "labels": [], "strings": [], "knowledge": []}
    q = a.text
    db = e.need_db()
    like = f"%{q}%"
    res["functions"] = [{"addr": f"{r[0]:X}", "name": r[1], "signature": r[2]} for r in db.execute(
        "SELECT addr,name,signature FROM functions WHERE name LIKE ? ORDER BY name LIMIT ?", (like, a.max))]
    res["labels"] = [{"addr": f"{r[0]:X}", "name": r[1]} for r in db.execute(
        "SELECT addr,name FROM labels WHERE name LIKE ? AND addr NOT IN (SELECT addr FROM functions) LIMIT ?", (like, a.max))]
    srows = db.execute("SELECT addr,text FROM strings WHERE text LIKE ? LIMIT ?", (like, a.max)).fetchall()
    for addr, text in srows:
        users = sorted({r[0] for r in db.execute("SELECT src_func FROM refs WHERE dst=? AND src_func IS NOT NULL", (addr,))})
        res["strings"].append({"addr": f"{addr:X}", "text": text, "used_by": [e.describe(u) for u in users[:8]],
                               "users": len(users)})
    res["knowledge"] = [k for k in e.kn["data"].get("names", []) + e.kn["data"].get("notes", [])
                        if q.lower() in json.dumps(k).lower()][:a.max]
    lines = []
    for f in res["functions"]:
        lines.append(f"func   {f['addr']}  {f['name']}   {f['signature']}")
    for l in res["labels"]:
        lines.append(f"label  {l['addr']}  {l['name']}")
    for s in res["strings"]:
        lines.append(f"string {s['addr']}  {s['text'][:90]!r}  used by {s['users']}: {', '.join(s['used_by'])}")
    for k in res["knowledge"]:
        lines.append(f"note   {k['address']}  {k.get('name') or ''} {k.get('note') or k.get('text') or ''}"[:160])
    out(a, res, lines or ["nothing found"])


def cmd_at(e, a):
    addr = e.resolve(a.addr)
    s = e.image.section(addr) if os.path.exists(a.image) else None
    res = {"address": f"{addr:X}", "section": s[0] if s else None, "label": e.label(addr)}
    if e.db:
        f = e.func_at(addr)
        if f:
            res["function"] = {"addr": f"{f[0]:X}", "name": e.label(f[0]) or f[2], "offset": addr - f[0],
                               "end": f"{f[1]:X}"}
        r = e.db.execute("SELECT text FROM strings WHERE addr=?", (addr,)).fetchone()
        if r:
            res["string"] = r[0]
        res["readers"] = e.db.execute("SELECT count(*) FROM refs WHERE dst=?", (addr,)).fetchone()[0]
        res["callers"] = e.db.execute("SELECT count(*) FROM calls WHERE dst=?", (addr,)).fetchone()[0]
    res["notes"] = [n for n in e.kn["data"].get("notes", []) if int(n["address"], 16) == addr]
    lines = [f"{res['address']}  {res.get('label') or ''}  section {res['section']}"]
    if "function" in res:
        fn = res["function"]
        lines.append(f"  in {fn['name']} ({fn['addr']}..{fn['end']}) +0x{fn['offset']:X}")
    if "string" in res:
        lines.append(f"  string {res['string']!r}")
    if e.db:
        lines.append(f"  {res['callers']} call(s) to it, {res['readers']} data reference(s) to it")
    for n in res["notes"]:
        lines.append(f"  note: {n['text']}  [{n.get('evidence', '')}]")
    out(a, res, lines)


def get_decomp(e, faddr):
    r = e.need_db().execute("SELECT ok,code FROM decomp WHERE addr=?", (faddr,)).fetchone()
    if not r:
        return None, False
    return zlib.decompress(r[1]).decode("utf-8", "replace"), bool(r[0])


def cmd_decomp(e, a):
    addr = e.resolve(a.func)
    f = e.func_start(addr)
    code, ok = get_decomp(e, f[0])
    if code is None:
        die(f"{f[2]} is not decompiled yet (the export is resumable: Invoke-EngineAnalysis.ps1 -Step export)", 3)
    notes = [n for n in e.kn["data"].get("notes", []) if f[0] <= int(n["address"], 16) < f[1]]
    header = [f"// {e.label(f[0]) or f[2]} at {f[0]:X}..{f[1]:X}" + ("" if ok else "  (DECOMPILATION FAILED)")]
    header += [f"// note {n['address']}: {n['text']}" for n in notes]
    out(a, {"addr": f"{f[0]:X}", "name": f[2], "ok": ok, "code": code, "notes": notes}, header + [code])


def cmd_callers(e, a, reverse=False):
    addr = e.resolve(a.func)
    db = e.need_db()
    seen = set()
    rows = []

    def walk(target, depth):
        if depth > a.depth:
            return
        if reverse:
            q = db.execute("SELECT dst,count(*),min(at),kind FROM calls WHERE src_func=? GROUP BY dst ORDER BY 2 DESC", (target,))
        else:
            q = db.execute("SELECT src_func,count(*),min(at),kind FROM calls WHERE dst=? GROUP BY src_func ORDER BY 2 DESC", (target,))
        for other, cnt, at, kind in q.fetchall():
            rows.append({"depth": depth, "func": f"{other:X}" if other else None, "name": e.describe(other) if other else "?",
                         "count": cnt, "at": f"{at:X}", "kind": kind})
            if other and other not in seen and len(rows) < a.max:
                seen.add(other)
                walk(other, depth + 1)

    target = addr if reverse else addr
    if reverse:
        target = e.func_start(addr)[0]
    walk(target, 1)
    rows = rows[:a.max]
    out(a, rows, [f"{'  ' * (r['depth'] - 1)}{r['name']}  x{r['count']}  at {r['at']}{'  (tail)' if r['kind'] == 'tail' else ''}"
                  for r in rows] or ["none (calls through registers or tables are not counted)"])


def cmd_xrefs(e, a):
    addr = e.resolve(a.addr)
    rows = []
    if e.db:
        rows = xrefs_from_db(e, a, addr)
    elif not os.path.exists(a.index):
        e.need_db()
    rows += xrefs_from_index(e, a, addr, {r["at"] for r in rows})
    lines = [f"{r['kind']:5} {r['at']}  {r['func']}" + (f"  -> {r['to']}" if a.range > 1 else "") +
             (f"   {r['insn']}" if r.get("insn") else "") for r in rows]
    out(a, rows, lines or ["no reference (try `imm` for the value as a constant)"])


def xrefs_from_db(e, a, addr):
    db = e.db
    q = "SELECT src_func,at,dst,kind FROM refs WHERE dst BETWEEN ? AND ?"
    args = [addr, addr + max(0, a.range - 1)]
    if a.kind:
        q += " AND kind=?"
        args.append(a.kind)
    q += " ORDER BY at LIMIT ?"
    args.append(a.max)
    rows = [{"func": e.describe(r[0]) if r[0] else "?", "at": f"{r[1]:X}", "to": f"{r[2]:X}", "kind": r[3]}
            for r in db.execute(q, args)]
    calls = [{"func": e.describe(r[0]) if r[0] else "?", "at": f"{r[1]:X}", "to": f"{r[2]:X}", "kind": r[3]}
             for r in db.execute("SELECT src_func,at,dst,kind FROM calls WHERE dst=? LIMIT ?", (addr, a.max))]
    return rows + calls


def xrefs_from_index(e, a, addr, known):
    # Forms Ghidra does not turn into references: an RVA in a displacement on an image-base register
    # ([rbx+rax*4+0x60B22F2] with rbx = 0x140000000), and absolute addresses in immediates. Also every
    # rip-relative reference in code Ghidra did not analyse (the protector section). From the instruction index.
    rows = []
    if os.path.exists(a.index):
        idb = sqlite3.connect(f"file:{a.index}?mode=ro", uri=True)
        lo, hi = addr, addr + max(0, a.range - 1)
        extra = idb.execute("SELECT at,func,value,kind,text FROM insn WHERE (kind='disp' AND value BETWEEN ? AND ?) "
                            "OR (kind IN ('addr','imm') AND value BETWEEN ? AND ?) ORDER BY at LIMIT ?",
                            (lo - BASE, hi - BASE, lo, hi, a.max)).fetchall()
        for at, fn, val, kind, text in extra:
            if f"{at:X}" in known:
                continue
            form = "rva" if kind == "disp" else kind
            mnem, _, ops = text.partition(" ")
            if mnem == "lea" or kind == "imm":
                access = "data"
            elif re.match(r"(mov\w*|add|sub|inc|dec|and|or|xor|not|neg|xchg|set\w+|cmpxchg|stos\w*)$", mnem) and \
                    re.match(r"\w+ ptr \[", ops):
                access = "write"
            else:
                access = "read"
            if a.kind and a.kind != access:
                continue
            form = f"{access}/{form}"
            rows.append({"func": e.describe(fn) if e.db else f"{fn:X}", "at": f"{at:X}",
                         "to": f"{(val + BASE if kind == 'disp' else val):X}", "kind": form, "insn": text})
    return rows


def cmd_grep(e, a):
    db = e.need_db()
    rx = re.compile(a.regex, 0 if a.case else re.I)
    hits = []
    if a.inside:
        f = e.func_start(e.resolve(a.inside))
        rows = db.execute("SELECT addr,code FROM decomp WHERE addr=? AND ok=1", (f[0],))
    else:
        rows = db.execute("SELECT addr,code FROM decomp WHERE ok=1")
    for addr, blob in rows:
        code = zlib.decompress(blob).decode("utf-8", "replace")
        if not rx.search(code):
            continue
        for i, line in enumerate(code.splitlines()):
            if rx.search(line):
                hits.append({"func": f"{addr:X}", "name": e.describe(addr), "line": i + 1, "text": line.strip()})
                if len(hits) >= a.max:
                    break
        if len(hits) >= a.max:
            break
    out(a, hits, [f"{h['name']}:{h['line']}: {h['text'][:160]}" for h in hits] or ["no match"])


IMM_RX = re.compile(r"(?<![\w])(-?0x[0-9a-f]+|-?\d+)(?![\w])")


def cmd_index(e, a):
    """Instruction index: every immediate and memory displacement of every instruction in a function."""
    import time
    from capstone import Cs, CS_ARCH_X86, CS_MODE_64
    t0 = time.time()
    img = e.image
    # Ranges: Ghidra's functions when the database exists, else the exception directory (.pdata) entries.
    # Both code sections are covered, the protector's one included (Ghidra may not have analysed all of it).
    ranges = set()
    if e.db:
        ranges |= {(r[0], r[1]) for r in e.db.execute("SELECT addr,end FROM functions ORDER BY addr")}
    for s in img.sections:
        if s[0] == ".pdata":
            raw = img.read(s[1], s[2])
            for k in range(0, len(raw) - 11, 12):
                b, en, _ = struct.unpack_from("<III", raw, k)
                sec = img.section(img.base + b) if b else None
                # a memory capture of .pdata runs past the real table: keep entries inside one code section
                if sec and sec[5] & 0x20000000 and b < en <= b + 0x100000 and img.base + en <= sec[1] + sec[2]:
                    ranges.add((img.base + b, img.base + en))
    starts = sorted({r[0] for r in ranges})
    merged = []
    for b, en in sorted(ranges):
        if merged and b <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], en)
        else:
            merged.append([b, en])
    # Code no function covers (the protector's section is mostly that: moved game code without unwind data):
    # a linear sweep with resynchronisation. Its rows carry the gap start as their "function".
    gaps = []
    for s in img.code_sections():
        cur = s[1]
        for b, en in merged:
            if en <= s[1] or b >= s[1] + s[2]:
                continue
            if b - cur > 16:
                gaps.append([cur, b])
            cur = max(cur, en)
        if s[1] + s[2] - cur > 16:
            gaps.append([cur, s[1] + s[2]])
    starts = sorted(set(starts) | {g[0] for g in gaps})
    ranges = sorted(merged + gaps)
    if os.path.exists(a.index + ".tmp"):
        os.remove(a.index + ".tmp")
    idb = sqlite3.connect(a.index + ".tmp")
    idb.execute("CREATE TABLE insn(value INTEGER, at INTEGER, func INTEGER, kind TEXT, text TEXT)")
    md = Cs(CS_ARCH_X86, CS_MODE_64)
    rows = []
    n = 0
    rip_rx = re.compile(r"rip ([+-]) 0x([0-9a-f]+)")
    for start, end in ranges:
        code = img.read(start, end - start)
        if not code:
            continue
        pos = start
        while pos < end:
            last = pos
            # decode a bounded window: slicing the whole remaining range at every resync point is quadratic
            for at, size, mnem, ops in md.disasm_lite(code[pos - start:pos - start + 0x4000], pos):
                last = at + size
                n += 1
                fn = starts[bisect.bisect_right(starts, at) - 1]
                if not ops:
                    continue
                mem = ops.find("[")
                close = ops.find("]", mem) if mem != -1 else -1
                if mem != -1 and "rip" in ops[mem:close]:
                    m = rip_rx.search(ops)
                    tgt = at + size + (int(m.group(2), 16) * (1 if m.group(1) == "+" else -1) if m else 0)
                    rows.append((tgt, at, fn, "addr", f"{mnem} {ops}"))
                for m in IMM_RX.finditer(ops):
                    if mem != -1 and mem < m.start() < close and "rip" in ops[mem:close]:
                        continue
                    v = int(m.group(1), 0)
                    if v >= 1 << 63:
                        v -= 1 << 64
                    if -2 <= v <= 1 and mnem != "cmp":
                        continue
                    inside = mem != -1 and mem < m.start() < close
                    kind = "disp" if inside else ("addr" if mnem in ("call", "jmp") or (0x140000000 <= v < 0x14D000000) else "imm")
                    rows.append((v, at, fn, kind if kind != "addr" or not inside else "disp", f"{mnem} {ops}"))
                if len(rows) > 200000:
                    idb.executemany("INSERT INTO insn VALUES(?,?,?,?,?)", rows)
                    rows = []
            pos = last + 1 if last < end else end  # undecodable byte: resynchronise one byte further
            if len(rows) > 500000:
                idb.executemany("INSERT INTO insn VALUES(?,?,?,?,?)", rows)
                rows = []
    idb.executemany("INSERT INTO insn VALUES(?,?,?,?,?)", rows)
    idb.execute("CREATE INDEX insn_value ON insn(value, kind)")
    idb.execute("CREATE INDEX insn_func ON insn(func)")
    idb.execute("CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT)")
    idb.execute("INSERT INTO meta VALUES('image', ?)", (img.path,))
    idb.commit()
    idb.close()
    os.replace(a.index + ".tmp", a.index)
    print(f"index: {n} instructions in {len(ranges)} ranges, {time.time() - t0:.1f} s -> {a.index}")


def cmd_imm(e, a):
    if not os.path.exists(a.index):
        die(f"no instruction index at {a.index}: run `engine.py index`")
    idb = sqlite3.connect(f"file:{a.index}?mode=ro", uri=True)
    v = int(a.value, 0)
    if v >= 1 << 63:
        v -= 1 << 64
    kind = "disp" if a.disp else "imm"
    q = "SELECT at,func,text FROM insn WHERE value=? AND kind=?"
    args = [v, kind]
    if a.inside:
        # function bounds: Ghidra's when the database exists, else the index's own function key (pdata start)
        x = e.resolve(a.inside)
        f = e.func_at(x) if e.db else None
        if f:
            q += " AND at>=? AND at<?"
            args += [f[0], f[1]]
        else:
            r = idb.execute("SELECT max(func) FROM (SELECT DISTINCT func FROM insn WHERE func<=? ORDER BY func DESC LIMIT 1)",
                            (x,)).fetchone()
            if not r or r[0] is None:
                die(f"no function known at {a.inside}")
            q += " AND func=?"
            args.append(r[0])
    if a.mnemonic:
        q += " AND text LIKE ?"
        args.append(a.mnemonic + " %")
    q += " ORDER BY at LIMIT ?"
    args.append(a.max)
    rows = [{"at": f"{r[0]:X}", "func": e.describe(r[1]) if e.db else f"{r[1]:X}", "insn": r[2]} for r in idb.execute(q, args)]
    total = idb.execute("SELECT count(*) FROM insn WHERE value=? AND kind=?", (v, kind)).fetchone()[0]
    out(a, {"total": total, "rows": rows}, [f"{r['at']}  {r['insn']:<48} {r['func']}" for r in rows] +
        [f"{total} instruction(s) with {kind} {a.value}" + (f" (showing {len(rows)})" if total > len(rows) else "")])


def cmd_disasm(e, a):
    from capstone import Cs, CS_ARCH_X86, CS_MODE_64
    addr = e.resolve(a.func)
    start, end = addr, addr + 0x200
    if e.db:
        f = e.func_at(addr)
        if f and not a.here:
            start, end = f[0], f[1]
    md = Cs(CS_ARCH_X86, CS_MODE_64)
    lines, rows = [], []
    if a.here or not e.db:
        # The address may fall inside an instruction (an immediate's address, for example): decode from each of
        # the 16 bytes up to it and let the decodings vote for the instruction that holds the address.
        votes = {}
        for back in range(0, 16):
            s0 = addr - back
            for at, size, _, _ in md.disasm_lite(e.image.read(s0, back + 32), s0):
                if at <= addr < at + size:
                    votes[at] = votes.get(at, 0) + 1
                    break
                if at > addr:
                    break
        best = (max(votes.items(), key=lambda kv: (kv[1], -kv[0]))[0], 0) if votes else None
        if best and best[0] != addr:
            lines.append(f"  ({addr:X} is inside the instruction at {best[0]:X}, chosen by {votes[best[0]]} of 16 decodings)")
        start = best[0] if best else addr
        end = max(end, start + 0x200)
    for at, size, mnem, ops in md.disasm_lite(e.image.read(start, end - start), start):
        txt = f"{mnem} {ops}"
        m = re.search(r"rip ([+-]) 0x([0-9a-f]+)", ops)
        target = None
        if m:
            target = at + size + (int(m.group(2), 16) * (1 if m.group(1) == "+" else -1))
        elif mnem in ("call", "jmp") and re.fullmatch(r"0x[0-9a-f]+", ops):
            target = int(ops, 16)
        cmt = ""
        if target is not None:
            cmt = f"  ; {e.describe(target)}"
            if e.db:
                s = e.db.execute("SELECT text FROM strings WHERE addr=?", (target,)).fetchone()
                if s:
                    cmt += f" {s[0][:60]!r}"
        rows.append({"at": f"{at:X}", "insn": txt, "target": f"{target:X}" if target else None})
        mark = ">>" if (a.here or not e.db) and at <= addr < at + size else "  "
        lines.append(f"{mark}{at:X}  {txt:<44}{cmt}")
        if len(rows) >= a.max:
            lines.append("  ... cut (--max)")
            break
    out(a, rows, [f"{e.describe(start)}:"] + lines)


def cmd_struct(e, a):
    res = []
    if e.db:
        for name, cat, kind, size, fields in e.db.execute(
                "SELECT name,category,kind,size,fields FROM types WHERE name LIKE ? LIMIT 20", (a.name,)):
            res.append({"name": name, "source": "ghidra " + cat, "kind": kind, "size": size, "fields": json.loads(fields)})
    if os.path.exists(a.names):
        for s in json.load(open(a.names, encoding="utf-8")).get("structs", []):
            if re.fullmatch(a.name.replace("%", ".*"), s["name"], re.I):
                res.append({"name": s["name"], "source": s.get("source", "fork"), "kind": "struct", "size": s.get("size"),
                            "fields": s.get("fields", []), "note": s.get("note")})
    for k in e.kn["data"].get("names", []):
        if k.get("kind") == "struct" and re.fullmatch(a.name.replace("%", ".*"), k["name"], re.I):
            res.append({"name": k["name"], "source": "knowledge", "kind": "struct", "size": k.get("size"),
                        "fields": k.get("fields", []), "note": k.get("note")})
    lines = []
    for s in res:
        lines.append(f"{s['kind']} {s['name']}  size {s['size']}  ({s['source']})" + (f"  note: {s['note']}" if s.get("note") else ""))
        for fl in s["fields"]:
            off = fl.get("offset")
            lines.append(f"  +{off:#06x}  {fl.get('type', '')} {fl.get('name')}" if isinstance(off, int) else
                         f"  +?       {fl.get('type', '')} {fl.get('name')}")
    out(a, res, lines or ["no structure by that name"])


TYPES = {"u8": "<B", "i8": "<b", "u16": "<H", "i16": "<h", "u32": "<I", "i32": "<i", "u64": "<Q", "i64": "<q",
         "f32": "<f", "f64": "<d", "ptr": "<Q"}


def snapshot_reader(path):
    meta = json.load(open(os.path.join(path, "sections.json")))
    secs = []
    for s in meta["sections"]:
        va = int(s["va"], 16)
        secs.append((va, va + s["bytes"], os.path.join(path, f"{va:X}.bin")))

    dump = meta.get("dump")
    md_reader = []

    def read(a, n):
        for lo, hi, f in secs:
            if lo <= a and a + n <= hi:
                with open(f, "rb") as fh:
                    fh.seek(a - lo)
                    return fh.read(n)
        # Outside the module: the heap, zones, dvars. Read the full-memory dump the snapshot was made from.
        if dump and os.path.exists(dump):
            if not md_reader:
                from minidump.minidumpfile import MinidumpFile
                md_reader.append(MinidumpFile.parse(dump).get_reader())
            try:
                return md_reader[0].read(a, n)
            except Exception:
                return None
        return None
    return meta, read


def cmd_mem(e, a):
    snaps = sorted(os.listdir(a.snapshots)) if os.path.isdir(a.snapshots) else []
    if not snaps:
        die(f"no memory snapshot in {a.snapshots} (docs/ENGINE.md, 'Memory snapshots')")
    snap = a.snapshot or snaps[-1]
    meta, read = snapshot_reader(os.path.join(a.snapshots, snap))
    expr = a.addr
    # [X]+off chains: [0x143C986B8]+0x546
    def ev(x):
        x = x.strip()
        m = re.fullmatch(r"\[(.+)\]([+-]0x[0-9A-Fa-f]+|[+-]\d+)?", x)
        if m:
            p = ev(m.group(1))
            b = read(p, 8)
            if b is None:
                die(f"0x{p:X} is not in the snapshot")
            return struct.unpack("<Q", b)[0] + (int(m.group(2), 0) if m.group(2) else 0)
        m = re.fullmatch(r"(.+?)([+-]0x[0-9A-Fa-f]+)", x)
        if m and not re.fullmatch(r"(?:0x)?[0-9A-Fa-f]+", x):
            return ev(m.group(1)) + int(m.group(2), 0)
        return e.resolve(x)
    addr = ev(expr)
    if a.type == "str":
        b = read(addr, 256) or b""
        s = b.split(b"\0")[0].decode("latin-1")
        out(a, {"snapshot": snap, "address": f"{addr:X}", "type": "str", "values": [s]},
            [f"{addr:X} ({e.describe(addr)}) str = {s!r}   [snapshot {snap}]"])
        return
    fmt = TYPES[a.type]
    size = struct.calcsize(fmt)
    vals = []
    for i in range(a.count):
        b = read(addr + i * size, size)
        if b is None:
            die(f"0x{addr + i * size:X} is not in snapshot {snap} (a snapshot from a live server holds the iw7_ship.exe module only; one made from a full-memory dump reads everything)")
        v = struct.unpack(fmt, b)[0]
        vals.append(v)
    res = {"snapshot": snap, "source": meta.get("dump") or meta.get("source"), "address": f"{addr:X}", "type": a.type, "values": vals}
    shown = [f"0x{v:X}" if a.type == "ptr" else str(v) for v in vals]
    out(a, res, [f"{addr:X} ({e.describe(addr)}) {a.type} = {' '.join(shown)}   [snapshot {snap}]"])


def today():
    return datetime.date.today().isoformat()


def cmd_name(e, a):
    addr = e.resolve(a.addr)
    data = e.kn["data"]
    for k in data["names"]:
        if k["name"] == a.name and int(k["address"], 16) != addr and not a.replace:
            die(f"{a.name} already names {k['address']} (use --replace)")
    data["names"] = [k for k in data["names"] if int(k["address"], 16) != addr and not (a.replace and k["name"] == a.name)]
    entry = {"address": f"{addr:X}", "name": a.name, "kind": a.kind, "by": a.by, "date": today()}
    if a.note:
        entry["note"] = a.note
    if a.evidence:
        entry["evidence"] = a.evidence
    data["names"].append(entry)
    save_knowledge(data)
    print(f"named {addr:X} {a.name} in {os.path.relpath(KNOWLEDGE)} (Ghidra gets it at the next analyze step)")


def cmd_note(e, a):
    addr = e.resolve(a.addr)
    data = e.kn["data"]
    entry = {"address": f"{addr:X}", "text": a.text, "by": a.by, "date": today()}
    for k in ("tag", "value", "evidence"):
        if getattr(a, k):
            entry[k] = getattr(a, k)
    data["notes"].append(entry)
    save_knowledge(data)
    print(f"note added at {addr:X} ({e.describe(addr)})")


def cmd_notes(e, a):
    rows = []
    for n in e.kn["data"].get("notes", []) + e.kn["data"].get("names", []):
        if a.tag and n.get("tag") != a.tag:
            continue
        if a.like and a.like.lower() not in json.dumps(n).lower():
            continue
        rows.append(n)
    out(a, rows, [f"{n['address']}  {n.get('name') or ''}{' [' + n['tag'] + ']' if n.get('tag') else ''}  "
                  f"{n.get('text') or n.get('note') or ''}" + (f"  = {n['value']}" if n.get("value") else "") for n in rows]
        or ["no notes"])


def cmd_status(e, a):
    res = {"db": a.db, "index": a.index, "image": a.image, "knowledge": KNOWLEDGE}
    if e.db:
        for t in ("functions", "calls", "refs", "strings", "labels", "types"):
            res[t] = e.db.execute(f"SELECT count(*) FROM {t}").fetchone()[0]
        res["decompiled_ok"] = e.db.execute("SELECT count(*) FROM decomp WHERE ok=1").fetchone()[0]
        res["decompiled_failed"] = e.db.execute("SELECT count(*) FROM decomp WHERE ok=0").fetchone()[0]
        res["meta"] = dict(e.db.execute("SELECT key,value FROM meta").fetchall())
    res["knowledge_names"] = len(e.kn["data"].get("names", []))
    res["knowledge_notes"] = len(e.kn["data"].get("notes", []))
    res["snapshots"] = sorted(os.listdir(a.snapshots)) if os.path.isdir(a.snapshots) else []
    out(a, res, [f"{k}: {v}" for k, v in res.items()])


def main(argv=None):
    ap = argparse.ArgumentParser(prog="engine", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--db", default=os.environ.get("IW7_ENGINE_DB", DEFAULT_DB))
    ap.add_argument("--index", default=DEFAULT_INDEX)
    ap.add_argument("--image", default=DEFAULT_IMAGE)
    ap.add_argument("--snapshots", default=DEFAULT_SNAPSHOTS)
    ap.add_argument("--names", default=DEFAULT_NAMES)
    ap.add_argument("--json", action="store_true")
    sp = ap.add_subparsers(dest="cmd", required=True)

    def p(name, fn, *args, **kw):
        x = sp.add_parser(name, help=kw.pop("help", None))
        x.set_defaults(fn=fn)
        x.add_argument("--json", action="store_true", default=argparse.SUPPRESS)
        for arg in args:
            x.add_argument(arg)
        return x

    x = p("find", cmd_find, "text"); x.add_argument("--max", type=int, default=25)
    p("at", cmd_at, "addr")
    p("decomp", cmd_decomp, "func")
    x = p("disasm", cmd_disasm, "func"); x.add_argument("--max", type=int, default=200); x.add_argument("--here", action="store_true")
    for nm in ("callers", "callees"):
        x = p(nm, (lambda e, a: cmd_callers(e, a, False)) if nm == "callers" else (lambda e, a: cmd_callers(e, a, True)), "func")
        x.add_argument("--depth", type=int, default=1); x.add_argument("--max", type=int, default=60)
    x = p("xrefs", cmd_xrefs, "addr"); x.add_argument("--kind", choices=["read", "write", "data"])
    x.add_argument("--range", type=lambda s: int(s, 0), default=1); x.add_argument("--max", type=int, default=200)
    x = p("grep", cmd_grep, "regex"); x.add_argument("--in", dest="inside"); x.add_argument("--max", type=int, default=100)
    x.add_argument("--case", action="store_true")
    x = p("imm", cmd_imm, "value"); x.add_argument("--disp", action="store_true"); x.add_argument("--in", dest="inside")
    x.add_argument("--mnemonic"); x.add_argument("--max", type=int, default=100)
    p("struct", cmd_struct, "name")
    x = p("mem", cmd_mem, "addr"); x.add_argument("--type", choices=sorted(TYPES) + ["str"], default="u32")
    x.add_argument("--count", type=int, default=1); x.add_argument("--snapshot")
    x = p("name", cmd_name, "addr", "name"); x.add_argument("--note"); x.add_argument("--evidence")
    x.add_argument("--kind", default="function", choices=["function", "data", "struct"]); x.add_argument("--replace", action="store_true")
    x.add_argument("--by", default=os.environ.get("IW7_AGENT", "agent"))
    x = p("note", cmd_note, "addr", "text"); x.add_argument("--tag"); x.add_argument("--value"); x.add_argument("--evidence")
    x.add_argument("--by", default=os.environ.get("IW7_AGENT", "agent"))
    x = p("notes", cmd_notes); x.add_argument("--tag"); x.add_argument("--like")
    p("index", cmd_index)
    p("status", cmd_status)
    a = ap.parse_args(argv)
    e = Engine(a)
    a.fn(e, a)


if __name__ == "__main__":
    main()
