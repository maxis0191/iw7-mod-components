"""Live engine tool: read, watch, dump and trace a running PRIVATE lab game process that our own runner started.

Every command except `ps` works on one process and refuses any process that is not ours (see `ps`): a game the
owner plays (`iw7-cb-aurora.exe`, always refused), another application's game, or anything outside a bench root.

    python -I engine_live.py ps [--json]
    python -I engine_live.py read  <expr> [--type u8|u16|u32|i32|u64|f32|ptr|str | --size N] [--count N] [--pid N]
    python -I engine_live.py deref <expr> [--pid N]
    python -I engine_live.py watch <expr>:<type>:<interval ms>:<count> [...] [--out samples.jsonl] [--pid N]
    python -I engine_live.py dump  --out <folder> [--pid N]
    python -I engine_live.py trace --session <bench session folder> --at <expr> [--at ...] [--log <cdb expr>] [--ret]
                                   [--hits N] [--seconds S] [--mode hw|sw] [--out hits.jsonl] [--pid N]
    python -I engine_live.py break --session <folder> --at <expr> [--hits N] ...   (registers and stack of each hit)

Address expressions: numbers (hex with or without 0x, 0n<decimal>), names from the names file (schema
iw7.engine-names/1), + and -, and [x] which reads the pointer (8 bytes) at x: `[0x143C986B8]+0x4A90`.
Watch types also take `<type>x<N>` (N values) and `nz<type>x<N>` (how many of N values are not zero), e.g.
`0x143CA1612:nzu8x24:250:40` counts in-use agent entities.

Ownership (`ps`): a process is ours when ALL hold: its image lies in a bench root (folder with
`paris-bench-root.json`, schema iw7.bench-root/1) under the bench parent; the machine scheduler's registry
(`%LOCALAPPDATA%/IW7Paris/ResourceScheduler/leases.json`, read only, never locked or written) lists this PID with the
same image and creation time in a lease whose scope holds the image. `trace`/`break` attach a debugger, so they also
need `--session` = that lease's scope (the runner's `glh-xxxxxxxx` folder): only the session you started.
`--i-own-it <image path>` replaces the checks for a process whose image is exactly that path.

`dump` and `read`/`watch` open the process with PROCESS_VM_READ | PROCESS_QUERY_INFORMATION only and never suspend it.
`trace`/`break` run the Microsoft console debugger (cdb) attached to the process, log each hit, then remove every
breakpoint and detach (`qd`); the process keeps running. Hardware breakpoints (`ba e1`, default) or software ones
(`bp`, int3 in the code): see docs for which survive the protector.
"""
import argparse
import ctypes
import datetime as _dt
import json
import os
import queue
import re
import struct
import subprocess
import sys
import threading
import time
from ctypes import wintypes

DEFAULT_NAMES = r"C:\Users\ezvalo\Documents\IW7-RE-Lab\engine\names\names.json"
DEFAULT_BENCH_PARENT = r"C:\Users\ezvalo\Documents\IW7-Runtime\bench"
DEFAULT_CDB = [
    r"C:\Program Files\WindowsApps\Microsoft.WinDbg_1.2606.22001.0_x64__8wekyb3d8bbwe\amd64\cdb.exe",
    r"C:\Users\ezvalo\Documents\IW7-Runtime\private-test-server\iw7-mod\capacity-tools\cdb.exe",
]
CDB_SHA256 = "5F54ABAFCA3AE5638BBF807D402FABB350A64575C1DFA9FBFC7F5732DF5BEE67"
OWNER_GAME = "iw7-cb-aurora.exe"
BENCH_MANIFEST = "paris-bench-root.json"
BENCH_SCHEMA = "iw7.bench-root/1"
GAME_BASE = 0x140000000
TYPES = {"u8": ("<B", 1), "u16": ("<H", 2), "u32": ("<I", 4), "i32": ("<i", 4), "u64": ("<Q", 8),
         "f32": ("<f", 4), "ptr": ("<Q", 8)}


class ToolError(Exception):
    """A refusal or a failure with a plain message; exit code 2."""


# ---------------------------------------------------------------- address expressions (pure, unit-tested)

def load_names(path):
    if not path or not os.path.exists(path):
        return {}
    with open(path, encoding="utf-8") as f:
        d = json.load(f)
    if d.get("schema") != "iw7.engine-names/1":
        raise ToolError("names file schema is not iw7.engine-names/1: %s" % path)
    out = {}
    for n in d.get("names", []):
        try:
            out[n["name"]] = int(str(n["address"]), 16)
        except (KeyError, ValueError):
            continue
    return out


_TOKEN = re.compile(r"\s*(?:(\[)|(\])|(\+)|(-)|(0n\d+)|(0x[0-9A-Fa-f]+)|([A-Za-z_][\w@?$.:]*)|([0-9A-Fa-f]+))")


def tokenize(text):
    pos, out = 0, []
    text = text.strip()
    while pos < len(text):
        m = _TOKEN.match(text, pos)
        if not m or m.end() == pos:
            raise ToolError("bad address expression at %r" % text[pos:])
        pos = m.end()
        lb, rb, plus, minus, dec, hx, name, bare = m.groups()
        if lb:
            out.append(("[", None))
        elif rb:
            out.append(("]", None))
        elif plus:
            out.append(("+", None))
        elif minus:
            out.append(("-", None))
        elif dec:
            out.append(("num", int(dec[2:], 10)))
        elif hx:
            out.append(("num", int(hx, 16)))
        elif bare is not None:
            out.append(("num", int(bare, 16)))
        else:
            out.append(("name", name))
    return out


def evaluate(text, names, read_ptr, steps=None):
    """Value of an address expression. read_ptr(addr) -> int reads 8 bytes; steps collects the chain."""
    toks = tokenize(text)
    pos = [0]

    def peek():
        return toks[pos[0]] if pos[0] < len(toks) else (None, None)

    def take(kind):
        t = peek()
        if t[0] != kind:
            raise ToolError("expected %r in %r" % (kind, text))
        pos[0] += 1
        return t

    def term():
        kind, val = peek()
        if kind == "num":
            pos[0] += 1
            return val
        if kind == "name":
            pos[0] += 1
            if val in names:
                return names[val]
            m = re.fullmatch(r"(?:sub|loc|off|data|hook_\w+?)_([0-9A-Fa-f]{9,16})", val)
            if m:
                return int(m.group(1), 16)
            raise ToolError("unknown name %r (give --names, or a hex address)" % val)
        if kind == "[":
            pos[0] += 1
            inner = expr()
            take("]")
            v = read_ptr(inner)
            if steps is not None:
                steps.append({"read": hex(inner), "value": hex(v)})
            return v
        raise ToolError("unexpected %r in %r" % (kind, text))

    def expr():
        v = term()
        while peek()[0] in ("+", "-"):
            op = take(peek()[0])[0]
            r = term()
            v = v + r if op == "+" else v - r
            if steps is not None:
                steps.append({op: hex(r), "value": hex(v)})
        return v

    v = expr()
    if pos[0] != len(toks):
        raise ToolError("trailing text in %r" % text)
    return v & 0xFFFFFFFFFFFFFFFF


