"""Write the sections of iw7_ship.exe as they were in memory, from a full-memory minidump of a game process.

The packed sections of the shipped executable (code, the protector's code, encrypted data) are only readable in
a running game. A full-memory dump (for example the one the crash handler writes with -paris-fulldump, or a dump
of our own lab server made by `engine_live.py dump`) holds them. This tool writes one file per section,
`<hex address>.bin`, the input of `build_image.py --live-dump`. Pages absent from the dump are written as zero
and counted. Output is machine-local (derived from the game) and never committed.

    python -I sections_from_dump.py --dump <file.dmp> --out <folder> [--module iw7_ship.exe] [--exe <iw7_ship.exe>]
"""
import argparse
import json
import os
import struct
import sys

from minidump.minidumpfile import MinidumpFile


def pe_sections(read, base):
    hdr = read(base, 0x1000)
    off = struct.unpack_from("<I", hdr, 0x3C)[0]
    count = struct.unpack_from("<H", hdr, off + 6)[0]
    opt = struct.unpack_from("<H", hdr, off + 20)[0]
    out = []
    for i in range(count):
        name, vsize, va, rsize, roff = struct.unpack_from("<8sIIII", hdr, off + 24 + opt + 40 * i)
        out.append((name.rstrip(b"\0").decode("ascii", "replace"), base + va, vsize, rsize))
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--dump", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--module", default="iw7_ship.exe")
    ap.add_argument("--max-bytes", type=lambda s: int(s, 0), default=0x8000000,
                    help="largest section written (the .data section is 160 MB of mostly zero; default 128 MiB)")
    a = ap.parse_args(argv)
    md = MinidumpFile.parse(a.dump)
    reader = md.get_reader()
    mod = None
    for m in md.modules.modules:
        if os.path.basename(m.name).lower() == a.module.lower():
            mod = m
    if not mod:
        print("module not in dump:", a.module, file=sys.stderr)
        return 2
    base = mod.baseaddress

    def read(addr, n):
        return reader.read(addr, n)

    os.makedirs(a.out, exist_ok=True)
    receipt = {"schema": "iw7.engine-dump-sections/1", "dump": os.path.abspath(a.dump), "module": mod.name,
               "base": hex(base), "size": mod.size, "timestamp": mod.timestamp, "sections": []}
    page = 0x1000
    for name, va, vsize, rsize in pe_sections(read, base):
        size = min(max(vsize, rsize), a.max_bytes)
        size = (size + page - 1) // page * page
        buf = bytearray(size)
        missing = 0
        for o in range(0, size, page):
            try:
                buf[o:o + page] = read(va + o, page)
            except Exception:
                missing += 1
        with open(os.path.join(a.out, f"{va:X}.bin"), "wb") as f:
            f.write(buf)
        receipt["sections"].append({"name": name, "va": hex(va), "bytes": size, "missing_pages": missing})
        print(f"{name:8} {va:X} {size:>10} bytes, {missing} missing pages")
    with open(os.path.join(a.out, "sections.json"), "w") as f:
        json.dump(receipt, f, indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
