"""The navigator release of a destroyed agent (a89): the shipped bytes the stub depends on, and the stub's text."""
import importlib.util
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
CPP = os.path.join(HERE, '..', '..', 'src', 'native', 'agent_capacity.cpp')
spec = importlib.util.spec_from_file_location('sites_test', os.path.join(HERE, 'agent_capacity_sites_test.py'))
st = importlib.util.module_from_spec(spec)
spec.loader.exec_module(st)


class NavRelease(unittest.TestCase):
    def test_shipped_function_reads_flag_then_calls_through_the_pointer(self):
        image, _ = st.find_image()
        # FUN_1403E3930: cmp byte [rcx+0x1328],0 ; mov rdi,rcx ; je ; mov rcx,[rcx+0x1320] ; call FUN_1405E85C0
        code = image.read(0x1403E3930, 0x1E)
        self.assertEqual(code[0:2], bytes([0x40, 0x57]))
        self.assertEqual(code[6:13], bytes([0x80, 0xB9, 0x28, 0x13, 0x00, 0x00, 0x00]))          # cmp byte [rcx+0x1328], 0
        self.assertEqual(code[18:25], bytes([0x48, 0x8B, 0x89, 0x20, 0x13, 0x00, 0x00]))         # mov rcx, [rcx+0x1320]
        self.assertEqual(code[25], 0xE8)                                                          # call FUN_1405E85C0
        # FUN_1405E85C0 is the virtual call that faults on a null pointer: mov rax,[rcx] ; jmp [rax+0x160]
        self.assertEqual(image.read(0x1405E85C0, 10).hex(), '488b0148ffa060010000')

    def test_stub_clears_the_stale_flag_and_is_hooked(self):
        text = open(CPP, encoding='utf-8').read()
        for needle in ('release_nav_hook.create(0x1403E3930, release_nav_stub);',
                       'if (agent && agent[0x1328] && !*reinterpret_cast<void**>(agent + 0x1320)) {',
                       'agent[0x1328] = 0;',
                       'release_nav_hook.invoke<void>(agent);'):
            self.assertIn(needle, text)


if __name__ == '__main__':
    unittest.main()
