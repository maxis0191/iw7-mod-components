"""atlas.py and the engine.py commands limits / dvars / builtins / atlas build, on a small synthetic database
(fake functions, strings, references; no game data)."""
import contextlib
import io
import json
import os
import sqlite3
import sys
import tempfile
import unittest
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "ops", "engine"))
import atlas  # noqa: E402
import engine  # noqa: E402

LIMIT_FN, NOCOND_FN, REG_FN, READER_FN, GSCR_FN, PCMD_FN, CALLER_A, CALLER_B = (
    0x140001000, 0x140002000, 0x140003000, 0x140003800, 0x140004000, 0x140004100, 0x140005000, 0x140005100)
S_LIMIT, S_NOCOND, S_NAME, S_ERR = 0x140100001, 0x140100100, 0x140100200, 0x140100300
D_ONE, D_TWO = 0x140200010, 0x140200020

LIMIT_CODE = """
void FUN_140001000(uint param_1)
{
  if (0x40 < param_1 && DAT_140200777 != 0) {
    Com_Error(1,"Too many widgets loaded, maximum is %i",0x40);
  }
}
"""
NOCOND_CODE = "void FUN_140002000(void)\n{\n  Com_Error(1,&DAT_140100100);\n}\n"
REG_CODE = """
void FUN_140003000(void)
{
  DAT_140200010 = Dvar_RegisterFloat("com_scale",0x3f800000,0x3a83126f,0x447a0000,uVar2);
  DAT_140200020 = Dvar_RegisterInt("g_cap",0x18,0,0x100,0x1000,"cap");
  local_8 = Dvar_RegisterBool("g_flag",1,0);
}
"""
READER_CODE = "void FUN_140003800(void)\n{\n  x = DAT_140200010;\n}\n"
PLAIN = "void f(void)\n{\n}\n"


def make_db(path):
    db = sqlite3.connect(path)
    db.executescript("""
        CREATE TABLE functions(addr INTEGER, end INTEGER, name TEXT, size INTEGER, signature TEXT, block TEXT, thunk INTEGER, source TEXT);
        CREATE TABLE strings(addr INTEGER, text TEXT);
        CREATE TABLE refs(src_func INTEGER, at INTEGER, dst INTEGER, kind TEXT, operand INTEGER);
        CREATE TABLE calls(src_func INTEGER, at INTEGER, dst INTEGER, kind TEXT);
        CREATE TABLE decomp(addr INTEGER, ok INTEGER, seconds REAL, code BLOB);
    """)
    funcs = {LIMIT_FN: "FUN_140001000", NOCOND_FN: "FUN_140002000", REG_FN: "FUN_140003000", READER_FN: "FUN_140003800",
             GSCR_FN: "GScr_dosomething", PCMD_FN: "PlayerCmd_Kick", CALLER_A: "FUN_140005000", CALLER_B: "FUN_140005100"}
    for a, n in funcs.items():
        db.execute("INSERT INTO functions VALUES(?,?,?,?,?,?,?,?)", (a, a + 0x80, n, 0x80, "", "", 0, ""))
    for a, t in ((S_LIMIT, "Too many widgets loaded, maximum is %i"), (S_NOCOND, "Out of memory in pool xyz"),
                 (S_NAME, "r_dustSmoothMax"), (S_ERR, "bad argument count for kick")):
        db.execute("INSERT INTO strings VALUES(?,?)", (a, t))
    # the first string is referenced one byte before its address, as the decompiler's data labels do
    for src, dst in ((LIMIT_FN, S_LIMIT - 1), (NOCOND_FN, S_NOCOND), (LIMIT_FN, S_NAME), (PCMD_FN, S_ERR),
                     (READER_FN, D_ONE), (REG_FN, D_ONE)):
        db.execute("INSERT INTO refs VALUES(?,?,?,?,0)", (src, src + 4, dst, "write" if src == REG_FN else "read"))
    for c in (CALLER_A, CALLER_B, CALLER_B):
        db.execute("INSERT INTO calls VALUES(?,?,?,?)", (c, c + 8, LIMIT_FN, "call"))
    for a, code in ((LIMIT_FN, LIMIT_CODE), (NOCOND_FN, NOCOND_CODE), (REG_FN, REG_CODE), (READER_FN, READER_CODE),
                    (GSCR_FN, PLAIN), (PCMD_FN, PLAIN)):
        db.execute("INSERT INTO decomp VALUES(?,1,0,?)", (a, zlib.compress(code.encode())))
    db.commit()
    return db


class AtlasTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(ignore_cleanup_errors=True)
        cls.dbpath = os.path.join(cls.tmp.name, "e.sqlite")
        cls.db = make_db(cls.dbpath)
        cls.atlas_dir = os.path.join(cls.tmp.name, "atlas")

    @classmethod
    def tearDownClass(cls):
        cls.db.close()
        cls.tmp.cleanup()

    def run_cmd(self, *args):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(io.StringIO()):
            engine.main(["--db", self.dbpath, "--atlas", self.atlas_dir, "--index", "none", *args])
        return buf.getvalue()

    def test_limit_with_condition(self):
        recs = {r["text"]: r for r in atlas.build_limits(self.db)}
        r = recs["Too many widgets loaded, maximum is %i"]
        self.assertEqual(r["function"]["addr"], f"{LIMIT_FN:X}")
        self.assertIn("0x40 < param_1", r["condition"])
        self.assertEqual(r["constants"], [0x40])
        self.assertEqual(r["globals"], ["140200777"])
        self.assertEqual(r["callers"], 2)

    def test_limit_without_condition_is_kept(self):
        recs = {r["text"]: r for r in atlas.build_limits(self.db)}
        r = recs["Out of memory in pool xyz"]
        self.assertIsNone(r["condition"])
        self.assertEqual(r["constants"], [])

    def test_name_like_string_dropped(self):
        self.assertFalse([r for r in atlas.build_limits(self.db) if "dustSmooth" in r["text"]])

    def test_dvar_float_and_int(self):
        recs = {r["name"]: r for r in atlas.build_dvars(self.db)}
        f = recs["com_scale"]
        self.assertEqual((f["kind"], f["default"], f["min"], f["max"]), ("Float", 1.0, 0.001, 1000.0))
        self.assertEqual(f["pointer"], f"{D_ONE:X}")
        self.assertEqual(f["registered_in"]["addr"], f"{REG_FN:X}")
        i = recs["g_cap"]
        self.assertEqual((i["default"], i["min"], i["max"]), (0x18, 0, 0x100))
        self.assertEqual(recs["g_flag"]["default"], 1)
        self.assertIsNone(recs["g_flag"]["pointer"])

    def test_dvar_reader_counted(self):
        f = [r for r in atlas.build_dvars(self.db) if r["name"] == "com_scale"][0]
        self.assertEqual(f["reader_count"], 1)  # the registering write is not a reader
        self.assertEqual(f["readers"][0]["function"], f"{READER_FN:X}")

    def test_builtins(self):
        recs = {r["script_name"]: r for r in atlas.build_builtins(self.db)}
        self.assertEqual(recs["dosomething"]["kind"], "function")
        self.assertEqual(recs["kick"]["kind"], "method")
        self.assertEqual(recs["kick"]["native"]["addr"], f"{PCMD_FN:X}")
        self.assertEqual(recs["kick"]["strings"], ["bad argument count for kick"])

    def test_commands_and_build_on_first_use(self):
        self.assertFalse(os.path.exists(self.atlas_dir))
        text = self.run_cmd("limits", "widgets")
        self.assertIn("Too many widgets loaded", text)
        self.assertIn("FUN_140001000 at 0x140001000 (2 callers)", text)
        self.assertIn("constants: 64 (0x40)", text)
        self.assertIn("next: engine.py decomp 0x140001000", text)
        out = self.run_cmd("atlas", "build")
        self.assertIn("limits: 2 records", out)
        d = self.run_cmd("dvars", "scale")
        self.assertIn("com_scale  [Float]  default 1.0  min 0.001  max 1000.0", d)
        self.assertIn(f"pointer 0x{D_ONE:X}", d)
        self.assertIn(f"next: engine.py xrefs 0x{D_ONE:X}", d)
        b = self.run_cmd("builtins", "kick")
        self.assertIn(f"PlayerCmd_Kick at 0x{PCMD_FN:X}", b)
        self.assertIn("next: engine.py decomp", b)
        top = self.run_cmd("limits")
        self.assertIn("2 limit messages", top)

    def test_json(self):
        recs = json.loads(self.run_cmd("--json", "builtins", "dosomething"))
        self.assertEqual(recs[0]["native"]["name"], "GScr_dosomething")
        recs = json.loads(self.run_cmd("limits", "Out of memory", "--json"))
        self.assertIsNone(recs[0]["condition"])


if __name__ == "__main__":
    unittest.main()
