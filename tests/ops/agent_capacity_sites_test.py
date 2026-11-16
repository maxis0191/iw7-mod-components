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
INC_REWIND = os.path.join(ROOT, 'src', 'native', 'agent_capacity_caves_rewind.inc')
INC_WIDE = os.path.join(ROOT, 'src', 'native', 'agent_capacity_caves_wide.inc')
INC_MASK = os.path.join(ROOT, 'src', 'native', 'agent_capacity_caves_mask.inc')
INC_GUARD = os.path.join(ROOT, 'src', 'native', 'agent_capacity_caves_guard.inc')
INC_INTERP = os.path.join(ROOT, 'src', 'native', 'agent_capacity_caves_interp.inc')
PLANS = os.path.join(ROOT, 'ops', 'engine', 'caves')
FRAME_FIELDS = os.path.join(ROOT, 'src', 'native', 'agent_capacity_frame_fields.inc')
FRAME_CAVE = os.path.join(ROOT, 'src', 'native', 'agent_capacity_frame_cave.inc')
HPP = os.path.join(ROOT, 'src', 'native', 'agent_capacity.hpp')
sys.path.insert(0, os.path.join(ROOT, 'ops', 'engine'))
spec = importlib.util.spec_from_file_location('cave_plan', os.path.join(ROOT, 'ops', 'engine', 'cave_plan.py'))
cp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cp)

SYMBOLS = {'stock_agents': 24, 'stock_characters': 42, 'players': 18, 'stock_parts': 0x800, 'ai_stock': 71,
           'anim_info_stock_heap': 0x147995420, 'anim_info_stock_base': 0x1479953E0, 'anim_info_stock_bytes': 0x40000, 'anim_info_header': 0x40,
           'bone_stock_base': 0x141FE5F23, 'bone_stock_cap': 0xFFFF0}
HEX = r'0x[0-9A-Fa-f]+(?:ull)?'


def evaluate(text, env=None):
    """A constant expression of literals, + - * & | << ~, the stock names, and (with env) the layout names `l.x` / `l.x()`."""
    text = re.sub(r'static_cast<[\w:]+>\(', '(', text.strip())
    text = re.sub(r'\b[lL]\.(\w+)(?:\(\))?', r'l_\1', text)
    tree = ast.parse(re.sub(r'(0x[0-9A-Fa-f]+)ull', r'\1', text), mode='eval')
    names = dict(SYMBOLS, **(env or {}))

    def ev(n):
        if isinstance(n, ast.Constant) and isinstance(n.value, int):
            return n.value
        if isinstance(n, ast.Name) and n.id in names:
            return names[n.id]
        if isinstance(n, ast.UnaryOp) and isinstance(n.op, (ast.USub, ast.Invert)):
            return -ev(n.operand) if isinstance(n.op, ast.USub) else ~ev(n.operand)
        if isinstance(n, ast.BinOp):
            a, b = ev(n.left), ev(n.right)
            return {ast.Add: a + b, ast.Sub: a - b, ast.Mult: a * b, ast.LShift: a << b, ast.BitOr: a | b,
                    ast.BitAnd: a & b}[type(n.op)]
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

    def emit(kind, a, args, width=4, tail=0, call=None, after=None):
        if kind == 'value':
            sites.append({'kind': 'value', 'address': a, 'width': width, 'before': evaluate(args[0]), 'call': call, 'after': after})
        elif kind == 'rip':
            sites.append({'kind': 'rip', 'address': a, 'width': 4, 'before': evaluate(args[0]),
                          'tail': tail})
        elif kind == 'rva':
            sites.append({'kind': 'value', 'address': a, 'width': 4, 'before': evaluate(args[0])})

    call_re = re.compile(r'\b(add1s?|add|rip|rva)\(')
    # 1. literal addresses
    for m in call_re.finditer(source):
        name = m.group(1)
        args, _ = split_args(source, m.end() - 1)
        if not re.fullmatch(HEX, args[0]):
            continue
        a = addr(args[0])
        if name == 'add':
            emit('value', a, args[1:2], int(args[3]) if len(args) > 3 and args[3].isdigit() else 4)
        elif name in ('add1', 'add1s'):
            emit('value', a, args[1:2], 1, call=name, after=args[2])
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
        for c in re.finditer(r'\b(add1s?|add|rip|rva)\(' + var + r'\s*,', body):
            args, _ = split_args(body, c.start() + len(c.group(1)))
            name = c.group(1)
            for a in addrs:
                if name == 'add':
                    emit('value', a, args[1:2], int(args[3]) if len(args) > 3 and args[3].isdigit() else 4)
                elif name in ('add1', 'add1s'):
                    emit('value', a, args[1:2], 1, call=name, after=args[2])
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
        for c in parse_inc(open(INC, encoding='utf-8').read()) + parse_inc(open(INC_REWIND, encoding='utf-8').read()) + parse_inc(open(INC_WIDE, encoding='utf-8').read()) + parse_inc(open(INC_MASK, encoding='utf-8').read()) + parse_inc(open(INC_GUARD, encoding='utf-8').read()) + parse_inc(open(INC_INTERP, encoding='utf-8').read()):
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

