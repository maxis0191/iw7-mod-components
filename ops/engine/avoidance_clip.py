"""Run the SHIPPED avoidance polygon clip (FUN_1403E6B10) offline, record its outputs, and compare the component's replacement with it (a75).

The shipped function and its helper FUN_1403E6A10 are copied byte for byte (0x1403E6A10..0x1403E6C91, contiguous) from the unpacked code of the reference root into
executable memory of this process; the three references that leave the range (the security cookie, the cookie check, the memcpy of the result) are re-pointed at a few bytes of stubs
in the same block. Nothing of the game runs. Windows x64 only.

  python -B ops/engine/avoidance_clip.py fixture --reference-root <refs> --out tests/fixtures/avoidance_clip_stock.bin [--cases 6000] [--seed 7]
  python -B ops/engine/avoidance_clip.py compare --reference-root <refs> --dll <avoidance-clip-dll> [--cases 2000000] [--seed 11]

`fixture` writes inputs and the shipped function's outputs for the C++ test (tests/native/avoidance_clip_test.cpp reads it; it needs no game file).
`compare` loads a DLL exporting `avoidance_clip_ref(float* poly, int* count, const float* plane)` (the replacement, built from src/native/avoidance_clip.hpp) and checks, for every
generated case, the return value, the count and the output BYTES against the shipped function.
Inputs are kept to what the shipped function can hold: at most 31 convex vertices (a clip adds at most one) or 16 arbitrary ones (a clip emits at most two a vertex).
"""
import argparse
import ctypes
import math
import os
import random
import struct
import sys

TEXT_VA = 0x140001000
START, END = 0x1403E6A10, 0x1403E6C91        # FUN_1403E6A10 .. the end of FUN_1403E6B10 (int3 after the ret)
CLIP = 0x1403E6B10
MEMCPY, COOKIE_CHECK = 0x1412BFE40, 0x1412BA0D0
STOCK_COOKIE_SLOT = 0x1403E6B1F + 7 + 0x17FAA0A   # the rip-relative cookie of the prologue: 0x141BE1530

# push rdi; push rsi; mov rdi, rcx; mov rsi, rdx; mov rcx, r8; rep movsb; pop rsi; pop rdi; ret
MEMCPY_STUB = bytes.fromhex("57564889CF4889D64C89C1F3A45E5FC3")


def load_code(refs):
    text = open(os.path.join(refs, "unpacked-text.bin"), "rb").read()
    return text[START - TEXT_VA:END - TEXT_VA]


class Stock:
    def __init__(self, refs):
        import capstone
        code = bytearray(load_code(refs))
        k = ctypes.windll.kernel32
        k.VirtualAlloc.restype = ctypes.c_void_p
        k.VirtualAlloc.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_ulong, ctypes.c_ulong]
        size = 0x1000 + ((len(code) + 0xFFF) & ~0xFFF)
        self.base = k.VirtualAlloc(None, size, 0x3000, 0x40)
        if not self.base:
            raise OSError("VirtualAlloc failed")
        stubs = self.base
        memcpy_at, ret_at, cookie_at = stubs, stubs + 0x20, stubs + 0x40
        code_at = self.base + 0x1000
        ctypes.memmove(memcpy_at, MEMCPY_STUB, len(MEMCPY_STUB))
        ctypes.memmove(ret_at, b"\xC3", 1)
        ctypes.memmove(cookie_at, struct.pack("<Q", 0x1122334455667788), 8)
        md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
        md.detail = True
        fixed = 0
        for ins in md.disasm(bytes(code), START):
            ops = ins.op_str
            if ins.mnemonic == "call" and ins.operands[0].type == capstone.x86.X86_OP_IMM:
                target = ins.operands[0].imm
                new = None
                if START <= target < END:
                    continue
                if target == MEMCPY:
                    new = memcpy_at
                elif target == COOKIE_CHECK:
                    new = ret_at
                else:
                    raise RuntimeError("unknown call target %#x at %#x" % (target, ins.address))
                disp = new - (code_at + (ins.address - START) + ins.size)
                code[ins.address - START + 1:ins.address - START + 5] = struct.pack("<i", disp)
                fixed += 1
            elif "rip" in ops and ins.mnemonic not in ("lea",):
                # a rip-relative data reference: only the cookie of the prologue is allowed
                target = ins.address + ins.size + ins.disp
                if target != 0x141BE1530:
                    raise RuntimeError("unknown data reference %#x at %#x" % (target, ins.address))
                disp = cookie_at - (code_at + (ins.address - START) + ins.size)
                code[ins.address - START + ins.disp_offset:ins.address - START + ins.disp_offset + 4] = struct.pack("<i", disp)
                fixed += 1
        if fixed != 3:
            raise RuntimeError("expected 3 external references, found %d" % fixed)
        ctypes.memmove(code_at, bytes(code), len(code))
        k.FlushInstructionCache.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t]
        k.FlushInstructionCache(ctypes.c_void_p(-1), ctypes.c_void_p(code_at), len(code))
        proto = ctypes.CFUNCTYPE(ctypes.c_ubyte, ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p)
        self.fn = proto(code_at + (CLIP - START))

    def clip(self, poly, plane):
        """poly: list of (x, y, z) float32 triples (<= 32). -> (returned, new poly or the unchanged one)"""
        n = len(poly)
        buf = (ctypes.c_float * 96)()
        for i, v in enumerate(poly):
            buf[3 * i], buf[3 * i + 1], buf[3 * i + 2] = v
        cnt = ctypes.c_int(n)
        pl = (ctypes.c_float * 4)(*plane)
        r = self.fn(ctypes.addressof(buf), 0x20, ctypes.addressof(cnt), ctypes.addressof(pl))
        return r, bytes(buf)[:12 * cnt.value], cnt.value


