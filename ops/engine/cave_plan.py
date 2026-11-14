#!/usr/bin/env python3
"""Cave planner: move one or more instructions to a code cave so one of them can get a longer encoding.

Offline half of the cave rewriter (docs/CAVE-REWRITER.md). Input: a JSON list of change requests

    {"address": "0x140ADA146", "kind": "disp",  "new_disp": 0x3F0C, "force32": false}
    {"address": "0x140ADA146", "kind": "bytes", "new_bytes": "8b94190c3f0000"}

Output: a JSON plan, one entry per cave (requests whose windows overlap are merged into one entry with a
`changes` list): the window of whole instructions that is replaced by `jmp rel32` at run time, the cave bytes,
the rip-relative fields to re-base (fixups) and the return address. Any rule that cannot be met refuses the
whole plan: reasons on stderr, exit code 2, nothing written.

    python -B ops/engine/cave_plan.py requests.json -o plan.json
    python -B ops/engine/cave_plan.py --emit-cpp plan.json -o src/native/agent_capacity_caves.inc
"""
import argparse
import bisect
import json
import os
import re
import struct
import sys

from capstone import (CS_ARCH_X86, CS_GRP_BRANCH_RELATIVE, CS_GRP_CALL, CS_GRP_INT, CS_GRP_IRET, CS_GRP_JUMP,
                      CS_GRP_RET, CS_MODE_64, CS_OP_IMM, CS_OP_MEM, CS_OP_REG, Cs)
from capstone.x86 import X86_REG_RIP

HERE = os.path.dirname(os.path.abspath(__file__))
LAB = os.environ.get("IW7_RE_LAB", os.path.join(os.path.expanduser("~"), "Documents", "IW7-RE-Lab"))
DEFAULT_IMAGE = os.path.join(LAB, "engine", "image", "iw7_ship_live.exe")
DEFAULT_DB = os.path.join(LAB, "engine", "iw7-engine.sqlite")
MIN_WINDOW = 5                 # a `jmp rel32`
HYPOTHETICAL_CAVE = 0x150000000  # where the self-check pretends the cave is (within 2 GB of the image)
INT3 = 0xCC


class Refusal(Exception):
    def __init__(self, reasons):
        super().__init__("; ".join(reasons))
        self.reasons = list(reasons)


# ------------------------------------------------------------------------------------------------ image access
class PlainImage:
    """Bytes at virtual addresses: `regions` is a list of (base address, bytes, is_code)."""

    def __init__(self, regions, base=0x140000000):
        self.regions = regions
        self.base = base
        self.path = "<memory>"

    def read(self, address, n):
        for start, data, _ in self.regions:
            if start <= address and address + n <= start + len(data):
                return bytes(data[address - start:address - start + n])
        return None

    def code_regions(self):
        return [(s, d) for s, d, c in self.regions if c]

    def all_regions(self):
        return [(s, d) for s, d, _ in self.regions]


class PeImage(PlainImage):
    """The analysed image of docs/ENGINE.md (same layout reading as ops/engine/engine.py `Image`)."""

    def __init__(self, path):
        data = open(path, "rb").read()
        pe = struct.unpack_from("<I", data, 0x3C)[0]
        n = struct.unpack_from("<H", data, pe + 6)[0]
        opt = struct.unpack_from("<H", data, pe + 20)[0]
        base = struct.unpack_from("<Q", data, pe + 24 + 24)[0]
        regions = []
        for i in range(n):
            nm, vs, va, rs, ro = struct.unpack_from("<8sIIII", data, pe + 24 + opt + 40 * i)
            ch = struct.unpack_from("<I", data, pe + 24 + opt + 40 * i + 36)[0]
            body = data[ro:ro + min(rs, vs)] if rs else b""
            regions.append((base + va, body, bool(ch & 0x20000000)))
        super().__init__(regions, base)
        self.path = path


def open_image(path):
    return PeImage(path)


