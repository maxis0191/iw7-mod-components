"""Collect every name the project knows for addresses in iw7_ship.exe.

Python 3.12, standard library only. Run with `python -I collect_names.py ...`.
Reads the sources (never writes them) and writes one JSON file, schema
`iw7.engine-names/1`, that the Ghidra import consumes.

Sources, by priority (first one wins an address, the others become aliases):
  1. symbols.hpp   client fork symbol table (WEAK symbol<type> Name{0x14...};)
  2. gsc-idc       "iw7 label GSC builtins.idc"  (LabelFunction("GScr_%s", "abs", 0x...);)
  3. lua-idc       "iw7 label LUA builtins.idc"  (tables of {name*, fn} read from .rdata)
  4. csv           name,address rows (--csv, repeatable)
  5. fork-src      every other 0x14xxxxxxx constant under src/client (hook_<stem>_<hex>)
Structs come from structs.hpp (offsets only when they can be computed with certainty).

--native-root is the fork's `native` folder (the one that holds src/ and ida_scripts/).
"""
from __future__ import annotations

import argparse
import bisect
import hashlib
import json
import os
import re
import struct
import sys
import time

SCHEMA = "iw7.engine-names/1"
IMAGE_BASE = 0x140000000
RDATA_BASE_DEFAULT = 0x141435000

SYMBOLS_REL = "src/client/game/symbols.hpp"
STRUCTS_REL = "src/client/game/structs.hpp"
GSC_IDC_REL = "ida_scripts/iw7 label GSC builtins.idc"
LUA_IDC_REL = "ida_scripts/iw7 label LUA builtins.idc"
FORK_SRC_REL = "src/client"

PRIORITY = ["symbols.hpp", "gsc-idc", "lua-idc", "csv", "fork-src"]


# --------------------------------------------------------------------------- helpers

def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def read_text(path: str) -> str:
    with open(path, "rb") as f:
        return f.read().decode("utf-8-sig", errors="replace")


def norm_addr(value) -> str | None:
    """Return the address as upper-case hex without 0x, or None when not an address."""
    if isinstance(value, int):
        return format(value, "X")
    s = str(value).strip()
    if s[:2].lower() == "0x":
        s = s[2:]
    if not s or not re.fullmatch(r"[0-9A-Fa-f]{1,16}", s):
        return None
    return format(int(s, 16), "X")


def strip_comments(text: str) -> str:
    """Blank out // and /* */ comments (newlines kept so line numbers stay valid)."""
    out = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == '"' or c == "'":
            j = i + 1
            while j < n and text[j] != c and text[j] != "\n":
                j += 2 if text[j] == "\\" else 1
            out.append(text[i:j + 1])
            i = j + 1
        elif text.startswith("//", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i))
            i = j
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append("".join("\n" if ch == "\n" else " " for ch in text[i:j]))
            i = j
        else:
            out.append(c)
            i += 1
    return "".join(out)


def line_of(text: str, pos: int) -> int:
    return text.count("\n", 0, pos) + 1


def squash(s: str) -> str:
    return re.sub(r"\s+", " ", s).strip()


# --------------------------------------------------------------------------- 1. symbols.hpp

SYM_RE = re.compile(
    r"WEAK\s+symbol<([^;{}]*)>\s*(\w+)\s*\{\s*(0[xX][0-9A-Fa-f]+)\s*\}\s*;")


def _enclosing_namespaces(clean: str):
    """Return a function pos -> tuple of enclosing namespace names (excluding 'game')."""
    events = []  # (pos, depth_change, ns or None)
    stack = []
    ns_re = re.compile(r"\bnamespace\s+(\w+)\s*\{")
    spans = []  # (start, end, name)
    i = 0
    brace_stack = []  # (is_ns, name, start)
    tokens = re.finditer(r"\bnamespace\s+(\w+)\s*\{|\{|\}", clean)
    for m in tokens:
        t = m.group(0)
        if t == "}":
            if brace_stack:
                is_ns, name, start = brace_stack.pop()
                if is_ns:
                    spans.append((start, m.start(), name))
        elif t == "{":
            brace_stack.append((False, None, m.start()))
        else:
            brace_stack.append((True, m.group(1), m.start()))
    spans.sort()

    def at(pos):
        return tuple(n for s, e, n in spans if s <= pos < e and n != "game")
    return at


