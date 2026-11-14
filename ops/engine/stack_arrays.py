#!/usr/bin/env python3
"""Stack-array scan: find the next "71-entry array under the cookie" by reading, not by crashing (docs/CAVE-REWRITER.md, "Scan").

    python -B ops/engine/stack_arrays.py [--range LO HI]... [--markdown out.md] [--json out.json]

For every function of the given code ranges (default: the three ranges of the capacity work) whose unwind data shows a GS cookie
handler (or whose code reads the security cookie) and whose frame (ALLOC) is at least 71 x 8 bytes, the scan decodes every chunk
of the function and looks for LOOPS (a backward direct branch) that WRITE to the stack through
  - an indexed address `[rsp/rbp + idx*k + d]`, or
  - a cursor: a register taken with `lea reg,[rsp/rbp + d]` and stepped with `add reg, imm` (or `lea reg,[reg+imm]`),
and for functions that call the sentient iterators (FUN_140AF71F0 / FUN_140AF8590) or read the character / agent / sentient count
globals. For each candidate it reports the array start (offset from rsp after the prologue), the room up to the cookie and up to the
next other stack access, the stride, what bounds the loop and the verdict under `-agent-capacity 100`:

    SAFE                  the bound (a constant, or a count) fits the room up to the next other stack access
    OVERRUNS ABOVE N      the bound exceeds the room up to the cookie: more than N entries write over the cookie
    UNKNOWN               the bound could not be read, or the room is between the two limits, or the array pointer is kept in memory

It is a reading aid, not a proof: a verdict is only as good as the linear stack model (the same one as frame_grow.py) and the loop
bound heuristics below; every OVERRUNS and every UNKNOWN is meant to be looked at in the decompile (`engine.py decomp`).
"""
import argparse
import json
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cave_plan as cp  # noqa: E402
import unwind_info as uw  # noqa: E402
from capstone import CS_GRP_CALL, CS_GRP_JUMP, CS_GRP_RET, CS_OP_IMM, CS_OP_MEM, CS_OP_REG  # noqa: E402
from capstone.x86 import X86_REG_RIP  # noqa: E402

GS_HANDLERS = (0x1412BA038,)             # __GSHandlerCheck
SECURITY_COOKIE = 0x141BE1530
ITERATORS = {0x140AF71F0: "sentient iterator FUN_140AF71F0", 0x140AF8590: "sentient iterator FUN_140AF8590"}
COUNT_GLOBALS = {0x143C986A8: "sentient count", 0x143C986C0: "agent count", 0x144C6F208: "MAX_CHARACTERS", 0x144C6F20C: "MAX_CLIENTS"}
DEFAULT_RANGES = [(0x1403D0000, 0x140480000), (0x140AC0000, 0x140B40000), (0x140C10000, 0x140C60000)]
MIN_FRAME = 71 * 8
# the values the counts take under -agent-capacity 100 (agents, characters = 18 + n, sentients = n + 47), and the stock ones
COUNT_MAX = {"sentient iterator": 147, "sentient count": 147, "agent count": 100, "MAX_CHARACTERS": 118, "MAX_CLIENTS": 18}
CURSOR_STEP = 0x100

_CANON = {}
for _f in (("rax", "eax", "ax", "al"), ("rcx", "ecx", "cx", "cl"), ("rdx", "edx", "dx", "dl"), ("rbx", "ebx", "bx", "bl"),
           ("rsp", "esp", "sp", "spl"), ("rbp", "ebp", "bp", "bpl"), ("rsi", "esi", "si", "sil"), ("rdi", "edi", "di", "dil")):
    for _n in _f:
        _CANON[_n] = _f[0]
for _i in range(8, 16):
    for _s in ("", "d", "w", "b"):
        _CANON["r%d%s" % (_i, _s)] = "r%d" % _i


def reg(ins, rid):
    n = ins.reg_name(rid)
    return _CANON.get(n, n)


class Function:
    def __init__(self, begin, ui, chunks):
        self.begin, self.ui, self.chunks = begin, ui, chunks    # chunks: [(begin, end)] in address order
        self.frame = ui.alloc()
        self.pushes = sum(1 for c in ui.codes if c.op == 0)
        self.handler = None
        self.cookie = None
        self.insns = []
        self.notes = []


