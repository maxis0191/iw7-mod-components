#!/usr/bin/env python3
"""Tests of ops/engine-map/iw7_ui.py on synthetic dumps (no game file, no machine path)."""
import contextlib
import io
import json
import os
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'ops', 'engine-map'))
import iw7_ui as ui  # noqa: E402

W, H = 1280, 720


def hud_raw(kind=1, x=0.0, y=0.0, font_scale=1.0, align_org=0, align_screen=0, color=(255, 255, 255, 255), width=0, height=0, sort=3.0, flags=0):
    raw = bytearray(0xB8)
    struct.pack_into('<i', raw, 0, kind)
    struct.pack_into('<ff', raw, 4, x, y)
    struct.pack_into('<f', raw, 0x14, font_scale)
    struct.pack_into('<ii', raw, 0x38, align_org, align_screen)
    raw[0x40:0x44] = bytes(color)
    struct.pack_into('<ii', raw, 0x54, width, height)
    struct.pack_into('<f', raw, 0x98, sort)
    struct.pack_into('<I', raw, 0xB4, flags)
    return raw.hex()


def hud(i, rect, text='', material='', alpha=1.0, drawn=True, font_height=20.0, **raw):
    e = {'i': i, 'address': '0x1', 'type': 4 if material else 1, 'drawn': drawn, 'draws': 1,
         'raw': hud_raw(kind=4 if material else 1, **raw)}
    if drawn:
        e.update(rect=list(rect), z=0, label='', text=text, label_width=0, text_width=rect[2], font='fonts/main', font_scale=0.5,
                 font_height=font_height, font_pixels=24, color=[1, 1, 1, alpha], time=1000)
    if material:
        e['material'] = material
    return e


def lui(i, p, d, rect, **more):
    e = {'i': i, 'p': p, 'd': d, 'rect': list(rect)}
    e.update(more)
    return e


def dump(hud_elements=(), lui_elements=(), **more):
    data = {'schema': 'iw7.ui-dump/1', 'tag': 't', 'map': 'cp_test', 'serial': 1, 'time_ms': 1,
            'screen': {'width': W, 'height': H, 'scene_width': W, 'scene_height': H, 'aspect': 1.7778},
            'hud': {'count': len(hud_elements), 'element_bytes': 184, 'overflow': False, 'elements': list(hud_elements)},
            'lui': {'walker': 'test', 'elements': list(lui_elements), 'count': len(lui_elements), 'truncated': False, 'root': True},
            'cost': {'request_to_file_ms': 1.0}}
    data.update(more)
    return data


PAGE = [hud(0, (962, 160, 312, 109), material='white', alpha=0.86, sort=2.0),
        hud(1, (968, 166, 150, 21), text='^5MAXIS ^7TERMINAL', font_height=21.0),
        hud(2, (968, 198, 120, 16), text='.rush  toggle Rush mode', font_height=16.0)]
TREE = [lui(0, -1, 0, (0, 0, W, H), id='root'),
        lui(1, 0, 1, (0, 0, W, H), id='hud'),
        lui(2, 1, 2, (40, 600, 240, 700), id='weaponInfo', clips=True),
        lui(3, 2, 3, (60, 620, 120, 660), id='ammo', text='30', text_height=40),
        lui(4, 2, 3, (130, 630, 200, 655), id='reserve', text='120', text_height=25),
        lui(5, 1, 2, (1100, 30, 1240, 80), id='round', text='1', text_height=50),
        lui(6, 1, 2, (600, 300, 680, 340), id='hint', text='Hold F', alpha=0.0, text_height=40)]


def run(argv):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        code = ui.main(argv)
    return code, out.getvalue()


