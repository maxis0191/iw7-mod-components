"""Export the analysed Ghidra program into the engine database (SQLite) that `engine.py` queries.

    <venv>/Scripts/python.exe -I ghidra_export.py --project <folder> --name iw7_ship --program iw7_ship_live.exe
        --ghidra <ghidra> --java <jdk> --db <iw7-engine.sqlite> [--threads 6] [--max-minutes 25] [--only tables|decomp]

Tables (rebuilt each run): functions, calls, refs, strings, types, meta.
Decompiled code (table decomp) is resumable: functions already decompiled are skipped; the run stops after
--max-minutes and exits 3 when functions remain, so the scheduler can give the slot to a waiting build between
slices. The database is derived from the game and stays machine-local; it is never committed.
"""
import argparse
import bisect
import json
import os
import sqlite3
import sys
import threading
import time
import zlib

SCHEMA = """
CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE IF NOT EXISTS functions(addr INTEGER PRIMARY KEY, end INTEGER, name TEXT, size INTEGER,
    signature TEXT, block TEXT, thunk INTEGER, source TEXT);
CREATE TABLE IF NOT EXISTS calls(src_func INTEGER, at INTEGER, dst INTEGER, kind TEXT);
CREATE TABLE IF NOT EXISTS refs(src_func INTEGER, at INTEGER, dst INTEGER, kind TEXT, operand INTEGER);
CREATE TABLE IF NOT EXISTS strings(addr INTEGER PRIMARY KEY, text TEXT);
CREATE TABLE IF NOT EXISTS labels(addr INTEGER, name TEXT, source TEXT);
CREATE TABLE IF NOT EXISTS types(name TEXT, category TEXT, kind TEXT, size INTEGER, fields TEXT);
CREATE TABLE IF NOT EXISTS decomp(addr INTEGER PRIMARY KEY, ok INTEGER, seconds REAL, code BLOB);
"""
INDEXES = """
CREATE INDEX IF NOT EXISTS calls_dst ON calls(dst);
CREATE INDEX IF NOT EXISTS calls_src ON calls(src_func);
CREATE INDEX IF NOT EXISTS refs_dst ON refs(dst);
CREATE INDEX IF NOT EXISTS refs_src ON refs(src_func);
CREATE INDEX IF NOT EXISTS functions_name ON functions(name);
CREATE INDEX IF NOT EXISTS labels_addr ON labels(addr);
CREATE INDEX IF NOT EXISTS labels_name ON labels(name);
CREATE INDEX IF NOT EXISTS functions_end ON functions(end);
"""


def start(ghidra, java, heap):
    os.environ["JAVA_HOME"] = java
    os.environ["GHIDRA_INSTALL_DIR"] = ghidra
    from pyghidra.launcher import HeadlessPyGhidraLauncher
    launcher = HeadlessPyGhidraLauncher(install_dir=ghidra)
    launcher.add_vmargs(f"-Xmx{heap}", "-XX:+UseG1GC")
    launcher.start()


def u(addr):
    return addr.getOffset()