def read_functions(image, ranges):
    va, n = image.exception_directory
    rfs = []
    for k in range(n):
        raw = image.read(va + 12 * k, 12)
        b, e, u = struct.unpack("<III", raw)
        a = image.base + b
        if any(lo <= a < hi for lo, hi in ranges):
            rfs.append(uw.RuntimeFunction(va + 12 * k, b, e, u))
    by_begin, uis = {}, {}
    for rf in rfs:
        by_begin[rf.begin_rva] = rf
        try:
            uis[rf.begin_rva] = uw.read_unwind_info(image, rf)
        except uw.UnwindError:
            uis[rf.begin_rva] = None
    groups = {}
    for rf in rfs:
        cur, steps = rf, 0
        while uis.get(cur.begin_rva) is not None and uis[cur.begin_rva].flags & uw.UNW_FLAG_CHAININFO and steps < 16:
            cur = uis[cur.begin_rva].chain
            steps += 1
        groups.setdefault(cur.begin_rva, []).append(rf)
    out = []
    for prim, chunk_rfs in groups.items():
        ui = uis.get(prim)
        if ui is None or ui.flags & uw.UNW_FLAG_CHAININFO:
            continue
        chunks = sorted((image.base + r.begin_rva, image.base + r.end_rva) for r in chunk_rfs)
        if prim not in {r.begin_rva for r in chunk_rfs}:
            chunks = sorted(chunks + [(image.base + prim, image.base + by_begin[prim].end_rva)]) if prim in by_begin else chunks
        f = Function(image.base + prim, ui, chunks)
        if ui.handler_va:
            f.handler = image.base + ui.handler_rva
            if f.handler in GS_HANDLERS:
                f.cookie = struct.unpack("<I", ui.handler_data[:4])[0] & ~7
        out.append(f)
    return out


def decode_function(image, f):
    for lo, hi in f.chunks:
        raw = image.read(lo, hi - lo)
        if raw is None:
            f.notes.append("chunk %#x not in the image" % lo)
            continue
        try:
            f.insns.extend(cp.decode(raw, lo))
        except cp.Refusal as e:
            f.notes.append("undecodable: %s" % e.reasons[0])
    f.insns.sort(key=lambda i: i.address)


def mem_operands(ins):
    return [o for o in ins.operands if o.type == CS_OP_MEM and o.mem.base != X86_REG_RIP]


