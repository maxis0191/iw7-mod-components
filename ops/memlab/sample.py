"""Timeline of every iw7* game process: commit (private bytes), peak commit and working set, once a second, as JSON lines.

  python -B ops/memlab/sample.py <out.jsonl> [--seconds 300]

Start it once in the background before a Forge request; read the file when the request ends (peak per pid: ops/memlab/summarize helper at the bottom of this file: `python -B ops/memlab/sample.py --summary out.jsonl`).
"""
import ctypes, json, subprocess, sys, time
from ctypes import wintypes as W
sys.path.insert(0, __file__.rsplit("\\", 1)[0] if "\\" in __file__ else ".")
import vmmap

def iw7_pids():
    out = subprocess.run(["tasklist", "/fo", "csv", "/nh"], capture_output=True, text=True).stdout
    return [(int(l.split('","')[1]), l.split('","')[0].strip('"')) for l in out.splitlines() if l.lower().startswith('"iw7')]

def sample(pid):
    h = vmmap.k32.OpenProcess(0x1000 | 0x0010, False, pid)
    if not h: return None
    pmc = vmmap.PMC(); pmc.cb = ctypes.sizeof(pmc)
    ok = vmmap.psapi.GetProcessMemoryInfo(h, ctypes.byref(pmc), pmc.cb)
    vmmap.k32.CloseHandle(h)
    return dict(commit=pmc.PrivateUsage, peak_commit=pmc.PeakPagefileUsage, ws=pmc.WorkingSetSize) if ok else None

def summary(path):
    peak = {}
    for line in open(path):
        r = json.loads(line)
        p = peak.setdefault((r["pid"], r["name"]), dict(commit=0, peak_commit=0, ws=0, first=r["t"], last=r["t"]))
        for k in ("commit", "peak_commit", "ws"): p[k] = max(p[k], r[k])
        p["last"] = r["t"]
    for (pid, name), p in peak.items():
        print("pid %d %s: max commit %.2f GB, peak commit %.2f GB, max ws %.2f GB, seen %.0f s" % (pid, name, p["commit"] / 2**30, p["peak_commit"] / 2**30, p["ws"] / 2**30, p["last"] - p["first"]))

if __name__ == "__main__":
    if sys.argv[1] == "--summary": summary(sys.argv[2]); sys.exit()
    out, secs = sys.argv[1], int(sys.argv[sys.argv.index("--seconds") + 1]) if "--seconds" in sys.argv else 300
    t0 = time.time()
    with open(out, "w") as f:
        while time.time() - t0 < secs:
            for pid, name in iw7_pids():
                s = sample(pid)
                if s: f.write(json.dumps(dict(t=round(time.time() - t0, 1), pid=pid, name=name, **s)) + "\n")
            f.flush(); time.sleep(1)
