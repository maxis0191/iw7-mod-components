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
    """Why an instruction cannot be moved to a cave (None: it can). Direct jmp/jcc are allowed (re-encoded as rel32)."""
    g = set(ins.groups)
    if CS_GRP_RET in g or CS_GRP_IRET in g or ins.mnemonic in ("ret", "retf", "retn"):
        return "return"
    if ins.id == 0 or ins.mnemonic in ("int3", "int", "int1", "into"):
        return "int3/int"
    if CS_GRP_INT in g:
        return "int3/int"
    if CS_GRP_CALL in g or ins.mnemonic == "call":
        return "call (it leaves a return address in cave memory, which has no unwind data)"
    if ins.mnemonic.startswith(("loop", "jrcxz", "jecxz", "xbegin")):
        return "relative " + ins.mnemonic + " (rel8 only: no rel32 form)"
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
def _cache(image):
    if not hasattr(image, "_cave_cache"):
        image._cave_cache = {}
    return image._cave_cache


def _rel32_index(image):
    """Every rel32 branch of the code regions, sorted by target: (target, at, info). Conservative: every byte is read
    as a possible opcode (E8 call, E9 jmp, 0F 80..8F jcc)."""
    c = _cache(image)
    if "rel32" not in c:
        rows = []
        pat = re.compile(rb"[\xe8\xe9]|\x0f[\x80-\x8f]", re.S)
        for base, data in image.code_regions():
            for m in pat.finditer(data):
                p = m.start()
                n = 1 if data[p] != 0x0F else 2
                if p + n + 4 > len(data):
                    continue
                rel = struct.unpack_from("<i", data, p + n)[0]
                info = "call" if data[p] == 0xE8 else ("jmp" if data[p] == 0xE9 else "jcc")
                rows.append((base + p + n + 4 + rel, base + p, info))
        rows.sort()
        c["rel32"] = (rows, [r[0] for r in rows])
    return c["rel32"]


def raw_branches_into(image, lo, hi):
    """Every rel32/rel8 branch in the code regions whose target is in [lo, hi): (kind, at, target, info) with info
    jmp, jcc, call or loop. Conservative (a data byte that looks like a jump is reported too)."""
    hits = []
    rows, keys = _rel32_index(image)
    i = bisect.bisect_left(keys, lo)
    while i < len(rows) and rows[i][0] < hi:
        hits.append(("rel32", rows[i][1], rows[i][0], rows[i][2]))
        i += 1
    for base, data in image.code_regions():
        a, b = max(0, lo - base - 130), min(len(data), hi - base + 130)
        for p in range(a, b - 1):
            op = data[p]
            if 0x70 <= op <= 0x7F or op in (0xEB, 0xE0, 0xE1, 0xE2, 0xE3):
                rel = struct.unpack_from("<b", data, p + 1)[0]
                target = base + p + 2 + rel
                if lo <= target < hi:
                    info = "jmp" if op == 0xEB else ("jcc" if op >= 0x70 else "loop")
                    hits.append(("rel8", base + p, target, info))
    return hits


def data_pointers_to(image, addresses):
    """8-byte absolute pointers and image-base relative 4-byte values (jump tables) equal to an address:
    (kind, at, address, info) with info = "table" (4-aligned, in a non-code region), "code" or "unaligned"."""
    c = _cache(image).setdefault("ptr", {})
    hits = []
    for a in addresses:
        if a not in c:
            found = []
            for pat, kind in ((struct.pack("<Q", a), "abs64"), (struct.pack("<I", (a - image.base) & 0xFFFFFFFF), "rva32")):
                for base, data, is_code in image.regions:
                    i = data.find(pat)
                    while i >= 0:
                        at = base + i
                        info = "code" if is_code else ("table" if at % 4 == 0 else "unaligned")
                        found.append((kind, at, a, info))
                        i = data.find(pat, i + 1)
            c[a] = found
        hits += c[a]
    return hits


