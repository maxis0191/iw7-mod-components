"""Tests of ops/engine (engine.py, engine_mcp.py, build_image.py) on synthetic inputs: no game file, no Ghidra."""
import json
import os
import shutil
import sqlite3
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
ENGINE = os.path.join(ROOT, "ops", "engine", "engine.py")
MCP = os.path.join(ROOT, "ops", "engine", "engine_mcp.py")
BUILD = os.path.join(ROOT, "ops", "engine", "build_image.py")
BASE = 0x140000000

# func A at 0x140001000: mov eax,0x18 ; cmp ecx,eax ; mov byte ptr [rdi+0x546],al ; call B ; ret
CODE_A = bytes.fromhex("b818000000" "39c1" "888746050000" "e806000000" "c3")
# func B at 0x140001020: mov eax, dword ptr [rip+X] (reads 0x140003000) ; ret
CODE_B_AT = 0x140001020


def make_pe(path):
    """Minimal PE32+: .text at 0x1000 (0x200 raw), .rdata at 0x2000, .data at 0x3000, .pdata at 0x4000."""
    text = bytearray(0x200)
    text[0:len(CODE_A)] = CODE_A
    rel = 0x140003000 - (CODE_B_AT + 6)
    text[0x20:0x27] = bytes.fromhex("8b05") + struct.pack("<i", rel) + b"\xc3"
    rdata = bytearray(0x200)
    data = bytearray(0x200)
    data[0:4] = struct.pack("<I", 24)
    pdata = bytearray(0x200)
    struct.pack_into("<III", pdata, 0, 0x1000, 0x1000 + len(CODE_A), 0)
    struct.pack_into("<III", pdata, 12, 0x1020, 0x1027, 0)
    secs = [(b".text", 0x1000, text, 0x60000020), (b".rdata", 0x2000, rdata, 0x40000040),
            (b".data", 0x3000, data, 0xC0000040), (b".pdata", 0x4000, pdata, 0x40000040)]
    hdr = bytearray(0x400)
    hdr[0:2] = b"MZ"
    struct.pack_into("<I", hdr, 0x3C, 0x80)
    hdr[0x80:0x84] = b"PE\0\0"
    struct.pack_into("<HH", hdr, 0x84, 0x8664, len(secs))
    struct.pack_into("<H", hdr, 0x94, 0xF0)
    struct.pack_into("<H", hdr, 0x98, 0x20B)
    struct.pack_into("<Q", hdr, 0x98 + 24, BASE)
    table = 0x98 + 0xF0
    raw = 0x400
    body = b""
    for i, (nm, va, buf, ch) in enumerate(secs):
        struct.pack_into("<8sIIII", hdr, table + 40 * i, nm, len(buf), va, len(buf), raw)
        struct.pack_into("<I", hdr, table + 40 * i + 36, ch)
        raw += len(buf)
        body += bytes(buf)
    with open(path, "wb") as f:
        f.write(bytes(hdr) + body)


def make_db(path):
    db = sqlite3.connect(path)
    sys.path.insert(0, os.path.join(ROOT, "ops", "engine"))
    import ghidra_export  # schema only; Ghidra is not started
    db.executescript(ghidra_export.SCHEMA)
    db.executemany("INSERT INTO functions VALUES(?,?,?,?,?,?,?,?)", [
        (0x140001000, 0x140001000 + len(CODE_A), "SelectMaxAgents", len(CODE_A), "byte SelectMaxAgents(void)", ".text", 0, "IMPORTED"),
        (CODE_B_AT, CODE_B_AT + 7, "FUN_140001020", 7, "int FUN_140001020(void)", ".text", 0, "DEFAULT")])
    db.execute("INSERT INTO calls VALUES(?,?,?,?)", (0x140001000, 0x14000100D, CODE_B_AT, "call"))
    db.execute("INSERT INTO refs VALUES(?,?,?,?,?)", (CODE_B_AT, CODE_B_AT, 0x140003000, "read", 1))
    db.execute("INSERT INTO strings VALUES(?,?)", (0x140002000, "scr_%s_maxagents"))
    db.execute("INSERT INTO refs VALUES(?,?,?,?,?)", (0x140001000, 0x140001002, 0x140002000, "data", 1))
    db.execute("INSERT INTO labels VALUES(?,?,?)", (0x140003000, "level_agentCount", "IMPORTED"))
    db.execute("INSERT INTO types VALUES(?,?,?,?,?)", ("agent_t", "/iw7", "struct", 0x5010,
               json.dumps([{"offset": 0, "name": "ent", "type": "gentity_s *", "size": 8}])))
    code = "byte SelectMaxAgents(void)\n{\n  if (0x18 < n) n = 0x18;\n  gs->maxAgents = n;\n}\n"
    db.execute("INSERT INTO decomp VALUES(?,?,?,?)", (0x140001000, 1, 0.1, zlib.compress(code.encode())))
    db.commit()
    db.close()


class EngineTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp()
        cls.image = os.path.join(cls.tmp, "img.exe")
        make_pe(cls.image)
        cls.db = os.path.join(cls.tmp, "e.sqlite")
        make_db(cls.db)
        cls.index = os.path.join(cls.tmp, "i.sqlite")
        cls.knowledge = os.path.join(cls.tmp, "knowledge.json")
        snap = os.path.join(cls.tmp, "snaps", "s1")
        os.makedirs(snap)
        with open(os.path.join(snap, "140003000.bin"), "wb") as f:
            f.write(struct.pack("<IQ", 24, 0x140003000))
        json.dump({"schema": "iw7.engine-dump-sections/1", "sections": [{"name": ".data", "va": "0x140003000", "bytes": 12}]},
                  open(os.path.join(snap, "sections.json"), "w"))
        cls.env = dict(os.environ, IW7_ENGINE_KNOWLEDGE=cls.knowledge, IW7_AGENT="test")

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def run_engine(self, *args, ok=True):
        argv = [sys.executable, "-B", ENGINE, "--db", self.db, "--index", self.index, "--image", self.image,
                "--snapshots", os.path.join(self.tmp, "snaps"), "--names", os.path.join(self.tmp, "none.json")] + list(args)
        r = subprocess.run(argv, capture_output=True, text=True, env=self.env)
        if ok:
            self.assertEqual(r.returncode, 0, r.stderr)
        return r

    def test_find_and_at(self):
        r = self.run_engine("find", "maxagents")
        self.assertIn("scr_%s_maxagents", r.stdout)
        self.assertIn("SelectMaxAgents", r.stdout)
        r = self.run_engine("at", "0x140001005")
        self.assertIn("SelectMaxAgents", r.stdout)
        self.assertIn("+0x5", r.stdout)

    def test_decomp_grep_callers_xrefs(self):
        self.assertIn("gs->maxAgents", self.run_engine("decomp", "SelectMaxAgents").stdout)
        self.assertIn("SelectMaxAgents:3", self.run_engine("grep", r"0x18 <").stdout)
        self.assertIn("SelectMaxAgents", self.run_engine("callers", "0x140001020").stdout)
        self.assertIn("FUN_140001020", self.run_engine("callees", "SelectMaxAgents").stdout)
        self.assertIn("read", self.run_engine("xrefs", "level_agentCount").stdout)

    def test_index_imm_disp_and_disasm(self):
        self.run_engine("index")
        r = self.run_engine("imm", "0x18")
        self.assertIn("140001000", r.stdout)
        r = self.run_engine("imm", "0x546", "--disp")
        self.assertIn("140001007", r.stdout)
        r = self.run_engine("--json", "imm", "0x140003000")
        self.assertEqual(json.loads(r.stdout)["total"], 0)  # rip-relative target is kind addr, not imm
        r = self.run_engine("disasm", "FUN_140001020")
        self.assertIn("level_agentCount", r.stdout)

    def test_struct_and_mem(self):
        self.assertIn("gentity_s", self.run_engine("struct", "agent_t").stdout)
        r = self.run_engine("--json", "mem", "0x140003000", "--type", "u32")
        self.assertEqual(json.loads(r.stdout)["values"], [24])
        r = self.run_engine("--json", "mem", "[0x140003004]+0x0", "--type", "u32")
        self.assertEqual(json.loads(r.stdout)["values"], [24])

    def test_knowledge_write_back(self):
        self.run_engine("name", "0x140001020", "G_GetLevelAgentCount", "--evidence", "decomp")
        r = self.run_engine("name", "0x140001000", "G_GetLevelAgentCount", "--evidence", "x", ok=False)
        self.assertNotEqual(r.returncode, 0)
        self.run_engine("note", "0x140001000", "agent limit clamp", "--tag", "limit", "--value", "24", "--evidence", "imm 0x18")
        data = json.load(open(self.knowledge))
        self.assertEqual(data["names"][0]["name"], "G_GetLevelAgentCount")
        self.assertEqual(data["notes"][0]["tag"], "limit")
        self.assertIn("G_GetLevelAgentCount", self.run_engine("callees", "SelectMaxAgents").stdout)
        self.assertIn("agent limit clamp", self.run_engine("notes", "--tag", "limit").stdout)

    def test_mcp_list_and_call(self):
        msgs = [{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}},
                {"jsonrpc": "2.0", "method": "notifications/initialized"},
                {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
                {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "status", "arguments": {}}}]
        env = dict(self.env, IW7_ENGINE_DB=self.db)
        r = subprocess.run([sys.executable, "-B", MCP], input="\n".join(json.dumps(m) for m in msgs) + "\n",
                           capture_output=True, text=True, env=env)
        replies = [json.loads(l) for l in r.stdout.splitlines()]
        self.assertEqual([x["id"] for x in replies], [1, 2, 3])
        self.assertIn("decomp", [t["name"] for t in replies[1]["result"]["tools"]])
        self.assertFalse(replies[2]["result"]["isError"], replies[2])
        self.assertIn("functions", replies[2]["result"]["content"][0]["text"])

    def test_build_image_replaces_sections(self):
        dump = os.path.join(self.tmp, "dump")
        os.makedirs(dump, exist_ok=True)
        with open(os.path.join(dump, "140003000.bin"), "wb") as f:
            f.write(struct.pack("<I", 42) + bytes(0x1FC))
        out = os.path.join(self.tmp, "rebuilt.exe")
        r = subprocess.run([sys.executable, "-I", BUILD, "--exe", self.image, "--live-dump", dump, "--out", out],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        blob = open(out, "rb").read()
        self.assertIn(struct.pack("<I", 42), blob[0x800:0x804])


if __name__ == "__main__":
    unittest.main()
