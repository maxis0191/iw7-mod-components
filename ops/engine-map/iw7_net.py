#!/usr/bin/env python3
"""Read the network update record of a lab client, and the server's own per-client trace.

    report  CLIENT.json [--trace DIR_OR_FILE ...] [--json]    update rate, gaps, stalls, skipped updates, predicted lead; server ping
    compare A.json B.json [--json]                            the same client numbers for two runs, side by side

The client file is written by src/native/paris_net.cpp (schema iw7.net-client/1). The trace is written by
src/native/paris_incident.cpp on a lab server started with -paris-network-trace: JSON lines, the per-client sample is
the line of type "reliable_window". See docs/NET.md.
"""
import argparse
import glob
import json
import os
import statistics
import sys

CLIENT_SCHEMA = 'iw7.net-client/1'
SAMPLE_TYPE = 'reliable_window'
# Per-second fields of the server trace that describe backlog or pending commands, named as the source names them.
TRACE_FIELDS = ('pending', 'maximum_pending', 'ack_backlog_gate', 'negative_acks', 'moves_without_immediate_advance',
                'arrivals', 'move_calls', 'text_calls', 'binary_calls', 'requested_command_bytes')


class Refused(Exception):
    pass


def load(path):
    try:
        with open(path, encoding='utf-8') as f:
            doc = json.load(f)
    except (OSError, ValueError) as error:
        raise Refused('%s cannot be read as JSON: %s' % (path, error))
    if not isinstance(doc, dict) or doc.get('schema') != CLIENT_SCHEMA:
        raise Refused('%s is not a net client document (schema %s)' % (path, CLIENT_SCHEMA))
    return doc


def percentile(sorted_values, q):
    return sorted_values[min(len(sorted_values) - 1, int(q * len(sorted_values)))]


def numbers(doc, key):
    values = doc.get(key)
    return [v for v in values if isinstance(v, (int, float))] if isinstance(values, list) else []


def spread(values):
    """Median, minimum and maximum of a list, or None when it is empty."""
    if not values:
        return None
    return {'median': statistics.median(values), 'min': min(values), 'max': max(values)}


def client_stats(doc):
    seconds = float(doc.get('seconds') or 0.0)
    updates = int(doc.get('updates') or 0)
    gaps = sorted(v / 1000.0 for v in numbers(doc, 'gaps_us'))
    steps = numbers(doc, 'server_time_steps_ms')
    ahead = numbers(doc, 'ahead_ms')
    out = {'seconds': round(seconds, 3), 'passes': int(doc.get('passes') or 0), 'updates': updates,
           'updates_per_second': round(updates / seconds, 3) if seconds > 0 else None,
           'skipped_updates': int(doc.get('skipped_updates') or 0),
           'longest_passes_without_update': int(doc.get('longest_passes_without_update') or 0),
           'first_snapshot_num': doc.get('first_snapshot_num'), 'last_snapshot_num': doc.get('last_snapshot_num'),
           'truncated': bool(doc.get('truncated')), 'discontinuities': int(doc.get('discontinuities') or 0),
           'gap_ms': None, 'late_updates': None, 'stalls': None, 'server_step_ms_median': None, 'ahead_ms': None}
    if gaps:
        median = statistics.median(gaps)
        out['gap_ms'] = {'median': round(median, 3), 'p95': round(percentile(gaps, 0.95), 3), 'max': round(gaps[-1], 3)}
        out['late_updates'] = sum(1 for g in gaps if g > 2 * median) if median > 0 else 0
        out['stalls'] = sum(1 for g in gaps if g > 5 * median) if median > 0 else 0
    if steps:
        out['server_step_ms_median'] = statistics.median(steps)
    if ahead:
        out['ahead_ms'] = spread(ahead)
    return out


def num(value, digits=3):
    if value is None:
        return '-'
    if isinstance(value, float):
        return ('%.' + str(digits) + 'f') % value
    return str(value)


def client_lines(s):
    rate = '' if s['updates_per_second'] is None else ' (%s a second)' % num(s['updates_per_second'], 2)
    lines = ['client: %s s active, %d updates%s, %d passes of the main pipeline' % (num(s['seconds'], 1), s['updates'], rate, s['passes'])]
    if s['gap_ms'] is None:
        lines.append('no updates recorded')
    else:
        g = s['gap_ms']
        lines.append('gap between updates (ms): median %s  95th percentile %s  max %s' % (num(g['median']), num(g['p95']), num(g['max'])))
        lines.append('late updates (gap over twice the median): %d   stalls (gap over five times the median): %d' % (s['late_updates'], s['stalls']))
    lines.append('skipped updates (snapshot number jumps): %d' % s['skipped_updates'])
    if s['server_step_ms_median'] is not None:
        lines.append('server time step between updates (ms), median: %s' % num(s['server_step_ms_median']))
    if s['ahead_ms'] is not None:
        a = s['ahead_ms']
        lines.append('predicted time ahead of the latest server time (ms): median %s  min %s  max %s' % (num(a['median']), num(a['min']), num(a['max'])))
    lines.append('longest run of passes without a new update: %d' % s['longest_passes_without_update'])
    if s['discontinuities']:
        lines.append('numbering went backwards %d time(s): those updates have no gap or step' % s['discontinuities'])
    if s['truncated']:
        lines.append('the arrays reached their cap: later updates are counted but not in the gap, step or lead numbers')
    return lines


