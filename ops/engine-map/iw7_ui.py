#!/usr/bin/env python3
"""Reader for user-interface dumps of the lab client (schema iw7.ui-dump/1, written by `paris_ui_dump`).

  show    DUMP                 the server-drawn HUD elements as a table and the Lua UI tree, compact
  find    DUMP --text REGEX    elements whose text (or --id REGEX: name) matches
  check   DUMP                 defects that need no picture: off screen, overlapping texts, clipped by the parent,
                               zero size, text too small. Exit 1 when one is found
  diff    A B                  what appeared, disappeared, moved or changed text between two dumps
  expect  DUMP RULES.json      rules as a verdict: exit 0 when every rule holds, 1 otherwise
  frame   DUMP FRAME.bmp       do the rectangles agree with a frame captured at the same moment (--base: a frame without them)

Every rectangle is in screen pixels of the dump's own resolution, origin at the top left. See docs/UI-DUMP.md.
"""
import argparse
import json
import re
import struct
import sys

SCHEMA = 'iw7.ui-dump/1'
HUD_TYPES = {0: 'free', 1: 'text', 2: 'value', 3: 'playername', 4: 'material', 5: 'timer_down', 6: 'timer_up', 7: 'timer_static',
             8: 'tenths_timer_down', 9: 'tenths_timer_up', 10: 'tenths_timer_static', 11: 'clock_down', 12: 'clock_up', 13: 'waypoint'}
ALIGN_X = {0: 'left', 1: 'center', 2: 'right'}
ALIGN_Y = {0: 'top', 1: 'middle', 2: 'bottom'}
# Offsets inside the client's copy of one HUD element (0xB8 bytes), read from the game's own layout and draw code.
HUD_FIELDS = (('x', 0x04, 'f'), ('y', 0x08, 'f'), ('z', 0x0C, 'f'), ('target_ent', 0x10, 'i'), ('lerp_value', 0x14, 'f'),
              ('lerp_from', 0x18, 'f'), ('lerp_start', 0x1C, 'i'), ('lerp_time', 0x20, 'i'), ('font_scale', 0x24, 'f'),
              ('from_font_scale', 0x28, 'f'), ('font_scale_start', 0x2C, 'i'), ('font_scale_time', 0x30, 'i'), ('font', 0x34, 'i'),
              ('align_org', 0x38, 'i'), ('align_screen', 0x3C, 'i'), ('fade_start', 0x48, 'i'), ('fade_time', 0x4C, 'i'),
              ('label', 0x50, 'i'), ('width', 0x54, 'i'), ('height', 0x58, 'i'), ('material_index', 0x5C, 'i'),
              ('from_width', 0x60, 'i'), ('from_height', 0x64, 'i'), ('scale_start', 0x68, 'i'), ('scale_time', 0x6C, 'i'),
              ('from_x', 0x70, 'f'), ('from_y', 0x74, 'f'), ('from_align_org', 0x78, 'i'), ('from_align_screen', 0x7C, 'i'),
              ('move_start', 0x80, 'i'), ('move_time', 0x84, 'i'), ('time', 0x88, 'i'), ('duration', 0x8C, 'i'),
              ('value', 0x90, 'f'), ('text_index', 0x94, 'i'), ('sort', 0x98, 'f'), ('flags', 0xB4, 'I'))
HUD_COLORS = (('color', 0x40), ('from_color', 0x44), ('glow_color', 0x9C))


class DumpError(Exception):
    pass


def decode_hud_raw(raw_hex):
    """The fields of one HUD element as the client holds it. Unknown bytes stay available in the dump's "raw"."""
    try:
        raw = bytes.fromhex(raw_hex)
    except ValueError:
        raise DumpError('a HUD element has a "raw" that is not hexadecimal')
    if len(raw) < 0xB8:
        raise DumpError('a HUD element has %d raw bytes, expected at least 184' % len(raw))
    out = {'type': struct.unpack_from('<i', raw, 0)[0]}
    for name, at, kind in HUD_FIELDS:
        out[name] = struct.unpack_from('<' + kind, raw, at)[0]
    for name, at in HUD_COLORS:
        out[name] = [raw[at], raw[at + 1], raw[at + 2], raw[at + 3]]
    out['type_name'] = HUD_TYPES.get(out['type'], 'type_%d' % out['type'])
    out['align_x'] = ALIGN_X.get((out['align_org'] >> 2) & 3, '?')
    out['align_y'] = ALIGN_Y.get(out['align_org'] & 3, '?')
    out['horz_align'] = (out['align_screen'] >> 4) & 15
    out['vert_align'] = out['align_screen'] & 15
    return out


