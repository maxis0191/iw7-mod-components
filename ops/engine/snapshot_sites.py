"""Snapshot entity capacity: every instruction field that depends on the per-snapshot entity cap (a49, 16 Nov 2026).

Stock the engine sends at most 768 entity records in one client snapshot (sv_maxSnapshotEntities, DAT_146B3985C, set by SV_InitSnapshotBufferSizes
0x140C68A00), builds two lists of at most 1,024 records (DAT_146B39858 / DAT_146B39860), keeps them in a server ring of frames x 0xA40 + clients x 1,024
records of 0x110 bytes (DAT_146B39810; its hunk size is FUN_140C68880), and the client copies at most 768 parsed records into the cgame snapshot
(DAT_1421EDA6C, entities at +0x4AB8 of the 0x3DC78 byte object), reading them from a ring of frames x 600 records (FUN_14034F1D0) with 1,024 baselines
(DAT_1421EDA68, FUN_14034F3E0). The entity list ends with the number 0x7FF in 11 bits (server FUN_140C67230, client FUN_1409B7C30), so a snapshot never
holds more than 2,047 records and a cap of 2,048 cannot drop one: no network field changes width.

    python -B ops/engine/snapshot_sites.py find  -o ops/engine/snapshot-sites.json   # instruction index + analysed image (RE lab)
    python -B ops/engine/snapshot_sites.py check ops/engine/snapshot-sites.json      # decode every row against the image
    python -B ops/engine/snapshot_sites.py emit  ops/engine/snapshot-sites.json -o src/native/agent_capacity_snapshot.inc

Rows: a field of `width` bytes (4, or 1 for the `shl eax, 0xA`) in one instruction, its stock value and the op the planner of
src/native/agent_capacity.cpp (`snapshot_op`) gives the new value. Two kinds:
  * VALUE rows (VALUE_SITES: instruction address, field kind, op, stock value): the cap, the list caps, the ring terms of SV_InitSnapshotBufferSizes,
    the server hunk size, the client ring multiplier and the client's baseline array;
  * ENTITY rows: every instruction of the image that holds 0x4AB8 as a displacement or an immediate and is a user of the cgame snapshot's entity
    array (`SNAPSHOT_USERS`); the others (`OTHER_0X4AB8`, struct fields of other objects at the same offset) are listed with the reason. `find` fails when
    the index holds a 0x4AB8 field that is in neither list (a new image, a missed user), so the table is complete by construction.
"""
import argparse
import json
import os
import sqlite3
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import state_sites as ss  # noqa: E402

BASE = ss.BASE
ENTITY_OFFSET = 0x4AB8

# (instruction address, field kind, stock value, op, why)
VALUE_SITES = [
    (0x140C68A28, 'imm', 0x400, 'cap', 'SV_InitSnapshotBufferSizes: DAT_146B39858 = 0x400 (list A cap, FUN_140C64310 / FUN_140C67F50)'),
    (0x140C68A34, 'imm', 0x300, 'cap', 'SV_InitSnapshotBufferSizes: DAT_146B3985C = 0x300 (sv_maxSnapshotEntities, checked at 0x140C67478)'),
    (0x140C68A4F, 'imm8', 0x0A, 'client_shift', 'SV_InitSnapshotBufferSizes: `shl eax, 0xA` = clients x 0x400 (the per client room of the entity ring)'),
    (0x140C68A52, 'imm', 0xA40, 'frame_term', 'SV_InitSnapshotBufferSizes: `imul r8d, ecx, 0xA40` = frames x 0xA40 (the per frame room of the ring DAT_146B39810)'),
    (0x140C68A63, 'imm', 0x400, 'cap', 'SV_InitSnapshotBufferSizes: DAT_146B39860 = 0x400 (list B cap, the baselines; FUN_140C647A0, alloc imul 0x110)'),
    (0x140C688BA, 'imm', 0x44000, 'records_bytes', 'FUN_140C68880 (server hunk size): clients x 0x400 x 0x110, the per client part of the ring'),
    (0x140C688C1, 'imm', 0xAE400, 'frame_bytes', 'FUN_140C68880: frames x 0xA40 x 0x110, the per frame part of the ring'),
    (0x140C689E5, 'imm', 0x45000, 'baseline_bytes', 'FUN_140C68880: list B 0x400 x 0x110 (0x44000) + the 0xFF8 block (0x1000)'),
    (0x14034F21C, 'imm', 0x258, 'client_ring', 'FUN_14034F1D0: `imul eax, r8d, 0x258` = the client parsed-entity ring, frames x 600 records (cl+0x11C08)'),
    (0x1403504C1, 'imm', 0x44000, 'records_bytes', 'FUN_14034F3E0: `mov edx, 0x44000` = alloc of the client baseline array, 0x400 x 0x110 (DAT_1421EDA60)'),
    (0x1403504C6, 'imm', 0x300, 'cap', 'FUN_14034F3E0: DAT_1421EDA6C = 0x300 (the most records CL_ParseSnapshot copies into the cgame snapshot)'),
    (0x1403504D6, 'imm', 0x400, 'cap', 'FUN_14034F3E0: DAT_1421EDA68 = 0x400 (the client baseline array capacity, FUN_1409AD830 clears it)'),
]

