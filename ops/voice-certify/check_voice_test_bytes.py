"""Check the engine byte table of src/native/voice_test.cpp against the unpacked retail code,
without starting the game.

Usage: python -I check_voice_test_bytes.py <voice_test.cpp> <dump dir>

<dump dir> holds unpacked-text.bin (mapped at 0x140001000). Every table entry must match the dump
byte for byte, and every engine address written in the code (comments excluded) must be a table
entry, lie inside one, or be referenced by an instruction inside one (RIP-relative operand, branch
target, or displacement from a register loaded with the image base). Exits non-zero on failure.
"""
import re
import sys
from pathlib import Path

import capstone
from capstone import x86

TEXT_BASE = 0x140001000
IMAGE_BASE = 0x140000000
ENTRY = re.compile(r'\{"([^"]+)",\s*0x([0-9A-Fa-f]+),\s*\{([^}]*)\},\s*role_(\w+)\}')
ADDRESS = re.compile(r'0x(14[0-9A-Fa-f]{7})\b')


def references(md, text, start, size):
    found, image_base_registers = set(), set()
    for ins in md.disasm(text[start - TEXT_BASE:start - TEXT_BASE + size], start):
        branch = ins.group(capstone.CS_GRP_JUMP) or ins.group(capstone.CS_GRP_CALL)
        for op in ins.operands:
            if op.type == x86.X86_OP_IMM and branch:
                found.add(op.imm)
            elif op.type == x86.X86_OP_MEM and op.mem.base == x86.X86_REG_RIP:
                target = ins.address + ins.size + op.mem.disp
                found.add(target)
                if ins.mnemonic == "lea" and target == IMAGE_BASE:
                    image_base_registers.add(ins.operands[0].reg)
            elif op.type == x86.X86_OP_MEM and op.mem.base in image_base_registers:
                found.add(IMAGE_BASE + op.mem.disp)
    return found


def main():
    source = Path(sys.argv[1]).read_text(encoding="utf-8")
    text = (Path(sys.argv[2]) / "unpacked-text.bin").read_bytes()
    md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
    md.detail = True

    code = re.sub(r"//[^\n]*", "", source)
    entries = [(name, int(address, 16), bytes(int(b, 16) for b in re.findall(r"0x([0-9A-Fa-f]{2})\b", body)), role)
               for name, address, body, role in ENTRY.findall(code)]
    failures = 0
    covered = set()

    for name, address, expected, role in entries:
        actual = text[address - TEXT_BASE:address - TEXT_BASE + len(expected)]
        ok = actual == expected
        failures += not ok
        print(f"{'ok  ' if ok else 'FAIL'} {address:#x} +{len(expected):#04x} {role:6} {name}")
        covered.update(range(address, address + len(expected)))
        covered.update(references(md, text, address, len(expected)))

    # Drop observer: every "drop site" entry must be a 5-byte call or jmp to SV_DropClient,
    # and every such branch found in the code should be listed (a byte scan may also find
    # false candidates inside other instructions, so a missing one is a note, not a failure).
    drop_target = 0x140C4FBA0
    sites = {address for name, address, expected, role in entries if name.startswith("drop site")}
    for name, address, expected, role in entries:
        if not name.startswith("drop site"):
            continue
        target = address + 5 + int.from_bytes(expected[1:5], "little", signed=True) if len(expected) == 5 and expected[0] in (0xE8, 0xE9) else None
        ok = target == drop_target
        failures += not ok
        print(f"{'ok  ' if ok else 'FAIL'} {address:#x} branches to {target:#x}" if target is not None else f"FAIL {address:#x} is not a 5-byte call or jmp")
    if sites:
        found = set()
        for offset in range(len(text) - 5):
            if text[offset] in (0xE8, 0xE9):
                address = TEXT_BASE + offset
                if address + 5 + int.from_bytes(text[offset + 1:offset + 5], "little", signed=True) == drop_target:
                    found.add(address)
        for address in sorted(found - sites):
            print(f"note {address:#x}: byte pattern of a branch to SV_DropClient not in the drop table (check it is a real instruction)")
        print(f"drop table: {len(sites)} sites; byte scan: {len(found)} candidates, {len(found & sites)} listed")

    for literal in sorted({int(value, 16) for value in ADDRESS.findall(code)}):
        ok = literal in covered
        failures += not ok
        print(f"{'ok  ' if ok else 'FAIL'} address {literal:#x} {'verified by the table' if ok else 'not covered by any table entry'}")

    print(f"{len(entries)} table entries; " + ("all verified" if not failures else f"{failures} failure(s)"))
    return 1 if failures or not entries else 0


if __name__ == "__main__":
    sys.exit(main())