class EngineDb:
    """Cross references of the engine database (docs/ENGINE.md): the `refs` and `calls` tables."""

    def __init__(self, path):
        import sqlite3
        self.db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        self._starts = self._rows = None

    def function_range(self, address):
        """(start, end) of the analysed function that contains `address`, or None."""
        if self._starts is None:
            rows = self.db.execute("SELECT addr,end FROM functions ORDER BY addr").fetchall()
            self._starts, self._rows = [r[0] for r in rows], rows
        i = bisect.bisect_right(self._starts, address) - 1
        if i >= 0 and address < self._rows[i][1]:
            return self._rows[i]
        return None

    def gap(self, address):
        """(end of the previous function, start of the next) when `address` is in no analysed function, else None."""
        self.function_range(address)
        i = bisect.bisect_right(self._starts, address) - 1
        if i >= 0 and address < self._rows[i][1]:
            return None
        return (self._rows[i][1] if i >= 0 else None, self._starts[i + 1] if i + 1 < len(self._starts) else None)

    def into(self, lo, hi):
        out = []
        for table in ("refs", "calls"):
            for at, dst, kind in self.db.execute(f"SELECT at,dst,kind FROM {table} WHERE dst>=? AND dst<?", (lo, hi)):
                out.append((f"db:{table}/{kind}", at, dst, "db"))
        return out


class Boundaries:
    """Instruction starts of the analysed function around an address (the database's function range, decoded linearly).

    Used (1) to drop byte-scan hits that are not instructions (`shl rdx, 6` is `48 c1 e2 06`, and `e2 06` looks like a
    loop), (2) to confirm that an incoming branch really is a jmp/jcc before it is retargeted, (3) for the instructions
    BEFORE a site (backward windows). The decode is trusted only when it ends exactly at the function's end."""

    def __init__(self, image, db):
        self.image, self.db, self.cache = image, db, {}

    def function(self, address):
        """(starts set, instruction list) or None."""
        if self.db is None or not hasattr(self.db, "function_range"):
            return None
        fr = self.db.function_range(address)
        if fr is None or fr[1] - fr[0] > 0x10000:
            return None
        if fr[0] not in self.cache:
            code = self.image.read(fr[0], fr[1] - fr[0])
            insns, pos = [], fr[0]
            while code and pos < fr[1]:
                got = list(MD.disasm(code[pos - fr[0]:pos - fr[0] + 16], pos, 1))
                if not got:
                    insns = None
                    break
                insns.append(got[0])
                pos += got[0].size
            ok = insns is not None and pos == fr[1]
            self.cache[fr[0]] = ({i.address for i in insns}, insns) if ok else None
        return self.cache[fr[0]]

    def starts(self, address):
        f = self.function(address)
        return f[0] if f else None

    def is_spurious(self, at):
        """A byte-scan hit that cannot be an instruction: not an instruction start of its (trusted) function, or inside
        the alignment gap (under 16 bytes) between two analysed functions."""
        starts = self.starts(at)
        if starts is not None:
            return at not in starts
        if self.db is not None and hasattr(self.db, "gap"):
            g = self.db.gap(at)
            return bool(g and g[0] is not None and g[1] is not None and g[1] - g[0] < 16)
        return False

    def before(self, site, count=12):
        """Up to `count` instructions that end exactly at `site`, or None when the decode does not land on it."""
        f = self.function(site)
        if f is None or site not in f[0]:
            return None
        insns = f[1]
        k = bisect.bisect_left([i.address for i in insns], site)
        return insns[max(0, k - count):k]


# ------------------------------------------------------------------------------------------------ planning
def _int(v):
    return int(v, 0) if isinstance(v, str) else int(v)


def _insn_at(image, pos):
    raw = image.read(pos, 16) or image.read(pos, 1)
    got = list(MD.disasm(raw, pos, 1)) if raw else []
    if not got:
        raise Refusal([f"no instruction at {pos:#x}" + (f": {raw[:8].hex()}" if raw else "")])
    return got[0]


