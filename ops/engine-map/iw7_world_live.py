#!/usr/bin/env python3
"""Read the prop list that the lab client's live world editor dumped from the running map (schema iw7.world-live/1).

    near FILE.json X Y Z [--radius R] [--top N]     props near a point, nearest first
    box FILE.json X1 Y1 Z1 X2 Y2 Z2 [--top N]       props whose origin is inside a box (corner order is free), by model
    models FILE.json [--top N]                      the most used models
    compare FILE.json --db WORLD.sqlite             same props as an independent on-disk reader? (table smodels)

The client writes the file with the console command `paris_world_dump` (src/native/paris_world.cpp). Exit code 2: the
file is not a world dump, is truncated, or the command line is wrong. Exit code 1: `compare` found a difference.
See docs/WORLD-LIVE.md.
"""
import argparse
import json
import math
import sqlite3
import sys
from collections import Counter

SCHEMA = 'iw7.world-live/1'
POSITION_TOLERANCE = 0.01


class DumpError(Exception):
    pass


def load(path):
    try:
        with open(path, encoding='utf-8') as f:
            doc = json.load(f)
    except OSError as e:
        raise DumpError('%s cannot be read: %s' % (path, e.strerror or e))
    except ValueError:
        raise DumpError('%s is truncated or is not JSON; it is not a complete world dump' % path)
    if not isinstance(doc, dict) or doc.get('schema') != SCHEMA:
        raise DumpError('%s is not a world dump (schema %s expected)' % (path, SCHEMA))
    props = doc.get('props')
    if not isinstance(props, list) or doc.get('count') != len(props):
        raise DumpError('%s is incomplete: count %r, %s props' % (path, doc.get('count'), len(props) if isinstance(props, list) else 'no'))
    for n, p in enumerate(props):
        if not isinstance(p, dict) or not isinstance(p.get('origin'), list) or len(p['origin']) != 3 or 'model' not in p:
            raise DumpError('%s: prop %d has no model or origin' % (path, n))
    return doc


def distance(p, point):
    o = p['origin']
    return math.sqrt(sum((o[k] - point[k]) ** 2 for k in range(3)))


def row(p, extra=''):
    o = p['origin']
    return '%6d  %-46s  (%9.2f %9.2f %9.2f)  scale %.3g  cull %s%s' % (p.get('i', -1), p['model'] or '(no model)', o[0], o[1], o[2], p.get('scale', 0), p.get('cull'), extra)


def cmd_near(args):
    doc = load(args.file)
    point = (args.x, args.y, args.z)
    ranked = sorted(((distance(p, point), p) for p in doc['props']), key=lambda t: (t[0], t[1].get('i', 0)))
    if args.radius is not None:
        ranked = [t for t in ranked if t[0] <= args.radius]
    shown = ranked[:args.top]
    print('%s: %d props in the dump, %d %s' % (doc['map'], doc['count'], len(ranked), 'within %g of the point' % args.radius if args.radius is not None else 'ranked'))
    for d, p in shown:
        print(row(p, '  dist %.2f' % d))
    if len(ranked) > len(shown):
        print('... %d more (raise --top)' % (len(ranked) - len(shown)))
    return 0


def cmd_box(args):
    doc = load(args.file)
    lo = [min(args.c[k], args.c[k + 3]) for k in range(3)]
    hi = [max(args.c[k], args.c[k + 3]) for k in range(3)]
    inside = [p for p in doc['props'] if all(lo[k] <= p['origin'][k] <= hi[k] for k in range(3))]
    print('%s: %d of %d props have their origin inside the box (%g,%g,%g)..(%g,%g,%g)' % (doc['map'], len(inside), doc['count'], *lo, *hi))
    for model, n in Counter(p['model'] for p in inside).most_common(args.top):
        print('%6d  %s' % (n, model or '(no model)'))
    return 0


def cmd_models(args):
    doc = load(args.file)
    counts = Counter(p['model'] for p in doc['props'])
    print('%s: %d props, %d distinct models' % (doc['map'], doc['count'], len(counts)))
    for model, n in counts.most_common(args.top):
        print('%6d  %s' % (n, model or '(no model)'))
    return 0


EXTRA_FIELDS = (
    ('cull', lambda p: [p.get('cull')], ['cullDist'], 0),
    ('flags', lambda p: [p.get('flags')], ['flags'], 0),
    ('scale', lambda p: [p.get('scale')], ['scale'], 1e-4),
    ('axis', lambda p: p.get('axis') or [None] * 9, ['a00', 'a01', 'a02', 'a10', 'a11', 'a12', 'a20', 'a21', 'a22'], 1e-4),
    ('bounds', lambda p: p.get('bounds') or [None] * 6, ['bmid_x', 'bmid_y', 'bmid_z', 'bhalf_x', 'bhalf_y', 'bhalf_z'], POSITION_TOLERANCE),
)
INDEX_NAMES = ('idx', 'index', 'i', 'smodel_index', 'smodel_idx', 'id')
MODEL_NAMES = ('model', 'model_name', 'name', 'xmodel')


