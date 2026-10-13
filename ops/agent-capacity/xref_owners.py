"""Offline RIP xrefs within retained pdata spans; run only under Analysis admission."""
import argparse
import hashlib
import json
import struct
from collections import defaultdict
from pathlib import Path

from inspect_retained import INPUTS

IMAGE = 0x140000000
TEXT = 0x140001000
RDATA = 0x141435000
POOL_TARGETS = {0x143C986B0, 0x143C986B8, 0x143C986C0}
# Exact neighbouring/context anchors only. A match is not a certified level
# layout: producer proof still needs the indirect store and its actual offset.
# 650 was a false level-base candidate (actual dvar slot). Preserve that
# history in the inventory; do not let its writers starve real reset callers.
ANCHOR_TARGETS = {0x143C98660, 0x143C98668, 0x143C98670, 0x143F25A88}
RESET_CALL_TARGETS = {0x1403FCC10}
CALL_TARGETS = {0x140C1A190} | RESET_CALL_TARGETS
TARGETS = {0x143C986B0, 0x143C986B8, 0x143C986C0, 0x146B2C508, 0x143F9B358,
           0x144C6F208, 0x144C6F20C, 0x144C6F210} | ANCHOR_TARGETS


class Owners:
    """Resolve UNW_FLAG_CHAININFO recursively, including all table children."""
    def __init__(self, pdata, rdata):
        self.records = list(struct.iter_unpack('<III', pdata))
        self.record_set = set(self.records)
        self.rdata = rdata
        self.cache = {}
        self.depths = {}
        self.errors = {}
        self.groups = defaultdict(list)
        for record in self.records:
            try:
                self.groups[self.root(record)].append(record)
            except ValueError as error:
                self.errors[record] = str(error)

    def root(self, record, ancestors=()):
        if record in self.cache:
            if len(ancestors) + self.depths[record] > 32:
                raise ValueError('Unwind chain depth')
            return self.cache[record]
        if record in ancestors or len(ancestors) >= 32:
            raise ValueError('Unwind chain cycle/depth')
        begin, end, unwind = record
        if begin >= end:
            raise ValueError('Invalid pdata interval')
        offset = IMAGE + unwind - RDATA
        if offset < 0 or offset + 4 > len(self.rdata):
            raise ValueError('Unwind outside captured rdata')
        version_flags, _, count, _ = self.rdata[offset:offset + 4]
        if version_flags & 7 not in (1, 2):
            raise ValueError('Unsupported unwind version')
        flags = version_flags >> 3
        if flags & ~7:
            raise ValueError('Unknown unwind flags')
        tail = offset + 4 + ((count + 1) & ~1) * 2
        if tail > len(self.rdata) or (flags & 3 and tail + 4 > len(self.rdata)):
            raise ValueError('Truncated unwind codes/handler')
        if flags & 4:
            if flags & 3:
                raise ValueError('Chain and handler flags conflict')
            if tail + 12 > len(self.rdata):
                raise ValueError('Truncated unwind chain')
            parent = struct.unpack_from('<III', self.rdata, tail)
            if parent not in self.record_set:
                raise ValueError('Parent runtime-function missing from pdata')
            root = self.root(parent, ancestors + (record,))
            depth = 1 + self.depths[parent]
        else:
            root = record
            depth = 1
        self.cache[record] = root
        self.depths[record] = depth
        return root

    def spans(self, root):
        ordered = sorted((IMAGE + a, IMAGE + b) for a, b, _ in self.groups[root])
        merged = []
        for a, b in ordered:
            if merged and a <= merged[-1][1]:
                merged[-1][1] = max(b, merged[-1][1])
            else:
                merged.append([a, b])
        return merged


def priority(xrefs):
    # Exact reset callers are the current missing producer bridge. Retained
    # selected-only call lists cannot establish their absence across the image.
    if any(x['access'] == 'call' and int(x['target'], 16) in RESET_CALL_TARGETS for x in xrefs):
        return (-1, 0)
    # Pool producers/consumers and the exact allocator caller precede the quota.
    pool = any(int(x['target'], 16) in POOL_TARGETS | ANCHOR_TARGETS for x in xrefs)
    caller = any(x['access'] == 'call' and int(x['target'], 16) in CALL_TARGETS for x in xrefs)
    access = (0 if any(x['access'] == 'write' for x in xrefs) else
              1 if any(x['access'] == 'address' for x in xrefs) else 2)
    # Do not let numerous generic pool readers starve the sole exact caller.
    pool_producer = any(int(x['target'], 16) in POOL_TARGETS | ANCHOR_TARGETS and x['access'] in ('write', 'address') for x in xrefs)
    family = 0 if pool_producer else 1 if caller else 2 if pool else 3
    return (family, access)


def retained_roots(report):
    if report.get('schema') != 'iw7.agent-capacity-xrefs/1':
        raise ValueError('Unsupported retained report schema')
    expected = {name: digest for name, digest in INPUTS.values()}
    if report.get('input_hashes') != expected:
        raise ValueError('Retained input hashes changed')
    rows = report['selected_owners'] + report['excluded_owners']
    roots = {int(row['root'], 16) for row in rows}
    if len(rows) != len(roots) or len(roots) != report['matching_owners'] or len(roots) > 256:
        raise ValueError('Retained owner coverage/duplicate/bound mismatch')
    return roots


def ranked_roots(matches):
    return sorted(matches, key=lambda root: (*priority(matches[root]), root))