# the cgame snapshot's entity array (0x4AB8): users, read in the decompile (a49); the loop `for i < snap->numEntities (+0x18)` or the copy into it
SNAPSHOT_USERS = {
    0x14021F14C: 'unmapped function 0x14021F124 (FUN_1402E2AD0 result, loop over numEntities)',
    0x140277A79: 'FUN_140277A10', 0x14050A5A0: 'FUN_140509590 (add r14, 0x4AB8)', 0x1405C7B88: 'FUN_1405C6B60', 0x140684267: 'FUN_140684140',
    0x14075C005: 'FUN_14075BFE0', 0x14077E7C6: 'FUN_14077E630', 0x1407A9766: 'FUN_1407A75F0', 0x1407AA8D7: 'FUN_1407A98A0 (add rsi, 0x4AB8)',
    0x140821325: 'FUN_140821300', 0x14082EDF8: 'FUN_14082EDC0 (add rdi, 0x4AB8)', 0x14084535F: 'FUN_140845330',
    0x14086FC69: 'CG_SetNextSnap FUN_14086FBA0', 0x14086FD0C: 'CG_SetNextSnap', 0x14087044D: 'CG_SetNextSnap', 0x1408705BA: 'CG_SetNextSnap',
    0x140872DFC: 'FUN_140871AF0', 0x1408734E5: 'FUN_1408734C0', 0x140873756: 'FUN_140873530',
    0x140993288: 'CL_ParseSnapshot FUN_140992000: copy of the parsed records into the cgame snapshot',
    0x14099331A: 'CL_ParseSnapshot FUN_140992000: the same copy, baseline path',
}
OTHER_0X4AB8 = {
    0x1400A9DB6: 'FUN_1400A9BB0 struct copy (movups of another object)', 0x1400A9FDB: 'FUN_1400A9F30 struct copy', 0x1400AA04E: 'FUN_1400A9F30 struct copy',
    0x1400AA0DA: 'FUN_1400A9F30 struct copy', 0x1400B5732: 'FUN_1400B2FD0 net field table (a field offset 0x4AB8 of a state struct)',
    0x1400B92A2: 'FUN_1400B6B40 net field table', 0x1402564EA: 'FUN_1402560F0 clear of a state struct', 0x140416625: 'FUN_140416610 struct copy',
    0x14047A784: 'FUN_14047A740 struct copy', 0x1404928BA: 'FUN_140492790 field of a state struct', 0x140492FEC: 'FUN_140492E50 field of a state struct',
    0x1408D40BF: 'FUN_1408D3ED0 copy of playerstate-like fields (0x4AA4..0x4ABC next to 0x491A0)', 0x140909699: 'FUN_1409095F0 playerstate-like copy',
    0x140AFABA1: 'FUN_140AFAB30 struct copy', 0x140B68222: 'FUN_140B68200 field of a state struct', 0x140B683BE: 'FUN_140B68340 field of a state struct',
    0x140B689F2: 'FUN_140B68340 field of a state struct', 0x14C2F176C: 'data decoded as code (`enter`)',
}


def index_hits():
    _, db_file = ss.image_path()
    idx = os.path.join(os.path.dirname(db_file), 'iw7-insn-index.sqlite')
    con = sqlite3.connect('file:' + idx.replace(chr(92), '/') + '?mode=ro', uri=True)
    return [(at, kind, text) for at, kind, text in con.execute('select at, kind, text from insn where value=? and kind in (?,?) order by at',
                                                               (ENTITY_OFFSET, 'disp', 'imm'))]


