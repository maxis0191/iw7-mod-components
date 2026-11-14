"""Copy the code a running IW7 process executes into files, read only (for iw7_xref32.py --extra).

The section files of the reference root hold the unpacked code at 0x140001000; part of the engine (agent pools, the
map-start reservation of G_InitGame, the sentient init) runs from protected spans that exist only in a live process
(0x14B2B4000 + 0x104D400 on the shipped executable). This tool opens one of YOUR OWN game processes for reading only,
copies the committed, readable pages of each asked span (unreadable pages are left zero and listed) and writes
<out>/<base hex>.bin plus <out>/spans.json. Nothing is written to the process.

usage: iw7_dump_spans.py --pid <pid> --out <new folder> [--span 14B2B4000:104D400 ...]
then:  iw7_xref32.py --reference-root <refs> --extra 14B2B4000=<out>/14B2B4000.bin ADDR[:SPAN] ...
"""
import argparse
import ctypes
import json
import os
from ctypes import wintypes

PAGE = 0x1000


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--pid', type=int, required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--span', action='append', default=None)
    a = ap.parse_args()
    spans = a.span or ['14B2B4000:104D400']
    os.makedirs(a.out, exist_ok=False)
    k = ctypes.WinDLL('kernel32', use_last_error=True)
    k.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    k.OpenProcess.restype = wintypes.HANDLE
    k.ReadProcessMemory.argtypes = [wintypes.HANDLE, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t,
                                    ctypes.POINTER(ctypes.c_size_t)]
    k.ReadProcessMemory.restype = wintypes.BOOL
    h = k.OpenProcess(0x1010, False, a.pid)          # PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_VM_READ
    if not h:
        raise ctypes.WinError(ctypes.get_last_error())
    report = []
    try:
        for item in spans:
            base_s, size_s = item.split(':')
            base, size = int(base_s, 16), int(size_s, 16)
            data = bytearray(size)
            got = ctypes.c_size_t()
            missing = []
            buf = ctypes.create_string_buffer(PAGE)
            for off in range(0, size, PAGE):
                n = min(PAGE, size - off)
                if k.ReadProcessMemory(h, base + off, buf, n, ctypes.byref(got)) and got.value == n:
                    data[off:off + n] = buf.raw[:n]
                else:
                    missing.append('%X' % (base + off))
            path = os.path.join(a.out, '%X.bin' % base)
            with open(path, 'wb') as f:
                f.write(data)
            report.append({'base': '%X' % base, 'size': size, 'file': path, 'unreadable_pages': len(missing),
                           'first_unreadable': missing[:8]})
    finally:
        k.CloseHandle(h)
    with open(os.path.join(a.out, 'spans.json'), 'w', encoding='utf-8') as f:
        json.dump({'pid': a.pid, 'spans': report}, f, indent=1)
    print(json.dumps(report, indent=1))


if __name__ == '__main__':
    main()