# ------------------------------------------------------------------------------------------------ decoding
def _cs():
    md = Cs(CS_ARCH_X86, CS_MODE_64)
    md.detail = True
    return md


MD = _cs()


def decode(code, address):
    """All instructions of `code` (capstone objects); raises Refusal when the bytes do not decode completely."""
    out, pos = [], 0
    while pos < len(code):
        got = list(MD.disasm(bytes(code[pos:pos + 16]), address + pos, 1))
        if not got:
            raise Refusal([f"bytes do not decode at {address + pos:#x}: {bytes(code[pos:pos + 8]).hex()}"])
        out.append(got[0])
        pos += got[0].size
    return out


def rip_operand(ins):
    for op in ins.operands:
        if op.type == CS_OP_MEM and op.mem.base == X86_REG_RIP:
            return op
    return None


def classify_block(ins):
    """Why an instruction cannot be moved to a cave (None: it can)."""
    g = set(ins.groups)
    if CS_GRP_RET in g or CS_GRP_IRET in g or ins.mnemonic in ("ret", "retf", "retn"):
        return "return"
    if ins.id == 0 or ins.mnemonic in ("int3", "int", "int1", "into"):
        return "int3/int"
    if CS_GRP_INT in g:
        return "int3/int"
    if CS_GRP_BRANCH_RELATIVE in g or ins.mnemonic.startswith(("loop", "jrcxz", "jecxz", "xbegin")):
        return "relative " + ins.mnemonic
    if (CS_GRP_JUMP in g or CS_GRP_CALL in g) and ins.operands and ins.operands[0].type == CS_OP_IMM:
        return "relative " + ins.mnemonic  # a direct jump or call is relative in 64-bit mode
    return None


# ------------------------------------------------------------------------------------------------ encoder
def _fits8(v):
    return -128 <= v <= 127


def modrm_layout(raw, ins):
    """Positions inside one instruction's bytes: (modrm, sib or None, mod, rm, base_field, disp_offset, disp_size)."""
    if raw[0] == 0x62:
        raise Refusal(["EVEX instruction: its 8-bit displacement is scaled, not handled"])
    m = ins.modrm_offset
    if not m:
        raise Refusal(["the instruction has no ModRM byte"])
    modrm = raw[m]
    mod, rm = modrm >> 6, modrm & 7
    if mod == 3:
        raise Refusal(["the ModRM operand is a register, not memory"])
    sib = m + 1 if rm == 4 else None
    base_field = (raw[sib] & 7) if sib is not None else rm
    disp_size = {0: 0, 1: 1, 2: 4}[mod]
    disp_off = m + 1 + (1 if sib is not None else 0)
    if mod == 0 and base_field == 5:
        if sib is None:
            raise Refusal(["the operand is rip-relative: its displacement is an address, not a table offset"])
        disp_size = 4  # no base, disp32 (absolute plus index)
    return m, sib, mod, rm, base_field, disp_off, disp_size


def reencode_disp(raw, ins, new_disp, force32=False):
    """Bytes of the same instruction with the memory displacement `new_disp` (mod 01 -> 10 etc.)."""
    if not (-0x80000000 <= new_disp <= 0x7FFFFFFF):
        raise Refusal([f"new displacement {new_disp:#x} does not fit 32 bits"])
    m, sib, mod, rm, base_field, off, size = modrm_layout(raw, ins)
    if mod == 0 and base_field == 5:  # SIB, no base: disp32 stays disp32
        return raw[:off] + struct.pack("<i", new_disp) + raw[off + 4:]
    want32 = force32 or not _fits8(new_disp)
    if mod == 2 or (mod == 1 and want32):
        new_mod, packed = 2, struct.pack("<i", new_disp)
    elif mod == 1:
        new_mod, packed = 1, struct.pack("<b", new_disp)
    else:  # mod 0: no displacement, base is not rbp/r13 (checked by modrm_layout)
        new_mod, packed = (2, struct.pack("<i", new_disp)) if want32 else (1, struct.pack("<b", new_disp))
    out = bytearray(raw)
    out[m] = (out[m] & 0x3F) | (new_mod << 6)
    return bytes(out[:off]) + packed + bytes(out[off + size:])


