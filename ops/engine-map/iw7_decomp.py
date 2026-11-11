"""Decompile functions of the unpacked IW7 executable to C, in one batch (Ghidra, no whole-program analysis).

The engine map (iw7_engine_map.py) answers "what is at this address, who calls it"; this tool answers "what does
this function do". It builds, once, a flat image of the unpacked code and read-only data (the same three section
files of the reference root: unpacked-text.bin at 0x140001000, unpacked-rdata.bin at 0x141435000), imports it into a
private Ghidra project WITHOUT auto-analysis (seconds, not hours), and for each asked address disassembles, creates
the function (bounds from the engine map's exception directory when given) and decompiles it.

usage:
  iw7_decomp.py --ghidra <ghidra root> --work <folder> --reference-root <refs> [--db <engine map>] ADDR [ADDR ...]
  ADDR: 0x140C18D00, 140C18D00 or sub_140C18D00. Output: one block per function on stdout ("// ==== <addr>").
  --out <folder>: also write <addr>.c files. --timeout <s> per function (default 60).

Needs the Python of the RE lab's pyghidra environment (pyghidra 3.1) and a JDK (JAVA_HOME). The project lives in
--work and is reused by later calls (the import is done once, ~20 s); nothing in the reference root is changed.
"""
import argparse
import os
import re
import sqlite3
import sys

TEXT_VA, RDATA_VA, BASE = 0x140001000, 0x141435000, 0x140000000


def parse_addr(text):
    t = text.strip()
    t = re.sub(r'^(sub_|FUN_)', '', t, flags=re.I)
    return int(t, 16)


def build_flat(refs, path):
    text = open(os.path.join(refs, 'unpacked-text.bin'), 'rb').read()
    rdata = open(os.path.join(refs, 'unpacked-rdata.bin'), 'rb').read()
    size = (RDATA_VA - BASE) + len(rdata)
    img = bytearray(size)
    img[TEXT_VA - BASE:TEXT_VA - BASE + len(text)] = text
    img[RDATA_VA - BASE:RDATA_VA - BASE + len(rdata)] = rdata
    tmp = path + '.tmp'
    with open(tmp, 'wb') as f:
        f.write(img)
    os.replace(tmp, path)


def fn_bounds(db, addr):
    if not db:
        return None
    con = sqlite3.connect(db)
    try:
        cols = [r[1] for r in con.execute("pragma table_info(functions)")]
        if 'start' in cols and 'end' in cols:
            row = con.execute("select start,end from functions where start<=? and end>? order by start desc limit 1",
                              (addr, addr)).fetchone()
            return row
    except sqlite3.Error:
        return None
    finally:
        con.close()
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--ghidra', required=True)
    ap.add_argument('--work', required=True)
    ap.add_argument('--reference-root', required=True)
    ap.add_argument('--db')
    ap.add_argument('--out')
    ap.add_argument('--timeout', type=int, default=60)
    ap.add_argument('addrs', nargs='+')
    a = ap.parse_args()
    os.makedirs(a.work, exist_ok=True)
    flat = os.path.join(a.work, 'iw7_flat.bin')
    if not os.path.exists(flat):
        build_flat(a.reference_root, flat)
    os.environ.setdefault('GHIDRA_INSTALL_DIR', a.ghidra)
    import pyghidra
    pyghidra.start(install_dir=a.ghidra)
    from ghidra.base.project import GhidraProject
    from ghidra.app.util.importer import MessageLog
    from ghidra.program.model.lang import LanguageID, CompilerSpecID
    from ghidra.app.decompiler import DecompInterface, DecompileOptions
    from ghidra.util.task import TaskMonitor
    from ghidra.app.cmd.disassemble import DisassembleCommand
    from ghidra.app.cmd.function import CreateFunctionCmd
    from java.io import File

    proj_dir, proj_name = a.work, 'iw7flat'
    if os.path.exists(os.path.join(proj_dir, proj_name + '.gpr')):
        project = GhidraProject.openProject(proj_dir, proj_name, False)
        program = project.openProgram('/', 'iw7_flat.bin', False)
    else:
        project = GhidraProject.createProject(proj_dir, proj_name, False)
        from ghidra.program.util import DefaultLanguageService
        ls = DefaultLanguageService.getLanguageService()
        language = ls.getLanguage(LanguageID('x86:LE:64:default'))
        cspec = language.getCompilerSpecByID(CompilerSpecID('windows'))
        program = project.importProgram(File(flat), language, cspec)
        tx = program.startTransaction('rebase')
        program.setImageBase(program.getAddressFactory().getDefaultAddressSpace().getAddress(BASE), True)
        program.endTransaction(tx, True)
        project.saveAs(program, '/', 'iw7_flat.bin', True)
    space = program.getAddressFactory().getDefaultAddressSpace()
    fm = program.getFunctionManager()
    ifc = DecompInterface()
    opts = DecompileOptions()
    ifc.setOptions(opts)
    ifc.openProgram(program)
    mon = TaskMonitor.DUMMY
    for text in a.addrs:
        addr = parse_addr(text)
        ga = space.getAddress(addr)
        tx = program.startTransaction('fn')
        try:
            f = fm.getFunctionAt(ga)
            if f is None:
                DisassembleCommand(ga, None, True).applyTo(program, mon)
                CreateFunctionCmd(ga).applyTo(program, mon)
                f = fm.getFunctionAt(ga)
        finally:
            program.endTransaction(tx, True)
        if f is None:
            print('// ==== %X: no function could be created' % addr)
            continue
        res = ifc.decompileFunction(f, a.timeout, mon)
        code = res.getDecompiledFunction().getC() if res and res.getDecompiledFunction() else '// decompile failed: %s' % (res.getErrorMessage() if res else '?')
        print('// ==== %X' % addr)
        print(code)
        if a.out:
            os.makedirs(a.out, exist_ok=True)
            with open(os.path.join(a.out, '%X.c' % addr), 'w', encoding='utf-8') as fh:
                fh.write(code)
    project.save(program)
    project.close()


if __name__ == '__main__':
    main()
