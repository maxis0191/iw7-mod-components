#!/usr/bin/env python3
"""Static table scan: find the .data/.bss arrays that are indexed by a character, agent or sentient number, by reading.

    python -B ops/engine/static_tables.py [--json out.json] [--capacity-source FILE | git:REF:PATH] [--all] [--min-pass N]

The engine keeps static tables with one row per character (42 = 18 clients + 24 agents), per agent (24), per sentient
(66/71) and so on. With -agent-capacity the counts grow (118 / 100 / 147) and every table that is not moved is overrun.
Each of them was found by a crash. This tool lists them by reading the analysed image (docs/ENGINE.md), in three
independent passes, and says for each whether src/native/agent_capacity.cpp already patches it.

  pass 1  loop bounds: a function that has a loop and reads a capacity-dependent count (agent count [*(0x146B22AC8)+0x30],
          MAX_CHARACTERS, sentient / agent count globals, svs_numclients) or compares or loads a stock count (an index that
          starts at 18; 24, 42, 66, 71 as a bound; 41, 65, 70 as a last index), and indexes or walks a static array.
  pass 2  sizes: memset / memcpy / `rep stos` of a static destination whose length is k x stride (k in 24, 42, 66, 71,
          stride >= 4); and two static `lea` of one function whose difference is k x stride, with that stride also used by the
          function (start and end of a scan).
  pass 3  index sources: an index that is computed from an entity (entity pointer minus g_entities, the entity number
          field read at offset 0 of a pointer) or from a sentient ((sentient - [0x143C986A0]) / 0xA0) and scaled into a
          static base.

Per candidate: base, stride, the rows the code implies, every function that references it, evidence lines, the room (rows
from the base to the next static address that no function of the table uses), and whether agent_capacity.cpp patches a site
of it. The reader forms understood: `lea r,[rip+X]` then `[r+idx*s+d]` / `[r+d]` / `add r,S` cursors, and the image-base
relative `[a+b+disp32]` (disp32 + 0x140000000 inside a writable section). Strides come from `imul r,r,S`, `shl`, `lea r,[r+r*k]`
and the access scale. It is a reading aid, not a proof: every candidate that is not handled needs its decompile read.
"""
import argparse
import bisect
import json
import os
import re
import sqlite3
import subprocess
import sys
import time
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import engine as eng  # noqa: E402

BASE = 0x140000000
AGENT_COUNT_PTR = 0x146B22AC8       # pointer to the SV agent object: [*ptr + 0x30] = agent record count (the pointer itself is read everywhere)
COUNT_GLOBALS = {
    0x143C986A8: "sentient count", 0x143C986C0: "agent count",
    0x144C6F208: "MAX_CHARACTERS", 0x144C6F20C: "MAX_CLIENTS", 0x146B229E0: "svs_numclients",
}
SENTIENT_BASE = 0x143C986A0         # pointer to the sentient array (stride 0xA0)
G_ENTITIES = 0x143D22610            # entity array (stride 0x3F8)
STOCK_COUNTS = {24: "24", 42: "42", 66: "66", 71: "71", 0x29: "last 41", 0x41: "last 65", 0x46: "last 70", 0x12: "start 18"}
KS = (24, 42, 66, 71)               # row counts of the stock tables
MAX_ROWS = 147                      # largest row count a table can need under -agent-capacity 100 (sentients)
MAX_SPAN_ROWS = 130

_CANON = {}
for _f in (("rax", "eax", "ax", "al"), ("rcx", "ecx", "cx", "cl"), ("rdx", "edx", "dx", "dl"), ("rbx", "ebx", "bx", "bl"),
           ("rsp", "esp", "sp", "spl"), ("rbp", "ebp", "bp", "bpl"), ("rsi", "esi", "si", "sil"), ("rdi", "edi", "di", "dil")):
    for _n in _f:
        _CANON[_n] = _f[0]
for _i in range(8, 16):
    for _s in ("", "d", "w", "b"):
        _CANON["r%d%s" % (_i, _s)] = "r%d" % _i
NOWRITE = {"cmp", "test", "push", "bt", "jmp", "call", "ret", "nop", "prefetcht0", "prefetchw", "ucomiss", "ucomisd",
           "comiss", "comisd", "cmpxchg", "lock", "rep", "stosq", "stosd", "stosb", "movsq", "movsb", "movsd"}
VOLATILE = ("rax", "rcx", "rdx", "r8", "r9", "r10", "r11")


