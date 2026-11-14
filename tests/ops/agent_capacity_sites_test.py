"""Every patch site of src/native/agent_capacity.cpp and every cave window is checked offline against the shipped code.

Sources of the shipped bytes, first found wins (the test skips when none exists on the machine):
  1. IW7_REFERENCE_ROOT (default: the server repository's tools/references): unpacked-text.bin (base 0x140001000) and
     unpacked-rdata.bin (base 0x141435000);
  2. the analysed image of docs/ENGINE.md (IW7_RE_LAB, engine/image/iw7_ship_live.exe).
Sites outside those files (the .data net fields, the protector span at 0x14B...) are counted as not checkable: the
component checks them at run time. The cpp is read as text: literal addresses, `for (auto f : {...})` lists, the q{}/u{}/r{}
record lists, named std::array blocks; an entry it cannot evaluate fails the test instead of being skipped.
"""
import ast
import importlib.util
import json
import os
import re
import struct
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
CPP = os.path.join(ROOT, 'src', 'native', 'agent_capacity.cpp')
INC = os.path.join(ROOT, 'src', 'native', 'agent_capacity_caves.inc')
PLANS = os.path.join(ROOT, 'ops', 'engine', 'caves')
FRAME_FIELDS = os.path.join(ROOT, 'src', 'native', 'agent_capacity_frame_fields.inc')
FRAME_CAVE = os.path.join(ROOT, 'src', 'native', 'agent_capacity_frame_cave.inc')
HPP = os.path.join(ROOT, 'src', 'native', 'agent_capacity.hpp')
sys.path.insert(0, os.path.join(ROOT, 'ops', 'engine'))
spec = importlib.util.spec_from_file_location('cave_plan', os.path.join(ROOT, 'ops', 'engine', 'cave_plan.py'))
cp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cp)

SYMBOLS = {'stock_agents': 24, 'stock_characters': 42, 'players': 18, 'stock_parts': 0x800, 'ai_stock': 71}
HEX = r'0x[0-9A-Fa-f]+(?:ull)?'


def evaluate(text):
    """A constant expression of literals, + - * | << and the stock names."""
    tree = ast.parse(re.sub(r'(0x[0-9A-Fa-f]+)ull', r'\1', text.strip()), mode='eval')

    def ev(n):
        if isinstance(n, ast.Constant) and isinstance(n.value, int):
            return n.value
        if isinstance(n, ast.Name) and n.id in SYMBOLS:
            return SYMBOLS[n.id]
        if isinstance(n, ast.BinOp):
            a, b = ev(n.left), ev(n.right)
            return {ast.Add: a + b, ast.Sub: a - b, ast.Mult: a * b, ast.LShift: a << b, ast.BitOr: a | b}[type(n.op)]
        raise ValueError(f'cannot evaluate {text!r}')
    return ev(tree.body)


def split_args(text, start):
    """Top-level arguments of the call whose '(' is at text[start]; returns (args, end index)."""
    depth, args, cur, i = 0, [], '', start
    while i < len(text):
        c = text[i]
        if c in '({[':
            depth += 1
            if depth > 1:
                cur += c
        elif c in ')}]':
            depth -= 1
            if depth == 0:
                args.append(cur.strip())
                return args, i
            cur += c
        elif c == ',' and depth == 1:
            args.append(cur.strip())
            cur = ''
        else:
            cur += c
        i += 1
    raise ValueError('unbalanced call')


def addr(text):
    return int(text.replace('ull', ''), 16)


def byte_list(text):
    return bytes(int(x, 0) for x in re.findall(r'0x[0-9A-Fa-f]+|(?<![\w.])\d+(?![\w.])', text))