def _window(image, address):
    """Smallest run of whole instructions from `address` covering at least MIN_WINDOW bytes."""
    insns, total, pos = [], 0, address
    while total < MIN_WINDOW:
        try:
            ins = _insn_at(image, pos)
        except Refusal as e:
            raise Refusal([f"{address:#x}: {r}" for r in e.reasons])
        insns.append(ins)
        total += ins.size
        pos += ins.size
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
    """Bytes of the changed instruction, or raises Refusal."""
    raw = bytes(ins.bytes)
    if req["kind"] == "bytes":
        for i in decode(req["new_bytes"], req["address"]):
            if classify_block(i) or rip_operand(i) or direct_branch(i):
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


def direct_branch(ins):
    """True for jmp/jcc with an immediate target (rel8 or rel32)."""
    return (CS_GRP_JUMP in ins.groups or CS_GRP_BRANCH_RELATIVE in ins.groups) and bool(ins.operands) \
        and ins.operands[0].type == CS_OP_IMM and not ins.mnemonic.startswith(("loop", "jrcxz", "jecxz", "xbegin"))


def _branch_rel32(ins):
    """The rel32 encoding of a direct jmp/jcc: (opcode bytes, length). Refuses prefixed or odd forms."""
    raw = bytes(ins.bytes)
    if len(raw) == 2 and raw[0] == 0xEB or len(raw) == 5 and raw[0] == 0xE9:
        return b"\xe9"
    if len(raw) == 2 and 0x70 <= raw[0] <= 0x7F:
        return bytes([0x0F, 0x80 | (raw[0] & 0x0F)])
    if len(raw) == 6 and raw[0] == 0x0F and 0x80 <= raw[1] <= 0x8F:
        return bytes(raw[:2])
    raise Refusal([f"{ins.address:#x}: {ins.mnemonic} {ins.op_str}: branch form with prefixes is not handled"])


def build_cave(image, win, rs):
    """The cave for one window: re-encode the changed instructions, branches as rel32 (outside targets become fixups,
    targets inside the window become cave-internal displacements). Returns the entry (without retargets)."""
    start, end = win[0].address, win[-1].address + win[-1].size
    by_addr = {r["address"]: r for r in rs}
    why = []
    for ins in win:
        b = classify_block(ins)
        if b:
            why.append(f"window {start:#x}: {ins.address:#x} {ins.mnemonic} {ins.op_str}: {b}")
    for r in rs:
        if not any(i.address == r["address"] for i in win):
            why.append(f"{r['address']:#x}: not at an instruction boundary of the window")
    if why:
        raise Refusal(why)
    starts = {i.address for i in win}
    pieces, changes = [], []
    for ins in win:
        raw = bytes(ins.bytes)
        r = by_addr.get(ins.address)
        if r:
            new = _new_encoding(image, r, ins)
            changes.append({"address": f"{ins.address:#x}", "kind": r["kind"], "old_bytes": raw.hex(), "new_bytes": new.hex(),
                            **({"new_disp": r["new_disp"], "force32": r["force32"]} if r["kind"] == "disp" else {})})
            pieces.append(["plain", new, ins])
        elif direct_branch(ins):
            target = ins.operands[0].imm
            if start <= target < end and target not in starts:
                raise Refusal([f"window {start:#x}: {ins.address:#x} {ins.mnemonic} {ins.op_str}: target is inside an instruction of the window"])
            opc = _branch_rel32(ins)
            pieces.append(["branch", opc, ins])
        else:
            pieces.append(["plain", raw, ins])
    offs, pos = {}, 0
    for kind, data, ins in pieces:
        offs[ins.address] = pos
        pos += len(data) + (4 if kind == "branch" else 0)
    cave, fixups = bytearray(), []
    for kind, data, ins in pieces:
        base = len(cave)
        if kind == "plain":
            op = rip_operand(ins)
            if op is not None and ins.address not in by_addr:
                if ins.disp_size != 4:
                    raise Refusal([f"{ins.address:#x}: rip-relative operand without a 32-bit displacement"])
                fixups.append({"kind": "rip", "offset": base + ins.disp_offset, "size": 4, "end": base + ins.size,
                               "target": f"{ins.address + ins.size + op.mem.disp:#x}"})
            cave += data
        else:
            target = ins.operands[0].imm
            length = len(data) + 4
            if start <= target < end:
                cave += data + struct.pack("<i", offs[target] - (base + length))
            else:
                fixups.append({"kind": "branch", "offset": base + length - 4, "size": 4, "end": base + length,
                               "target": f"{target:#x}"})
                cave += data + b"\0\0\0\0"
    old = b"".join(bytes(i.bytes) for i in win)
    entry = {"window_start": f"{start:#x}", "window_len": end - start, "old_bytes": old.hex(), "cave_bytes": bytes(cave).hex(),
             "fixups": fixups, "return_address": f"{end:#x}", "changes": changes, "retargets": [],
             "offsets": {f"{a:#x}": o for a, o in offs.items()}}
    return entry