class Ctx:
    """The analysed image, its function table and the writable ranges. Tests build one from a fake image."""

    def __init__(self, image, funcs, writable, index=None):
        self.image = image
        self.funcs = funcs                    # sorted list of (start, end)
        self.starts = [f[0] for f in funcs]
        self.writable = writable              # [(lo, hi)]
        self.index = index

    def is_data(self, a):
        for lo, hi in self.writable:
            if lo <= a < hi:
                return True
        return False

    def func_of(self, a):
        i = bisect.bisect_right(self.starts, a) - 1
        if i >= 0 and a < self.funcs[i][1]:
            return self.funcs[i][0]
        return None


def canon(ins, rid):
    if not rid:
        return None
    n = ins.reg_name(rid)
    return _CANON.get(n, n)


class Fn:
    def __init__(self, start):
        self.start = start
        self.uses = []          # dicts: table(X), at, text, kind, stride, origin
        self.signals = []       # (kind, detail, at)
        self.sizes = []         # (X, length, how, at)
        self.leas = []          # (X, at)
        self.hints = set()
        self.loop = False
        self.refs = {}          # static address (incl. field offsets) -> kind ("base" via table register, "direct")
        self.pass3 = False
        self.ptr_stores = []    # (table base, pointer global, at): `mov [rip+P],reg` of a register holding a static base