def run(reference_root, retained_report=None):
    import capstone
    from capstone.x86 import X86_OP_MEM, X86_OP_IMM, X86_REG_RIP
    blobs = {}
    for kind, (name, expected) in INPUTS.items():
        blob = (reference_root / name).read_bytes()
        if hashlib.sha256(blob).hexdigest() != expected:
            raise ValueError(f'Input SHA256 changed: {name}')
        blobs[kind] = blob
    owners = Owners(blobs['pdata'], blobs['rdata'])
    scope = retained_roots(retained_report) if retained_report is not None else None
    if scope is not None and not scope.issubset({IMAGE + root[0] for root in owners.groups}):
        raise ValueError('Retained root is not a complete captured pdata owner')
    md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
    md.detail = True
    matches = defaultdict(list)
    decoded_bytes = 0
    incomplete_records = 0
    for record in owners.records:
        if record in owners.errors:
            continue
        if scope is not None and IMAGE + owners.root(record)[0] not in scope:
            continue
        begin, end, _ = record
        start, stop = IMAGE + begin, IMAGE + end
        if start < TEXT or stop > TEXT + len(blobs['text']):
            continue
        last = start
        # No skipdata: a failed decode ends this metadata span and is reported.
        for instruction in md.disasm(blobs['text'][start - TEXT:stop - TEXT], start):
            last = instruction.address + instruction.size
            decoded_bytes += instruction.size
            if instruction.mnemonic == 'call' and instruction.operands and instruction.operands[0].type == X86_OP_IMM:
                target = instruction.operands[0].imm
                if target in CALL_TARGETS:
                    matches[owners.root(record)].append({
                        'address': hex(instruction.address), 'target': hex(target), 'access': 'call',
                        'mnemonic': instruction.mnemonic,
                        'instruction_sha256': hashlib.sha256(instruction.bytes).hexdigest(),
                        'record_start': hex(start), 'record_end': hex(stop)})
            for operand in instruction.operands:
                if operand.type != X86_OP_MEM or operand.mem.base != X86_REG_RIP:
                    continue
                target = last + operand.mem.disp
                if target in TARGETS:
                    access = ('address' if instruction.mnemonic == 'lea' else
                              'write' if operand.access & capstone.CS_AC_WRITE else 'read')
                    matches[owners.root(record)].append({
                        'address': hex(instruction.address), 'target': hex(target),
                        'access': access, 'mnemonic': instruction.mnemonic,
                        'instruction_sha256': hashlib.sha256(instruction.bytes).hexdigest(),
                        'record_start': hex(start), 'record_end': hex(stop)})
        if last != stop:
            incomplete_records += 1
    ranked = ranked_roots(matches)
    selected, excluded = [], []
    for root in ranked:
        spans = owners.spans(root)
        size = sum(b - a for a, b in spans)
        if size > 65536 or len(selected) >= 32:
            excluded.append({'root': hex(IMAGE + root[0]), 'bytes': size,
                             'xrefs': matches[root], 'priority': list(priority(matches[root])),
                             'reason': 'owner-byte-bound' if size > 65536 else 'owner-count-bound'})
            continue
        calls = []
        for a, b in spans:
            for instruction in md.disasm(blobs['text'][a - TEXT:b - TEXT], a):
                if instruction.mnemonic == 'call' and instruction.operands:
                    operand = instruction.operands[0]
                    if operand.type == X86_OP_IMM and len(calls) < 512:
                        calls.append({'site': hex(instruction.address), 'target': hex(operand.imm)})
        selected.append({'root': hex(IMAGE + root[0]), 'bytes': size,
                         'spans': [{'start': hex(a), 'end': hex(b),
                                    'sha256': hashlib.sha256(blobs['text'][a - TEXT:b - TEXT]).hexdigest()}
                                   for a, b in spans],
                         'pdata_records': len(owners.groups[root]), 'priority': list(priority(matches[root])), 'xrefs': matches[root],
                         'direct_calls': calls, 'status': 'decoded-candidate-needs-control-flow-review'})
    return {'schema': 'iw7.agent-capacity-xrefs/1',
            'input_hashes': {name: expected for name, expected in INPUTS.values()},
            'capstone_version': capstone.__version__, 'targets': sorted(map(hex, TARGETS)),
            'indirect_producer_anchors': sorted(map(hex, ANCHOR_TARGETS)),
            'anchor_caveat': '650 rejected as dvar.660/668/670 reset/player/entity anchors verified, not B8/C0 publication proof; certify indirect stores from complete owners, never SDK offsetof alone.',
            'direct_call_targets': sorted(map(hex, CALL_TARGETS)),
            'decode_scope': 'retained-candidate-owners-only' if scope is not None else 'all-captured-pdata',
            'retained_candidates_reused': len(scope) if scope is not None else 0,
            'decoded_bytes': decoded_bytes, 'incomplete_records': incomplete_records,
            'unresolved_unwind_records': len(owners.errors), 'matching_owners': len(matches),
            'selected_owners': selected, 'excluded_owners': excluded,
            'limitations': 'Pdata linear decode only, no leaf scan or indirect xrefs. RIP hits are candidates; control flow/type and allocator role remain unproven.'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference-root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--retained-report', type=Path, help='Revisit <=256 prior candidates only; callers outside this set remain unsearched')
    args = parser.parse_args()
    output = args.output.resolve()
    runtime = Path(__file__).resolve().parents[2] / 'runtime' / 'agent-capacity'
    if not output.is_relative_to(runtime) or output.exists():
        parser.error('Use a new output under this worktree runtime/agent-capacity')
    retained = json.loads(args.retained_report.read_text()) if args.retained_report else None
    report = run(args.reference_root, retained)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(f"Selected {len(report['selected_owners'])}/{report['matching_owners']} owners; "
          f"unresolved unwind {report['unresolved_unwind_records']}; incomplete {report['incomplete_records']}")


if __name__ == '__main__':
    main()
