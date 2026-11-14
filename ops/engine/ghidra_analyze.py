"""Import the rebuilt IW7 image into a Ghidra project, apply every name we have, run the auto-analysis once.

Run with the Python of the PyGhidra environment (the RE lab's pyghidra-mcp venv has PyGhidra 3.1):

    <venv>/Scripts/python.exe -I ghidra_analyze.py --image <iw7_ship_live.exe> --project <folder> --name iw7_ship
        --ghidra <ghidra install> --java <jdk> --names <names.json> [--knowledge <knowledge.json>] [--heap 8g]

What it does, in order, and the time and memory of each step go into <project>/<name>.analyze.json:
  1. import the image (x86-64 Windows PE, image base 0x140000000) unless the program is already in the project;
  2. apply names (collect_names.py output, then our knowledge file): a label at each address, a function at each
     address of kind "function", a plate comment with the source;
  3. auto-analysis with a chosen analyzer set (slow analyzers that per-function decompile are off: the export
     decompiles every function once anyway);
  4. save.
Run under the scheduler's Analysis reservation (Invoke-EngineAnalysis.ps1 does that).
"""
import argparse
import ctypes
import ctypes.wintypes
import json
import os
import sys
import time


class PMC(ctypes.Structure):
    _fields_ = [("cb", ctypes.wintypes.DWORD), ("PageFaultCount", ctypes.wintypes.DWORD),
                ("PeakWorkingSetSize", ctypes.c_size_t), ("WorkingSetSize", ctypes.c_size_t),
                ("QuotaPeakPagedPoolUsage", ctypes.c_size_t), ("QuotaPagedPoolUsage", ctypes.c_size_t),
                ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t), ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
                ("PagefileUsage", ctypes.c_size_t), ("PeakPagefileUsage", ctypes.c_size_t)]


def memory():
    pmc = PMC()
    pmc.cb = ctypes.sizeof(PMC)
    k32 = ctypes.WinDLL("kernel32")
    k32.GetCurrentProcess.restype = ctypes.c_void_p
    get = ctypes.WinDLL("psapi").GetProcessMemoryInfo
    get.argtypes = [ctypes.c_void_p, ctypes.POINTER(PMC), ctypes.wintypes.DWORD]
    get(k32.GetCurrentProcess(), ctypes.byref(pmc), pmc.cb)
    return {"working_set_mb": round(pmc.WorkingSetSize / 2**20), "peak_working_set_mb": round(pmc.PeakWorkingSetSize / 2**20),
            "peak_private_mb": round(pmc.PeakPagefileUsage / 2**20)}


# Analyzers turned off: per-function decompiler passes (the export decompiles everything once), media scans and
# PDB lookups (there is no PDB). Everything else keeps Ghidra's defaults.
ANALYZERS_OFF = [
    "Decompiler Parameter ID",
    "Decompiler Switch Analysis",
    "Embedded Media",
    "PDB MSDIA",
    "PDB Universal",
    "Aggressive Instruction Finder",
    "Condense Filler Bytes",
    "Variadic Function Signature Override",
]


def start(ghidra, java, heap):
    os.environ["JAVA_HOME"] = java
    os.environ["GHIDRA_INSTALL_DIR"] = ghidra
    from pyghidra.launcher import HeadlessPyGhidraLauncher
    launcher = HeadlessPyGhidraLauncher(install_dir=ghidra)
    launcher.add_vmargs(f"-Xmx{heap}", "-XX:+UseG1GC")
    launcher.start()