def model(f):
    """Linear stack model: every stack memory operand with its offset s from S (rsp after the prologue)."""
    insns = f.insns
    refs, cursors_seen, S = [], [], None
    rsp_c, stage, alias, rbp_c = 0, "pro", {}, None
    cursor = {}                                           # reg -> [s_start, stride or None]
    rip_reads, iter_calls, cookie_code = [], [], False
    prev_chunk_end = None
    for ins in insns:
        if prev_chunk_end is not None and ins.address != prev_chunk_end and S is not None:
            rsp_c, stage, alias = S, "body", {}           # a new (non-contiguous or chained) chunk: the body state
        prev_chunk_end = ins.address + ins.size
        mn, ops = ins.mnemonic, ins.operands
        if mn == "push":
            rsp_c -= 8
        elif mn == "pop":
            rsp_c += 8
        elif mn == "sub" and ops and ops[0].type == CS_OP_REG and reg(ins, ops[0].reg) == "rsp" and ops[1].type == CS_OP_IMM and S is None:
            rsp_c -= ops[1].imm
            S, stage = rsp_c, "body"
        elif mn == "sub" and ops and ops[0].type == CS_OP_REG and reg(ins, ops[0].reg) == "rsp" and ops[1].type == CS_OP_REG and S is None:
            rsp_c -= f.frame                              # `mov eax, N; call __chkstk; sub rsp, rax`: the frame of the unwind data
            S, stage = rsp_c, "body"
        elif mn == "add" and ops and ops[0].type == CS_OP_REG and reg(ins, ops[0].reg) == "rsp" and ops[1].type == CS_OP_IMM:
            rsp_c += ops[1].imm
        elif mn == "mov" and len(ops) == 2 and ops[0].type == CS_OP_REG and ops[1].type == CS_OP_REG and reg(ins, ops[1].reg) == "rsp":
            d = reg(ins, ops[0].reg)
            if d in ("rax", "r10", "r11"):
                alias[d] = rsp_c
            elif d == "rbp":
                rbp_c = rsp_c
        if mn == "lea" and ops[0].type == CS_OP_REG and ops[1].type == CS_OP_MEM and ops[1].mem.base and not ops[1].mem.index \
                and ops[1].mem.base != X86_REG_RIP:
            b, d = reg(ins, ops[1].mem.base), reg(ins, ops[0].reg)
            base_c = rsp_c if b == "rsp" else (rbp_c if b == "rbp" else alias.get(b))
            if d == "rbp" and base_c is not None and b != "rbp":
                rbp_c = base_c + ops[1].mem.disp
            elif base_c is not None and d not in ("rsp",) and S is not None and base_c + ops[1].mem.disp - S < f.frame:
                cursor[d] = [base_c + ops[1].mem.disp - S, None]
            elif d in cursor and b == d and 0 < ops[1].mem.disp <= CURSOR_STEP:
                cursor[d][1] = ops[1].mem.disp
        elif mn == "add" and ops and ops[0].type == CS_OP_REG and ops[1].type == CS_OP_IMM and 0 < ops[1].imm <= CURSOR_STEP:
            d = reg(ins, ops[0].reg)
            if d in cursor:
                cursor[d][1] = ops[1].imm
            elif d == "rbp" and rbp_c is not None and S is not None:
                cursor["rbp"] = [rbp_c - S, ops[1].imm]
                cursors_seen.append(("rbp", ins))
        # stack memory operands
        for o in mem_operands(ins):
            if not o.mem.base:
                continue
            b = reg(ins, o.mem.base)
            base_c = rsp_c if b == "rsp" else (rbp_c if b == "rbp" else alias.get(b))
            if base_c is not None and S is not None:
                refs.append({"ins": ins, "s": base_c + o.mem.disp - S, "base": b, "index": bool(o.mem.index), "scale": o.mem.scale,
                             "write": bool(o.access & 2), "lea": mn == "lea", "disp": o.mem.disp})
            elif b in cursor and S is not None and o.access & 2 and not o.mem.index:
                refs.append({"ins": ins, "s": cursor[b][0] + o.mem.disp, "base": b, "index": False, "scale": 1, "write": True,
                             "lea": False, "disp": o.mem.disp, "cur": cursor[b]})
        # globals read: count globals (rip-relative) and the cookie
        for o in ins.operands:
            if o.type == CS_OP_MEM and o.mem.base == X86_REG_RIP:
                t = ins.address + ins.size + o.mem.disp
                if t in COUNT_GLOBALS:
                    rip_reads.append((ins.address, COUNT_GLOBALS[t]))
                if t == SECURITY_COOKIE:
                    cookie_code = True
        if CS_GRP_CALL in ins.groups:
            if ins.operands and ins.operands[0].type == CS_OP_IMM and ins.operands[0].imm in ITERATORS:
                iter_calls.append((ins.address, ITERATORS[ins.operands[0].imm]))
            alias = {}
        elif CS_GRP_JUMP in ins.groups or CS_GRP_RET in ins.groups:
            alias = {}
        # writes kill cursors
        try:
            for r in ins.regs_access()[1]:
                n = reg(ins, r)
                if n in cursor and not (mn in ("add", "lea") and n == reg(ins, ops[0].reg)) and n != "rbp":
                    del cursor[n]
        except Exception:
            pass
        if CS_GRP_RET in ins.groups:
            rsp_c = S if S is not None else 0
    rbp_cursor = next((c for c in cursors_seen if c[0] == "rbp"), None)
    for r in refs:
        if "cur" in r:
            if r["cur"][1]:
                r["cursor"] = r["cur"][1]                 # the stride is known only after the step instruction (end of the loop body)
        elif rbp_cursor and r["base"] == "rbp" and r["write"] and not r["lea"] and abs(r["disp"]) <= 0x40:
            r["cursor"] = rbp_cursor[1].operands[1].imm   # rbp itself steps through the array: its small-displacement stores are entry fields
    return {"refs": refs, "S": S, "rip_reads": rip_reads, "iter_calls": iter_calls, "cookie_code": cookie_code}


def loops(insns):
    """Backward direct branches: [(target, end_of_branch_instruction)]."""
    out = []
    for ins in insns:
        if (CS_GRP_JUMP in ins.groups) and ins.operands and ins.operands[0].type == CS_OP_IMM and ins.operands[0].imm <= ins.address:
            out.append((ins.operands[0].imm, ins.address + ins.size))
    return out


