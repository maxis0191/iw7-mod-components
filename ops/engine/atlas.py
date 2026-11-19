"""atlas: three lookup tables derived once from the engine database (docs/ENGINE.md, "Atlases").

    limits.json    every message where the engine refuses because something is full / too many, with its guarding condition
    dvars.json     every console variable registered in decompiled code, with default/min/max, pointer and readers
    builtins.json  every script-callable native function (GScr_, PlayerCmd_, ...) with the strings it uses

Pure functions over an open sqlite connection (tables functions, strings, refs, calls, decomp); engine.py owns the commands.
The generated files hold game text and stay outside the repository.
"""
import json
import os
import re
import struct
import time
import zlib

ATLAS_FILES = {"limits": "limits.json", "dvars": "dvars.json", "builtins": "builtins.json"}

LIMIT_RX = re.compile(r"exceed|too many|overflow|out of (memory|space|range|room|[a-z]+ ?entities)|max(imum)?\b|limit|"
                      r"no free|ran out|cannot allocate|is full|no more", re.I)
COND_RX = re.compile(r"\b(if|while)\s*\(")
INT_RX = re.compile(r"(?<![\w.])(0x[0-9a-fA-F]+|\d+)(?![\w.])")
DAT_RX = re.compile(r"(?<![\w])_?DAT_([0-9a-fA-F]+)")
DVAR_RX = re.compile(r'(_?DAT_[0-9a-f]+|\w+)\s*=\s*(Dvar_Register\w+)\(\s*"([^"]+)"\s*,([^;]*)\);')

BUILTIN_PREFIXES = ("GScr_", "Scr_", "ScrCmd_", "PlayerCmd_", "ScriptEntCmd_", "ScriptVehicleCmd_", "ActorCmd_",
                    "HECmd_", "BotCmd_", "VehicleCmd_", "Scriptable_Cmd", "ScrVehicle_")


def decomp_of(db, addr):
    r = db.execute("SELECT ok,code FROM decomp WHERE addr=?", (addr,)).fetchone()
    if not r or not r[1]:
        return None
    return zlib.decompress(r[1]).decode("utf-8", "replace")


def string_ref_map(db, strings):
    """{ref target: string index}: references hit the string address, or the byte before it (a stripped leading byte)."""
    exact = {a: i for i, (a, _) in enumerate(strings)}
    m = dict(exact)
    for a, i in exact.items():
        if a - 1 not in exact:
            m.setdefault(a - 1, i)
    return m


def func_names(db):
    return {a: n for a, n in db.execute("SELECT addr,name FROM functions")}


# ---------------------------------------------------------------- limits
def condition_for(code, text, saddr):
    """(condition line or None): the nearest `if (`/`while (` at or above (<= 40 lines) the first line naming the string."""
    lines = code.splitlines()
    keys = [text[:24], f"DAT_{saddr:x}", f"DAT_{saddr - 1:x}"]
    for i, line in enumerate(lines):
        if any(k in line for k in keys):
            for j in range(i, max(-1, i - 41), -1):
                if COND_RX.search(lines[j]):
                    return lines[j].strip()[:200]
            return None
    return None


def condition_facts(cond):
    if not cond:
        return [], []
    consts = []
    for m in INT_RX.finditer(cond):
        v = int(m.group(1), 0)
        if v not in (0, 1) and v not in consts:
            consts.append(v)
    globs = []
    for m in DAT_RX.finditer(cond):
        v = int(m.group(1), 16)
        if v not in globs:
            globs.append(v)
    return consts, globs


def build_limits(db):
    strings = db.execute("SELECT addr,text FROM strings").fetchall()
    cands = [(a, t) for a, t in strings if t.count(" ") >= 2 and LIMIT_RX.search(t)]
    refmap = string_ref_map(db, cands)
    users = {}
    for src, dst in db.execute("SELECT src_func,dst FROM refs WHERE src_func IS NOT NULL"):
        i = refmap.get(dst)
        if i is not None:
            users.setdefault(i, set()).add(src)
    names = func_names(db)
    funcs = {f for s in users.values() for f in s}
    callers = {}
    for src, dst in db.execute("SELECT src_func,dst FROM calls"):
        if dst in funcs:
            callers.setdefault(dst, set()).add(src)
    records = []
    code_cache = {}
    for i, (saddr, text) in enumerate(cands):
        for f in sorted(users.get(i, ())):
            if f not in code_cache:
                code_cache[f] = decomp_of(db, f)
            code = code_cache[f]
            cond = condition_for(code, text, saddr) if code else None
            consts, globs = condition_facts(cond)
            records.append({"text": text, "string_addr": f"{saddr:X}",
                            "function": {"addr": f"{f:X}", "name": names.get(f, f"FUN_{f:x}")},
                            "condition": cond, "constants": consts, "globals": [f"{g:X}" for g in globs],
                            "callers": len(callers.get(f, ()))})
        if len(code_cache) > 400:
            code_cache.clear()
    return records


