"""Diff of two write censuses (components src/native/paris_write_census.cpp): which writers of an object only exist, or reach further, at the larger agent count.

    python -I -B ops/engine/census_diff.py <census at 24 (or 56) agents.tsv> <census at 264 agents.tsv> [--db <engine database>] [--min-rows N]

A census line is one writing instruction (RIP, relative to the game image) of one region (`cg`, `abs_<address>`) with the number of stores, the number of distinct offsets seen (up to 128),
the lowest and highest offset and the gcd of the differences of the sampled offsets (the stride when it is a table). Classes of the diff:

  only_big   the writer does not appear in the small census: code that runs only with the larger count (or was not reached by the smaller scene): read it
  reaches    the writer appears in both and its highest offset (or its number of distinct offsets) is larger in the big census: a table with more rows than the small scene reached
  same       the same offset range
  only_small the writer appears only in the small census (the scene differs)

A `reaches` or `only_big` writer with a stride >= 4 and 20 or more distinct offsets is a table indexed by a number that grew with the count (a character number is the usual one). Offsets are compared after the shift of the grown client object (records at 0x884F8, the tail after them, the flags, the moved table); writers of the records, the flags and the moved table are `known_table`.
"""
import argparse
import os
import sqlite3
import sys


def load(path, agents=0):
    rows, head = {}, []
    for line in open(path, encoding='utf-8'):
        line = line.rstrip('\n')
        if line.startswith('#'):
            head.append(line)
            continue
        f = line.split('\t')
        if len(f) < 8 or f[0] == 'region':
            continue
        row = dict(count=int(f[2]), main=int(f[3]), distinct=int(f[4]), lo=int(f[5], 16), hi=int(f[6], 16), stride=int(f[7], 16), sample=f[8] if len(f) > 8 else '')
        regs = regions(agents)
        row['kind'], row['lo'] = classify(regs, row['lo'])
        row['kind_hi'], row['hi'] = classify(regs, row['hi'])
        rows[(f[0], int(f[1], 16))] = row
    return rows, head


def regions(agents):
    """The layout of the client object for -agent-capacity <agents> (agent_capacity.hpp): (name, lo, hi, shift) ranges; offsets are compared after the shift."""
    if not agents:
        return []
    c = 18 + agents
    growth = (c - 42) * 0x2CA0
    flags = 0xFDEA8 + growth
    table = (flags + c + 15) & ~15
    return [('record', 0x884F8, 0xFD7F8 + growth, 0), ('tail', 0xFD7F8 + growth, flags, growth), ('flags', flags, flags + c, growth + 0xFDEA8 - 0xFDEA8),
            ('char_c0', table, table + c * 0xC0, table)]


def classify(regs, offset):
    for name, lo, hi, shift in regs:
        if lo <= offset < hi:
            return name, offset - shift if name in ('tail', 'flags') else offset - (shift if name == 'char_c0' else 0)
    return 'cg', offset


def function_of(db, rip):
    if not db:
        return ''
    r = db.execute('select name, addr from functions where addr <= ? order by addr desc limit 1', (0x140000000 + rip,)).fetchone()
    return '%s+0x%X' % (r[0], 0x140000000 + rip - r[1]) if r else ''


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('small')
    ap.add_argument('big')
    ap.add_argument('--db', default=os.path.join(os.path.expanduser('~'), 'Documents', 'IW7-RE-Lab', 'engine', 'iw7-engine.sqlite'))
    ap.add_argument('--min-rows', type=int, default=20, help='distinct offsets that make a writer a table candidate (default 20)')
    a = ap.parse_args()
    def agents_of(path):
        for line in open(path, encoding='utf-8'):
            if line.startswith('# census agents='):
                return int(line.split('agents=')[1].split()[0])
        return 0
    small, small_head = load(a.small, agents_of(a.small))
    big, big_head = load(a.big, agents_of(a.big))
    db = sqlite3.connect('file:%s?mode=ro' % a.db, uri=True) if os.path.exists(a.db) else None
    for name, head in (('small', small_head), ('big', big_head)):
        print('# %s: %s' % (name, ' | '.join(h for h in head if h.startswith('# census') or h.startswith('# region'))))
        released = [h for h in head if h.startswith('# released')]
        if released:
            print('# %s: %d released (hot) pages: the census of the writers of those pages is incomplete' % (name, len(released)))
    out = []
    for key in sorted(set(small) | set(big)):
        s, b = small.get(key), big.get(key)
        if s and not b:
            cls = 'only_small'
        elif b and not s:
            cls = 'only_big'
        elif b['kind'] in ('record', 'char_c0', 'flags') or b['kind_hi'] in ('record', 'char_c0', 'flags'):
            cls = 'known_table'      # the character records (grown) and the moved table: written for every character, the point of the census is the others
        elif b['hi'] > s['hi'] or b['distinct'] > s['distinct']:
            cls = 'reaches'
        else:
            cls = 'same'
        out.append((cls, key, s, b))
    order = {'only_big': 0, 'reaches': 1, 'only_small': 2, 'known_table': 3, 'same': 4}
    out.sort(key=lambda x: (order[x[0]], x[1]))
    print('class\tregion\trip\tfunction\tsmall: count/distinct/lo-hi/stride\tbig: count/distinct/lo-hi/stride\tcandidate')
    n = {}
    for cls, (region, rip), s, b in out:
        n[cls] = n.get(cls, 0) + 1
        if cls in ('same', 'known_table'):
            continue
        fmt = lambda r: '-' if not r else '%d/%d/0x%X-0x%X/0x%X' % (r['count'], r['distinct'], r['lo'], r['hi'], r['stride'])
        cand = ''
        if b and cls in ('only_big', 'reaches') and b['distinct'] >= a.min_rows and b['stride'] >= 4:
            cand = 'TABLE?'
        print('%s\t%s\t0x%X\t%s\t%s\t%s\t%s' % (cls, region, rip, function_of(db, rip), fmt(s), fmt(b), cand))
    print('# totals: ' + ', '.join('%s %d' % (k, n[k]) for k in order if k in n))


if __name__ == '__main__':
    main()