def incoming(image, win, bounds, db):
    """References from outside the window to its bytes after the first: (retargets, hard reasons).
    A retarget is a jmp/jcc rel32 or a 4-byte image-relative jump-table entry; everything else is a hard reason."""
    start, end = win[0].address, win[-1].address + win[-1].size
    lo, hi = start + 1, end
    starts = {i.address for i in win}
    hits = [h for h in raw_branches_into(image, lo, hi) if not (start <= h[1] < end)]
    own = bounds.starts(start) if bounds else None
    if bounds and (own is None or start in own):
        hits = [h for h in hits if not bounds.is_spurious(h[1])]
    hits += [h for h in data_pointers_to(image, [i.address for i in win[1:]]) if not (start <= h[1] < end)]
    seen_at = {h[1] for h in hits}
    if db is not None:
        for h in db.into(lo, hi):
            h = h if len(h) == 4 else (*h, "db")
            if not (start <= h[1] < end) and h[1] not in seen_at:
                hits.append(h)
    retargets, hard = [], []
    for kind, at, dst, info in hits:
        where = f"window {start:#x}+{end - start}: {kind} at {at:#x} reaches {dst:#x} inside the window"
        if kind in ("rel32", "rel8") and start <= at < end:
            continue
        if dst not in starts and kind != "rva32" and kind != "abs64":
            hard.append(where + " (not at an instruction boundary)")
        elif kind == "rel32" and info in ("jmp", "jcc"):
            f = bounds.starts(at) if bounds else None
            if f is None or at not in f:
                hard.append(where + " (cannot confirm that it is a branch instruction: no function decode)")
                continue
            length = 5 if info == "jmp" else 6
            field = at + length - 4
            old = image.read(field, 4)
            retargets.append({"kind": "rel32", "at": f"{at:#x}", "field": f"{field:#x}", "length": length,
                              "old_bytes": old.hex() if old else "", "target": f"{dst:#x}"})
        elif kind == "rel32" and info == "call":
            hard.append(where + " (a call cannot be retargeted)")
        elif kind == "rel8":
            hard.append(where + " (a rel8 branch cannot be retargeted)")
        elif kind == "rva32" and info == "table" and dst in starts:
            old = image.read(at, 4)
            retargets.append({"kind": "rva32", "at": f"{at:#x}", "field": f"{at:#x}", "length": 4,
                              "old_bytes": old.hex() if old else "", "target": f"{dst:#x}"})
        else:
            hard.append(where + (f" ({info})" if info else ""))
    return retargets, hard