def field_of(md, ins, kind, value):
    """(field address, width) of the field of `ins` that holds `value`."""
    from capstone import x86_const as X
    if kind == 'imm8':
        raw = bytes(ins.bytes)
        for p in range(len(raw)):
            if raw[p] == value and p >= 1:
                changed = bytearray(raw)
                changed[p] = value + 1
                other = next(md.disasm(bytes(changed), ins.address), None)
                if other is not None and other.size == ins.size and other.mnemonic == ins.mnemonic and other.op_str != ins.op_str:
                    return ins.address + p, 1
        raise SystemExit('no byte field %#x in %s' % (value, ins.bytes.hex()))
    for f in ss.fields(ins, md):
        if f[0] == ('imm' if kind == 'imm' else 'disp') and (f[2] & 0xFFFFFFFF) == value:
            return f[1], 4
    raise SystemExit('no %s field %#x in %s %s' % (kind, value, ins.mnemonic, ins.op_str))


def row_of(img, md, at, kind, value, op, why):
    probe = img.read(at, 15)
    ins = next(md.disasm(probe, at))
    field, width = field_of(md, ins, kind, value)
    got = int.from_bytes(img.read(field, width), 'little')
    if got != value:
        raise SystemExit('%#x: field %#x holds %#x, expected %#x' % (at, field, got, value))
    return dict(at=at, field=field, width=width, stock=value, op=op, text=ins.mnemonic + ' ' + ins.op_str, bytes=ins.bytes.hex(), why=why)


def find(args):
    image_file, _ = ss.image_path()
    img, md = ss.Image(image_file), ss.cs()
    rows = []
    for at, kind, value, op, why in VALUE_SITES:
        rows.append(row_of(img, md, at, kind, value, op, why))
    unclassified = []
    for at, kind, text in index_hits():
        if at in OTHER_0X4AB8:
            continue
        if at not in SNAPSHOT_USERS:
            unclassified.append((hex(at), kind, text))
            continue
        rows.append(row_of(img, md, at, 'imm' if kind == 'imm' else 'disp', ENTITY_OFFSET, 'entity_offset', SNAPSHOT_USERS[at]))
    missing = [hex(a) for a in list(SNAPSHOT_USERS) + list(OTHER_0X4AB8) if a not in {h[0] for h in index_hits()}]
    rows.sort(key=lambda r: r['field'])
    json.dump({'schema': 'iw7.snapshot-sites/1', 'other_0x4ab8': {hex(k): v for k, v in OTHER_0X4AB8.items()}, 'rows': rows}, open(args.o, 'w'), indent=1)
    by = {}
    for r in rows:
        by[r['op']] = by.get(r['op'], 0) + 1
    print(len(rows), 'rows', by)
    if unclassified or missing:
        print('0x4AB8 fields in the index that no list names:', unclassified)
        print('listed users the index does not hold:', missing)
        return 1


def check(args):
    image_file, _ = ss.image_path()
    img, md = ss.Image(image_file), ss.cs()
    data = json.load(open(args.file))
    bad = 0
    for r in data['rows']:
        raw = img.read(r['at'], len(r['bytes']) // 2)
        ins = next(md.disasm(raw, r['at']))
        if raw.hex() != r['bytes'] or ins.size != len(raw):
            print('MISMATCH', hex(r['at']))
            bad += 1
            continue
        if int.from_bytes(img.read(r['field'], r['width']), 'little') != r['stock']:
            print('FIELD', hex(r['field']))
            bad += 1
    print('checked', len(data['rows']), 'rows,', bad, 'bad')
    return 1 if bad else 0


def emit(args):
    data = json.load(open(args.file))
    lines = ['// Generated by ops/engine/snapshot_sites.py emit from snapshot-sites.json; do not edit.',
             '// Each row: field address, width in bytes, stock value, snapshot_op.']
    for r in data['rows']:
        lines.append('{0x%Xull, %d, 0x%Xu, snapshot_op::%s},' % (r['field'], r['width'], r['stock'], r['op']))
    with open(args.o, 'w', newline='\n') as out:
        out.write('\n'.join(lines) + '\n')
    print('wrote', len(data['rows']), 'rows to', args.o)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('find'); p.add_argument('-o', required=True); p.set_defaults(fn=find)
    p = sub.add_parser('check'); p.add_argument('file'); p.set_defaults(fn=check)
    p = sub.add_parser('emit'); p.add_argument('file'); p.add_argument('-o', required=True); p.set_defaults(fn=emit)
    args = ap.parse_args()
    sys.exit(args.fn(args) or 0)


if __name__ == '__main__':
    main()