def strip_colors(text):
    """Text as a player reads it: the game's colour codes (^0 to ^9, ^:) removed."""
    return re.sub(r'\^[0-9:;]', '', text or '')


def load(path):
    try:
        with open(path, encoding='utf-8') as f:
            data = json.load(f)
    except (OSError, ValueError) as e:
        raise DumpError('%s: %s' % (path, e))
    if not isinstance(data, dict) or data.get('schema') != SCHEMA:
        raise DumpError('%s: not a %s file' % (path, SCHEMA))
    screen = data.get('screen') or {}
    if not isinstance(screen.get('width'), int) or not isinstance(screen.get('height'), int) or screen['width'] <= 0 or screen['height'] <= 0:
        raise DumpError('%s: no screen size' % path)
    return data


def elements(data):
    """Both layers as one flat list of dicts: layer, index, parent, depth, name, kind, rect (x0, y0, x1, y1) or None,
    text, alpha (own times every ancestor's), visible, clips (the element cuts its children), image."""
    out = []
    hud = data.get('hud') or {}
    for e in hud.get('elements') or []:
        f = decode_hud_raw(e.get('raw', ''))
        rect = None
        if e.get('drawn') and isinstance(e.get('rect'), list) and len(e['rect']) == 4:
            x, y, w, h = e['rect']
            rect = (x, y, x + w, y + h)
        text = (e.get('label') or '') + (e.get('text') or '')
        alpha = e['color'][3] if isinstance(e.get('color'), list) and len(e['color']) == 4 else f['color'][3] / 255.0
        kind = 'text' if text else ('image' if f['type_name'] == 'material' or e.get('material') else f['type_name'])
        out.append({'layer': 'hud', 'index': e.get('i', len(out)), 'parent': None, 'depth': 0, 'name': 'hud%d' % e.get('i', len(out)),
                    'kind': kind, 'rect': rect, 'text': text, 'alpha': alpha, 'visible': bool(e.get('drawn')) and alpha > 0.004 and rect is not None,
                    'clips': False, 'image': e.get('material') or '', 'sort': f['sort'], 'fields': f,
                    'text_height': e.get('font_height'), 'font': e.get('font') or ''})
    lui = data.get('lui') or {}
    rows = lui.get('elements') or []
    base = len(out)
    alphas = {}
    hidden = {}
    for e in rows:
        i, p = e.get('i'), e.get('p', -1)
        own = e.get('alpha', 1.0)
        own = 1.0 if not isinstance(own, (int, float)) else float(own)
        alpha = own * alphas.get(p, 1.0)
        alphas[i] = alpha
        off = bool(e.get('hidden')) or hidden.get(p, False)
        hidden[i] = off
        rect = None
        if isinstance(e.get('rect'), list) and len(e['rect']) == 4 and all(isinstance(v, (int, float)) for v in e['rect']):
            rect = tuple(float(v) for v in e['rect'])
        text = e.get('text') or ''
        image = e.get('image') or ''
        kind = e.get('kind') or ('text' if text else ('image' if image else 'element'))
        out.append({'layer': 'lui', 'index': i, 'parent': (base + p) if isinstance(p, int) and p >= 0 else None, 'depth': e.get('d', 0),
                    'name': str(e.get('id', '')), 'kind': kind, 'rect': rect, 'text': text, 'alpha': alpha,
                    'visible': not off and alpha > 0.004 and rect is not None, 'clips': bool(e.get('clips')), 'image': image,
                    'text_height': e.get('text_height'), 'font': e.get('font') or '', 'children': 0})
    for e in out:
        if e['layer'] == 'lui' and e['parent'] is not None:
            out[e['parent']]['children'] += 1
    return out