# ------------------------------------------------------------------------------------------------ cross references
def raw_branches_into(image, lo, hi):
    """Every rel32/rel8 branch in the code regions whose target is in [lo, hi). Conservative: it reads the bytes at
    every offset, so a data byte that looks like a jump is reported too (a spurious refusal, never a missed branch)."""
    hits = []
    r32 = re.compile(rb"[\xe8\xe9]|\x0f[\x80-\x8f]", re.S)
    for base, data in image.code_regions():
        for m in r32.finditer(data):
            p = m.start()
            op_len = 1 if data[p] != 0x0F else 2
            if p + op_len + 4 > len(data):
                continue
            rel = struct.unpack_from("<i", data, p + op_len)[0]
            target = base + p + op_len + 4 + rel
            if lo <= target < hi:
                hits.append(("rel32", base + p, target))
        # rel8: only branch bytes within reach of the window (+-130 bytes) can land in it
        a, b = max(0, lo - base - 130), min(len(data), hi - base + 130)
        for p in range(a, b - 1):
            if 0x70 <= data[p] <= 0x7F or data[p] in (0xEB, 0xE0, 0xE1, 0xE2, 0xE3):
                rel = struct.unpack_from("<b", data, p + 1)[0]
                target = base + p + 2 + rel
                if lo <= target < hi:
                    hits.append(("rel8", base + p, target))
    return hits


def data_pointers_to(image, addresses):
    """Absolute 8-byte pointers and image-base relative 4-byte values (jump tables) equal to an address."""
    hits = []
    for a in addresses:
        for pat, kind in ((struct.pack("<Q", a), "abs64"), (struct.pack("<I", (a - image.base) & 0xFFFFFFFF), "rva32")):
            for base, data in image.all_regions():
                i = data.find(pat)
                while i >= 0:
                    hits.append((kind, base + i, a))
                    i = data.find(pat, i + 1)
    return hits


class EngineDb:
    """Cross references of the engine database (docs/ENGINE.md): the `refs` and `calls` tables."""

    def __init__(self, path):
        import sqlite3
        self.db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)

    def into(self, lo, hi):
        out = []
        for table in ("refs", "calls"):
            for at, dst, kind in self.db.execute(f"SELECT at,dst,kind FROM {table} WHERE dst>=? AND dst<?", (lo, hi)):
                out.append((f"db:{table}/{kind}", at, dst))
        return out


# ------------------------------------------------------------------------------------------------ planning
def _int(v):
    return int(v, 0) if isinstance(v, str) else int(v)


def _window(image, address):
    """Smallest run of whole instructions from `address` covering at least MIN_WINDOW bytes."""
    insns, total = [], 0
    pos = address
    while total < MIN_WINDOW:
        raw = image.read(pos, 16) or image.read(pos, 1)
        if raw is None:
            raise Refusal([f"{address:#x}: no readable bytes at {pos:#x}"])
        got = list(MD.disasm(raw, pos, 1))
        if not got:
            raise Refusal([f"{address:#x}: no instruction at {pos:#x}: {raw[:8].hex()}"])
        insns.append(got[0])
        total += got[0].size
        pos += got[0].size
    return insns


def validate_request(req):
    if "address" not in req or req.get("kind") not in ("disp", "bytes"):
        raise Refusal([f"request needs an address and a kind of disp or bytes: {req}"])
    out = {"address": _int(req["address"]), "kind": req["kind"], "force32": bool(req.get("force32", False))}
    if req["kind"] == "disp":
        if "new_disp" not in req:
            raise Refusal([f"{out['address']:#x}: kind disp needs new_disp"])
        out["new_disp"] = _int(req["new_disp"])
    else:
        nb = bytes.fromhex(req.get("new_bytes", ""))
        if not nb:
            raise Refusal([f"{out['address']:#x}: kind bytes needs new_bytes"])
        out["new_bytes"] = nb
    return out