# ---- one-byte fields the CPU sign-extends ------------------------------------------------------------------------------------
# Every instruction the component still patches with ONE byte (add1 / add1s, and the byte of a `block`) was read in the shipped code:
# field address -> (instruction address, instruction bytes). A displacement byte (disp8) and the immediate of an `83 /r`, `6B`,
# `48 83` form are sign-extended by the CPU: a value above 0x7F is read as negative. The test below decodes each instruction with
# capstone, proves the patched byte is such a field, and runs the value the C++ writes for every allowed agent count.
# After a34 no signed one-byte patch is left: the fields that held a count are 32-bit (WIDE_SITES) and CG_SetNextSnap's eight stack offsets
# are gone (five instructions in the mask caves, three back to the shipped bytes), see MOVED_TO_CAVE.
SIGNED_BYTE_SITES = {}      # none left (a34): the eight CG_SetNextSnap stack offsets are gone, see MOVED_TO_CAVE
# The 34 instructions of a29 section 2.1 that held a count in a one-byte field and now hold it in 32 bits: row -> (instruction address,
# shipped bytes, layout name). 15 corpse sites (rows 1-14 and the two bound subtractions), 16 character-bound sites (15-30 minus the two in
# place), 2 character-index bounds (31, 32), 2 agent bounds (33, 34), 35 (agents - 18), 37 (the frames x agents imul in caves).
WIDE_SITES = {
    1: (0x140B67400, '8d422a', 'l_player_corpses'), 2: (0x140C1BB20, '8d4132', 'l_agent_corpses'),
    3: (0x1407AE400, '4183e92a', 'l_player_corpses'), 4: (0x140823B5F, '83e82a', 'l_player_corpses'),
    5: (0x140826382, '4183eb2a', 'l_player_corpses'), 6: (0x14086D120, '83ef2a', 'l_player_corpses'),
    7: (0x140872E63, '83e82a', 'l_player_corpses'), 8: (0x140B2F533, '4183e92a', 'l_player_corpses'),
    9: (0x1407AF52D, '83ef32', 'l_agent_corpses'), 10: (0x140823B7E, '83e832', 'l_agent_corpses'),
    11: (0x140865EB7, '83e932', 'l_agent_corpses'), 12: (0x14086F507, '83e832', 'l_agent_corpses'),
    13: (0x140872EEA, '83e832', 'l_agent_corpses'), 14: (0x1408213F1, '418d5bce', '-l_agent_corpses'),
    15: (0x14084A54F, '83f82a', 'l_characters'), 16: (0x140842A1E, '83f92a', 'l_characters'),
    17: (0x140842B09, '83f82a', 'l_characters'), 20: (0x140780547, '83f82a', 'l_characters'),
    21: (0x140805D4C, '83fb2a', 'l_characters'), 22: (0x140282ED6, '83fb2a', 'l_characters'),
    23: (0x1402854DC, '83ff2a', 'l_characters'), 24: (0x1405C2576, '83f82a', 'l_characters'),
    25: (0x140B202DA, '83fb2a', 'l_characters'), 26: (0x140C217CA, '4183f92a', 'l_characters'),
    27: (0x140C3F3A8, '83ff2a', 'l_characters'), 28: (0x140AC67BE, '4183f92a', 'l_characters'),
    29: (0x140AC686C, '83fb2a', 'l_characters'), 30: (0x140445B43, '83fd2a', 'l_characters'),
    31: (0x140242E20, '83fa29', 'l_characters - 1'), 32: (0x140242E3A, '83fa29', 'l_characters - 1'),
    33: (0x1404494FB, '83fa18', 'l_agents'), 34: (0x140449693, '4883fe18', 'l_agents'),
    35: (0x1409B26F9, '448d7506', 'l_agents - 18'), 37: (0x140C68A82, '438d0452', 'l_agents'),
}
WIDE_WIDTH = 4
# Rewritten in place (the new encoding has the stock length): row -> (address, shipped bytes, layout name)
IN_PLACE_SITES = {18: (0x14077EDEB, '6683f82a', 'l_characters'), 19: (0x1407801DB, '6683f82a', 'l_characters'),
                  38: (0x140C68A96, '438d045bc1e003', 'l_agents')}
# Sites that were one byte and now go through a cave with a 32-bit field: they must not come back as a byte site. Field address -> instruction.
MOVED_TO_CAVE = {0x140415C28: (0x140415C24, '488944df40')}   # FUN_140415bf0+34, mov [rdi+rbx*8+0x40],rax
# CG_SetNextSnap (a34): the five instructions that held the change mask at [rsp+0x40] are caves (agent_capacity_caves_mask.inc); the memset
# start/length and the saved qword at 0x60 are the shipped bytes again (the mask no longer sits there).
MOVED_TO_CAVE.update({0x14086FE70: (0x14086FE6C, '4c8d4c2440'), 0x14086FE78: (0x14086FE74, '4889442440'), 0x14086FE87: (0x14086FE83, '4c8d442440'),
                      0x140870670: (0x14087066D, '8b4c8c40'), 0x1408706D0: (0x1408706CD, '8b4c8c40'),
                      0x14086FBE0: (0x14086FBDC, '488d4c2470'), 0x14086FDAF: (0x14086FDAB, '4889442460'), 0x140870705: (0x140870701, '488b5c2460')})
