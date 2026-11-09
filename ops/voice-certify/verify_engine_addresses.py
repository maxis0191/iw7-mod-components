"""Check every engine address the voice component relies on against an unpacked
retail code dump, without starting the game.

Usage: python -I verify_engine_addresses.py <iw7-mod checkout> <dump dir>

<dump dir> holds unpacked-text.bin (mapped at 0x140001000) and unpacked-pdata.bin.
Exits non-zero when any check fails.
"""
import re
import struct
import sys
from pathlib import Path

import capstone

TEXT_BASE = 0x140001000
IMAGE_BASE = 0x140000000

# Functions called or hooked: must be the start of an unwind (pdata) entry.
FUNCTIONS = {
    0x14037BBA0: "CL_IsPlayerMuted",
    0x14099E210: "CL_ShouldSendVoiceTo",
    0x14037D5C0: "CL_VoiceFlush (hooked)",
    0x14037CFF0: "CL_VoiceReceive (hooked call)",
    0x140C73970: "Session_UnregisterRemotePlayer",
    0x140C733E0: "Session_RegisterRemotePlayer",
    0x1409C3EF0: "Voice_ShareChannel",
    0x140D59620: "Voice_IncomingVoiceData",
    0x140D92790: "Demonware address reference getter (hooked call)",
}

# Leaf functions have no unwind entry: require a direct call to them at a known site.
LEAVES = {
    0x140347690: (0x14037D649, "CL_ControllerIndexFromClientNum"),
    0x140D32920: (0x14037D66C, "Voice_GetLocalTalker"),
    0x140C72BA0: (0x14099E29A, "Session_IsUserRegistered"),
    0x140C732A0: (0x14099E2DE, "Session_IsLoopback (hooked call)"),
}

# Patched call sites: site -> expected original callee
CALL_SITES = {
    0x1409B0714: 0x14037CFF0,  # "v" dispatch -> CL_VoiceReceive
    0x14099E2DE: 0x140C732A0,  # CL_ShouldSendVoiceTo -> loopback test
    0x14099E349: 0x140D92790,  # CL_ShouldSendVoiceTo -> address reference
}

# Data addresses: address -> (functions that must reference it RIP-relatively, name)
DATA = {
    0x1422553D0: ((0x14037D5C0,), "cl_voicePackets"),
    0x142255DF8: ((0x14037D5C0,), "cl_voicePacketCount"),
    # the session players are registered in, also the lobby's session
    0x146B4E080: ((0x1409B2840, 0x14037D940, 0x1409C3E40), "g_serverSession"),
}


def load(dump: Path):
    text = (dump / "unpacked-text.bin").read_bytes()
    pdata = (dump / "unpacked-pdata.bin").read_bytes()
    starts = set()
    for offset in range(0, len(pdata) - 11, 12):
        begin, end, _ = struct.unpack_from("<III", pdata, offset)
        if begin and end > begin:
            starts.add(IMAGE_BASE + begin)
    return text, starts


def disassemble(text, address, limit=0x800):
    md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
    md.detail = True
    offset = address - TEXT_BASE
    for ins in md.disasm(text[offset:offset + limit], address):
        yield ins
        if ins.mnemonic in ("ret", "int3"):
            break


def call_target(text, site):
    raw = text[site - TEXT_BASE:site - TEXT_BASE + 5]
    return site + 5 + struct.unpack("<i", raw[1:5])[0] if raw[0] == 0xE8 else None


def rip_targets(ins):
    for op in ins.operands:
        if op.type == capstone.x86.X86_OP_MEM and op.mem.base == capstone.x86.X86_REG_RIP:
            yield ins.address + ins.size + op.mem.disp


def source_addresses(checkout: Path):
    found = set()
    for path in [checkout / "src/client/component/voice.cpp", checkout / "src/client/game/symbols.hpp"]:
        text = path.read_text(encoding="utf-8")
        if path.name == "symbols.hpp":
            text = "\n".join(line for line in text.splitlines() if any(
                name in line for name in ("Voice_", "CL_ShouldSendVoiceTo", "CL_IsPlayerMuted",
                                          "CL_ControllerIndexFromClientNum", "Session_UnregisterRemotePlayer",
                                          "cl_voicePacket")))
        found.update(int(value, 16) for value in re.findall(r"0x(14[0-9A-Fa-f]{7})", text))
    return found


def main():
    checkout, dump = Path(sys.argv[1]), Path(sys.argv[2])
    text, starts = load(dump)
    failures = []

    for address, name in FUNCTIONS.items():
        ok = address in starts
        print(f"{'ok  ' if ok else 'FAIL'} function {address:#x} {name}")
        if not ok:
            failures.append(name)

    for address, (site, name) in LEAVES.items():
        ok = call_target(text, site) == address
        print(f"{'ok  ' if ok else 'FAIL'} leaf {address:#x} {name}, called at {site:#x}")
        if not ok:
            failures.append(name)

    for site, callee in CALL_SITES.items():
        target = call_target(text, site)
        ok = target == callee
        print(f"{'ok  ' if ok else 'FAIL'} call site {site:#x} -> {target:#x}" if target else f"FAIL call site {site:#x} is not a call")
        if not ok:
            failures.append(f"call site {site:#x}")

    for address, (functions, name) in DATA.items():
        for function in functions:
            ok = any(address in set(rip_targets(ins)) for ins in disassemble(text, function, 0x1000))
            print(f"{'ok  ' if ok else 'FAIL'} data {address:#x} {name} referenced by {function:#x}")
            if not ok:
                failures.append(f"{name} in {function:#x}")

    known = set(FUNCTIONS) | set(LEAVES) | set(CALL_SITES) | set(DATA)
    unknown = sorted(source_addresses(checkout) - known)
    for address in unknown:
        print(f"FAIL source uses unchecked address {address:#x}")
        failures.append(f"{address:#x}")

    print("all engine addresses verified" if not failures else f"{len(failures)} check(s) failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