def _new_encoding(image, req, ins):
    """(new bytes of the changed instruction, note) or raises Refusal."""
    raw = bytes(ins.bytes)
    if req["kind"] == "bytes":
        for i in decode(req["new_bytes"], req["address"]):
            if classify_block(i) or rip_operand(i):
                raise Refusal([f"{req['address']:#x}: new_bytes must be position independent ({i.mnemonic} {i.op_str})"])
        return req["new_bytes"]
    if rip_operand(ins):
        raise Refusal([f"{req['address']:#x}: the operand is rip-relative: its displacement is an address, not a table offset"])
    mems = [o for o in ins.operands if o.type == CS_OP_MEM]
    if len(mems) != 1 or not ins.modrm_offset:
        raise Refusal([f"{req['address']:#x}: {ins.mnemonic} {ins.op_str} has no single ModRM memory operand"])
    try:
        return reencode_disp(raw, ins, req["new_disp"], req["force32"])
    except Refusal as e:
        raise Refusal([f"{req['address']:#x}: {r}" for r in e.reasons])


def plan(requests, image, db=None, scan=True):
    """-> list of cave dicts. Raises Refusal with every reason found."""
    reasons = []
    reqs = [validate_request(r) for r in requests]
    reqs.sort(key=lambda r: r["address"])
    for a, b in zip(reqs, reqs[1:]):
        if a["address"] == b["address"]:
            reasons.append(f"{a['address']:#x}: two requests for the same instruction")
    if reasons:
        raise Refusal(reasons)
    groups = []  # each: [window insns, [requests]]
    for r in reqs:
        try:
            win = _window(image, r["address"])
        except Refusal as e:
            reasons += e.reasons
            continue
        if groups and r["address"] < groups[-1][0][-1].address + groups[-1][0][-1].size:
            # overlapping windows: one window from the first start that covers both
            prev = groups[-1]
            need_end = max(win[0].address + win[0].size, prev[0][-1].address + prev[0][-1].size)
            merged = list(prev[0])
            pos = merged[-1].address + merged[-1].size
            while pos < need_end:
                merged += _window_from(image, pos)
                pos = merged[-1].address + merged[-1].size
            prev[0][:] = merged
            prev[1].append(r)
        else:
            groups.append([win, [r]])
    caves = []
    for win, rs in groups:
        try:
            caves.append(_cave_for(image, win, rs, db, scan))
        except Refusal as e:
            reasons += e.reasons
    if reasons:
        raise Refusal(reasons)
    return caves


def _window_from(image, pos):
    raw = image.read(pos, 16) or image.read(pos, 1)
    got = list(MD.disasm(raw, pos, 1)) if raw else []
    if not got:
        raise Refusal([f"no instruction at {pos:#x}"])
    return [got[0]]