for _row, (_a, _hx, _name) in WIDE_SITES.items():
    if _row != 37:
        MOVED_TO_CAVE[_a + len(_hx) // 2 - 1] = (_a, _hx)
ALLOWED_COUNTS = range(24, 321, 4)                           # refuse(): 24, 28, ..., 320
SITE_COUNTS = [n for n in range(24, 321) if (18 + n - 42) % 4 == 0]   # every count the sites are written for: 24, 28, ..., 320


def layout_names(n):
    """The names of layout (agent_capacity.hpp) a site can use, for n agents."""
    c = 18 + n
    return {'l_agents': n, 'l_characters': c, 'l_player_corpses': c, 'l_agent_corpses': c + 8, 'l_map_start': c + 16,
            'l_rewind_pointers': (0x14 + c + 7) & ~7}


def refuse_mirror(n):
    """agent_capacity.hpp refuse(n) in Python (the text of every rule is pinned by test_the_refuse_mirror_matches_the_hpp)."""
    c = 18 + n
    if n < 24:
        return 'fewer than the stock 24 agents'
    if (c - 42) % 4:
        return 'players + agents - 42 must be a multiple of 4'
    if n > 320:
        return 'more than 320 agents'
    if ((c + 31) // 32) * 4 > 48:
        return 'character change mask does not fit'
    slots = 71 + n - 24
    if ((2 * slots - 71) * 32 + 15) & ~15 > 0x52E0:
        return 'FUN_1403E61B0 probe cave'
    if (slots - 71) * 32 > 0x2500:
        return 'FUN_140ADDED0 probe cave'
    if (slots - 71) * 16 > 0x1280:
        return 'FUN_140ADB8E0 probe cave'
    if ((0x3F08 + slots * 0x40 + slots * 0x3C + 15) & ~15) > 0x20000:
        return 'embedded record room'
    return ''


class SignedByteSites(unittest.TestCase):
    def setUp(self):
        self.image, self.source = find_image()
        if self.image is None:
            self.skipTest('no unpacked code files or analysed image on this machine')
        self.text = open(CPP, encoding='utf-8').read()
        self.sites = [s for s in extract_sites(self.text)[0] if s['kind'] == 'value' and s['width'] == 1]

    def field_of(self, address, insn_address, hexbytes):
        """(kind, sign-extended) of the byte at `address` inside the instruction, read from the shipped bytes."""
        raw = self.image.read(insn_address, len(hexbytes) // 2)
        self.assertEqual(raw.hex(), hexbytes, f'{insn_address:#x}: the shipped bytes differ from the table')
        i = next(cp._cs().disasm(raw, insn_address))
        self.assertEqual(i.size, len(raw), f'{insn_address:#x}: not one whole instruction')
        enc, off = i.encoding, address - insn_address
        if enc.disp_size == 1 and enc.disp_offset == off:
            return 'disp8', True
        if enc.imm_size == 1 and enc.imm_offset == off:
            width = max(o.size for o in i.operands)
            return 'imm8', width > 1                 # the imm8 of a byte operation is not extended
        self.fail(f'{address:#x}: not a disp8 or imm8 field of {i.mnemonic} {i.op_str}')

    def test_the_hpp_mirror_matches_the_formulas(self):
        hpp = open(HPP, encoding='utf-8').read()
        self.assertIn('(0x14 + characters + 7) & ~7u', hpp)       # layout_names() repeats this formula
        self.assertIn('l.player_corpses = l.characters; l.agent_corpses = l.characters + 8; l.map_start = l.characters + 16;', hpp)
        self.assertEqual(layout_names(100)['l_rewind_pointers'], 0x90)
        self.assertEqual(layout_names(24)['l_rewind_pointers'], 0x40)     # the stock value at 24 agents

    def test_the_remaining_byte_sites_are_constants_and_the_max_agents_byte_is_bounded(self):
        for s in self.sites:
            self.assertEqual(evaluate(s['after'], layout_names(24)), evaluate(s['after'], layout_names(320)), f"{s['address']:#x} depends on the count")
        # G_GetMaxAgents: the low byte of `mov eax, n` with three zero bytes: unsigned_imm8 refuses above 255; the byte is min(n, 255) (gamestate_agent_byte)
        self.assertIn('unsigned_imm8(gamestate_agent_byte(l.agents))', self.text)
        self.assertIn('add(0x140C18D77, stock_agents, gamestate_agent_byte(l.agents));', self.text)
        self.assertIn('if (value > 0xFF) throw', self.text)
        self.assertIn('constexpr bool byte_sites_hold(std::uint32_t agents) { return gamestate_agent_byte(agents) <= 255; }', open(HPP, encoding='utf-8').read())
        # add1s itself still refuses what a signed byte cannot hold (the plan-time guard for anything left one-byte)
        self.assertIn('does not fit a signed 8-bit field', self.text)
        self.assertIn('constexpr bool fits_signed_byte(std::int64_t value) { return value >= -128 && value <= 127; }', open(HPP, encoding='utf-8').read())

    def test_every_one_byte_site_is_classified_and_every_signed_one_uses_add1s(self):
        by = {s['address']: s for s in self.sites}
        unknown = sorted(hex(a) for a in by if a not in SIGNED_BYTE_SITES and a not in MOVED_TO_CAVE)
        self.assertEqual(unknown, [], 'a new one-byte site: read its instruction and add it to SIGNED_BYTE_SITES (or an unsigned table)')
        for address, (insn, hexbytes) in SIGNED_BYTE_SITES.items():
            kind, signed = self.field_of(address, insn, hexbytes)
            self.assertTrue(signed, f'{address:#x} is an unsigned byte but listed as signed')
            if address in by:
                self.assertEqual(by[address]['call'], 'add1s', f'{address:#x} ({kind}) is read signed by the CPU: it must be written with add1s')
        print(f'\nsigned one-byte sites: {len(SIGNED_BYTE_SITES)} (disp8 and sign-extended imm8), checked against the shipped bytes')

    def test_no_value_a_signed_byte_receives_is_read_differently_at_any_allowed_count(self):
        bad = []
        for s in self.sites:
            for n in SITE_COUNTS:
                value = evaluate(s['after'], layout_names(n))
                if not -128 <= value <= 127:
                    note = f'{s["address"]:#x} ({s["call"]}) at {n} agents: writes {value:#x} (a one-byte field read as {((value & 0xFF) ^ 0x80) - 0x80})'
                    if s['address'] in MOVED_TO_CAVE:
                        note += ' - this site now belongs to a cave'
                    bad.append(note)
        self.assertEqual(bad, [], '\n' + '\n'.join(bad))

    def test_a_site_moved_to_a_cave_is_not_a_byte_site(self):
        by = {s['address'] for s in self.sites}
        for address, (insn, hexbytes) in MOVED_TO_CAVE.items():
            self.field_of(address, insn, hexbytes)
            self.assertNotIn(address, by, f'{address:#x} is patched as one byte again')

    def test_the_rewind_pointer_cave_holds_the_value_for_every_allowed_count(self):
        """FUN_140415bf0+34: the 5-byte store is re-encoded with a 32-bit displacement that the component writes into the cave."""
        c, = parse_inc(open(INC_REWIND, encoding='utf-8').read())
        self.assertEqual((c['start'], c['old'].hex()), (0x140415C24, '488944df40'))
        self.assertEqual(self.image.read(c['start'], 5), c['old'])
        with open(os.path.join(PLANS, 'rewind-pointer.plan.json'), encoding='utf-8') as f:
            plan_file, = json.load(f)['caves']
        self.assertEqual((plan_file['cave_bytes'], plan_file['old_bytes'], plan_file['fixups'], plan_file['retargets']), (c['cave'].hex(), c['old'].hex(), [], []))
        cp.self_check(plan_file, cp.decode(c['old'], c['start']))     # the cave means the same instruction as the window
        cs = cp._cs()
        stock, = cs.disasm(c['old'], c['start'])
        self.assertEqual((c['cave'][:4].hex(), len(c['cave'])), ('488984df', 8))
        # the displacement is written at cave offset 4 by the C++ (pinned below)
        self.assertRegex(self.text, r'std::memcpy\(bytes\.data\(\) \+ 4, &disp, 4\)')
        self.assertIn('const std::uint32_t disp = L.rewind_pointers();', self.text)
        for n in SITE_COUNTS:
            want = layout_names(n)['l_rewind_pointers']
            bytes_ = c['cave'][:4] + want.to_bytes(4, 'little')
            new, = cs.disasm(bytes_, c['start'])
            self.assertEqual(new.size, 8)
            self.assertEqual(new.encoding.disp_size, 4)
            self.assertEqual((new.mnemonic, new.operands[1].reg, new.operands[0].mem.base, new.operands[0].mem.index,
                              new.operands[0].mem.scale, new.operands[0].mem.disp),
                             (stock.mnemonic, stock.operands[1].reg, stock.operands[0].mem.base, stock.operands[0].mem.index,
                              stock.operands[0].mem.scale, want))
            # the planner re-encodes the same instruction the same way for this displacement
            plan, = cp.plan([{'address': c['start'], 'kind': 'disp', 'new_disp': want, 'force32': True}], self.image, scan=False)
            self.assertEqual(bytes.fromhex(plan['cave_bytes']), bytes_, f'{n} agents')
        # the placeholder in the table is not a layout value
        self.assertEqual(int.from_bytes(c['cave'][4:8], 'little'), 0x7FFFFFF0)


def magic(row):
    return 0x5A5A0000 | row


class WideSites(unittest.TestCase):
    """The 34 count fields of a29 section 2.1 that are 32-bit now: caves of single instructions plus the two-window imul pair of row 37, the
    two 16-bit compares and the lea + shl of 0x140C68A96 in place. Offline proof for every count from 24 to 320: each cave decodes to the
    shipped instruction with its field holding the intended value; at 24 agents every field holds the shipped value."""

    def setUp(self):
        self.image, self.source = find_image()
        if self.image is None:
            self.skipTest('no unpacked code files or analysed image on this machine')
        self.text = open(CPP, encoding='utf-8').read()
        self.hpp = open(HPP, encoding='utf-8').read()
        self.caves = parse_inc(open(INC_WIDE, encoding='utf-8').read())
        self.cs = cp._cs()

    def holder(self, row):
        """-> (cave, offset of the placeholder in it): exactly one placeholder a row over all caves."""
        want = magic(row).to_bytes(4, 'little')
        hits = [(c, at) for c in self.caves for at in range(len(c['cave']) - 3) if c['cave'][at:at + 4] == want]
        self.assertEqual(len(hits), 1, f'row {row}: {len(hits)} placeholders')
        return hits[0]

    def decode_at(self, cave_bytes, field_offset, start=0x150000000):
        """The instruction of the cave whose imm32 / disp32 is at field_offset: (instruction, 'imm' or 'disp')."""
        for i in self.cs.disasm(cave_bytes, start):
            e = i.encoding
            off = i.address - start
            if e.imm_size == 4 and off + e.imm_offset == field_offset:
                return i, 'imm'
            if e.disp_size == 4 and off + e.disp_offset == field_offset:
                return i, 'disp'
        self.fail(f'no instruction has its imm32/disp32 at cave offset {field_offset}')

    @staticmethod
    def shape(i):
        """Mnemonic and operands without the immediate / displacement value."""
        ops = []
        for o in i.operands:
            if o.type == 1:
                ops.append(('r', o.reg, o.size))
            elif o.type == 2:
                ops.append(('i', o.size))
            else:
                ops.append(('m', o.mem.base, o.mem.index, o.mem.scale, o.size))
        return i.mnemonic, tuple(ops)

    @staticmethod
    def field_value(i, kind):
        return i.operands[-1].imm if kind == 'imm' else next(o.mem.disp for o in i.operands if o.type == 3)

    def test_the_inc_is_the_plan_and_the_windows_match_the_shipped_code(self):
        plan = json.load(open(os.path.join(PLANS, 'wide-sites.plan.json'), encoding='utf-8'))['caves']
        self.assertEqual(len(plan), len(self.caves))
        for p_, c in zip(plan, self.caves):
            self.assertEqual((int(p_['window_start'], 0), p_['old_bytes'], p_['cave_bytes']), (c['start'], c['old'].hex(), c['cave'].hex()))
            self.assertEqual(self.image.read(c['start'], len(c['old'])), c['old'], f"{c['start']:#x}: the shipped bytes differ")
            cp.self_check(p_, cp.decode(c['old'], c['start']))
        self.assertEqual(len(plan), 35, '34 sites: 33 single-instruction caves, the imul of row 37 in two')

    def test_the_requests_reproduce_the_plan(self):
        if not os.path.exists(cp.DEFAULT_DB):
            self.skipTest('the planner needs the engine database to rule out raw branch hits')
        reqs = json.load(open(os.path.join(PLANS, 'wide-sites.requests.json'), encoding='utf-8'))
        plan = json.load(open(os.path.join(PLANS, 'wide-sites.plan.json'), encoding='utf-8'))['caves']
        got = cp.plan(reqs, self.image, cp.EngineDb(cp.DEFAULT_DB))
        self.assertEqual([(c['window_start'], c['old_bytes'], c['cave_bytes']) for c in got],
                         [(c['window_start'], c['old_bytes'], c['cave_bytes']) for c in plan])

    def test_every_row_is_one_placeholder_in_the_instruction_the_table_names(self):
        self.assertEqual(sorted(WIDE_SITES), [r for r in range(1, 38) if r not in (18, 19, 36)])
        for row, (address, hx, name) in WIDE_SITES.items():
            self.assertEqual(self.image.read(address, len(hx) // 2).hex(), hx, f'row {row}: the shipped bytes differ')
            cave, at = self.holder(row)
            i, kind = self.decode_at(cave['cave'], at)
            stock = next(self.cs.disasm(self.image.read(address, 16), address))
            if row == 37:                                              # lea + shl 3 (r * 24) became imul r, agents
                self.assertEqual((i.mnemonic, i.op_str), ('imul', 'eax, r10d, 0x5a5a0025'))
                self.assertEqual(stock.mnemonic, 'lea')
            else:
                self.assertEqual(self.shape(i), self.shape(stock), f'row {row}: {i.mnemonic} {i.op_str} is not {stock.mnemonic} {stock.op_str}')
                self.assertEqual(kind, 'disp' if stock.mnemonic == 'lea' else 'imm', f'row {row}')
                self.assertEqual(i.size, stock.size + 3, f'row {row}: an imm8/disp8 became an imm32/disp32 (+3 bytes)')

    def test_every_field_holds_the_intended_value_for_every_count_and_the_shipped_one_at_24(self):
        table = self.text.split('wide_sites[] = {')[1].split('};')[0]
        cpp = {int(m.group(1)): m.group(2) for m in re.finditer(r'\{(\d+), wide_field::(\w+)\}', table)}
        self.assertEqual(sorted(cpp), sorted(WIDE_SITES), 'the rows of wide_sites in the .cpp are the rows of the test')
        kinds = {'player_corpses': 'l_player_corpses', 'agent_corpses': 'l_agent_corpses', 'minus_agent_corpses': '-l_agent_corpses',
                 'characters': 'l_characters', 'characters_less_one': 'l_characters - 1', 'agents': 'l_agents', 'agents_less_players': 'l_agents - 18'}
        for row, (address, hx, name) in WIDE_SITES.items():
            self.assertEqual(kinds[cpp[row]], name, f'row {row}: wide_field in the .cpp')
            cave, at = self.holder(row)
            stock = next(self.cs.disasm(self.image.read(address, 16), address))
            for n in SITE_COUNTS:
                value = evaluate(name, layout_names(n))
                self.assertTrue(-2 ** 31 <= value < 2 ** 31, f'row {row} at {n}')
                b = bytearray(cave['cave'])
                b[at:at + 4] = (value & 0xFFFFFFFF).to_bytes(4, 'little')
                i, kind = self.decode_at(bytes(b), at)
                self.assertEqual(self.field_value(i, kind), value, f'row {row} at {n} agents')
                if n == 24 and row != 37:                              # the shipped value: the cave is the shipped instruction
                    self.assertEqual(self.field_value(i, kind), self.field_value(stock, kind), f'row {row}: at 24 agents the field must hold the shipped value')
                if n == 24 and row == 37:                              # lea r*3 then shl 3 = r * 24
                    self.assertEqual(value, 24)
        # the hpp mirror of the names
        for text in ('case wide_field::characters: return characters;', 'case wide_field::characters_less_one: return static_cast<std::int64_t>(characters) - 1;',
                     'case wide_field::agent_corpses: return agent_corpses;', 'case wide_field::minus_agent_corpses: return -static_cast<std::int64_t>(agent_corpses);',
                     'case wide_field::agents_less_players: return static_cast<std::int64_t>(agents) - players;'):
            self.assertIn(text, self.hpp)

    def test_the_imul_pair_and_the_in_place_sites(self):
        # row 37: window 1 = imul + the 7-byte mov [rip], r8d; window 2 = shl eax, 3 (becomes a 3-byte nop) + mov [rip], eax
        starts = {c['start']: c for c in self.caves}
        self.assertEqual(starts[0x140C68A8D]['old'][:3].hex(), 'c1e003')
        self.assertEqual(starts[0x140C68A8D]['cave'][:3].hex(), '0f1f00')
        self.assertEqual(starts[0x140C68A82]['cave'][:3].hex(), '4169c2')
        # in place: 66 83 f8 2a -> 66 3d iw (cmp ax, imm16, the same 4 bytes), and lea + shl (7 bytes) -> imul r11d, agents (7 bytes)
        for row, (address, hx, name) in IN_PLACE_SITES.items():
            self.assertEqual(self.image.read(address, len(hx) // 2).hex(), hx, f'row {row}')
        windows = [(c['start'], c['start'] + len(c['old'])) for inc in (INC, INC_REWIND, INC_WIDE, INC_MASK, INC_GUARD, INC_INTERP) for c in parse_inc(open(inc, encoding='utf-8').read())]
        for address in (0x14077EDEB, 0x1407801DB):
            self.assertFalse([w for w in windows if w[0] < address + 4 and address < w[1]], f'{address:#x} overlaps a cave window')
        self.assertIn('wide16(0x14077EDEB, l.characters)', self.text)
        self.assertIn('wide16(0x1407801DB, l.characters)', self.text)
        self.assertRegex(self.text, r'block\(0x140C68A96, std::array<std::uint8_t, 7>\{0x43, 0x8d, 0x04, 0x5b, 0xc1, 0xe0, 0x03\}')
        self.assertIn('std::array<std::uint8_t, 7>{0x41, 0x69, 0xc3, static_cast<std::uint8_t>(l.agents), static_cast<std::uint8_t>(l.agents >> 8), 0, 0}', self.text)
        self.assertIn('if (value > 0xFFFF) throw', self.text)
        stock16, = self.cs.disasm(self.image.read(0x14077EDEB, 4), 0x14077EDEB)
        for n in SITE_COUNTS:
            c = 18 + n
            i, = self.cs.disasm(bytes([0x66, 0x3d, c & 0xFF, c >> 8]), 0x14077EDEB)
            self.assertEqual((i.mnemonic, i.size, i.operands[1].imm, i.operands[0].reg), ('cmp', 4, c, stock16.operands[0].reg), f'{n} agents')
            i, = self.cs.disasm(bytes([0x41, 0x69, 0xc3, n & 0xFF, n >> 8, 0, 0]), 0x140C68A96)
            self.assertEqual((i.mnemonic, i.op_str, i.size), ('imul', f'eax, r11d, {n:#x}', 7), f'{n} agents')
        # at 24 agents: imul by 24 is the lea r*3 << 3 of the shipped code
        lea, shl = self.cs.disasm(self.image.read(0x140C68A96, 7), 0x140C68A96)
        self.assertEqual((lea.mnemonic, shl.mnemonic, shl.operands[1].imm), ('lea', 'shl', 3))

    def test_the_net_bit_counts_follow_the_count_of_characters(self):
        self.assertIn('constexpr std::uint32_t net_id_bits() const { return characters <= 127 ? 7 : (characters <= 256 ? 8 : 9); }', self.hpp)
        self.assertEqual(len(re.findall(r'add\(f, 6, l\.net_id_bits\(\)', self.text)), 3, 'agent-state loop, 21-list loop, 3-list loop')
        self.assertNotRegex(self.text, r'add\(f, 6, 7')
        bits = {n: (7 if 18 + n <= 127 else (8 if 18 + n <= 256 else 9)) for n in SITE_COUNTS}
        self.assertTrue(all(b == 7 for n, b in bits.items() if n <= 100), 'unchanged (7 bits) at every count up to 100')
        self.assertEqual([n for n, b in bits.items() if b == 8][0], 112)
        self.assertEqual([n for n, b in bits.items() if b == 9][0], 240)
        self.assertEqual(max(n for n, b in bits.items() if b == 8), 236)

    def test_the_refuse_mirror_matches_the_hpp(self):
        for text in ('constexpr std::uint32_t frame_cave_max_extra_a = 0x52E0, frame_cave_max_extra_b = 0x1280, frame_cave_max_extra_c = 0x2500;',
                     'constexpr std::uint32_t snap_mask_room = 48;', 'constexpr std::uint32_t max_analysed_agents = 320;',
                     'if (((c + 31) / 32) * 4 > snap_mask_room) return', '(((2 * slots - 71) * 32 + 15) & ~15u) > frame_cave_max_extra_a',
                     '(slots - 71) * 32 > frame_cave_max_extra_c', '(slots - 71) * 16 > frame_cave_max_extra_b'):
            self.assertIn(text, self.hpp)
        # the probe caves' planned maxima are the ones in the generated tables
        for name, want in (('agent_capacity_frame_cave.inc', 0x52E0), ('agent_capacity_frame_cave_added0.inc', 0x2500), ('agent_capacity_frame_cave_adb8e0.inc', 0x1280)):
            m = re.search(r'^\{0x[0-9a-f]+ull, \{[^}]*\}, \{[^}]*\}, \d+, 0x[0-9a-f]+u, (0x[0-9a-f]+)u, \d+\},$', open(src(name), encoding='utf-8').read(), re.M)
            self.assertEqual(int(m.group(1), 16), want, name)
        accepted = [n for n in range(0, 1100) if refuse_mirror(n) == '']
        self.assertEqual(accepted, list(range(24, 321, 4)))
        self.assertEqual(refuse_mirror(324), 'more than 320 agents')
        reasons = {}
        for n in SITE_COUNTS:
            reasons.setdefault(refuse_mirror(n), []).append(n)
        print('\nrefuse() by count (24..320, valid counts): ' + '; '.join(f'{k or "accepted"}: {v[0]}..{v[-1]}' for k, v in reasons.items()))
        print(f'highest count the byte and count sites accept: {SITE_COUNTS[-1]}; highest count refuse() accepts: {accepted[-1]}')
        self.assertEqual(SITE_COUNTS[-1], 320)


def src(name):
    return os.path.join(ROOT, 'src', 'native', name)


# the three frame-grow tables: plan file, generated tables, function and the run-time formula of X (the hpp lines pinned below)
FRAME_TABLES = [
    {'plan': 'frame-1403e61b0.frame.json', 'fields': 'agent_capacity_frame_fields.inc', 'cave': 'agent_capacity_frame_cave.inc',
     'function': 0x1403E61B0, 'entry': 32, 'formula': '((2 * sentient_slots() - 71) * 32 + 15) & ~15u',
     'extra': lambda n: ((2 * (71 + n - 24) - 71) * 32 + 15) & ~15, 'need': lambda n: (2 * (71 + n - 24) - 71) * 32},
    {'plan': 'frame-140adb8e0.frame.json', 'fields': 'agent_capacity_frame_fields_adb8e0.inc', 'cave': 'agent_capacity_frame_cave_adb8e0.inc',
     'function': 0x140ADB8E0, 'entry': 16, 'formula': 'frame_extra_b() const { return (sentient_slots() - 71) * 16; }',
     'extra': lambda n: (n - 24) * 16, 'need': lambda n: (n - 24) * 16},
    {'plan': 'frame-140added0.frame.json', 'fields': 'agent_capacity_frame_fields_added0.inc', 'cave': 'agent_capacity_frame_cave_added0.inc',
     'function': 0x140ADDED0, 'entry': 32, 'formula': 'frame_extra_c() const { return (sentient_slots() - 71) * 32; }',
     'extra': lambda n: (n - 24) * 32, 'need': lambda n: (n - 24) * 32},
    # CG_SetNextSnap: a constant room for the 12-word change mask (planned with two bounded index regions and rbp as an ordinary register)
    {'plan': 'frame-14086fba0.frame.json', 'fields': 'agent_capacity_frame_fields_86fba0.inc', 'cave': None,
     'function': 0x14086FBA0, 'entry': 4, 'formula': 'constexpr std::uint32_t snap_mask_room = 48;',
     'extra': lambda n: 48, 'need': lambda n: ((18 + n + 31) // 32) * 4},
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
                    doc = frame_grow.plan_frame_grow(self.image, t['function'], plan['array_top'], plan['extra'], plan['max_extra'], db=db,
                                                     bounded=tuple(tuple(b) for b in plan.get('bounded_index', ())), rbp_general=plan.get('rbp_general', False))
                except cp.Refusal as e:
                    if db is not None or not plan['cave']:
                        raise
                    self.skipTest('the probe cave of %s needs the engine database to rule out raw branch hits: %s' % (t['plan'], e.reasons))
                self.assertEqual(doc['fields'], plan['fields'])
                self.assertEqual((doc['cave'] or {}).get('cave_bytes'), (plan['cave'] or {}).get('cave_bytes'))
                frame_grow.self_check(self.image, doc, extras=[16 * k for k in range(1, 4)] + [t['extra'](n) for n in range(28, 321, 4)])

    def test_the_run_time_arithmetic_for_every_agent_count(self):
        import frame_grow
        hpp = open(HPP, encoding='utf-8').read()
        for t in FRAME_TABLES:
            with self.subTest(t['plan']):
                self.assertIn(t['formula'], hpp)                    # the formula this test repeats
                fields = self.parse_fields(t['fields'])
                plan = t['doc']
                cave = plan['cave']
                for n in SITE_COUNTS:
                    extra = t['extra'](n)
                    self.assertLessEqual(extra, plan['max_extra'])
                    # the room holds what the function stores at this count: one entry per sentient slot beyond the stock 71 (each loop), or the mask words
                    self.assertGreaterEqual(extra, t['need'](n))
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
        caves = parse_inc(open(INC, encoding='utf-8').read()) + parse_inc(open(INC_REWIND, encoding='utf-8').read()) + parse_inc(open(INC_WIDE, encoding='utf-8').read()) + parse_inc(open(INC_MASK, encoding='utf-8').read()) + parse_inc(open(INC_GUARD, encoding='utf-8').read()) + parse_inc(open(INC_INTERP, encoding='utf-8').read())
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

    def test_the_build_copies_every_file_the_cpp_includes(self):
        """A new `#include "x.inc"` that Build-Voice.ps1 does not copy into the native tree fails the build (error C1083)."""
        with open(os.path.join(ROOT, 'ops', 'Build-Voice.ps1'), encoding='utf-8') as f:
            build = f.read()
        copied = set(re.findall(r"'(agent_capacity[\w]*\.(?:cpp|hpp|inc))'", build.split('foreach ($capFile in @(')[1].split(')')[0]))
        with open(CPP, encoding='utf-8') as f:
            included = set(re.findall(r'#include "(agent_capacity[\w]*\.(?:hpp|inc))"', f.read()))
        self.assertEqual(sorted(included - copied), [], 'included by agent_capacity.cpp but not copied by ops/Build-Voice.ps1')

    def test_the_cpp_sees_every_table(self):
        text = open(CPP, encoding='utf-8').read()
        for name in ('agent_capacity_frame_fields.inc', 'agent_capacity_frame_fields_adb8e0.inc', 'agent_capacity_frame_fields_added0.inc',
                     'agent_capacity_frame_cave.inc', 'agent_capacity_frame_cave_added0.inc', 'agent_capacity_frame_cave_adb8e0.inc',
                     'agent_capacity_frame_fields_86fba0.inc', 'agent_capacity_caves_mask.inc', 'agent_capacity_caves_guard.inc', 'agent_capacity_caves_interp.inc', 'agent_capacity_state.inc'):
            self.assertIn('#include "%s"' % name, text)
        reserve = text.split('void plan_caves()')[1]
        for sets in ('frame_caves_a', 'frame_caves_b', 'frame_caves_c', 'frame_caves_d', 'mask_cave_table', 'guard_cave_table', 'interp_cave_table'):
            self.assertIn(sets, reserve, 'the probe caves of every function are reserved')


from capstone.x86 import X86_REG_RSP  # noqa: E402


class MaskSites(unittest.TestCase):
    """CG_SetNextSnap's character change mask (a34): the five instructions of the shipped function that used [rsp+0x40] (two 32-bit words) are
    caves with the mask at [rsp+0x170, +0x190) (12 words = 384 characters since a57), in the room the frame grow of 0x14086FBA0 opens below the cookie."""
    ROOM_START, ROOM = 0x170, 48

    def setUp(self):
        self.image, self.source = find_image()
        if self.image is None:
            self.skipTest('no unpacked code files or analysed image on this machine')
        self.caves = {c['start']: c for c in parse_inc(open(INC_MASK, encoding='utf-8').read())}
        self.cs = cp._cs()

    def test_the_five_sites_are_the_stock_mask_accesses_and_the_caves_mean_the_same_at_the_new_offset(self):
        self.assertEqual(sorted(self.caves), [0x14086FE6C, 0x14086FE74, 0x14086FE83, 0x14087066D, 0x1408706CD])
        for start, c in self.caves.items():
            self.assertEqual(self.image.read(start, len(c['old'])), c['old'], f'{start:#x} stock window')
            stock = next(self.cs.disasm(c['old'], start))
            self.assertEqual(stock.operands[1].mem.disp if stock.mnemonic == 'lea' else
                             next(o for o in stock.operands if o.type == 3).mem.disp, 0x40, f'{start:#x} used [rsp+0x40]')
            new = list(self.cs.disasm(c['cave'], 0))
            first = new[0]
            self.assertEqual(first.mnemonic, stock.mnemonic)
            mem = next(o for o in first.operands if o.type == 3).mem
            self.assertEqual((mem.base, mem.index, mem.scale, mem.disp), (lambda m: (m.base, m.index, m.scale, self.ROOM_START))(
                next(o for o in stock.operands if o.type == 3).mem), f'{start:#x} the same address form, the mask at 0x170')
            self.assertEqual(first.encoding.disp_size, 4)
            if stock.mnemonic == 'mov' and stock.operands[0].type == 3:          # the store: all 12 words are cleared (rax is 0 there)
                stores = [(i.mnemonic, i.operands[1].reg, next(o for o in i.operands if o.type == 3).mem.disp) for i in new]
                self.assertEqual([d for _, _, d in stores], [0x170, 0x178, 0x180, 0x188, 0x190, 0x198])
                self.assertEqual({m for m, _, _ in stores}, {'mov'})
                self.assertEqual(len({r for _, r, _ in stores}), 1)
        self.assertEqual(self.ROOM_START + self.ROOM, 0x1A0)

    def test_nothing_else_of_the_function_touches_the_room_and_the_index_claims_hold(self):
        """In the shipped function the only stack accesses at or above 0x170 are the cookie (store and check) and the saved rbp (0x1d0); the indexed
        accesses are on the 0x100-byte entity bit array at 0x70 (index = entity number >> 5, 64 dwords) or on the mask at 0x40."""
        start, end = 0x14086FBA0, 0x140870808
        raw = self.image.read(start, end - start)
        high, indexed = [], set()
        for i in self.cs.disasm(raw, start):
            for o in i.operands:
                if o.type == 3 and o.mem.base == X86_REG_RSP:
                    if o.mem.index:
                        indexed.add(o.mem.disp)
                    elif o.mem.disp >= self.ROOM_START:
                        high.append((i.address, o.mem.disp))
        self.assertEqual(sorted({d for _, d in high}), [0x170, 0x1D0])
        self.assertEqual(sorted(indexed), [0x40, 0x70])
        # the memset of the shipped function clears 0x100 bytes at 0x70: exactly the bit array indexed above
        self.assertEqual(self.image.read(0x14086FBDC, 5).hex(), '488d4c2470')
        self.assertEqual(self.image.read(0x14086FBE1, 6).hex(), '41b800010000')

    def test_the_frame_plan_opens_the_room_and_the_component_pins_it(self):
        plan = json.load(open(os.path.join(PLANS, 'frame-14086fba0.frame.json'), encoding='utf-8'))
        self.assertEqual((plan['array_top'], plan['extra'], plan['max_extra'], plan['cave']), (0x170, 48, 48, None))
        self.assertEqual(plan['bounded_index'], [[0x40, 0x50], [0x70, 0x170]])
        roles = {f['role'] for f in plan['fields']}
        self.assertIn('frame-sub', roles)
        hpp = open(HPP, encoding='utf-8').read()
        self.assertIn('constexpr std::uint32_t snap_mask_room = 48;', hpp)
        text = open(CPP, encoding='utf-8').read()
        self.assertIn('frame_sets.push_back({"14086FBA0", frame_fields_d, frame_caves_d, snap_mask_room});', text)
        for n in SITE_COUNTS:
            self.assertLessEqual(((18 + n + 31) // 32) * 4, self.ROOM, f'{n} agents: the mask words fit the room')
        self.assertNotRegex(text, r'add1s\(0x14086F')
        self.assertNotRegex(text, r'add1s\(0x140870')


if __name__ == '__main__':
    unittest.main()
