#!/usr/bin/env python3
"""Find where the game keeps a value by watching how it changes: read a memory recording of a lab client.

    find  FILE.bin [--width W] [--kind K] [--rate-min R] [--rate-max R] [--step-min S] [--step-max S] [--align N] [--top N] [--json]
    diff  A.bin B.bin [--width W] [--align N] [--top N] [--json]      offsets whose behaviour differs between two recordings
    show  FILE.bin --offset O [--width W] [--count N]                  the values of consecutive fields over all samples

The file is written by src/native/paris_watch.cpp (schema iw7.memory-watch/1): one JSON header line, then the raw
copies of the block back to back. See docs/MEMORY-WATCH.md.
"""
import argparse
import array
import json
import math
import mmap
import re
import struct
import sys

SCHEMA = 'iw7.memory-watch/1'
HEADER_LIMIT = 1 << 20
CODES = {1: 'b', 2: 'h', 4: 'i', 8: 'q'}
KINDS = ('counter', 'clock', 'changing', 'constant', 'float')
COUNTER_STEPS = (1, 8)
CLOCK_RATE = (500.0, 2000.0)
HELP_NOTE = ('The rate a recording can show is limited by its sampling interval: a value that changes 30 times a second, '
             'sampled 10 times a second, shows about 10 changes a second with a mean step of 3. Compare the total change per second '
             '(last value minus first value, divided by the time between them) with the rate you expect, not the number of changes.')


class Refused(Exception):
    pass


class Recording:
    """A memory recording: the header, and the samples as views into the memory-mapped file."""

    def __init__(self, path):
        self.path = path
        self._file = None
        self._map = None
        try:
            self._file = open(path, 'rb')
        except OSError as error:
            raise Refused('%s cannot be read: %s' % (path, error))
        try:
            self._load()
        except BaseException:
            self.close()
            raise

    def _load(self):
        path = self.path
        head = self._file.read(HEADER_LIMIT)
        newline = head.find(b'\n')
        if newline < 0:
            raise Refused('%s has no header line (truncated file or not a memory recording)' % path)
        try:
            header = json.loads(head[:newline].decode('utf-8'))
        except (ValueError, UnicodeDecodeError) as error:
            raise Refused('%s has a header that is not JSON: %s' % (path, error))
        if not isinstance(header, dict) or header.get('schema') != SCHEMA:
            raise Refused('%s is not a memory recording (schema %s)' % (path, SCHEMA))
        try:
            self.address = int(str(header['address']), 16)
            self.size = int(header['size'])
            self.count = int(header['count'])
            self.interval_ms = int(header['interval_ms'])
            self.qpc_hz = int(header['qpc_hz'])
            self.timestamps = [int(v) for v in header['timestamps']]
            self.unreadable = [int(v) for v in header['unreadable_pages']]
        except (KeyError, TypeError, ValueError) as error:
            raise Refused('%s has an incomplete header (%s)' % (path, error))
        self.pid = header.get('pid')
        if self.size < 1 or self.count < 1 or self.qpc_hz < 1:
            raise Refused('%s has an invalid header (size, count or qpc_hz)' % path)
        if len(self.timestamps) != self.count or len(self.unreadable) != self.count:
            raise Refused('%s has an invalid header: %d samples but %d timestamps and %d page counts'
                          % (path, self.count, len(self.timestamps), len(self.unreadable)))
        self.data_start = newline + 1
        expected = self.data_start + self.size * self.count
        self._file.seek(0, 2)
        actual = self._file.tell()
        if actual != expected:
            raise Refused('%s is %s: %d bytes, the header needs %d (%d samples of %d bytes)'
                          % (path, 'truncated' if actual < expected else 'longer than its header says', actual, expected, self.count, self.size))
        self._map = mmap.mmap(self._file.fileno(), 0, access=mmap.ACCESS_READ)
        self.view = memoryview(self._map)

    def close(self):
        view = getattr(self, 'view', None)
        if view is not None:
            self.view = None
            try:
                view.release()
            except BufferError:
                pass
        if self._map is not None:
            try:
                self._map.close()
            except BufferError:
                pass
            self._map = None
        if self._file is not None:
            self._file.close()
            self._file = None

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

    def sample(self, index):
        start = self.data_start + index * self.size
        return self.view[start:start + self.size]

    def used_samples(self, keep_unreadable=False):
        """Indices of the samples to use. A sample with more unreadable pages than the quietest sample has a hole the
        others do not have: its zeros are not values. A hole present in every sample stays (it is a fixed part of the block)."""
        indices = list(range(self.count))
        if keep_unreadable or not self.unreadable:
            return indices, []
        baseline = min(self.unreadable)
        kept = [i for i in indices if self.unreadable[i] <= baseline]
        if len(kept) < 2:
            return indices, []
        return kept, [i for i in indices if self.unreadable[i] > baseline]