# ---------------------------------------------------------------- dvars
def split_args(s):
    out, depth, cur, q = [], 0, "", False
    for ch in s:
        if ch == '"':
            q = not q
        if not q and ch in "([":
            depth += 1
        elif not q and ch in ")]":
            depth -= 1
        if ch == "," and depth == 0 and not q:
            out.append(cur.strip())
            cur = ""
        else:
            cur += ch
    if cur.strip():
        out.append(cur.strip())
    return out


def parse_float(tok):
    t = tok.strip().lstrip("(").rstrip(")")
    m = re.fullmatch(r"(?:\(\w+\))?\s*0x([0-9a-fA-F]{8})", t)
    if m:
        v = struct.unpack("<f", struct.pack("<I", int(m.group(1), 16)))[0]
        return float(f"{v:.7g}")
    try:
        return float(t.rstrip("f"))
    except ValueError:
        return None


def parse_int(tok):
    t = tok.strip()
    t = re.sub(r"^\((?:u?int|u?long|u?longlong|undefined\d?)\)\s*", "", t).strip("() ")
    try:
        v = int(t, 0)
    except ValueError:
        return None
    return v - (1 << 32) if v >= 1 << 31 and re.fullmatch(r"0x[0-9a-fA-F]{8}", t) else v


def dvar_values(kind, args):
    rest = split_args(args)
    vals = {"default": None, "min": None, "max": None}
    if kind == "Float":
        parse = parse_float
    elif kind == "Int":
        parse = parse_int
    elif kind == "Bool":
        vals["default"] = parse_int(rest[0]) if rest else None
        return vals
    else:
        return vals
    for key, tok in zip(("default", "min", "max"), rest[:3]):
        vals[key] = parse(tok)
    return vals


def build_dvars(db):
    names = func_names(db)
    records = []
    for addr, blob in db.execute("SELECT addr,code FROM decomp WHERE ok=1"):
        raw = zlib.decompress(blob)
        if b"Dvar_Register" not in raw:
            continue
        code = raw.decode("utf-8", "replace")
        for m in DVAR_RX.finditer(code):
            left, reg, name, args = m.groups()
            kind = reg[len("Dvar_Register"):]
            pm = re.fullmatch(r"_?DAT_([0-9a-f]+)", left)
            rec = {"name": name, "kind": kind, "args": args.strip()[:160], "pointer": f"{int(pm.group(1), 16):X}" if pm else None,
                   "registered_in": {"addr": f"{addr:X}", "name": names.get(addr, f"FUN_{addr:x}")}}
            rec.update(dvar_values(kind, args))
            records.append(rec)
    ptrs = {int(r["pointer"], 16) for r in records if r["pointer"]}
    readers = {}
    for src, dst, kind in db.execute("SELECT src_func,dst,kind FROM refs WHERE src_func IS NOT NULL"):
        if dst in ptrs:
            readers.setdefault(dst, {}).setdefault(src, set()).add(kind)
    for r in records:
        rd = readers.get(int(r["pointer"], 16), {}) if r["pointer"] else {}
        real = {f: k for f, k in rd.items() if k - {"write"}}
        ordered = sorted(real, key=lambda f: (names.get(f, "FUN_").startswith("FUN_"), names.get(f, ""), f))
        r["reader_count"] = len(ordered)
        r["readers"] = [{"function": f"{f:X}", "name": names.get(f, f"FUN_{f:x}"), "kind": "/".join(sorted(real[f]))}
                        for f in ordered[:40]]
    return records