class Files(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def write(self, name, data):
        path = os.path.join(self.tmp.name, name)
        with open(path, 'w', encoding='utf-8') as f:
            json.dump(data, f)
        return path

    def bmp(self, name, pixels, bits=32, top_down=True):
        """pixels(x, y) -> (r, g, b)."""
        step = bits // 8
        row = (W * step + 3) & ~3
        body = bytearray()
        for y in (range(H) if top_down else range(H - 1, -1, -1)):
            line = bytearray()
            for x in range(W):
                r, g, b = pixels(x, y)
                line += bytes((b, g, r, 255)[:step])
            body += line + bytes(row - len(line))
        head = b'BM' + struct.pack('<IHHI', 54 + len(body), 0, 0, 54) + struct.pack('<IiiHHIIiiII', 40, W, -H if top_down else H, 1, bits, 0, len(body), 0, 0, 0, 0)
        path = os.path.join(self.tmp.name, name)
        with open(path, 'wb') as f:
            f.write(head + body)
        return path


class DecodeTests(unittest.TestCase):
    def test_the_fields_of_a_hud_element_are_read_at_the_game_s_offsets(self):
        f = ui.decode_hud_raw(hud_raw(kind=1, x=-306.0, y=86.0, font_scale=1.05, align_org=(0 << 2) | 0, align_screen=(3 << 4) | 1,
                                      color=(10, 20, 30, 219), sort=3.0, flags=1))
        self.assertEqual((f['type_name'], f['x'], f['y'], f['sort'], f['flags']), ('text', -306.0, 86.0, 3.0, 1))
        self.assertAlmostEqual(f['font_scale'], 1.05, places=5)
        self.assertEqual((f['align_x'], f['align_y'], f['horz_align'], f['vert_align']), ('left', 'top', 3, 1))
        self.assertEqual(f['color'], [10, 20, 30, 219])

    def test_a_short_or_broken_raw_is_refused(self):
        for bad in ('zz', '00' * 10):
            with self.assertRaises(ui.DumpError):
                ui.decode_hud_raw(bad)

    def test_both_layers_become_one_list_with_inherited_alpha(self):
        els = ui.elements(dump(PAGE, TREE + [lui(7, 6, 3, (600, 300, 680, 340), id='inner', text='x')]))
        self.assertEqual([e['layer'] for e in els], ['hud'] * 3 + ['lui'] * 8)
        self.assertEqual(els[0]['rect'], (962, 160, 1274, 269))
        self.assertEqual(els[1]['text'], '^5MAXIS ^7TERMINAL')
        self.assertFalse(els[9]['visible'])                 # alpha 0
        self.assertFalse(els[10]['visible'])                # its parent has alpha 0
        self.assertEqual(ui.path_of(els, 6), 'root/hud/weaponInfo/ammo')
        self.assertEqual(els[5]['children'], 2)

    def test_colour_codes_are_not_text(self):
        self.assertEqual(ui.strip_colors('^5MAXIS ^7TERMINAL'), 'MAXIS TERMINAL')


class CommandTests(Files):
    def test_show_and_find(self):
        path = self.write('a.json', dump(PAGE, TREE))
        code, text = run(['show', path])
        self.assertEqual(code, 0)
        self.assertIn('screen 1280x720  hud 3  lui 7', text)
        self.assertIn('"^5MAXIS ^7TERMINAL"', text)
        self.assertIn('      ammo  60,620 60x40  a=1.00  "30"', text)
        code, text = run(['find', path, '--text', 'maxis terminal'])
        self.assertEqual(code, 0)
        self.assertIn('968,166 150x21', text)
        self.assertEqual(run(['find', path, '--text', 'nowhere'])[0], 1)
        code, text = run(['find', path, '--id', 'weaponInfo/ammo$'])
        self.assertIn('1 found', text)

    def test_not_a_dump_is_exit_2(self):
        path = self.write('x.json', {'schema': 'other'})
        self.assertEqual(run(['show', path])[0], 2)
        self.assertEqual(run(['check', os.path.join(self.tmp.name, 'missing.json')])[0], 2)

    def test_a_clean_screen_has_no_finding(self):
        self.assertEqual(ui.check(dump(PAGE, TREE)), [])
        self.assertEqual(run(['check', self.write('a.json', dump(PAGE, TREE))])[0], 0)

    def test_each_defect_is_found_and_nothing_else(self):
        cases = {
            'PARTLY_OFF_SCREEN': dump([hud(0, (1200, 100, 200, 20), text='half out')]),
            'OFF_SCREEN': dump([hud(0, (1300, 100, 200, 20), text='gone')]),
            'ZERO_SIZE': dump([hud(0, (100, 100, 0, 20), material='white')]),
            'SMALL_TEXT': dump([hud(0, (100, 100, 60, 6), text='tiny', font_height=6.0)]),
            'TEXT_OVERLAP': dump([hud(0, (100, 100, 200, 20), text='cash 500'), hud(1, (180, 105, 200, 20), text='cash 750')]),
            'CLIPPED': dump([], [lui(0, -1, 0, (0, 0, W, H), id='root'), lui(1, 0, 1, (40, 40, 140, 140), id='portraitFrame', clips=True),
                                 lui(2, 1, 2, (40, 90, 140, 190), id='portrait', image='portrait_a')]),
        }
        for rule, data in cases.items():
            found = ui.check(data)
            self.assertEqual([f['rule'] for f in found], [rule], rule)
        code, text = run(['check', self.write('o.json', cases['TEXT_OVERLAP'])])
        self.assertEqual(code, 1)
        self.assertIn('TEXT_OVERLAP', text)
        self.assertIn('"cash 500" and hud1 "cash 750" overlap', text)
        self.assertEqual(run(['check', self.write('o.json', cases['TEXT_OVERLAP']), '--ignore', 'text_overlap'])[0], 0)

    def test_hidden_elements_and_parent_child_texts_are_not_defects(self):
        data = dump([hud(0, (1300, 100, 200, 20), text='gone', alpha=0.0), hud(1, (0, 0, 10, 10), drawn=False)],
                    [lui(0, -1, 0, (0, 0, W, H), id='root'), lui(1, 0, 1, (100, 100, 300, 140), id='label', text='A'),
                     lui(2, 1, 2, (100, 100, 300, 140), id='shadow', text='A'),
                     lui(3, 0, 1, (-500, 0, 2000, 900), id='bigContainer')])
        self.assertEqual(ui.check(data), [])

    def test_diff_names_what_changed(self):
        after = dump(PAGE[:2] + [hud(2, (968, 230, 120, 16), text='.rush  toggle Rush mode', font_height=16.0)],
                     TREE[:5] + [lui(5, 1, 2, (1100, 30, 1240, 80), id='round', text='2', text_height=50)])
        rows = ui.diff(dump(PAGE, TREE), after)
        self.assertEqual(sorted(r[0] for r in rows), ['moved', 'removed', 'text'])
        a, b = self.write('a.json', dump(PAGE, TREE)), self.write('b.json', after)
        code, text = run(['diff', a, b])
        self.assertEqual(code, 1)
        self.assertIn('text     root/hud/round "1"  "1" -> "2"', text)
        self.assertEqual(run(['diff', a, a])[0], 0)

    def test_closing_a_page_removes_its_elements(self):
        rows = ui.diff(dump(PAGE, TREE), dump([], TREE))
        self.assertEqual([r[0] for r in rows], ['removed'] * 3)

    def test_expect_is_a_verdict(self):
        path = self.write('a.json', dump(PAGE, TREE))
        good = [{'present': 'MAXIS TERMINAL', 'near': [968, 166], 'tol': 4}, {'present': {'id': 'round$', 'layer': 'lui'}},
                {'absent': 'Game over'}, {'visible': {'id': 'weaponInfo/ammo'}}, {'hidden': {'id': 'hint'}},
                {'no_overlap': [{'id': 'ammo$'}, {'id': 'reserve$'}]}, {'inside_screen': 'toggle Rush'},
                {'count': {'layer': 'hud', 'eq': 3}}, {'no_findings': {}}]
        code, text = run(['expect', path, self.write('good.json', {'rules': good})])
        self.assertEqual(code, 0, text)
        self.assertIn('expect: PASS  (9 of 9 rules hold)', text)
        bad = [{'present': 'MAXIS TERMINAL', 'near': [100, 100], 'tol': 4}, {'absent': 'MAXIS'}, {'visible': {'id': 'hint'}},
               {'no_overlap': ['MAXIS', {'id': 'nothing'}]}, {'count': {'layer': 'hud', 'max': 2}}]
        code, text = run(['expect', path, self.write('bad.json', bad)])
        self.assertEqual(code, 1)
        self.assertIn('expect: FAIL  (0 of 5 rules hold)', text)
        self.assertEqual(run(['expect', path, self.write('odd.json', [{'sideways': 1}])])[0], 2)

    def test_expect_sees_an_overlap_between_two_named_elements(self):
        data = dump([], TREE[:3] + [lui(3, 2, 3, (60, 620, 150, 660), id='ammo', text='30'), lui(4, 2, 3, (130, 630, 200, 655), id='reserve', text='120')])
        rows = ui.expect(data, [{'no_overlap': [{'id': 'ammo$'}, {'id': 'reserve$'}]}])
        self.assertFalse(rows[0][0])


class FrameTests(Files):
    PANEL, BACK, INK = (962, 160, 1274, 269), (20, 24, 30), (240, 240, 240)

    def with_page(self, shift=0):
        def pixels(x, y):
            if 968 + shift <= x < 1118 + shift and 166 <= y < 187 and (x // 3) % 2 == 0:
                return self.INK
            if self.PANEL[0] <= x < self.PANEL[2] and self.PANEL[1] <= y < self.PANEL[3]:
                return self.BACK
            return (90, 110, 130)
        return pixels

    def test_rectangles_that_match_the_frame_agree(self):
        frame = self.bmp('page.bmp', self.with_page())
        base = self.bmp('base.bmp', lambda x, y: (90, 110, 130), bits=24, top_down=False)
        rows = ui.frame_rows(dump(PAGE[:2]), frame, base)
        self.assertEqual([m['agrees'] for m in rows], [True, True])
        self.assertEqual((rows[0]['changed_inside'], rows[0]['changed_ring']), (1.0, 0.0))     # the panel changed the frame, its surroundings did not
        self.assertEqual(rows[1]['by'], 'ink')
        self.assertGreater(rows[1]['ink_inside'], 0.3)
        self.assertEqual(rows[1]['ink_ring'], 0)
        self.assertEqual(run(['frame', self.write('a.json', dump(PAGE[:2])), frame, '--base', base])[0], 0)

    def test_a_rectangle_that_is_not_where_the_pixels_are_does_not_agree(self):
        frame = self.bmp('page.bmp', self.with_page(shift=40))
        rows = ui.frame_rows(dump(PAGE[1:2]), frame)
        self.assertFalse(rows[0]['agrees'])
        self.assertGreater(rows[0]['ink_ring'], 0.01)

    def test_a_frame_of_another_size_is_refused(self):
        path = os.path.join(self.tmp.name, 'small.bmp')
        with open(path, 'wb') as f:
            f.write(b'BM' + struct.pack('<IHHI', 54 + 16, 0, 0, 54) + struct.pack('<IiiHHIIiiII', 40, 2, 2, 1, 32, 0, 16, 0, 0, 0, 0) + bytes(16))
        with self.assertRaises(ui.DumpError):
            ui.frame_rows(dump(PAGE), path)


if __name__ == '__main__':
    unittest.main()