def rows_for(rec, indices, width, kind_float, phase):
    """One typed view per used sample, starting `phase` bytes into the block: element k is the value at offset phase + k * width."""
    code = 'f' if kind_float else CODES[width]
    usable = (rec.size - phase) // width * width
    rows = []
    for i in indices:
        raw = rec.sample(i)[phase:phase + usable]
        view = raw.cast(code)
        if sys.byteorder == 'big':
            swapped = array.array(code, view.tolist())
            swapped.byteswap()
            view = swapped
        rows.append(view)
    return rows


def candidate_offsets(rec, indices, width, align):
    """Aligned offsets whose bytes differ in some used sample. Everything else is constant. Returns (offsets, total aligned offsets)."""
    total = (rec.size - width) // align + 1 if rec.size >= width else 0
    if len(indices) < 2:
        return [], total
    first = int.from_bytes(rec.sample(indices[0]), 'little')
    mask = 0
    for i in indices[1:]:
        mask |= first ^ int.from_bytes(rec.sample(i), 'little')
    if not mask:
        return [], total
    flags = mask.to_bytes(rec.size, 'little')
    offsets = []
    last = -1
    top = rec.size - width
    for run in re.finditer(rb'[^\x00]+', flags):
        # A field at offset o covers bytes o .. o + width - 1: it changed when any of them did.
        low = max(0, run.start() - width + 1, last + 1)
        high = min(run.end() - 1, top)
        if low % align:
            low += align - low % align
        if low > high:
            continue
        offsets.extend(range(low, high + 1, align))
        last = offsets[-1]
    return offsets, total


def column_stats(values, seconds, kind_float):
    """Behaviour of one field over the used samples. `seconds` are the sample times in seconds from the first used sample."""
    deltas = [b - a for a, b in zip(values, values[1:])]
    changed = [d for d in deltas if d != 0]
    elapsed = seconds[-1] - seconds[0]
    total = values[-1] - values[0]
    stats = {
        'first': values[0],
        'last': values[-1],
        'changes': len(changed),
        'never_decreased': (min(deltas) >= 0) if deltas else True,
        'total_change': total,
        'total_change_per_second': (total / elapsed) if elapsed > 0 else 0.0,
        'changes_per_second': (len(changed) / elapsed) if elapsed > 0 else 0.0,
        'mean_step': (total / len(changed)) if changed else 0,
        'min_step': min(changed) if changed else 0,
        'max_step': max(changed) if changed else 0,
        'samples': len(values),
    }
    if kind_float:
        stats['finite'] = all(math.isfinite(v) for v in values)
    return stats


def sample_seconds(rec, indices):
    base = rec.timestamps[indices[0]]
    return [(rec.timestamps[i] - base) / rec.qpc_hz for i in indices]


def classify(stats, kind, opts):
    """True when the field fits the kind and the filters. Rates are totals per second (see HELP_NOTE)."""
    rate = abs(stats['total_change_per_second'])
    n = stats['samples']
    changes = stats['changes']
    low, high = opts.step_min, opts.step_max
    if kind == 'counter':
        if not stats['never_decreased'] or changes < 3:
            return False
        low = COUNTER_STEPS[0] if low is None else low
        high = COUNTER_STEPS[1] if high is None else high
    elif kind == 'clock':
        if not stats['never_decreased'] or changes < 0.6 * (n - 1) or not (CLOCK_RATE[0] <= rate <= CLOCK_RATE[1]):
            return False
    elif kind == 'changing':
        if changes < 3:
            return False
    elif kind == 'float':
        if changes < 3 or not stats.get('finite', False):
            return False
    if changes and ((low is not None and stats['min_step'] < low) or (high is not None and stats['max_step'] > high)):
        return False
    if opts.rate_min is not None and rate < opts.rate_min:
        return False
    if opts.rate_max is not None and rate > opts.rate_max:
        return False
    return True