def analyze(ctx, start, end):
    from capstone import Cs, CS_ARCH_X86, CS_MODE_64, CS_OP_IMM, CS_OP_MEM, CS_OP_REG
    from capstone.x86 import X86_REG_RIP
    md = Cs(CS_ARCH_X86, CS_MODE_64)
    md.detail = True
    code = ctx.image.read(start, min(end - start, 0x30000))
    fn = Fn(start)
    if not code:
        return fn
    val = {}      # reg -> ("base", X) | ("img",) | ("load", X)
    idx = {}      # reg -> [mult, origin]
    window = []   # recent (insn) for the size pattern
    written = set()   # registers written so far: an entity pointer is an argument register nobody wrote yet
    for ins in md.disasm(code, start):
        mn = ins.mnemonic
        ops = ins.operands
        at = ins.address
        nxt = at + ins.size
        text = f"{mn} {ins.op_str}"
        window.append(ins)
        if len(window) > 14:
            window.pop(0)
        # backward branches
        if mn.startswith("j") and ops and ops[0].type == CS_OP_IMM and ops[0].imm < at and start <= ops[0].imm:
            fn.loop = True
        # ---- memory operands
        mem = None
        for o in ops:
            if o.type == CS_OP_MEM:
                mem = o
        dst = canon(ins, ops[0].reg) if ops and ops[0].type == CS_OP_REG else None
        if mem is not None:
            b = canon(ins, mem.mem.base) if mem.mem.base else None
            i = canon(ins, mem.mem.index) if mem.mem.index else None
            s = mem.mem.scale
            d = mem.mem.disp
            if mem.mem.base == X86_REG_RIP:
                x = nxt + d
                if ctx.is_data(x):
                    if mn == "lea":
                        fn.leas.append((x, at))
                        fn.refs.setdefault(x, "base")
                    else:
                        fn.refs.setdefault(x, "direct")
                    if mn == "mov" and len(ops) == 2 and ops[0].type == CS_OP_MEM and ops[1].type == CS_OP_REG:
                        v = val.get(canon(ins, ops[1].reg))
                        if v and v[0] == "base":
                            fn.ptr_stores.append((v[1], x, at))
                    if x in COUNT_GLOBALS:
                        fn.signals.append(("count", COUNT_GLOBALS[x], at))
                    if x == SENTIENT_BASE and mn in ("sub",):
                        fn.pass3 = True
                    if x == G_ENTITIES and mn == "sub":
                        fn.pass3 = True
                if mn == "lea" and dst:
                    if ctx.is_data(x):
                        val[dst] = ("base", x)
                    elif x == BASE:
                        val[dst] = ("img",)
                    else:
                        val.pop(dst, None)
                    idx.pop(dst, None)
                    continue
                if mn in ("mov", "movsxd") and dst and ctx.is_data(x):
                    val[dst] = ("load", x)
                    idx.pop(dst, None)
                    continue
            else:
                bv = val.get(b) if b else None
                iv = val.get(i) if i else None
                if bv and bv[0] == "load" and bv[1] == AGENT_COUNT_PTR and d == 0x30 and not i:
                    fn.signals.append(("count", "agent count [*(0x146B22AC8)+0x30]", at))
                bi = idx.get(b, [1, None]) if b else [1, None]
                ii = idx.get(i, [1, None]) if i else [1, None]
                tab = None
                stride = 0
                origin = None
                kind = None
                field = d
                if bv and bv[0] == "base":
                    tab = bv[1]
                    if i:
                        stride = ii[0] * s
                        origin = ii[1]
                        kind = "indexed"
                    else:
                        kind = "field"
                elif iv and iv[0] == "base":
                    tab = iv[1]
                    stride = bi[0]
                    origin = bi[1]
                    kind = "indexed"
                else:
                    # image-base relative: [a + b + disp32], disp32 + image base inside a writable section
                    x = BASE + d
                    if d > 0x100000 and (b or i) and ctx.is_data(x):
                        tab = x
                        field = 0
                        kind = "rva"
                        pick = None
                        for r, sc in ((b, 1), (i, s)):
                            if r and not (val.get(r) == ("img",)):
                                pick = (r, sc) if pick is None or idx.get(r, [1])[0] > idx.get(pick[0], [1])[0] else pick
                        if pick:
                            stride = idx.get(pick[0], [1, None])[0] * pick[1]
                            origin = idx.get(pick[0], [1, None])[1]
                        if stride < 2:
                            kind = "rva"
                if tab is not None:
                    x = tab + (field if kind == "field" else 0)
                    fn.refs.setdefault(x, "base")
                    if mn != "lea" or True:
                        fn.uses.append(dict(table=tab, at=at, text=text, kind=kind, stride=stride if stride >= 2 else 0,
                                            field=field if kind != "rva" else 0, origin=origin))
                    if stride >= 2:
                        fn.hints.add(stride)
                if mn == "lea" and dst and (bv or iv or True):
                    # pointer arithmetic result: lea dst,[base + idx*k + d] keeps the table, lea dst,[i + i*k] scales
                    if bv and bv[0] == "base":
                        val[dst] = bv
                        if i:
                            idx[dst] = [ii[0] * s, ii[1]]
                    elif b and i and b == i:
                        m = idx.get(b, [1, None])
                        idx[dst] = [m[0] * (1 + s), m[1]]
                        val.pop(dst, None)
                    elif i and not b:
                        m = idx.get(i, [1, None])
                        idx[dst] = [m[0] * s, m[1]]
                        val.pop(dst, None)
                    elif b and not i:
                        idx[dst] = list(bi)
                        val.pop(dst, None)
                    else:
                        val.pop(dst, None)
                        idx.pop(dst, None)
                    continue
                # an index loaded from [reg+0] (entity number at offset 0 of an entity)
                if mn in ("mov", "movsxd") and dst and not i and b and d == 0 and b not in ("rsp", "rbp") and \
                        (val.get(b) is None) and mem.size == 4:
                    val.pop(dst, None)
                    idx[dst] = [1, "entity number read at [reg+0]"]
                    continue
        # ---- immediates and counts
        if ops:
            for k, o in enumerate(ops):
                if o.type == CS_OP_IMM and mn in ("cmp", "mov", "sub", "add") and "rsp" not in ins.op_str and \
                        k == len(ops) - 1 and ops[0].type != CS_OP_MEM:
                    v = o.imm
                    if v in STOCK_COUNTS:
                        fn.signals.append(("const", STOCK_COUNTS[v], at))
        # ---- register tracking
        if mn == "imul" and len(ops) == 3 and ops[2].type == CS_OP_IMM and ops[0].type == CS_OP_REG and ops[1].type == CS_OP_REG:
            d0 = dst
            sreg = canon(ins, ops[1].reg)
            m = idx.get(sreg, [1, None])
            v = ops[2].imm
            if v > 0x7fff and m[1] and "diff" in str(m[1]):
                idx[d0] = [1, m[1]]
            else:
                idx[d0] = [m[0] * v, m[1]]
                if v >= 4:
                    fn.hints.add(v)
            val.pop(d0, None)
            continue
        if mn == "imul" and len(ops) == 3 and ops[2].type == CS_OP_IMM and ops[1].type == CS_OP_MEM and dst:
            idx[dst] = [ops[2].imm, None]
            val.pop(dst, None)
            continue
        if mn in ("shl", "sal") and len(ops) == 2 and ops[1].type == CS_OP_IMM and dst:
            m = idx.get(dst, [1, None])
            idx[dst] = [m[0] << ops[1].imm, m[1]]
            continue
        if mn in ("shr", "sar") and len(ops) == 2 and ops[1].type == CS_OP_IMM and dst:
            m = idx.get(dst, [1, None])
            if m[1] and "diff" in str(m[1]):
                idx[dst] = [1, m[1]]
            continue
        if mn == "add" and len(ops) == 2 and dst:
            if ops[1].type == CS_OP_REG:
                src = canon(ins, ops[1].reg)
                if src == dst:
                    m = idx.get(dst, [1, None])
                    idx[dst] = [m[0] * 2, m[1]]
                    continue
                bv = val.get(dst)
                if bv and bv[0] == "base":
                    sm = idx.get(src, [1, None])
                    fn.uses.append(dict(table=bv[1], at=at, text=text, kind="indexed", stride=sm[0] if sm[0] >= 2 else 0,
                                        field=0, origin=sm[1]))
                    if sm[0] >= 2:
                        fn.hints.add(sm[0])
                    continue
            elif ops[1].type == CS_OP_IMM:
                bv = val.get(dst)
                if bv and bv[0] == "base" and ops[1].imm >= 4:
                    fn.uses.append(dict(table=bv[1], at=at, text=text, kind="step", stride=ops[1].imm, field=0, origin=None))
                    fn.hints.add(ops[1].imm)
                    continue
                if ops[1].imm >= 4:
                    fn.hints.add(ops[1].imm)
        if mn == "sub" and len(ops) == 2 and ops[0].type == CS_OP_REG and dst:
            a = val.get(dst)
            rhs = None
            if ops[1].type == CS_OP_REG:
                rhs = val.get(canon(ins, ops[1].reg))
            if (a and a[0] in ("load", "base") and a[1] in (SENTIENT_BASE, G_ENTITIES)) or \
               (rhs and rhs[0] in ("load", "base") and rhs[1] in (SENTIENT_BASE, G_ENTITIES)):
                idx[dst] = [1, "diff of an entity/sentient pointer"]
                val.pop(dst, None)
                fn.pass3 = True
                continue
        if mn == "mov" and len(ops) == 2 and ops[0].type == CS_OP_REG:
            if ops[1].type == CS_OP_REG:
                src = canon(ins, ops[1].reg)
                if src in val:
                    val[dst] = val[src]
                else:
                    val.pop(dst, None)
                if src in idx:
                    idx[dst] = list(idx[src])
                else:
                    idx.pop(dst, None)
                continue
            if ops[1].type == CS_OP_IMM:
                if ops[1].imm == BASE:
                    val[dst] = ("img",)
                else:
                    val.pop(dst, None)
                idx.pop(dst, None)
                if ops[1].imm in STOCK_COUNTS and "rsp" not in ins.op_str:
                    pass
                continue
        if mn in ("movsxd", "movzx", "movsx", "cdqe") and len(ops) == 2 and ops[0].type == CS_OP_REG and ops[1].type == CS_OP_REG:
            src = canon(ins, ops[1].reg)
            if src in idx:
                idx[dst] = list(idx[src])
            else:
                idx.pop(dst, None)
            val.pop(dst, None)
            continue
        # ---- size pattern (pass 2): a call / tail jump / rep stos with a static destination and a constant length
        if mn == "call" or (mn == "jmp" and ops and ops[0].type == CS_OP_IMM) or mn.startswith("rep") or mn.startswith("stos"):
            _size_pattern(ctx, fn, window, at, mn)
        # ---- generic write invalidation
        if dst and mn not in NOWRITE and not mn.startswith("j"):
            written.add(dst)
        if mn == "call":
            for r in VOLATILE:
                val.pop(r, None)
                idx.pop(r, None)
        elif dst and mn not in NOWRITE and not mn.startswith("j"):
            val.pop(dst, None)
            idx.pop(dst, None)
    return fn