def pick(columns, names):
    lowered = {c.lower(): c for c in columns}
    for n in names:
        if n in lowered:
            return lowered[n]
    return None


def cmd_compare(args):
    doc = load(args.file)
    try:
        con = sqlite3.connect('file:%s?mode=ro' % args.db.replace('\\', '/'), uri=True)
        cols = [r[1] for r in con.execute('PRAGMA table_info(smodels)')]
    except sqlite3.Error as e:
        print('%s cannot be read as a database: %s' % (args.db, e), file=sys.stderr)
        return 2
    if not cols:
        con.close()
        print('%s has no table smodels' % args.db, file=sys.stderr)
        return 2
    ci, cm = pick(cols, INDEX_NAMES), pick(cols, MODEL_NAMES)
    cx, cy, cz = (pick(cols, (n,)) for n in ('x', 'y', 'z'))
    if None in (ci, cm, cx, cy, cz):
        con.close()
        print('smodels has columns %s; need an index, a model name, x, y and z' % ', '.join(cols), file=sys.stderr)
        return 2
    # Fields that are compared when the database has them too: label, how to read the dump, database columns, tolerance.
    extras = [(label, getter, [pick(cols, (c.lower(),)) for c in names], tol) for label, getter, names, tol in EXTRA_FIELDS]
    extras = [e for e in extras if None not in e[2]]
    select = [ci, cm, cx, cy, cz] + [c for e in extras for c in e[2]]
    try:
        rows = {r[0]: r[1:] for r in con.execute('SELECT %s FROM smodels' % ','.join('"%s"' % c for c in select))}
    finally:
        con.close()
    live = {p.get('i', n): p for n, p in enumerate(doc['props'])}
    issues = []
    bad = len(rows) != len(live)
    if bad:
        issues.append('count: live %d, database %d' % (len(live), len(rows)))
    names = positions = 0
    worst = 0.0
    extra_bad = {e[0]: 0 for e in extras}
    for i, p in live.items():
        r = rows.get(i)
        if r is None:
            bad = True
            issues.append('index %d is not in the database' % i)
            continue
        if (r[0] or '') != (p['model'] or ''):
            names += 1
            if names <= 5:
                issues.append('index %d model: live %r, database %r' % (i, p['model'], r[0]))
        d = max(abs(p['origin'][0] - r[1]), abs(p['origin'][1] - r[2]), abs(p['origin'][2] - r[3]))
        worst = max(worst, d)
        if d > POSITION_TOLERANCE:
            positions += 1
            if positions <= 5:
                issues.append('index %d origin differs by %.4f' % (i, d))
        at = 4
        for label, getter, columns, tol in extras:
            live_values, db_values = getter(p), r[at:at + len(columns)]
            at += len(columns)
            if any(a is None or b is None or abs(a - b) > tol for a, b in zip(live_values, db_values)):
                extra_bad[label] += 1
                if extra_bad[label] <= 2:
                    issues.append('index %d %s: live %s, database %s' % (i, label, live_values, list(db_values)))
    print('compare: %d live props, %d database rows, %d model names differ, %d positions beyond %g (largest %.5f)' %
          (len(live), len(rows), names, positions, POSITION_TOLERANCE, worst))
    if extras:
        print('compare: also compared %s' % ', '.join('%s (%d differ)' % (k, v) for k, v in extra_bad.items()))
    for line in issues:
        print('  ' + line)
    return 1 if bad or names or positions or any(extra_bad.values()) else 0


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    sub = p.add_subparsers(dest='cmd', required=True)
    s = sub.add_parser('near')
    s.add_argument('file', metavar='FILE.json')
    for axis in 'xyz':
        s.add_argument(axis, type=float)
    s.add_argument('--radius', type=float)
    s.add_argument('--top', type=int, default=10)
    s.set_defaults(fn=cmd_near)
    s = sub.add_parser('box')
    s.add_argument('file', metavar='FILE.json')
    s.add_argument('c', type=float, nargs=6, metavar=('X1', 'Y1', 'Z1', 'X2', 'Y2', 'Z2'))
    s.add_argument('--top', type=int, default=10)
    s.set_defaults(fn=cmd_box)
    s = sub.add_parser('models')
    s.add_argument('file', metavar='FILE.json')
    s.add_argument('--top', type=int, default=10)
    s.set_defaults(fn=cmd_models)
    s = sub.add_parser('compare')
    s.add_argument('file', metavar='FILE.json')
    s.add_argument('--db', required=True)
    s.set_defaults(fn=cmd_compare)
    try:
        args = p.parse_args(argv)
    except SystemExit as e:
        return 2 if e.code else 0
    if getattr(args, 'radius', None) is not None and args.radius < 0 or getattr(args, 'top', 1) < 1:
        print('--radius must not be negative and --top must be at least 1', file=sys.stderr)
        return 2
    try:
        return args.fn(args)
    except DumpError as e:
        print(str(e), file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