def path_of(els, i):
    """A stable name for a Lua UI element: the names from the root down, unnamed levels as '*'."""
    parts = []
    while i is not None:
        e = els[i]
        parts.append(e['name'] or '*')
        i = e['parent']
    return '/'.join(reversed(parts))


def label(els, i):
    e = els[i]
    if e['layer'] == 'hud':
        return '%s %s' % (e['name'], json.dumps(strip_colors(e['text'])[:40]) if e['text'] else ('[%s]' % (e['image'] or e['kind'])))
    return '%s %s' % (path_of(els, i), json.dumps(strip_colors(e['text'])[:40]) if e['text'] else ('[%s]' % e['image'] if e['image'] else ''))


def fmt_rect(r):
    if r is None:
        return '-'
    return '%d,%d %dx%d' % (round(r[0]), round(r[1]), round(r[2] - r[0]), round(r[3] - r[1]))


def area(r):
    return max(0.0, r[2] - r[0]) * max(0.0, r[3] - r[1])


def intersect(a, b):
    r = (max(a[0], b[0]), max(a[1], b[1]), min(a[2], b[2]), min(a[3], b[3]))
    return r if r[2] > r[0] and r[3] > r[1] else None


def is_ancestor(els, a, b):
    """True when a is b or above b."""
    while b is not None:
        if b == a:
            return True
        b = els[b]['parent']
    return False


def has_content(e):
    return bool(e['text'] or e['image'])


# ---------------------------------------------------------------------------------------------------------------------
# show, find
# ---------------------------------------------------------------------------------------------------------------------

def cmd_show(args):
    data = load(args.dump)
    els = elements(data)
    s = data['screen']
    hud = [e for e in els if e['layer'] == 'hud']
    lui = [e for e in els if e['layer'] == 'lui']
    print('%s  map %s  screen %dx%d  hud %d  lui %d' % (data.get('tag') or '-', data.get('map') or '-', s['width'], s['height'], len(hud), len(lui)))
    if args.layer in ('all', 'hud'):
        print('HUD elements (server-drawn): #  type  rect  sort  alpha  align  text or material')
        for e in hud:
            f = e['fields']
            print('  %-3d %-9s %-18s %5g %5.2f  %s/%s %d/%d  %s' % (
                e['index'], f['type_name'], fmt_rect(e['rect']), f['sort'], e['alpha'], f['align_x'], f['align_y'], f['horz_align'], f['vert_align'],
                json.dumps(e['text']) if e['text'] else (e['image'] or ('(not drawn)' if e['rect'] is None else ''))))
    if args.layer in ('all', 'lui'):
        err = (data.get('lui') or {}).get('error')
        if err:
            print('Lua UI: no tree (%s)' % err)
        else:
            print('Lua UI tree: name  rect  alpha  text or image')
        shown = 0
        for e in lui:
            if args.depth is not None and e['depth'] > args.depth:
                continue
            if args.visible and not e['visible']:
                continue
            if args.content and not has_content(e):
                continue
            if shown >= args.max:
                print('  ... cut at %d rows (--max)' % args.max)
                break
            shown += 1
            extra = json.dumps(e['text']) if e['text'] else (('[%s]' % e['image']) if e['image'] else '')
            print('  %s%s  %s  a=%.2f%s%s  %s' % ('  ' * e['depth'], e['name'] or '*', fmt_rect(e['rect']), e['alpha'],
                                               '' if e['visible'] else ' hidden', ' clips' if e['clips'] else '', extra))
    return 0


def matches(els, text=None, name=None, layer=None, visible=None):
    t = re.compile(text, re.I) if text else None
    n = re.compile(name, re.I) if name else None
    out = []
    for i, e in enumerate(els):
        if layer and e['layer'] != layer:
            continue
        if visible is not None and e['visible'] != visible:
            continue
        if t and not (e['text'] and t.search(strip_colors(e['text']))):
            continue
        if n and not n.search(path_of(els, i) if e['layer'] == 'lui' else e['name']):
            continue
        out.append(i)
    return out