def scan(rec, width, align, kind_float, keep_unreadable):
    """Behaviour of every field that changed in some used sample. Returns (list of (offset, stats), constant count, total, used, dropped)."""
    indices, dropped = rec.used_samples(keep_unreadable)
    offsets, total = candidate_offsets(rec, indices, width, align)
    seconds = sample_seconds(rec, indices)
    cache = {}
    found = []
    for offset in offsets:
        phase = offset % width
        rows = cache.get(phase)
        if rows is None:
            rows = cache[phase] = rows_for(rec, indices, width, kind_float, phase)
        index = offset // width
        found.append((offset, column_stats([row[index] for row in rows], seconds, kind_float)))
    for rows in cache.values():
        for row in rows:
            if isinstance(row, memoryview):
                row.release()
    return found, total - len(offsets), total, indices, dropped


def behaviour_class(stats, opts):
    if stats is None or stats['changes'] == 0:
        return 'constant'
    for kind in ('counter', 'clock'):
        if classify(stats, kind, opts):
            return kind
    return 'changing'


def num(value, places=3):
    if value is None:
        return '-'
    if isinstance(value, float):
        if not math.isfinite(value):
            return str(value)
        return ('%.' + str(places) + 'f') % value
    return str(value)


def check_width(args, kind):
    width = args.width
    if kind == 'float':
        if width not in (None, 4):
            raise Refused('--kind float reads 32-bit floats: use --width 4')
        width = 4
    return 4 if width is None else width


def check_align(args, width):
    align = args.align if args.align is not None else width
    if align < 1:
        raise Refused('--align must be at least 1')
    return align


def cmd_find(args):
    kind = args.kind
    width = check_width(args, kind)
    align = check_align(args, width)
    with Recording(args.file) as rec:
        if rec.size < width:
            raise Refused('%s: the block (%d bytes) is smaller than --width %d' % (args.file, rec.size, width))
        found, constants, total, indices, dropped = scan(rec, width, align, kind == 'float', args.keep_unreadable)
        if len(indices) < 2:
            raise Refused('%s has fewer than 2 usable samples' % args.file)
        elapsed = sample_seconds(rec, indices)[-1]
        head = {'file': args.file, 'address': '%X' % rec.address, 'size': rec.size, 'samples': rec.count, 'samples_used': len(indices),
                'dropped_samples': dropped, 'interval_ms': rec.interval_ms, 'seconds': elapsed, 'width': width, 'align': align, 'kind': kind}
        if kind == 'constant':
            result = {'header': head, 'constant_offsets': constants, 'aligned_offsets': total}
            if args.json:
                print(json.dumps(result, indent=1))
            else:
                print(describe(head))
                print('constant (never changed): %d of %d aligned offsets' % (constants, total))
            return 0
        matches = [(offset, stats) for offset, stats in found if classify(stats, kind, args)]
        target = None
        if args.rate_min is not None and args.rate_max is not None:
            target = (args.rate_min + args.rate_max) / 2.0
        elif args.rate_min is not None:
            target = args.rate_min
        elif args.rate_max is not None:
            target = args.rate_max
        if target is not None:
            matches.sort(key=lambda item: (abs(abs(item[1]['total_change_per_second']) - target), item[0]))
        shown = matches[:args.top]
        rows = [row(rec, offset, stats) for offset, stats in shown]
        if args.json:
            print(json.dumps({'header': head, 'matches': len(matches), 'candidates': rows, 'note': HELP_NOTE}, indent=1))
            return 0
        print(describe(head))
        if not matches:
            print('no field matches')
        else:
            print('%-10s %-9s %-14s %14s %14s %8s %12s %10s' % ('offset', 'decimal', 'address', 'first', 'last', 'changes', 'total/s', 'mean step'))
            for r in rows:
                print('%-10s %-9d %-14s %14s %14s %8d %12s %10s' % ('0x%X' % r['offset'], r['offset'], r['address'], num(r['first'], 4), num(r['last'], 4),
                                                                    r['changes'], num(r['total_change_per_second'], 2), num(r['mean_step'], 2)))
            print('%d match(es)%s' % (len(matches), ', showing %d' % len(shown) if len(shown) < len(matches) else ''))
        print('Note: ' + HELP_NOTE)
    return 0


