"""VMMap-like walker: lists a process's virtual memory regions (VirtualQueryEx) and groups the committed bytes.

  python -B ops/memlab/vmmap.py <pid> [--top 30] [--json out.json]

Prints: process counters (private bytes = commit charge, working set, peak), committed bytes by type
(Image / Mapped / Private) and protection, the top committed private regions (a run of adjacent
committed pages with the same allocation base), and committed bytes per owning module for Image regions.
Read-only; needs PROCESS_QUERY_INFORMATION | PROCESS_VM_READ on the target (same user is enough).
"""
import argparse, ctypes, json, sys
from ctypes import wintypes as W

k32 = ctypes.WinDLL("kernel32", use_last_error=True)
psapi = ctypes.WinDLL("psapi", use_last_error=True)

class MBI(ctypes.Structure):
    _fields_ = [("BaseAddress", ctypes.c_void_p), ("AllocationBase", ctypes.c_void_p), ("AllocationProtect", W.DWORD),
                ("PartitionId", W.WORD), ("RegionSize", ctypes.c_size_t), ("State", W.DWORD), ("Protect", W.DWORD), ("Type", W.DWORD)]

class PMC(ctypes.Structure):
    _fields_ = [("cb", W.DWORD), ("PageFaultCount", W.DWORD), ("PeakWorkingSetSize", ctypes.c_size_t), ("WorkingSetSize", ctypes.c_size_t),
                ("QuotaPeakPagedPoolUsage", ctypes.c_size_t), ("QuotaPagedPoolUsage", ctypes.c_size_t),
                ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t), ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
                ("PagefileUsage", ctypes.c_size_t), ("PeakPagefileUsage", ctypes.c_size_t), ("PrivateUsage", ctypes.c_size_t)]

MEM_COMMIT, MEM_RESERVE, MEM_FREE = 0x1000, 0x2000, 0x10000
TYPES = {0x1000000: "Image", 0x40000: "Mapped", 0x20000: "Private"}
PROT = {0x01: "NA", 0x02: "R", 0x04: "RW", 0x08: "WC", 0x10: "X", 0x20: "RX", 0x40: "RWX", 0x80: "XWC"}
GB = 1 << 30; MB = 1 << 20

k32.OpenProcess.restype = W.HANDLE
k32.ReadProcessMemory.argtypes = [W.HANDLE, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)]
k32.VirtualQueryEx.argtypes = [W.HANDLE, ctypes.c_void_p, ctypes.POINTER(MBI), ctypes.c_size_t]
k32.VirtualQueryEx.restype = ctypes.c_size_t
psapi.GetMappedFileNameW.argtypes = [W.HANDLE, ctypes.c_void_p, W.LPWSTR, W.DWORD]
psapi.QueryWorkingSetEx.argtypes = [W.HANDLE, ctypes.c_void_p, W.DWORD]

class WSEX(ctypes.Structure):
    _fields_ = [("VirtualAddress", ctypes.c_void_p), ("Flags", ctypes.c_uint64)]