def parse_type(t):
    """('u32', 1, False) for 'u32', ('u8', 24, True) for 'nzu8x24', ('str', 0, False) for 'str'."""
    m = re.fullmatch(r"(nz)?(u8|u16|u32|i32|u64|f32|ptr|str)(?:x(\d+))?", t)
    if not m:
        raise ToolError("unknown type %r (u8 u16 u32 i32 u64 f32 ptr str, <type>x<N>, nz<type>x<N>)" % t)
    nz, base, n = m.group(1), m.group(2), m.group(3)
    if base == "str" and (nz or n):
        raise ToolError("str takes no count")
    return base, int(n) if n else 1, bool(nz)


def parse_watch(spec):
    """'<expr>:<type>:<interval ms>:<count>' -> dict. The expression may itself hold ':' only inside names."""
    parts = spec.rsplit(":", 3)
    if len(parts) != 4:
        raise ToolError("watch spec is <expr>:<type>:<interval ms>:<count>: %r" % spec)
    expr, t, iv, cnt = parts
    base, n, nz = parse_type(t)
    iv, cnt = int(iv, 0), int(cnt, 0)
    if iv < 1 or cnt < 1:
        raise ToolError("interval and count must be >= 1: %r" % spec)
    return {"spec": spec, "expr": expr, "type": base, "n": n, "nz": nz, "interval_ms": iv, "count": cnt}


def decode(raw, base, n, nz=False):
    if base == "str":
        return raw.split(b"\0", 1)[0].decode("utf-8", "replace")
    fmt, size = TYPES[base]
    vals = [struct.unpack_from(fmt, raw, i * size)[0] for i in range(n)]
    if base == "ptr":
        vals = [hex(v) for v in vals]
    if nz:
        return sum(1 for v in vals if v not in (0, "0x0"))
    return vals[0] if n == 1 else vals


def type_size(base, n):
    return 256 if base == "str" else TYPES[base][1] * n


# ---------------------------------------------------------------- Windows process access

PROCESS_VM_READ = 0x0010
PROCESS_QUERY_INFORMATION = 0x0400
PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
PROCESS_SUSPEND_RESUME = 0x0800
PROCESS_CREATE_THREAD = 0x0002
PROCESS_VM_OPERATION = 0x0008
PROCESS_VM_WRITE = 0x0020


class PROCESSENTRY32W(ctypes.Structure):
    _fields_ = [("dwSize", wintypes.DWORD), ("cntUsage", wintypes.DWORD), ("th32ProcessID", wintypes.DWORD),
                ("th32DefaultHeapID", ctypes.c_size_t), ("th32ModuleID", wintypes.DWORD),
                ("cntThreads", wintypes.DWORD), ("th32ParentProcessID", wintypes.DWORD),
                ("pcPriClassBase", ctypes.c_long), ("dwFlags", wintypes.DWORD), ("szExeFile", ctypes.c_wchar * 260)]


class MEMORY_BASIC_INFORMATION(ctypes.Structure):
    _fields_ = [("BaseAddress", ctypes.c_void_p), ("AllocationBase", ctypes.c_void_p),
                ("AllocationProtect", wintypes.DWORD), ("PartitionId", wintypes.WORD),
                ("RegionSize", ctypes.c_size_t), ("State", wintypes.DWORD), ("Protect", wintypes.DWORD),
                ("Type", wintypes.DWORD)]


def _k32():
    if os.name != "nt" or ctypes.sizeof(ctypes.c_void_p) != 8:
        raise ToolError("needs 64-bit Python on Windows")
    k = ctypes.WinDLL("kernel32", use_last_error=True)
    k.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    k.OpenProcess.restype = wintypes.HANDLE
    k.CloseHandle.argtypes = [wintypes.HANDLE]
    k.ReadProcessMemory.argtypes = [wintypes.HANDLE, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t,
                                    ctypes.POINTER(ctypes.c_size_t)]
    k.ReadProcessMemory.restype = wintypes.BOOL
    k.QueryFullProcessImageNameW.argtypes = [wintypes.HANDLE, wintypes.DWORD, wintypes.LPWSTR,
                                             ctypes.POINTER(wintypes.DWORD)]
    k.GetProcessTimes.argtypes = [wintypes.HANDLE] + [ctypes.POINTER(wintypes.FILETIME)] * 4
    k.CreateToolhelp32Snapshot.restype = wintypes.HANDLE
    k.Process32FirstW.argtypes = [wintypes.HANDLE, ctypes.POINTER(PROCESSENTRY32W)]
    k.Process32NextW.argtypes = [wintypes.HANDLE, ctypes.POINTER(PROCESSENTRY32W)]
    k.VirtualQueryEx.argtypes = [wintypes.HANDLE, ctypes.c_void_p, ctypes.POINTER(MEMORY_BASIC_INFORMATION),
                                 ctypes.c_size_t]
    k.VirtualQueryEx.restype = ctypes.c_size_t
    k.GetExitCodeProcess.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
    k.DebugBreakProcess.argtypes = [wintypes.HANDLE]
    return k


def filetime_utc(ft):
    v = (ft.dwHighDateTime << 32) | ft.dwLowDateTime
    return _dt.datetime(1601, 1, 1, tzinfo=_dt.timezone.utc) + _dt.timedelta(microseconds=v // 10)


def process_info(k, pid):
    """{pid, name, image, created_utc, command_line} with what can be read (limited query rights only)."""
    info = {"pid": pid, "image": None, "created_utc": None, "command_line": None}
    h = k.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, pid)
    if not h:
        info["error"] = "OpenProcess failed (%d)" % ctypes.get_last_error()
        return info
    try:
        buf = ctypes.create_unicode_buffer(32768)
        n = wintypes.DWORD(len(buf))
        if k.QueryFullProcessImageNameW(h, 0, buf, ctypes.byref(n)):
            info["image"] = buf.value
        c, e, kk, u = (wintypes.FILETIME() for _ in range(4))
        if k.GetProcessTimes(h, ctypes.byref(c), ctypes.byref(e), ctypes.byref(kk), ctypes.byref(u)):
            info["created_utc"] = filetime_utc(c).isoformat()
        info["command_line"] = _command_line(h)
    finally:
        k.CloseHandle(h)
    return info