def cmd_find(args):
    if not args.text and not args.id:
        print('find: give --text or --id')
        return 2
    els = elements(load(args.dump))
    found = matches(els, args.text, args.id, None if args.layer == 'all' else args.layer)
    for i in found:
        e = els[i]
        print('%s  %s  %s  a=%.2f%s' % (e['layer'], fmt_rect(e['rect']), label(els, i), e['alpha'], '' if e['visible'] else '  hidden'))
    print('%d found' % len(found))
    return 0 if found else 1


# ---------------------------------------------------------------------------------------------------------------------
# check
# ---------------------------------------------------------------------------------------------------------------------

def check(data, min_text=None, overlap=0.10, tolerance=1.0):
    """Findings as dicts: rule, element (index into elements), other, detail. Only visible elements are judged."""
    els = elements(data)
    w, h = data['screen']['width'], data['screen']['height']
    if min_text is None:
        min_text = 10.0 * h / 720.0
    out = []
    seen = [i for i, e in enumerate(els) if e['visible']]
    for i in seen:
        e = els[i]
        r = e['rect']
        leaf = e['layer'] == 'hud' or has_content(e)
        if not leaf:
            continue
        if r[2] - r[0] <= 0 or r[3] - r[1] <= 0:
            out.append({'rule': 'ZERO_SIZE', 'element': i, 'detail': '%s has no area (%s)' % (label(els, i), fmt_rect(r))})
            continue
        inside = intersect(r, (0, 0, w, h))
        if inside is None:
            out.append({'rule': 'OFF_SCREEN', 'element': i, 'detail': '%s is wholly off screen (%s on %dx%d)' % (label(els, i), fmt_rect(r), w, h)})
        elif r[0] < -tolerance or r[1] < -tolerance or r[2] > w + tolerance or r[3] > h + tolerance:
            out.append({'rule': 'PARTLY_OFF_SCREEN', 'element': i, 'detail': '%s is %d%% off screen (%s on %dx%d)' % (
                label(els, i), round(100 * (1 - area(inside) / area(r))), fmt_rect(r), w, h)})
        if e['text'] and isinstance(e.get('text_height'), (int, float)) and 0 < e['text_height'] < min_text:
            out.append({'rule': 'SMALL_TEXT', 'element': i, 'detail': '%s is %.1f px high, under %.1f' % (label(els, i), e['text_height'], min_text)})
        p = e['parent']
        while p is not None:
            pe = els[p]
            if pe['clips'] and pe['rect'] is not None:
                kept = intersect(r, pe['rect'])
                lost = 1.0 - (area(kept) / area(r) if kept else 0.0)
                if lost > 0.02:
                    out.append({'rule': 'CLIPPED', 'element': i, 'other': p, 'detail': '%s is cut by %s: %d%% of it is outside %s' % (
                        label(els, i), path_of(els, p), round(100 * lost), fmt_rect(pe['rect']))})
                    break
            p = pe['parent']
    texts = [i for i in seen if els[i]['text'] and area(els[i]['rect']) > 0]
    for k, a in enumerate(texts):
        for b in texts[k + 1:]:
            ea, eb = els[a], els[b]
            if ea['layer'] == 'lui' and eb['layer'] == 'lui' and (is_ancestor(els, a, b) or is_ancestor(els, b, a)):
                continue
            both = intersect(ea['rect'], eb['rect'])
            if both is None:
                continue
            share = area(both) / min(area(ea['rect']), area(eb['rect']))
            if share >= overlap:
                out.append({'rule': 'TEXT_OVERLAP', 'element': a, 'other': b, 'detail': '%s and %s overlap (%d%% of the smaller, %s)' % (
                    label(els, a), label(els, b), round(100 * share), fmt_rect(both))})
    return out


def cmd_check(args):
    data = load(args.dump)
    ignore = set(x.strip().upper() for x in (args.ignore or '').split(',') if x.strip())
    found = [f for f in check(data, args.min_text, args.overlap) if f['rule'] not in ignore]
    if args.json:
        print(json.dumps({'schema': 'iw7.ui-check/1', 'dump': args.dump, 'findings': found}, indent=1))
    else:
        for f in found:
            print('%-18s %s' % (f['rule'], f['detail']))
        print('check: %d finding%s' % (len(found), '' if len(found) == 1 else 's'))
    return 1 if found else 0