def _candidates(core, pre, post, cap=24):
    """Windows that contain `core`: forward, then backward, then every mixed one up to `cap` bytes, shortest first.
    -> list of (kind, instruction list)."""
    size = lambda l: sum(i.size for i in l)
    out, seen = [], set()
    has_pre, pre = pre is not None, list(pre or [])

    def add(kind, i, j):
        if (i, j) in seen or i > len(pre) or j > len(post):
            return
        seen.add((i, j))
        out.append((kind, pre[len(pre) - i:] + core + post[:j]))

    for j in range(len(post) + 1):
        if size(core) + size(post[:j]) >= MIN_WINDOW:
            add("forward", 0, j)
            break
    if has_pre:
        for i in range(len(pre) + 1):
            if size(pre[len(pre) - i:]) + size(core) >= MIN_WINDOW:
                add("backward", i, 0)
                break
        mixed = []
        for i in range(len(pre) + 1):
            for j in range(len(post) + 1):
                n = size(pre[len(pre) - i:]) + size(core) + size(post[:j])
                if MIN_WINDOW <= n <= cap and (i, j) not in seen:
                    mixed.append((n, i, j))
        for _, i, j in sorted(mixed):
            add("mixed", i, j)
    return out


def _solve_group(image, rs, db, scan, bounds):
    """-> (entry, tried): the first candidate window that passes every rule, else the first one that passes with
    retargeted incoming references, else raises Refusal (reasons of the forward window)."""
    addrs = sorted(r["address"] for r in rs)
    cs = addrs[0]
    core, pos = [], cs
    while True:
        ins = _insn_at(image, pos)
        core.append(ins)
        pos += ins.size
        if pos > addrs[-1]:
            break
    pre = bounds.before(cs) if bounds else None
    post, pos = [], core[-1].address + core[-1].size
    for _ in range(14):
        try:
            ins = _insn_at(image, pos)
        except Refusal:
            break
        post.append(ins)
        pos += ins.size
    tried, fallback, first_reasons = [], None, None
    for kind, win in _candidates(core, pre, post):
        try:
            entry = build_cave(image, win, rs)
        except Refusal as e:
            tried.append({"window": f"{win[0].address:#x}+{sum(i.size for i in win)}", "kind": kind, "reasons": e.reasons[:2]})
            first_reasons = first_reasons or e.reasons
            continue
        retargets, hard = incoming(image, win, bounds, db) if scan else ([], [])
        if hard:
            tried.append({"window": f"{win[0].address:#x}+{entry['window_len']}", "kind": kind, "reasons": hard[:2]})
            first_reasons = first_reasons or hard
            continue
        entry["window_kind"] = kind
        if not retargets:
            self_check(entry, win)
            entry["tried"] = tried
            return entry
        if fallback is None:
            fallback = (entry, win, retargets, kind)
        tried.append({"window": f"{win[0].address:#x}+{entry['window_len']}", "kind": kind,
                      "reasons": [f"{len(retargets)} incoming reference(s) would have to be retargeted"]})
    if fallback:
        entry, win, retargets, kind = fallback
        k = entry["offsets"]
        for t in retargets:
            t["cave_offset"] = k[t["target"]]
        entry["retargets"] = retargets
        self_check(entry, win)
        entry["tried"] = tried
        return entry
    raise Refusal((first_reasons or ["no window"]) + [f"({len(tried)} windows tried; first reasons shown)"])


