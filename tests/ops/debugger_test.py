"""Evidence semantics and malformed/private input regression tests."""
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest import mock
import uuid
import zipfile
import sys

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("debugger", ROOT / "ops/iw7_debugger.py")
dbg = importlib.util.module_from_spec(spec); spec.loader.exec_module(dbg)
sys.path.insert(0, str(ROOT / "ops"))
import iw7_watch as watch


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


def make_pe():
    data = bytearray(2048)
    data[:2] = b"MZ"; struct.pack_into("<I", data, 60, 128)
    data[128:132] = b"PE\0\0"; struct.pack_into("<HHI", data, 132, 0x8664, 1, 123)
    struct.pack_into("<H", data, 148, 240)
    opt = 152; struct.pack_into("<H", data, opt, 0x20b)
    struct.pack_into("<Q", data, opt + 24, 0x140000000)
    struct.pack_into("<I", data, opt + 56, 0x10000)
    struct.pack_into("<I", data, opt + 108, 16)
    struct.pack_into("<II", data, opt + 112 + 6 * 8, 0x1000, 28)
    struct.pack_into("<IIII", data, opt + 240 + 8, 1024, 0x1000, 1024, 512)
    cv = b"RSDS" + uuid.UUID(int=1).bytes_le + struct.pack("<I", 2) + b"test.pdb\0"
    struct.pack_into("<IIII", data, 512 + 12, 2, len(cv), 0x1100, 768)
    data[768:768 + len(cv)] = cv
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

    def test_image_pdb_dump_match_and_rejection(self):
        image = self.write("image.exe", make_pe()); pdb = self.write("symbols.pdb", make_pdb())
        dump = self.write("dump.dmp", make_dump())
        self.assertTrue(dbg.symbols_report(image, pdb, dump)["valid"])
        changed = bytearray(make_pdb()); struct.pack_into("<I", changed, 4 * 512 + 8, 3)
        bad = self.write("wrong.pdb", bytes(changed))
        self.assertFalse(dbg.symbols_report(image, bad, dump)["valid"])

    def test_unused_dump_stream_placeholders(self):
        data = bytearray(make_dump()); struct.pack_into("<I", data, 8, 4)
        # Move stream directory away from payload and add repeated unused entries.
        struct.pack_into("<I", data, 12, 800)
        data[800:824] = data[32:56]
        struct.pack_into("<6I", data, 824, 0, 0, 0, 0, 0, 0)
        self.assertEqual(dbg.MiniDump(bytes(data)).summary()["exception"]["code"], "0xC0000005")

    def test_builtin_label_resolution(self):
        self.write("iw7_func.cpp", '{ 0x001, "abs" },')
        self.write("iw7_meth.cpp", '{ 0x8001, "getorigin" },')
        trace = self.write("tokens.jsonl", '{"type":"timing","category":"gsc_method","id":32769,"calls":1,"total_us":50,"max_us":50}')
        self.assertEqual(dbg.perf_report(trace, self.path)["hotspots"][0]["label"], "gsc_method:getorigin")

    def test_presentmon_quantiles_keep_swapchains_separate(self):
        path = self.write("presents.csv", "ProcessID,SwapChainAddress,MsBetweenPresents\n1,0xA,10\n1,0xA,30\n2,0xB,100\n")
        report = dbg.presents_report(path, 1)
        self.assertEqual(len(report["swapchains"]), 1)
        self.assertEqual(report["swapchains"][0]["present_rate_fps"], 50)
        self.assertEqual(report["swapchains"][0]["frame_ms"]["p50"], 20)

    def test_live_detector_growth_is_hypothesis(self):
        detector = watch.Detector(warmup=10)
        alerts = []
        for second in range(40):
            alerts += detector.sample({"private_bytes": 100000000 + second * 2000000, "cpu_core_percent": 10, "physical_percent": 40, "commit_percent": 40}, second)
        growth = [a for a in alerts if a["code"] == "memory.growth_candidate"]
        self.assertTrue(growth)
        self.assertEqual(growth[0]["confidence"], "hypothesis")

    def test_live_detector_flat_memory_no_leak_alert(self):
        detector = watch.Detector(warmup=0)
        alerts = []
        for second in range(40):
            alerts += detector.sample({"private_bytes": 100000000, "physical_percent": 40, "commit_percent": 40}, second)
        self.assertFalse([x for x in alerts if "memory" in x["code"]])

    def test_live_tick_slow_and_transition_grace(self):
        detector = watch.Detector(warmup=0)
        row = {"type": "server_ticks", "hz": 3, "game_time_ms": 100}
        self.assertFalse(detector.native(row, 1)); self.assertFalse(detector.native(row, 2))
        self.assertEqual(detector.native(row, 3)[0]["code"], "server.simulation_cadence")
        self.assertFalse(detector.native({**row, "resets": 1}, 20))
        self.assertFalse(detector.native(row, 21))

    def test_live_present_spike_and_repeat_suppression(self):
        detector = watch.Detector(frame_budget_ms=10)
        self.assertTrue(detector.presents([10, 50], 20))
        self.assertFalse(detector.presents([10, 50], 21))
        self.assertFalse(detector.presents([10, 11], 40))

    def test_live_tail_partial_line_and_truncation(self):
        path = self.write("live.jsonl", '{"type":"sample"}')
        tail = watch.Tail(path)
        self.assertEqual(tail.lines(), [])
        with path.open("ab") as f: f.write(b"\n")
        self.assertEqual(tail.lines(), ['{"type":"sample"}'])
        path.write_bytes(b"")
        with self.assertRaises(ValueError): tail.lines()

    def test_multitarget_perf_does_not_mix_server_client(self):
        path = self.write("multi.jsonl", '\n'.join(json.dumps(x) for x in [
            {"type": "sample", "target": "Server", "cpu_core_percent": 10},
            {"type": "sample", "target": "Client", "cpu_core_percent": 200}]))
        report = dbg.perf_report(path)
        self.assertEqual(report["metrics"]["Server:cpu_core_percent"]["mean"], 10)
        self.assertEqual(report["metrics"]["Client:cpu_core_percent"]["mean"], 200)

    def test_idle_server_is_not_tps_drop(self):
        detector = watch.Detector(warmup=0)
        detector.sample({'private_bytes': 100, 'physical_percent': 30, 'commit_percent': 30, 'server': {'clients': '0', 'mapname': 'cp_zmb'}}, 50)
        for i in range(10):
            self.assertFalse(detector.native({'type': 'server_ticks', 'hz': 0, 'game_time_ms': 50}, 51+i))

    def test_loading_growth_is_excluded_from_retained_window(self):
        detector = watch.Detector(warmup=30)
        alerts = []
        for second in range(60):
            alerts += detector.sample({'private_bytes': min(second, 29)*50*1024*1024, 'physical_percent': 30, 'commit_percent': 30}, second)
        self.assertFalse([a for a in alerts if a['code'] == 'memory.growth_candidate'])

    def test_live_performance_retains_gaps_and_swapchains(self):
        path = self.write('windows.jsonl', '\n'.join(json.dumps(x) for x in [
            {'type': 'present_window', 'target': 'Client', 'swapchain': 'a', 'present_rate_fps': 30},
            {'type': 'present_window', 'target': 'Client', 'swapchain': 'b', 'present_rate_fps': 1},
            {'type': 'coverage', 'sensor': 'displayed_fps', 'status': 'unavailable'},
            {'type': 'alert', 'target': 'Server', 'code': 'gsc.runtime'}]))
        report = dbg.perf_report(path)
        self.assertEqual(report['metrics']['Client:a:present_rate_fps']['mean'], 30)
        self.assertEqual(report['metrics']['Client:b:present_rate_fps']['mean'], 1)
        self.assertEqual(report['alerts']['Server:gsc.runtime'], 1)
        self.assertEqual(report['coverage_gaps'][0]['status'], 'unavailable')

    def test_gsc_stack_context_is_retained(self):
        report = dbg.log_events(self.write('stack.log', 'script runtime error\nwhile processing instruction OP_CastFieldObject\n at function "init_cryobomb" in file "scripts/test.gsc"\n'))
        self.assertIn('init_cryobomb', '\n'.join(report['events'][0]['context']))

    def test_renderer_and_gpu_alerts_preserve_semantics(self):
        detector = watch.Detector()
        self.assertTrue(detector.native({'type': 'render_window', 'max_interval_ms': 100, 'callback_rate_fps': 30}, 50))
        self.assertEqual(detector.native({'type': 'gpu_budget', 'hresult': -1, 'budget_bytes': 100, 'usage_bytes': 99}, 50)[0]['code'], 'coverage.gpu_budget')
        self.assertEqual(detector.native({'type': 'gpu_budget', 'hresult': 0, 'budget_bytes': 100, 'usage_bytes': 99, 'meaning': 'process budget'}, 50)[0]['code'], 'gpu.process_budget_pressure')

    def test_renderer_metrics_do_not_become_displayed_fps(self):
        path = self.write('render.jsonl', json.dumps({'type': 'render_window', 'target': 'Client', 'swapchain_slot': 0, 'callback_rate_fps': 30, 'max_interval_ms': 80}))
        report = dbg.perf_report(path)
        self.assertEqual(report['metrics']['Client:renderer_0:callback_rate_fps']['mean'], 30)
        self.assertFalse(any('present_rate_fps' in k for k in report['metrics']))

    def test_sustained_render_drop_is_per_channel(self):
        detector = watch.Detector(frame_budget_ms=33.34, warmup=0)
        for i in range(4):
            self.assertFalse(detector.native({'type': 'render_window', 'callback_rate_fps': 20, 'max_interval_ms': 50, 'swapchain_slot': 0}, i))
            self.assertFalse(detector.native({'type': 'render_window', 'callback_rate_fps': 30, 'max_interval_ms': 34, 'swapchain_slot': 1}, i))
        self.assertTrue(detector.native({'type': 'render_window', 'callback_rate_fps': 20, 'max_interval_ms': 50, 'swapchain_slot': 0}, 5))

    def test_unreturned_scope_requires_repetition_and_is_hypothesis(self):
        detector = watch.Detector(warmup=0)
        row = {'type': 'timing', 'category': 'engine_scope', 'id': 1, 'active': 1, 'calls': 0}
        self.assertFalse(detector.native(row, 1)); self.assertFalse(detector.native(row, 2))
        self.assertEqual(detector.native(row, 3)[0]['confidence'], 'hypothesis')
        self.assertFalse(detector.native({**row, 'active': 0, 'calls': 1}, 4))

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
        rows += [{"type": "sample", "cpu_core_percent": v, "physical_percent": 95, "commit_percent": 86 if v == 30 else 40} for v in (10, 20, 30)]
        rows += [{"type": "timing", "category": "gsc_region", "id": 1, "calls": 2, "total_us": 100, "max_us": 70}]
        p = self.write("perf.jsonl", "\n".join(json.dumps(x) for x in rows))
        r = dbg.perf_report(p)
        self.assertEqual(r["metrics"]["cpu_core_percent"]["mean"], 20)
        self.assertEqual(r["hotspots"][0]["mean_us"], 50)
        self.assertEqual(r["high_pressure_samples"], 1)
        self.assertFalse(dbg.compare_reports(p, p)["pressure_free"])

    def test_high_ram_alone_does_not_invalidate_or_alert(self):
        row = {"type": "sample", "private_bytes": 100, "physical_percent": 99, "commit_percent": 40}
        report = dbg.perf_report(self.write("ram.jsonl", json.dumps(row)))
        self.assertEqual(report["high_pressure_samples"], 0)
        detector = watch.Detector(warmup=0)
        self.assertFalse([x for x in detector.sample(row, 1) if x["code"] == "resource.pressure"])
        self.assertTrue([x for x in detector.sample({**row, "commit_percent": 86}, 2) if x["code"] == "resource.pressure"])

    def test_high_commit_remains_observation_with_legacy_metrics(self):
        low = self.write("low-commit.jsonl", json.dumps({"type": "sample", "commit_percent": 85}))
        high = self.write("high-commit.jsonl", "\n".join(json.dumps({"type": "sample", "commit_percent": value}) for value in (86, 99)))
        report = dbg.perf_report(high)
        self.assertEqual(report["schema"], dbg.SCHEMA)
        self.assertEqual(report["metrics"]["commit_percent"]["count"], 2)
        self.assertEqual(report["metrics"]["commit_percent"]["mean"], 92.5)
        self.assertEqual(report["high_pressure_samples"], 2)
        self.assertEqual(dbg.perf_report(low)["high_pressure_samples"], 0)
        self.assertEqual(report["acceptance"], dbg.perf_report(low)["acceptance"])
        self.assertTrue(report["acceptance"].startswith("observation;"))
        self.assertIn("legacy commit_percent >85", report["limits"])
        comparison = dbg.compare_reports(low, high)
        self.assertIs(comparison["pressure_free"], False)
        self.assertIs(dbg.compare_reports(low, low)["pressure_free"], True)
        self.assertIn("does not establish capacity or exhaustion", comparison["conclusion"])

    def test_legacy_commit_alert_is_not_exhaustion_evidence(self):
        row = {"type": "sample", "private_bytes": 100, "physical_percent": 99, "commit_percent": 99}
        alerts = watch.Detector(warmup=0).sample(row, 1)
        pressure = [alert for alert in alerts if alert["code"] == "resource.pressure"]
        self.assertEqual(len(pressure), 1)
        self.assertEqual(pressure[0]["evidence"]["physical_percent"], 99)
        self.assertEqual(pressure[0]["evidence"]["commit_percent"], 99)
        self.assertEqual(pressure[0]["causality"], "not established")
        self.assertIn("not proof of exhaustion", pressure[0]["evidence"]["meaning"])
        self.assertIn("observation/admission/stop", pressure[0]["evidence"]["meaning"])

    def test_nonfinite_and_truncated_trace(self):
        for text in ('{"type":"sample","cpu_core_percent":NaN}', '{"type":'):
            with self.assertRaises(ValueError): dbg.perf_report(self.write("bad.jsonl", text))

    def test_empty_trace_does_not_accept(self):
        r = dbg.perf_report(self.write("empty.jsonl", ""))
        self.assertEqual(r["metrics"], {})
        self.assertNotEqual(r["acceptance"], "passed")

    def phase_context(self):
        return {"map": "cp_zmb", "phase": "round_active", "declared_clients": 1,
                "actors": {"zombies": 24}, "pending": {"spawns": 0},
                "resolution": "not_applicable", "scale": "not_applicable", "options": {"dedicated": True},
                "config_hashes": {"server": "a" * 64}, "script_hashes": {"scripts": "b" * 64},
                "builds": {"Server": "c" * 64}}

    def phase_trace(self, name, rows, context=None, finish=True):
        header = {"type": "header", "scenario": "generic laboratory", "comparison_context": context or self.phase_context(),
                  "collection_id": "a" * 32, "clock": dbg.WINDOWS_CLOCK, "collection_start_ms": 0,
                  "measurement_window": {"clock": dbg.WINDOWS_CLOCK, "start_ms": 1000, "end_ms": 4000}}
        complete = {"type": "complete", "collection_id": "a" * 32, "clock": dbg.WINDOWS_CLOCK,
                    "collection_end_ms": 5000, "collection_complete": True}
        return self.write(name, "\n".join(json.dumps(x) for x in [header, *rows, *([complete] if finish else [])]))

    def phase_samples(self, values=(10, 20, 30)):
        return [{"type": "sample", "target": "Server", "cpu_core_percent": value, "private_bytes": 100 + i,
                 "cpu_rate_bounds": {"clock": dbg.CPU_RATE_CLOCK, "lower_percent": value, "upper_percent": value,
                                     "minimum_interval_seconds": 1.0, "maximum_interval_seconds": 1.0},
                 "acquisition": {"clock": dbg.WINDOWS_CLOCK, "start_ms": 2000 + i * 1000, "end_ms": 2000 + i * 1000},
                 "cpu_period": {"clock": dbg.WINDOWS_CLOCK, "start_ms": 1000 + i * 1000, "end_ms": 2000 + i * 1000}}
                for i, value in enumerate(values)]

    def test_post_counter_threads_and_udp_cost_cannot_fabricate_cpu_gain(self):
        results, post_times = [], []
        for delay in (.05, .5):
            class Clock:
                now = 0.0
            clock = Clock()
            class FakeObserver:
                calls = 0
                def sample(self):
                    value = {"cpu_seconds": self.calls * .1}
                    self.calls += 1
                    return value
                def threads(self):
                    clock.now += delay
                    return {(1, 1): .1}
            observer = FakeObserver()
            with mock.patch.object(watch, "windows_tick_ms", side_effect=lambda: int(clock.now * 1000)), \
                 mock.patch.object(watch.time, "perf_counter", side_effect=lambda: clock.now):
                before, before_phase, before_rate = watch.acquire_process(observer)
                clock.now = 1.0
                current, current_phase, current_rate = watch.acquire_process(observer)
                _, thread_phase, _ = watch.acquire_threads(observer)
                clock.now += delay  # Synthetic UDP work, after the original CPU acquisition.
                results.append(watch.cpu_rate(current["cpu_seconds"] - before["cpu_seconds"], before_rate, current_rate))
                post_times.append(clock.now)
                self.assertEqual(current_phase["end_ms"], 1000)
                self.assertGreater(thread_phase["end_ms"], current_phase["end_ms"])
                self.assertEqual(before_phase["start_ms"], 0)
        self.assertNotEqual(post_times[0], post_times[1])
        self.assertEqual(results[0], results[1])
        self.assertEqual(results[0][0], 10)

    def test_cpu_uncertainty_overlap_cannot_qualify_apparent_gain(self):
        before = self.phase_trace("precise-cpu.jsonl", self.phase_samples())
        rows = self.phase_samples((9, 19, 29))
        for row in rows:
            row["cpu_rate_bounds"].update({"lower_percent": 0, "upper_percent": 50})
        after = self.phase_trace("uncertain-cpu.jsonl", rows)
        result = dbg.compare_reports(before, after)
        self.assertTrue(result["contexts_match"])
        self.assertEqual(result["phase_comparison"]["changes"], [])
        self.assertEqual(result["phase_comparison"]["exclusions"]["Server:cpu_core_percent"], ["cpu_rate_uncertainty_overlaps"])
        self.assertIn("Server:cpu_core_percent", [x["metric"] for x in result["changes"]])

    def test_cpu_rate_bounds_are_required_for_phase_comparison(self):
        rows = self.phase_samples(); del rows[1]["cpu_rate_bounds"]
        result = dbg.perf_report(self.phase_trace("rate-unknown.jsonl", rows))
        self.assertIn("cpu_rate_uncertainty_missing_or_invalid", result["phase"]["channels"]["Server:cpu_core_percent"]["reasons"])

    def test_generic_or_absent_contexts_never_match(self):
        for rows in ([], [{"type": "header", "scenario": "same generic laboratory"}]):
            path = self.write("generic" + str(len(rows)) + ".jsonl", "\n".join(json.dumps(x) for x in rows))
            result = dbg.compare_reports(path, path)
            self.assertFalse(result["contexts_match"])
            self.assertEqual(result["phase_comparison"]["changes"], [])

    def test_declared_context_is_strict_and_headless_is_explicit(self):
        context = self.phase_context()
        self.assertIs(dbg.comparison_context(context), context)
        mutants = []
        for key in context:
            bad = {**context}; del bad[key]; mutants.append(bad)
        mutants += [{**context, "extra": 0}, {**context, "declared_clients": False},
                    {**context, "actors": {}}, {**context, "pending": {"spawns": False}},
                    {**context, "options": {"scale": float("inf")}}, {**context, "options": {"scale": 10 ** 1000}},
                    {**context, "script_hashes": {}}, {**context, "builds": {"Client": "c" * 64}},
                    {**context, "resolution": [1920, 1080], "scale": True}]
        for bad in mutants:
            with self.subTest(bad=bad):
                with self.assertRaises(ValueError): dbg.comparison_context(bad)
        rendered = {**context, "resolution": [1920, 1080], "scale": 1.0, "builds": {"Client": "c" * 64}}
        self.assertIs(dbg.comparison_context(rendered), rendered)

    def test_phase_controls_and_build_variable_are_separate(self):
        before = self.phase_trace("phase-before.jsonl", self.phase_samples())
        changed_build = self.phase_context(); changed_build["builds"]["Server"] = "d" * 64
        after = self.phase_trace("phase-after.jsonl", self.phase_samples((20, 40, 60)), changed_build)
        result = dbg.compare_reports(before, after)
        self.assertTrue(result["contexts_match"])
        self.assertEqual(result["build_differences"], [{"target": "Server", "before": "c" * 64, "after": "d" * 64}])
        self.assertEqual([x["metric"] for x in result["phase_comparison"]["changes"]], ["Server:cpu_core_percent"])
        self.assertAlmostEqual(result["phase_comparison"]["changes"][0]["delta_percent"], 100)
        other_map = self.phase_trace("other-map.jsonl", self.phase_samples(), {**self.phase_context(), "map": "cp_rave"})
        self.assertFalse(dbg.compare_reports(before, other_map)["contexts_match"])
        self.assertEqual(dbg.compare_reports(before, other_map)["phase_comparison"]["changes"], [])

    def test_warmup_history_and_crossing_periods_are_not_prorated(self):
        rows = self.phase_samples()
        rows += [{"type": "sample", "target": "Server", "cpu_core_percent": 999,
                  "cpu_period": {"clock": dbg.WINDOWS_CLOCK, "start_ms": a, "end_ms": b}}
                 for a, b in ((0, 900), (900, 1500), (3500, 4500), (4500, 5000))]
        report = dbg.perf_report(self.phase_trace("bounds.jsonl", rows))
        self.assertEqual(report["metrics"]["Server:cpu_core_percent"]["count"], 7)
        self.assertEqual(report["phase"]["metrics"]["Server:cpu_core_percent"]["mean"], 20)
        channel = report["phase"]["channels"]["Server:cpu_core_percent"]
        self.assertEqual(channel["excluded"]["outside_or_crossing_window"], 4)
        self.assertEqual((channel["accepted_start_ms"], channel["accepted_end_ms"]), (1000, 4000))
        self.assertTrue(channel["qualified"])

    def test_crossing_cpu_period_cannot_supply_accepted_window_edges(self):
        crossing, accepted = self.phase_samples()[:2]
        crossing["cpu_period"].update(start_ms=0, end_ms=5000)
        accepted["cpu_period"].update(start_ms=2000, end_ms=2100)
        path = self.phase_trace("crossing-cpu-support.jsonl", [crossing, accepted])
        report = dbg.perf_report(path)["phase"]
        channel = report["channels"]["Server:cpu_core_percent"]
        self.assertEqual(report["window"], {"clock": dbg.WINDOWS_CLOCK, "start_ms": 1000, "end_ms": 4000})
        self.assertEqual(channel["count"], 1)
        self.assertEqual((channel["observed_start_ms"], channel["observed_end_ms"]), (1000, 4000))
        self.assertEqual((channel["accepted_start_ms"], channel["accepted_end_ms"]), (2000, 2100))
        self.assertEqual(channel["excluded"]["outside_or_crossing_window"], 1)
        self.assertFalse(channel["window_covered"])
        self.assertFalse(channel["qualified"])
        self.assertIn("uncovered_measurement_window", channel["reasons"])
        self.assertEqual(dbg.compare_reports(path, path)["phase_comparison"]["changes"], [])

    def test_crossing_native_period_cannot_supply_accepted_window_edges_or_gap(self):
        for periods in (((2000, 2100),), ((1000, 2000), (3000, 4000))):
            with self.subTest(periods=periods):
                rows = [{"type": "server_ticks", "target": "Server", "clock": dbg.WINDOWS_CLOCK,
                         "tick_ms": right, "window_ms": right - left, "hz": 20}
                        for left, right in ((0, 5000), *periods)]
                path = self.phase_trace("crossing-native-support-" + str(len(periods)) + ".jsonl", rows)
                report = dbg.perf_report(path)["phase"]
                channel = report["channels"]["Server:simulation_hz"]
                self.assertEqual(report["window"], {"clock": dbg.WINDOWS_CLOCK, "start_ms": 1000, "end_ms": 4000})
                self.assertEqual(channel["count"], len(periods))
                self.assertEqual((channel["observed_start_ms"], channel["observed_end_ms"]), (1000, 4000))
                self.assertEqual((channel["accepted_start_ms"], channel["accepted_end_ms"]), (periods[0][0], periods[-1][1]))
                self.assertFalse(channel["window_covered"])
                self.assertFalse(channel["qualified"])
                self.assertIn("uncovered_measurement_window", channel["reasons"])
                self.assertEqual(dbg.compare_reports(path, path)["phase_comparison"]["changes"], [])

    def test_invalid_cpu_metric_or_rate_bounds_cannot_supply_coverage(self):
        for invalid in ("metric", "rate_bounds"):
            with self.subTest(invalid=invalid):
                rejected, accepted = self.phase_samples()[:2]
                rejected["cpu_period"].update(start_ms=1000, end_ms=4000)
                accepted["cpu_period"].update(start_ms=2000, end_ms=2100)
                if invalid == "metric": rejected["cpu_core_percent"] = "unavailable"
                else: del rejected["cpu_rate_bounds"]
                path = self.phase_trace("invalid-cpu-support-" + invalid + ".jsonl", [rejected, accepted])
                channel = dbg.perf_report(path)["phase"]["channels"]["Server:cpu_core_percent"]
                self.assertEqual(channel["count"], 1)
                self.assertEqual((channel["accepted_start_ms"], channel["accepted_end_ms"]), (2000, 2100))
                self.assertFalse(channel["window_covered"])
                self.assertFalse(channel["qualified"])
                reason = "invalid_metric" if invalid == "metric" else "cpu_rate_uncertainty_missing_or_invalid"
                self.assertEqual(channel["excluded"][reason], 1)
                self.assertIn("uncovered_measurement_window", channel["reasons"])

    def test_sparse_memory_brackets_do_not_claim_whole_window_coverage(self):
        report = dbg.perf_report(self.phase_trace("sparse.jsonl", self.phase_samples()))
        cpu = report["phase"]["channels"]["Server:cpu_core_percent"]
        memory = report["phase"]["channels"]["Server:private_bytes"]
        self.assertTrue(cpu["qualified"])
        self.assertEqual(memory["count"], 3)
        self.assertEqual((memory["observed_start_ms"], memory["observed_end_ms"]), (2000, 4000))
        self.assertFalse(memory["qualified"])
        self.assertIn("uncovered_measurement_window", memory["reasons"])

    def test_missing_time_mixed_clock_and_missing_target_are_explicit(self):
        for field in (None, {"clock": "monotonic", "start_ms": 1000, "end_ms": 2000},
                      {"clock": dbg.WINDOWS_CLOCK, "start_ms": True, "end_ms": 2000}):
            rows = self.phase_samples(); rows[0]["cpu_period"] = field
            report = dbg.perf_report(self.phase_trace("missing-" + str(field is None) + str(field.get("clock") if field else "") + ".jsonl", rows))
            self.assertIn("acquisition_interval_or_clock_missing", report["phase"]["channels"]["Server:cpu_core_percent"]["reasons"])
        rows = self.phase_samples(); rows[0]["target"] = "Other"
        report = dbg.perf_report(self.phase_trace("undeclared-target.jsonl", rows))
        self.assertIn("target_not_declared", report["phase"]["channels"]["Other:cpu_core_percent"]["reasons"])

    def test_missing_or_incomplete_collection_cannot_qualify(self):
        path = self.phase_trace("unfinished.jsonl", self.phase_samples(), finish=False)
        self.assertEqual(dbg.compare_reports(path, path)["phase_comparison"]["changes"], [])
        original = self.phase_trace("finished.jsonl", self.phase_samples())
        rows = list(dbg.jsonl(original))
        for key, value in (("collection_complete", False), ("collection_id", "b" * 32),
                           ("collection_end_ms", 3000), ("clock", "utc")):
            changed = [*rows[:-1], {**rows[-1], key: value}]
            path = self.write("bad-finish-" + key + ".jsonl", "\n".join(json.dumps(x) for x in changed))
            self.assertEqual(dbg.compare_reports(original, path)["phase_comparison"]["changes"], [])

    def test_native_emission_time_filters_late_ingested_history(self):
        rows = [{"type": "server_ticks", "target": "Server", "clock": dbg.WINDOWS_CLOCK,
                 "tick_ms": end, "window_ms": 1000, "hz": rate, "at_utc": "late ingestion is not emission time"}
                for end, rate in ((1000, 999), (2000, 20), (3000, 20), (4000, 20), (5000, 999))]
        rows += [{"type": "timing", "target": "Server", "tick_ms": 2000, "calls": 1, "total_us": 2000, "max_us": 2000}]
        report = dbg.perf_report(self.phase_trace("native-history.jsonl", rows))
        self.assertEqual(report["phase"]["metrics"]["Server:simulation_hz"]["mean"], 20)
        channel = report["phase"]["channels"]["Server:simulation_hz"]
        self.assertEqual((channel["accepted_start_ms"], channel["accepted_end_ms"]), (1000, 4000))
        self.assertTrue(channel["qualified"])
        self.assertEqual(report["hotspots"][0]["total_us"], 2000)
        self.assertIn("inclusive_scope_period_unqualified", report["phase"]["channels"]["Server:timing"]["excluded"])

    def test_presentmon_and_unbounded_render_stay_descriptive(self):
        context = {**self.phase_context(), "resolution": [1920, 1080], "scale": 1.0}
        rows = self.phase_samples() + [
            {"type": "present_window", "target": "Server", "swapchain": "a", "present_rate_fps": 60, "max_ms": 20, "clock": dbg.WINDOWS_CLOCK, "tick_ms": 2000},
            {"type": "render_window", "target": "Server", "swapchain_slot": 0, "callback_rate_fps": 60, "mean_interval_ms": 16, "max_interval_ms": 20, "clock": dbg.WINDOWS_CLOCK, "tick_ms": 2000}]
        report = dbg.perf_report(self.phase_trace("separate-render.jsonl", rows, context))
        self.assertIn("Server:a:present_rate_fps", report["metrics"])
        self.assertIn("presentmon_clock_correspondence_missing", report["phase"]["channels"]["Server:a:present_rate_fps"]["reasons"])
        self.assertIn("source_period_unknown", report["phase"]["channels"]["Server:renderer_0:callback_rate_fps"]["reasons"])
        self.assertTrue(report["phase"]["channels"]["Server:cpu_core_percent"]["qualified"])

    def test_coverage_gaps_are_scoped_and_duration_is_controlled(self):
        rows = self.phase_samples() + [{"type": "coverage", "sensor": "render", "target": "Server", "clock": dbg.WINDOWS_CLOCK, "tick_ms": 2000}]
        before = self.phase_trace("scoped-gap.jsonl", rows)
        self.assertTrue(dbg.perf_report(before)["phase"]["channels"]["Server:cpu_core_percent"]["qualified"])
        rows.append({"type": "coverage", "sensor": "all", "target": "Server", "clock": dbg.WINDOWS_CLOCK, "tick_ms": 2000})
        after = self.phase_trace("all-gap.jsonl", rows)
        self.assertIn("coverage_gap_or_time_unknown", dbg.perf_report(after)["phase"]["channels"]["Server:cpu_core_percent"]["reasons"])
        changed = list(dbg.jsonl(before)); changed[0]["measurement_window"]["end_ms"] = 3000
        shorter = self.write("shorter.jsonl", "\n".join(json.dumps(x) for x in changed))
        self.assertIn("phase_duration_differs_or_unknown", dbg.compare_reports(before, shorter)["phase_comparison"]["reasons"])

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