# ---------------------------------------------------------------------------------------------------------------------
# diff
# ---------------------------------------------------------------------------------------------------------------------

def keyed(els):
    """Elements by a name that survives between two dumps: layer, path (or text for HUD elements), and a counter for repeats."""
    out, count = {}, {}
    for i, e in enumerate(els):
        base = (e['layer'], path_of(els, i) if e['layer'] == 'lui' else (strip_colors(e['text']) or e['image'] or e['kind']))
        k = count.get(base, 0)
        count[base] = k + 1
        out[base + (k,)] = i
    return out


def diff(a, b, tolerance=1.0):
    ea, eb = elements(a), elements(b)
    ka, kb = keyed(ea), keyed(eb)
    out = []
    for key in kb:
        if key not in ka:
            out.append(('added', label(eb, kb[key]), fmt_rect(eb[kb[key]]['rect'])))
    for key in ka:
        if key not in kb:
            out.append(('removed', label(ea, ka[key]), fmt_rect(ea[ka[key]]['rect'])))
            continue
        x, y = ea[ka[key]], eb[kb[key]]
        if x['text'] != y['text']:
            out.append(('text', label(ea, ka[key]), '%s -> %s' % (json.dumps(x['text'][:60]), json.dumps(y['text'][:60]))))
        if (x['rect'] is None) != (y['rect'] is None) or (x['rect'] and any(abs(p - q) > tolerance for p, q in zip(x['rect'], y['rect']))):
            out.append(('moved', label(ea, ka[key]), '%s -> %s' % (fmt_rect(x['rect']), fmt_rect(y['rect']))))
        if x['visible'] != y['visible']:
            out.append(('shown' if y['visible'] else 'hidden', label(ea, ka[key]), fmt_rect(y['rect'])))
    return out


def cmd_diff(args):
    rows = diff(load(args.a), load(args.b), args.tolerance)
    if args.layer != 'all':
        pass
    for kind, name, detail in rows[:args.max]:
        print('%-8s %s  %s' % (kind, name, detail))
    if len(rows) > args.max:
        print('... %d more (--max)' % (len(rows) - args.max))
    print('diff: %d change%s' % (len(rows), '' if len(rows) == 1 else 's'))
    return 1 if rows else 0


# ---------------------------------------------------------------------------------------------------------------------
# expect
# ---------------------------------------------------------------------------------------------------------------------

def select(els, sel):
    """A selector is a text pattern, or an object with any of text, id, layer."""
    if isinstance(sel, str):
        sel = {'text': sel}
    if not isinstance(sel, dict) or not (sel.get('text') or sel.get('id')):
        raise DumpError('a selector needs "text" or "id": %r' % (sel,))
    return matches(els, sel.get('text'), sel.get('id'), sel.get('layer'))