def extract_sites(source):
    """-> (sites, notes). A site is a dict: kind (value/rip/rva/block), address, width, before (int or bytes), tail."""
    sites, notes = [], []
    arrays = {m.group(1): byte_list(m.group(2)) for m in
              re.finditer(r'std::array<std::uint8_t,\s*\d+>\s+(\w+)\s*=\s*\{([^}]*)\}', source)}
    pools = {}
    for i, m in enumerate(re.finditer(r'\{\s*(0x[0-9A-F]+),\s*(0x[0-9A-F]+),\s*0x[0-9A-F]+,\s*\{0x', source)):
        pools[i] = (addr(m.group(1)), addr(m.group(2)))

    def emit(kind, a, args, width=4, tail=0):
        if kind == 'value':
            sites.append({'kind': 'value', 'address': a, 'width': width, 'before': evaluate(args[0])})
        elif kind == 'rip':
            sites.append({'kind': 'rip', 'address': a, 'width': 4, 'before': evaluate(args[0]),
                          'tail': tail})
        elif kind == 'rva':
            sites.append({'kind': 'value', 'address': a, 'width': 4, 'before': evaluate(args[0])})

    call_re = re.compile(r'\b(add1?|rip|rva)\(')
    # 1. literal addresses
    for m in call_re.finditer(source):
        name = m.group(1)
        args, _ = split_args(source, m.end() - 1)
        if not re.fullmatch(HEX, args[0]):
            continue
        a = addr(args[0])
        if name == 'add':
            emit('value', a, args[1:2], int(args[3]) if len(args) > 3 and args[3].isdigit() else 4)
        elif name == 'add1':
            emit('value', a, args[1:2], 1)
        elif name == 'rip':
            emit('rip', a, args[1:2], tail=int(args[3]) if len(args) > 3 else 0)
        else:
            emit('rva', a, args[1:2])
    # 1b. block(address, before, after): the arrays are written with a comma inside <>, so read them by shape
    for m in re.finditer(r'\bblock\(\s*(' + HEX + r'),\s*(?:(\w+)\s*,|std::array<std::uint8_t,\s*\d+>\{([^}]*)\})', source):
        before = arrays[m.group(2)] if m.group(2) in arrays else byte_list(m.group(3))
        sites.append({'kind': 'block', 'address': addr(m.group(1)), 'before': before})
    # 2. `for (auto X : {addresses}) call(X, ...)` and the loop bodies that call with X
    for m in re.finditer(r'for \((?:const )?auto&? (\w+) : \{([^{}]*?)\}\)', source):
        var, items = m.group(1), m.group(2)
        if re.search(r'\b[qur]\{', items):
            continue
        addrs = [addr(x) for x in re.findall(HEX, items)]
        if not addrs:
            continue
        body = source[m.end():m.end() + 900]
        nxt = re.search(r'\bfor \(', body)
        body = body[:nxt.start()] if nxt else body
        found = False
        for c in re.finditer(r'\b(add1?|rip|rva)\(' + var + r'\s*,', body):
            args, _ = split_args(body, c.start() + len(c.group(1)))
            name = c.group(1)
            for a in addrs:
                if name == 'add':
                    emit('value', a, args[1:2], int(args[3]) if len(args) > 3 and args[3].isdigit() else 4)
                elif name == 'add1':
                    emit('value', a, args[1:2], 1)
                elif name == 'rip':
                    emit('rip', a, args[1:2], tail=int(args[3]) if len(args) > 3 else 0)
                else:
                    emit('rva', a, args[1:2])
            found = True
            break
        if not found:
            raise ValueError(f'a loop over addresses with no add/rip/rva call: {items[:60]}')
    # 3. record lists: q{address, before, stack}, u{address, before, width, scale}, r{pool, field, off, at_end}
    for m in re.finditer(r'\bq\{(' + HEX + r'),\s*(0x[0-9A-Fa-f]+|\d+),\s*\d\}', source):
        sites.append({'kind': 'value', 'address': addr(m.group(1)), 'width': 4, 'before': int(m.group(2), 0)})
    for m in re.finditer(r'\bt2\{(' + HEX + r'),\s*(0x[0-9A-Fa-f]+)\}', source):  # table 2: address of a disp32 field, its stock value
        sites.append({'kind': 'value', 'address': addr(m.group(1)), 'width': 4, 'before': int(m.group(2), 0)})
    for m in re.finditer(r'\bu\{(' + HEX + r'),\s*(0x[0-9A-Fa-f]+|\d+),\s*(\d),\s*\d+\}', source):
        sites.append({'kind': 'value', 'address': addr(m.group(1)), 'width': int(m.group(3)),
                      'before': int(m.group(2), 0)})
    for m in re.finditer(r'\br\{(\d), (' + HEX + r'), (0x[0-9A-F]+|0), (true|false)\}', source):
        base, stride = pools[int(m.group(1))]
        off = int(m.group(3), 0)
        target = base + (SYMBOLS['ai_stock'] * stride if m.group(4) == 'true' else 0) + off
        sites.append({'kind': 'rip', 'address': addr(m.group(2)), 'width': 4, 'before': target, 'tail': 0})
    return sites, notes


