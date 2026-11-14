"""Unit tests of ops/engine/live/engine_live.py without a game: address expressions, watch specs, the cdb script
and its output parser, and the ownership refusal.

    python -I -m unittest tests/ops/engine_live_test.py      (or: python -I tests/ops/engine_live_test.py)
"""
import os
import re
import struct
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "ops", "engine", "live"))
import engine_live as el  # noqa: E402

MEM = {0x143C986B8: 0x145C9E590, 0x145C9E590 + 0x10: 0x1460000AA}


def read_ptr(a):
    if a not in MEM:
        raise el.ToolError("unmapped 0x%X" % a)
    return MEM[a]


class Expressions(unittest.TestCase):
    def test_plain_hex_forms(self):
        self.assertEqual(el.evaluate("0x140C18D00", {}, read_ptr), 0x140C18D00)
        self.assertEqual(el.evaluate("140C18D00", {}, read_ptr), 0x140C18D00)
        self.assertEqual(el.evaluate("0n24", {}, read_ptr), 24)

    def test_deref_chain_and_steps(self):
        steps = []
        v = el.evaluate("[0x143C986B8]+0x546", {}, read_ptr, steps)
        self.assertEqual(v, 0x145C9E590 + 0x546)
        self.assertEqual(steps[0], {"read": "0x143c986b8", "value": "0x145c9e590"})
        self.assertEqual(el.evaluate("[[0x143C986B8]+0x10]-0xA", {}, read_ptr), 0x1460000A0)

    def test_names(self):
        names = {"agent_pool_ptr": 0x143C986B8}
        self.assertEqual(el.evaluate("[agent_pool_ptr]+0x4A90", names, read_ptr), 0x145C9E590 + 0x4A90)
        self.assertEqual(el.evaluate("sub_140B53330", {}, read_ptr), 0x140B53330)
        with self.assertRaises(el.ToolError):
            el.evaluate("no_such_name", {}, read_ptr)

    def test_bad_expressions(self):
        for bad in ("[0x10", "0x10]", "0x10 +", "0x10 * 2"):
            with self.assertRaises(el.ToolError, msg=bad):
                el.evaluate(bad, {}, read_ptr)

    def test_names_file_schema(self):
        import json
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "n.json")
            with open(p, "w") as f:
                json.dump({"schema": "iw7.engine-names/1", "names": [{"address": "140B53330", "name": "GScr_addagent"}]}, f)
            self.assertEqual(el.load_names(p), {"GScr_addagent": 0x140B53330})
            with open(p, "w") as f:
                json.dump({"schema": "other", "names": []}, f)
            with self.assertRaises(el.ToolError):
                el.load_names(p)


class Types(unittest.TestCase):
    def test_types_and_watch(self):
        self.assertEqual(el.parse_type("u32"), ("u32", 1, False))
        self.assertEqual(el.parse_type("nzu8x24"), ("u8", 24, True))
        with self.assertRaises(el.ToolError):
            el.parse_type("u33")
        w = el.parse_watch("[0x143C986B8]+0x546:u8:250:40")
        self.assertEqual((w["expr"], w["type"], w["interval_ms"], w["count"]), ("[0x143C986B8]+0x546", "u8", 250, 40))
        with self.assertRaises(el.ToolError):
            el.parse_watch("0x10:u8:0:5")

    def test_decode(self):
        raw = bytes([1, 0, 3, 0]) + struct.pack("<f", 1.5)
        self.assertEqual(el.decode(raw, "u8", 4, nz=True), 2)
        self.assertEqual(el.decode(raw, "u8", 4), [1, 0, 3, 0])
        self.assertEqual(el.decode(raw[4:], "f32", 1), 1.5)
        self.assertEqual(el.decode(struct.pack("<Q", 0x145C9E590), "ptr", 1), "0x145c9e590")
        self.assertEqual(el.decode(b"cp_zmb\0junk", "str", 1), "cp_zmb")