def describe(head):
    line = '%s: block %s, %d bytes, %d samples (%d used) every %d ms, %.3f s; width %d, align %d, kind %s' % (
        head['file'], head['address'], head['size'], head['samples'], head['samples_used'], head['interval_ms'], head['seconds'],
        head['width'], head['align'], head['kind'])
    if head['dropped_samples']:
        line += '\nnot used: samples %s have more unreadable pages than the others (--keep-unreadable uses them)' % ','.join(str(i) for i in head['dropped_samples'])
    return line


def row(rec, offset, stats):
    return {'offset': offset, 'address': '%X' % (rec.address + offset), 'first': stats['first'], 'last': stats['last'],
            'changes': stats['changes'], 'total_change': stats['total_change'], 'total_change_per_second': stats['total_change_per_second'],
            'changes_per_second': stats['changes_per_second'], 'mean_step': stats['mean_step'],
            'min_step': stats['min_step'], 'max_step': stats['max_step']}


def cmd_diff(args):
    width = check_width(args, None)
    align = check_align(args, width)
    with Recording(args.a) as a, Recording(args.b) as b:
        if (a.address, a.size) != (b.address, b.size):
            raise Refused('the recordings are of different blocks: %X+%d and %X+%d' % (a.address, a.size, b.address, b.size))
        if a.size < width:
            raise Refused('the block (%d bytes) is smaller than --width %d' % (a.size, width))
        found_a, _c, total, used_a, _d = scan(a, width, align, False, args.keep_unreadable)
        found_b, _c, _t, used_b, _d = scan(b, width, align, False, args.keep_unreadable)
        if len(used_a) < 2 or len(used_b) < 2:
            raise Refused('a recording has fewer than 2 usable samples')
        stats_a, stats_b = dict(found_a), dict(found_b)
        differing = []
        for offset in sorted(set(stats_a) | set(stats_b)):
            sa, sb = stats_a.get(offset), stats_b.get(offset)
            ca, cb = behaviour_class(sa, args), behaviour_class(sb, args)
            if ca != cb:
                differing.append((offset, ca, cb, sa, sb))
        shown = differing[:args.top]

        def side(s):
            return None if s is None else {'first': s['first'], 'last': s['last'], 'changes': s['changes'], 'total_change_per_second': s['total_change_per_second']}
        rows = [{'offset': o, 'address': '%X' % (a.address + o), 'a': ca, 'b': cb, 'a_values': side(sa), 'b_values': side(sb)} for o, ca, cb, sa, sb in shown]
        if args.json:
            print(json.dumps({'address': '%X' % a.address, 'size': a.size, 'width': width, 'aligned_offsets': total, 'differing': len(differing), 'offsets': rows}, indent=1))
            return 0
        print('A %s: %d samples (%d used); B %s: %d samples (%d used); block %X, %d bytes; width %d, align %d'
              % (args.a, a.count, len(used_a), args.b, b.count, len(used_b), a.address, a.size, width, align))
        if not differing:
            print('no offset behaves differently')
        else:
            print('%-10s %-14s %-10s %-10s %12s %12s' % ('offset', 'address', 'A', 'B', 'A total/s', 'B total/s'))
            for r in rows:
                print('%-10s %-14s %-10s %-10s %12s %12s' % ('0x%X' % r['offset'], r['address'], r['a'], r['b'],
                                                            num(r['a_values']['total_change_per_second'], 2) if r['a_values'] else '-',
                                                            num(r['b_values']['total_change_per_second'], 2) if r['b_values'] else '-'))
            print('%d offset(s) differ%s' % (len(differing), ', showing %d' % len(shown) if len(shown) < len(differing) else ''))
        print('Classes: constant, counter (never decreases, steps 1 to 8), clock (a millisecond clock), changing (anything else that changed).')
    return 0


