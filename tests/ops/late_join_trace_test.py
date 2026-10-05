"""Synthetic, anonymous memory fixtures; never opens a live process in CI."""
import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[2] / "ops" / "Trace-LateJoin.py"
spec = importlib.util.spec_from_file_location("late_join_trace", SOURCE)
trace = importlib.util.module_from_spec(spec)
spec.loader.exec_module(trace)


class FakeMemory:
    def __init__(self):
        self.bytes = {}
        self.reads = []
        self.clock_reads = 0
        self.advance_clock = False

    def put(self, address, fmt, *values):
        self.bytes.update(enumerate(struct.pack(fmt, *values), address))

    def read(self, address, size):
        self.reads.append((address, size))
        if address == trace.GAME_TIME:
            self.clock_reads += 1
            if self.advance_clock and self.clock_reads > 1:
                return struct.pack("<i", 100050)
        return bytes(self.bytes[i] for i in range(address, address + size))


def fixture(state=5):
    memory = FakeMemory()
    client, ps = 0x200000000, 0x300000000
    memory.put(trace.GAME_TIME, "<i", 100000)
    memory.put(trace.CLIENT_COUNT, "<i", 1)
    memory.put(trace.CLIENT_TABLE, "<Q", client)
    memory.put(trace.SERVER_ID, "<B", 17)
    memory.put(client + 8, "<B", state)
    memory.put(client + 0x18, "<i", 99950)
    memory.put(client + 0x41274, "<ii", 150, 149)
    memory.put(client + 0x41280, "<i", 450)
    memory.put(client + 0x9F35C, "<i", 17)
    memory.put(client + 136, "<Q", trace.ENTITIES)
    memory.put(trace.ENTITIES + 368, "<Q", ps)
    memory.put(ps, "<ii", 99950, 0)
    memory.put(ps + 40, "<6f", 1, 2, 3, 4, 5, 6)
    memory.put(ps + 120, "<ii", 800, 190)
    return memory, client, ps


class TraceTests(unittest.TestCase):
    def test_active_player_fields_and_no_identity_reads(self):
        memory, client, _ = fixture()
        sample = trace.Fields(memory.read).sample()
        self.assertTrue(sample["stable_frame_and_bindings"])
        row = sample["slots"][0]
        self.assertEqual((row["reliable_pending"], row["server_minus_last_usercmd_ms"]), (1, 50))
        self.assertEqual(row["origin"], [1, 2, 3])
        self.assertEqual((row["gravity"], row["speed"]), (800, 190))
        forbidden = [(client + 164, client + 1220), (client + 649616, client + 649636),
                     (client + 652096, client + 652117)]
        for address, size in memory.reads:
            self.assertLessEqual(size, 64)
            self.assertFalse(any(address < end and address + size > begin for begin, end in forbidden))

    def test_loading_does_not_dereference_player(self):
        memory, client, _ = fixture(state=4)
        memory.put(client + 136, "<Q", 0)
        row = trace.Fields(memory.read).sample()["slots"][0]
        self.assertNotIn("origin", row)

    def test_empty_slot_is_not_gameplay(self):
        memory, _, _ = fixture(state=0)
        self.assertEqual(trace.Fields(memory.read).sample()["slots"], [])

    def test_frame_change_is_marked_unstable(self):
        memory, _, _ = fixture()
        memory.advance_clock = True
        self.assertFalse(trace.Fields(memory.read).sample()["stable_frame_and_bindings"])

    def test_wrong_entity_binding_refused(self):
        memory, client, _ = fixture()
        memory.put(client + 136, "<Q", trace.ENTITIES + 1016)
        with self.assertRaisesRegex(ValueError, "binding"):
            trace.Fields(memory.read).sample()

    def test_invalid_pointer_refused(self):
        memory, _, _ = fixture()
        memory.put(trace.CLIENT_TABLE, "<Q", 0)
        with self.assertRaisesRegex(ValueError, "pointer"):
            trace.Fields(memory.read).sample()

    def test_invalid_count_and_state_refused(self):
        for field, fmt, value in [(trace.CLIENT_COUNT, "<i", 19), (0x200000008, "<B", 6)]:
            memory, _, _ = fixture()
            memory.put(field, fmt, value)
            with self.assertRaises(ValueError):
                trace.Fields(memory.read).sample()

    def test_counter_rollover(self):
        self.assertEqual(trace.signed_delta(-2147483648, 2147483647), 1)
        self.assertEqual(trace.signed_delta(150, 0), 150)
        self.assertEqual(trace.signed_delta(150, -1), 151)

    def test_nonfinite_position_refused(self):
        memory, _, ps = fixture()
        memory.put(ps + 40, "<f", float("nan"))
        with self.assertRaisesRegex(ValueError, "Non-finite"):
            trace.Fields(memory.read).sample()

    def test_output_outside_runtime_and_overwrite_refused(self):
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(ValueError, "runtime"):
                trace.output_path(str(Path(temporary) / "trace.jsonl"))
        runtime = SOURCE.parents[1] / "runtime"
        runtime.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=runtime) as temporary:
            path = Path(temporary) / "trace.jsonl"
            self.assertEqual(trace.output_path(str(path)), path.resolve())
            path.write_text("preserve", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "new"):
                trace.output_path(str(path))
            self.assertEqual(path.read_text(encoding="utf-8"), "preserve")

    def test_creation_time_requires_timezone(self):
        with self.assertRaisesRegex(ValueError, "timezone"):
            trace.utc_datetime("2026-10-06T00:00:00")
        self.assertEqual(trace.utc_datetime("2026-10-06T02:00:00+02:00"),
                         trace.utc_datetime("2026-10-06T00:00:00Z"))


if __name__ == "__main__":
    unittest.main()
