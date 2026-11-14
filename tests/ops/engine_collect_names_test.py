"""Tests for ops/engine/collect_names.py with synthetic inputs (no game files).

Run: python -I tests/ops/engine_collect_names_test.py
"""
import importlib.util
import json
import os
import struct
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
MODULE = os.path.join(HERE, "..", "..", "ops", "engine", "collect_names.py")
spec = importlib.util.spec_from_file_location("collect_names", MODULE)
cn = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cn)

SYMBOLS = """#pragma once
#define WEAK __declspec(selectany)
namespace game
{
	WEAK symbol<void(int type, VariableUnion u)> AddRef{ 0x140C04360 };
	// WEAK symbol<void()> Commented{ 0x140000001 };
	WEAK symbol<int(int a,
		float b)> MultiLine{ 0x140C0ACD0 };
	WEAK symbol<char* (char* s)> PtrRet { 0x140CFACC0 };
	WEAK symbol<int> SomeVar{ 0x142000000 };
	namespace hks
	{
		WEAK symbol<void()> Inner{ 0x1411D07B0 };
	}
	WEAK symbol<void()> Odd{ SOME_MACRO };
}
"""

GSC = """static main(void)
{
    LabelFunction("GScr_%s", "abs", 0x140B35B20);
    // skipped ambientplay (nullptr)
    LabelFunction("PlayerCmd_%s", "allowads", 0x140B08FF0);
    LabelFunction("GScr_%s", "broken", SOMETHING);
}
"""

LUA = """static LabelFunctions(table_ea)
{
    name = form("LUI_CoD_LuaCall_%s", name);
}
static main(void)
{
    // Engine
    LabelFunctions(0x141435000);
    // Other
    LabelFunctions(0x141435040);
}
"""

STRUCTS = """namespace game
{
	enum Mode : std::uint32_t { A = 0 };
	struct Plain
	{
		char a;      // 0
		int b;       // 4
		void* c;     // 8
		char name[32];
		float f[3], g;
	}; static_assert(sizeof(Plain) == 64);
	struct Partial
	{
		short number;
		char __pad0[150];
		int clientNum;
	}; // sizeof = ?
	assert_offsetof(Partial, clientNum, 152);
#pragma pack(push, 1)
	struct Packed
	{
		char a;
		int b;
		Mode m;
	};
#pragma pack(pop)
	struct Unknown
	{
		int a;
		SomeUnknownType u;
		int after;
	};
	static_assert(offsetof(Unknown, after) == 99);
	struct UsesPad
	{
		Plain p;
		char __pad[100 - sizeof(Plain)];
		int tail;
	};
	struct Derived : Plain
	{
		int x;
	};
}
"""


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)


class SymbolsTest(unittest.TestCase):
    def test_parse(self):
        entries, st = cn.parse_symbols(SYMBOLS)
        by = {e["name"]: e for e in entries}
        self.assertEqual(set(by), {"AddRef", "MultiLine", "PtrRet", "SomeVar", "hks::Inner"})
        self.assertEqual(by["AddRef"]["address"], "140C04360")
        self.assertEqual(by["AddRef"]["kind"], "function")
        self.assertEqual(by["AddRef"]["type"], "void AddRef(int type, VariableUnion u)")
        self.assertEqual(by["MultiLine"]["address"], "140C0ACD0")
        self.assertEqual(by["PtrRet"]["type"], "char* PtrRet(char* s)")
        self.assertEqual(by["SomeVar"]["kind"], "data")
        self.assertEqual(by["SomeVar"]["type"], "int SomeVar")
        self.assertEqual(st["declarations"], 6)
        self.assertEqual(st["parsed"], 5)
        # `Odd` has a macro instead of an address; it is a declaration we could not parse
        self.assertEqual(st["unparsed_lines"], 1)


