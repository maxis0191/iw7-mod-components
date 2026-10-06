"""Agent-oriented IW7 evidence analysis. Standard library only; JSON on stdout.

Raw evidence stays under ignored runtime. No process writes, launches or game assets
are needed for these commands. Call Debug-Server.ps1 for Windows acquisition.
"""
import argparse
from collections import Counter, defaultdict
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import re
import struct
import subprocess
import sys
import uuid
import zipfile

REPO = Path(__file__).resolve().parents[1]
MAX_INPUT = 256 * 1024 * 1024
SCHEMA = "iw7.debugger/1"


def digest(path):
    with Path(path).open("rb") as f:
        return hashlib.file_digest(f, "sha256").hexdigest()


def read_bytes(path, limit=MAX_INPUT):
    p = Path(path)
    if p.stat().st_size > limit:
        raise ValueError(f"Input exceeds {limit} bytes: {p.name}")
    return p.read_bytes()


def emit(value):
    print(json.dumps(value, ensure_ascii=False, allow_nan=False, indent=2))


def git(*args, root=REPO):
    r = subprocess.run(["git", "-C", str(root), *args], capture_output=True,
                       text=True, encoding="utf-8", errors="replace", timeout=20)
    if r.returncode:
        raise ValueError(r.stderr.strip() or "Git command failed")
    return r.stdout.strip()


def local_output(path):
    runtime = REPO / "runtime"
    # Refuse redirected parent components and writes outside ignored scratch.
    if runtime.resolve() != runtime.absolute():
        raise ValueError("Runtime is redirected")
    p = Path(path).absolute()
    if p.resolve() != p or not p.is_relative_to(runtime) or p == runtime:
        raise ValueError("Output must be under this worktree's unredirected runtime")
    if p.exists():
        raise ValueError("Refusing to overwrite evidence")
    p.parent.mkdir(parents=True, exist_ok=True)
    if p.resolve() != p:
        raise ValueError("Output parent is redirected")
    return p


def save(path, value):
    with local_output(path).open("x", encoding="utf-8") as f:
        json.dump(value, f, indent=2, ensure_ascii=False, allow_nan=False)
        f.write("\n")


def scrub(text):
    text = re.sub(r"(?i)((?:g_password|password|token|secret|authorization|api[_-]?key)\s*[:= ]\s*)[^\s;,]+", r"\1[redacted]", text)
    text = re.sub(r"\b(?:\d{1,3}\.){3}\d{1,3}(?::\d+)?\b", "[endpoint]", text)
    text = re.sub(r"(?i)\b[0-9a-f]{16}\b", "[identifier]", text)
    return text[:1000]


# Symptoms are classified, never automatically promoted to root causes.
RULES = [
    ("gsc.link", "error", r"unknown (?:script|function)|script link error", "Inspect dependency graph and actual loaded ScriptFiles."),
    ("gsc.compile", "error", r"compil(?:e|ation|er) error|syntax error|\[ERROR\]", "Parse then compile the named script; parser success is not linkage."),
    ("gsc.runtime", "error", r"script runtime error|script error|stack overflow|undefined is not|parameter .*does not exist", "Correlate the fresh GSC stack with the exact source hashes."),
    ("asset.capacity", "fatal", r"Exceeded limit of .* assets|Out of custom script memory|out of .* memory", "Reduce the dependency closure; retain the failing asset type and map."),
    ("native.exception", "fatal", r"0xC0000005|access violation|exception code|fatal error|crash dump", "Analyze exception context and matching binary/PDB; the faulting module alone is not causality."),
    ("native.heap", "fatal", r"heap corruption|0xC0000374|0xC0000409|VERIFIER STOP", "Use a separately scoped PageHeap/verifier reproduction, with memory admission."),
    ("fixture.safety", "error", r"protection failure|protected=0|godmode=0|EXE_PLAYERKICKED_INACTIVE", "Invalidate encounter evidence until current engine protection is verified."),
    ("network.symptom", "warning", r"timed? ?out|timeout|reliable command overflow|lost connection|packet.*reject", "Capture paired server/client telemetry; a timeout alone proves neither crash nor zero clients."),
    ("engine.warning", "warning", r"WARNING|missing .*asset|default asset", "Check load phase and stock baseline before attributing this warning to a mod."),
]