def sym_function_kind(type_str: str) -> bool:
    """True when the symbol<> template argument is a function type."""
    t = type_str.strip()
    if not t.endswith(")"):
        return False
    # function pointer / pointer-to-array data such as `void(*)[2]` is rare; a function type
    # has its parameter list as the last parenthesised group
    depth = 0
    for idx in range(len(t) - 1, -1, -1):
        if t[idx] == ")":
            depth += 1
        elif t[idx] == "(":
            depth -= 1
            if depth == 0:
                head = t[:idx].strip()
                return bool(head) and not head.endswith("*)") and not head.endswith("(")
    return False


def sym_declaration(type_str: str, name: str, is_func: bool) -> str:
    t = squash(type_str)
    if not is_func:
        return f"{t} {name}"
    depth = 0
    for idx in range(len(t) - 1, -1, -1):
        if t[idx] == ")":
            depth += 1
        elif t[idx] == "(":
            depth -= 1
            if depth == 0:
                ret = t[:idx].strip()
                return f"{ret} {name}{t[idx:]}"
    return f"{t} {name}"


def parse_symbols(text: str):
    """-> (entries, stats). entries: list of dict(address,name,kind,type)."""
    clean = strip_comments(text)
    at_ns = _enclosing_namespaces(clean)
    entries = []
    covered = set()
    for m in SYM_RE.finditer(clean):
        type_str, name, addr_s = m.group(1), m.group(2), m.group(3)
        addr = norm_addr(addr_s)
        if addr is None:
            continue
        ns = at_ns(m.start())
        full = "::".join(ns + (name,)) if ns else name
        is_func = sym_function_kind(type_str)
        entries.append({
            "address": addr, "name": full, "kind": "function" if is_func else "data",
            "type": sym_declaration(type_str, name, is_func),
        })
        l0, l1 = line_of(clean, m.start()), line_of(clean, m.end())
        covered.update(range(l0, l1 + 1))
    unparsed = []
    for ln, line in enumerate(clean.split("\n"), 1):
        if ("symbol<" in line or re.search(r"0[xX]14[0-9A-Fa-f]{7}", line)) and ln not in covered \
                and not line.lstrip().startswith("#"):
            unparsed.append((ln, squash(line)))
    decls = len(re.findall(r"\bWEAK\s+symbol<", clean))
    stats = {"declarations": decls, "parsed": len(entries),
             "unparsed_lines": len(unparsed), "unparsed_samples": unparsed[:10]}
    return entries, stats


# --------------------------------------------------------------------------- 2. gsc idc

GSC_RE = re.compile(
    r'^\s*LabelFunction\(\s*"([^"]*)"\s*,\s*"([^"]*)"\s*,\s*(0[xX][0-9A-Fa-f]+)\s*\)\s*;')


def parse_gsc_idc(text: str):
    entries = []
    unparsed = []
    skipped = 0
    prefix_counts = {}
    for ln, line in enumerate(text.split("\n"), 1):
        s = line.strip()
        if re.match(r"//\s*skipped\b", s):
            skipped += 1
            continue
        if not s.startswith("LabelFunction("):
            continue
        m = GSC_RE.match(line)
        if not m:
            unparsed.append((ln, s))
            continue
        prefix, name, addr_s = m.groups()
        addr = norm_addr(addr_s)
        if addr is None or "%s" not in prefix:
            unparsed.append((ln, s))
            continue
        entries.append({"address": addr, "name": prefix.replace("%s", name), "kind": "function"})
        prefix_counts[prefix] = prefix_counts.get(prefix, 0) + 1
    stats = {"parsed": len(entries), "skipped_nullptr": skipped,
             "unparsed_lines": len(unparsed), "unparsed_samples": unparsed[:10],
             "per_prefix": prefix_counts}
    return entries, stats


# --------------------------------------------------------------------------- 3. lua idc

LUA_TABLE_RE = re.compile(r"^\s*LabelFunctions\(\s*(0[xX][0-9A-Fa-f]+)\s*\)\s*;")
LUA_PREFIX_RE = re.compile(r'form\(\s*"([^"]*%s[^"]*)"\s*,\s*name\s*\)')


class Rdata:
    def __init__(self, data: bytes, base: int):
        self.data, self.base = data, base

    def u64(self, ea: int):
        o = ea - self.base
        if o < 0 or o + 8 > len(self.data):
            return None
        return struct.unpack_from("<Q", self.data, o)[0]

    def cstr(self, ea: int):
        o = ea - self.base
        if o < 0 or o >= len(self.data):
            return None
        end = self.data.find(b"\x00", o, o + 512)
        if end < 0:
            return None
        return self.data[o:end].decode("latin-1")


