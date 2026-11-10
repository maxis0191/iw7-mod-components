#!/usr/bin/env python3
"""Read the windows written by the client's performance recorder: frame times, and where the threads spend their time.

    report  WINDOW.json --map MAP.sqlite      frame statistics and the functions of the game that cost the most
    compare BASE.json CANDIDATE.json [...]    is the candidate faster, by how much, and how sure is that
    folded  WINDOW.json --map MAP.sqlite      call stacks in the folded format flame-graph tools read

The recorder (src/native/paris_perf.cpp) writes raw addresses. The engine map (iw7_engine_map.py) names them.
See docs/PERF.md.
"""
import argparse
import json
import os
import random
import statistics
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import iw7_engine_map  # noqa: E402

WAITING = ('ntdll.dll', 'win32u.dll', 'kernelbase.dll', 'kernel32.dll', 'user32.dll')


def load(path):
    with open(path, encoding='utf-8') as f:
        doc = json.load(f)
    if doc.get('schema') != 'iw7.perf-window/1':
        raise SystemExit('%s is not a recorder window' % path)
    return doc


def frame_stats(frames_us):
    """Frame-time statistics in milliseconds. A frame rate is frames over time, never the mean of rates."""
    if not frames_us:
        return None
    ms = sorted(f / 1000.0 for f in frames_us)
    n = len(ms)
    pick = lambda q: ms[min(n - 1, int(q * n))]
    total = sum(ms)
    worst = ms[int(n * 0.99):] or ms[-1:]
    return {'frames': n, 'seconds': round(total / 1000.0, 3), 'fps': round(n / (total / 1000.0), 2), 'median_ms': round(statistics.median(ms), 4),
            'p95_ms': round(pick(0.95), 4), 'p99_ms': round(pick(0.99), 4), 'max_ms': round(ms[-1], 3),
            'low_1pct_fps': round(1000.0 / (sum(worst) / len(worst)), 2),
            'over_2x_median': sum(1 for v in ms if v > 2 * statistics.median(ms))}


class Namer:
    """Addresses to names: a game function through the engine map, anything else by its module."""

    def __init__(self, doc, engine_map):
        self.map = engine_map
        self.text = (int(doc['image']['text_begin'], 16), int(doc['image']['text_end'], 16))
        self.modules = sorted((int(m['base'], 16), m['size'], m['name']) for m in doc.get('modules', []))
        self.cache = {}

    def game(self, pc):
        return self.text[0] <= pc < self.text[1]

    def module(self, pc):
        for base, size, name in self.modules:
            if base <= pc < base + size:
                return name
        return 'unknown'

    def name(self, pc):
        got = self.cache.get(pc)
        if got is None:
            if self.game(pc):
                f = self.map.func(pc) if self.map else None
                got = self.map.label(f) if f is not None else 'game+%X' % (pc - 0x140000000)
            else:
                got = '[%s]' % self.module(pc)
            self.cache[pc] = got
        return got


def profile(doc, namer, role):
    """For the threads of one role: samples, self time by name, inclusive time by game function, and the callers of system time."""
    index = {i for i, t in enumerate(doc['threads']) if t['role'] == role}
    total, self_time, inclusive, via, waiting = 0, {}, {}, {}, 0
    for thread, count, stack, scan in doc['stacks']:
        if thread not in index:
            continue
        pcs = [int(x, 16) for x in stack.split(';') if x]
        total += count
        leaf = namer.name(pcs[0])
        if not namer.game(pcs[0]) and namer.module(pcs[0]).lower() in WAITING:
            waiting += count
        self_time[leaf] = self_time.get(leaf, 0) + count
        seen = set()
        for pc in pcs:
            if namer.game(pc):
                seen.add(namer.name(pc))
        if not namer.game(pcs[0]) and scan:
            first = namer.name(int(scan.split(';')[0], 16))             # nearest game code on the stack of a system sample
            via[(leaf, first)] = via.get((leaf, first), 0) + count
        for name in seen:
            inclusive[name] = inclusive.get(name, 0) + count
    cpu = sum(t['user_ms'] + t['kernel_ms'] for i, t in enumerate(doc['threads']) if i in index)
    return {'role': role, 'threads': len(index), 'samples': total, 'cpu_ms': round(cpu, 1), 'waiting_share': round(waiting / total, 4) if total else 0,
            'self': sorted(self_time.items(), key=lambda kv: -kv[1]), 'inclusive': sorted(inclusive.items(), key=lambda kv: -kv[1]),
            'via': sorted(via.items(), key=lambda kv: -kv[1])}