def f32(x):
    return struct.unpack("<f", struct.pack("<f", x))[0]


def unit_plane(rng, spread=300.0, flat=True):
    a = rng.uniform(-1, 1)
    b = rng.uniform(-1, 1)
    c = 0.0 if flat else rng.uniform(-1, 1)
    n = math.sqrt(a * a + b * b + c * c) or 1.0
    return (f32(a / n), f32(b / n), f32(c / n), f32(rng.uniform(-spread, spread) * rng.choice((0.02, 0.2, 1.0))))


def box(rng):
    r = rng.choice((299.7, 150.0, 600.0, rng.uniform(5, 400)))
    cx, cy = rng.uniform(-500, 500), rng.uniform(-500, 500)
    z = rng.uniform(-50, 50)
    return [(f32(cx - r), f32(cy - r), f32(z)), (f32(cx + r), f32(cy - r), f32(z)), (f32(cx + r), f32(cy + r), f32(z)), (f32(cx - r), f32(cy + r), f32(z))]


def convex(rng, n):
    cx, cy, z = rng.uniform(-300, 300), rng.uniform(-300, 300), rng.uniform(-20, 20)
    r = rng.uniform(1, 400)
    angles = sorted(rng.uniform(0, 2 * math.pi) for _ in range(n))
    return [(f32(cx + r * math.cos(t)), f32(cy + r * math.sin(t)), f32(z)) for t in angles]


def cases(rng, total):
    """yield (poly, plane) the way the solver uses the function (a box, then clip after clip) and the awkward ones."""
    produced = 0
    while produced < total:
        kind = rng.randrange(10)
        if kind <= 4:                                       # a box and one plane (the first clip of a solver run)
            yield box(rng), unit_plane(rng, flat=rng.random() < 0.9)
            produced += 1
        elif kind <= 6:
            poly = convex(rng, rng.randrange(3, 32))
            yield poly, unit_plane(rng, flat=rng.random() < 0.7)
            produced += 1
        elif kind == 7:                                     # a plane that passes exactly through vertices / equals a vertex's distance
            poly = box(rng) if rng.random() < 0.5 else convex(rng, rng.randrange(3, 20))
            v = rng.choice(poly)
            a, b = rng.choice(((1.0, 0.0), (0.0, 1.0), (0.6, 0.8), (-1.0, 0.0)))
            yield poly, (f32(a), f32(b), 0.0, f32(a * v[0] + b * v[1]))
            produced += 1
        elif kind == 8:                                     # arbitrary (non convex) vertices, few, so that two a vertex still fits
            n = rng.randrange(1, 17)
            poly = [(f32(rng.uniform(-400, 400)), f32(rng.uniform(-400, 400)), f32(rng.uniform(-30, 30))) for _ in range(n)]
            yield poly, unit_plane(rng, flat=rng.random() < 0.5)
            produced += 1
        else:                                               # sizes at the edges, identical planes, nan and inf
            poly = box(rng)
            plane = unit_plane(rng)
            if rng.random() < 0.15:
                plane = (float("nan"), plane[1], plane[2], plane[3])
            elif rng.random() < 0.15:
                plane = (plane[0], plane[1], plane[2], float("inf") * rng.choice((1, -1)))
            yield poly, plane
            produced += 1