def _command_line(h):
    nt = ctypes.WinDLL("ntdll")
    nt.NtQueryInformationProcess.argtypes = [wintypes.HANDLE, ctypes.c_ulong, ctypes.c_void_p, ctypes.c_ulong,
                                             ctypes.POINTER(ctypes.c_ulong)]
    size = ctypes.c_ulong(0)
    nt.NtQueryInformationProcess(h, 60, None, 0, ctypes.byref(size))  # ProcessCommandLineInformation
    if not size.value:
        return None
    buf = ctypes.create_string_buffer(size.value)
    if nt.NtQueryInformationProcess(h, 60, buf, size, ctypes.byref(size)) != 0:
        return None
    length = struct.unpack_from("<H", buf.raw, 0)[0]
    ptr = struct.unpack_from("<Q", buf.raw, 8)[0]
    off = ptr - ctypes.addressof(buf)
    if not (0 <= off <= size.value - length):
        return None
    return buf.raw[off:off + length].decode("utf-16-le", "replace")


def list_processes(k, match=re.compile(r"iw7", re.I)):
    snap = k.CreateToolhelp32Snapshot(2, 0)
    if snap in (None, wintypes.HANDLE(-1).value):
        raise ToolError("process snapshot failed")
    out = []
    try:
        e = PROCESSENTRY32W()
        e.dwSize = ctypes.sizeof(e)
        ok = k.Process32FirstW(snap, ctypes.byref(e))
        while ok:
            if match.search(e.szExeFile):
                out.append({"pid": e.th32ProcessID, "name": e.szExeFile, "parent": e.th32ParentProcessID})
            ok = k.Process32NextW(snap, ctypes.byref(e))
    finally:
        k.CloseHandle(snap)
    return out


# ---------------------------------------------------------------- ownership (pure part unit-tested)

def scheduler_registry_path():
    return os.path.join(os.environ.get("LOCALAPPDATA", ""), "IW7Paris", "ResourceScheduler", "leases.json")


def read_registry(path):
    """The scheduler's lease registry, read only (shared read, no lock); [] when absent or unreadable."""
    try:
        with open(path, "rb") as f:
            data = f.read()
        return json.loads(data.decode("utf-8-sig")).get("Leases") or []
    except (OSError, ValueError):
        return []


def _utc(s):
    if not s:
        return None
    s = str(s).replace("Z", "+00:00")
    m = re.match(r"^(.*?\.\d{1,6})\d*(.*)$", s)
    if m:
        s = m.group(1) + m.group(2)
    try:
        d = _dt.datetime.fromisoformat(s)
    except ValueError:
        return None
    return d if d.tzinfo else d.replace(tzinfo=_dt.timezone.utc)


def _norm(p):
    return os.path.normcase(os.path.abspath(p)) if p else ""


def find_bench(image, read_json=None):
    """(bench root, manifest) of the bench that holds image, or (None, None)."""
    read_json = read_json or _read_json
    d = os.path.dirname(image or "")
    for _ in range(4):
        if not d:
            break
        m = read_json(os.path.join(d, BENCH_MANIFEST))
        if m is not None:
            return d, m
        nd = os.path.dirname(d)
        if nd == d:
            break
        d = nd
    return None, None


def _read_json(path):
    try:
        with open(path, encoding="utf-8-sig") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def judge_ownership(info, leases, bench_parent, read_json=None, own_image=None):
    """{'ours': bool, 'reasons': [...], 'scope': lease scope or None, 'lease_owner'} for one process."""
    reasons, ok = [], True
    image = info.get("image") or ""
    name = os.path.basename(image) or info.get("name", "")
    if name.lower() == OWNER_GAME:
        return {"ours": False, "reasons": ["the owner's game (%s): never touched" % OWNER_GAME], "scope": None}
    if own_image:
        if image and _norm(image) == _norm(own_image):
            return {"ours": True, "reasons": ["--i-own-it: image is exactly %s" % own_image], "scope": None}
        return {"ours": False, "reasons": ["--i-own-it image %s != process image %s" % (own_image, image)],
                "scope": None}
    if not image:
        return {"ours": False, "reasons": ["image path unreadable"], "scope": None}
    root, manifest = find_bench(image, read_json)
    if not root:
        ok = False
        reasons.append("not in a bench root (no %s next to the image)" % BENCH_MANIFEST)
    elif (manifest or {}).get("Schema", manifest.get("schema") if manifest else None) != BENCH_SCHEMA:
        ok = False
        reasons.append("bench manifest schema is not %s" % BENCH_SCHEMA)
    else:
        reasons.append("bench root %s" % root)
    if root and bench_parent and not _norm(root).startswith(_norm(bench_parent) + os.sep):
        ok = False
        reasons.append("bench root is not under the bench parent %s" % bench_parent)
    created = _utc(info.get("created_utc"))
    lease_hit = None
    for lease in leases:
        for p in lease.get("Processes") or []:
            if int(p.get("PID", -1)) != int(info["pid"]):
                continue
            pc = _utc(p.get("CreatedUtc"))
            if _norm(p.get("Image")) != _norm(image) or not pc or not created \
                    or abs((pc - created).total_seconds()) > 0.001:
                continue
            scope = lease.get("Scope") or ""
            if not _norm(image).startswith(_norm(scope) + os.sep):
                continue
            lease_hit = lease
    if lease_hit is None:
        ok = False
        reasons.append("no scheduler lease lists this PID with this image and creation time")
        scope = None
    else:
        scope = lease_hit.get("Scope")
        reasons.append("scheduler lease %s... '%s' scope %s" % (str(lease_hit.get("Token", ""))[:8],
                                                              lease_hit.get("Owner", ""), scope))
    return {"ours": ok, "reasons": reasons, "scope": scope, "lease_owner": lease_hit.get("Owner") if lease_hit else None}


def candidates(args):
    k = _k32()
    leases = read_registry(scheduler_registry_path())
    out = []
    for p in list_processes(k):
        info = process_info(k, p["pid"])
        info["name"] = p["name"]
        j = judge_ownership(info, leases, args.bench_parent)
        info.update(j)
        cl = info.get("command_line") or ""
        info["kind"] = "server" if "-dedicated" in cl else ("client" if info.get("image") else "unknown")
        out.append(info)
    return out