def cmd_report(args):
    doc = load(args.window)
    m = iw7_engine_map.Map(args.map) if args.map else None
    namer = Namer(doc, m)
    out = {'name': doc['name'], 'frames': frame_stats(doc['frames_us']), 'sampler': doc['sampler'], 'memory': doc['memory'], 'roles': []}
    lines = ['window %s: %.1f s' % (doc['name'], doc['seconds'])]
    f = out['frames']
    if f:
        lines.append('frames %d  %.1f fps  median %.3f ms  p95 %.3f  p99 %.3f  max %.2f  1%% low %.1f fps  frames over twice the median: %d' % (
            f['frames'], f['fps'], f['median_ms'], f['p95_ms'], f['p99_ms'], f['max_ms'], f['low_1pct_fps'], f['over_2x_median']))
    seconds = doc['seconds'] or 1
    lines.append('sampler %.0f ticks a second, %d samples, %d dropped; memory %.0f MB private' % (
        doc['sampler']['hz'], doc['sampler']['samples'], doc['sampler']['dropped'], doc['memory']['private'] / 2 ** 20))
    for role in ('main', 'render', 'other'):
        p = profile(doc, namer, role)
        out['roles'].append(p)
        if not p['samples']:
            continue
        lines.append('')
        lines.append('%s thread%s: %d, CPU %.0f ms (%.0f%% of one core), %d samples, %.0f%% of them waiting in the system' % (
            role, '' if p['threads'] == 1 else 's', p['threads'], p['cpu_ms'], 100.0 * p['cpu_ms'] / (seconds * 1000.0), p['samples'], 100.0 * p['waiting_share']))
        lines.append('  self time (where the thread was):')
        lines += ['    %5.1f%%  %s' % (100.0 * n / p['samples'], name) for name, n in p['self'][:args.top]]
        lines.append('  inclusive time (game functions on the stack):')
        lines += ['    %5.1f%%  %s' % (100.0 * n / p['samples'], name) for name, n in p['inclusive'][:args.top]]
        if p['via']:
            lines.append('  system time, by the nearest game code on the stack:')
            lines += ['    %5.1f%%  %s  <-  %s' % (100.0 * n / p['samples'], leaf, game) for (leaf, game), n in p['via'][:max(5, args.top // 2)]]
    if args.json:
        for p in out['roles']:
            p['self'], p['inclusive'] = p['self'][:200], p['inclusive'][:200]
            p['via'] = [[leaf, game, n] for (leaf, game), n in p['via'][:200]]
        print(json.dumps(out, indent=1))
    else:
        print('\n'.join(lines))
    return 0


def bootstrap(a, b, stat, rounds=600, seed=7):
    """95 % interval of stat(b) / stat(a) - 1, by resampling blocks of frames (frame times are not independent)."""
    rng = random.Random(seed)

    def blocks(x, size=50):
        return [x[i:i + size] for i in range(0, len(x), size)] or [x]

    ba, bb = blocks(a), blocks(b)
    out = []
    for _ in range(rounds):
        ra = [v for _ in ba for v in rng.choice(ba)]
        rb = [v for _ in bb for v in rng.choice(bb)]
        out.append(stat(rb) / stat(ra) - 1.0)
    out.sort()
    return out[int(0.025 * rounds)], out[int(0.975 * rounds)]


def cmd_compare(args):
    """Frame times of candidate windows against base windows. Several files on a side are repeats of the same scene."""
    base = [load(p) for p in args.base.split(',')]
    cand = [load(p) for p in args.candidate.split(',')]
    a = [f / 1000.0 for d in base for f in d['frames_us']]
    b = [f / 1000.0 for d in cand for f in d['frames_us']]
    if len(a) < 200 or len(b) < 200:
        raise SystemExit('too few frames to compare (%d and %d)' % (len(a), len(b)))
    p99 = lambda x: sorted(x)[int(0.99 * len(x))]
    mean = lambda x: sum(x) / len(x)
    rows = []
    for label, stat in (('mean frame time', mean), ('median frame time', statistics.median), ('99th percentile frame time', p99)):
        lo, hi = bootstrap(a, b, stat)
        change = stat(b) / stat(a) - 1.0
        verdict = 'faster' if hi < 0 else 'slower' if lo > 0 else 'no difference shown'
        rows.append({'what': label, 'base_ms': round(stat(a), 4), 'candidate_ms': round(stat(b), 4), 'change': round(change, 4), 'low': round(lo, 4), 'high': round(hi, 4), 'verdict': verdict})
    # Run-to-run spread: when each side has repeats, the difference must also exceed what repeats of one side show.
    spread = None
    if len(base) > 1:
        med = [statistics.median(d['frames_us']) for d in base]
        spread = (max(med) - min(med)) / statistics.median(med)
    out = {'base_windows': len(base), 'candidate_windows': len(cand), 'base_fps': round(len(a) / (sum(a) / 1000.0), 2), 'candidate_fps': round(len(b) / (sum(b) / 1000.0), 2),
           'rows': rows, 'base_run_to_run_spread': round(spread, 4) if spread is not None else None}
    if args.json:
        print(json.dumps(out, indent=1))
        return 0
    print('base %d window(s) %.1f fps; candidate %d window(s) %.1f fps' % (len(base), out['base_fps'], len(cand), out['candidate_fps']))
    for r in rows:
        print('  %-28s %8.4f -> %8.4f ms  %+6.2f%%  (95%% interval %+.2f%% .. %+.2f%%)  %s' % (
            r['what'], r['base_ms'], r['candidate_ms'], 100 * r['change'], 100 * r['low'], 100 * r['high'], r['verdict']))
    if spread is not None:
        print('  repeats of the base differ by %.2f%% in median frame time: a smaller change than that is not established' % (100 * spread))
    else:
        print('  one window a side: this interval covers frame-to-frame noise only, not run-to-run differences; repeat each side to be sure')
    return 0


def cmd_folded(args):
    doc = load(args.window)
    namer = Namer(doc, iw7_engine_map.Map(args.map) if args.map else None)
    roles = {i: t['role'] for i, t in enumerate(doc['threads'])}
    total = {}
    for thread, count, stack, _scan in doc['stacks']:
        if args.role and roles.get(thread) != args.role:
            continue
        names = [namer.name(int(x, 16)) for x in stack.split(';') if x]
        key = ';'.join([roles.get(thread, '?')] + names[::-1])
        total[key] = total.get(key, 0) + count
    for key, n in sorted(total.items(), key=lambda kv: -kv[1])[:args.max]:
        print('%s %d' % (key, n))
    return 0


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    sub = p.add_subparsers(dest='cmd', required=True)
    s = sub.add_parser('report')
    s.add_argument('window')
    s.add_argument('--map')
    s.add_argument('--top', type=int, default=15)
    s.add_argument('--json', action='store_true')
    s.set_defaults(fn=cmd_report)
    s = sub.add_parser('compare')
    s.add_argument('base', help='one window file, or several separated by commas (repeats of the same scene)')
    s.add_argument('candidate')
    s.add_argument('--json', action='store_true')
    s.set_defaults(fn=cmd_compare)
    s = sub.add_parser('folded')
    s.add_argument('window')
    s.add_argument('--map')
    s.add_argument('--role', choices=('main', 'render', 'other'))
    s.add_argument('--max', type=int, default=100000)
    s.set_defaults(fn=cmd_folded)
    args = p.parse_args(argv)
    return args.fn(args)


if __name__ == '__main__':
    sys.exit(main())