# ---------------------------------------------------------------- builtins
def build_builtins(db):
    funcs = [(a, n, e - a) for a, n, e in db.execute("SELECT addr,name,end FROM functions") if n.startswith(BUILTIN_PREFIXES)]
    fset = {a for a, _, _ in funcs}
    strings = db.execute("SELECT addr,text FROM strings").fetchall()
    refmap = string_ref_map(db, strings)
    used = {}
    for src, dst in db.execute("SELECT src_func,dst FROM refs WHERE src_func IS NOT NULL"):
        if src in fset:
            i = refmap.get(dst)
            if i is not None:
                used.setdefault(src, [])
                if i not in used[src]:
                    used[src].append(i)
    records = []
    for a, n, size in sorted(funcs, key=lambda x: x[1]):
        prefix = next(p for p in BUILTIN_PREFIXES if n.startswith(p))
        kind = "function" if prefix in ("GScr_", "Scr_") else "method"
        records.append({"script_name": n[len(prefix):].lower(), "kind": kind,
                        "native": {"name": n, "addr": f"{a:X}", "size": size},
                        "strings": [strings[i][1][:80] for i in used.get(a, [])[:6]]})
    return records


BUILDERS = {"limits": build_limits, "dvars": build_dvars, "builtins": build_builtins}


# ---------------------------------------------------------------- files
def atlas_dir(a):
    return a.atlas or os.path.join(os.path.dirname(os.path.abspath(a.db)), "atlas")


def build(db, folder, which=None):
    os.makedirs(folder, exist_ok=True)
    stats = {}
    for name in which or ATLAS_FILES:
        t0 = time.time()
        recs = BUILDERS[name](db)
        path = os.path.join(folder, ATLAS_FILES[name])
        with open(path + ".tmp", "w", encoding="utf-8", newline="\n") as f:
            json.dump({"schema": f"iw7.atlas.{name}/1", "records": recs}, f, ensure_ascii=False)
        os.replace(path + ".tmp", path)
        stats[name] = {"records": len(recs), "seconds": round(time.time() - t0, 1), "path": path}
    return stats


def load(db, folder, name, say=print):
    path = os.path.join(folder, ATLAS_FILES[name])
    if not os.path.exists(path):
        say(f"{path} is absent: building the {name} atlas (first use)")
        build(db, folder, [name])
    with open(path, encoding="utf-8") as f:
        return json.load(f)["records"]


# ---------------------------------------------------------------- queries
def hexes(vals):
    return ", ".join(f"{v} (0x{v:X})" for v in vals)


def query_limits(recs, text, mx):
    if not text:
        top = sorted(recs, key=lambda r: -r["callers"])[:30]
        lines = [f"{len(recs)} limit messages; the 30 whose function has the most callers:"]
        return top, lines + [limit_line(r) for r in top]
    q = text.lower()
    hits = [r for r in recs if q in r["text"].lower() or q in r["function"]["name"].lower() or q in (r["condition"] or "").lower()]
    hits = hits[:mx]
    lines = []
    for r in hits:
        lines.append(limit_line(r))
        lines.append(f"    condition: {r['condition']}")
        if r["constants"]:
            lines.append(f"    constants: {hexes(r['constants'])}")
        if r["globals"]:
            lines.append(f"    globals:   {', '.join('0x' + g for g in r['globals'])}")
        lines.append(f"    next: engine.py decomp 0x{r['function']['addr']}")
    return hits, lines or ["no limit message matches"]


def limit_line(r):
    return f"{r['text'][:100]!r}  {r['function']['name']} at 0x{r['function']['addr']} ({r['callers']} callers)"


def query_dvars(recs, text, mx):
    q = text.lower()
    hits = [r for r in recs if q in r["name"].lower()][:mx]
    lines = []
    for r in hits:
        vals = "  ".join(f"{k} {r[k]}" for k in ("default", "min", "max") if r.get(k) is not None)
        lines.append(f"{r['name']}  [{r['kind']}]  {vals}".rstrip())
        lines.append(f"    pointer {'0x' + r['pointer'] if r['pointer'] else 'none'}   registered in "
                     f"{r['registered_in']['name']} at 0x{r['registered_in']['addr']}")
        shown = ", ".join(x["name"] for x in r["readers"][:12])
        lines.append(f"    {r['reader_count']} reading function(s): {shown}")
        if r["pointer"]:
            lines.append(f"    next: engine.py xrefs 0x{r['pointer']}")
    return hits, lines or ["no console variable matches"]


def query_builtins(recs, text, mx):
    q = text.lower()
    hits = [r for r in recs if q in r["script_name"]][:mx]
    lines = []
    for r in hits:
        n = r["native"]
        lines.append(f"{r['script_name']}  [{r['kind']}]  {n['name']} at 0x{n['addr']} (size {n['size']})")
        for s in r["strings"]:
            lines.append(f"    {s!r}")
        lines.append(f"    next: engine.py decomp 0x{n['addr']}")
    return hits, lines or ["no script builtin matches"]
