#!/usr/bin/env python3
"""Read the windows written by the server meter of a lab dedicated server: server frame times, and which script
functions and which script threads cost the server's time.

    report  WINDOW.json [--top N] [--json]       frame statistics, script cost per function and per thread
    compare BASE.json CANDIDATE.json [--json]    what changed: frame time, and the script functions that grew most

The meter (src/native/paris_sperf.cpp) writes raw code positions of the script VM and the function table of the
loaded scripts; this tool names the positions. See docs/SERVER-PERF.md.

Costs are given in milliseconds per server frame: the share of the window the server thread spent in a function
(samples over sampler ticks) times the window's length, divided by the server frames of the window. The interval is
two standard deviations of a Poisson count.
"""
import argparse
import bisect
import json
import math
import statistics
import sys

SCHEMA = 'iw7.server-perf/1'


def load(path):
    with open(path, encoding='utf-8') as f:
        doc = json.load(f)
    if doc.get('schema') != SCHEMA:
        raise SystemExit('%s is not a server meter window' % path)
    return doc


class Scripts:
    """Code positions to 'file::function' through the function table of the window ("__end__" closes a file)."""

    def __init__(self, doc):
        rows = []
        for script in doc.get('scripts', []):
            for name, address in script['functions']:
                rows.append((int(address, 16), script['file'], name))
        rows.sort()
        self.starts = [r[0] for r in rows]
        self.rows = rows
        self.cache = {}

    def name(self, pos):
        got = self.cache.get(pos)
        if got is None:
            i = bisect.bisect_right(self.starts, pos) - 1
            if i < 0 or self.rows[i][2] == '__end__':
                got = 'unknown@%X' % pos
            else:
                got = '%s::%s' % (self.rows[i][1], self.rows[i][2])
            self.cache[pos] = got
        return got


def frame_stats(frames):
    """Server frame durations (time inside the engine's server frame function) and intervals, in milliseconds."""
    if not frames:
        return None
    dur = sorted(f[1] / 1000.0 for f in frames)
    n = len(dur)
    pick = lambda q: dur[min(n - 1, int(q * n))]
    starts = [f[0] for f in frames]
    gaps = [(b - a) / 1000.0 for a, b in zip(starts, starts[1:])]
    out = {'frames': n, 'mean_ms': round(sum(dur) / n, 4), 'median_ms': round(statistics.median(dur), 4),
           'p95_ms': round(pick(0.95), 4), 'p99_ms': round(pick(0.99), 4), 'max_ms': round(dur[-1], 3),
           'over_33ms': sum(1 for d in dur if d > 33.0)}
    if gaps:
        out['interval_median_ms'] = round(statistics.median(gaps), 3)
        out['interval_max_ms'] = round(max(gaps), 3)
        out['hz'] = round(len(gaps) / (sum(gaps) / 1000.0), 2) if sum(gaps) else 0
    return out


def profile(doc):
    """Samples per function (self: the running frame; inclusive: anywhere on the stack) and per thread (outermost frame)."""
    names = Scripts(doc)
    self_time, inclusive, threads, in_frame = {}, {}, {}, 0
    for count, frame, stack in doc.get('stacks', []):
        positions = [int(p, 16) for p in stack.split(';') if p]
        if not positions:
            continue
        labels = [names.name(p) for p in positions]
        self_time[labels[-1]] = self_time.get(labels[-1], 0) + count
        for label in set(labels):
            inclusive[label] = inclusive.get(label, 0) + count
        threads[labels[0]] = threads.get(labels[0], 0) + count
        if frame:
            in_frame += count
    return self_time, inclusive, threads, in_frame


def to_ms(count, doc, frames):
    """Samples to milliseconds per server frame, with a two-sigma interval."""
    ticks = doc['sampler']['ticks'] or 1
    scale = doc['seconds'] * 1000.0 / ticks / max(frames, 1)
    return count * scale, 2.0 * math.sqrt(count) * scale


def summary(doc, top=15):
    fs = frame_stats(doc.get('frames_us', []))
    frames = fs['frames'] if fs else 0
    self_time, inclusive, threads, in_frame = profile(doc)
    s = doc['sampler']

    def rows(table):
        out = []
        for name, count in sorted(table.items(), key=lambda kv: -kv[1])[:top]:
            ms, err = to_ms(count, doc, frames)
            out.append({'name': name, 'samples': count, 'ms_per_frame': round(ms, 4), 'pm': round(err, 4),
                        'share': round(count / (s['ticks'] or 1), 5)})
        return out

    script_ms, script_err = to_ms(s['script'], doc, frames)
    return {'name': doc['name'], 'seconds': round(doc['seconds'], 3), 'frames': fs,
            'sampler': {'ticks': s['ticks'], 'hz': s['hz'], 'script': s['script'], 'frame_no_script': s['frame_no_script'],
                        'idle': s['idle'], 'failures': s['failures'], 'dropped': s['dropped'],
                        'script_in_frame': in_frame},
            'script_ms_per_frame': round(script_ms, 4), 'script_pm': round(script_err, 4),
            'self': rows(self_time), 'inclusive': rows(inclusive), 'threads': rows(threads)}