def parse_lua_idc(text: str, rdata: Rdata, max_entries: int = 4096):
    pm = LUA_PREFIX_RE.search(text)
    prefix = pm.group(1) if pm else "LUI_CoD_LuaCall_%s"
    lines = text.split("\n")
    entries = []
    tables = []
    unparsed = []
    for ln, line in enumerate(lines, 1):
        s = line.strip()
        if s.startswith("LabelFunctions(") and not LUA_TABLE_RE.match(line):
            unparsed.append((ln, s))
            continue
        m = LUA_TABLE_RE.match(line)
        if not m:
            continue
        table_ea = int(m.group(1), 16)
        label = ""
        if ln >= 2:
            prev = lines[ln - 2].strip()
            if prev.startswith("//"):
                label = prev[2:].strip()
        cur, count, sub_names, bad = table_ea, 0, 0, 0
        stop = "terminator"
        while True:
            name_ptr = rdata.u64(cur)
            if name_ptr is None:
                stop = "end of rdata file"
                break
            if name_ptr == 0 or name_ptr == 0xFFFFFFFFFFFFFFFF:
                break
            fn = rdata.u64(cur + 8)
            if fn is None:
                stop = "end of rdata file"
                break
            if count >= max_entries:
                stop = "max entries"
                break
            cur += 16
            if fn in (0, 0xFFFFFFFFFFFFFFFF):
                bad += 1
                continue
            name = rdata.cstr(name_ptr)
            if not name:
                name = "sub_%X" % fn
                sub_names += 1
            count += 1
            entries.append({"address": norm_addr(fn), "name": prefix.replace("%s", name),
                            "kind": "function", "table": label or ("0x%X" % table_ea)})
        tables.append({"table": label or ("0x%X" % table_ea), "address": "%X" % table_ea,
                       "entries": count, "invalid_fn": bad, "sub_names": sub_names, "stop": stop})
    stats = {"parsed": len(entries), "tables": tables, "unparsed_lines": len(unparsed),
             "unparsed_samples": unparsed[:10]}
    return entries, stats


# --------------------------------------------------------------------------- 6. csv

def parse_csv(text: str):
    entries, unparsed = [], []
    for ln, line in enumerate(text.split("\n"), 1):
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        parts = [p.strip().strip('"') for p in s.split(",")]
        if len(parts) < 2:
            unparsed.append((ln, s))
            continue
        addr = norm_addr(parts[1])
        if addr is None or not parts[0]:
            if ln == 1 and parts[0].lower() in ("name", "symbol"):
                continue  # header row
            unparsed.append((ln, s))
            continue
        entries.append({"address": addr, "name": parts[0], "kind": "function"})
    return entries, {"parsed": len(entries), "unparsed_lines": len(unparsed),
                     "unparsed_samples": unparsed[:10]}


# --------------------------------------------------------------------------- 5. fork-src hooks

ADDR_CONST_RE = re.compile(
    r"(?<![0-9A-Za-z_])0[xX]14([0-9A-Fa-f]{7})(?:[uU]?[lL]{0,2})(?![0-9A-Za-z_])")


def scan_fork_src(native_root: str):
    """-> (list of (address, stem, relpath, line)), source hash, file count)."""
    root = os.path.join(native_root, FORK_SRC_REL.replace("/", os.sep))
    hits = []
    files = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for fn in sorted(filenames):
            if os.path.splitext(fn)[1].lower() not in (".cpp", ".hpp"):
                continue
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, native_root).replace(os.sep, "/")
            if rel == SYMBOLS_REL:
                continue
            files.append((rel, full))
    h = hashlib.sha256()
    for rel, full in files:
        h.update(rel.encode() + b"\0" + sha256_file(full).encode() + b"\n")
        text = read_text(full)
        stem = re.sub(r"\W", "_", os.path.splitext(os.path.basename(rel))[0])
        for ln, line in enumerate(text.split("\n"), 1):
            for m in ADDR_CONST_RE.finditer(line):
                hits.append(("14" + m.group(1).upper(), stem, rel, ln))
    return hits, h.hexdigest(), len(files)


# --------------------------------------------------------------------------- 4. structs.hpp