def resident_pages(h, base, size):
    """Number of pages of [base, base+size) in the working set (QueryWorkingSetEx, bit 0 of Flags = Valid)."""
    total, page, chunk = 0, 4096, 1 << 15
    for off in range(0, size, chunk * page):
        n = min(chunk, (size - off + page - 1) // page)
        arr = (WSEX * n)()
        for i in range(n): arr[i].VirtualAddress = base + off + i * page
        if psapi.QueryWorkingSetEx(h, arr, ctypes.sizeof(arr)):
            total += sum(1 for e in arr if e.Flags & 1)
    return total

def peek(h, addr, n=64):
    buf = ctypes.create_string_buffer(n); got = ctypes.c_size_t(0)
    ok = k32.ReadProcessMemory(h, ctypes.c_void_p(addr), buf, n, ctypes.byref(got))
    return buf.raw[:got.value] if ok else b""

def mapped_name(h, addr):
    buf = ctypes.create_unicode_buffer(520)
    n = psapi.GetMappedFileNameW(h, ctypes.c_void_p(addr), buf, 520)
    return buf.value.rsplit("\\", 1)[-1] if n else ""

def walk(pid):
    h = k32.OpenProcess(0x0410 | 0x1000, False, pid)   # QUERY_INFORMATION | VM_READ | QUERY_LIMITED
    if not h: raise OSError("OpenProcess failed: %d" % ctypes.get_last_error())
    pmc = PMC(); pmc.cb = ctypes.sizeof(pmc)
    psapi.GetProcessMemoryInfo(h, ctypes.byref(pmc), pmc.cb)
    regions, addr, mbi = [], 0, MBI()
    while k32.VirtualQueryEx(h, ctypes.c_void_p(addr), ctypes.byref(mbi), ctypes.sizeof(mbi)):
        base, size = mbi.BaseAddress or 0, mbi.RegionSize
        if mbi.State != MEM_FREE:
            regions.append(dict(base=base, alloc=mbi.AllocationBase or 0, size=size, state=mbi.State, prot=mbi.Protect,
                                type=mbi.Type, name=mapped_name(h, base) if mbi.Type in (0x1000000, 0x40000) else ""))
        addr = base + size
        if addr >= 0x7FFFFFFF0000: break
    return h, pmc, regions

def main():
    ap = argparse.ArgumentParser(); ap.add_argument("pid", type=int); ap.add_argument("--top", type=int, default=30); ap.add_argument("--json"); ap.add_argument("--peek", type=int, default=0, metavar="MB", help="print the first bytes of up to 6 private allocations of this size class (MB, committed)"); ap.add_argument("--resident-all", action="store_true", help="resident vs committed of every private allocation, by size class (slow: 2M pages)"); ap.add_argument("--resident", action="store_true", help="also count the pages of each top allocation that are in the working set (slower)")
    a = ap.parse_args()
    h, pmc, regs = walk(a.pid)
    print("pid %d: private(commit) %.2f GB, PEAK commit %.2f GB, working set %.2f GB, peak ws %.2f GB" %
          (a.pid, pmc.PrivateUsage / GB, pmc.PeakPagefileUsage / GB, pmc.WorkingSetSize / GB, pmc.PeakWorkingSetSize / GB))
    com = [r for r in regs if r["state"] == MEM_COMMIT]
    res = [r for r in regs if r["state"] == MEM_RESERVE]
    print("committed %.2f GB, reserved-only %.2f GB" % (sum(r["size"] for r in com) / GB, sum(r["size"] for r in res) / GB))
    by_type = {}
    for r in com: by_type[TYPES.get(r["type"], "?")] = by_type.get(TYPES.get(r["type"], "?"), 0) + r["size"]
    print("committed by type:", {k: round(v / MB) for k, v in by_type.items()}, "MB")
    # group adjacent committed regions of one allocation
    groups = {}
    for r in com:
        g = groups.setdefault(r["alloc"], dict(alloc=r["alloc"], size=0, type=TYPES.get(r["type"], "?"), prots=set(), name=r["name"], first=r["base"], last=r["base"]))
        g["size"] += r["size"]; g["prots"].add(PROT.get(r["prot"] & 0xFF, hex(r["prot"]))); g["last"] = r["base"] + r["size"]
    top = sorted(groups.values(), key=lambda g: -g["size"])
    print("\ntop %d committed allocations (allocation base, committed MB, type, protections, span MB, mapped file):" % a.top)
    if a.resident:
        for g in top[:a.top]:
            g["res"] = sum(resident_pages(h, r["base"], r["size"]) * 4096 for r in com if r["alloc"] == g["alloc"])
    for g in top[:a.top]:
        print("  %016X %9.1f MB  %-7s %-8s span %9.1f MB  %s%s" % (g["alloc"], g["size"] / MB, g["type"], "/".join(sorted(g["prots"])), (g["last"] - g["first"]) / MB, g["name"], ("  resident %.1f MB" % (g["res"] / MB)) if "res" in g else ""))
    if a.resident_all:
        cls = {}
        by_alloc = {}
        for r in com:
            if r["type"] == 0x20000: by_alloc.setdefault(r["alloc"], []).append(r)
        print("private committed vs resident by allocation size class (MB):")
        for alloc, rs in by_alloc.items():
            size = sum(r["size"] for r in rs); res = sum(resident_pages(h, r["base"], r["size"]) * 4096 for r in rs)
            name = "arena>=1GB-span" if (groups[alloc]["last"] - groups[alloc]["first"]) > (1 << 30) else ("%d MB" % round(size / MB) if size >= 8 * MB else "<8MB")
            c = cls.setdefault(name, [0, 0, 0]); c[0] += 1; c[1] += size; c[2] += res
        for name, (n, size, res) in sorted(cls.items(), key=lambda kv: -kv[1][1])[:14]:
            print("  %-16s x%-4d committed %8.0f MB  resident %8.0f MB  untouched %8.0f MB" % (name, n, size / MB, res / MB, (size - res) / MB))
        print("  TOTAL private committed %.0f MB resident %.0f MB untouched %.0f MB" % (sum(c[1] for c in cls.values()) / MB, sum(c[2] for c in cls.values()) / MB, sum(c[1] - c[2] for c in cls.values()) / MB))
    if a.peek:
        sel = [g for g in top if g["type"] == "Private" and round(g["size"] / MB) == a.peek][:6]
        for g in sel:
            for off in (0, 4096):
                d = peek(h, g["alloc"] + off, 48)
                print("  peek %016X+%d: %s | %s" % (g["alloc"], off, d.hex(" ") if d else "unreadable", "".join(chr(c) if 32 <= c < 127 else "." for c in d)))
    mods = {}
    for g in groups.values():
        if g["type"] == "Image": mods[g["name"] or "?"] = mods.get(g["name"] or "?", 0) + g["size"]
    print("\ncommitted by image:", ", ".join("%s %.0f MB" % (k, v / MB) for k, v in sorted(mods.items(), key=lambda kv: -kv[1])[:8]))
    sizes = {}
    for g in groups.values():
        if g["type"] == "Private":
            b = "<1MB" if g["size"] < MB else "1-16MB" if g["size"] < 16 * MB else "16-256MB" if g["size"] < 256 * MB else ">=256MB"
            sizes[b] = sizes.get(b, 0) + g["size"]
    print("private committed by allocation size:", {k: round(v / MB) for k, v in sizes.items()}, "MB")
    if a.json:
        json.dump(dict(pid=a.pid, private=pmc.PrivateUsage, ws=pmc.WorkingSetSize, groups=[dict(g, prots=sorted(g["prots"])) for g in top]), open(a.json, "w"))

if __name__ == "__main__":
    main()