def run_cases(stock, rng, total):
    """(poly, plane, returned, out, count) for `total` single clips"""
    for poly, plane in cases(rng, total):
        r, out, n = stock.clip(poly, plane)
        yield poly, plane, r, out, n


def solver_runs(stock, rng, runs):
    """chains: a box, then up to 30 planes, each clip's stock output is the next input (what FUN_1403E61B0 does)."""
    for _ in range(runs):
        poly = box(rng)
        for _ in range(rng.randrange(1, 31)):
            plane = unit_plane(rng, flat=rng.random() < 0.9)
            if len(poly) > 31:
                break
            r, out, n = stock.clip(poly, plane)
            yield poly, plane, r, out, n
            if r:
                poly = [struct.unpack("<3f", out[12 * i:12 * i + 12]) for i in range(n)]


def all_cases(stock, rng, total):
    yield from solver_runs(stock, rng, max(1, total // 12))
    yield from run_cases(stock, rng, total)


def write_fixture(refs, path, total, seed):
    stock = Stock(refs)
    rng = random.Random(seed)
    items = list(all_cases(stock, rng, total))
    with open(path, "wb") as f:
        f.write(b"AVC1" + struct.pack("<I", len(items)))
        for poly, plane, r, out, n in items:
            f.write(struct.pack("<I", len(poly)) + b"".join(struct.pack("<3f", *v) for v in poly) + struct.pack("<4f", *plane))
            f.write(struct.pack("<II", r, n if r else 0) + (out if r else b""))
    return len(items)


def compare(refs, dll_path, total, seed):
    stock = Stock(refs)
    dll = ctypes.CDLL(dll_path)
    dll.avoidance_clip_ref.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
    dll.avoidance_clip_ref.restype = ctypes.c_int
    rng = random.Random(seed)
    bad = n_cases = returned = 0
    for poly, plane, r, out, n in all_cases(stock, rng, total):
        buf = (ctypes.c_float * 96)()
        for i, v in enumerate(poly):
            buf[3 * i], buf[3 * i + 1], buf[3 * i + 2] = v
        cnt = ctypes.c_int(len(poly))
        pl = (ctypes.c_float * 4)(*plane)
        r2 = dll.avoidance_clip_ref(ctypes.addressof(buf), ctypes.addressof(cnt), ctypes.addressof(pl))
        n_cases += 1
        returned += 1 if r else 0
        ok = (bool(r2) == bool(r)) and (not r or (cnt.value == n and bytes(buf)[:12 * n] == out)) and (r or cnt.value == len(poly))
        if not ok:
            bad += 1
            if bad <= 5:
                print("MISMATCH poly=%r plane=%r stock=(%d, %d) new=(%d, %d)" % (poly, plane, r, n, r2, cnt.value))
    print("cases %d (non-empty %d), mismatches %d" % (n_cases, returned, bad))
    return 0 if bad == 0 else 1


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    f = sub.add_parser("fixture")
    f.add_argument("--reference-root", required=True)
    f.add_argument("--out", required=True)
    f.add_argument("--cases", type=int, default=6000)
    f.add_argument("--seed", type=int, default=7)
    c = sub.add_parser("compare")
    c.add_argument("--reference-root", required=True)
    c.add_argument("--dll", required=True)
    c.add_argument("--cases", type=int, default=2000000)
    c.add_argument("--seed", type=int, default=11)
    a = ap.parse_args(argv)
    if a.cmd == "fixture":
        n = write_fixture(a.reference_root, a.out, a.cases, a.seed)
        print("wrote %d cases, %d bytes" % (n, os.path.getsize(a.out)))
        return 0
    return compare(a.reference_root, a.dll, a.cases, a.seed)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