def export_tables(program, db, log):
    from ghidra.program.model.data import Structure, Union, Enum
    from ghidra.program.util import DefinedStringIterator
    fm = program.getFunctionManager()
    t = time.time()
    rows = []
    for f in fm.getFunctions(True):
        body = f.getBody()
        start = u(f.getEntryPoint())
        end = u(body.getMaxAddress()) + 1
        block = program.getMemory().getBlock(f.getEntryPoint())
        rows.append((start, end, f.getName(), int(body.getNumAddresses()), f.getSignature().getPrototypeString(),
                     block.getName() if block else None, 1 if f.isThunk() else 0, str(f.getSymbol().getSource())))
    db.execute("DELETE FROM functions")
    db.executemany("INSERT INTO functions VALUES(?,?,?,?,?,?,?,?)", rows)
    log("functions", len(rows), time.time() - t)
    starts = [r[0] for r in rows]
    ends = [r[1] for r in rows]

    def func_of(a):
        i = bisect.bisect_right(starts, a) - 1
        if i >= 0 and a < ends[i]:
            return starts[i]
        # a function body can be split; fall back to Ghidra for the rare miss
        return None

    t = time.time()
    db.execute("DELETE FROM calls")
    db.execute("DELETE FROM refs")
    rm = program.getReferenceManager()
    calls, refs = [], []
    n = 0
    it = rm.getReferenceSourceIterator(program.getMinAddress(), True)
    for src in it:
        for r in rm.getReferencesFrom(src):
            rt = r.getReferenceType()
            if rt.isFallthrough():
                continue
            at = u(src)
            dst = r.getToAddress()
            if not dst.isMemoryAddress():
                continue
            sf = func_of(at)
            if rt.isCall():
                calls.append((sf, at, u(dst), "call"))
            elif rt.isJump() and not rt.isConditional() and func_of(u(dst)) != sf:
                calls.append((sf, at, u(dst), "tail"))
            elif rt.isFlow():
                continue
            else:
                kind = "write" if rt.isWrite() else "read" if rt.isRead() else "data"
                refs.append((sf, at, u(dst), kind, r.getOperandIndex()))
            n += 1
        if len(refs) + len(calls) > 200000:
            db.executemany("INSERT INTO calls VALUES(?,?,?,?)", calls)
            db.executemany("INSERT INTO refs VALUES(?,?,?,?,?)", refs)
            calls, refs = [], []
    db.executemany("INSERT INTO calls VALUES(?,?,?,?)", calls)
    db.executemany("INSERT INTO refs VALUES(?,?,?,?,?)", refs)
    log("references", n, time.time() - t)

    t = time.time()
    db.execute("DELETE FROM strings")
    srows = []
    for d in DefinedStringIterator.forProgram(program):
        try:
            srows.append((u(d.getAddress()), str(d.getValue())))
        except Exception:
            pass
    db.executemany("INSERT OR REPLACE INTO strings VALUES(?,?)", srows)
    log("strings", len(srows), time.time() - t)

    t = time.time()
    db.execute("DELETE FROM labels")
    lrows = []
    for s in program.getSymbolTable().getAllSymbols(False):
        st = str(s.getSource())
        if st in ("USER_DEFINED", "IMPORTED", "ANALYSIS") and s.getAddress().isMemoryAddress():
            name = s.getName(True)
            if name.startswith(("LAB_", "DAT_", "switchD", "caseD")):
                continue
            lrows.append((u(s.getAddress()), name, st))
    db.executemany("INSERT INTO labels VALUES(?,?,?)", lrows)
    log("labels", len(lrows), time.time() - t)

    t = time.time()
    db.execute("DELETE FROM types")
    trows = []
    for dt in program.getDataTypeManager().getAllDataTypes():
        if isinstance(dt, (Structure, Union)):
            fields = [{"offset": c.getOffset(), "name": c.getFieldName(), "type": c.getDataType().getName(),
                       "size": c.getLength()} for c in dt.getDefinedComponents()]
            trows.append((dt.getName(), str(dt.getCategoryPath()), "union" if isinstance(dt, Union) else "struct",
                          dt.getLength(), json.dumps(fields)))
        elif isinstance(dt, Enum):
            vals = [{"name": nm, "value": int(dt.getValue(nm))} for nm in dt.getNames()]
            trows.append((dt.getName(), str(dt.getCategoryPath()), "enum", dt.getLength(), json.dumps(vals)))
    db.executemany("INSERT INTO types VALUES(?,?,?,?,?)", trows)
    log("types", len(trows), time.time() - t)
    db.executescript(INDEXES)
    db.commit()