def log_events(path):
    raw = read_bytes(path)
    text = raw.decode("utf-8-sig", errors="replace")
    if raw.startswith(b"\xff\xfe"):
        text = raw.decode("utf-16", errors="replace")
    events = []
    for line_num, line in enumerate(text.splitlines(), 1):
        for code, severity, pattern, action in RULES:
            if re.search(pattern, line, re.I):
                stamp = re.search(r"\b(?:\d{4}-\d\d-\d\d[T ][\d:.+-]+|tick_ms=\d+)\b", line)
                events.append({"line": line_num, "code": code, "severity": severity,
                               "text": scrub(line), "timestamp": stamp.group() if stamp else None,
                               "next_action": action, "causality": "unproven"})
                break
    counts = Counter(e["code"] for e in events)
    return {"schema": SCHEMA, "kind": "logs", "file": Path(path).name,
            "sha256": digest(path), "lines": len(text.splitlines()),
            "counts": dict(counts), "events": events[:2000],
            "events_truncated": len(events) > 2000,
            "scope": "Whole supplied file, including historical phases. Freshness needs capture identity/time."}


class MiniDump:
    def __init__(self, data):
        self.data = data
        if len(data) < 32 or data[:4] != b"MDMP":
            raise ValueError("Not a Windows minidump")
        count, directory = self.unpack("<II", 8)
        if count > 4096:
            raise ValueError("Excessive stream count")
        self.streams = {}
        for i in range(count):
            kind, size, offset = self.unpack("<III", directory + i * 12)
            self.slice(offset, size)
            if kind == 0 and size == 0:  # UnusedStream placeholders are repeated by DbgHelp.
                continue
            if kind in self.streams:
                raise ValueError("Duplicate minidump stream")
            self.streams[kind] = (offset, size)

    def slice(self, offset, size):
        if offset < 0 or size < 0 or offset + size > len(self.data):
            raise ValueError("Truncated or invalid minidump range")
        return self.data[offset:offset + size]

    def unpack(self, fmt, offset):
        return struct.unpack(fmt, self.slice(offset, struct.calcsize(fmt)))

    def stream(self, kind, minimum):
        if kind not in self.streams:
            return None
        offset, size = self.streams[kind]
        if size < minimum:
            raise ValueError("Truncated minidump stream")
        return offset, size

    def string(self, offset):
        size, = self.unpack("<I", offset)
        if size > 65536 or size % 2:
            raise ValueError("Invalid dump string")
        return self.slice(offset + 4, size).decode("utf-16-le", errors="replace")

    def summary(self):
        modules = []
        s = self.stream(4, 4)
        if s:
            base, length = s
            count, = self.unpack("<I", base)
            if count > 4096 or 4 + count * 108 > length:
                raise ValueError("Invalid module count")
            for i in range(count):
                pos = base + 4 + i * 108
                address, size, checksum, timestamp, name = self.unpack("<QIIII", pos)
                cv_size, cv_offset = self.unpack("<II", pos + 76)
                cv = self.slice(cv_offset, cv_size)
                pdb = None
                if cv[:4] == b"RSDS":
                    if len(cv) < 24:
                        raise ValueError("Truncated RSDS")
                    pdb = {"guid": str(uuid.UUID(bytes_le=cv[4:20])),
                           "age": struct.unpack_from("<I", cv, 20)[0],
                           "name": Path(cv[24:].split(b"\0")[0].decode(errors="replace").replace("\\", "/")).name}
                modules.append({"name": Path(self.string(name).replace("\\", "/")).name,
                                "base": hex(address), "size": size, "timestamp": timestamp,
                                "checksum": checksum, "pdb": pdb})
        exception = None
        s = self.stream(6, 168)
        if s:
            pos, _ = s
            thread, = self.unpack("<I", pos)
            code, flags, record, address, count = self.unpack("<IIQQI", pos + 8)
            if count > 15:
                raise ValueError("Invalid exception parameter count")
            params = list(self.unpack("<" + "Q" * count, pos + 40))
            module = next((m for m in modules if int(m["base"], 16) <= address < int(m["base"], 16) + m["size"]), None)
            exception = {"thread_id": thread, "code": f"0x{code:08X}", "flags": flags,
                         "address": hex(address), "parameters": [hex(v) for v in params],
                         "module": module["name"] if module else None,
                         "rva": hex(address - int(module["base"], 16)) if module else None}
            if code == 0xC0000005 and len(params) >= 2:
                exception["access"] = {0: "read", 1: "write", 8: "execute"}.get(params[0], "unknown")
                exception["target"] = hex(params[1])
        threads = None
        s = self.stream(3, 4)
        if s:
            threads, = self.unpack("<I", s[0])
            if threads > 100000 or 4 + threads * 48 > s[1]:
                raise ValueError("Invalid thread list")
        return {"modules": modules, "exception": exception, "threads": threads,
                "streams": sorted(self.streams), "stack": "Use CDB with matching symbols for unwinding.",
                "causality": "Fault context only; faulting module may be a victim of earlier corruption."}