def loop_bound(f, region, m):
    """What bounds the loop region: (kind, value, text)."""
    lo, hi = region
    inside = [i for i in f.insns if lo <= i.address < hi]
    for a, name in m["iter_calls"]:
        if lo <= a < hi:
            return ("count", COUNT_MAX["sentient iterator"], "%s in the loop (the sentient count, %d under -agent-capacity 100)" % (name, COUNT_MAX["sentient iterator"]))
    for a, name in m["rip_reads"]:
        if lo <= a < hi:
            return ("count", COUNT_MAX[name], "%s read in the loop" % name)
    # a constant compare that feeds a conditional branch out of the loop or the closing branch
    best = None
    for k, ins in enumerate(inside[:-1]):
        if ins.mnemonic in ("cmp",) and len(ins.operands) == 2 and ins.operands[1].type == CS_OP_IMM:
            nxt = inside[k + 1]
            if nxt.mnemonic.startswith("j") and nxt.mnemonic != "jmp":
                t = nxt.operands[0].imm if nxt.operands and nxt.operands[0].type == CS_OP_IMM else None
                if t is not None and (t < lo or t >= hi or t == lo):
                    best = (ins.operands[1].imm, "%#x: %s %s ; %s" % (ins.address, ins.mnemonic, ins.op_str, nxt.mnemonic))
    if best:
        return ("const", best[0], best[1])
    for a, name in m["rip_reads"]:
        pass
    # a count read before the loop (a loop to a count held in a register)
    pre = [name for a, name in m["rip_reads"] if a < lo]
    if pre:
        return ("count", COUNT_MAX[pre[-1]], "%s read before the loop" % pre[-1])
    return ("unknown", None, "no constant compare or known count in the loop")