def _cave_for(image, win, rs, db, scan):
    start = win[0].address
    end = win[-1].address + win[-1].size
    why = []
    for ins in win:
        b = classify_block(ins)
        if b:
            why.append(f"window {start:#x}: {ins.address:#x} {ins.mnemonic} {ins.op_str}: {b}")
    by_addr = {r["address"]: r for r in rs}
    for r in rs:
        if not any(i.address == r["address"] for i in win):
            why.append(f"{r['address']:#x}: not at an instruction boundary of the window")
    if why:
        raise Refusal(why)
    # branch targets into the bytes the jmp and the int3 fill overwrite (everything after the first byte)
    lo, hi = start + 1, end
    interior = [i.address for i in win[1:]]
    hits = []
    if scan:
        hits += raw_branches_into(image, lo, hi)
        hits += data_pointers_to(image, interior)
    if db is not None:
        hits += db.into(lo, hi)
    if hits:
        raise Refusal([f"window {start:#x}+{end - start}: {kind} at {at:#x} reaches {dst:#x} inside the window"
                       for kind, at, dst in hits])
    cave, fixups, changes, spans = bytearray(), [], [], []
    for ins in win:
        raw = bytes(ins.bytes)
        r = by_addr.get(ins.address)
        base = len(cave)
        if r:
            new = _new_encoding(image, r, ins)
            changes.append({"address": f"{ins.address:#x}", "kind": r["kind"], "old_bytes": raw.hex(),
                            "new_bytes": new.hex(), "offset": base,
                            **({"new_disp": r["new_disp"], "force32": r["force32"]} if r["kind"] == "disp" else {})})
            cave += new
        else:
            op = rip_operand(ins)
            if op is not None:
                if ins.disp_size != 4:
                    raise Refusal([f"{ins.address:#x}: rip-relative operand without a 32-bit displacement"])
                fixups.append({"offset": base + ins.disp_offset, "size": 4, "end": base + ins.size,
                               "target": f"{ins.address + ins.size + op.mem.disp:#x}"})
            cave += raw
        spans.append((ins.address, base, len(cave)))
    old = b"".join(bytes(i.bytes) for i in win)
    entry = {"window_start": f"{start:#x}", "window_len": end - start, "old_bytes": old.hex(),
             "cave_bytes": bytes(cave).hex(), "fixups": fixups, "return_address": f"{end:#x}", "changes": changes}
    self_check(entry, win)
    return entry


# ------------------------------------------------------------------------------------------------ self check
def apply_fixups(cave_bytes, fixups, cave_address):
    out = bytearray(cave_bytes)
    for f in fixups:
        target = _int(f["target"])
        rel = target - (cave_address + f["end"])
        if f["offset"] + 4 > len(out) or f["end"] > len(out):
            raise Refusal([f"fixup at {f['offset']} is outside the cave bytes"])
        if not (-0x80000000 <= rel <= 0x7FFFFFFF):
            raise Refusal([f"fixup at {f['offset']}: target {target:#x} is not within 2 GB of the cave"])
        struct.pack_into("<i", out, f["offset"], rel)
    return bytes(out)


def _operand_key(ins, rip_absolute):
    """Everything that defines what an instruction does, with rip-relative operands resolved to absolute targets."""
    ops = []
    for o in ins.operands:
        if o.type == CS_OP_REG:
            ops.append(("r", o.reg, o.size))
        elif o.type == CS_OP_IMM:
            ops.append(("i", o.imm, o.size))
        elif o.type == CS_OP_MEM:
            m = o.mem
            if m.base == X86_REG_RIP:
                ops.append(("m", "rip", ins.address + ins.size + m.disp if rip_absolute else None, o.size))
            else:
                ops.append(("m", m.segment, m.base, m.index, m.scale, m.disp, o.size))
        else:
            ops.append(("o", o.type))
    return (ins.id, ins.mnemonic, tuple(ops))


