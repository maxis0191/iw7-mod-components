"""stack_arrays.py: the scan finds a counter-indexed stack store loop and judges its bound against the room under the cookie.
Hand-built functions in a fake image (the helpers of frame_grow_test.py); no game, no engine image."""
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, '..', '..', 'ops', 'engine'))
import frame_grow_test as t  # noqa: E402
import stack_arrays as sa  # noqa: E402


def loop_body(bound, cursor=False):
    # push rbx; sub rsp,0x300; xor eax,eax; L: store; inc/add; cmp rax,bound; jb L; add rsp,0x300; pop rbx; ret
    if cursor:
        # lea rdx,[rsp+0x40]; L: mov [rdx],rcx; add rdx,0x10; inc rax; cmp rax,bound; jb L
        loop = bytes.fromhex('488d542440') + bytes.fromhex('488902') + bytes.fromhex('4883c210') + bytes.fromhex('48ffc0') + \
            bytes.fromhex('4883f8') + bytes([bound]) + bytes.fromhex('72ee')
        loop = bytes.fromhex('31c0') + loop
    else:
        loop = bytes.fromhex('31c0') + bytes.fromhex('488954c440'.replace('488954c440', '48894cc440')) + bytes.fromhex('48ffc0') + \
            bytes.fromhex('4883f8') + bytes([bound]) + bytes.fromhex('72f2')
    return [b'\x53', t.sub_rsp(0x300), loop, t.add_rsp(0x300), b'\x5b', b'\xc3']


class Scan(unittest.TestCase):
    def run_scan(self, body):
        fn = t.Fn(body=body, flags=3, handler_data=0x2C0, unwind_codes=[t.code_alloc_large(1 + 7, 0x300), t.code_push(1, 3)], prolog=8)
        img = fn.image()
        sa.GS_HANDLERS = (t.HANDLER,)
        rows, stats = sa.run(img, [(t.CODE, t.CODE + 0x1000)])
        return rows

    def test_an_indexed_loop_that_passes_the_cookie_is_an_overrun(self):
        rows = self.run_scan(loop_body(100))
        self.assertEqual(len(rows), 1, rows)
        self.assertEqual((rows[0]['start_s'], rows[0]['stride'], rows[0]['bound'], rows[0]['verdict']), (0x40, 8, 100, 'OVERRUNS ABOVE 80'))

    def test_a_constant_that_fits_is_safe(self):
        rows = self.run_scan(loop_body(80))
        self.assertEqual([r['verdict'] for r in rows], ['SAFE'])

    def test_a_cursor_register_is_found_too(self):
        rows = self.run_scan(loop_body(100, cursor=True))
        self.assertEqual(len(rows), 1, rows)
        self.assertEqual((rows[0]['stride'], rows[0]['verdict']), (16, 'OVERRUNS ABOVE 40'))

    def test_a_function_without_a_loop_store_has_no_row(self):
        self.assertEqual(self.run_scan(t.Fn.default_body(0x300)), [])


if __name__ == '__main__':
    unittest.main()
