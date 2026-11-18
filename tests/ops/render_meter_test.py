"""Render meter and the draw surface list (a90): the hooked functions and the tables the fix writes, against the shipped code.

paris_render_meter.cpp hooks FUN_140E2D9D0 (draw command), FUN_140E29C50 (end of the render commands), FUN_1407AA9E0 (CG_ProcessEntity) and FUN_140E328E0 (end of a scene) at their first
bytes, and FUN_140E4B0B0 (the renderer warning) behind iw7-mod's own detour. agent_capacity.cpp section 3c moves list 1 of the dynamic models' draw surfaces: FUN_140E34A80 fills the
capacity table (0x149EEAA00), the base table (0x149EEAAC0) and the readers (FUN_140DDE800, FUN_140E3CEE0) take both from the tables. Offline: the prologue arrays of the meter are the shipped
bytes, the initialiser stores 0x100 and 0x149E0AD80 for list 1, the constants of the C++ are those values, the draw surface function compares its cursor with the limit array and raises
warning 0x29 from the same three sites the meter's table names. Skipped when neither the unpacked code files nor the analysed image exist on the machine.
"""
import importlib.util
import os
import re
import struct
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
METER = os.path.join(ROOT, 'src', 'native', 'paris_render_meter.cpp')
CAP = os.path.join(ROOT, 'src', 'native', 'agent_capacity.cpp')

spec = importlib.util.spec_from_file_location('sites_test', os.path.join(HERE, 'agent_capacity_sites_test.py'))
st = importlib.util.module_from_spec(spec)
spec.loader.exec_module(st)

HOOKS = {'draw_code': 0x140E2D9D0, 'render_end_code': 0x140E29C50, 'process_code': 0x1407AA9E0, 'expected': 0x140E328E0}


def array_bytes(text, name):
    m = re.search(r'%s\[\]\s*=\s*\{([^}]*)\}' % name, text)
    return bytes(int(x, 16) for x in re.findall(r'0x[0-9A-Fa-f]+', m.group(1)))


class RenderMeter(unittest.TestCase):
    def setUp(self):
        self.image, _ = st.find_image()
        if self.image is None:
            self.skipTest('no unpacked code files or analysed image on this machine')
        self.meter = open(METER, encoding='utf-8').read()
        self.cap = open(CAP, encoding='utf-8').read()

    def test_the_hook_prologues_are_the_shipped_bytes(self):
        for name, address in HOOKS.items():
            expected = array_bytes(self.meter, name)
            self.assertEqual(self.image.read(address, len(expected)), expected, '%s at %#x' % (name, address))

    def test_the_warning_function_starts_with_the_bytes_the_meter_accepts_when_nobody_detoured_it(self):
        bytes_ = bytes(int(x, 16) for x in re.findall(r'\\x([0-9A-Fa-f]{2})', re.search(r'memcmp\(p, "([^"]*)"', self.meter).group(1) and re.search(r'memcmp\(p, "([^"]*)"', self.meter).group(0)))
        self.assertEqual(self.image.read(0x140E4B0B0, len(bytes_)), bytes_)

    def test_the_initialiser_stores_the_stock_capacity_and_base_of_list_1(self):
        code = self.image.read(0x140E34A80, 0x400)
        stores = {}
        # mov dword ptr [rip+disp32], imm32 = C7 05 disp32 imm32 (10 bytes); the stored address is the end of the instruction plus disp32
        for i in range(len(code) - 10):
            if code[i] == 0xC7 and code[i + 1] == 0x05:
                disp, imm = struct.unpack_from('<iI', code, i + 2)
                stores[0x140E34A80 + i + 10 + disp] = imm
        self.assertEqual(stores.get(0x149EEAA00 + 4), 0x100, 'list 1 holds 0x100 entries at the stock')
        self.assertEqual(stores.get(0x149EEAA00), 0x2000, 'list 0 holds 0x2000 entries (the table starts there)')
        # lea rax,[rip+disp32] (48 8D 05) followed by mov [rip+disp32], rax (48 89 05): the base of each list
        bases = {}
        i = 0
        while i < len(code) - 14:
            if code[i:i + 3] == b'\x48\x8D\x05' and code[i + 7:i + 10] == b'\x48\x89\x05':
                lea, = struct.unpack_from('<i', code, i + 3)
                mov, = struct.unpack_from('<i', code, i + 10)
                bases[0x140E34A80 + i + 14 + mov] = 0x140E34A80 + i + 7 + lea
                i += 14
            else:
                i += 1
        self.assertEqual(bases.get(0x149EEAAC8), 0x149E0AD80, 'the base of list 1')

    def test_the_cpp_constants_are_those_values(self):
        text = self.cap
        self.assertIn('drawsurf_capacities = 0x149EEAA00', text)
        self.assertIn('drawsurf_bases = 0x149EEAAC0', text)
        self.assertIn('drawsurf_dobj_list = 1', text)
        self.assertIn('drawsurf_dobj_stock = 0x100', text)
        self.assertIn('drawsurf_dobj_stock_base = 0x149E0AD80', text)
        self.assertIn('plan_drawsurf_lists();', text.split('plan_render_list();')[1][:60])

    def test_the_reader_takes_the_limit_from_the_tables_and_warns_0x29_from_three_sites(self):
        # the reader loop of FUN_140DDE800: `*(0x149EEAA00 + idx*4) * 0x10 + base` is the limit, `*(0x149EEAA60 + idx*4) * 0x10 + base` the cursor
        func = self.image.read(0x140DDE800, 0x600)
        self.assertGreater(func.count(struct.pack('<i', 0)), 0)
        # warning 0x29: mov ecx,0x29 ; call 0x140E4B0B0 at the three sites the meter's census lists
        for site in (0x140E2C9E8, 0x140E2D6D6, 0x140E309BD):
            window = self.image.read(site - 16, 16 + 5)
            self.assertIn(bytes([0xB9, 0x29, 0, 0, 0]), window[:16], '%#x: mov ecx,0x29 shortly before the call' % site)
            self.assertEqual(window[16], 0xE8)
            rel, = struct.unpack_from('<i', window, 17)
            self.assertEqual(site + 5 + rel, 0x140E4B0B0)

    def test_the_perf_recorder_no_longer_creates_its_own_scene_end_hook(self):
        perf = open(os.path.join(ROOT, 'src', 'native', 'paris_perf.cpp'), encoding='utf-8').read()
        self.assertIn('subscribe_scene_end(scene_copy_callback)', perf)
        self.assertNotIn('scene_copy_hook', perf)


if __name__ == '__main__':
    unittest.main()