def plan(requests, image, db=None, scan=True):
    """-> list of cave dicts. Raises Refusal with every reason found."""
    reasons = []
    reqs = sorted((validate_request(r) for r in requests), key=lambda r: r["address"])
    for a, b in zip(reqs, reqs[1:]):
        if a["address"] == b["address"]:
            reasons.append(f"{a['address']:#x}: two requests for the same instruction")
    if reasons:
        raise Refusal(reasons)
    bounds = Boundaries(image, db)
    groups = []  # lists of requests; forward windows that overlap are one group
    for r in reqs:
        try:
            win = _window(image, r["address"])
        except Refusal as e:
            reasons += e.reasons
            continue
        if groups and r["address"] < groups[-1]["end"]:
            groups[-1]["reqs"].append(r)
            groups[-1]["end"] = max(groups[-1]["end"], win[0].address + win[0].size)
        else:
            groups.append({"reqs": [r], "end": win[-1].address + win[-1].size})
    groups = [g["reqs"] for g in groups]
    while True:
        solved = []
        for g in groups:
            try:
                solved.append((g, _solve_group(image, g, db, scan, bounds), None))
            except Refusal as e:
                solved.append((g, None, e.reasons))
        spans = sorted((int(e["window_start"], 0), int(e["window_start"], 0) + e["window_len"], i)
                       for i, (_, e, _) in enumerate(solved) if e)
        merge = next(((a[2], b[2]) for a, b in zip(spans, spans[1:]) if b[0] < a[1]), None)
        if not merge:
            break
        i, j = merge
        merged = sorted(solved[i][0] + solved[j][0], key=lambda r: r["address"])
        groups = [g for k, (g, _, _) in enumerate(solved) if k not in (i, j)] + [merged]
    caves = []
    for g, entry, why in solved:
        if entry:
            caves.append(entry)
        else:
            reasons += why
    caves.sort(key=lambda c: int(c["window_start"], 0))
    # no cave may jump to, or retarget from, the bytes another cave's window overwrites
    for c in caves:
        for o in caves:
            if o is c:
                continue
            s, e = int(o["window_start"], 0), int(o["window_start"], 0) + o["window_len"]
            for f in c["fixups"]:
                if f["kind"] == "branch" and s < _int(f["target"]) < e:
                    reasons.append(f"cave {c['window_start']}: a branch goes to {f['target']}, inside the window of cave {o['window_start']}")
            for t in c["retargets"]:
                if s <= _int(t["at"]) < e:
                    reasons.append(f"cave {c['window_start']}: incoming branch at {t['at']} lies inside the window of cave {o['window_start']}")
    if reasons:
        raise Refusal(reasons)
    return caves


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
    """Everything that defines what an instruction does, with rip-relative operands resolved to absolute targets and
    the target of a direct branch left out (it is compared separately)."""
    ops = []
    for o in ins.operands:
        if o.type == CS_OP_REG:
            ops.append(("r", o.reg, o.size))
        elif o.type == CS_OP_IMM:
            ops.append(("t",) if direct_branch(ins) else ("i", o.imm, o.size))
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
    """Decode the cave (fixups applied at a hypothetical cave address) and compare it instruction by instruction with the
    original window decoded at its own address: same instruction and operands, rip-relative operands resolved to the same
    absolute target, branch targets outside the window equal, branch targets inside the window equal to the matching
    instruction of the cave; only the intended changes differ. Raises Refusal on any difference."""
    cave_bytes = bytes.fromhex(entry["cave_bytes"])
    fixed = apply_fixups(cave_bytes, entry["fixups"], HYPOTHETICAL_CAVE)
    new = decode(fixed, HYPOTHETICAL_CAVE)
    start, end = win[0].address, win[-1].address + win[-1].size
    changes = {_int(c["address"]): c for c in entry["changes"]}
    errs, match, pairs = [], {}, []
    j = 0
    for ins in win:
        c = changes.get(ins.address)
        if c is None:
            if j >= len(new):
                errs.append(f"{ins.address:#x}: cave ends early")
                break
            n = new[j]
            match[ins.address] = n.address
            pairs.append((ins, n))
            j += 1
            if _operand_key(ins, True) != _operand_key(n, True):
                errs.append(f"{ins.address:#x}: {ins.mnemonic} {ins.op_str} became {n.mnemonic} {n.op_str}")
        elif c["kind"] == "disp":
            n = new[j]
            match[ins.address] = n.address
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
            match[ins.address] = new[j].address if j < len(new) else None
            got = bytearray()
            while len(got) < len(nb) and j < len(new):
                got += bytes(new[j].bytes)
                j += 1
            if bytes(got) != nb:
                errs.append(f"{ins.address:#x}: replacement bytes are not in the cave as given")
    if j != len(new):
        errs.append(f"the cave has {len(new) - j} instructions more than the window")
    for o, n in pairs:
        if direct_branch(o):
            t = o.operands[0].imm
            expect = match.get(t) if start <= t < end else t
            got = n.operands[0].imm if n.operands and n.operands[0].type == CS_OP_IMM else None
            if expect is None or got != expect:
                errs.append(f"{o.address:#x}: branch to {t:#x} goes to {got if got is None else hex(got)} in the cave, "
                            f"expected {expect if expect is None else hex(expect)}")
    for n in new:
        if classify_block(n):
            errs.append(f"cave {n.address:#x}: {n.mnemonic} {n.op_str}: {classify_block(n)}")
    if errs:
        raise Refusal([f"self-check of window {entry['window_start']}: {e}" for e in errs])