def _size_pattern(ctx, fn, window, at, mn):
    """Look back over the last instructions: lea rcx/rdi,[rip+X]; mov r8d/edx/ecx,imm; call / rep stos."""
    from capstone import CS_OP_IMM, CS_OP_MEM, CS_OP_REG
    from capstone.x86 import X86_REG_RIP
    dest = {}
    imm = {}
    immat = {}
    for ins in window[:-1]:
        ops = ins.operands
        if not ops:
            continue
        if ins.mnemonic == "lea" and ops[0].type == CS_OP_REG and ops[1].type == CS_OP_MEM and ops[1].mem.base == X86_REG_RIP:
            x = ins.address + ins.size + ops[1].mem.disp
            if ctx.is_data(x):
                dest[canon(ins, ops[0].reg)] = x
        elif ins.mnemonic == "mov" and len(ops) == 2 and ops[0].type == CS_OP_REG and ops[1].type == CS_OP_IMM:
            imm[canon(ins, ops[0].reg)] = ops[1].imm
            immat[canon(ins, ops[0].reg)] = ins.address
    if mn.startswith("rep") or mn.startswith("stos"):
        width = 8 if "stosq" in mn or window[-1].op_str.startswith("qword") else (4 if "stosd" in mn else 1)
        last = window[-1]
        txt = last.mnemonic + " " + last.op_str
        if "stosq" in txt:
            width = 8
        elif "stosd" in txt:
            width = 4
        elif "stosb" in txt:
            width = 1
        if "rdi" in dest and "rcx" in imm:
            fn.sizes.append((dest["rdi"], imm["rcx"] * width, "rep stos", immat["rcx"]))
        return
    # memset(dst=rcx, 0, len=r8) / memcpy(dst=rcx, src=rdx, len=r8) / fill(rcx, edx=len)
    if "rcx" in dest and "r8" in imm and imm["r8"] > 0:
        fn.sizes.append((dest["rcx"], imm["r8"], "call", immat["r8"]))
    if "rdx" in dest and "r8" in imm and imm["r8"] > 0:
        fn.sizes.append((dest["rdx"], imm["r8"], "call (source)", immat["r8"]))
    if "rcx" in dest and "rdx" in imm and "r8" not in imm and imm["rdx"] > 0x40:
        fn.sizes.append((dest["rcx"], imm["rdx"], "call (rdx length?)", immat["rdx"]))


