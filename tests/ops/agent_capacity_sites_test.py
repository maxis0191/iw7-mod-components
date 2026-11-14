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
    for m in re.finditer(r'^\{(0x[0-9a-f]+)ull, \{([^}]*)\}, \{([^}]*)\}, \{((?:\{[^}]*\},?)*)\}\},$', text, re.M):
        fix = [{'offset': int(a), 'end': int(b), 'target': int(t.replace('ull', ''), 16)}
               for a, b, t in re.findall(r'\{(\d+),(\d+),(0x[0-9a-f]+ull)\}', m.group(4))]
        out.append({'start': int(m.group(1).replace('ull', ''), 16), 'old': byte_list(m.group(2)),
                    'cave': byte_list(m.group(3)), 'fixups': fix})
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
        return cp.PlainImage(parts), 'unpacked sections'
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
        self.assertEqual(len(sites), 12)

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

    def test_every_cave_window_matches_and_the_cave_means_the_same(self):
        caves = parse_inc(open(INC, encoding='utf-8').read())
        plans = {}
        for name in (sorted(os.listdir(PLANS)) if os.path.isdir(PLANS) else []):
            if name.endswith('.json') and not name.endswith('.requests.json'):
                for c in json.load(open(os.path.join(PLANS, name), encoding='utf-8'))['caves']:
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
        print(f'\ncave windows checked: {len(caves)}')


if __name__ == '__main__':
    unittest.main()