class CdbScript(unittest.TestCase):
    def test_hw_script(self):
        s = el.build_script([0x140B53330], ["rcx", "poi(rdx+8)"], ret=True, mode="hw", hits=5)
        bp = [ln for ln in s if ln.startswith("ba0 e1 0x140B53330")]
        self.assertEqual(len(bp), 1)
        self.assertIn('.printf \\"ELVHIT 0 %x %p %p\\\\n\\", @$tid, @rcx, poi(@rdx+8)', bp[0])
        # the return breakpoint comes before .printf and has its own id (ba takes no /1)
        # with --ret the hit counter lives in the return breakpoint, so no return breakpoint is pending at a stop
        self.assertIn('"ba10 e1 @$ra \\".echo ELVRET 0; r rax; bc 10; r $t1 = @$t1 + 1; '
                      '.if (@$t1 >= 0n5) { .echo ELVLIMIT } .else { gc }\\"; .printf', bp[0])
        self.assertTrue(bp[0].endswith('poi(@rdx+8); gc"'))
        s2 = el.build_script([0x140B53330], ["rcx"], mode="hw", hits=5)
        self.assertTrue(s2[-4].endswith('.if (@$t1 >= 0n5) { .echo ELVLIMIT } .else { gc }"'))
        self.assertEqual(s[-1], "g")
        self.assertIn("sxd av", s)

    def test_sw_script_and_hw_limit(self):
        s = el.build_script([1, 2, 3], [], mode="sw", hits=0)
        bps = [x for x in s if re.match(r"bp\d 0x", x)]
        self.assertEqual([x.split()[0] for x in bps], ["bp0", "bp1", "bp2"])
        self.assertTrue(all(x.endswith('gc"') for x in bps))
        with self.assertRaises(el.ToolError):
            el.build_script([1, 2, 3], [], ret=True, mode="hw")

    def test_stop_breakpoints(self):
        s = el.build_script([0x140C1B900], ["rcx"], mode="hw", hits=3, stop_at=["ntdll!NtDelayExecution"],
                            deadline=0x1DC5A0000000000)
        self.assertIn("bp30 ntdll!NtDelayExecution \"j (qwo(0x7ffe0014) > 0x1DC5A0000000000) '.echo ELVSTOP'; 'gc'\"", s)
        self.assertEqual(el.stop_lines(["a!b", "c!d"]), ['bp30 a!b ".echo ELVSTOP"', 'bp31 c!d ".echo ELVSTOP"'])
        self.assertEqual([r["kind"] for r in el.parse_cdb_output(["0:000> ELVSTOP"], 0)], ["stop"])

    def test_cdb_expr(self):
        self.assertEqual(el.cdb_expr("poi(rcx+8)"), "poi(@rcx+8)")
        self.assertEqual(el.cdb_expr("@rcx"), "@rcx")
        self.assertEqual(el.cdb_expr("by(r8+0x546)"), "by(@r8+0x546)")

    def test_parse_output(self):
        sample = [
            "0:000> bl",
            '     0 e Disable Clear  00000001`40b53330 e 1 0001 (0001)  0:**** ".printf \\"ELVHIT 0 %x %p\\\\n\\", @$tid, @rcx; .if (@$t1 >= 0n2) { .echo ELVLIMIT } .else { gc }"',
            "0:000> ELVREADY",
            "ELVHIT 0 1a2c 00000001`45c9e590",
            "ELVRET 0",
            "rax=0000000000000001",
            "ELVHIT 0 1a2c 0000000000000000",
            "ELVLIMIT",
            "Unable to insert breakpoint 1 at 00000001`40b53330, Win32 error 0n998",
            "(1f00.2a04): Access violation - code c0000005 (first chance)",
            "Adjusting checksum (14B000000): 1 -> 2",
        ]
        st = {}
        recs = [r for line in sample for r in el.parse_cdb_output([line], 1, st)]  # one line at a time, as live
        kinds = [r["kind"] for r in recs]
        self.assertEqual(kinds, ["ready", "hit", "return", "hit", "limit", "error", "exception", "protector"])
        self.assertEqual(recs[1]["values"], ["0x145c9e590"])
        self.assertEqual(recs[1]["tid"], 0x1A2C)
        self.assertEqual(recs[2]["rax"], "0x1")
        self.assertEqual(recs[3]["values"], ["0x0"])


class Ownership(unittest.TestCase):
    BENCH = r"C:\bench"
    IMG = r"C:\bench\glh-1234abcd\server\iw7-paris-voice.exe"
    CREATED = "2026-11-11T18:29:02.188004+00:00"

    def manifests(self, path):
        if os.path.normcase(path) == os.path.normcase(r"C:\bench\glh-1234abcd\server\paris-bench-root.json"):
            return {"Schema": "iw7.bench-root/1"}
        return None

    def lease(self, pid=4242, image=None, created="2026-11-11T18:29:02.1880045Z", scope=r"c:\bench\glh-1234abcd"):
        return {"Token": "abcdef0123", "Owner": "gamelab headless session", "Scope": scope,
                "Processes": [{"PID": pid, "Image": image or self.IMG, "CreatedUtc": created}]}

    def info(self, **kw):
        d = {"pid": 4242, "image": self.IMG, "created_utc": self.CREATED, "name": "iw7-paris-voice.exe"}
        d.update(kw)
        return d

    def test_ours(self):
        j = el.judge_ownership(self.info(), [self.lease()], self.BENCH, self.manifests)
        self.assertTrue(j["ours"], j)
        self.assertEqual(j["scope"], r"c:\bench\glh-1234abcd")

    def test_refusals(self):
        cases = {
            "owner game": (self.info(image=r"C:\Users\x\Desktop\iw_game_files\iw7-cb-aurora.exe"), [self.lease()]),
            "no lease": (self.info(), []),
            "other pid": (self.info(), [self.lease(pid=1)]),
            "pid reused": (self.info(created_utc="2026-11-11T19:00:00+00:00"), [self.lease()]),
            "other image": (self.info(), [self.lease(image=r"C:\other\iw7-paris-voice.exe")]),
            "not a bench": (self.info(image=r"C:\Games\IW7\iw7-paris-voice.exe"),
                            [self.lease(image=r"C:\Games\IW7\iw7-paris-voice.exe", scope=r"c:\games")]),
        }
        for name, (info, leases) in cases.items():
            j = el.judge_ownership(info, leases, self.BENCH, self.manifests)
            self.assertFalse(j["ours"], name)

    def test_bench_outside_parent(self):
        j = el.judge_ownership(self.info(), [self.lease()], r"C:\elsewhere", self.manifests)
        self.assertFalse(j["ours"])

    def test_i_own_it(self):
        j = el.judge_ownership(self.info(), [], self.BENCH, self.manifests, own_image=self.IMG)
        self.assertTrue(j["ours"])
        j = el.judge_ownership(self.info(), [], self.BENCH, self.manifests, own_image=r"C:\x.exe")
        self.assertFalse(j["ours"])
        aurora = self.info(image=r"C:\g\iw7-cb-aurora.exe")
        j = el.judge_ownership(aurora, [], self.BENCH, self.manifests, own_image=r"C:\g\iw7-cb-aurora.exe")
        self.assertFalse(j["ours"], "the owner's game is refused even with --i-own-it")


if __name__ == "__main__":
    unittest.main()