def trace_files(paths):
    files = []
    for path in paths:
        if os.path.isdir(path):
            files += sorted(glob.glob(os.path.join(path, '*.jsonl')))
        else:
            files.append(path)
    return files


def trace_stats(paths):
    """Per client slot: the ping of the server and the backlog fields, from the per-client sample lines only."""
    files = trace_files(paths)
    by_slot = {}
    for name in files:
        try:
            handle = open(name, encoding='utf-8')
        except OSError as error:
            raise Refused('%s cannot be read: %s' % (name, error))
        with handle:
            for raw in handle:
                try:
                    row = json.loads(raw)
                except ValueError:
                    continue
                if not isinstance(row, dict) or row.get('type') != SAMPLE_TYPE or not isinstance(row.get('slot'), int):
                    continue
                by_slot.setdefault(row['slot'], []).append(row)
    slots = {}
    for slot in sorted(by_slot):
        rows = by_slot[slot]
        entry = {'samples': len(rows), 'ping': None, 'fields': {}}
        pings = [r['ping'] for r in rows if isinstance(r.get('ping'), (int, float))]
        if pings:
            entry['ping'] = dict(spread(pings), samples=len(pings))
        for field in TRACE_FIELDS:
            values = [r[field] for r in rows if isinstance(r.get(field), (int, float))]
            if values:
                entry['fields'][field] = {'median': statistics.median(values), 'max': max(values)}
        # Derived from two named fields: how old the oldest unacknowledged reliable command was, in server time.
        ages = [r['server_time'] - r['oldest_pending_time'] for r in rows
                if isinstance(r.get('server_time'), int) and isinstance(r.get('oldest_pending_time'), int)]
        if ages:
            entry['fields']['server_time_minus_oldest_pending_time'] = {'median': statistics.median(ages), 'max': max(ages)}
        slots[str(slot)] = entry
    return {'files': len(files), 'samples': sum(len(v) for v in by_slot.values()), 'slots': slots}


def trace_lines(t):
    if not t['samples']:
        return ['server trace: no per-client samples in %d file(s)' % t['files']]
    lines = ['server trace: %d per-client samples from %d file(s)' % (t['samples'], t['files'])]
    for slot, e in t['slots'].items():
        lines.append('  slot %s: %d samples' % (slot, e['samples']))
        if e['ping'] is None:
            lines.append('    ping: not in this trace')
        else:
            p = e['ping']
            lines.append('    ping (ms): median %s  min %s  max %s  (%d samples)' % (num(p['median'], 1), num(p['min']), num(p['max']), p['samples']))
        for field, v in e['fields'].items():
            lines.append('    %s: median %s  max %s' % (field, num(v['median'], 1), num(v['max'])))
    return lines


def cmd_report(args):
    stats = client_stats(load(args.client))
    trace = trace_stats(args.trace) if args.trace else None
    if args.json:
        print(json.dumps({'client': stats, 'trace': trace}, indent=1))
        return 0
    lines = client_lines(stats)
    if trace is not None:
        lines += [''] + trace_lines(trace)
    print('\n'.join(lines))
    return 0


def flat(s):
    """The client numbers as rows of (name, value), the same rows for every run."""
    g, a = s['gap_ms'] or {}, s['ahead_ms'] or {}
    return [('seconds', s['seconds']), ('updates', s['updates']), ('updates per second', s['updates_per_second']),
            ('gap median (ms)', g.get('median')), ('gap 95th percentile (ms)', g.get('p95')), ('gap max (ms)', g.get('max')),
            ('late updates', s['late_updates']), ('stalls', s['stalls']), ('skipped updates', s['skipped_updates']),
            ('server time step median (ms)', s['server_step_ms_median']),
            ('ahead median (ms)', a.get('median')), ('ahead min (ms)', a.get('min')), ('ahead max (ms)', a.get('max')),
            ('longest passes without update', s['longest_passes_without_update'])]


def cmd_compare(args):
    a, b = client_stats(load(args.a)), client_stats(load(args.b))
    rows = []
    for (name, x), (_name, y) in zip(flat(a), flat(b)):
        difference = round(y - x, 3) if x is not None and y is not None else None
        rows.append({'what': name, 'a': x, 'b': y, 'difference': difference})
    if args.json:
        print(json.dumps({'a': a, 'b': b, 'rows': rows}, indent=1))
        return 0
    print('%-32s %14s %14s %14s' % ('', 'A', 'B', 'B minus A'))
    for r in rows:
        print('%-32s %14s %14s %14s' % (r['what'], num(r['a']), num(r['b']), num(r['difference'])))
    for label, s in (('A', a), ('B', b)):
        if s['gap_ms'] is None:
            print('%s: no updates recorded' % label)
        if s['truncated']:
            print('%s: the arrays reached their cap' % label)
    return 0


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    sub = p.add_subparsers(dest='cmd', required=True)
    s = sub.add_parser('report')
    s.add_argument('client')
    s.add_argument('--trace', nargs='+', default=[], metavar='DIR_OR_FILE')
    s.add_argument('--json', action='store_true')
    s.set_defaults(fn=cmd_report)
    s = sub.add_parser('compare')
    s.add_argument('a')
    s.add_argument('b')
    s.add_argument('--json', action='store_true')
    s.set_defaults(fn=cmd_compare)
    args = p.parse_args(argv)
    try:
        return args.fn(args)
    except Refused as error:
        print('iw7_net: %s' % error, file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