def dry_run(requests, image, db=None):
    """Each request planned ALONE (no merging with the others): one row each with the window chosen or the refusal."""
    rows = []
    for r in requests:
        row = {"address": str(r.get("address")), "note": r.get("note", "")}
        try:
            (c,) = plan([r], image, db)
            row.update(status="accepted", window_start=c["window_start"], window_len=c["window_len"],
                       window_kind=c.get("window_kind", ""), retargets=len(c["retargets"]), reasons=[],
                       tried=c.get("tried", []))
        except Refusal as e:
            row.update(status="refused", reasons=e.reasons)
        rows.append(row)
    return rows


# ------------------------------------------------------------------------------------------------ C++ fragment
def emit_cpp(plan_doc, source_name):
    def arr(h):
        return "{" + ",".join(f"0x{b:02x}" for b in bytes.fromhex(h)) + "}"

    lines = [f"// Generated by ops/engine/cave_plan.py --emit-cpp from {source_name}; do not edit.",
             "// Each entry: window start, stock window bytes, cave bytes, fixups {offset, end, target},",
             "// retargets {field, kind (0 rel32, 1 rva32), stock value, cave offset}."]
    for c in plan_doc["caves"]:
        fx = ",".join(f"{{{f['offset']},{f['end']},{_int(f['target']):#x}ull}}" for f in c["fixups"])
        rt = ",".join(f"{{{_int(t['field']):#x}ull,{0 if t['kind'] == 'rel32' else 1},"
                      f"{int.from_bytes(bytes.fromhex(t['old_bytes']), 'little'):#x}u,{t['cave_offset']}}}"
                      for t in c.get("retargets", []))
        lines.append(f"{{{_int(c['window_start']):#x}ull, {arr(c['old_bytes'])}, {arr(c['cave_bytes'])}, {{{fx}}}, {{{rt}}}}},")
    return "\n".join(lines) + "\n"


# ------------------------------------------------------------------------------------------------ command line
def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("input", help="requests JSON (plan mode) or plan JSON (--emit-cpp)")
    ap.add_argument("-o", "--output", help="output file (default: stdout)")
    ap.add_argument("--emit-cpp", action="store_true", help="input is a plan: write the C++ array initialiser")
    ap.add_argument("--dry-run", action="store_true",
                    help="plan every request alone and write a per-request accepted/refused table (exit 0)")
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
            if a.dry_run:
                rows = dry_run(reqs, image, db)
                text = json.dumps({"version": 1, "dry_run": True, "accepted": sum(r["status"] == "accepted" for r in rows),
                                   "refused": sum(r["status"] == "refused" for r in rows), "sites": rows}, indent=1) + chr(10)
                caves = None
            else:
                caves = plan(reqs, image, db)
        if not a.emit_cpp and caves is not None:
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
