#!/usr/bin/env python3
"""Frame grow: give a function more stack room at the TOP of its frame (docs/CAVE-REWRITER.md, "frame grow").

For a function whose overrun array is its highest local (the array ends at the stack-protector cookie), everything BELOW
the array top moves down by X while everything at or above it keeps its place relative to the CALLER:

    sub rsp, F          -> sub rsp, F+X          add rsp, F     -> add rsp, F+X
    lea rbp,[r11-d]     -> lea rbp,[r11-d-X]     (the frame base moves with the locals)
    [rsp/rbp + d]       -> [rsp/rbp + d+X]       for every access at or above the array top (cookie, xmm saves, ...)
    UNWIND_INFO         -> ALLOC_LARGE F+X, SAVE_* offsets at or above the array top +X, GS handler cookie offset +X

    python -B ops/engine/cave_plan.py frame-grow --function 0x1403E61B0 --array-top 0xCC0 --extra 7136 [--max-extra N] -o plan.json
    python -B ops/engine/cave_plan.py --emit-cpp plan.json -o src/native/agent_capacity_frame_fields.inc     (plan JSON of kind frame-grow)

The plan is a list of FIELDS (address, width, stock value, unit, sign): at run time new = stock + sign * X / unit, X chosen at
start (a plan is made for one X and a largest X; the table carries the base values). When the grown frame can pass 0x1000 bytes
the `sub rsp` goes through a cave that first touches one byte in every 0x1000 step below the entry stack pointer, top down
(`test byte [rsp-0x1000*k], 0`, read only; the `sub` that follows overwrites every flag the probes set, so no flag analysis is
needed; no register is used), planned for the largest X.

Refusals (exit 2, nothing written): a displacement or immediate that must change but has an 8-bit field; a dynamic stack
adjustment (`sub rsp, reg`, `lea rsp`, `mov rsp, ..`, `leave`, push/pop in the body, a second `sub rsp`); an epilogue that is not
`add rsp, F`; the address of above-threshold stack memory taken with `lea`; a stack pointer copied into another register (except `add rbp, imm` on a cursor, see CURSOR_STEP); an
indexed stack access; an access that straddles the array top; unwind data in a form not handled (ALLOC_SMALL, an unknown handler,
version 2, chunks whose chain does not end at the primary chunk, a size operand that overflows); a self-check difference.
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
from capstone.x86 import X86_REG_RBP, X86_REG_RIP, X86_REG_RSP  # noqa: E402

GS_HANDLER_CHECK = 0x1412BA038     # __GSHandlerCheck in the shipped image (handler data: one dword, cookie offset | flags)
PAGE = 0x1000
CURSOR_STEP = 0x100               # largest `add rbp, imm` accepted as one array-entry step of a cursor
CURSOR_REACH = 0x40               # largest |displacement| of an rbp access in a function whose rbp is a cursor
SUB_RSP_IMM32 = b"\x48\x81\xec"
ADD_RSP_IMM32 = b"\x48\x81\xc4"

_FAMILY = (("rax", "eax", "ax", "al", "ah"), ("rcx", "ecx", "cx", "cl", "ch"), ("rdx", "edx", "dx", "dl", "dh"),
           ("rbx", "ebx", "bx", "bl", "bh"), ("rsp", "esp", "sp", "spl"), ("rbp", "ebp", "bp", "bpl"),
           ("rsi", "esi", "si", "sil"), ("rdi", "edi", "di", "dil"))
CANON = {n: f[0] for f in _FAMILY for n in f}
for _i in range(8, 16):
    for _s in ("", "d", "w", "b"):
        CANON["r%d%s" % (_i, _s)] = "r%d" % _i
ALIASABLE = ("rax", "r10", "r11")      # volatile registers that may hold a copy of the stack pointer in a prologue


def _fail(msg):
    raise cp.Refusal([msg])


def _reg(ins, rid):
    return CANON.get(ins.reg_name(rid), ins.reg_name(rid))


def _written(ins):
    try:
        return {_reg(ins, r) for r in ins.regs_access()[1]}
    except Exception:
        return set()


def _read(ins):
    try:
        return {_reg(ins, r) for r in ins.regs_access()[0]}
    except Exception:
        return set()


def _text(ins):
    return "%#x: %s %s" % (ins.address, ins.mnemonic, ins.op_str)


# ------------------------------------------------------------------------------------------------ the symbolic walk
class Access:
    """One instruction memory operand (or lea) that addresses the stack."""

    def __init__(self, ins, op, kind, base, c, moving):
        self.ins, self.op, self.kind, self.base, self.c, self.moving = ins, op, kind, base, c, moving
        self.s = None          # offset from S (rsp after the prologue)
        self.delta = 0         # +X, -X or 0: the change of the displacement
        self.frame_base = False


class Walk:
    def __init__(self):
        self.insns = []
        self.accesses = []
        self.pushes = 0
        self.sub = None        # (instruction, frame size)
        self.adds = []         # epilogue `add rsp, F` instructions
        self.S = None          # c-offset of rsp in the body
        self.frame_regs = []   # (instruction, kind) frame-base definitions of rbp
        self.cursor_adds = []  # `add rbp, imm` instructions: rbp is a cursor that walks the array (see walk())


def first_sub(insns):
    """(index, instruction) of the frame allocation: the first `sub rsp, imm`, with only pushes and register moves before it."""
    pushes = 0
    for k, ins in enumerate(insns):
        if ins.mnemonic == "push":
            pushes += 1
            continue
        if ins.mnemonic == "sub" and ins.operands and ins.operands[0].type == CS_OP_REG and _reg(ins, ins.operands[0].reg) == "rsp":
            if ins.operands[1].type != CS_OP_IMM:
                _fail("%s: dynamic stack adjustment (the size is not an immediate: alloca or a probe call)" % _text(ins))
            return k, ins, pushes
        if CS_GRP_CALL in ins.groups or CS_GRP_JUMP in ins.groups or CS_GRP_RET in ins.groups:
            break
    _fail("no `sub rsp, imm` frame allocation in the prologue of %#x" % insns[0].address)


def walk(insns, array_top):
    """Decode the stack behaviour of a function linearly. Raises Refusal on every unsupported form. Returns a Walk whose
    accesses carry c (offset from the entry stack pointer), s (offset from S), whether their base moves with the frame, and
    the change of their displacement."""
    k0, sub, pushes = first_sub(insns)
    if sub.bytes[:3] != SUB_RSP_IMM32:
        _fail("%s: the frame allocation has an 8-bit immediate (cannot hold the larger size; route it through a cave)" % _text(sub))
    F = sub.operands[1].imm
    w = Walk()
    w.insns, w.pushes, w.sub = insns, pushes, (sub, F)
    w.S = -(8 * pushes + F)
    rsp_c, stage, moving_rsp = 0, "pro", False
    alias = {}                  # reg -> (c, moving)
    rbp = None                  # (c, moving) once a frame base is set
    seen_sub = False
    for ins in insns:
        mn, ops = ins.mnemonic, ins.operands
        writes, reads = _written(ins), _read(ins)
        # ---- rsp
        if mn == "push":
            if stage != "pro":
                _fail("%s: push in the body or the epilogue (dynamic stack adjustment)" % _text(ins))
            rsp_c -= 8
        elif mn == "pop":
            if stage != "epi":
                _fail("%s: pop outside an epilogue (dynamic stack adjustment)" % _text(ins))
            rsp_c += 8
        elif mn == "leave":
            _fail("%s: leave (the epilogue restores rsp from rbp)" % _text(ins))
        elif mn in ("sub", "add") and ops and ops[0].type == CS_OP_REG and _reg(ins, ops[0].reg) == "rsp":
            if ops[1].type != CS_OP_IMM:
                _fail("%s: dynamic stack adjustment (the amount is not an immediate)" % _text(ins))
            if mn == "sub":
                if seen_sub or ins is not sub:
                    _fail("%s: a second stack allocation" % _text(ins))
                seen_sub = True
                stage, moving_rsp = "body", True
                rsp_c -= F
            else:
                if stage != "body" or ops[1].imm != F:
                    _fail("%s: epilogue that is not `add rsp, %#x` after the frame allocation" % (_text(ins), F))
                if ins.bytes[:3] != ADD_RSP_IMM32:
                    _fail("%s: the epilogue add has an 8-bit immediate (cannot hold the larger size; route it through a cave)" % _text(ins))
                stage, moving_rsp = "epi", False
                rsp_c += F
                w.adds.append(ins)
        elif "rsp" in writes and not (CS_GRP_CALL in ins.groups or CS_GRP_RET in ins.groups):
            _fail("%s: writes rsp (dynamic stack adjustment)" % _text(ins))
        # ---- rbp (frame base) and the register copies of rsp
        frame_def = None
        if mn == "lea" and ops[0].type == CS_OP_REG and _reg(ins, ops[0].reg) == "rbp":
            m = ops[1].mem
            if m.index:
                _fail("%s: frame base with an index register" % _text(ins))
            b = _reg(ins, m.base) if m.base else None
            if b in alias and stage in ("pro", "body"):
                c, mv = alias[b][0] + m.disp, alias[b][1]
            elif b == "rsp" and stage in ("pro", "body"):
                c, mv = rsp_c + m.disp, moving_rsp
            else:
                _fail("%s: frame base from a register that is not a stack-pointer copy" % _text(ins))
            frame_def = (c, mv)
        elif mn == "mov" and ops[0].type == CS_OP_REG and ops[1].type == CS_OP_REG and _reg(ins, ops[1].reg) in ("rsp", "rbp") \
                and ops[0].size == 8:
            dst, src = _reg(ins, ops[0].reg), _reg(ins, ops[1].reg)
            if dst == "rbp" and src == "rsp" and stage == "body":
                frame_def = (rsp_c, True)
            elif dst in ALIASABLE and src == "rsp" and stage in ("pro", "body"):
                alias[dst] = (rsp_c, moving_rsp)
            elif dst == "rsp":
                pass
            else:
                _fail("%s: copies a stack pointer into %s" % (_text(ins), dst))
        else:
            # a stack pointer read as a plain register operand: only the cookie arithmetic, compares and saves are understood
            adjust = mn in ("sub", "add") and ops[0].type == CS_OP_REG and _reg(ins, ops[0].reg) == "rsp"
            if mn not in ("xor", "cmp", "test", "push", "pop", "lea") and not adjust:
                for o in ops:
                    if o.type == CS_OP_REG and o.access & 1:
                        r = _reg(ins, o.reg)
                        if r == "rbp" and mn == "add" and o is ops[0] and ops[1].type == CS_OP_IMM and 0 < ops[1].imm <= CURSOR_STEP                                 and stage == "body" and rbp not in (None, ("unknown",)):
                            # rbp, taken with `lea rbp,[rsp+d]` below the array top, steps through the array entry by entry (a cursor):
                            # every rbp access is then entry-local and moves with the frame; checked in classify()
                            w.cursor_adds.append(ins)
                        elif r == "rsp" or (r == "rbp" and rbp not in (None, ("unknown",))):
                            _fail("%s: copies a stack pointer into a register or memory" % _text(ins))
        if frame_def is not None:
            if rbp is not None:
                _fail("%s: a second frame base" % _text(ins))
            rbp = (frame_def[0], True)           # after the change the frame base moves with the locals
            w.frame_regs.append((ins, frame_def))
        # ---- other writes invalidate what they overwrite
        for r in writes:
            if r in alias and not (mn == "mov" and ops[0].type == CS_OP_REG and _reg(ins, ops[0].reg) == r and ops[1].type == CS_OP_REG
                                   and _reg(ins, ops[1].reg) == "rsp"):
                del alias[r]
            if r == "rbp" and frame_def is None and not (mn == "pop" and stage == "epi"):
                rbp = ("unknown",)
        # ---- memory operands
        for o in ops:
            if o.type != CS_OP_MEM or o.mem.base == X86_REG_RIP or not o.mem.base:
                continue
            b = _reg(ins, o.mem.base)
            if b == "rsp":
                base_c, mv = rsp_c, moving_rsp
            elif b == "rbp":
                if rbp is None or rbp == ("unknown",):
                    _fail("%s: rbp-based access but rbp is not a known frame base here" % _text(ins))
                base_c, mv = rbp
            elif b in alias:
                base_c, mv = alias[b]
            else:
                continue
            if o.mem.index:
                _fail("%s: indexed stack access" % _text(ins))
            if mn == "lea" and frame_def is not None and ins is w.frame_regs[-1][0]:
                continue                      # the frame base itself: handled as a frame definition
            a = Access(ins, o, "lea" if mn == "lea" else "mem", b, base_c + o.mem.disp, mv)
            w.accesses.append(a)
        # ---- aliases die at calls and branches
        if CS_GRP_CALL in ins.groups or CS_GRP_JUMP in ins.groups or CS_GRP_RET in ins.groups:
            alias.clear()
        if CS_GRP_RET in ins.groups and stage != "epi":
            _fail("%s: a return outside an epilogue (before the frame allocation or without freeing it)" % _text(ins))
        if CS_GRP_RET in ins.groups or (mn == "jmp" and stage == "epi"):
            if stage == "epi":
                if rsp_c != 0:
                    _fail("%s: the stack pointer is not back at the entry value at the return (%+d)" % (_text(ins), rsp_c))
                stage, rsp_c, moving_rsp = "body", w.S, True
    if not w.adds:
        _fail("no epilogue `add rsp, %#x` found" % F)
    for a in w.accesses:
        a.s = a.c - w.S
    return w


def classify(w, array_top, extra_sign=1):
    """Fill in the displacement change of every access; refuse the forms that cannot be changed. -> list of Access with delta != 0."""
    if w.cursor_adds:
        # rbp is a cursor: it must start below the array top and every access through it stays inside one entry
        for ins, (c, mv) in w.frame_regs:
            if c - w.S >= array_top:
                _fail("%s: the cursor register starts at or above the array top (S+%#x)" % (_text(ins), c - w.S))
        for a in w.accesses:
            if a.base == "rbp" and abs(a.op.mem.disp) > CURSOR_REACH:
                _fail("%s: rbp is stepped as a cursor (`%s`) but this access reaches %+d from it (more than one entry)"
                      % (_text(a.ins), _text(w.cursor_adds[0]), a.op.mem.disp))
    changed = []
    for a in w.accesses:
        o = a.op
        size = o.size
        high = a.s >= array_top
        if a.kind == "lea":
            if high:
                _fail("%s: takes the address of stack memory at or above the array top (S+%#x): the pointer would escape" % (_text(a.ins), a.s))
        elif a.s < array_top < a.s + size:
            _fail("%s: the access S+%#x..+%#x straddles the array top S+%#x" % (_text(a.ins), a.s, a.s + size, array_top))
        if a.moving:
            a.delta = 1 if high else 0
        else:
            a.delta = 0 if high else -1
        if a.delta:
            if a.ins.disp_size != 4:
                _fail("%s: the displacement field is %d bytes: it cannot hold the shifted value (route the instruction through a cave)"
                      % (_text(a.ins), a.ins.disp_size))
            changed.append(a)
    # the frame base moves with the locals: a definition from a non-moving base needs -X, from the moving rsp nothing
    for ins, (c, mv) in w.frame_regs:
        if ins.mnemonic == "lea" and not mv:
            if ins.disp_size != 4:
                _fail("%s: the frame base displacement field is %d bytes (route it through a cave)" % (_text(ins), ins.disp_size))
    return changed


# ------------------------------------------------------------------------------------------------ unwind data
def function_chunks(image, start, end):
    """RUNTIME_FUNCTION chunks covering [start, end): [(RuntimeFunction, UnwindInfo)]; every non-primary chunk must chain to the primary."""
    out, pos = [], start
    while pos < end:
        rf = uw.find_runtime_function(image, pos)
        if rf is None:
            _fail("no RUNTIME_FUNCTION covers %#x (the function has no unwind data there)" % pos)
        if image.base + rf.begin_rva != pos:
            _fail("RUNTIME_FUNCTION chunk at %#x does not begin at %#x" % (image.base + rf.begin_rva, pos))
        try:
            ui = uw.read_unwind_info(image, rf)
        except uw.UnwindError as e:
            _fail("unwind data of %#x: %s" % (pos, e))
        out.append((rf, ui))
        pos = image.base + rf.end_rva
    if pos != end:
        _fail("the unwind chunks end at %#x, the function at %#x" % (pos, end))
    primary = out[0]
    begins = {r.begin_rva for r, _ in out}          # a chunk may chain to any chunk of the function (chains of chains), ending at the primary
    if primary[1].flags & uw.UNW_FLAG_CHAININFO:
        _fail("the first chunk is itself chained (the function is a continuation)")
    by_begin = {r.begin_rva: u for r, u in out}
    for rf, ui in out[1:]:
        if ui.flags & uw.UNW_FLAG_CHAININFO:
            if ui.chain is None or ui.chain.begin_rva not in begins:
                _fail("chunk %#x chains to something that is not a chunk of this function" % (image.base + rf.begin_rva))
            cur, steps = ui, 0                       # the chain must end at the primary chunk (no cycle, no other end)
            while cur.va != primary[1].va and steps <= len(out):
                nxt = by_begin.get(cur.chain.begin_rva) if (cur.flags & uw.UNW_FLAG_CHAININFO and cur.chain) else None
                if nxt is None:
                    break
                cur, steps = nxt, steps + 1
            if cur.va != primary[1].va:
                _fail("chunk %#x chains to something other than the primary chunk (its chain does not end there)" % (image.base + rf.begin_rva))
        elif rf.unwind_rva != primary[0].unwind_rva:
            _fail("chunk %#x has its own unwind info that is neither chained nor the primary one" % (image.base + rf.begin_rva))
    return out


def unwind_fields(image, chunks, F, array_top, prolog_end, extra, max_extra, gs_handlers, cookie_slots):
    """The unwind fields that must change: [(address, width, stock, unit, role, text)]."""
    fields, seen = [], set()
    alloc_seen = False
    for k, (rf, ui) in enumerate(chunks):
        if ui.va in seen:
            continue
        seen.add(ui.va)
        if ui.version != 1:
            _fail("unwind info %#x has version %d (only version 1 is handled)" % (ui.va, ui.version))
        for c in ui.codes:
            if c.op == 2:
                _fail("unwind info %#x: ALLOC_SMALL (the new size would not fit its encoding)" % c.va)
            if c.op == 1:
                if c.value != F:
                    _fail("unwind info %#x: ALLOC_LARGE %#x differs from the frame size %#x of the code" % (c.va, c.value, F))
                if c.prolog_offset != prolog_end:
                    _fail("unwind info %#x: ALLOC_LARGE is at prolog offset %#x, the code's `sub rsp` ends at %#x" % (c.va, c.prolog_offset, prolog_end))
                alloc_seen = True
                unit = 8 if c.value_size == 2 else 1
                top = (F + max_extra) // unit
                if c.value_size == 2 and top > 0xFFFF:
                    _fail("unwind info %#x: the size operand cannot hold %#x (16 bits of 8-byte units)" % (c.va, F + max_extra))
                fields.append((c.value_va, c.value_size, c.value // unit, unit, "unwind-alloc", "ALLOC_LARGE %#x" % c.value))
            elif c.op in (4, 5, 8, 9):
                if c.value >= array_top:
                    unit = {4: 8, 5: 1, 8: 16, 9: 1}[c.op]
                    if extra % unit or max_extra % unit:
                        _fail("unwind info %#x: X must be a multiple of %d" % (c.va, unit))
                    if c.value_size == 2 and (c.value + max_extra) // unit > 0xFFFF:
                        _fail("unwind info %#x: the offset operand cannot hold %#x" % (c.va, c.value + max_extra))
                    fields.append((c.value_va, c.value_size, c.value // unit, unit, "unwind-save", c.describe()))
            elif c.op == 3:
                pass
            elif c.op == 10:
                _fail("unwind info %#x: PUSH_MACHFRAME" % c.va)
        if ui.handler_va:
            if image.base + ui.handler_rva not in gs_handlers:
                _fail("unwind info %#x: exception handler %#x is not a known GS handler (handlers not handled)" % (ui.va, image.base + ui.handler_rva))
            data = struct.unpack("<I", ui.handler_data[:4])[0]
            if data & 7:
                _fail("unwind info %#x: GS handler data has flag bits %#x (alignment or exception forms are not handled)" % (ui.va, data & 7))
            cookie = data & ~7
            if cookie not in cookie_slots:
                _fail("unwind info %#x: the GS cookie offset %#x is not accessed by the code (accessed: %s)"
                      % (ui.va, cookie, ", ".join("%#x" % x for x in sorted(cookie_slots)) or "nothing at or above the array top"))
            if cookie < array_top:
                _fail("unwind info %#x: the GS cookie offset %#x lies below the array top %#x" % (ui.va, cookie, array_top))
            if extra % 16 or max_extra % 16:
                _fail("X must be a multiple of 16")
            fields.append((ui.handler_data_va, 4, data, 1, "unwind-gs-cookie", "GS handler cookie offset %#x" % cookie))
    if not alloc_seen:
        _fail("the unwind data has no ALLOC_LARGE for the frame")
    return fields


# ------------------------------------------------------------------------------------------------ planning
def _signed(v, width):
    v &= (1 << (8 * width)) - 1
    return v - (1 << (8 * width)) if v >> (8 * width - 1) else v


def plan_frame_grow(image, function, array_top, extra, max_extra=None, end=None, db=None, gs_handlers=(GS_HANDLER_CHECK,)):
    """The frame-grow plan (a dict) for the function at `function`, or raises cave_plan.Refusal."""
    max_extra = extra if max_extra is None else max_extra
    if extra <= 0 or extra % 16:
        _fail("--extra must be a positive multiple of 16 (movaps alignment), got %d" % extra)
    if max_extra < extra or max_extra % 16:
        _fail("--max-extra must be a multiple of 16 and at least --extra")
    if array_top <= 0 or array_top % 8:
        _fail("--array-top must be a positive multiple of 8")
    rf = uw.find_runtime_function(image, function)
    if rf is None or image.base + rf.begin_rva != function:
        _fail("%#x is not the start of a function with unwind data" % function)
    if end is None:
        # the primary chunk, then the chunks that chain to it, as far as they are contiguous
        pos, end = function, image.base + rf.end_rva
        members = {rf.begin_rva}      # chunks that chain (possibly through other chunks) to the primary
        while True:
            nxt = uw.find_runtime_function(image, end)
            if nxt is None or image.base + nxt.begin_rva != end:
                break
            ui = uw.read_unwind_info(image, nxt)
            if not (ui.flags & uw.UNW_FLAG_CHAININFO) or ui.chain.begin_rva not in members:
                break
            members.add(nxt.begin_rva)
            end = image.base + nxt.end_rva
    raw = image.read(function, end - function)
    if raw is None:
        _fail("the function %#x..%#x is not in the image" % (function, end))
    insns = cp.decode(raw, function)
    w = walk(insns, array_top)
    sub, F = w.sub
    changed = classify(w, array_top)
    S = w.S
    cookie_slots = {a.s for a in w.accesses if a.s >= array_top}
    chunks = function_chunks(image, function, end)
    prolog_end = sub.address + sub.size - function
    fields = []

    def add(address, width, stock, unit, sign, role, ins, text):
        fields.append({"address": "%#x" % address, "width": width, "stock": stock & ((1 << (8 * width)) - 1), "unit": unit,
                       "sign": sign, "role": role, "instruction": "%#x" % ins if ins else None, "text": text})

    for a in changed:
        disp = a.op.mem.disp
        add(a.ins.address + a.ins.disp_offset, 4, disp, 1, a.delta, "access-high" if a.delta > 0 else "access-low", a.ins.address, _text(a.ins)[len("%#x: " % a.ins.address):])
    for ins, (c, mv) in w.frame_regs:
        if ins.mnemonic == "lea" and not mv:
            add(ins.address + ins.disp_offset, 4, ins.operands[1].mem.disp, 1, -1, "frame-base", ins.address, _text(ins)[len("%#x: " % ins.address):])
    for ins in w.adds:
        add(ins.address + 3, 4, F, 1, 1, "epilogue-add", ins.address, "add rsp, %#x" % F)
    cave = None
    if F + max_extra >= PAGE:
        cave = _plan_probe_cave(image, db, sub, F, max_extra)
    else:
        add(sub.address + 3, 4, F, 1, 1, "frame-sub", sub.address, "sub rsp, %#x" % F)
    for (address, width, stock, unit, role, text) in unwind_fields(
            image, chunks, F, array_top, prolog_end, extra, max_extra, set(gs_handlers), cookie_slots):
        fields.append({"address": "%#x" % address, "width": width, "stock": stock, "unit": unit, "sign": 1, "role": role,
                       "instruction": None, "text": text})
    fields.sort(key=lambda f: int(f["address"], 0))
    doc = {"version": 1, "kind": "frame-grow", "image": os.path.basename(getattr(image, "path", "<memory>")),
           "function": "%#x" % function, "end": "%#x" % end, "array_top": array_top, "extra": extra, "max_extra": max_extra,
           "frame": {"pushes": w.pushes, "stock_size": F, "sub_address": "%#x" % sub.address, "S_from_entry": S},
           "fields": fields, "cave": cave,
           "unwind_chunks": [{"begin": "%#x" % (image.base + r.begin_rva), "end": "%#x" % (image.base + r.end_rva),
                              "entry": "%#x" % r.entry_va, "unwind": "%#x" % u.va} for r, u in chunks]}
    self_check(image, doc, gs_handlers)
    return doc


def _plan_probe_cave(image, db, sub, F, max_extra):
    n = (F + max_extra + PAGE - 1) // PAGE
    probes = b"".join(b"\xf6\x84\x24" + struct.pack("<i", -PAGE * k) + b"\x00" for k in range(1, n + 1))
    new = probes + SUB_RSP_IMM32 + struct.pack("<I", F + max_extra)
    (entry,) = cp.plan([{"address": sub.address, "kind": "bytes", "new_bytes": new.hex()}], image, db)
    if int(entry["window_start"], 0) != sub.address or entry["window_len"] != sub.size or entry["fixups"] or entry["retargets"]:
        _fail("the cave for the `sub rsp` at %#x needed a window other than the instruction itself (%s+%d): refused"
              % (sub.address, entry["window_start"], entry["window_len"]))
    if bytes.fromhex(entry["cave_bytes"]) != new:
        _fail("internal: the cave bytes differ from the probe sequence")
    return {"window_start": entry["window_start"], "window_len": entry["window_len"], "old_bytes": entry["old_bytes"],
            "cave_bytes": entry["cave_bytes"], "probes": n, "imm_offset": len(probes) + 3, "stock_frame": F,
            "max_extra": max_extra, "page": PAGE}


# ------------------------------------------------------------------------------------------------ applying a plan, checking it
def field_value(f, extra):
    """The new value of a field for a given X (what the run time writes)."""
    width = f["width"]
    unit = f["unit"]
    if extra % unit:
        raise cp.Refusal(["X=%d is not a multiple of the unit %d of the field at %s" % (extra, unit, f["address"])])
    new = f["stock"] + f["sign"] * (extra // unit)
    if f["role"].startswith("unwind") and (new < 0 or new >= 1 << (8 * width)):
        raise cp.Refusal(["the field at %s cannot hold %#x" % (f["address"], new)])
    return new & ((1 << (8 * width)) - 1)


def apply_plan(image, plan, extra):
    """-> (function bytes after, {address: patched bytes}) for X = extra: the same arithmetic as the run time."""
    start, end = int(plan["function"], 0), int(plan["end"], 0)
    code = bytearray(image.read(start, end - start))
    patches = {}
    for f in plan["fields"]:
        a, w = int(f["address"], 0), f["width"]
        val = field_value(f, extra).to_bytes(w, "little")
        if start <= a < end:
            code[a - start:a - start + w] = val
        else:
            patches[a] = val
    cave = plan.get("cave")
    cave_bytes = None
    if cave:
        cave_bytes = bytearray.fromhex(cave["cave_bytes"])
        cave_bytes[cave["imm_offset"]:cave["imm_offset"] + 4] = struct.pack("<I", cave["stock_frame"] + extra)
        cave_bytes = bytes(cave_bytes)
    return bytes(code), patches, cave_bytes


class _Overlay:
    """The image with a few patched byte ranges: lets the unwind reader decode the 'after' unwind data."""

    def __init__(self, image, patches):
        self.base, self.path = image.base, getattr(image, "path", "<memory>")
        self.exception_directory = image.exception_directory
        self.image, self.patches = image, patches

    def read(self, address, n):
        raw = bytearray(self.image.read(address, n) or b"")
        if len(raw) != n:
            return None
        for a, v in self.patches.items():
            for i in range(len(v)):
                if address <= a + i < address + n:
                    raw[a + i - address] = v[i]
        return bytes(raw)


def _decoded(code, start):
    return cp.decode(code, start)


def self_check(image, plan, gs_handlers=(GS_HANDLER_CHECK,), extras=None):
    """Apply the plan to a copy of the function for X = extra, max_extra and 16 and compare with the original: every instruction
    identical except the listed fields; every stack access at or above the array top at the same offset from the CALLER's stack
    pointer, every one below at that offset minus X; the unwind data decodes to the same records with the new sizes."""
    start, end = int(plan["function"], 0), int(plan["end"], 0)
    top = plan["array_top"]
    before = _decoded(image.read(start, end - start), start)
    wb = walk(before, top)
    classify(wb, top)
    F = wb.sub[1]
    listed = {int(f["address"], 0): f for f in plan["fields"]}
    errs = []
    for extra in sorted(set(extras or (plan["extra"], plan["max_extra"], 16))):
        code, patches, cave = apply_plan(image, plan, extra)
        after = _decoded(code, start)
        if len(after) != len(before):
            errs.append("X=%d: instruction count differs" % extra)
            continue
        touched = set()
        for b, a in zip(before, after):
            if b.bytes == a.bytes:
                continue
            diff = [i for i in range(b.size) if b.bytes[i] != a.bytes[i]]
            fields = [f for f in listed if b.address <= f < b.address + b.size]
            if a.size != b.size or a.mnemonic != b.mnemonic or not fields or any(b.address + i not in range(min(fields), max(fields) + 4) for i in diff):
                errs.append("X=%d: %#x changed beyond its listed fields: %s -> %s" % (extra, b.address, b.bytes.hex(), a.bytes.hex()))
            touched.update(fields)
        stray = [hex(f) for f in listed if start <= f < end and f not in touched and field_value(listed[f], extra) != listed[f]["stock"]]
        if stray:
            errs.append("X=%d: listed fields without a changed instruction: %s" % (extra, ", ".join(stray)))
        if plan.get("cave"):
            # the sub rsp is in the cave: the in-place copy keeps the stock bytes there; the cave holds the new size
            cb = cp.decode(cave, int(plan["cave"]["window_start"], 0))
            if cb[-1].mnemonic != "sub" or cb[-1].operands[1].imm != F + extra:
                errs.append("X=%d: the cave's sub rsp is %s %s, expected sub rsp, %#x" % (extra, cb[-1].mnemonic, cb[-1].op_str, F + extra))
            code2 = bytearray(code)
            sa = int(plan["frame"]["sub_address"], 0) - start
            code2[sa:sa + 7] = SUB_RSP_IMM32 + struct.pack("<I", F + extra)
            after = _decoded(bytes(code2), start)
            probes = cb[:-1]
            if len(probes) != plan["cave"]["probes"] or any(
                    p.mnemonic != "test" or p.operands[0].mem.base != X86_REG_RSP or p.operands[0].mem.disp != -PAGE * (k + 1)
                    or p.operands[1].imm != 0 for k, p in enumerate(probes)):
                errs.append("X=%d: the probe sequence is not `test byte [rsp-0x1000*k], 0`" % extra)
            if extra > plan["max_extra"]:
                errs.append("X=%d is above the largest X (%d) the probe cave was planned for" % (extra, plan["max_extra"]))
            if PAGE * len(probes) < F + extra:
                errs.append("X=%d: the probes stop at %#x, the frame is %#x" % (extra, PAGE * len(probes), F + extra))
        # the same walk on the new code: every access keeps its place relative to the caller (high) or moves down by X (low)
        try:
            wa = walk(after, top)
        except cp.Refusal as e:
            errs.append("X=%d: the patched function is not a coherent frame: %s" % (extra, "; ".join(e.reasons)))
            continue
        if wa.sub[1] != F + extra:
            errs.append("X=%d: the new frame is %#x, expected %#x" % (extra, wa.sub[1], F + extra))
        pa = {}
        for a in wa.accesses:
            pa.setdefault(a.ins.address, []).append(a)
        for a in wb.accesses:
            got = pa.get(a.ins.address, [])
            if not got:
                errs.append("X=%d: %#x lost its stack access" % (extra, a.ins.address))
                continue
            n = got.pop(0)
            want = a.c if a.s >= top else a.c - extra
            if n.c != want:
                errs.append("X=%d: %#x: caller offset %+#x, expected %+#x (%s)" % (extra, a.ins.address, n.c, want,
                                                                                     "at or above the array top" if a.s >= top else "below the array top"))
        # the unwind data
        ov = _Overlay(image, patches)
        ub = uw.read_unwind_info(image, uw.find_runtime_function(image, start))
        ua = uw.read_unwind_info(ov, uw.find_runtime_function(ov, start))
        if ua.alloc() != ub.alloc() + extra:
            errs.append("X=%d: the unwind ALLOC_LARGE is %#x, expected %#x" % (extra, ua.alloc(), ub.alloc() + extra))
        for rfb, rfa in zip(function_chunks(image, start, end), function_chunks(ov, start, end)):
            for cb_, ca_ in zip(rfb[1].codes, rfa[1].codes):
                exp = None if cb_.value is None else cb_.value + (extra if (cb_.op in (4, 5, 8, 9) and cb_.value >= top) or cb_.op == 1 else 0)
                if (cb_.op, cb_.info, cb_.prolog_offset) != (ca_.op, ca_.info, ca_.prolog_offset) or ca_.value != exp:
                    errs.append("X=%d: unwind code at %#x: %s -> %s, expected value %#x" % (extra, cb_.va, cb_.describe(), ca_.describe(), exp))
            if rfb[1].handler_va and rfa[1].handler_va:
                db_ = struct.unpack("<I", rfb[1].handler_data[:4])[0]
                da_ = struct.unpack("<I", rfa[1].handler_data[:4])[0]
                if da_ != db_ + extra:
                    errs.append("X=%d: GS cookie offset %#x -> %#x, expected %#x" % (extra, db_, da_, db_ + extra))
    if errs:
        raise cp.Refusal(["self-check: " + e for e in errs])


def emit_cpp(plan, source_name):
    """C++ initialisers for src/native/agent_capacity_frame_fields.inc (one line per field) and the probe cave line."""
    lines = ["// Generated by ops/engine/cave_plan.py --emit-cpp from %s; do not edit." % source_name,
             "// Frame grow of %s: {address, width, stock value, unit, sign, code}: new = stock + sign * X / unit (X = the extra frame bytes)." % plan["function"]]
    for f in plan["fields"]:
        code = "false" if f["role"].startswith("unwind") else "true"
        lines.append("{%#xull, %d, %#xu, %d, %d, %s}," % (int(f["address"], 0), f["width"], f["stock"], f["unit"], f["sign"], code))
    return "\n".join(lines) + "\n"


def emit_cave_cpp(plan, source_name):
    c = plan.get("cave")
    head = ["// Generated by ops/engine/cave_plan.py --emit-cpp from %s; do not edit." % source_name,
            "// Frame grow probe cave of %s: window start, stock window bytes, cave bytes planned for X = max_extra, offset of the" % plan["function"],
            "// sub rsp immediate in the cave, stock frame size, max_extra, page probes."]
    if not c:
        return "\n".join(head) + "\n"

    def arr(h):
        return "{" + ",".join("0x%02x" % b for b in bytes.fromhex(h)) + "}"
    head.append("{%#xull, %s, %s, %d, %#xu, %#xu, %d}," % (int(c["window_start"], 0), arr(c["old_bytes"]), arr(c["cave_bytes"]),
                                                          c["imm_offset"], c["stock_frame"], c["max_extra"], c["probes"]))
    return "\n".join(head) + "\n"


def main(argv):
    ap = argparse.ArgumentParser(prog="cave_plan.py frame-grow", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--function", required=True, help="start address of the function")
    ap.add_argument("--array-top", required=True, help="offset from rsp after the prologue where the grown region ends (the cookie)")
    ap.add_argument("--extra", required=True, help="X: bytes the frame grows (multiple of 16)")
    ap.add_argument("--max-extra", help="the largest X the run time may use (default: --extra); the probe cave is planned for it")
    ap.add_argument("--end", help="end address of the function (default: from the unwind chunks)")
    ap.add_argument("-o", "--output")
    ap.add_argument("--image", default=cp.DEFAULT_IMAGE)
    ap.add_argument("--db", default=cp.DEFAULT_DB)
    ap.add_argument("--gs-handler", action="append", help="address of a GS handler routine whose data is one dword (default 0x1412BA038)")
    a = ap.parse_args(argv)
    try:
        image = cp.open_image(a.image)
        db = cp.EngineDb(a.db) if os.path.exists(a.db) else None
        handlers = tuple(int(h, 0) for h in a.gs_handler) if a.gs_handler else (GS_HANDLER_CHECK,)
        plan = plan_frame_grow(image, int(a.function, 0), int(a.array_top, 0), int(a.extra, 0),
                               int(a.max_extra, 0) if a.max_extra else None, int(a.end, 0) if a.end else None, db, handlers)
    except (OSError, ValueError, uw.UnwindError) as e:
        print("cannot plan: %s" % e, file=sys.stderr)
        return 2
    except cp.Refusal as e:
        print("REFUSED:", file=sys.stderr)
        for r in e.reasons:
            print(" ", r, file=sys.stderr)
        return 2
    text = json.dumps(plan, indent=1) + "\n"
    if a.output:
        with open(a.output, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
    else:
        sys.stdout.write(text)
    n = len(plan["fields"])
    print("frame grow %s: %d fields, cave %s, frame %#x -> %#x (X=%d, max %d)" % (
        plan["function"], n, "yes (%d probes)" % plan["cave"]["probes"] if plan["cave"] else "no", plan["frame"]["stock_size"],
        plan["frame"]["stock_size"] + plan["extra"], plan["extra"], plan["max_extra"]), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