PRIMS = {
    "char": 1, "signed char": 1, "unsigned char": 1, "bool": 1, "BYTE": 1, "byte": 1, "int8_t": 1,
    "uint8_t": 1, "__int8": 1, "unsigned __int8": 1, "std::int8_t": 1, "std::uint8_t": 1,
    "short": 2, "unsigned short": 2, "WORD": 2, "__int16": 2, "unsigned __int16": 2, "int16_t": 2,
    "uint16_t": 2, "std::int16_t": 2, "std::uint16_t": 2, "wchar_t": 2,
    "int": 4, "unsigned int": 4, "unsigned": 4, "DWORD": 4, "long": 4, "unsigned long": 4,
    "float": 4, "__int32": 4, "unsigned __int32": 4, "int32_t": 4, "uint32_t": 4,
    "std::int32_t": 4, "std::uint32_t": 4,
    "double": 8, "__int64": 8, "unsigned __int64": 8, "long long": 8, "unsigned long long": 8,
    "int64_t": 8, "uint64_t": 8, "std::int64_t": 8, "std::uint64_t": 8, "size_t": 8,
    "std::size_t": 8, "uintptr_t": 8, "intptr_t": 8, "QWORD": 8, "ULONG_PTR": 8,
}


def _find_close(text: str, open_pos: int, o: str = "{", c: str = "}") -> int:
    depth = 0
    for i in range(open_pos, len(text)):
        if text[i] == o:
            depth += 1
        elif text[i] == c:
            depth -= 1
            if depth == 0:
                return i
    return -1


def _split_top(text: str, sep: str = ",") -> list[str]:
    parts, depth, cur = [], 0, []
    for ch in text:
        if ch in "<([{":
            depth += 1
        elif ch in ">)]}":
            depth -= 1
        if ch == sep and depth == 0:
            parts.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
    parts.append("".join(cur))
    return parts