class GscTest(unittest.TestCase):
    def test_parse(self):
        entries, st = cn.parse_gsc_idc(GSC)
        self.assertEqual([(e["name"], e["address"]) for e in entries],
                         [("GScr_abs", "140B35B20"), ("PlayerCmd_allowads", "140B08FF0")])
        self.assertEqual(st["skipped_nullptr"], 1)
        self.assertEqual(st["unparsed_lines"], 1)


class LuaTest(unittest.TestCase):
    def test_parse(self):
        base = 0x141435000
        blob = bytearray(0x200)
        blob[0x100:0x104] = b"Foo\x00"
        blob[0x110:0x114] = b"Bar\x00"
        struct.pack_into("<QQQQQQ", blob, 0, base + 0x100, 0x1400C6E30, base + 0x110, 0x1400C75B0, 0, 0)
        # table 2: unreadable name pointer -> sub_<addr>
        struct.pack_into("<QQQQ", blob, 0x40, 0x150000000, 0x1400AAAA0, 0, 0)
        entries, st = cn.parse_lua_idc(LUA, cn.Rdata(bytes(blob), base))
        self.assertEqual([(e["name"], e["address"]) for e in entries], [
            ("LUI_CoD_LuaCall_Foo", "1400C6E30"),
            ("LUI_CoD_LuaCall_Bar", "1400C75B0"),
            ("LUI_CoD_LuaCall_sub_1400AAAA0", "1400AAAA0")])
        self.assertEqual([(t["table"], t["entries"]) for t in st["tables"]], [("Engine", 2), ("Other", 1)])


class CsvTest(unittest.TestCase):
    def test_parse(self):
        entries, st = cn.parse_csv("name,address\nvoice_batch,14037D5C0\nbad line\nx,0x140001000\n")
        self.assertEqual([(e["name"], e["address"]) for e in entries],
                         [("voice_batch", "14037D5C0"), ("x", "140001000")])
        self.assertEqual(st["unparsed_lines"], 1)


class ForkSrcTest(unittest.TestCase):
    def test_scan(self):
        with tempfile.TemporaryDirectory() as tmp:
            write(os.path.join(tmp, "src/client/component/foo-bar.cpp"),
                  "a = 0x140123456;\nb = 0x140123456;\nc = 0x14012345678;\nd = 0x140000000;\n")
            write(os.path.join(tmp, "src/client/game/symbols.hpp"), "0x140999999")
            hits, digest, files = cn.scan_fork_src(tmp)
            self.assertEqual(files, 1)
            self.assertEqual([(h[0], h[1], h[2], h[3]) for h in hits],
                             [("140123456", "foo_bar", "src/client/component/foo-bar.cpp", 1),
                              ("140123456", "foo_bar", "src/client/component/foo-bar.cpp", 2),
                              ("140000000", "foo_bar", "src/client/component/foo-bar.cpp", 4)])
            self.assertEqual(len(digest), 64)


class StructsTest(unittest.TestCase):
    def setUp(self):
        structs, self.stats = cn.parse_structs(STRUCTS)
        self.s = {s["name"]: s for s in structs}

    @staticmethod
    def offs(s):
        return {f["name"]: f["offset"] for f in s["fields"]}

    def test_plain(self):
        s = self.s["Plain"]
        self.assertEqual(s["size"], 64)
        self.assertEqual(self.offs(s), {"a": 0, "b": 4, "c": 8, "name": 16, "f": 48, "g": 60})
        self.assertNotIn("note", s)

    def test_partial_struct_has_no_size(self):
        s = self.s["Partial"]
        self.assertIsNone(s["size"])
        self.assertEqual(self.offs(s), {"number": 0, "__pad0": 2, "clientNum": 152})

    def test_pack(self):
        self.assertEqual(self.offs(self.s["Packed"]), {"a": 0, "b": 1, "m": 5})

    def test_unknown_type_stops_offsets(self):
        s = self.s["Unknown"]
        self.assertEqual(self.offs(s), {"a": 0, "u": None, "after": 99})
        self.assertTrue(s["fields"][2]["asserted"])
        self.assertIn("size of `SomeUnknownType` unknown", s["note"])

    def test_sizeof_expression(self):
        s = self.s["UsesPad"]
        self.assertEqual(self.offs(s), {"p": 0, "__pad": 64, "tail": 100})

    def test_base_class(self):
        s = self.s["Derived"]
        self.assertEqual(self.offs(s), {"x": None})
        self.assertIn("base class", s["note"])


