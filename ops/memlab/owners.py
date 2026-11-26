"""Who holds a pointer to each big committed private block? (attribution without call sites)

  python -B ops/memlab/owners.py <pid> [--min-mb 8] [--max 200] [--json out.json]

Walks the process, takes every private allocation of at least --min-mb, and scans the committed pages of the main
image (iw7_ship.exe: globals, .data/.bss) and of every other image for 8-byte values that point inside the block.
Prints, per block: size, how much of it is resident, and the engine globals that point at it (address; resolve the
name with `python -B ops/engine/engine.py at <address>`). A block no global points at is held by another heap
object (the engine's 2.4 GB arena) or is a dlmalloc segment.
"""
import argparse, collections, ctypes, json, sys
import numpy as np
sys.path.insert(0, __file__.rsplit("\\", 1)[0] if "\\" in __file__ else ".")
import vmmap

def main():
    ap = argparse.ArgumentParser(); ap.add_argument("pid", type=int); ap.add_argument("--min-mb", type=int, default=8)
    ap.add_argument("--max", type=int, default=200); ap.add_argument("--json")
    a = ap.parse_args()
    h, pmc, regs = vmmap.walk(a.pid)
    com = [r for r in regs if r["state"] == vmmap.MEM_COMMIT]
    blocks = collections.defaultdict(lambda: dict(size=0, lo=1 << 62, hi=0))
    for r in com:
        if r["type"] == 0x20000:
            b = blocks[r["alloc"]]; b["size"] += r["size"]; b["lo"] = min(b["lo"], r["base"]); b["hi"] = max(b["hi"], r["base"] + r["size"])
    big = sorted([(al, b) for al, b in blocks.items() if b["size"] >= a.min_mb << 20 and b["hi"] - b["lo"] < (1 << 30)], key=lambda kv: kv[0])[:a.max]
    starts = np.array([al for al, _ in big], dtype=np.uint64); ends = np.array([b["hi"] for _, b in big], dtype=np.uint64)
    holders = collections.defaultdict(list)
    scanned = 0
    for r in com:
        if r["type"] != 0x1000000 or not (r["prot"] & 0xCC): continue   # image pages that are writable
        n = r["size"] & ~7
        buf = ctypes.create_string_buffer(n); got = ctypes.c_size_t(0)
        if not vmmap.k32.ReadProcessMemory(h, ctypes.c_void_p(r["base"]), buf, n, ctypes.byref(got)) or got.value < 8: continue
        vals = np.frombuffer(buf.raw[:got.value & ~7], dtype=np.uint64); scanned += len(vals) * 8
        idx = np.searchsorted(starts, vals, side="right") - 1
        ok = (idx >= 0) & (vals >= starts[np.clip(idx, 0, len(starts) - 1)]) & (vals < ends[np.clip(idx, 0, len(starts) - 1)])
        for pos in np.nonzero(ok)[0]:
            holders[int(starts[idx[pos]])].append((r["base"] + int(pos) * 8, int(vals[pos])))
    print("pid %d: scanned %.0f MB of writable image pages, %d blocks >= %d MB" % (a.pid, scanned / 2**20, len(big), a.min_mb))
    out = []
    for al, b in big:
        res = sum(vmmap.resident_pages(h, r["base"], r["size"]) * 4096 for r in com if r["alloc"] == al)
        hs = holders.get(al, [])
        print("  block %012X %6.1f MB committed, %6.1f MB resident: %s" % (al, b["size"] / 2**20, res / 2**20, ", ".join("%X->+%X" % (w, v - al) for w, v in hs[:4]) or "no image global points here"))
        out.append(dict(block=al, mb=b["size"] / 2**20, resident_mb=res / 2**20, holders=[dict(at=w, to=v) for w, v in hs]))
    if a.json: json.dump(out, open(a.json, "w"))

if __name__ == "__main__":
    main()