class StructParser:
    def __init__(self, text: str):
        self.clean = strip_comments(text)
        self.sizes: dict[str, tuple[int, int | None]] = {}  # name -> (size, align|None)
        self.asserted_size: dict[str, int] = {}
        self.asserted_off: dict[str, dict[str, int]] = {}
        self.structs: list[dict] = []
        self.seen_names: dict[str, int] = {}
        self.pack_stack: list[int] = []
        self.pack = 8
        self.enum_sizes: dict[str, int] = {}
        self.skipped_decls = 0
        self._collect_asserts()

    # -- assertions -----------------------------------------------------------
    def _collect_asserts(self):
        c = self.clean
        for m in re.finditer(r"static_assert\s*\(\s*sizeof\s*\(\s*([\w:]+)\s*\)\s*==\s*(0[xX][0-9A-Fa-f]+|\d+)", c):
            self.asserted_size[m.group(1).split("::")[-1]] = int(m.group(2), 0)
        for m in re.finditer(r"assert_sizeof\s*\(\s*([\w:]+)\s*,\s*(0[xX][0-9A-Fa-f]+|\d+)\s*\)", c):
            self.asserted_size[m.group(1).split("::")[-1]] = int(m.group(2), 0)
        for m in re.finditer(r"static_assert\s*\(\s*offsetof\s*\(\s*([\w:]+)\s*,\s*([\w.\[\]]+)\s*\)\s*==\s*(0[xX][0-9A-Fa-f]+|\d+)", c):
            self.asserted_off.setdefault(m.group(1).split("::")[-1], {})[m.group(2)] = int(m.group(3), 0)
        for m in re.finditer(r"assert_offsetof\s*\(\s*([\w:]+)\s*,\s*([\w.\[\]]+)\s*,\s*(0[xX][0-9A-Fa-f]+|\d+)\s*\)", c):
            self.asserted_off.setdefault(m.group(1).split("::")[-1], {})[m.group(2)] = int(m.group(3), 0)

    # -- type sizes -----------------------------------------------------------
    def resolve(self, type_str: str):
        """-> (size, align|None) or None when unknown."""
        t = squash(type_str)
        if "*" in t or "&" in t:
            return (8, 8)
        t = re.sub(r"\b(const|volatile|struct|class|enum|union|typename)\b", " ", t)
        t = squash(t)
        t = re.sub(r"^(game|entity|scripting|party|sv|session|pmem|ddl|database|demonware)::", "", t)
        if t in PRIMS:
            s = PRIMS[t]
            return (s, s)
        if t in self.enum_sizes:
            s = self.enum_sizes[t]
            return (s, s)
        if t in self.sizes:
            return self.sizes[t]
        return None

    def eval_expr(self, expr: str):
        """Integer expression with + - * ( ), literals and sizeof(Type). None when unknown."""
        def sizeof_sub(m):
            r = self.resolve(m.group(1))
            return str(r[0]) if r else "None"
        e = re.sub(r"sizeof\s*\(\s*([^()]*?)\s*\)", sizeof_sub, expr)
        e = re.sub(r"(0[xX][0-9A-Fa-f]+|\d+)[uUlL]*", lambda m: str(int(m.group(1), 0)), e)
        if not re.fullmatch(r"[\d\s+\-*()/]+", e):
            return None
        try:
            v = eval(e, {"__builtins__": {}}, {})  # noqa: S307 (charset checked above)
        except Exception:
            return None
        return int(v) if isinstance(v, (int, float)) and v == int(v) and v >= 0 else None

    # -- scanning ---------------------------------------------------------------
    def run(self):
        self.scan(0, len(self.clean), [])
        return self.structs

    def scan(self, i: int, end: int, ns: list[str]):
        c = self.clean
        while i < end:
            while i < end and c[i].isspace():
                i += 1
            if i >= end:
                break
            if c[i] == "#":
                j = i
                while True:
                    k = c.find("\n", j)
                    k = end if k < 0 or k > end else k
                    if k > i and c[k - 1] == "\\" and k < end:
                        j = k + 1
                        continue
                    break
                self.pragma(c[i:k])
                i = k + 1
                continue
            m = re.compile(r"namespace\s+(\w+)\s*\{").match(c, i)
            if m:
                close = _find_close(c, m.end() - 1)
                self.scan(m.end(), close, ns + [m.group(1)])
                i = close + 1
                continue
            m = re.compile(r"enum\s+(?:class\s+|struct\s+)?(\w+)\s*(?::\s*([\w: ]+?))?\s*\{").match(c, i)
            if m:
                close = _find_close(c, m.end() - 1)
                under = squash(m.group(2) or "int")
                r = self.resolve(under)
                self.enum_sizes[m.group(1)] = r[0] if r else 4
                i = c.find(";", close) + 1 or end
                continue
            m = re.compile(r"(struct|class)\s+(?:alignas\s*\(\s*\d+\s*\)\s*)?(\w+)\s*(:[^{;]*)?\{").match(c, i)
            if m:
                close = _find_close(c, m.end() - 1)
                body = c[m.end():close]
                self.parse_struct(m.group(2), body, ns, m.group(3), line_of(c, i))
                i = c.find(";", close) + 1 or end
                continue
            # generic statement/definition: skip to ';' or balanced '{...}'
            j = i
            while j < end and c[j] not in ";{":
                j += 1
            if j < end and c[j] == "{":
                j = _find_close(c, j)
                nxt = j + 1
                while nxt < end and c[nxt].isspace():
                    nxt += 1
                j = nxt if nxt < end and c[nxt] == ";" else j
            i = j + 1

    def pragma(self, line: str):
        m = re.match(r"#\s*pragma\s+pack\s*\(\s*(push|pop)\s*(?:,\s*(\d+))?\s*\)", line.strip())
        if not m:
            return
        if m.group(1) == "push":
            self.pack_stack.append(self.pack)
            if m.group(2):
                self.pack = int(m.group(2))
        else:
            self.pack = self.pack_stack.pop() if self.pack_stack else 8

    # -- one struct -------------------------------------------------------------
    def parse_struct(self, name: str, body: str, ns: list[str], base: str | None, line: int):
        pack = self.pack
        fields: list[dict] = []
        notes: list[str] = []
        off: int | None = 0
        max_align = 1
        align_known = True
        if base:
            notes.append("has base class; offsets not computed")
            off = None
            align_known = False
        for stmt in self._statements(body):
            s = squash(stmt)
            if not s or re.fullmatch(r"(public|private|protected)\s*:", s):
                continue
            if re.match(r"(static|using|typedef|friend|template|static_assert)\b", s):
                continue
            if "{" in s:
                if off is not None:
                    notes.append("nested type definition; offsets not computed after it")
                off = None
                align_known = False
                continue
            fp = re.search(r"\(\s*(?:__\w+\s+)?\*\s*(\w+)\s*\)\s*\(", s)
            if fp:
                decl = [(fp.group(1), 8, 8, s)]
            elif "(" in re.sub(r"\[[^\]]*\]", "", s):
                continue  # method / constructor: no storage
            else:
                decl = self._declarators(s, notes)
                if decl is None:
                    if off is not None:
                        notes.append("unparsed declaration `%s`; offsets not computed after it" % s[:60])
                    off = None
                    align_known = False
                    continue
            for fname, fsize, falign, ftype in decl:
                f = {"name": fname, "offset": None, "type": ftype}
                if off is not None and fsize is not None:
                    a = falign
                    if a is None:
                        if off % 8 != 0:
                            notes.append("alignment of `%s` unknown; offsets not computed after it" % ftype[:40])
                            off = None
                            align_known = False
                    else:
                        a = min(a, pack)
                        off = (off + a - 1) // a * a
                        max_align = max(max_align, a)
                    if off is not None:
                        f["offset"] = off
                        off += fsize
                    elif False:
                        pass
                    if falign is None:
                        align_known = False
                else:
                    if off is not None:
                        notes.append("size of `%s` unknown; offsets not computed after it" % ftype[:40])
                    off = None
                    align_known = False
                fields.append(f)
        # asserted offsets: validate / fill
        for f in fields:
            a = self.asserted_off.get(name, {}).get(f["name"])
            if a is None:
                continue
            if f["offset"] is None:
                f["offset"] = a
                f["asserted"] = True
            elif f["offset"] != a:
                notes.append("computed offset of %s (%d) disagrees with the file's assertion (%d); assertion kept"
                             % (f["name"], f["offset"], a))
                f["offset"] = a
                f["asserted"] = True
        size = self.asserted_size.get(name)
        size_src = "static_assert" if size is not None else None
        # a computed size is never trusted: the fork's structs are often partial (pad + the few
        # fields it uses), so only static_assert gives a size
        if size is not None and off is not None and align_known:
            comp = (off + max_align - 1) // max_align * max_align
            if comp > size:
                notes.append("computed size %d disagrees with static_assert %d; static_assert kept" % (comp, size))
        if size is not None:
            self.sizes[name] = (size, max_align if (align_known and off is not None) else None)
        qual = name
        if name in self.seen_names:
            qual = "::".join(ns + [name]) if ns else name
        self.seen_names[name] = self.seen_names.get(name, 0) + 1
        entry = {"name": qual, "size": size, "fields": fields, "source": "structs.hpp"}
        if ns:
            entry["namespace"] = "::".join(ns)
        if size_src:
            entry["size_source"] = size_src
        if notes:
            entry["note"] = "; ".join(dict.fromkeys(notes))
        self.structs.append(entry)

    @staticmethod
    def _statements(body: str):
        """Split a struct body into top-level statements, nested {...} kept inside their statement."""
        out, depth, cur = [], 0, []
        for ch in body:
            cur.append(ch)
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
            elif ch == ";" and depth == 0:
                out.append("".join(cur)[:-1])
                cur = []
        tail = "".join(cur)
        if tail.strip():
            out.append(tail)
        return out

    def _declarators(self, s: str, notes: list[str]):
        """-> [(name,size|None,align|None,type_text)] or None if not understood."""
        if ":" in s and not re.search(r"::", s) or re.search(r"[^:]:[^:]", s):
            return None  # bit-field
        parts = _split_top(s)
        first = parts[0].strip()
        m = re.match(r"^(.*?[\w>\]*&])\s*(\**)\s*(\w+)\s*((?:\[[^\]]+\]\s*)*)$", first)
        if not m:
            return None
        base_with_stars, stars, name, dims = m.group(1), m.group(2), m.group(3), m.group(4)
        # base type: strip pointer stars that belong to the first declarator
        base = re.sub(r"[\s*&]+$", "", base_with_stars)
        first_stars = base_with_stars[len(base):].count("*") + len(stars)
        if re.search(r"\b(unsigned|signed)\s*$", base) or base in ("unsigned", "signed"):
            return None
        if "<" in base:
            return None  # templates are not resolved
        decls = [(name, first_stars, dims)]
        for p in parts[1:]:
            pm = re.match(r"^\s*(\**)\s*(\w+)\s*((?:\[[^\]]+\]\s*)*)$", p)
            if not pm:
                return None
            decls.append((pm.group(2), len(pm.group(1)), pm.group(3)))
        out = []
        base_r = self.resolve(base)
        for dname, nstars, ddims in decls:
            if nstars:
                size, align = 8, 8
                tname = base + "*" * nstars
            else:
                size, align = (base_r if base_r else (None, None))
                tname = base
            dim_vals = []
            for dm in re.finditer(r"\[([^\]]*)\]", ddims):
                v = self.eval_expr(dm.group(1))
                dim_vals.append(v)
            if dim_vals:
                if size is None or any(v is None for v in dim_vals):
                    size = None
                else:
                    for v in dim_vals:
                        size *= v
                tname += "".join("[%s]" % ("?" if v is None else v) for v in dim_vals)
            out.append((dname, size, align, squash(tname)))
        return out


