#!/usr/bin/env python3
"""x64 unwind data reader for the analysed image (docs/CAVE-REWRITER.md, "frame grow").

    python -B ops/engine/unwind_info.py 0x1403E61B0 [0x140...]      decode the RUNTIME_FUNCTION and UNWIND_INFO of each function

`find_runtime_function(image, address)` -> RuntimeFunction (with the VA of its 12-byte entry), `read_unwind_info(image, rf)` ->
UnwindInfo: every field with its virtual address and width, so a planner can name the bytes that encode the frame size
and the GS cookie offset. Codes follow the Microsoft x64 exception handling documentation (UWOP_PUSH_NONVOL 0, ALLOC_LARGE 1,
ALLOC_SMALL 2, SET_FPREG 3, SAVE_NONVOL 4, SAVE_NONVOL_FAR 5, SAVE_XMM128 8, SAVE_XMM128_FAR 9, PUSH_MACHFRAME 10).
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cave_plan  # noqa: E402

UWOP_NAMES = {0: "PUSH_NONVOL", 1: "ALLOC_LARGE", 2: "ALLOC_SMALL", 3: "SET_FPREG", 4: "SAVE_NONVOL", 5: "SAVE_NONVOL_FAR",
              8: "SAVE_XMM128", 9: "SAVE_XMM128_FAR", 10: "PUSH_MACHFRAME"}
REGS = ["rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi"] + ["r%d" % i for i in range(8, 16)]
UNW_FLAG_EHANDLER, UNW_FLAG_UHANDLER, UNW_FLAG_CHAININFO = 1, 2, 4


class UnwindError(Exception):
    pass


class RuntimeFunction:
    def __init__(self, entry_va, begin, end, unwind):
        self.entry_va, self.begin_rva, self.end_rva, self.unwind_rva = entry_va, begin, end, unwind


class UnwindCode:
    def __init__(self, va, offset, op, info, slots, value, raw, value_va=None, value_size=0):
        self.va, self.prolog_offset, self.op, self.info, self.slots, self.value, self.raw = va, offset, op, info, slots, value, raw
        self.value_va, self.value_size = value_va, value_size   # where the size/offset operand lives (ALLOC_LARGE, SAVE_*)

    @property
    def name(self):
        return UWOP_NAMES.get(self.op, "UWOP_%d" % self.op)

    def describe(self):
        if self.op == 0:
            return "PUSH_NONVOL %s" % REGS[self.info]
        if self.op == 1:
            return "ALLOC_LARGE %#x" % self.value
        if self.op == 2:
            return "ALLOC_SMALL %#x" % self.value
        if self.op == 3:
            return "SET_FPREG"
        if self.op in (4, 5):
            return "SAVE_NONVOL %s at rsp+%#x" % (REGS[self.info], self.value)
        if self.op in (8, 9):
            return "SAVE_XMM128 xmm%d at rsp+%#x" % (self.info, self.value)
        return self.name


class UnwindInfo:
    def __init__(self):
        self.va = 0
        self.version = self.flags = self.prolog_size = self.count = self.frame_reg = self.frame_offset = 0
        self.codes = []
        self.handler_rva = None
        self.handler_va = None          # VA of the 4-byte handler RVA
        self.handler_data_va = None
        self.handler_data = b""
        self.chain = None               # RuntimeFunction when chained
        self.raw = b""

    def alloc(self):
        """Total bytes allocated by the ALLOC_* codes of the prologue."""
        return sum(c.value for c in self.codes if c.op in (1, 2))


def _pdata(image):
    if getattr(image, "exception_directory", None) is None:
        raise UnwindError("the image has no exception directory")
    return image.exception_directory


def find_runtime_function(image, address):
    va, n = _pdata(image)
    rva = address - image.base
    lo, hi = 0, n - 1
    while lo <= hi:
        mid = (lo + hi) // 2
        b, e, u = struct.unpack("<III", image.read(va + 12 * mid, 12))
        if rva < b:
            hi = mid - 1
        elif rva >= e:
            lo = mid + 1
        else:
            return RuntimeFunction(va + 12 * mid, b, e, u)
    return None


def parse_unwind_info(raw, va, base=0x140000000):
    """UnwindInfo from the bytes of the record (>= header + codes + handler or chain) at virtual address `va`."""
    ui = UnwindInfo()
    ui.va = va
    ui.version, ui.flags = raw[0] & 7, raw[0] >> 3
    ui.prolog_size, ui.count = raw[1], raw[2]
    ui.frame_reg, ui.frame_offset = raw[3] & 15, raw[3] >> 4
    if ui.version not in (1, 2):
        raise UnwindError("unwind version %d" % ui.version)
    i = 0
    while i < ui.count:
        p = 4 + 2 * i
        off, opinfo = raw[p], raw[p + 1]
        op, info = opinfo & 15, opinfo >> 4
        slots, value, vva, vsz = 1, None, None, 0
        if op == 1:
            if info == 0:
                slots, value, vva, vsz = 2, struct.unpack_from("<H", raw, p + 2)[0] * 8, va + p + 2, 2
            elif info == 1:
                slots, value, vva, vsz = 3, struct.unpack_from("<I", raw, p + 2)[0], va + p + 2, 4
            else:
                raise UnwindError("ALLOC_LARGE info %d" % info)
        elif op == 2:
            value = info * 8 + 8
        elif op == 4:
            slots, value, vva, vsz = 2, struct.unpack_from("<H", raw, p + 2)[0] * 8, va + p + 2, 2
        elif op == 5:
            slots, value, vva, vsz = 3, struct.unpack_from("<I", raw, p + 2)[0], va + p + 2, 4
        elif op == 8:
            slots, value, vva, vsz = 2, struct.unpack_from("<H", raw, p + 2)[0] * 16, va + p + 2, 2
        elif op == 9:
            slots, value, vva, vsz = 3, struct.unpack_from("<I", raw, p + 2)[0], va + p + 2, 4
        elif op in (0, 3, 10):
            pass
        else:
            raise UnwindError("unwind op %d not handled" % op)
        ui.codes.append(UnwindCode(va + p, off, op, info, slots, value, bytes(raw[p:p + 2 * slots]), vva, vsz))
        i += slots
    after = 4 + 2 * ((ui.count + 1) & ~1)
    if ui.flags & UNW_FLAG_CHAININFO:
        b, e, u = struct.unpack_from("<III", raw, after)
        ui.chain = RuntimeFunction(va + after, b, e, u)
    elif ui.flags & (UNW_FLAG_EHANDLER | UNW_FLAG_UHANDLER):
        ui.handler_va = va + after
        ui.handler_rva = struct.unpack_from("<I", raw, after)[0]
        ui.handler_data_va = va + after + 4
        ui.handler_data = bytes(raw[after + 4:after + 20])
    ui.raw = bytes(raw)
    return ui


def read_unwind_info(image, rf):
    va = image.base + (rf.unwind_rva & ~1)
    raw = image.read(va, 4)
    if raw is None:
        raise UnwindError("unwind info at %#x is not in the image" % va)
    n = 4 + 2 * ((raw[2] + 1) & ~1) + 24
    raw = image.read(va, n) or image.read(va, n - 20)
    return parse_unwind_info(raw, va, image.base)


def describe(image, address):
    rf = find_runtime_function(image, address)
    if rf is None:
        return ["%#x: no RUNTIME_FUNCTION" % address]
    ui = read_unwind_info(image, rf)
    out = ["function %#x..%#x  RUNTIME_FUNCTION at %#x: %s" % (image.base + rf.begin_rva, image.base + rf.end_rva, rf.entry_va,
                                                              image.read(rf.entry_va, 12).hex()),
           "UNWIND_INFO at %#x: version %d flags %#x prolog_size %#x count %d frame_reg %s frame_offset %#x" % (
               ui.va, ui.version, ui.flags, ui.prolog_size, ui.count, REGS[ui.frame_reg] if ui.frame_reg else "-",
               ui.frame_offset * 16)]
    for c in ui.codes:
        out.append("  code at %#x (%s): prolog offset %#x  %s" % (c.va, c.raw.hex(), c.prolog_offset, c.describe()))
    if ui.handler_va:
        out.append("  handler RVA at %#x = %#x (%#x); handler data at %#x: %s" % (
            ui.handler_va, ui.handler_rva, image.base + ui.handler_rva, ui.handler_data_va, ui.handler_data.hex()))
    if ui.chain:
        out.append("  chained RUNTIME_FUNCTION at %#x: %#x..%#x unwind %#x" % (ui.chain.entry_va, image.base + ui.chain.begin_rva,
                                                                         image.base + ui.chain.end_rva, ui.chain.unwind_rva))
    return out


def main(argv):
    img = cave_plan.open_image(os.environ.get("IW7_IMAGE", cave_plan.DEFAULT_IMAGE))
    for a in argv:
        print("\n".join(describe(img, int(a, 16))))
        print()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
