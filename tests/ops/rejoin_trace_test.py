"""Exercise the actual paired reader with anonymous synthetic player state."""
import importlib.util
from pathlib import Path
import struct
import unittest

spec = importlib.util.spec_from_file_location('paired', Path(__file__).resolve().parents[2] / 'ops/Trace-Rejoin.py')
paired = importlib.util.module_from_spec(spec)
spec.loader.exec_module(paired)


class PredictionTests(unittest.TestCase):
    def memory(self, changed=False, invalid=False, rebound=False, pointer=0x200000000):
        calls = []
        ps_reads = 0
        pointer_reads = 0
        def read(address, size):
            nonlocal ps_reads, pointer_reads
            calls.append((address, size))
            if address == paired.CG_POINTER:
                pointer_reads += 1
                return struct.pack('<Q', pointer + (4096 if rebound and pointer_reads > 1 else 0))
            offset = address - pointer - 8
            if offset == 0:
                ps_reads += 1
                return struct.pack('<i', 20050 if changed and ps_reads > 1 else 20000)
            if offset == 40:
                return struct.pack('<6f', float('nan') if invalid else 10, 20, 30, 0, 190, 0)
            if offset == 120:
                return struct.pack('<ii', 800, 190)
            raise AssertionError('Unexpected/private field read')
        return read, calls

    def test_stable_numeric_state_only(self):
        read, calls = self.memory()
        row = paired.prediction(read)
        self.assertEqual(row['origin'], [10, 20, 30])
        self.assertEqual(row['velocity'], [0, 190, 0])
        self.assertEqual(row['gravity_speed'], [800, 190])
        self.assertTrue(row['stable_command_time'])
        self.assertTrue(all(size <= 24 for _, size in calls))

    def test_asynchronous_change_is_visible(self):
        read, _ = self.memory(changed=True)
        self.assertFalse(paired.prediction(read)['stable_command_time'])

    def test_invalid_prediction_is_refused(self):
        read, _ = self.memory(invalid=True)
        with self.assertRaisesRegex(ValueError, 'Non-finite'):
            paired.prediction(read)

    def test_rebound_allocation_is_not_stable(self):
        read, _ = self.memory(rebound=True)
        self.assertFalse(paired.prediction(read)['stable_command_time'])

    def test_null_pointer_is_refused(self):
        read, calls = self.memory(pointer=0)
        with self.assertRaisesRegex(ValueError, 'Invalid client globals'):
            paired.prediction(read)
        self.assertEqual(calls, [(paired.CG_POINTER, 8)])

    def test_changed_engine_getter_is_refused(self):
        with self.assertRaisesRegex(ValueError, 'getter layout changed'):
            paired.validate_prediction_layout(lambda address, size: bytes(size))


if __name__ == '__main__':
    unittest.main()