def dump_report(path):
    if Path(path).suffix.lower() == ".zip":
        with zipfile.ZipFile(path) as archive:
            entries = [x for x in archive.infolist() if x.filename.lower().endswith((".dmp", ".mdmp"))]
            if len(entries) != 1 or entries[0].file_size > MAX_INPUT:
                raise ValueError("Expected one bounded minidump in ZIP")
            data = archive.read(entries[0])
    else:
        data = read_bytes(path)
    return {"schema": SCHEMA, "kind": "dump", "sha256": digest(path),
            "dump_sha256": hashlib.sha256(data).hexdigest(), **MiniDump(data).summary()}


def pe_identity(path):
    data = read_bytes(path)
    if data[:2] != b"MZ" or len(data) < 64:
        raise ValueError("Not a PE image")
    pe, = struct.unpack_from("<I", data, 60)
    def take(fmt, off):
        if off < 0 or off + struct.calcsize(fmt) > len(data):
            raise ValueError("Invalid PE range")
        return struct.unpack_from(fmt, data, off)
    if data[pe:pe + 4] != b"PE\0\0":
        raise ValueError("Invalid PE signature")
    machine, sections, timestamp = take("<HHI", pe + 4)
    opt_size, = take("<H", pe + 20)
    opt = pe + 24
    magic, = take("<H", opt)
    if magic not in (0x10b, 0x20b) or sections > 96:
        raise ValueError("Unsupported PE")
    image_base, = take("<Q" if magic == 0x20b else "<I", opt + (24 if magic == 0x20b else 28))
    size, = take("<I", opt + 56)
    number_offset = 108 if magic == 0x20b else 92
    directories = number_offset + 4
    dir_count, = take("<I", opt + number_offset)
    if opt_size < directories or directories + min(dir_count, 16) * 8 > opt_size:
        raise ValueError("Invalid PE directories")
    def rva_offset(rva, required):
        for i in range(sections):
            vs, va, raw_size, raw_off = take("<IIII", opt + opt_size + i * 40 + 8)
            if va <= rva and rva + required <= va + raw_size:
                return raw_off + rva - va
        raise ValueError("PE directory outside file-backed sections")
    pdb = None
    if dir_count > 6:
        debug_rva, debug_size = take("<II", opt + directories + 6 * 8)
        if debug_rva:
            if debug_size % 28 or debug_size > 28 * 1024:
                raise ValueError("Invalid PE debug directory")
            debug = rva_offset(debug_rva, debug_size)
            for i in range(debug_size // 28):
                typ, cv_size, cv_rva, cv_off = take("<IIII", debug + i * 28 + 12)
                if typ == 2 and cv_size >= 24:
                    if cv_off + cv_size > len(data):
                        raise ValueError("Invalid PE CodeView range")
                    cv = data[cv_off:cv_off + cv_size]
                    if cv[:4] == b"RSDS":
                        pdb = {"guid": str(uuid.UUID(bytes_le=cv[4:20])),
                               "age": struct.unpack_from("<I", cv, 20)[0],
                               "name": Path(cv[24:].split(b"\0")[0].decode(errors="replace").replace("\\", "/")).name}
    return {"name": Path(path).name, "sha256": digest(path), "machine": hex(machine),
            "timestamp": timestamp, "size_of_image": size, "image_base": hex(image_base), "pdb": pdb}


def pdb_identity(path):
    data = read_bytes(path)
    if not data.startswith(b"Microsoft C/C++ MSF 7.00\r\n\x1aDS\0\0\0"):
        raise ValueError("Expected PDB MSF 7.0")
    block_size, free_map, blocks, directory_size, reserved, block_map = struct.unpack_from("<6I", data, 32)
    if block_size not in (512, 1024, 2048, 4096, 8192) or directory_size > 16 * 1024 * 1024 or blocks * block_size > len(data):
        raise ValueError("Invalid PDB superblock")
    def block(number):
        if number >= blocks:
            raise ValueError("Invalid PDB block")
        return data[number * block_size:(number + 1) * block_size]
    n = (directory_size + block_size - 1) // block_size
    if n * 4 > block_size:
        raise ValueError("Unsupported multi-block PDB directory map")
    nums = struct.unpack_from("<" + "I" * n, block(block_map))
    directory = b"".join(block(x) for x in nums)[:directory_size]
    if len(directory) < 12:
        raise ValueError("Truncated PDB directory")
    streams, = struct.unpack_from("<I", directory)
    if streams < 2 or streams > 100000 or 4 + streams * 4 > len(directory):
        raise ValueError("Invalid PDB streams")
    sizes = struct.unpack_from("<" + "I" * streams, directory, 4)
    cursor = 4 + streams * 4
    info = None
    for index, size in enumerate(sizes):
        count = 0 if size == 0xFFFFFFFF else (size + block_size - 1) // block_size
        if cursor + count * 4 > len(directory):
            raise ValueError("Invalid PDB stream blocks")
        if index == 1:
            numbers = struct.unpack_from("<" + "I" * count, directory, cursor)
            info = b"".join(block(x) for x in numbers)[:size]
        cursor += count * 4
    if info is None or len(info) < 28:
        raise ValueError("Missing PDB info stream")
    version, signature, age = struct.unpack_from("<III", info)
    return {"guid": str(uuid.UUID(bytes_le=info[12:28])), "age": age,
            "sha256": digest(path), "name": Path(path).name}


def symbols_report(image, pdb, dump=None):
    pe, symbols = pe_identity(image), pdb_identity(pdb)
    matched = pe["pdb"] is not None and all(pe["pdb"][k] == symbols[k] for k in ("guid", "age"))
    dump_match = None
    if dump:
        ds = dump_report(dump)
        dump_match = any(m["pdb"] and pe["pdb"] and
                         all(m["pdb"][k] == pe["pdb"][k] for k in ("guid", "age")) and
                         m["timestamp"] == pe["timestamp"] and m["size"] == pe["size_of_image"]
                         for m in ds["modules"])
    return {"schema": SCHEMA, "kind": "symbols", "image": pe, "pdb": symbols,
            "image_pdb_match": matched, "dump_image_match": dump_match,
            "valid": matched and dump_match is not False}


def strip_comments_strings(text):
    pattern = r'//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\''
    return re.sub(pattern, lambda m: "".join("\n" if c == "\n" else " " for c in m.group()), text)


def source_index(root):
    root = Path(root).resolve()
    tracked = git("ls-files", "src", "tests/fixtures", root=root).splitlines()
    files, functions, warnings = [], [], []
    for rel in tracked:
        path = root / rel
        if path.suffix not in (".gsc", ".cpp", ".hpp") or not path.exists():
            continue
        raw = read_bytes(path, 4 * 1024 * 1024).decode("utf-8-sig", errors="replace")
        clean = strip_comments_strings(raw)
        files.append({"path": rel, "sha256": digest(path)})
        if path.suffix != ".gsc":
            continue
        for match in re.finditer(r"(?m)^[ \t]*([A-Za-z_]\w*)\s*\([^;{}]*\)\s*\{", clean):
            name = match[1]
            if name in ("if", "while", "for", "foreach", "switch", "catch"):
                continue
            start, depth, end = match.end(), 1, match.end()
            while end < len(clean) and depth:
                depth += (clean[end] == "{") - (clean[end] == "}")
                end += 1
            body = clean[start:end - 1]
            line = clean.count("\n", 0, match.start()) + 1
            calls = sorted(set(re.findall(r"(?<![\w])((?:[\w/]+::)?[A-Za-z_]\w*)\s*\(", body)) - {"if", "while", "for", "foreach", "switch"})
            functions.append({"path": rel, "name": name, "line": line,
                              "end_line": clean.count("\n", 0, end) + 1, "calls": calls,
                              "threads": len(re.findall(r"\bthread\b", body)),
                              "loops": len(re.findall(r"\b(?:while|for)\s*\(", body)),
                              "yield_tokens": len(re.findall(r"\b(?:wait|waittill|waittill_any|waittillframeend)\b", body))})
            if functions[-1]["loops"] and not functions[-1]["yield_tokens"]:
                warnings.append({"path": rel, "line": line, "function": name,
                                 "code": "review.loop_without_local_yield",
                                 "meaning": "Heuristic only: finite loops and yielding callees can be correct."})
    return {"schema": SCHEMA, "kind": "source-index", "commit": git("rev-parse", "HEAD", root=root),
            "dirty": bool(git("status", "--porcelain", root=root)), "files": files,
            "functions": functions, "review_hints": warnings,
            "limits": "Lexical GSC index, not a compiler or dynamic call graph. Native source hashes retained."}


def quantiles(values):
    xs = sorted(float(v) for v in values if isinstance(v, (int, float)) and math.isfinite(v))
    if not xs:
        return None
    def p(q):
        pos = (len(xs) - 1) * q
        low = int(pos)
        return xs[low] + (xs[min(low + 1, len(xs) - 1)] - xs[low]) * (pos - low)
    return {"count": len(xs), "mean": sum(xs) / len(xs), "p50": p(.5), "p95": p(.95), "p99": p(.99), "max": xs[-1]}


def jsonl(path):
    if Path(path).stat().st_size > MAX_INPUT:
        raise ValueError("Trace too large")
    with Path(path).open(encoding="utf-8-sig") as f:
        for n, line in enumerate(f, 1):
            if len(line) > 1024 * 1024:
                raise ValueError(f"Excessive JSONL row {n}")
            if line.strip():
                value = json.loads(line, parse_constant=lambda x: (_ for _ in ()).throw(ValueError("Non-finite JSON")))
                if not isinstance(value, dict):
                    raise ValueError(f"Expected object at JSONL row {n}")
                yield value


def builtin_labels(root):
    labels = {"engine_scope:1": "server_engine_and_scheduler", "engine_scope:2": "main_engine_call"}
    if root:
        for category, filename in (("gsc_function", "iw7_func.cpp"), ("gsc_method", "iw7_meth.cpp")):
            text = read_bytes(Path(root) / filename, 1024 * 1024).decode("utf-8-sig")
            for ident, name in re.findall(r'\{\s*(0x[0-9A-Fa-f]+)\s*,\s*"([a-zA-Z0-9_]+)"\s*\}', text):
                labels[f"{category}:{int(ident, 16)}"] = f"{category}:{name}"
    return labels


def perf_report(path, token_root=None):
    metrics, timings = defaultdict(list), defaultdict(lambda: {"calls": 0, "total_us": 0., "max_us": 0., "windows": 0})
    coverage = Counter()
    context, identities, high_pressure = [], [], 0
    labels = builtin_labels(token_root)
    for row in jsonl(path):
        typ = row.get("type", row.get("Type", "unknown"))
        coverage[typ] += 1
        if typ == "header":
            context.append(row.get("scenario", row.get("limits")))
            identities.append(row.get("identity"))
        elif typ == "sample":
            for key in ("cpu_core_percent", "private_bytes", "working_set", "read_bytes_delta", "write_bytes_delta", "thread_count", "physical_percent", "commit_percent", "udp_rtt_ms"):
                if row.get(key) is not None:
                    metrics[key].append(row[key])
            if row.get("physical_percent", 0) > 80 or row.get("commit_percent", 0) > 85:
                high_pressure += 1
            for thread in row.get("threads", []):
                metrics[f"thread_{thread['id']}_cpu_core_percent"].append(thread["cpu_core_percent"])
        elif typ == "timing":
            key = str(row.get("label", f"{row.get('category')}:{row.get('id')}"))
            key = labels.get(key, key)
            entry = timings[key]
            entry["calls"] += int(row["calls"])
            entry["total_us"] += float(row["total_us"])
            entry["max_us"] = max(entry["max_us"], float(row["max_us"]))
            entry["windows"] += 1
            entry["started"] = entry.get("started", 0) + int(row.get("started", row["calls"]))
    hot = [{"label": key, **value, "mean_us": value["total_us"] / value["calls"] if value["calls"] else None}
           for key, value in timings.items()]
    hot.sort(key=lambda x: x["total_us"], reverse=True)
    return {"schema": SCHEMA, "kind": "performance", "sha256": digest(path),
            "builtin_map": {"root": str(token_root), "hashes": [digest(Path(token_root) / f) for f in ("iw7_func.cpp", "iw7_meth.cpp")]} if token_root else None,
            "coverage": dict(coverage), "context": context, "identities": identities,
            "metrics": {k: quantiles(v) for k, v in metrics.items()}, "hotspots": hot,
            "high_pressure_samples": high_pressure,
            "acceptance": "invalid under memory pressure" if high_pressure else "observation; scenario/repetition/overhead controls required",
            "limits": "CPU uses one-core scale (100% = one busy logical CPU). Wall scopes overlap; do not sum nested timings. No renderer FPS claim."}


def compare_reports(before, after):
    a, b = perf_report(before), perf_report(after)
    changes = []
    for key in sorted(set(a["metrics"]) & set(b["metrics"])):
        av, bv = a["metrics"][key]["p95"], b["metrics"][key]["p95"]
        changes.append({"metric": key, "before_p95": av, "after_p95": bv,
                        "delta_percent": 100 * (bv - av) / av if av else None})
    return {"schema": SCHEMA, "kind": "comparison", "changes": changes,
            "contexts_match": a["context"] == b["context"],
            "pressure_free": not a["high_pressure_samples"] and not b["high_pressure_samples"],
            "conclusion": "Descriptive difference only; equal workloads, settings, duration and repeated A/B are required for optimization evidence."}


def cdb_report(path):
    text = read_bytes(path).decode("utf-8-sig", errors="replace")
    # CDB sometimes writes UTF-16, depending on debugger settings.
    if "\x00" in text[:200]:
        text = read_bytes(path).decode("utf-16", errors="replace")
    fields = {}
    for key in ("EXCEPTION_CODE", "EXCEPTION_CODE_STR", "MODULE_NAME", "IMAGE_NAME", "SYMBOL_NAME", "FAILURE_BUCKET_ID"):
        m = re.search(r"(?m)^\s*" + key + r"\s*:\s*(.+)$", text)
        if m:
            fields[key.lower()] = scrub(m[1].strip())
    stack = [scrub(s) for s in text.splitlines() if re.match(r"^\s*[0-9a-f`]+\s+[0-9a-f`]+\s+", s, re.I)][:100]
    warnings = [scrub(s) for s in text.splitlines() if re.search(r"mismatch|unable to|wrong symbols|symbols could not|ERROR:", s, re.I)][:100]
    return {"schema": SCHEMA, "kind": "cdb", "sha256": digest(path), "fields": fields,
            "stack_candidates": stack, "warnings": warnings,
            "causality": "Stack context, not proof of the initiating corruptor. Check symbols report and earliest fault."}


def address_report(image, address):
    pe = pe_identity(image)
    base = int(pe["image_base"], 16)
    rva = address - base
    if rva < 0 or rva >= pe["size_of_image"]:
        raise ValueError("Address outside preferred image; pass preferred VA, not relocated VA")
    return {"schema": SCHEMA, "kind": "address", "image": pe, "preferred_va": hex(address),
            "rva": hex(rva), "next_action": "Use CDB ln/u for matching unpacked memory, or a selected-function Ghidra list; packed PE bytes may differ."}


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--output", help="New JSON file under ignored runtime")
    subs = p.add_subparsers(dest="command", required=True)
    for cmd in ("logs", "dump", "cdb"):
        subs.add_parser(cmd).add_argument("input")
    s = subs.add_parser("perf"); s.add_argument("input"); s.add_argument("--token-root")
    s = subs.add_parser("index"); s.add_argument("--root", default=str(REPO))
    s = subs.add_parser("symbols"); s.add_argument("--image", required=True); s.add_argument("--pdb", required=True); s.add_argument("--dump")
    s = subs.add_parser("compare"); s.add_argument("before"); s.add_argument("after")
    s = subs.add_parser("address"); s.add_argument("--image", required=True); s.add_argument("--va", type=lambda v: int(v, 0), required=True)
    s = subs.add_parser("blame"); s.add_argument("file"); s.add_argument("--line", type=int, required=True); s.add_argument("--root", default=str(REPO))
    s = subs.add_parser("case"); s.add_argument("--scenario", required=True); s.add_argument("--artifacts", nargs="*", default=[])
    s = subs.add_parser("report"); s.add_argument("inputs", nargs="+")
    args = p.parse_args(argv)
    if args.command in ("logs", "dump", "perf", "cdb"):
        result = perf_report(args.input, args.token_root) if args.command == "perf" else {"logs": log_events, "dump": dump_report, "cdb": cdb_report}[args.command](args.input)
    elif args.command == "index":
        result = source_index(args.root)
    elif args.command == "symbols":
        result = symbols_report(args.image, args.pdb, args.dump)
    elif args.command == "compare":
        result = compare_reports(args.before, args.after)
    elif args.command == "address":
        result = address_report(args.image, args.va)
    elif args.command == "blame":
        rel = Path(args.file)
        if rel.is_absolute() or ".." in rel.parts or args.line < 1:
            raise ValueError("Expected repository-relative source and positive line")
        result = {"schema": SCHEMA, "kind": "history", "file": args.file, "line": args.line,
                  "blame": git("blame", "--porcelain", "-L", f"{args.line},{args.line}", "--", str(rel), root=args.root),
                  "history": git("log", "-8", "--format=%H %s", "--", str(rel), root=args.root),
                  "causality": "Change attribution, not runtime culpability."}
    elif args.command == "case":
        result = {"schema": SCHEMA, "kind": "case", "id": str(uuid.uuid4()),
                  "created_utc": datetime.now(timezone.utc).isoformat(), "scenario": args.scenario,
                  "source_commit": git("rev-parse", "HEAD"), "dirty": bool(git("status", "--porcelain")),
                  "artifacts": [{"path": str(Path(x).resolve()), "sha256": digest(x), "bytes": Path(x).stat().st_size} for x in args.artifacts],
                  "hypotheses": [], "owner_acceptance": "not established"}
    elif args.command == "report":
        reports = [json.loads(read_bytes(x).decode("utf-8-sig")) for x in args.inputs]
        if any(x.get("schema") != SCHEMA for x in reports):
            raise ValueError("Report schema mismatch")
        result = {"schema": SCHEMA, "kind": "report", "evidence": reports,
                  "root_cause": "not automatically established", "next_actions": sorted(set(
                      e["next_action"] for r in reports for e in r.get("events", [])))}
    if args.output:
        save(args.output, result)
    emit(result)
    return 2 if result.get("kind") == "symbols" and not result["valid"] else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, struct.error, zipfile.BadZipFile, subprocess.TimeoutExpired) as exc:
        emit({"schema": SCHEMA, "kind": "error", "error": str(exc)})
        sys.exit(1)