def export_decomp(program, db, threads, deadline, log):
    from ghidra.app.decompiler import DecompInterface, DecompileOptions
    from ghidra.util.task import ConsoleTaskMonitor
    done = {r[0] for r in db.execute("SELECT addr FROM decomp")}
    fm = program.getFunctionManager()
    todo = [f for f in fm.getFunctions(True) if u(f.getEntryPoint()) not in done and not f.isExternal()]
    log("decomp todo", len(todo), 0)
    lock = threading.Lock()
    out = []
    idx = [0]
    stats = {"ok": 0, "failed": 0}

    def worker():
        di = DecompInterface()
        opts = DecompileOptions()
        opts.grabFromProgram(program)
        di.setOptions(opts)
        di.toggleCCode(True)
        di.toggleSyntaxTree(False)
        di.setSimplificationStyle("decompile")
        di.openProgram(program)
        mon = ConsoleTaskMonitor()
        try:
            while time.time() < deadline:
                with lock:
                    if idx[0] >= len(todo):
                        return
                    f = todo[idx[0]]
                    idx[0] += 1
                t = time.time()
                res = di.decompileFunction(f, 60, mon)
                code = None
                if res is not None and res.decompileCompleted():
                    code = res.getDecompiledFunction().getC()
                with lock:
                    if code is None:
                        stats["failed"] += 1
                        msg = res.getErrorMessage() if res is not None else "no result"
                        out.append((u(f.getEntryPoint()), 0, time.time() - t, zlib.compress(str(msg).encode())))
                    else:
                        stats["ok"] += 1
                        out.append((u(f.getEntryPoint()), 1, time.time() - t, zlib.compress(str(code).encode(), 6)))
        finally:
            di.dispose()

    ths = [threading.Thread(target=worker, daemon=True) for _ in range(threads)]
    for th in ths:
        th.start()
    t0 = time.time()
    last = t0
    while any(th.is_alive() for th in ths):
        time.sleep(5)
        with lock:
            batch, out[:] = list(out), []
        if batch:
            db.executemany("INSERT OR REPLACE INTO decomp VALUES(?,?,?,?)", batch)
            db.commit()
        if time.time() - last > 60:
            last = time.time()
            log("decomp progress", idx[0], time.time() - t0, ok=stats["ok"], failed=stats["failed"])
    with lock:
        batch = list(out)
    db.executemany("INSERT OR REPLACE INTO decomp VALUES(?,?,?,?)", batch)
    db.commit()
    remaining = len(todo) - idx[0]
    log("decomp", stats["ok"] + stats["failed"], time.time() - t0, ok=stats["ok"], failed=stats["failed"],
        remaining=remaining)
    return remaining


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--project", required=True)
    ap.add_argument("--name", default="iw7_ship")
    ap.add_argument("--program", required=True)
    ap.add_argument("--ghidra", required=True)
    ap.add_argument("--java", required=True)
    ap.add_argument("--db", required=True)
    ap.add_argument("--heap", default="8g")
    ap.add_argument("--threads", type=int, default=6)
    ap.add_argument("--max-minutes", type=float, default=25)
    ap.add_argument("--only", choices=["tables", "decomp"])
    a = ap.parse_args(argv)
    t0 = time.time()
    deadline = t0 + a.max_minutes * 60

    def log(what, n, secs, **kw):
        print(json.dumps({"export": what, "count": n, "seconds": round(secs, 1), "elapsed": round(time.time() - t0, 1), **kw}),
              flush=True)

    start(a.ghidra, a.java, a.heap)
    from ghidra.base.project import GhidraProject
    project = GhidraProject.openProject(a.project, a.name, True)
    program = project.openProgram("/", a.program, True)
    db = sqlite3.connect(a.db)
    db.executescript(SCHEMA)
    db.execute("PRAGMA journal_mode=WAL")
    remaining = 0
    if a.only in (None, "tables"):
        export_tables(program, db, log)
        db.execute("INSERT OR REPLACE INTO meta VALUES('exported_utc', ?)", (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),))
        db.execute("INSERT OR REPLACE INTO meta VALUES('program', ?)", (a.program,))
        db.commit()
    if a.only in (None, "decomp"):
        remaining = export_decomp(program, db, a.threads, deadline, log)
    db.execute("INSERT OR REPLACE INTO meta VALUES('decomp_remaining', ?)", (str(remaining),))
    db.commit()
    db.close()
    project.close()
    print("export done", round(time.time() - t0, 1), "s; remaining", remaining)
    return 3 if remaining else 0


if __name__ == "__main__":
    sys.exit(main())