def expect(data, rules):
    """Each rule -> (ok, sentence). Rules: present (optional near [x, y] and tol), absent, visible, hidden, no_overlap [a, b],
    inside_screen, count {layer, eq|min|max}, no_findings (the check command's rules, optional ignore list)."""
    els = elements(data)
    w, h = data['screen']['width'], data['screen']['height']
    out = []
    if not isinstance(rules, list) or not rules:
        raise DumpError('the rules file is a non-empty list of rules, or an object with "rules"')
    for n, rule in enumerate(rules):
        if not isinstance(rule, dict):
            raise DumpError('rule %d is not an object' % n)
        why = (' (%s)' % rule['why']) if rule.get('why') else ''
        if 'present' in rule:
            found = [i for i in select(els, rule['present']) if els[i]['visible']]
            near = rule.get('near')
            if near is not None:
                tol = float(rule.get('tol', 0.03 * h))
                if isinstance(near, list) and len(near) == 2 and all(isinstance(v, (int, float)) and 0 <= v <= 1 for v in near) and rule.get('unit') == 'fraction':
                    near = [near[0] * w, near[1] * h]
                found = [i for i in found if abs(els[i]['rect'][0] - near[0]) <= tol and abs(els[i]['rect'][1] - near[1]) <= tol]
                out.append((bool(found), 'present %r near %s (top left, tolerance %g px): %s%s' % (
                    rule['present'], near, tol, label(els, found[0]) + ' at ' + fmt_rect(els[found[0]]['rect']) if found else 'not found', why)))
            else:
                out.append((bool(found), 'present %r: %s%s' % (rule['present'], '%d visible' % len(found) if found else 'not found or not visible', why)))
        elif 'absent' in rule:
            found = [i for i in select(els, rule['absent']) if els[i]['visible']]
            out.append((not found, 'absent %r: %s%s' % (rule['absent'], '%d visible' % len(found) if found else 'none', why)))
        elif 'visible' in rule or 'hidden' in rule:
            want = 'visible' in rule
            sel = rule['visible' if want else 'hidden']
            found = select(els, sel)
            ok = bool(found) and all(els[i]['visible'] == want for i in found)
            out.append((ok, '%s %r: %s%s' % ('visible' if want else 'hidden', sel, 'no such element' if not found else '%d of %d visible' % (
                sum(1 for i in found if els[i]['visible']), len(found)), why)))
        elif 'no_overlap' in rule:
            pair = rule['no_overlap']
            if not isinstance(pair, list) or len(pair) != 2:
                raise DumpError('rule %d: no_overlap takes two selectors' % n)
            a, b = select(els, pair[0]), select(els, pair[1])
            hits = [(i, j) for i in a for j in b if i != j and els[i]['visible'] and els[j]['visible'] and intersect(els[i]['rect'], els[j]['rect'])]
            ok = bool(a) and bool(b) and not hits
            text = 'one of them does not exist' if not (a and b) else ('%s meets %s' % (label(els, hits[0][0]), label(els, hits[0][1])) if hits else 'apart')
            out.append((ok, 'no_overlap %r, %r: %s%s' % (pair[0], pair[1], text, why)))
        elif 'inside_screen' in rule:
            found = [i for i in select(els, rule['inside_screen']) if els[i]['visible']]
            bad = [i for i in found if els[i]['rect'][0] < -1 or els[i]['rect'][1] < -1 or els[i]['rect'][2] > w + 1 or els[i]['rect'][3] > h + 1]
            out.append((bool(found) and not bad, 'inside_screen %r: %s%s' % (rule['inside_screen'], 'not found' if not found else (
                '%s at %s' % (label(els, bad[0]), fmt_rect(els[bad[0]]['rect'])) if bad else 'inside'), why)))
        elif 'count' in rule:
            c = rule['count']
            n_found = sum(1 for e in els if e['layer'] == c.get('layer', e['layer']) and (not c.get('visible') or e['visible']))
            ok = all((k not in c) or t(n_found, c[k]) for k, t in (('eq', lambda x, y: x == y), ('min', lambda x, y: x >= y), ('max', lambda x, y: x <= y)))
            out.append((ok, 'count %s: %d%s' % (json.dumps(c, sort_keys=True), n_found, why)))
        elif 'no_findings' in rule:
            opt = rule['no_findings'] if isinstance(rule['no_findings'], dict) else {}
            ignore = set(opt.get('ignore', []))
            found = [f for f in check(data) if f['rule'] not in ignore]
            out.append((not found, 'no_findings: %s%s' % ('none' if not found else '%d, first: %s' % (len(found), found[0]['detail']), why)))
        else:
            raise DumpError('rule %d: unknown rule %s' % (n, sorted(rule)))
    return out


def cmd_expect(args):
    data = load(args.dump)
    try:
        with open(args.rules, encoding='utf-8') as f:
            rules = json.load(f)
    except (OSError, ValueError) as e:
        raise DumpError('%s: %s' % (args.rules, e))
    if isinstance(rules, dict):
        rules = rules.get('rules')
    rows = expect(data, rules)
    for ok, text in rows:
        print('%s  %s' % ('ok  ' if ok else 'FAIL', text))
    bad = sum(1 for ok, _ in rows if not ok)
    print('expect: %s  (%d of %d rules hold)' % ('PASS' if not bad else 'FAIL', len(rows) - bad, len(rows)))
    return 1 if bad else 0