def pick_process(args, intrusive=False):
    """The PID to work on, after the ownership checks; raises ToolError on refusal."""
    k = _k32()
    leases = read_registry(scheduler_registry_path())
    if args.pid is None:
        ours = [c for c in candidates(args) if c["ours"]]
        if len(ours) != 1:
            raise ToolError("give --pid: %d processes of ours run (%s)" % (len(ours), ", ".join(
                str(c["pid"]) for c in ours) or "none"))
        args.pid = ours[0]["pid"]
    info = process_info(k, args.pid)
    if not info.get("image"):
        raise ToolError("process %d: %s" % (args.pid, info.get("error", "image unreadable (gone?)")))
    j = judge_ownership(info, leases, args.bench_parent, own_image=getattr(args, "i_own_it", None))
    if not j["ours"]:
        raise ToolError("refused: process %d (%s) is not one of ours: %s" % (args.pid, info["image"],
                                                                             "; ".join(j["reasons"])))
    if intrusive and not getattr(args, "i_own_it", None):
        sess = getattr(args, "session", None)
        if not sess:
            raise ToolError("refused: a debugger is attached only to the session you started: give --session "
                            "<the runner's session folder> (lease scope %s)" % j["scope"])
        if _norm(sess) != _norm(j["scope"]):
            raise ToolError("refused: --session %s is not the lease scope %s of process %d" % (sess, j["scope"],
                                                                                              args.pid))
    info.update(j)
    return info


# ---------------------------------------------------------------- memory reader

class Reader:
    """Read-only handle (PROCESS_VM_READ | PROCESS_QUERY_INFORMATION); never suspends or writes."""

    def __init__(self, pid):
        self.k = _k32()
        self.h = self.k.OpenProcess(PROCESS_VM_READ | PROCESS_QUERY_INFORMATION, False, pid)
        if not self.h:
            raise ToolError("OpenProcess(%d) failed: %d" % (pid, ctypes.get_last_error()))
        self.got = ctypes.c_size_t()

    def read(self, addr, size):
        buf = ctypes.create_string_buffer(size)
        if not self.k.ReadProcessMemory(self.h, ctypes.c_void_p(addr), buf, size, ctypes.byref(self.got)) \
                or self.got.value != size:
            raise ToolError("read of %d bytes at 0x%X failed (%d)" % (size, addr, ctypes.get_last_error()))
        return buf.raw

    def try_read(self, addr, size):
        buf = ctypes.create_string_buffer(size)
        ok = self.k.ReadProcessMemory(self.h, ctypes.c_void_p(addr), buf, size, ctypes.byref(self.got))
        return buf.raw[:self.got.value] if ok or self.got.value else b""

    def ptr(self, addr):
        return struct.unpack("<Q", self.read(addr, 8))[0]

    def regions(self, start, end):
        """(base, size, committed) covering [start, end)."""
        mbi = MEMORY_BASIC_INFORMATION()
        a = start
        while a < end:
            if not self.k.VirtualQueryEx(self.h, ctypes.c_void_p(a), ctypes.byref(mbi), ctypes.sizeof(mbi)):
                yield a, end - a, False
                return
            base = mbi.BaseAddress or 0
            size = mbi.RegionSize - (a - base)
            committed = mbi.State == 0x1000 and not (mbi.Protect & 0x101)  # MEM_COMMIT, not NOACCESS/GUARD
            yield a, min(size, end - a), committed
            a += size

    def alive(self):
        code = wintypes.DWORD()
        return bool(self.k.GetExitCodeProcess(self.h, ctypes.byref(code))) and code.value == 259

    def close(self):
        if self.h:
            self.k.CloseHandle(self.h)
            self.h = None


def pe_sections(read, base):
    hdr = read(base, 0x1000)
    if hdr[:2] != b"MZ":
        raise ToolError("no PE header at 0x%X" % base)
    off = struct.unpack_from("<I", hdr, 0x3C)[0]
    if hdr[off:off + 4] != b"PE\0\0":
        raise ToolError("bad PE signature at 0x%X" % base)
    count = struct.unpack_from("<H", hdr, off + 6)[0]
    ts = struct.unpack_from("<I", hdr, off + 8)[0]
    opt = struct.unpack_from("<H", hdr, off + 20)[0]
    size_of_image = struct.unpack_from("<I", hdr, off + 24 + 56)[0]
    secs = []
    for i in range(count):
        name, vsize, va, rsize, roff = struct.unpack_from("<8sIIII", hdr, off + 24 + opt + 40 * i)
        secs.append((name.rstrip(b"\0").decode("ascii", "replace"), base + va, vsize, rsize))
    return secs, ts, size_of_image