def cmd_show(args):
    width = 4 if args.width is None else args.width
    offset = args.offset
    if args.float and width != 4:
        raise Refused('--float reads 32-bit floats: use --width 4')
    with Recording(args.file) as rec:
        if offset < 0 or offset + width > rec.size:
            raise Refused('offset 0x%X with width %d is outside the block of %d bytes' % (offset, width, rec.size))
        count = max(1, min(args.count, (rec.size - offset) // width))
        code = 'f' if args.float else CODES[width]
        fmt = '<%d%s' % (count, code)
        base = rec.timestamps[0]
        rows = []
        for i in range(rec.count):
            raw = bytes(rec.sample(i)[offset:offset + count * width])
            rows.append({'sample': i, 'seconds': (rec.timestamps[i] - base) / rec.qpc_hz, 'unreadable_pages': rec.unreadable[i],
                         'values': list(struct.unpack(fmt, raw))})
        if args.json:
            print(json.dumps({'file': args.file, 'address': '%X' % (rec.address + offset), 'offset': offset, 'width': width, 'rows': rows}, indent=1))
            return 0
        print('%s: offset 0x%X (%d), address %X, %d field(s) of %d bytes' % (args.file, offset, offset, rec.address + offset, count, width))
        print('%-6s %9s %6s  %s' % ('sample', 'seconds', 'holes', '  '.join('%+d' % (k * width) for k in range(count))))
        for r in rows:
            if args.hex and not args.float:
                cells = ['%0*X' % (width * 2, v & ((1 << (width * 8)) - 1)) for v in r['values']]
            else:
                cells = [num(v, 4) if args.float else str(v) for v in r['values']]
            print('%-6d %9.3f %6d  %s' % (r['sample'], r['seconds'], r['unreadable_pages'], '  '.join(cells)))
    return 0


def int_arg(text):
    try:
        return int(text, 0)
    except ValueError:
        raise argparse.ArgumentTypeError('%r is not a number' % text)


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split('\n')[0], epilog=HELP_NOTE)
    sub = p.add_subparsers(dest='cmd', required=True)

    def common(s):
        s.add_argument('--width', type=int, choices=(1, 2, 4, 8), default=None, help='field width in bytes (default 4; 4 for --kind float)')
        s.add_argument('--align', type=int, default=None, help='only offsets that are a multiple of this (default: the width)')
        s.add_argument('--top', type=int, default=40, help='most lines to show (default 40)')
        s.add_argument('--json', action='store_true')
        s.add_argument('--keep-unreadable', action='store_true',
                       help='use samples that have more unreadable pages than the quietest sample (by default they are left out)')

    s = sub.add_parser('find', help='list the fields that behave as asked', epilog=HELP_NOTE)
    s.add_argument('file')
    common(s)
    s.add_argument('--kind', choices=KINDS, default='changing',
                   help='counter: never decreases, changed at least 3 times, every step between --step-min (1) and --step-max (8). '
                        'clock: never decreases, changed in 60 percent of the intervals, 500 to 2000 per second. changing: changed at least 3 times. '
                        'constant: never changed (a count only). float: 32-bit floats, finite, changed at least 3 times. Default: changing')
    s.add_argument('--rate-min', type=float, default=None,
                   help='least total change per second (last minus first, over the time between them; absolute value). This is the rate to compare with an expected one, not changes per second')
    s.add_argument('--rate-max', type=float, default=None, help='most total change per second (see --rate-min)')
    s.add_argument('--step-min', type=float, default=None, help='least signed step of a change (counter default 1)')
    s.add_argument('--step-max', type=float, default=None, help='most signed step of a change (counter default 8)')
    s.set_defaults(fn=cmd_find)

    s = sub.add_parser('diff', help='offsets whose behaviour class differs between two recordings of the same block')
    s.add_argument('a')
    s.add_argument('b')
    common(s)
    s.set_defaults(fn=cmd_diff, step_min=None, step_max=None, rate_min=None, rate_max=None)

    s = sub.add_parser('show', help='the values of consecutive fields from one offset, one row per sample')
    s.add_argument('file')
    s.add_argument('--offset', type=int_arg, required=True, help='byte offset in the block (decimal or 0x hex)')
    s.add_argument('--width', type=int, choices=(1, 2, 4, 8), default=None, help='field width in bytes (default 4)')
    s.add_argument('--count', type=int, default=8, help='number of consecutive fields (default 8)')
    s.add_argument('--float', action='store_true', help='read 32-bit floats')
    s.add_argument('--hex', action='store_true', help='print integers as unsigned hex')
    s.add_argument('--json', action='store_true')
    s.set_defaults(fn=cmd_show)

    args = p.parse_args(argv)
    try:
        if getattr(args, 'top', 1) < 1:
            raise Refused('--top must be at least 1')
        return args.fn(args)
    except Refused as error:
        print('iw7_watch: %s' % error, file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