# ---------------------------------------------------------------------------------------------------------------------
# frame: do the rectangles of a dump agree with a captured frame?
# ---------------------------------------------------------------------------------------------------------------------

def read_bmp(path):
    """An uncompressed 24 or 32 bit BMP (what capture_frame writes) -> (width, height, pixel(x, y) -> (r, g, b))."""
    try:
        with open(path, 'rb') as f:
            raw = f.read()
    except OSError as e:
        raise DumpError('%s: %s' % (path, e))
    if len(raw) < 54 or raw[:2] != b'BM':
        raise DumpError('%s: not a BMP file' % path)
    offset = struct.unpack_from('<I', raw, 10)[0]
    w, h, _, bits, compression = struct.unpack_from('<iiHHI', raw, 18)
    if bits not in (24, 32) or compression not in (0, 3) or w <= 0 or h == 0:
        raise DumpError('%s: only uncompressed 24 or 32 bit BMP files are read' % path)
    top_down, h = h < 0, abs(h)
    step = bits // 8
    row = (w * step + 3) & ~3
    if len(raw) < offset + row * h:
        raise DumpError('%s: the file is cut short' % path)

    def pixel(x, y):
        at = offset + (y if top_down else h - 1 - y) * row + x * step
        return raw[at + 2], raw[at + 1], raw[at]
    return w, h, pixel


def _box(r, grow, w, h):
    return max(0, int(round(r[0])) - grow), max(0, int(round(r[1])) - grow), min(w, int(round(r[2])) + grow), min(h, int(round(r[3])) + grow)