def analyse(f, image):
    decode_function(image, f)
    m = model(f)
    f.cookie_code = m["cookie_code"]
    rows = []
    lps = loops(f.insns)
    refs = m["refs"]
    S = m["S"]
    if S is None:
        return [{"verdict": "UNKNOWN", "why": "no `sub rsp, imm` frame allocation found"}]
    cookie_s = f.cookie if f.cookie else None
    if cookie_s is None:
        # the cookie slot from the code: the store right after `xor reg, rsp/rbp`
        ins = f.insns
        for k, i in enumerate(ins[:40]):
            if i.mnemonic == "mov" and i.operands and i.operands[0].type == CS_OP_MEM and k and ins[k - 1].mnemonic == "xor":
                for r in refs:
                    if r["ins"] is i:
                        cookie_s = r["s"]
                        break
                if cookie_s is not None:
                    break
    writes = [r for r in refs if r["write"] and not r["lea"] and (r["index"] or "cursor" in r)]
    seen_arrays = {}
    for w in writes:
        inl = [(lo, hi) for lo, hi in lps if lo <= w["ins"].address < hi]
        if not inl:
            continue
        region = min(inl, key=lambda r: r[1] - r[0])
        stride = w.get("cursor") or w["scale"]
        start0 = w["s"] - w["disp"] if "cursor" in w else w["s"]
        key = (start0, w["base"], region)                  # one row per array and loop (the entry's fields share it)
        if key in seen_arrays:
            continue
        kind, bound, text = loop_bound(f, region, m)
        seen_arrays[key] = (w, region, stride, kind, bound, text)
    for key, (w, region, stride, kind, bound, text) in seen_arrays.items():
        start = w["s"]
        if "cursor" in w:
            start = w["s"] - w["disp"]
        others = sorted({r["s"] for r in refs if r["s"] > start + stride and not r["index"] and "cursor" not in r})
        nxt = others[0] if others else None
        to_cookie = (cookie_s - start) if cookie_s is not None and cookie_s > start else None
        to_next = min(x for x in (nxt, cookie_s) if x is not None and x > start) - start if (nxt or cookie_s) else None
        entries_cookie = -(-to_cookie // stride) if to_cookie is not None and stride else None   # the cursor may start inside the first entry: round up
        entries_next = to_next // stride if to_next is not None and stride else None
        verdict = "UNKNOWN"
        if bound is not None and entries_cookie is not None:
            if bound > entries_cookie:
                verdict = "OVERRUNS ABOVE %d" % entries_cookie
            elif entries_next is not None and bound <= entries_next:
                verdict = "SAFE"
        rows.append({"start_s": start, "stride": stride, "base": w["base"], "write": "%#x %s %s" % (w["ins"].address, w["ins"].mnemonic, w["ins"].op_str),
                     "loop": "%#x..%#x" % region, "bound_kind": kind, "bound": bound, "bound_text": text, "cookie_s": cookie_s,
                     "entries_to_cookie": entries_cookie, "entries_to_next": entries_next, "verdict": verdict})
    if not rows and (m["iter_calls"] or m["rip_reads"]):
        rows.append({"verdict": "UNKNOWN", "why": "calls a sentient iterator / reads a count (%s) but no traced stack array write: "
                     "the array pointer may live in a register that is not tracked or in memory (look at the decompile)" %
                     ", ".join(sorted({n for _, n in m["iter_calls"]} | {n for _, n in m["rip_reads"]}))})
    return rows


def run(image, ranges):
    out = []
    funcs = read_functions(image, ranges)
    stats = {"functions": len(funcs), "gs_handler": 0, "gs_or_cookie_code": 0, "frame_ge_568": 0, "decoded_failed": 0}
    for f in funcs:
        if f.cookie is not None:
            stats["gs_handler"] += 1
        if f.frame < MIN_FRAME:
            continue
        decode_function(image, f)
        m_cookie = any(i.mnemonic == "mov" and any(o.type == CS_OP_MEM and o.mem.base == X86_REG_RIP and
                                                   i.address + i.size + o.mem.disp == SECURITY_COOKIE for o in i.operands) for i in f.insns)
        if f.cookie is None and not m_cookie:
            continue
        stats["gs_or_cookie_code"] += 1
        f.insns = []
        rows = analyse(f, image)
        if f.notes:
            stats["decoded_failed"] += 1
        stats["frame_ge_568"] += 1
        for r in rows:
            r.update({"function": "%#x" % f.begin, "frame": f.frame, "chunks": len(f.chunks), "handler": f.handler is not None and "GS" or "code"})
            if f.notes:
                r["notes"] = f.notes
            out.append(r)
    return out, stats


def function_verdicts(rows):
    """One verdict a function: the worst of its rows (OVERRUNS, then UNKNOWN, then SAFE)."""
    order = {"OVERRUNS": 0, "UNKNOWN": 1, "SAFE": 2}
    out = {}
    for r in rows:
        v = r["verdict"].split(" ABOVE")[0]
        cur = out.get(r["function"])
        if cur is None or order[v] < order[cur[0]]:
            out[r["function"]] = (v, r)
    return out


def needs_eyes(r):
    """An UNKNOWN row whose room is smaller than the largest count that depends on the capacity (147 sentients)."""
    if r["verdict"] != "UNKNOWN":
        return False
    room = r.get("entries_to_next")
    return room is None or room < COUNT_MAX["sentient iterator"]


def markdown(rows, stats):
    verdicts = {}
    for f, (v, _) in function_verdicts(rows).items():
        verdicts[v] = verdicts.get(v, 0) + 1
    row_verdicts = {}
    for r in rows:
        k = r["verdict"].split(" ABOVE")[0]
        row_verdicts[k] = row_verdicts.get(k, 0) + 1
    stats = dict(stats, rows=len(rows), functions_with_rows=len({r["function"] for r in rows}), function_verdicts=verdicts,
                 row_verdicts=row_verdicts, unknown_rows_needing_eyes=sum(1 for r in rows if needs_eyes(r)))
    lines = ["| function | frame | array start S+ | stride | entries to cookie / next object | loop | bound | verdict |", "|---|---|---|---|---|---|---|---|"]
    for r in rows:
        if "start_s" in r:
            lines.append("| %s | %#x | %#x | %d | %s / %s | %s | %s | %s |" % (
                r["function"], r["frame"], r["start_s"], r["stride"], r["entries_to_cookie"], r["entries_to_next"], r["loop"],
                "%s %s: %s" % (r["bound_kind"], r["bound"], r["bound_text"]), r["verdict"]))
        else:
            lines.append("| %s | %#x | | | | | %s | %s |" % (r["function"], r["frame"], r.get("why", ""), r["verdict"]))
    return stats, verdicts, "\n".join(lines)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--range", nargs=2, action="append", metavar=("LO", "HI"))
    ap.add_argument("--image", default=cp.DEFAULT_IMAGE)
    ap.add_argument("--markdown")
    ap.add_argument("--json")
    a = ap.parse_args(argv)
    ranges = [(int(lo, 0), int(hi, 0)) for lo, hi in a.range] if a.range else DEFAULT_RANGES
    image = cp.open_image(a.image)
    rows, stats = run(image, ranges)
    stats, verdicts, table = markdown(rows, stats)
    if a.json:
        json.dump({"stats": stats, "verdicts": verdicts, "rows": rows}, open(a.json, "w"), indent=1)
    if a.markdown:
        open(a.markdown, "w", encoding="utf-8").write(table + "\n")
    print(json.dumps({"stats": stats}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
