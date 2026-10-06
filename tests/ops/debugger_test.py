"""Evidence semantics and malformed/private input regression tests."""
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest
import uuid
import zipfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("debugger", ROOT / "ops/iw7_debugger.py")
dbg = importlib.util.module_from_spec(spec); spec.loader.exec_module(dbg)


def make_dump():
    data = bytearray(1024)
    struct.pack_into("<4sIII", data, 0, b"MDMP", 0xA793, 2, 32)
    struct.pack_into("<III", data, 32, 4, 112, 64)
    struct.pack_into("<III", data, 44, 6, 168, 200)
    struct.pack_into("<I", data, 64, 1)
    struct.pack_into("<QIIII", data, 68, 0x140000000, 0x10000, 0, 123, 400)
    name = "C:\\private\\iw7-test.exe".encode("utf-16-le")
    struct.pack_into("<I", data, 400, len(name)); data[404:404 + len(name)] = name
    cv = b"RSDS" + uuid.UUID(int=1).bytes_le + struct.pack("<I", 2) + b"C:\\private\\test.pdb\0"
    struct.pack_into("<II", data, 68 + 76, len(cv), 500); data[500:500 + len(cv)] = cv
    struct.pack_into("<I", data, 200, 77)
    struct.pack_into("<IIQQI", data, 208, 0xC0000005, 0, 0, 0x140001234, 2)
    struct.pack_into("<QQ", data, 240, 1, 0x18)
    return bytes(data)


def make_pdb():
    data = bytearray(5 * 512)
    data[:32] = b"Microsoft C/C++ MSF 7.00\r\n\x1aDS\0\0\0"
    struct.pack_into("<6I", data, 32, 512, 1, 5, 16, 0, 2)
    struct.pack_into("<I", data, 2 * 512, 3)
    struct.pack_into("<4I", data, 3 * 512, 2, 0, 28, 4)
    struct.pack_into("<III", data, 4 * 512, 20000404, 123, 2)
    data[4 * 512 + 12:4 * 512 + 28] = uuid.UUID(int=1).bytes_le
    return bytes(data)


class DebuggerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.path = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, name, data):
        p = self.path / name
        p.write_bytes(data if isinstance(data, bytes) else data.encode())
        return p

    def test_dump_exception_and_rva(self):
        r = dbg.dump_report(self.write("crash.dmp", make_dump()))
        self.assertEqual(r["exception"]["access"], "write")
        self.assertEqual(r["exception"]["target"], "0x18")
        self.assertEqual(r["exception"]["rva"], "0x1234")
        self.assertEqual(r["modules"][0]["name"], "iw7-test.exe")
        self.assertEqual(r["modules"][0]["pdb"]["age"], 2)
        self.assertNotIn("private", json.dumps(r))

    def test_zip_never_extracts_paths(self):
        p = self.path / "crash.zip"
        with zipfile.ZipFile(p, "w") as z:
            z.writestr("../../escape.dmp", make_dump())
        self.assertEqual(dbg.dump_report(p)["exception"]["thread_id"], 77)
        self.assertFalse((self.path.parent / "escape.dmp").exists())

    def test_malformed_dump_ranges(self):
        for raw in (b"MDMP", b"no dump", make_dump()[:100]):
            with self.assertRaises(ValueError): dbg.MiniDump(raw).summary()
        data = bytearray(make_dump()); struct.pack_into("<I", data, 36, 99999)
        with self.assertRaises(ValueError): dbg.MiniDump(data).summary()

    def test_pdb_identity_not_filename(self):
        a = dbg.pdb_identity(self.write("renamed.pdb", make_pdb()))
        self.assertEqual(a["guid"], str(uuid.UUID(int=1)))
        self.assertEqual(a["age"], 2)
        with self.assertRaises(ValueError): dbg.pdb_identity(self.write("fake.pdb", b"fake"))

    def test_invalid_pdb_directory(self):
        data = bytearray(make_pdb()); struct.pack_into("<I", data, 2 * 512, 99999)
        with self.assertRaises(ValueError): dbg.pdb_identity(self.write("bad.pdb", bytes(data)))

    def test_log_classification_and_privacy(self):
        p = self.write("server.log", "g_password hunter2\nunknown function 'scripts/example::work'\n0xC0000005 at endpoint 192.0.2.123\nWARNING old stock message\n")
        r = dbg.log_events(p)
        self.assertEqual(r["counts"], {"gsc.link": 1, "native.exception": 1, "engine.warning": 1})
        self.assertNotIn("192.0.2.123", json.dumps(r))
        self.assertIn("unproven", json.dumps(r))
        self.assertNotIn("hunter2", dbg.scrub("g_password hunter2 token=secret123"))

    def test_utf16_log(self):
        r = dbg.log_events(self.write("utf16.log", "script link error".encode("utf-16")))
        self.assertEqual(r["counts"]["gsc.link"], 1)

    def test_metrics_and_pressure(self):
        rows = [{"type": "header", "scenario": "same map/settings"}]
        rows += [{"type": "sample", "cpu_core_percent": v, "physical_percent": 81 if v == 30 else 40} for v in (10, 20, 30)]
        rows += [{"type": "timing", "category": "gsc_region", "id": 1, "calls": 2, "total_us": 100, "max_us": 70}]
        p = self.write("perf.jsonl", "\n".join(json.dumps(x) for x in rows))
        r = dbg.perf_report(p)
        self.assertEqual(r["metrics"]["cpu_core_percent"]["mean"], 20)
        self.assertEqual(r["hotspots"][0]["mean_us"], 50)
        self.assertEqual(r["high_pressure_samples"], 1)
        self.assertFalse(dbg.compare_reports(p, p)["pressure_free"])

    def test_nonfinite_and_truncated_trace(self):
        for text in ('{"type":"sample","cpu_core_percent":NaN}', '{"type":'):
            with self.assertRaises(ValueError): dbg.perf_report(self.write("bad.jsonl", text))

    def test_empty_trace_does_not_accept(self):
        r = dbg.perf_report(self.write("empty.jsonl", ""))
        self.assertEqual(r["metrics"], {})
        self.assertNotEqual(r["acceptance"], "passed")

    def test_lexing_preserves_lines(self):
        text = 'main() {\n print("while(1) { wait;"); // wait\n /* multi\n line */\n loop();\n}'
        clean = dbg.strip_comments_strings(text)
        self.assertEqual(clean.count("\n"), text.count("\n"))
        self.assertNotIn("while", clean)
        self.assertIn("loop", clean)

    def test_output_containment_and_overwrite(self):
        with self.assertRaises(ValueError): dbg.local_output(self.path / "outside.json")
        p = ROOT / "runtime/debugger/tests/no-overwrite.json"
        p.parent.mkdir(parents=True, exist_ok=True)
        if not p.exists(): p.write_text("{}")
        with self.assertRaises(ValueError): dbg.local_output(p)

    def test_cdb_not_automatic_culprit(self):
        r = dbg.cdb_report(self.write("cdb.txt", "EXCEPTION_CODE: c0000005\nMODULE_NAME: iw7\n*** ERROR: symbols mismatch\n"))
        self.assertEqual(r["fields"]["module_name"], "iw7")
        self.assertTrue(r["warnings"])
        self.assertIn("not proof", r["causality"])

    def test_quantiles(self):
        self.assertIsNone(dbg.quantiles([]))
        self.assertEqual(dbg.quantiles([1, 3])["p50"], 2)
        self.assertEqual(dbg.quantiles([1, float("nan")])["count"], 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
