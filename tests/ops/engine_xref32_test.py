"""iw7_xref32.py finds a global in both forms (rip-relative and image-base-relative disp32) and nothing else."""
import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, '..', '..', 'ops', 'engine-map', 'iw7_xref32.py')
TEXT_VA = 0x140001000


def code():
    b = bytearray(b'\x90' * 96)            # nops before each instruction: the decoder votes from up to 32 bytes back
    # 0x140001020: lea rcx, [rip + X] with target 0x1460B22F2 (7 bytes)
    disp = 0x1460B22F2 - (TEXT_VA + 0x20 + 7)
    b[0x20:0x27] = b'\x48\x8d\x0d' + disp.to_bytes(4, 'little', signed=True)
    # 0x140001030: movzx eax, word ptr [r10 + rcx*4 + 0x60B22F2] (9 bytes)
    b[0x30:0x39] = bytes.fromhex('410fb7848af2220b06')
    # 0x140001040: mov eax, 0x60B22F2 (an immediate, not a memory operand: must not be reported)
    b[0x40:0x45] = b'\xb8' + (0x60B22F2).to_bytes(4, 'little')
    return bytes(b)


class Xref32(unittest.TestCase):
    def test_both_forms_and_no_immediates(self):
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, 'unpacked-text.bin'), 'wb') as f:
                f.write(code())
            out = subprocess.run([sys.executable, '-B', TOOL, '--reference-root', d, '--json', '1460B22F0:10'],
                                 capture_output=True, text=True, check=True).stdout
            rows = json.loads(out)
            self.assertEqual(sorted((r['kind'], r['ins']) for r in rows), [('rip', '140001020'), ('rva', '140001030')])


if __name__ == '__main__':
    unittest.main()