def parse_structs(text: str):
    sp = StructParser(text)
    structs = sp.run()
    complete = sum(1 for s in structs if all(f["offset"] is not None for f in s["fields"]) and s["fields"])
    with_size = sum(1 for s in structs if s["size"] is not None)
    fields = sum(len(s["fields"]) for s in structs)
    placed = sum(1 for s in structs for f in s["fields"] if f["offset"] is not None)
    asserts = sum(len(v) for v in sp.asserted_off.values()) + len(sp.asserted_size)
    stats = {"structs": len(structs), "structs_fully_laid_out": complete, "structs_with_size": with_size,
             "fields": fields, "fields_with_offset": placed, "assertions_read": asserts}
    return structs, stats


# --------------------------------------------------------------------------- merge + main

def merge(entries_by_source: dict[str, list[dict]]):
    """Resolve conflicts by priority. Returns (names list, conflict count, duplicate-name count)."""
    by_addr: dict[str, list[dict]] = {}
    for src in PRIORITY:
        for e in entries_by_source.get(src, []):
            by_addr.setdefault(e["address"], []).append({**e, "source": e.get("source", src)})
    names = []
    conflicts = 0
    for addr in sorted(by_addr, key=lambda a: int(a, 16)):
        cands = by_addr[addr]
        # fork-src hooks only fill addresses nothing else names
        real = [c for c in cands if not c["source"].startswith("fork-src")]
        use = real if real else cands
        win = use[0]
        out = {"address": addr, "name": win["name"], "kind": win["kind"], "source": win["source"]}
        if win.get("type"):
            out["type"] = win["type"]
        seen = {win["name"]}
        aliases = []
        for c in use[1:]:
            if c["name"] not in seen:
                seen.add(c["name"])
                aliases.append({"name": c["name"], "source": c["source"]})
        if aliases:
            out["aliases"] = aliases
            conflicts += 1
        names.append(out)
    return names, conflicts


