#!/usr/bin/env python3
"""Read the freeze reports written by the lab build's hang reporter: where the main thread was stuck, in function names.

    report HANG.json [--map MAP.sqlite] [--json] [--top N]

The reporter (src/native/paris_hang.cpp) writes raw addresses. The engine map (iw7_engine_map.py) names them.
Exit code 2: the file is not a hang report, or it is truncated. See docs/HANG.md.
"""
import argparse
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import iw7_perf  # noqa: E402  (its Namer turns an address into a name)

SCHEMA = 'iw7.hang/1'
REQUIRED = ('pid', 'process', 'began_utc', 'frozen_ms', 'threshold_ms', 'still_frozen', 'image', 'main_thread', 'samples', 'others', 'modules')
MAX_FRAMES = 12
SIGNATURE_FRAMES = 2
OFFSET = re.compile(r'\+0x[0-9A-Fa-f]+$')


class ReportError(Exception):
    pass


def load(path):
    try:
        with open(path, encoding='utf-8') as f:
            doc = json.load(f)
    except OSError as e:
        raise ReportError('%s cannot be read: %s' % (path, e.strerror or e))
    except ValueError:
        raise ReportError('%s is truncated or is not JSON; it is not a complete hang report' % path)
    if not isinstance(doc, dict) or doc.get('schema') != SCHEMA:
        raise ReportError('%s is not a hang report (schema %s expected)' % (path, SCHEMA))
    missing = [k for k in REQUIRED if k not in doc]
    if missing:
        raise ReportError('%s is incomplete: missing %s' % (path, ', '.join(missing)))
    try:
        for row in doc['samples']:
            if len(row) != 3 or not isinstance(row[0], (int, float)):
                raise ValueError
        for row in doc['others']:
            if len(row) != 3:
                raise ValueError
        iw7_perf.Namer(doc, None)
    except (ValueError, TypeError, KeyError):
        raise ReportError('%s is incomplete or damaged' % path)
    return doc


def pcs_of(text):
    return [int(x, 16) for x in text.split(';') if x]


def plain(name):
    """A name without any '+0x<offset>' tail."""
    return OFFSET.sub('', name)


def named_frames(namer, stack, scan):
    """Leaf first: [leaf, caller, ...]. A leaf in the game is named through the map and followed by the game frames of
    the stack. A leaf outside the game is shown as [module] and followed by the nearest game code of the scan list."""
    pcs, scans = pcs_of(stack), pcs_of(scan)
    if not pcs:
        return []
    if namer.game(pcs[0]):
        names = [plain(namer.name(pc)) for pc in pcs]
    else:
        names = [plain(namer.name(pcs[0]))] + [plain(namer.name(pc)) for pc in scans]
    frames = []
    for name in names:                       # recursion and several addresses of one function collapse
        if not frames or frames[-1] != name:
            frames.append(name)
    return frames[:MAX_FRAMES]


def signature_of(frames):
    if not frames:
        return 'freeze (no sample of the main thread)'
    return 'freeze in ' + ' < '.join(frames[:1 + SIGNATURE_FRAMES])


def analyse(doc, namer):
    groups = {}
    order = []
    total = 0
    for ms, stack, scan in doc['samples']:
        frames = named_frames(namer, stack, scan)
        if not frames:
            continue
        total += 1
        key = tuple(frames)
        if key not in groups:
            groups[key] = {'frames': list(frames), 'samples': 0, 'from_ms': ms, 'to_ms': ms}
            order.append(key)
        g = groups[key]
        g['samples'] += 1
        g['from_ms'] = min(g['from_ms'], ms)
        g['to_ms'] = max(g['to_ms'], ms)
    stacks = [groups[k] for k in order]
    # The stack that covers most of the freeze: most samples, then the longest span, then the earliest.
    best = max(range(len(stacks)), key=lambda i: (stacks[i]['samples'], stacks[i]['to_ms'] - stacks[i]['from_ms'], -i)) if stacks else None
    for i, g in enumerate(stacks):
        g['share'] = round(g['samples'] / total, 4) if total else 0.0
        g['stuck_here'] = i == best
    stacks.sort(key=lambda g: (not g['stuck_here'], -g['samples'], g['from_ms']))
    others = []
    for thread, stack, scan in doc['others']:
        frames = named_frames(namer, stack, scan)
        others.append({'thread': thread, 'leaf': frames[0] if frames else '?', 'first_game_frame': frames[1] if len(frames) > 1 else None})
    signature = signature_of(stacks[0]['frames']) if stacks else signature_of([])
    return {'process': doc['process'], 'began_utc': doc['began_utc'], 'frozen_ms': doc['frozen_ms'], 'threshold_ms': doc['threshold_ms'],
            'still_frozen': bool(doc['still_frozen']), 'main_thread': doc['main_thread'], 'samples': total,
            'server_pipeline_frozen': doc.get('server_pipeline_frozen'), 'stacks': stacks, 'others': others, 'signature': signature}


def render(result, top):
    lines = ['freeze of the %s: %s ms (threshold %s ms), began %s%s' % (
        result['process'], result['frozen_ms'], result['threshold_ms'], result['began_utc'], '; still frozen when written' if result['still_frozen'] else ''),
        'main thread %s, %d samples' % (result['main_thread'], result['samples'])]
    if result['server_pipeline_frozen'] is not None:
        lines.append('server pipeline frozen: %s' % ('yes' if result['server_pipeline_frozen'] else 'no'))
    lines.append('')
    lines.append('Where the main thread was:')
    if not result['stacks']:
        lines.append('  no sample')
    for g in result['stacks'][:top]:
        lines.append('  %5.1f%%  %d sample%s  %s-%s ms%s' % (100.0 * g['share'], g['samples'], '' if g['samples'] == 1 else 's',
                                                           g['from_ms'], g['to_ms'], '   <- stuck here' if g['stuck_here'] else ''))
        lines += ['          ' + name for name in g['frames']]
    if len(result['stacks']) > top:
        lines.append('  (%d more stack%s not shown)' % (len(result['stacks']) - top, '' if len(result['stacks']) - top == 1 else 's'))
    lines.append('')
    lines.append('Other threads at the start: %d' % len(result['others']))
    for o in result['others']:
        lines.append('  thread %s: %s%s' % (o['thread'], o['leaf'], '  <-  ' + o['first_game_frame'] if o['first_game_frame'] else ''))
    lines.append('')
    lines.append('signature: ' + result['signature'])
    return '\n'.join(lines)


def cmd_report(args):
    try:
        doc = load(args.report)
    except ReportError as e:
        print(str(e), file=sys.stderr)
        return 2
    engine_map = iw7_perf.iw7_engine_map.Map(args.map) if args.map else None
    result = analyse(doc, iw7_perf.Namer(doc, engine_map))
    if args.json:
        print(json.dumps(result, indent=1))
    else:
        print(render(result, args.top))
    return 0


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    sub = p.add_subparsers(dest='cmd', required=True)
    s = sub.add_parser('report')
    s.add_argument('report', metavar='HANG.json')
    s.add_argument('--map')
    s.add_argument('--top', type=int, default=5, help='how many distinct stacks of the main thread to print')
    s.add_argument('--json', action='store_true')
    s.set_defaults(fn=cmd_report)
    args = p.parse_args(argv)
    return args.fn(args)


if __name__ == '__main__':
    sys.exit(main())