def check_site(image, s):
    """None when the shipped bytes match, 'skip' when outside the files, else a message."""
    n = 4 if s['kind'] == 'rip' else (len(s['before']) if s['kind'] == 'block' else s['width'])
    got = image.read(s['address'], n)
    if got is None:
        return 'skip'
    if s['kind'] == 'block':
        return None if got == s['before'] else f"{s['address']:#x}: block {got.hex()} != {s['before'].hex()}"
    if s['kind'] == 'rip':
        target = s['address'] + 4 + s['tail'] + struct.unpack('<i', got)[0]
        return None if target == s['before'] else f"{s['address']:#x}: rip target {target:#x} != {s['before']:#x}"
    value = int.from_bytes(got, 'little')
    return None if value == s['before'] else f"{s['address']:#x}: {value:#x} != {s['before']:#x}"


def parse_inc(text):
    """The generated cave table: window start, old bytes, cave bytes, fixups."""
    out = []
    for m in re.finditer(r'^\{(0x[0-9a-f]+)ull, \{([^}]*)\}, \{([^}]*)\}, \{((?:\{[^}]*\},?)*)\}, \{((?:\{[^}]*\},?)*)\}\},$', text, re.M):
        fix = [{'offset': int(a), 'end': int(b), 'target': int(t.replace('ull', ''), 16)}
               for a, b, t in re.findall(r'\{(\d+),(\d+),(0x[0-9a-f]+ull)\}', m.group(4))]
        rt = [{'field': int(f.replace('ull', ''), 16), 'kind': int(k), 'old': int(o.replace('u', ''), 16), 'offset': int(c)}
              for f, k, o, c in re.findall(r'\{(0x[0-9a-f]+ull),(\d+),(0x[0-9a-f]+u),(\d+)\}', m.group(5))]
        out.append({'start': int(m.group(1).replace('ull', ''), 16), 'old': byte_list(m.group(2)),
                    'cave': byte_list(m.group(3)), 'fixups': fix, 'retargets': rt})
    return out