def module_list(pid):
    """[(name, base, size)] of the process (PSAPI with query+read rights)."""
    k = _k32()
    psapi = ctypes.WinDLL("psapi", use_last_error=True)
    h = k.OpenProcess(PROCESS_VM_READ | PROCESS_QUERY_INFORMATION, False, pid)
    if not h:
        return []
    try:
        arr = (wintypes.HMODULE * 2048)()
        need = wintypes.DWORD()
        psapi.EnumProcessModulesEx.argtypes = [wintypes.HANDLE, ctypes.c_void_p, wintypes.DWORD,
                                               ctypes.POINTER(wintypes.DWORD), wintypes.DWORD]
        if not psapi.EnumProcessModulesEx(h, arr, ctypes.sizeof(arr), ctypes.byref(need), 3):
            return []
        psapi.GetModuleBaseNameW.argtypes = [wintypes.HANDLE, wintypes.HMODULE, wintypes.LPWSTR, wintypes.DWORD]

        class MODINFO(ctypes.Structure):
            _fields_ = [("base", ctypes.c_void_p), ("size", wintypes.DWORD), ("entry", ctypes.c_void_p)]

        psapi.GetModuleInformation.argtypes = [wintypes.HANDLE, wintypes.HMODULE, ctypes.POINTER(MODINFO),
                                               wintypes.DWORD]
        out = []
        for i in range(min(need.value // ctypes.sizeof(wintypes.HMODULE), 2048)):
            nb = ctypes.create_unicode_buffer(260)
            psapi.GetModuleBaseNameW(h, arr[i], nb, 260)
            mi = MODINFO()
            psapi.GetModuleInformation(h, arr[i], ctypes.byref(mi), ctypes.sizeof(mi))
            out.append((nb.value, mi.base or 0, mi.size))
        return out
    finally:
        k.CloseHandle(h)


# ---------------------------------------------------------------- commands: ps, read, deref, watch, dump

def emit(args, obj, text):
    if args.json:
        print(json.dumps(obj))
    else:
        print(text)


def cmd_ps(args):
    t0 = time.perf_counter()
    rows = candidates(args)
    ms = round((time.perf_counter() - t0) * 1000, 1)
    if args.json:
        print(json.dumps({"processes": rows, "ms": ms}))
        return 0
    if not rows:
        print("no iw7 process")
    for r in rows:
        print("%-6d %-5s %-6s %s  started %s" % (r["pid"], "OURS" if r["ours"] else "-", r["kind"], r.get("image"),
                                                 r.get("created_utc")))
        print("       cmd: %s" % (r.get("command_line") or "?")[:300])
        for why in r["reasons"]:
            print("       - %s" % why)
    print("(%s ms)" % ms)
    return 0


def _names(args):
    return load_names(args.names)


def cmd_read(args):
    info = pick_process(args)
    t0 = time.perf_counter()
    r = Reader(args.pid)
    try:
        steps = []
        addr = evaluate(args.expr, _names(args), r.ptr, steps)
        if args.size:
            raw = r.read(addr, args.size * args.count)
            value = raw.hex()
            typ = "bytes"
        else:
            base, n, nz = parse_type(args.type)
            n *= args.count
            raw = r.read(addr, type_size(base, n)) if base != "str" else r.try_read(addr, 256)
            value = decode(raw, base, n, nz)
            typ = args.type
        ms = round((time.perf_counter() - t0) * 1000, 2)
        emit(args, {"pid": args.pid, "expr": args.expr, "address": hex(addr), "type": typ, "value": value,
                    "steps": steps, "ms": ms},
             "%s = 0x%X : %s = %s   (%s ms)" % (args.expr, addr, typ, value, ms))
    finally:
        r.close()
    return 0


def cmd_deref(args):
    pick_process(args)
    r = Reader(args.pid)
    try:
        steps = []
        addr = evaluate(args.expr, _names(args), r.ptr, steps)
        if args.json:
            print(json.dumps({"pid": args.pid, "expr": args.expr, "address": hex(addr), "steps": steps}))
        else:
            for s in steps:
                print("  " + ", ".join("%s %s" % kv for kv in s.items()))
            print("%s = 0x%X" % (args.expr, addr))
    finally:
        r.close()
    return 0


def cmd_watch(args):
    pick_process(args)
    specs = [parse_watch(s) for s in args.spec]
    r = Reader(args.pid)
    names = _names(args)
    out = open(args.out, "a", encoding="utf-8") if args.out else None
    t0 = time.perf_counter()
    try:
        for s in specs:
            s["left"] = s["count"]
            s["next"] = 0.0
            s["last"] = object()
        while any(s["left"] for s in specs):
            now = time.perf_counter() - t0
            due = [s for s in specs if s["left"] and s["next"] <= now]
            for s in due:
                s["left"] -= 1
                s["next"] = now + s["interval_ms"] / 1000.0
                rec = {"t": round(now, 4), "wall": _dt.datetime.now(_dt.timezone.utc).isoformat(), "spec": s["spec"]}
                try:
                    addr = evaluate(s["expr"], names, r.ptr)
                    raw = r.read(addr, type_size(s["type"], s["n"])) if s["type"] != "str" else r.try_read(addr, 256)
                    rec.update({"address": hex(addr), "value": decode(raw, s["type"], s["n"], s["nz"])})
                except ToolError as e:
                    rec["error"] = str(e)
                    if not r.alive():
                        rec["error"] = "process ended"
                        for x in specs:
                            x["left"] = 0
                changed = rec.get("value", rec.get("error")) != s["last"]
                rec["changed"] = changed
                s["last"] = rec.get("value", rec.get("error"))
                line = json.dumps(rec)
                if out:
                    out.write(line + "\n")
                    out.flush()
                if args.json:
                    print(line, flush=True)
                elif changed:
                    print("%8.3f s  %s = %s" % (now, s["expr"], rec.get("value", rec.get("error"))), flush=True)
            pending = [s["next"] for s in specs if s["left"]]
            if pending:
                time.sleep(max(0.0, min(pending) - (time.perf_counter() - t0)))
    finally:
        r.close()
        if out:
            out.close()
    if not args.json:
        print("(%.2f s)" % (time.perf_counter() - t0))
    return 0


def find_game_module(pid, read, module):
    """(base, name, how) of the game image: the module of that name, else the image mapped at 0x140000000."""
    mods = module_list(pid)
    for name, base, size in mods:
        if name.lower() == module.lower():
            return base, name, "module list"
    secs, _, _ = pe_sections(read, GAME_BASE)
    if not any(n == ".text" and va == GAME_BASE + 0x1000 for n, va, _, _ in secs):
        raise ToolError("%s is not in the module list and 0x%X holds no game image" % (module, GAME_BASE))
    owner = next((n for n, b, s in mods if b == GAME_BASE), None)
    return GAME_BASE, owner or "image@0x140000000", "image at 0x140000000 (loaded by %s)" % (owner or "?")


def cmd_dump(args):
    info = pick_process(args)
    t0 = time.perf_counter()
    r = Reader(args.pid)
    page = 0x1000
    try:
        base, modname, how = find_game_module(args.pid, r.read, args.module)
        secs, ts, size_of_image = pe_sections(r.read, base)
        os.makedirs(args.out, exist_ok=True)
        receipt = {"schema": "iw7.engine-dump-sections/1", "dump": "live:pid=%d" % args.pid, "module": modname,
                   "base": hex(base), "size": size_of_image, "timestamp": ts, "sections": [],
                   "live": {"pid": args.pid, "image": info["image"], "created_utc": info["created_utc"],
                            "found_by": how, "access": "PROCESS_VM_READ|PROCESS_QUERY_INFORMATION",
                            "suspended": False}}
        total = 0
        for name, va, vsize, rsize in secs:
            size = min(max(vsize, rsize), args.max_bytes)
            size = (size + page - 1) // page * page
            buf = bytearray(size)
            missing = 0
            for a, n, committed in r.regions(va, va + size):
                o = a - va
                if committed:
                    got = r.try_read(a, n)
                    buf[o:o + len(got)] = got
                    if len(got) < n:  # partial region: fall back to pages
                        for po in range(o + len(got) - (o + len(got)) % page, o + n, page):
                            g = r.try_read(va + po, page)
                            buf[po:po + len(g)] = g
                            missing += 0 if len(g) == page else 1
                else:
                    missing += (n + page - 1) // page
            with open(os.path.join(args.out, "%X.bin" % va), "wb") as f:
                f.write(buf)
            total += size
            receipt["sections"].append({"name": name, "va": hex(va), "bytes": size, "missing_pages": missing})
            if not args.json:
                print("%-8s %X %10d bytes, %d missing pages" % (name, va, size, missing))
        receipt["live"]["seconds"] = round(time.perf_counter() - t0, 2)
        receipt["live"]["alive_after"] = r.alive()
        with open(os.path.join(args.out, "sections.json"), "w") as f:
            json.dump(receipt, f, indent=1)
        emit(args, {"out": os.path.abspath(args.out), "bytes": total, "seconds": receipt["live"]["seconds"],
                    "base": hex(base), "module": modname, "found_by": how, "alive_after": receipt["live"]["alive_after"]},
             "%d bytes in %d sections -> %s (%.2f s, %s; process alive after: %s)" % (
                 total, len(secs), args.out, receipt["live"]["seconds"], how, receipt["live"]["alive_after"]))
    finally:
        r.close()
    return 0


# ---------------------------------------------------------------- trace / break (cdb)

HIT_RE = re.compile(r"ELVHIT (\d+) ([0-9a-fA-F]+)((?: [0-9a-fA-F`]+)*)\s*$")
RET_RE = re.compile(r"ELVRET (\d+)\s*$")
RAX_RE = re.compile(r"\brax=([0-9a-fA-F`]+)")
MARK_RE = re.compile(r"(?:^|> )ELV(READY|LIMIT|STOP)\s*$")  # a marker alone on its line (not inside a 'bl' listing)
BP_ERR_RE = re.compile(r"(Unable to (?:insert|set) breakpoint[^\r\n]*|Couldn't resolve error[^\r\n]*|"
                       r"Bp expression[^\r\n]*could not be resolved[^\r\n]*|\^ [^\r\n]*error[^\r\n]*)", re.I)


def cdb_expr(e):
    """A logged expression in cdb (MASM) syntax: bare register names get '@'."""
    regs = r"(?<![@\w$])(r[a-d]x|r[sd]i|r[sb]p|r(?:8|9|1[0-5])d?|rip|e[a-d]x|e[sd]i)(?!\w)"
    return re.sub(regs, r"@\1", e)


def build_script(points, logs, ret=False, mode="hw", hits=0, stack=0, regs=False, stop_at=(), deadline=None):
    """cdb commands (list of lines) that set one breakpoint per address and log each hit, then 'g'.

    A hit prints `ELVHIT <bp> <tid> <values>`; with ret, a one-shot breakpoint on the return address prints
    `ELVRET <bp> <tid>` and the 'r rax' line. When the hit counter reaches `hits`, the hit prints ELVLIMIT and stays
    broken in, so the driver removes every breakpoint and detaches."""
    if mode not in ("hw", "sw"):
        raise ToolError("mode is hw or sw")
    if mode == "hw" and len(points) * (2 if ret else 1) > 4:
        raise ToolError("hardware mode has 4 debug registers: %d addresses%s do not fit" % (
            len(points), " with --ret" if ret else ""))
    lines = [".symopt+ 0x80000", "sxd av", "sxd ch", "sxd ii", "sxd dz", "sxd c000041d", "sxd eh", "sxn out",
             "sxi ld", "sxi ud", "sxi ct", "sxi et", "r $t1 = 0"]
    vals = [cdb_expr(e) for e in logs]

    def count_then(go):
        # The counter is kept where the session may stop: at the return when --ret (so no return breakpoint is
        # pending when the driver detaches: a pending one killed the test process, measured), else at the hit.
        if hits:
            return "r $t1 = @$t1 + 1; .if (@$t1 >= 0n%d) { .echo ELVLIMIT } .else { %s }" % (hits, go)
        return go

    for i, addr in enumerate(points):
        # cdb text: .printf \"ELVHIT 0 %x %p\\n\", @$tid, @rcx  (quotes and backslash escaped once inside the bp string)
        fmt = "ELVHIT %d %%x%s\\\\n" % (i, " %p" * len(vals))
        body = []
        if ret:
            # first: .printf would take a later quoted string as one of its arguments (syntax error, measured)
            # 'ba' takes no /1 (syntax error, measured): the return breakpoint has its own id and clears itself
            rid = 10 + i
            setter = ("ba%d e1 @$ra" if mode == "hw" else "bp%d @$ra") % rid
            body.append("%s \\\".echo ELVRET %d; r rax; bc %d; %s\\\"" % (setter, i, rid, count_then("gc")))
        body.append(".printf \\\"%s\\\", @$tid%s" % (fmt, "".join(", " + v for v in vals)))
        if regs:
            body.append("r")
        if stack:
            body.append("kc %d" % stack)
        body.append("gc" if ret else count_then("gc"))
        cmd = "; ".join(body)
        lines.append(("ba%d e1 0x%X \"%s\"" if mode == "hw" else "bp%d 0x%X \"%s\"") % (i, addr, cmd))
    lines += stop_lines(stop_at, deadline)
    lines += ["bl", ".echo ELVREADY", "g"]
    return lines


STOP_IDS = (30, 31, 32, 33)


def stop_lines(stop_at, deadline=None):
    """Software breakpoints on often-called system functions (never in the game's code) that stop the session:
    at once (deadline None), or at the first call after the deadline, read from the system clock every process
    maps at 0x7FFE0014 (KUSER_SHARED_DATA SystemTime, 100 ns units). The game ignores a debugger's break-in
    request (DebugBreakProcess left the lab server frozen, measured 11 Nov 2026), so the session stops itself."""
    out = []
    for sid, fn in zip(STOP_IDS, stop_at or ()):
        if deadline is None:
            out.append("bp%d %s \".echo ELVSTOP\"" % (sid, fn))
        else:
            out.append("bp%d %s \"j (qwo(0x7ffe0014) > 0x%X) '.echo ELVSTOP'; 'gc'\"" % (sid, fn, deadline))
    return out


def system_time_100ns():
    """The value cdb reads at 0x7FFE0014: FILETIME of now (same clock in every process of the machine)."""
    ft = wintypes.FILETIME()
    ctypes.windll.kernel32.GetSystemTimeAsFileTime(ctypes.byref(ft))
    return (ft.dwHighDateTime << 32) | ft.dwLowDateTime


def parse_cdb_output(lines, nlogs, state=None):
    """Records from cdb output lines: hits, returns (emitted with their rax line), errors, protector messages,
    exceptions, ready/limit markers. Pass the same state dict when feeding one line at a time."""
    state = {} if state is None else state
    recs = []
    for raw in lines:
        t, line = raw if isinstance(raw, tuple) else (None, raw)
        m = HIT_RE.search(line)
        if m:
            vals = m.group(3).split()
            recs.append({"kind": "hit", "t": t, "bp": int(m.group(1)), "tid": int(m.group(2), 16),
                         "values": ["0x" + v.replace("`", "").lstrip("0").lower() if v.replace("`", "").strip("0")
                                    else "0x0" for v in vals[:nlogs]]})
            continue
        m = RET_RE.search(line)
        if m:
            state["ret"] = {"kind": "return", "t": t, "bp": int(m.group(1))}
            continue
        m = RAX_RE.search(line)
        if m and state.get("ret"):
            v = m.group(1).replace("`", "")
            state["ret"]["rax"] = "0x" + (v.lstrip("0").lower() or "0")
            recs.append(state.pop("ret"))
            continue
        mk = MARK_RE.search(line)
        if mk:
            recs.append({"kind": mk.group(1).lower(), "t": t})
        elif BP_ERR_RE.search(line):
            recs.append({"kind": "error", "t": t, "text": line.strip()})
        elif "Adjusting checksum" in line:
            recs.append({"kind": "protector", "t": t, "text": line.strip()})
        elif re.search(r"\(([0-9a-f]+)\.([0-9a-f]+)\): (.+?) - code ([0-9a-f]{8})", line):
            recs.append({"kind": "exception", "t": t, "text": line.strip()})
    return recs


def find_cdb(given):
    for p in ([given] if given else []) + DEFAULT_CDB:
        if p and os.path.exists(p):
            return p
    raise ToolError("cdb.exe not found (give --cdb)")


def cmd_trace(args, is_break=False):
    info = pick_process(args, intrusive=True)
    names = _names(args)
    r = Reader(args.pid)
    try:
        points = [evaluate(a, names, r.ptr) for a in args.at]
    finally:
        r.close()
    logs = args.log or (["rcx", "rdx", "r8", "r9"] if not is_break else [])
    hits = args.hits if args.hits is not None else (1 if is_break else 20)
    stop_at = [x.strip() for x in args.stop_at.split(",") if x.strip()]
    deadline = system_time_100ns() + int((args.seconds + 3) * 1e7)  # +3 s: the attach
    script = build_script(points, logs, ret=args.ret, mode=args.mode, hits=hits,
                          stack=(args.stack or (12 if is_break else 0)), regs=is_break, stop_at=stop_at,
                          deadline=deadline)
    cdb = find_cdb(args.cdb)
    symdir = os.path.join(os.environ.get("TEMP", "."), "engine_live_nosym")
    os.makedirs(symdir, exist_ok=True)
    env = {k: v for k, v in os.environ.items() if not k.upper().startswith("_NT_")}
    t0 = time.perf_counter()
    proc = subprocess.Popen([cdb, "-p", str(args.pid), "-pd", "-y", symdir, "-snul"], stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env,
                            creationflags=0x08000000)  # CREATE_NO_WINDOW
    q = queue.Queue()

    def pump():
        for b in iter(proc.stdout.readline, b""):
            q.put((round(time.perf_counter() - t0, 4), b.decode("utf-8", "replace").rstrip("\r\n")))
        q.put(None)

    threading.Thread(target=pump, daemon=True).start()
    proc.stdin.write(("\n".join(script) + "\n").encode())
    proc.stdin.flush()
    log, recs, pstate = [], [], {}
    state = {"ready": None, "limit": False, "stop": False, "ended": False, "broke_in": False}
    out = open(args.out, "w", encoding="utf-8") if args.out else None
    detach_at = None

    def take(timeout):
        try:
            item = q.get(timeout=timeout)
        except queue.Empty:
            return False
        if item is None:
            state["ended"] = True
            return True
        log.append(item)
        if re.search(r"(?:^|> )ELVPING\s*$", item[1]):
            state["ping"] = True
        new = parse_cdb_output([item], len(logs), pstate)
        if is_break and not new and state.get("last_hit") is not None and "ELV" not in item[1]:
            d = state["last_hit"].setdefault("detail", [])  # registers and stack printed after the hit line
            if len(d) < 80 and item[1].strip():
                d.append(item[1].rstrip())
        for rec in new:
            if rec["kind"] == "hit":
                state["last_hit"] = rec
            elif rec["kind"] in ("limit", "ready", "stop"):
                state["last_hit"] = None
            recs.append(rec)
            if rec["kind"] == "ready":
                state["ready"] = item[0]
            if rec["kind"] == "limit":
                state["limit"] = True
            if rec["kind"] == "stop":
                state["stop"] = True
                state.setdefault("deadline_stop", not state["limit"])
            if rec["kind"] in ("hit", "return"):
                rec["wall"] = _dt.datetime.now(_dt.timezone.utc).isoformat()
                if out:
                    out.write(json.dumps(rec) + "\n")
                    out.flush()
                if not args.json:
                    print("%8.3f s  %s" % (rec["t"], json.dumps({k: v for k, v in rec.items() if k not in ("t", "wall")})),
                          flush=True)
        return True

    try:
        attach_limit = time.perf_counter() + 60
        while state["ready"] is None and not state["ended"] and time.perf_counter() < attach_limit:
            take(0.5)
        if state["ready"] is None:
            raise ToolError("cdb did not attach (ended: %s):\n" % state["ended"] + "\n".join(l for _, l in log[-25:]))
        # the stop breakpoints fire at the first call after the deadline; wait a little longer than that
        wait_end = time.perf_counter() + args.seconds + 20
        while not (state["limit"] or state["stop"]) and not state["ended"] and time.perf_counter() < wait_end:
            take(0.25)
        # The detach protocol (each rule measured, see docs):
        #   - the game ignores break-in requests: a session stops itself (hit limit, or a stop breakpoint on a
        #     system function after the deadline); a break-in is only the last resort, and cdb is never killed
        #     while attached (a killed cdb left the lab server frozen, measured 11 Nov 2026);
        #   - never detach right after clearing a hardware breakpoint: its debug registers stay set until the
        #     debugger resumes the threads once, and the next hit after the detach kills the process (measured);
        # So: once stopped, clear every breakpoint, arm an immediate stop breakpoint, run; at that software
        # breakpoint (all debug registers written back by the run), clear it and detach.
        if not state["ended"] and not (state["limit"] or state["stop"]):
            state["ping"] = False
            proc.stdin.write(b".echo ELVPING\n")
            proc.stdin.flush()
            t_end = time.perf_counter() + 1.0
            while time.perf_counter() < t_end and not state["ping"] and not state["ended"]:
                take(0.1)
            if not state["ping"] and not state["ended"]:
                _break_in(args.pid)
                state["broke_in"] = True
                t_end = time.perf_counter() + 75  # dbgeng suspends the threads itself after 30 s
                while time.perf_counter() < t_end and not state["ping"] and not state["ended"]:
                    take(0.25)
                if not state["ping"] and not state["ended"]:
                    state["left_attached"] = True
                    raise ToolError("cdb did not stop; it stays attached with -pd (pid %d): do not kill it" % proc.pid)
        if not state["ended"]:
            state["stop"] = False
            proc.stdin.write(("bc *\n" + "\n".join(stop_lines(stop_at)) + "\ng\n").encode())
            proc.stdin.flush()
            t_end = time.perf_counter() + 30
            while time.perf_counter() < t_end and not state["stop"] and not state["ended"]:
                take(0.1)
            if not state["stop"] and not state["ended"]:
                state["left_attached"] = True
                raise ToolError("the stop breakpoint (%s) was not reached in 30 s; cdb stays attached (pid %d)" % (
                    ", ".join(stop_at), proc.pid))
        detach_at = round(time.perf_counter() - t0, 3)
        proc.stdin.write(b"bc *\nqd\n")
        proc.stdin.flush()
        try:
            proc.wait(timeout=30)
        except subprocess.TimeoutExpired:
            state["left_attached"] = True
        while take(0.2):
            if state["ended"]:
                break
    finally:
        if out:
            out.close()
        if args.cdb_log:
            with open(args.cdb_log, "w", encoding="utf-8") as f:
                f.write("\n".join(script) + "\n----\n")
                f.write("\n".join("%9.3f %s" % x for x in log))
        if proc.poll() is None and not state.get("left_attached"):
            proc.stdin.close()  # end of input: cdb quits and, with -pd, detaches
    # The process must still run after the detach, also 2 s later (a stray break left behind kills it only then).
    time.sleep(2.0)
    k = _k32()
    after = process_info(k, args.pid)
    alive = bool(after.get("created_utc") and after["created_utc"] == info["created_utc"])
    if alive:
        rr = Reader(args.pid)
        alive = rr.alive()
        rr.close()
    hit_recs = [x for x in recs if x["kind"] == "hit"]
    summary = {"pid": args.pid, "mode": args.mode, "points": [hex(p) for p in points], "logs": logs,
               "hits": len(hit_recs), "returns": len([x for x in recs if x["kind"] == "return"]),
               "limit_reached": state["limit"], "stopped_by_deadline": bool(state.get("deadline_stop")),
               "broke_in": state["broke_in"], "left_attached": bool(state.get("left_attached")),
               "attach_s": state["ready"], "detach_at_s": detach_at, "total_s": round(time.perf_counter() - t0, 3),
               "process_alive_after_detach": alive, "cdb_exit": proc.returncode,
               "errors": [x["text"] for x in recs if x["kind"] == "error"],
               "protector_lines": len([x for x in recs if x["kind"] == "protector"]),
               "exceptions": [x["text"] for x in recs if x["kind"] == "exception"][:20]}
    if is_break:
        summary["hit_records"] = hit_recs  # each with 'detail': the registers and the call stack
    if args.out:
        with open(args.out, "a", encoding="utf-8") as f:
            f.write(json.dumps({"kind": "summary", **summary}) + "\n")
    emit(args, summary, "\n".join("%s: %s" % kv for kv in summary.items()))
    return 0 if alive and not summary["errors"] else 1


def _break_in(pid):
    k = _k32()
    h = k.OpenProcess(0x1F0FFF, False, pid)
    if not h:
        raise ToolError("cannot open %d to break in (%d)" % (pid, ctypes.get_last_error()))
    try:
        if not k.DebugBreakProcess(h):
            raise ToolError("DebugBreakProcess failed (%d)" % ctypes.get_last_error())
    finally:
        k.CloseHandle(h)


# ---------------------------------------------------------------- command line

def build_parser():
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--json", action="store_true", help="one JSON object (or JSONL) on stdout")
    common.add_argument("--bench-parent", default=DEFAULT_BENCH_PARENT)
    target = argparse.ArgumentParser(add_help=False)
    target.add_argument("--pid", type=int)
    target.add_argument("--i-own-it", metavar="IMAGE", help="skip the bench/lease checks for exactly this image path")
    target.add_argument("--names", default=DEFAULT_NAMES)
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("ps", parents=[common], help="list iw7 processes and say which are ours")
    p = sub.add_parser("read", parents=[common, target])
    p.add_argument("expr")
    p.add_argument("--type", default="u32")
    p.add_argument("--size", type=int, help="raw bytes (hex) instead of a type")
    p.add_argument("--count", type=int, default=1)
    p = sub.add_parser("deref", parents=[common, target])
    p.add_argument("expr")
    p = sub.add_parser("watch", parents=[common, target])
    p.add_argument("spec", nargs="+")
    p.add_argument("--out")
    p = sub.add_parser("dump", parents=[common, target])
    p.add_argument("--out", required=True)
    p.add_argument("--module", default="iw7_ship.exe")
    p.add_argument("--max-bytes", type=lambda s: int(s, 0), default=0xA000000)
    for name in ("trace", "break"):
        p = sub.add_parser(name, parents=[common, target])
        p.add_argument("--session", help="the runner's session folder (the lease scope of the process)")
        p.add_argument("--at", action="append", required=True, help="address expression (repeat)")
        p.add_argument("--log", action="append", help="cdb expression to log at each hit (repeat): rcx, "
                                                      "poi(rcx+8), by(rdx+0x546)")
        p.add_argument("--ret", action="store_true", help="also log rax when the function returns")
        p.add_argument("--hits", type=int, help="stop after this many hits (trace 20, break 1)")
        p.add_argument("--seconds", type=float, default=30.0, help="stop after this long")
        p.add_argument("--mode", choices=("hw", "sw"), default="hw")
        p.add_argument("--stack", type=int, default=0, help="frames of call stack at each hit")
        p.add_argument("--out", help="JSONL of hits and a summary line")
        p.add_argument("--cdb-log", help="the cdb script and its whole output")
        p.add_argument("--stop-at", default="ntdll!NtDelayExecution",
                       help="system functions (comma separated) whose next call stops the session: software "
                            "breakpoints outside the game code; the process must call one often")
        p.add_argument("--cdb")
    return ap


def main(argv=None):
    args = build_parser().parse_args(argv)
    try:
        if args.cmd == "ps":
            return cmd_ps(args)
        if args.cmd == "read":
            return cmd_read(args)
        if args.cmd == "deref":
            return cmd_deref(args)
        if args.cmd == "watch":
            return cmd_watch(args)
        if args.cmd == "dump":
            return cmd_dump(args)
        return cmd_trace(args, is_break=args.cmd == "break")
    except ToolError as e:
        if getattr(args, "json", False):
            print(json.dumps({"error": str(e)}))
        else:
            print("engine_live: " + str(e), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