def print_report(r):
    print('window %s: %.1f s' % (r['name'], r['seconds']))
    fs = r['frames']
    if fs:
        print('server frames %d  %.1f Hz  time in the frame: mean %.3f ms  median %.3f  p95 %.3f  p99 %.3f  max %.2f  over 33 ms: %d'
              % (fs['frames'], fs.get('hz', 0), fs['mean_ms'], fs['median_ms'], fs['p95_ms'], fs['p99_ms'], fs['max_ms'], fs['over_33ms']))
    else:
        print('no server frame in the window')
    s = r['sampler']
    print('sampler %.0f ticks a second, %d ticks: script %d, frame without script %d, idle %d, failed %d, dropped %d'
          % (s['hz'], s['ticks'], s['script'], s['frame_no_script'], s['idle'], s['failures'], s['dropped']))
    print('script on the server thread: %.3f ms per server frame (+-%.3f)' % (r['script_ms_per_frame'], r['script_pm']))
    for title, key in (('self time (the running function)', 'self'), ('inclusive time (on the stack)', 'inclusive'),
                       ('threads (outermost function)', 'threads')):
        print('  %s:' % title)
        for row in r[key]:
            print('    %8.3f ms/frame +-%.3f  %6.2f%%  %s' % (row['ms_per_frame'], row['pm'], 100 * row['share'], row['name']))


def compare(base_docs, cand_docs, top=10):
    """Pooled frame statistics a side, and the script functions whose self time per server frame changed most."""
    def side(docs):
        frames = [f for d in docs for f in d.get('frames_us', [])]
        tables = {'self': {}, 'threads': {}}
        ticks = seconds = 0
        for d in docs:
            st, _, th, _ = profile(d)
            for k, v in st.items():
                tables['self'][k] = tables['self'].get(k, 0) + v
            for k, v in th.items():
                tables['threads'][k] = tables['threads'].get(k, 0) + v
            ticks += d['sampler']['ticks']
            seconds += d['seconds']
        scale = seconds * 1000.0 / (ticks or 1) / max(len(frames), 1)
        return frame_stats(frames), tables, scale

    bf, bt, bs = side(base_docs)
    cf, ct, cs = side(cand_docs)
    out = {'base_frames': bf, 'candidate_frames': cf}
    if bf and cf:
        out['frame_mean_delta_ms'] = round(cf['mean_ms'] - bf['mean_ms'], 4)
        out['frame_median_delta_ms'] = round(cf['median_ms'] - bf['median_ms'], 4)
    for key in ('self', 'threads'):
        rows = []
        for name in set(bt[key]) | set(ct[key]):
            b, c = bt[key].get(name, 0), ct[key].get(name, 0)
            delta = c * cs - b * bs
            err = 2.0 * math.sqrt(c * cs * cs + b * bs * bs)
            rows.append({'name': name, 'base_ms': round(b * bs, 4), 'candidate_ms': round(c * cs, 4),
                         'delta_ms': round(delta, 4), 'pm': round(err, 4)})
        rows.sort(key=lambda r: -abs(r['delta_ms']))
        out[key] = rows[:top]
    grown = [r for r in out['self'] if r['delta_ms'] - r['pm'] > 0]
    out['largest_increase'] = max(grown, key=lambda r: r['delta_ms']) if grown else None
    return out


def print_compare(c):
    bf, cf = c['base_frames'], c['candidate_frames']
    if bf and cf:
        print('server frame: mean %.3f -> %.3f ms (%+.3f), median %.3f -> %.3f ms (%+.3f), p99 %.3f -> %.3f'
              % (bf['mean_ms'], cf['mean_ms'], c['frame_mean_delta_ms'], bf['median_ms'], cf['median_ms'],
                 c['frame_median_delta_ms'], bf['p99_ms'], cf['p99_ms']))
    for title, key in (('script functions, self time per server frame', 'self'), ('script threads', 'threads')):
        print('  %s:' % title)
        for r in c[key]:
            print('    %+8.3f ms +-%.3f  (%.3f -> %.3f)  %s' % (r['delta_ms'], r['pm'], r['base_ms'], r['candidate_ms'], r['name']))
    li = c['largest_increase']
    print('largest increase: %s' % ('%s %+.3f ms per server frame (+-%.3f)' % (li['name'], li['delta_ms'], li['pm']) if li else 'none beyond the noise'))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    r = sub.add_parser('report')
    r.add_argument('window')
    r.add_argument('--top', type=int, default=15)
    r.add_argument('--json', action='store_true')
    c = sub.add_parser('compare')
    c.add_argument('base', help='window(s), several separated by commas')
    c.add_argument('candidate', help='window(s), several separated by commas')
    c.add_argument('--top', type=int, default=10)
    c.add_argument('--json', action='store_true')
    args = ap.parse_args(argv)
    if args.cmd == 'report':
        result = summary(load(args.window), args.top)
        if args.json:
            print(json.dumps(result, indent=1))
        else:
            print_report(result)
    else:
        result = compare([load(p) for p in args.base.split(',') if p], [load(p) for p in args.candidate.split(',') if p], args.top)
        if args.json:
            print(json.dumps(result, indent=1))
        else:
            print_compare(result)
    return 0


if __name__ == '__main__':
    sys.exit(main())