def find_image():
    refs = os.environ.get('IW7_REFERENCE_ROOT') or os.path.join(
        os.path.expanduser('~'), 'Documents', 'IW7-Paris-Server', 'tools', 'references')
    parts = []
    for name, base in (('unpacked-text.bin', 0x140001000), ('unpacked-rdata.bin', 0x141435000)):
        p = os.path.join(refs, name)
        if os.path.exists(p):
            parts.append((base, open(p, 'rb').read(), name.startswith('unpacked-text')))
    if parts:
        img = cp.PlainImage(parts)
        pd = os.path.join(refs, 'unpacked-pdata.bin')
        if os.path.exists(pd):                       # the exception directory (frame grow reads unwind data)
            raw = open(pd, 'rb').read()
            img.regions.append((0x14B094000, raw, False))
            img.exception_directory = (0x14B094000, len(raw) // 12)
        return img, 'unpacked sections'
    lab = os.environ.get('IW7_RE_LAB', os.path.join(os.path.expanduser('~'), 'Documents', 'IW7-RE-Lab'))
    p = os.path.join(lab, 'engine', 'image', 'iw7_ship_live.exe')
    if os.path.exists(p):
        return cp.PeImage(p), 'analysed image'
    return None, None


class Extractor(unittest.TestCase):
    """The reader itself, on a fragment (runs on every machine)."""

    FRAGMENT = '''
    add(0x140C18D77, stock_agents, l.agents);
    add1(0x140B67402, 42, l.player_corpses);
    add1(0x1408213F4, 0x100 - 50, 0x100 - l.agent_corpses);
    for (auto f : {0x140C22AE3ull, 0x140C29144ull}) add(f, stock_characters * 0x3F8, l.characters * 0x3F8);
    for (auto f : {0x141BB3F50ull}) {
        readable(f - 4, 12);
        add(f, 6, 7, 4, false);
    }
    rip(0x14C1ED662, 0x145C9E590, agent_pool.data);
    rva(0x140BF981C, 0x60B22F2, parts_pool.data + 2);
    block(0x140C18D6E, std::array<std::uint8_t, 5>{0xe8, 0x35, 0xed, 0x6a, 0x00}, std::array<std::uint8_t, 5>{0xb8});
    for (const auto& i : {q{0x140C6236E,0x2A0,1},q{0x140C62380,0x280,1}}) add(i.a, i.before, i.before + 1);
    for (const auto& i : {u{0x1416CCF5A,0x54,2,8}}) add(i.a, i.before, i.before + 1, i.width, false);
    for (const auto& i : {t2{0x140C1F25F,0x2400},t2{0x140C1F4A0,0x2414}}) add(i.field, i.before, i.before + shift);
    '''

    def test_fragment(self):
        sites, _ = extract_sites(self.FRAGMENT)
        by = {s['address']: s for s in sites}
        self.assertEqual(by[0x140C18D77]['before'], 24)
        self.assertEqual(by[0x140B67402]['width'], 1)
        self.assertEqual(by[0x1408213F4]['before'], 0x100 - 50)
        self.assertEqual(by[0x140C29144]['before'], 42 * 0x3F8)
        self.assertEqual(by[0x141BB3F50]['before'], 6)
        self.assertEqual(by[0x14C1ED662]['kind'], 'rip')
        self.assertEqual(by[0x140BF981C]['before'], 0x60B22F2)
        self.assertEqual(by[0x140C18D6E]['before'], bytes.fromhex('e835ed6a00'))
        self.assertEqual(by[0x140C62380]['before'], 0x280)
        self.assertEqual((by[0x1416CCF5A]['width'], by[0x1416CCF5A]['before']), (2, 0x54))
        self.assertEqual((by[0x140C1F4A0]['width'], by[0x140C1F4A0]['before']), (4, 0x2414))
        self.assertEqual(len(sites), 14)

    def test_a_wrong_stock_value_and_a_wrong_rip_target_are_found(self):
        image = cp.PlainImage([(0x140001000, bytes.fromhex('18000000') + (0x1000).to_bytes(4, 'little', signed=True)
                                + bytes.fromhex('e835ed6a00'), True)])
        self.assertIsNone(check_site(image, {'kind': 'value', 'address': 0x140001000, 'width': 4, 'before': 24}))
        self.assertIn('!=', check_site(image, {'kind': 'value', 'address': 0x140001000, 'width': 4, 'before': 25}))
        target = 0x140001004 + 4 + 0x1000
        self.assertIsNone(check_site(image, {'kind': 'rip', 'address': 0x140001004, 'width': 4, 'before': target, 'tail': 0}))
        self.assertIn('rip target', check_site(image, {'kind': 'rip', 'address': 0x140001004, 'width': 4,
                                                       'before': target + 1, 'tail': 0}))
        self.assertIn('block', check_site(image, {'kind': 'block', 'address': 0x140001008, 'before': bytes.fromhex('e835ed6a01')}))
        self.assertEqual(check_site(image, {'kind': 'value', 'address': 0x150000000, 'width': 4, 'before': 1}), 'skip')

    def test_inc_round_trip_and_window_check(self):
        img = cp.PlainImage([(0x140001040, bytes.fromhex('8b4310') + bytes.fromhex('488d0d00010000') + b'\x90' * 16, True)])
        (cave,) = cp.plan([{'address': 0x140001040, 'kind': 'disp', 'new_disp': 0x3F08}], img)
        text = cp.emit_cpp({'caves': [cave]}, 'x.json')
        (c,) = parse_inc(text)
        self.assertEqual(c['start'], 0x140001040)
        self.assertEqual(c['old'].hex(), cave['old_bytes'])
        self.assertEqual(c['cave'].hex(), cave['cave_bytes'])
        self.assertEqual([(f['offset'], f['end'], f['target']) for f in c['fixups']],
                         [(f['offset'], f['end'], int(f['target'], 0)) for f in cave['fixups']])
        bad = cp.PlainImage([(0x140001040, bytes.fromhex('8b4311') + bytes.fromhex('488d0d00010000'), True)])
        self.assertNotEqual(bad.read(0x140001040, len(c['old'])), c['old'])


class Sites(unittest.TestCase):
    def setUp(self):
        self.image, self.source = find_image()
        if self.image is None:
            self.skipTest('no unpacked code files or analysed image on this machine')

    def test_every_patch_site_matches_the_shipped_bytes(self):
        sites, _ = extract_sites(open(CPP, encoding='utf-8').read())
        bad, skipped, ok = [], 0, 0
        for s in sites:
            r = check_site(self.image, s)
            if r == 'skip':
                skipped += 1
            elif r:
                bad.append(r)
            else:
                ok += 1
        print(f'\nagent_capacity sites ({self.source}): {ok} match, {skipped} outside the files, {len(bad)} differ')
        self.assertEqual(bad, [], '\n'.join(bad))
        self.assertGreater(ok, 200)

    def test_a1_table_sites(self):
        """The A1 table relocation: its counts, and no patch (site, block or cave window) overlaps another."""
        source = open(CPP, encoding='utf-8').read()
        body = source[source.index('void plan_tables()'):]
        body = body[:body.index('\n}\n')]
        self.assertEqual(len(re.findall(r'\bt2\{0x', body)), 77, 'table 2: 77 displacement sites')
        loop = re.search(r'for \(auto a : \{([^{}]*)\}\)\s*add\(a, 0x3F08, l\.record_bytes\(\)\)', body)
        self.assertEqual(len(re.findall(HEX, loop.group(1))), 24, 'record size: 24 immediates')
        for a in ('0x140C2A302, 0x2408', '0x140C2A31F, 0x42'):
            self.assertIn(a, body)
        plan = json.load(open(os.path.join(PLANS, 'a1-table1.plan.json'), encoding='utf-8'))
        starts = {int(c['window_start'], 0) for c in plan['caves']}
        self.assertEqual(len(starts), 48, 'table 1: 49 instructions in 48 caves')
        self.assertIn(0x140C2A310, starts, 'SV_InitAgentRecord table 1 start goes through the cave planner')
        sites, _ = extract_sites(source)
        spans = []
        for x in sites:
            n = 4 if x['kind'] == 'rip' else (len(x['before']) if x['kind'] == 'block' else x['width'])
            spans.append((x['address'], x['address'] + n, 'site'))
        for c in parse_inc(open(INC, encoding='utf-8').read()):
            spans.append((c['start'], c['start'] + len(c['old']), 'cave'))
            spans.extend((t['field'], t['field'] + 4, 'retarget') for t in c['retargets'])
        spans.sort()
        clash = [(hex(a[0]), a[2], hex(b[0]), b[2]) for a, b in zip(spans, spans[1:]) if a[1] > b[0]]
        self.assertEqual(clash, [], 'overlapping patches')

    def test_entity_queue_sites(self):
        """The server entity queue table (FUN_1405ee500..ee9e0): its 10 encoded references and the memset length, each checked
        against the shipped bytes, no other site of the plan overlaps them, and the loop-2 start is row 18's head."""
        source = open(CPP, encoding='utf-8').read()
        body = source[source.index('void plan_entity_queue()'):]
        body = body[:body.index('\n}\n')]
        sites, _ = extract_sites(body)
        self.assertEqual(len(sites), 11, 'ten references (nine rip, one rva) and the memset length')
        self.assertEqual(sorted(s['address'] for s in sites if s['kind'] == 'rip'),
                         [0x1405EE50F, 0x1405EE535, 0x1405EE556, 0x1405EE5B2, 0x1405EE6FF, 0x1405EE968, 0x1405EE9F4,
                          0x1405EEA03, 0x1405EEA8A])
        for s in sites:
            self.assertIsNone(check_site(self.image, s), hex(s['address']))
            if s['kind'] == 'rip':
                self.assertTrue(0x144EB2B70 <= s['before'] < 0x144EB8090)
        self.assertEqual(0x144EB2B70 + 18 * 0x208 + 0x200, 0x144EB5200)   # loop 2 starts at the head of row 18
        self.assertEqual(self.image.read(0x1405EE53B, 4), (42 * 0x208).to_bytes(4, 'little'))
        inside = [(s['address'], s['address'] + 4) for s in sites]
        others = [x for x in extract_sites(source)[0] if x['address'] not in {a for a, _ in inside}]
        for x in others:
            n = 4 if x['kind'] == 'rip' else (len(x['before']) if x['kind'] == 'block' else x['width'])
            for a, b in inside:
                self.assertFalse(x['address'] < b and a < x['address'] + n, f"{x['address']:#x} overlaps the entity queue site {a:#x}")

    def test_every_committed_plan_matches_the_shipped_bytes(self):
        """The plan files under ops/engine/caves (a1-table1.plan.json is not in the .inc yet): stock windows, self-check, retarget fields."""
        n = 0
        for name in sorted(os.listdir(PLANS)):
            if not name.endswith('.plan.json') and name != 'proof-zero-change.json':
                continue
            for c in json.load(open(os.path.join(PLANS, name), encoding='utf-8'))['caves']:
                start = int(c['window_start'], 0)
                self.assertEqual(self.image.read(start, c['window_len']).hex(), c['old_bytes'], f'{name} {start:#x}')
                cp.self_check(c, cp.decode(bytes.fromhex(c['old_bytes']), start))
                for t in c['retargets']:
                    self.assertEqual(self.image.read(int(t['field'], 0), 4).hex(), t['old_bytes'])
                n += 1
        print(f'\ncommitted plans: {n} cave windows match the shipped bytes')

    def test_every_cave_window_matches_and_the_cave_means_the_same(self):
        caves = parse_inc(open(INC, encoding='utf-8').read())
        plans = {}
        # the plan file the table was generated from is named in the .inc header; the proof plans stay in the repository, not in the build
        live = re.search(r'from (\S+\.json)', open(INC, encoding='utf-8').read().splitlines()[0]).group(1)
        for c in json.load(open(os.path.join(PLANS, live), encoding='utf-8')).get('caves', []):
            plans[int(c['window_start'], 0)] = c
        for c in caves:
            stock = self.image.read(c['start'], len(c['old']))
            self.assertEqual(stock, c['old'], f"cave window {c['start']:#x}: the shipped bytes differ")
            plan = plans.get(c['start'])
            self.assertIsNotNone(plan, f"cave {c['start']:#x} is in the .inc but in no plan file under ops/engine/caves")
            self.assertEqual(plan['cave_bytes'], c['cave'].hex())
            self.assertEqual(plan['old_bytes'], c['old'].hex())
            win = cp.decode(c['old'], c['start'])
            self.assertEqual(sum(i.size for i in win), len(c['old']), 'window is not whole instructions')
            self.assertGreaterEqual(len(c['old']), 5)
            cp.self_check(plan, win)                       # raises Refusal on any difference
            self.assertEqual([(f['offset'], f['end'], int(f['target'], 0)) for f in plan['fixups']],
                             [(f['offset'], f['end'], f['target']) for f in c['fixups']])
            self.assertEqual([(int(t['field'], 0), 0 if t['kind'] == 'rel32' else 1, int.from_bytes(bytes.fromhex(t['old_bytes']), 'little'), t['cave_offset'])
                              for t in plan['retargets']],
                             [(t['field'], t['kind'], t['old'], t['offset']) for t in c['retargets']])
            for t in c['retargets']:                       # the incoming reference still has its stock value
                self.assertEqual(int.from_bytes(self.image.read(t['field'], 4), 'little'), t['old'], f"retarget {t['field']:#x}")
        print(f'\ncave windows checked: {len(caves)}')


def src(name):
    return os.path.join(ROOT, 'src', 'native', name)


# the three frame-grow tables: plan file, generated tables, function and the run-time formula of X (the hpp lines pinned below)
FRAME_TABLES = [
    {'plan': 'frame-1403e61b0.frame.json', 'fields': 'agent_capacity_frame_fields.inc', 'cave': 'agent_capacity_frame_cave.inc',
     'function': 0x1403E61B0, 'entry': 32, 'formula': '((2 * sentient_slots() - 71) * 32 + 15) & ~15u',
     'extra': lambda n: ((2 * (71 + n - 24) - 71) * 32 + 15) & ~15},
    {'plan': 'frame-140adb8e0.frame.json', 'fields': 'agent_capacity_frame_fields_adb8e0.inc', 'cave': None,
     'function': 0x140ADB8E0, 'entry': 16, 'formula': 'frame_extra_b() const { return (sentient_slots() - 71) * 16; }',
     'extra': lambda n: (n - 24) * 16},
    {'plan': 'frame-140added0.frame.json', 'fields': 'agent_capacity_frame_fields_added0.inc', 'cave': 'agent_capacity_frame_cave_added0.inc',
     'function': 0x140ADDED0, 'entry': 32, 'formula': 'frame_extra_c() const { return (sentient_slots() - 71) * 32; }',
     'extra': lambda n: (n - 24) * 32},
]


class FrameGrow(unittest.TestCase):
    """Frame grow of FUN_1403E61B0, FUN_140ADB8E0 and FUN_140ADDED0: the generated tables, the plan files, the shipped bytes and the
    run-time arithmetic for every agent count."""

    def setUp(self):
        self.image, self.source = find_image()
        if self.image is None:
            self.skipTest('no unpacked code files or analysed image on this machine')
        for t in FRAME_TABLES:
            t['doc'] = json.load(open(os.path.join(PLANS, t['plan']), encoding='utf-8'))

    @staticmethod
    def parse_fields(name):
        text = open(src(name), encoding='utf-8').read()
        out = []
        for m in re.finditer(r'^\{(0x[0-9a-f]+)ull, (\d+), (0x[0-9a-f]+)u, (\d+), (-?\d+), (true|false)\},$', text, re.M):
            out.append({'address': int(m.group(1).replace('ull', ''), 16), 'width': int(m.group(2)), 'stock': int(m.group(3), 16),
                        'unit': int(m.group(4)), 'sign': int(m.group(5)), 'code': m.group(6) == 'true'})
        return out

    def test_the_tables_are_the_plans_and_the_shipped_bytes_match(self):
        for t in FRAME_TABLES:
            with self.subTest(t['plan']):
                fields = self.parse_fields(t['fields'])
                plan = t['doc']
                self.assertEqual(len(fields), len(plan['fields']))
                for x, f in zip(fields, plan['fields']):
                    self.assertEqual((x['address'], x['width'], x['stock'], x['unit'], x['sign']),
                                     (int(f['address'], 0), f['width'], f['stock'], f['unit'], f['sign']))
                    self.assertEqual(x['code'], not f['role'].startswith('unwind'))
                    got = self.image.read(x['address'], x['width'])
                    self.assertIsNotNone(got, f"{x['address']:#x} is not in the shipped files")
                    self.assertEqual(int.from_bytes(got, 'little'), x['stock'], f"frame field {x['address']:#x}")
                print(f"\nframe grow {plan['function']}: {len(fields)} fields match the shipped bytes ({self.source})")

    def test_the_cave_lines_are_the_plans_and_the_windows_match(self):
        for t in FRAME_TABLES:
            with self.subTest(t['plan']):
                cave = t['doc']['cave']
                if t['cave'] is None:
                    self.assertIsNone(cave, 'a plan with a probe cave needs its cave table')
                    continue
                text = open(src(t['cave']), encoding='utf-8').read()
                m = re.search(r'^\{(0x[0-9a-f]+)ull, \{([^}]*)\}, \{([^}]*)\}, (\d+), (0x[0-9a-f]+)u, (0x[0-9a-f]+)u, (\d+)\},$', text, re.M)
                self.assertIsNotNone(m, 'no frame cave line')
                start = int(m.group(1).replace('ull', ''), 16)
                old, new = byte_list(m.group(2)), byte_list(m.group(3))
                self.assertEqual((start, old.hex(), new.hex()), (int(cave['window_start'], 0), cave['old_bytes'], cave['cave_bytes']))
                self.assertEqual(self.image.read(start, len(old)), old)
                imm, stock, top, probes = int(m.group(4)), int(m.group(5), 16), int(m.group(6), 16), int(m.group(7))
                self.assertEqual((imm, stock, top, probes), (cave['imm_offset'], cave['stock_frame'], cave['max_extra'], cave['probes']))
                self.assertEqual(int.from_bytes(new[imm:imm + 4], 'little'), stock + top, 'the cave holds the largest frame')
                self.assertEqual(old[3:7], stock.to_bytes(4, 'little'), 'the stock sub rsp immediate is the stock frame')
                self.assertEqual(len(new), 8 * probes + 7)

    def test_the_planner_reproduces_the_committed_plans_and_checks_itself(self):
        import frame_grow
        for t in FRAME_TABLES:
            with self.subTest(t['plan']):
                plan = t['doc']
                db = cp.EngineDb(cp.DEFAULT_DB) if os.path.exists(cp.DEFAULT_DB) else None    # instruction boundaries clear false raw-branch hits
                try:
                    doc = frame_grow.plan_frame_grow(self.image, t['function'], plan['array_top'], plan['extra'], plan['max_extra'], db=db)
                except cp.Refusal as e:
                    if db is not None or not plan['cave']:
                        raise
                    self.skipTest('the probe cave of %s needs the engine database to rule out raw branch hits: %s' % (t['plan'], e.reasons))
                self.assertEqual(doc['fields'], plan['fields'])
                self.assertEqual((doc['cave'] or {}).get('cave_bytes'), (plan['cave'] or {}).get('cave_bytes'))
                frame_grow.self_check(self.image, doc, extras=[16 * k for k in range(1, 4)] + [t['extra'](n) for n in range(28, 101, 4)])

    def test_the_run_time_arithmetic_for_every_agent_count(self):
        import frame_grow
        hpp = open(HPP, encoding='utf-8').read()
        for t in FRAME_TABLES:
            with self.subTest(t['plan']):
                self.assertIn(t['formula'], hpp)                    # the formula this test repeats
                fields = self.parse_fields(t['fields'])
                plan = t['doc']
                cave = plan['cave']
                for n in range(24, 101, 4):
                    extra = t['extra'](n)
                    self.assertLessEqual(extra, plan['max_extra'])
                    # the array holds one entry per sentient slot: 71 stock entries + extra / entry size >= slots
                    self.assertGreaterEqual(71 + extra // t['entry'], 71 + n - 24)
                    if extra == 0:                                  # one-loop functions: nothing changes at 24 agents
                        self.assertEqual(n, 24)
                        continue
                    code, patches, cave_bytes = frame_grow.apply_plan(self.image, plan, extra)
                    for x in fields:
                        new = x['stock'] + x['sign'] * (extra // x['unit'])
                        self.assertEqual(extra % x['unit'], 0)
                        if x['width'] < 4:
                            self.assertTrue(0 <= new < 1 << (8 * x['width']))
                        new &= (1 << (8 * x['width'])) - 1
                        f = next(y for y in plan['fields'] if int(y['address'], 0) == x['address'])
                        self.assertEqual(frame_grow.field_value(f, extra), new)
                    if cave:
                        self.assertEqual(int.from_bytes(cave_bytes[cave['imm_offset']:cave['imm_offset'] + 4], 'little'), cave['stock_frame'] + extra)

    def test_no_overlap_with_any_other_patch(self):
        sites, _ = extract_sites(open(CPP, encoding='utf-8').read())
        spans = []
        for x in sites:
            n = 4 if x['kind'] == 'rip' else (len(x['before']) if x['kind'] == 'block' else x['width'])
            spans.append((x['address'], x['address'] + n, 'site'))
        caves = parse_inc(open(INC, encoding='utf-8').read())
        for c in caves:
            spans.append((c['start'], c['start'] + len(c['old']), 'cave'))
            spans.extend((t['field'], t['field'] + 4, 'retarget') for t in c['retargets'])
        for t in FRAME_TABLES:                                      # BOTH tables of every function: fields and probe cave
            for x in self.parse_fields(t['fields']):
                spans.append((x['address'], x['address'] + x['width'], 'frame field %#x' % t['function']))
            cave = t['doc']['cave']
            if cave:
                spans.append((int(cave['window_start'], 0), int(cave['window_start'], 0) + cave['window_len'], 'frame cave %#x' % t['function']))
        spans.sort()
        clash = [(hex(a[0]), a[2], hex(b[0]), b[2]) for a, b in zip(spans, spans[1:]) if a[1] > b[0]]
        self.assertEqual(clash, [], 'overlapping patches')
        # the table-1 caves that live inside the grown FUN_140ADB8E0 (there are three) touch none of its frame fields
        inside = [c for c in caves if 0x140ADB8E0 <= c['start'] < 0x140ADBC08]
        self.assertGreaterEqual(len(inside), 3)

    def test_the_cpp_sees_every_table(self):
        text = open(CPP, encoding='utf-8').read()
        for name in ('agent_capacity_frame_fields.inc', 'agent_capacity_frame_fields_adb8e0.inc', 'agent_capacity_frame_fields_added0.inc',
                     'agent_capacity_frame_cave.inc', 'agent_capacity_frame_cave_added0.inc'):
            self.assertIn('#include "%s"' % name, text)
        reserve = text.split('void plan_caves()')[1]
        for sets in ('frame_caves_a', 'frame_caves_b', 'frame_caves_c'):
            self.assertIn(sets, reserve, 'the probe caves of every function are reserved')


if __name__ == '__main__':
    unittest.main()