class MergeTest(unittest.TestCase):
    def test_priority_and_aliases(self):
        names, conflicts = cn.merge({
            "symbols.hpp": [{"address": "140000010", "name": "S", "kind": "function", "type": "void S()"}],
            "gsc-idc": [{"address": "140000010", "name": "G", "kind": "function"},
                        {"address": "140000020", "name": "G2", "kind": "function"}],
            "csv": [{"address": "140000010", "name": "S", "kind": "function"}],
            "fork-src": [{"address": "140000010", "name": "hook_x_140000010", "kind": "unknown", "source": "fork-src:a:1"},
                         {"address": "140000030", "name": "hook_x_140000030", "kind": "unknown", "source": "fork-src:a:2"}],
        })
        self.assertEqual([n["name"] for n in names], ["S", "G2", "hook_x_140000030"])
        self.assertEqual(names[0]["source"], "symbols.hpp")
        self.assertEqual(names[0]["type"], "void S()")
        self.assertEqual(names[0]["aliases"], [{"name": "G", "source": "gsc-idc"}])
        self.assertEqual(conflicts, 1)


class EndToEndTest(unittest.TestCase):
    def test_main(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = os.path.join(tmp, "native")
            write(os.path.join(root, "src/client/game/symbols.hpp"), SYMBOLS)
            write(os.path.join(root, "src/client/game/structs.hpp"), STRUCTS)
            write(os.path.join(root, "src/client/component/hook.cpp"), "x(0x140B35B20); y(0x140777777);")
            write(os.path.join(root, "ida_scripts/iw7 label GSC builtins.idc"), GSC)
            write(os.path.join(root, "ida_scripts/iw7 label LUA builtins.idc"), LUA)
            rd = os.path.join(tmp, "rdata.bin")
            blob = bytearray(0x200)
            struct.pack_into("<QQQQ", blob, 0, 0x141435100, 0x1400C6E30, 0, 0)
            blob[0x100:0x104] = b"Foo\x00"
            with open(rd, "wb") as f:
                f.write(blob)
            csv = os.path.join(tmp, "v.csv")
            write(csv, "voice_batch,14037D5C0\n")
            out = os.path.join(tmp, "out", "names.json")
            self.assertEqual(cn.main(["--native-root", root, "--rdata", rd, "--out", out, "--csv", csv]), 0)
            with open(out, encoding="utf-8") as f:
                d = json.load(f)
            self.assertEqual(d["schema"], "iw7.engine-names/1")
            for k in ("symbols.hpp", "gsc-idc", "lua-idc", "structs.hpp", "unpacked-rdata.bin", "fork-src", "csv:v.csv"):
                self.assertEqual(len(d["generated_from"][k]), 64, k)
            by = {n["address"]: n for n in d["names"]}
            self.assertEqual(by["140B35B20"]["name"], "GScr_abs")  # named by gsc, not by the hook
            self.assertEqual(by["140777777"]["name"], "hook_hook_140777777")
            self.assertEqual(by["140777777"]["kind"], "unknown")
            self.assertEqual(by["1400C6E30"]["name"], "LUI_CoD_LuaCall_Foo")
            self.assertEqual(by["14037D5C0"]["source"], "csv")
            self.assertEqual(by["140C04360"]["type"], "void AddRef(int type, VariableUnion u)")
            self.assertTrue(any(s["name"] == "Plain" for s in d["structs"]))


if __name__ == "__main__":
    unittest.main()