def frame_measure(rect, w, h, pixel, base=None, ring=4, gap=1, threshold=40):
    """Shares of pixels, inside the rectangle and in a ring just outside it. "ink": pixels that differ from the ring's own
    median colour in the same frame (text on a flat panel). "changed": pixels that differ from the base frame."""
    ix0, iy0, ix1, iy1 = _box(rect, 0, w, h)
    ox0, oy0, ox1, oy1 = _box(rect, gap + ring, w, h)
    gx0, gy0, gx1, gy1 = _box(rect, gap, w, h)
    step = 1 if (ox1 - ox0) * (oy1 - oy0) <= 60000 else 2
    inside, around = [], []
    for y in range(oy0, oy1, step):
        for x in range(ox0, ox1, step):
            if ix0 <= x < ix1 and iy0 <= y < iy1:
                inside.append((x, y))
            elif not (gx0 <= x < gx1 and gy0 <= y < gy1):
                around.append((x, y))
    out = {'inside_pixels': len(inside), 'ring_pixels': len(around)}
    if not inside or not around:
        return out
    ring_colors = [pixel(x, y) for x, y in around]
    median = tuple(sorted(c[k] for c in ring_colors)[len(ring_colors) // 2] for k in range(3))

    def far(c, d):
        return max(abs(c[0] - d[0]), abs(c[1] - d[1]), abs(c[2] - d[2])) > threshold
    out['ink_inside'] = sum(1 for x, y in inside if far(pixel(x, y), median)) / len(inside)
    out['ink_ring'] = sum(1 for c in ring_colors if far(c, median)) / len(ring_colors)
    if base:
        out['changed_inside'] = sum(1 for x, y in inside if far(pixel(x, y), base(x, y))) / len(inside)
        out['changed_ring'] = sum(1 for x, y in around if far(pixel(x, y), base(x, y))) / len(around)
    return out


def frame_rows(data, frame, base=None, text=None, layer=None, threshold=40):
    """One row per visible element with a text or an image: the measures and whether the rectangle agrees with the frame.
    It agrees when the frame has ink inside and none around (a text on a flat panel), or when the inside changed against
    the base frame and the ring did not (a panel over the world)."""
    w, h, pixel = read_bmp(frame)
    s = data['screen']
    if (w, h) != (s['width'], s['height']):
        raise DumpError('the frame is %dx%d and the dump %dx%d' % (w, h, s['width'], s['height']))
    base_pixel = None
    if base:
        bw, bh, base_pixel = read_bmp(base)
        if (bw, bh) != (w, h):
            raise DumpError('the two frames have different sizes')
    els = elements(data)
    out = []
    for i in matches(els, text, None, layer, True):
        e = els[i]
        if not (has_content(e) or e['layer'] == 'hud') or area(e['rect']) <= 0:
            continue
        m = frame_measure(e['rect'], w, h, pixel, base_pixel, threshold=threshold)
        by_ink = m.get('ink_inside', 0) >= 0.02 and m.get('ink_ring', 1) <= 0.01
        by_change = m.get('changed_inside', 0) >= 0.5 and m.get('changed_ring', 1) <= 0.1
        m.update(element=i, name=label(els, i), rect=fmt_rect(e['rect']), agrees=bool(by_ink or by_change), by='ink' if by_ink else ('change' if by_change else ''))
        out.append(m)
    return out


def cmd_frame(args):
    rows = frame_rows(load(args.dump), args.frame, args.base, args.text, None if args.layer == 'all' else args.layer, args.threshold)
    for m in rows:
        parts = ['ink inside %.1f%% ring %.1f%%' % (100 * m.get('ink_inside', 0), 100 * m.get('ink_ring', 0))]
        if 'changed_inside' in m:
            parts.append('changed inside %.1f%% ring %.1f%%' % (100 * m['changed_inside'], 100 * m['changed_ring']))
        print('%-6s %-18s %s  %s' % ('agrees' if m['agrees'] else 'NO', m['rect'], '; '.join(parts), m['name']))
    good = sum(1 for m in rows if m['agrees'])
    print('frame: %d of %d rectangles agree with the frame' % (good, len(rows)))
    return 0 if rows and good == len(rows) else 1


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('show')
    p.add_argument('dump')
    p.add_argument('--layer', choices=('all', 'hud', 'lui'), default='all')
    p.add_argument('--depth', type=int)
    p.add_argument('--max', type=int, default=200)
    p.add_argument('--visible', action='store_true', help='only visible elements')
    p.add_argument('--content', action='store_true', help='only elements with a text or an image')
    p.set_defaults(fn=cmd_show)
    p = sub.add_parser('find')
    p.add_argument('dump')
    p.add_argument('--text')
    p.add_argument('--id')
    p.add_argument('--layer', choices=('all', 'hud', 'lui'), default='all')
    p.set_defaults(fn=cmd_find)
    p = sub.add_parser('check')
    p.add_argument('dump')
    p.add_argument('--min-text', type=float, help='smallest readable text height in pixels (default 10 at 720 lines, scaled)')
    p.add_argument('--overlap', type=float, default=0.10, help='share of the smaller text rectangle that counts as an overlap')
    p.add_argument('--ignore', help='rules to leave out, separated by commas')
    p.add_argument('--json', action='store_true')
    p.set_defaults(fn=cmd_check)
    p = sub.add_parser('diff')
    p.add_argument('a')
    p.add_argument('b')
    p.add_argument('--tolerance', type=float, default=1.0)
    p.add_argument('--layer', choices=('all', 'hud', 'lui'), default='all')
    p.add_argument('--max', type=int, default=200)
    p.set_defaults(fn=cmd_diff)
    p = sub.add_parser('expect')
    p.add_argument('dump')
    p.add_argument('rules')
    p.set_defaults(fn=cmd_expect)
    p = sub.add_parser('frame')
    p.add_argument('dump')
    p.add_argument('frame', help='a frame captured at the moment of the dump (BMP)')
    p.add_argument('--base', help='a frame of the same view without the elements (BMP)')
    p.add_argument('--text', help='only elements whose text matches')
    p.add_argument('--layer', choices=('all', 'hud', 'lui'), default='all')
    p.add_argument('--threshold', type=int, default=40, help='colour distance (0..255) that counts as different')
    p.set_defaults(fn=cmd_frame)
    args = ap.parse_args(argv)
    try:
        return args.fn(args)
    except DumpError as e:
        print('iw7_ui: %s' % e)
        return 2


if __name__ == '__main__':
    sys.exit(main())