def apply_names(program, entries, source_tag):
    from ghidra.program.model.symbol import SourceType
    from ghidra.app.cmd.disassemble import DisassembleCommand
    from ghidra.app.cmd.function import CreateFunctionCmd
    from ghidra.program.model.listing import CodeUnit
    space = program.getAddressFactory().getDefaultAddressSpace()
    st = program.getSymbolTable()
    fm = program.getFunctionManager()
    mem = program.getMemory()
    stats = {"labels": 0, "functions_created": 0, "renamed_functions": 0, "outside_memory": 0, "errors": 0}
    for e in entries:
        try:
            addr = space.getAddress(int(e["address"], 16))
        except Exception:
            stats["errors"] += 1
            continue
        if not mem.contains(addr):
            stats["outside_memory"] += 1
            continue
        name = e["name"].replace(" ", "_")
        try:
            if e.get("kind") == "function":
                f = fm.getFunctionAt(addr)
                if f is None and program.getListing().getInstructionAt(addr) is None:
                    DisassembleCommand(addr, None, True).applyTo(program)
                if f is None:
                    CreateFunctionCmd(addr).applyTo(program)
                    f = fm.getFunctionAt(addr)
                    if f is not None:
                        stats["functions_created"] += 1
                if f is not None:
                    f.setName(name, SourceType.IMPORTED)
                    stats["renamed_functions"] += 1
                    continue
            sym = st.createLabel(addr, name, SourceType.IMPORTED)
            sym.setPrimary()
            stats["labels"] += 1
            cmt = e.get("type")
            if cmt:
                program.getListing().setComment(addr, CodeUnit.PLATE_COMMENT, f"{source_tag}: {cmt}")
        except Exception:
            stats["errors"] += 1
    return stats


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--image", required=True)
    ap.add_argument("--project", required=True)
    ap.add_argument("--name", default="iw7_ship")
    ap.add_argument("--ghidra", required=True)
    ap.add_argument("--java", required=True)
    ap.add_argument("--names", action="append", default=[])
    ap.add_argument("--knowledge")
    ap.add_argument("--heap", default="8g")
    ap.add_argument("--skip-analysis", action="store_true")
    a = ap.parse_args(argv)
    report = {"schema": "iw7.engine-analyze/1", "image": os.path.abspath(a.image), "steps": []}
    t0 = time.time()

    def step(name, **extra):
        report["steps"].append({"step": name, "seconds": round(time.time() - t0, 1), **memory(), **extra})
        print(json.dumps(report["steps"][-1]), flush=True)

    start(a.ghidra, a.java, a.heap)
    step("jvm")
    from java.io import File
    from ghidra.base.project import GhidraProject
    from ghidra.program.util import GhidraProgramUtilities
    from ghidra.app.plugin.core.analysis import AutoAnalysisManager
    from ghidra.util.task import ConsoleTaskMonitor
    from java.lang import Runtime

    os.makedirs(a.project, exist_ok=True)
    gpr = os.path.join(a.project, a.name + ".gpr")
    if os.path.exists(gpr):
        project = GhidraProject.openProject(a.project, a.name)
    else:
        project = GhidraProject.createProject(a.project, a.name, False)
    prog_name = os.path.basename(a.image)
    df = project.getRootFolder().getFile(prog_name)
    if df is None:
        from ghidra.program.model.lang import LanguageID, CompilerSpecID
        from ghidra.app.util.importer import MessageLog
        program = project.importProgram(File(a.image))
        project.saveAs(program, "/", prog_name, True)
        step("import")
    else:
        program = project.openProgram("/", prog_name, False)
        step("open")

    tx = program.startTransaction("iw7 names")
    try:
        for path in a.names + ([a.knowledge] if a.knowledge else []):
            data = json.load(open(path, encoding="utf-8"))
            entries = data.get("names", [])
            stats = apply_names(program, entries, os.path.basename(path))
            step("names", file=os.path.basename(path), entries=len(entries), **stats)
    finally:
        program.endTransaction(tx, True)
    project.save(program)

    if not a.skip_analysis:
        options = program.getOptions("Analyzers")
        for an in ANALYZERS_OFF:
            if options.contains(an):
                options.setBoolean(an, False)
        mgr = AutoAnalysisManager.getAnalysisManager(program)
        tx = program.startTransaction("auto analysis")
        try:
            mgr.initializeOptions()
            mgr.reAnalyzeAll(None)
            # Ghidra's own progress output is swallowed by PyGhidra: print one line a minute ourselves.
            import threading
            stop = threading.Event()

            def progress():
                while not stop.wait(60):
                    try:
                        step("analysis progress", functions=program.getFunctionManager().getFunctionCount())
                    except Exception:
                        pass
            threading.Thread(target=progress, daemon=True).start()
            try:
                mgr.startAnalysis(ConsoleTaskMonitor())
            finally:
                stop.set()
            GhidraProgramUtilities.markProgramAnalyzed(program)
        finally:
            program.endTransaction(tx, True)
        rt = Runtime.getRuntime()
        step("analysis", functions=program.getFunctionManager().getFunctionCount(),
             jvm_used_mb=round((rt.totalMemory() - rt.freeMemory()) / 2**20), jvm_max_mb=round(rt.maxMemory() / 2**20))
        project.save(program)
        step("save")
    project.close()
    report["total_seconds"] = round(time.time() - t0, 1)
    with open(os.path.join(a.project, a.name + ".analyze.json"), "w") as f:
        json.dump(report, f, indent=1)
    print("done", report["total_seconds"], "s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
