"""Rebuild an analysable IW7 image: the shipped PE with its packed sections replaced by unpacked bytes.

The shipped iw7_ship.exe keeps its code protected on disk; the real code exists only in memory once the game
runs. This tool writes a new PE file whose headers, imports and initialised data come from the shipped file and
whose code (and any other section given) comes from section files taken from memory:

  - the reference root of the engine map (unpacked-text.bin, unpacked-rdata.bin, unpacked-pdata.bin), or
  - a live image dump made by ops/engine/live/engine_live.py dump (one file per section, named by address).

The output is machine-local (it is derived from the game) and is never committed.

    python -I build_image.py --exe <iw7_ship.exe> --reference-root <folder> --out <image.exe> [--live-dump <folder>]
"""
import argparse
import hashlib
import json
import os
import struct
import sys

REFERENCE_FILES = {
    0x140001000: "unpacked-text.bin",
    0x141435000: "unpacked-rdata.bin",
    0x14B094000: "unpacked-pdata.bin",
}


def sections(pe):
    off = struct.unpack_from("<I", pe, 0x3C)[0]
    count = struct.unpack_from("<H", pe, off + 6)[0]
    opt = struct.unpack_from("<H", pe, off + 20)[0]
    base = struct.unpack_from("<Q", pe, off + 24 + 24)[0]
    table = off + 24 + opt
    out = []
    for i in range(count):
        name, vsize, va, rsize, roff = struct.unpack_from("<8sIIII", pe, table + 40 * i)
        out.append({"name": name.rstrip(b"\0").decode("ascii", "replace"), "va": base + va, "vsize": vsize,
                    "rsize": rsize, "roff": roff})
    return base, out


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--exe", required=True)
    ap.add_argument("--reference-root")
    ap.add_argument("--live-dump", help="folder of <hexaddress>.bin section files from engine_live.py dump")
    ap.add_argument("--out", required=True)
    ap.add_argument("--keep", default=".idata,.rsrc,.tls",
                    help="sections kept from the shipped file (the import table in memory holds resolved pointers)")
    a = ap.parse_args(argv)
    pe = bytearray(open(a.exe, "rb").read())
    base, secs = sections(pe)
    replaced = []
    sources = {}
    if a.reference_root:
        for va, name in REFERENCE_FILES.items():
            p = os.path.join(a.reference_root, name)
            if os.path.exists(p):
                sources[va] = p
    if a.live_dump:
        for f in os.listdir(a.live_dump):
            if f.endswith(".bin"):
                try:
                    sources[int(f[:-4], 16)] = os.path.join(a.live_dump, f)
                except ValueError:
                    pass
    keep = {k for k in a.keep.split(",") if k}
    for s in secs:
        p = sources.get(s["va"])
        if s["name"] in keep:
            continue
        if not p:
            continue
        data = open(p, "rb").read()
        n = min(len(data), s["rsize"])
        if n == 0:
            continue
        pe[s["roff"]:s["roff"] + n] = data[:n]
        replaced.append({"section": s["name"], "va": hex(s["va"]), "bytes": n, "from": os.path.basename(p),
                         "source_bytes": len(data), "raw_size": s["rsize"]})
    if not replaced:
        print("no section replaced: give --reference-root or --live-dump", file=sys.stderr)
        return 2
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with open(a.out, "wb") as f:
        f.write(pe)
    receipt = {"schema": "iw7.engine-image/1", "exe_sha256": sha256(open(a.exe, "rb").read()),
               "image_sha256": sha256(bytes(pe)), "base": hex(base), "replaced": replaced,
               "sections": [{k: (hex(v) if k == "va" else v) for k, v in s.items()} for s in secs]}
    with open(a.out + ".json", "w") as f:
        json.dump(receipt, f, indent=1)
    for r in replaced:
        print(f"{r['section']:8} {r['va']}  {r['bytes']:>10} bytes from {r['from']}")
    print("image", a.out, receipt["image_sha256"][:16])
    return 0


if __name__ == "__main__":
    sys.exit(main())