def main(argv=None) -> int:
    t0 = time.perf_counter()
    ap = argparse.ArgumentParser(description="Collect every known name for iw7_ship.exe addresses.")
    ap.add_argument("--native-root", required=True,
                    help="the fork's `native` folder (holds src/ and ida_scripts/)")
    ap.add_argument("--rdata", required=True, help="unpacked-rdata.bin")
    ap.add_argument("--out", required=True, help="names.json to write")
    ap.add_argument("--csv", action="append", default=[], help="name,address CSV (repeatable)")
    ap.add_argument("--rdata-base", default="0x%X" % RDATA_BASE_DEFAULT,
                    help="address of the first byte of the rdata file")
    args = ap.parse_args(argv)

    root = args.native_root
    p = {k: os.path.join(root, v.replace("/", os.sep)) for k, v in
         (("symbols", SYMBOLS_REL), ("structs", STRUCTS_REL), ("gsc", GSC_IDC_REL), ("lua", LUA_IDC_REL))}
    for k, path in p.items():
        if not os.path.isfile(path):
            print("missing source: %s" % path, file=sys.stderr)
            return 2
    if not os.path.isfile(args.rdata):
        print("missing rdata: %s" % args.rdata, file=sys.stderr)
        return 2
    for c in args.csv:
        if not os.path.isfile(c):
            print("missing csv: %s" % c, file=sys.stderr)
            return 2

    generated = {
        "symbols.hpp": sha256_file(p["symbols"]),
        "gsc-idc": sha256_file(p["gsc"]),
        "lua-idc": sha256_file(p["lua"]),
        "structs.hpp": sha256_file(p["structs"]),
        "unpacked-rdata.bin": sha256_file(args.rdata),
    }
    with open(args.rdata, "rb") as f:
        rdata = Rdata(f.read(), int(args.rdata_base, 0))

    stats = {}
    by_source: dict[str, list[dict]] = {}
    by_source["symbols.hpp"], stats["symbols.hpp"] = parse_symbols(read_text(p["symbols"]))
    by_source["gsc-idc"], stats["gsc-idc"] = parse_gsc_idc(read_text(p["gsc"]))
    by_source["lua-idc"], stats["lua-idc"] = parse_lua_idc(read_text(p["lua"]), rdata)
    csv_entries, csv_stats = [], {"files": [], "parsed": 0, "unparsed_lines": 0}
    for c in args.csv:
        es, st = parse_csv(read_text(c))
        csv_entries += es
        generated["csv:" + os.path.basename(c)] = sha256_file(c)
        csv_stats["files"].append({"file": os.path.basename(c), "parsed": st["parsed"],
                                   "unparsed_lines": st["unparsed_lines"]})
        csv_stats["parsed"] += st["parsed"]
        csv_stats["unparsed_lines"] += st["unparsed_lines"]
    by_source["csv"], stats["csv"] = csv_entries, csv_stats

    hits, fork_hash, fork_files = scan_fork_src(root)
    generated["fork-src"] = fork_hash
    named = {e["address"] for src in ("symbols.hpp", "gsc-idc", "lua-idc", "csv") for e in by_source[src]}
    hooks, already = [], 0
    seen_pair = set()
    for addr, stem, rel, ln in hits:
        if addr == "%X" % IMAGE_BASE:
            continue  # the image base itself, not a name
        if addr in named:
            already += 1
            continue
        nm = "hook_%s_%s" % (stem, addr)
        if (addr, nm) in seen_pair:
            continue
        seen_pair.add((addr, nm))
        hooks.append({"address": addr, "name": nm, "kind": "unknown",
                      "source": "fork-src:%s:%d" % (rel, ln)})
    by_source["fork-src"] = hooks
    stats["fork-src"] = {"files": fork_files, "constants_found": len(hits),
                         "already_named": already, "hook_names": len(hooks),
                         "distinct_addresses": len({h["address"] for h in hooks})}

    structs, stats["structs.hpp"] = parse_structs(read_text(p["structs"]))
    names, conflicts = merge(by_source)
    name_count: dict[str, int] = {}
    for n in names:
        name_count[n["name"]] = name_count.get(n["name"], 0) + 1
    dup_names = sum(1 for v in name_count.values() if v > 1)

    out_dir = os.path.dirname(os.path.abspath(args.out))
    os.makedirs(out_dir, exist_ok=True)
    tmp = args.out + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        f.write('{"schema":%s,\n"generated_from":%s,\n"names":[\n'
                % (json.dumps(SCHEMA), json.dumps(generated, sort_keys=True)))
        f.write(",\n".join(json.dumps(n, separators=(",", ":")) for n in names))
        f.write('\n],\n"structs":[\n')
        f.write(",\n".join(json.dumps(s, separators=(",", ":")) for s in structs))
        f.write("\n]}\n")
    os.replace(tmp, args.out)

    elapsed = time.perf_counter() - t0
    ss, sg, sl = stats["symbols.hpp"], stats["gsc-idc"], stats["lua-idc"]
    print("symbols.hpp : %d parsed of %d declarations, %d unparsed lines" % (ss["parsed"], ss["declarations"], ss["unparsed_lines"]))
    print("gsc-idc     : %d parsed (%s), %d skipped nullptr, %d unparsed lines"
          % (sg["parsed"], ", ".join("%s=%d" % kv for kv in sg["per_prefix"].items()), sg["skipped_nullptr"], sg["unparsed_lines"]))
    print("lua-idc     : %d parsed in %d tables, %d unparsed lines" % (sl["parsed"], len(sl["tables"]), sl["unparsed_lines"]))
    for t in sl["tables"]:
        print("    %-20s %s %4d entries%s" % (t["table"], t["address"], t["entries"],
              "" if t["stop"] == "terminator" else "  (stopped: %s)" % t["stop"]))
    print("csv         : %d parsed, %d unparsed lines" % (stats["csv"]["parsed"], stats["csv"]["unparsed_lines"]))
    sf = stats["fork-src"]
    print("fork-src    : %d files, %d constants, %d already named, %d hook names (%d addresses)"
          % (sf["files"], sf["constants_found"], sf["already_named"], sf["hook_names"], sf["distinct_addresses"]))
    st = stats["structs.hpp"]
    print("structs.hpp : %d structs (%d with size, %d fully laid out), %d/%d fields with offset, %d assertions read"
          % (st["structs"], st["structs_with_size"], st["structs_fully_laid_out"], st["fields_with_offset"], st["fields"], st["assertions_read"]))
    for src in ("symbols.hpp", "gsc-idc", "lua-idc", "csv"):
        for ln, s in stats[src].get("unparsed_samples", [])[:5]:
            print("    unparsed %s line %d: %s" % (src, ln, s[:100]))
    print("names.json  : %d names (%d with aliases, %d names used by more than one address), %d structs"
          % (len(names), conflicts, dup_names, len(structs)))
    print("run time    : %.2f s" % elapsed)
    print("wrote %s" % args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