def size_hypotheses(length):
    out = []
    for k in KS:
        if length % k == 0 and length // k >= 4:
            out.append((k, length // k))
    return out


# ---------------------------------------------------------------- the three passes over analysed functions
class Cand:
    def __init__(self, base):
        self.base = base
        self.votes = {}                  # stride -> count
        self.passes = {}                 # pass number -> [evidence]
        self.funcs = set()               # functions that index / walk / size it
        self.bases = {base}              # other addresses merged into it (fields, row heads)
        self.evidence = []
        self.signals = {}                # function -> [signals]
        self.rows_hint = set()
        self.sites = []                  # (at, text) of every referencing instruction with this table
        self.used = False                # an indexed / stepped / image-relative use exists (not only a size or a pair of leas)

    def vote(self, stride, w=1):
        if stride:
            self.votes[stride] = self.votes.get(stride, 0) + w


def collect(ctx, fns):
    """Turn analysed functions into candidates by the three passes. Returns {base: Cand}."""
    cands = {}

    def cand(x):
        c = cands.get(x)
        if c is None:
            c = cands[x] = Cand(x)
        return c

    for fn in fns:
        sig = fn.signals
        counts = [s for s in sig if s[0] == "count"]
        consts = [s for s in sig if s[0] == "const"]
        names = {x[1] for x in sig}
        if "svs_numclients" in names and "start 18" in names:
            counts = counts + [("count", "clients then agents loop", 0)]
        # pass 1: a loop plus a capacity count or a stock bound, and an indexed / stepped static use
        p1sig = counts + consts
        for u in fn.uses:
            if u["kind"] == "field":
                continue
            c = cand(u["table"])
            if u["kind"] == "rva":
                c.sites.append((u["at"], u["text"]))
                c.funcs.add(fn.start)             # an image-relative indexed use is a reference the patch has to move
            c.used = c.used or bool(u["stride"] or u["kind"] in ("step", "rva"))
            if u["stride"]:
                c.vote(u["stride"])
            if fn.loop and p1sig and (u["stride"] or u["kind"] in ("step", "rva")):
                c.funcs.add(fn.start)
                ev = "loop with " + ", ".join(sorted({s[1] for s in p1sig})[:4])
                c.passes.setdefault(1, []).append((fn.start, u["at"], ev + ": " + u["text"]))
                c.signals.setdefault(fn.start, set()).update(s[1] for s in p1sig)
            if (u["origin"] or (fn.pass3 and u["stride"])) and not u["text"].startswith(("call", "jmp")):
                c.funcs.add(fn.start)
                ev = u["origin"] or "function divides by an entity/sentient stride"
                c.passes.setdefault(3, []).append((fn.start, u["at"], ev + ": " + u["text"]))
        # pass 2a: size calls
        for x, length, how, at in fn.sizes:
            for k, s in size_hypotheses(length):
                c = cand(x)
                c.funcs.add(fn.start)
                c.rows_hint.add(k)
                c.vote(s, 2)
                c.sites.append((at, f"size immediate 0x{length:X}"))
                c.passes.setdefault(2, []).append((fn.start, at, f"{how} 0x{length:X} bytes = {k} x 0x{s:X}"))
        # pass 2b: two static leas whose difference is k x stride, the stride also used by the function
        lea_t = sorted(set(x for x, _ in fn.leas))
        if 2 <= len(lea_t) <= 60:
            for i, a in enumerate(lea_t):
                for b in lea_t[i + 1:]:
                    dlt = b - a
                    if dlt > 0x400000:
                        break
                    for k in KS:
                        if dlt % k == 0 and dlt // k >= 8 and (dlt // k) in fn.hints:
                            c = cand(a)
                            c.funcs.add(fn.start)
                            c.rows_hint.add(k)
                            c.vote(dlt // k, 2)
                            c.passes.setdefault(2, []).append((fn.start, 0, f"two leas {a:X}..{b:X} = {k} x 0x{dlt // k:X}"))
    # the lea of a table base is a reference the capacity patch has to move
    for fn in fns:
        for x, at in fn.leas:
            c = cands.get(x)
            if c is not None and c.funcs:
                c.sites.append((at, "lea of the base"))
    return cands


def merge(cands, addr_funcs):
    """Merge candidates that one function uses with the same stride and that lie within MAX_SPAN_ROWS rows of each other."""
    items = []
    for x, c in cands.items():
        if not c.funcs or not c.votes:
            continue
        s = max(c.votes, key=lambda k: (c.votes[k], k))
        items.append((x, s, c))
    items.sort(key=lambda t: t[0])
    tables = []
    for x, s, c in items:
        placed = False
        for t in tables:
            d = x - t.base
            if d < 0 or d > MAX_SPAN_ROWS * t.stride:
                continue
            same = t.stride == s
            field0 = d < t.stride and t.stride in c.votes
            linked = same and ((t.funcs & c.funcs) or any(
                addr_funcs.get(b, {}).get(f) == "base" and addr_funcs.get(x, {}).get(f) == "base"
                for b in t.bases for f in addr_funcs.get(x, {})))
            if linked or field0:
                t.absorb(x, c)
                placed = True
                break
        if not placed:
            tables.append(Table(x, s, c))
    return tables


class Table:
    def __init__(self, base, stride, c):
        self.base = base
        self.stride = stride
        self.bases = {base}
        self.funcs = set()
        self.passes = {}
        self.signals = {}
        self.rows_hint = set()
        self.sites = []
        self.votes = {}
        self.used = False
        self.absorb(base, c)

    def absorb(self, x, c):
        self.bases.add(x)
        if x < self.base:
            self.base = x
        self.funcs |= c.funcs
        self.used = self.used or c.used
        self.rows_hint |= c.rows_hint
        self.sites += c.sites
        for p, ev in c.passes.items():
            self.passes.setdefault(p, []).extend(ev)
        for f, s in c.signals.items():
            self.signals.setdefault(f, set()).update(s)
        for k, v in c.votes.items():
            self.votes[k] = self.votes.get(k, 0) + v


# counts that grow with -agent-capacity (svs_numclients and MAX_CLIENTS stay 18: a table indexed by them alone is not at risk)
CAPACITY_SIGNALS = {"agent count [*(0x146B22AC8)+0x30]", "MAX_CHARACTERS", "sentient count", "agent count", "clients then agents loop"}


def priority(r):
    """Which candidates to read first. A: room is exactly a stock row count (24, 42, 66, 71). A18: room is the 18 client rows
    and a loop starts at index 18 or reads a capacity count. B: a loop bounded by a capacity-dependent count over a table
    with less room than 118 rows. C: an index computed from an entity or sentient, room under 147 rows. Else None."""
    room_rows, s = r["room_rows"], r["stride"]
    if room_rows is not None and room_rows < 2 and r["used"]:
        room_rows = r["room_rows_far"]            # another function's fields sit inside the first rows: look past them
    if r["handled"] == "yes" or room_rows is None or s % 4 or s < 4:
        return None
    sig = set(r["signals"])
    if room_rows in KS:
        return "A" if r["used"] else "A-size"
    if room_rows == 18 and (sig & CAPACITY_SIGNALS or "start 18" in sig):
        return "A18"
    if sig & CAPACITY_SIGNALS and 8 <= room_rows < 118 and 1 in r["passes"]:
        return "B"
    if 3 in r["passes"] and 8 <= room_rows < MAX_ROWS:
        return "C"
    return None


def room(table, addr_funcs, sorted_addrs, skip_rows=0):
    """Rows from the base to the next referenced static address that no function of the table uses with a table register.
    skip_rows: ignore addresses closer than that many rows (fields of the first rows that other functions touch)."""
    i = bisect.bisect_right(sorted_addrs, table.base + skip_rows * table.stride - (1 if skip_rows else 0))
    while i < len(sorted_addrs):
        a = sorted_addrs[i]
        users = addr_funcs.get(a, {})
        # owned: used through a table register by one of the table's functions
        if not any(f in table.funcs and k == "base" for f, k in users.items()):
            return a, (a - table.base)
        i += 1
    return None, None


def handled_sets(source_text):
    """Addresses written in the capacity source: data targets and code sites (any 0x14xxxxxxx / 0x5xxxxxx literal)."""
    lits = set()
    for m in re.finditer(r"\b0x([0-9A-Fa-f]{6,9})(?:ull|ULL|u|U)?\b", source_text):
        v = int(m.group(1), 16)
        if 0x140001000 <= v < 0x14C400000:
            lits.add(v)
        elif 0x1000000 <= v < 0xC400000:
            lits.add(BASE + v)          # image-base relative values (rva)
    return lits


def read_source(spec):
    if not spec:
        return ""
    if spec.startswith("git:"):
        _, ref, path = spec.split(":", 2)
        return subprocess.run(["git", "show", f"{ref}:{path}"], capture_output=True, text=True, check=True).stdout
    with open(spec, encoding="utf-8", errors="replace") as f:
        return f.read()


def judge_handled(table, lits, sizes_of):
    """handled: some site instruction of the table holds a patched field, or a patched data target lies in its span.
    Returns (sites patched, sites in all, patched data targets in the span, the sites not patched)."""
    hit_sites = 0
    open_sites = []
    for at, text in sorted(set(table.sites)):
        if any(at <= v < at + 12 for v in lits_near(lits, at)):
            hit_sites += 1
        else:
            open_sites.append((at, text))
    span_lo = table.base
    span_hi = table.base + table.stride * max(table.rows_hint or {42}, default=42)
    data_hits = sorted(v for v in lits if span_lo <= v < span_hi + table.stride)
    return hit_sites, hit_sites + len(open_sites), data_hits, open_sites


_lit_sorted = {}


def lits_near(lits, at):
    key = id(lits)
    arr = _lit_sorted.get(key)
    if arr is None:
        arr = _lit_sorted[key] = sorted(lits)
    i = bisect.bisect_left(arr, at)
    return arr[i:i + 4]


# ---------------------------------------------------------------- driver
def load_ctx(a):
    e = eng.Engine(a)
    img = e.image
    funcs = [(r[0], r[1]) for r in e.need_db().execute("SELECT addr,end FROM functions ORDER BY addr")]
    # keep a function inside its code section (split bodies end far away)
    fixed = []
    for b, en in funcs:
        sec = img.section(b)
        if sec and sec[5] & 0x20000000:
            fixed.append((b, min(en, sec[1] + sec[2], b + 0x100000)))
    writable = [(s[1], s[1] + max(s[2], s[4])) for s in img.sections if s[5] & 0x80000000 and s[0] in (".data",)]
    ctx = Ctx(img, fixed, writable, a.index)
    return e, ctx


def function_set(ctx):
    """Functions that reference a writable static address (rip form) or use the image-relative disp form."""
    lo, hi = ctx.writable[0][0], ctx.writable[-1][1]
    idb = sqlite3.connect(f"file:{ctx.index}?mode=ro", uri=True)
    fs = set(r[0] for r in idb.execute("SELECT DISTINCT func FROM insn WHERE kind='addr' AND value>=? AND value<?", (lo, hi)))
    fs |= set(r[0] for r in idb.execute("SELECT DISTINCT func FROM insn WHERE kind='disp' AND value>=? AND value<?",
                                        (lo - BASE, hi - BASE)))
    idb.close()
    return fs


def decomp_signals(e):
    """Pass 3 helper: functions whose decompiled C divides a pointer difference by an entity or sentient stride."""
    out = {}
    rx = re.compile(r"/ (0xa0|160|0x3f8|1016|0xfe|254|0x3f08|0x5010)\b")
    for addr, blob in e.need_db().execute("SELECT addr,code FROM decomp WHERE ok=1"):
        code = zlib.decompress(blob).decode("utf-8", "replace")
        if "143c986a0" in code or "g_entities" in code:
            if rx.search(code):
                out[addr] = True
    return out


def analyze_all(ctx, e=None, funcs=None, progress=None):
    starts = funcs if funcs is not None else function_set(ctx)
    ends = dict(ctx.funcs)
    fns = []
    for k, f in enumerate(sorted(starts)):
        en = ends.get(f)
        if en is None:
            # a function key from the index without a Ghidra range: up to the next known start
            i = bisect.bisect_right(ctx.starts, f)
            en = ctx.starts[i] if i < len(ctx.starts) else f + 0x1000
            en = min(en, f + 0x4000)
        fns.append(analyze(ctx, f, en))
        if progress and k % 5000 == 0:
            progress(k, len(starts))
    dsig = decomp_signals(e) if e is not None else {}
    for fn in fns:
        if fn.start in dsig:
            fn.pass3 = True
    return fns


def run(ctx, e=None, funcs=None, source="", progress=None, fns=None):
    t0 = time.time()
    if fns is None:
        fns = analyze_all(ctx, e, funcs, progress)
    cands = collect(ctx, fns)
    # address -> {function: kind} for the room and for linking the row heads of one table
    addr_funcs = {}
    for fn in fns:
        for x, k in fn.refs.items():
            cur = addr_funcs.setdefault(x, {})
            if cur.get(fn.start) != "base":
                cur[fn.start] = k
    tables = merge(cands, addr_funcs)
    ptr_globals = {}
    for fn in fns:
        for x, pg, at in fn.ptr_stores:
            ptr_globals.setdefault(x, set()).add((pg, fn.start))
    sorted_addrs = sorted(addr_funcs)
    lits = handled_sets(source)
    rows = []
    for t in tables:
        nxt, dist = room(t, addr_funcs, sorted_addrs)
        s = t.stride
        rows_room = (dist // s) if dist is not None else None
        slack = (dist % s) if dist is not None else None
        nxt2, dist2 = room(t, addr_funcs, sorted_addrs, 2)
        rows_far = (dist2 // s) if dist2 is not None else None
        hit, total, data_hits, open_sites = judge_handled(t, lits, None)
        if source:
            handled = "yes" if total and hit == total else ("partly" if hit or data_hits else "no")
        else:
            handled = "unknown"
        passes = sorted(t.passes)
        ev = []
        for p in passes:
            for fa, at, text in t.passes[p][:2]:
                ev.append(f"pass {p}: {fa:X} @ {at:X} {text}"[:200])
        rows.append(dict(
            base=f"{t.base:X}", stride=s, stride_hex=f"0x{s:X}", votes={f"0x{k:X}": v for k, v in sorted(t.votes.items(), key=lambda kv: -kv[1])[:4]},
            passes=passes, funcs=sorted(f"{f:X}" for f in t.funcs), n_funcs=len(t.funcs),
            rows_implied=sorted(t.rows_hint), room_rows=rows_room, room_slack=slack, room_rows_far=rows_far,
            next_symbol_far=f"{nxt2:X}" if nxt2 else None,
            next_symbol=f"{nxt:X}" if nxt else None,
            strong=(rows_room in KS) or bool(t.rows_hint & {rows_room}),
            handled=handled, handled_sites=f"{hit}/{total}", patched_targets=[f"{v:X}" for v in data_hits[:4]],
            open_sites=[f"{at:X} {text}" for at, text in open_sites[:12]],
            signals=sorted({x for v in t.signals.values() for x in v}), used=t.used,
            other_bases=sorted(f"{b:X}" for b in t.bases if b != t.base)[:8], evidence=ev,
            pointer_globals=sorted({f"{pg:X} (stored in {f:X})" for b in t.bases for pg, f in ptr_globals.get(b, ())})[:4]))
    for r in rows:
        r["priority"] = priority(r)
    rows.sort(key=lambda r: int(r["base"], 16))
    return rows, dict(functions=len(fns), tables=len(rows), seconds=round(time.time() - t0, 1))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--db", default=eng.DEFAULT_DB)
    ap.add_argument("--index", default=eng.DEFAULT_INDEX)
    ap.add_argument("--image", default=eng.DEFAULT_IMAGE)
    ap.add_argument("--capacity-source", default="git:origin/claude/engine-capacity:src/native/agent_capacity.cpp",
                    help="the capacity patch source: a file or git:REF:PATH (run inside a repository that has it)")
    ap.add_argument("--json", help="write the full result here")
    ap.add_argument("--all", action="store_true", help="print every candidate, not only the prioritised ones and the strong handled ones")
    ap.add_argument("--unhandled", action="store_true", help="print only tables not handled by the capacity source")
    a = ap.parse_args(argv)
    a.snapshots = eng.DEFAULT_SNAPSHOTS
    try:
        src = read_source(a.capacity_source)
    except Exception as ex:  # noqa: BLE001
        print(f"capacity source not read ({ex}): the handled column says unknown", file=sys.stderr)
        src = ""
    e, ctx = load_ctx(a)
    rows, stats = run(ctx, e, source=src, progress=lambda k, n: print(f"  {k}/{n}", file=sys.stderr))
    if a.json:
        with open(a.json, "w") as f:
            json.dump(dict(stats=stats, tables=rows), f, indent=1)
    shown = rows if a.all else [r for r in rows if r["priority"] or r["handled"] == "yes" and r["strong"]]
    if a.unhandled:
        shown = [r for r in shown if r["handled"] != "yes"]
    print(f"{stats['tables']} candidate tables in {stats['functions']} functions ({stats['seconds']} s); {len(shown)} shown")
    for r in shown:
        print(f"{r['base']} stride {r['stride_hex']} room {r['room_rows']} rows (+{r['room_slack']}) next {r['next_symbol']} "
              f"passes {r['passes']} funcs {r['n_funcs']} handled {r['handled']} ({r['handled_sites']}) "
              f"{'priority ' + r['priority'] if r['priority'] else ''}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