def self_check(entry, win):
    """Decode the cave (fixups applied at a hypothetical cave address) and compare it, instruction by instruction,
    with the original window decoded at its own address. Raises Refusal on any difference."""
    cave_bytes = bytes.fromhex(entry["cave_bytes"])
    fixed = apply_fixups(cave_bytes, entry["fixups"], HYPOTHETICAL_CAVE)
    new = decode(fixed, HYPOTHETICAL_CAVE)
    changes = {_int(c["address"]): c for c in entry["changes"]}
    j, errs = 0, []
    for ins in win:
        c = changes.get(ins.address)
        if c is None:
            if j >= len(new):
                errs.append(f"{ins.address:#x}: cave ends early")
                break
            n = new[j]
            j += 1
            if _operand_key(ins, True) != _operand_key(n, True):
                errs.append(f"{ins.address:#x}: {ins.mnemonic} {ins.op_str} became {n.mnemonic} {n.op_str}")
        elif c["kind"] == "disp":
            n = new[j]
            j += 1
            a, b = _operand_key(ins, True), _operand_key(n, True)
            want = list(a[2])
            for k, o in enumerate(want):
                if o[0] == "m":
                    want[k] = o[:5] + (c["new_disp"],) + o[6:]
            if (a[0], a[1], tuple(want)) != b:
                errs.append(f"{ins.address:#x}: expected {ins.mnemonic} {ins.op_str} with displacement "
                            f"{c['new_disp']:#x}, the cave has {n.mnemonic} {n.op_str}")
        else:
            nb = bytes.fromhex(c["new_bytes"])
            got = bytearray()
            while len(got) < len(nb) and j < len(new):
                got += bytes(new[j].bytes)
                j += 1
            if bytes(got) != nb:
                errs.append(f"{ins.address:#x}: replacement bytes are not in the cave as given")
    if j != len(new):
        errs.append(f"the cave has {len(new) - j} instructions more than the window")
    # position independence: no relative branch, no return left
    for n in new:
        if classify_block(n):
            errs.append(f"cave {n.address:#x}: {n.mnemonic} {n.op_str}: {classify_block(n)}")
    if errs:
        raise Refusal([f"self-check of window {entry['window_start']}: {e}" for e in errs])


# ------------------------------------------------------------------------------------------------ C++ fragment
def emit_cpp(plan_doc, source_name):
    def arr(h):
        return "{" + ",".join(f"0x{b:02x}" for b in bytes.fromhex(h)) + "}"

    lines = [f"// Generated by ops/engine/cave_plan.py --emit-cpp from {source_name}; do not edit.",
             "// Each entry: window start, stock window bytes, cave bytes, fixups {offset, end, target}."]
    for c in plan_doc["caves"]:
        fx = ",".join(f"{{{f['offset']},{f['end']},{_int(f['target']):#x}ull}}" for f in c["fixups"])
        lines.append(f"{{{_int(c['window_start']):#x}ull, {arr(c['old_bytes'])}, {arr(c['cave_bytes'])}, {{{fx}}}}},")
    return "\n".join(lines) + "\n"


# ------------------------------------------------------------------------------------------------ command line
def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("input", help="requests JSON (plan mode) or plan JSON (--emit-cpp)")
    ap.add_argument("-o", "--output", help="output file (default: stdout)")
    ap.add_argument("--emit-cpp", action="store_true", help="input is a plan: write the C++ array initialiser")
    ap.add_argument("--image", default=DEFAULT_IMAGE)
    ap.add_argument("--db", default=DEFAULT_DB, help="engine database for cross references (skipped when absent)")
    a = ap.parse_args(argv)
    try:
        doc = json.load(open(a.input, encoding="utf-8"))
        if a.emit_cpp:
            text = emit_cpp(doc, os.path.basename(a.input))
        else:
            if not os.path.exists(a.image):
                print(f"no analysed image at {a.image} (docs/ENGINE.md)", file=sys.stderr)
                return 2
            image = open_image(a.image)
            db = EngineDb(a.db) if os.path.exists(a.db) else None
            if db is None:
                print("note: no engine database: cross references come from the byte scans only", file=sys.stderr)
            reqs = doc["requests"] if isinstance(doc, dict) else doc
            caves = plan(reqs, image, db)
            text = json.dumps({"version": 1, "image": os.path.basename(image.path),
                               "xrefs": "engine database refs+calls and byte scans" if db else "byte scans only",
                               "caves": caves}, indent=1) + "\n"
    except (OSError, ValueError, KeyError) as e:
        print(f"cannot read the input: {e}", file=sys.stderr)
        return 2
    except Refusal as e:
        print("REFUSED:", file=sys.stderr)
        for r in e.reasons:
            print(" ", r, file=sys.stderr)
        return 2
    if a.output:
        with open(a.output, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
