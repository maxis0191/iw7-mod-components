"""static_tables.py: the three passes on hand-built functions (fake image), and, when the analysed engine image exists on this
machine, on the real functions of tables the capacity work already knows (the entity queue, the per-character work tables, the
sentient pool). No game, no Ghidra run."""
import os
import struct
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "ops", "engine"))
import static_tables as st  # noqa: E402

CODE = 0x140001000
DATA = 0x140003000
X = DATA + 0x100          # the table under test
Y = X + 42 * 0x208 + 0x10  # the next module's global, 42 rows plus 16 bytes after the table


class Image:
    def __init__(self):
        self.mem = bytearray(0x10000)

    def put(self, a, b):
        self.mem[a - 0x140000000:a - 0x140000000 + len(b)] = b

    def read(self, a, n):
        o = a - 0x140000000
        return bytes(self.mem[o:o + n])


def rel(target, nxt):
    return struct.pack("<i", target - nxt)


def lea_rip(reg_mod, at, target):       # 48 8d <modrm> rel32: lea r64,[rip+target]
    return bytes([0x48, 0x8D, reg_mod]) + rel(target, at + 7)


def build():
    img = Image()
    # A at CODE: lea rdx,[X]; xor ebx,ebx; L: imul eax,ebx,0x208; mov ecx,[rdx+rax+0x200]; inc ebx; cmp ebx,0x2a; jl L; ret
    a = lea_rip(0x15, CODE, X) + bytes.fromhex("31db" "69c308020000" "8b8c0200020000" "ffc3" "83fb2a" "7cec" "c3")
    img.put(CODE, a)
    # B at CODE+0x100: lea rcx,[X]; mov r8d,0x5550; xor edx,edx; jmp CODE+0x300
    b = lea_rip(0x0D, CODE + 0x100, X) + bytes.fromhex("41b850550000" "31d2") + b"\xe9" + rel(CODE + 0x300, CODE + 0x100 + 7 + 6 + 2 + 5)
    img.put(CODE + 0x100, b)
    # C at CODE+0x200: mov eax,[rcx]; imul eax,eax,0x40; movsxd rax,eax; lea rdx,[X+0x4000-0x4000 + 0x40*0]... a second table Z
    z = DATA + 0x6000
    c = bytes.fromhex("8b01" "6bc040" "4863c0") + lea_rip(0x15, CODE + 0x200 + 8, z) + bytes.fromhex("8b4c0208" "c3")
    img.put(CODE + 0x200, c)
    # D at CODE+0x300: mov eax,[rip+Y]; ret  (the global right behind the 42 rows)
    d = bytes.fromhex("8b05") + rel(Y, CODE + 0x300 + 6) + b"\xc3"
    img.put(CODE + 0x300, d)
    funcs = [(CODE, CODE + 0x1E), (CODE + 0x100, CODE + 0x114), (CODE + 0x200, CODE + 0x214), (CODE + 0x300, CODE + 0x307)]
    ctx = st.Ctx(img, funcs, [(DATA, DATA + 0x8000)])
    return ctx


class Passes(unittest.TestCase):
    def setUp(self):
        self.ctx = build()
        self.fns = [st.analyze(self.ctx, b, e) for b, e in self.ctx.funcs]

    def test_the_loop_pass_reads_stride_and_bound(self):
        fn = self.fns[0]
        self.assertTrue(fn.loop)
        self.assertIn("42", {s[1] for s in fn.signals})
        strides = {u["stride"] for u in fn.uses if u["kind"] == "indexed"}
        self.assertEqual(strides, {0x208})

    def test_the_size_pass_finds_k_times_stride(self):
        fn = self.fns[1]
        self.assertEqual([(x, n) for x, n, _, _ in fn.sizes], [(X, 0x5550)])
        self.assertIn((42, 0x208), st.size_hypotheses(0x5550))

    def test_the_index_source_pass_sees_the_entity_number(self):
        fn = self.fns[2]
        origins = [u["origin"] for u in fn.uses if u["kind"] == "indexed"]
        self.assertTrue(origins and origins[0].startswith("entity number"), origins)
        self.assertEqual([u["stride"] for u in fn.uses if u["kind"] == "indexed"], [0x40])

    def test_full_run_merges_passes_and_measures_room(self):
        rows, stats = st.run(self.ctx, None, fns=self.fns, source="rip(0x140001003ull, 0x140003100, 1);")
        by = {r["base"]: r for r in rows}
        t = by["%X" % X]
        self.assertEqual(t["stride"], 0x208)
        self.assertEqual(t["passes"], [1, 2])
        self.assertEqual(t["room_rows"], 42)           # 42 rows, then 16 spare bytes, then the global Y
        self.assertEqual(t["next_symbol"], "%X" % Y)
        self.assertTrue(t["strong"])
        self.assertEqual(t["handled"], "partly")       # the lea in A is patched, the lea and the size in B are not
        z = by["%X" % (DATA + 0x6000)]
        self.assertEqual(z["passes"], [3])
        self.assertEqual(z["handled"], "no")

    def test_handled_sets_reads_sites_and_rva_values(self):
        lits = st.handled_sets("rip(0x1405EE50Full, 0x144EB2B70, x); rva(0x1405EEA03, 0x4EB2D74, y); int n = 0x2a;")
        self.assertEqual(lits, {0x1405EE50F, 0x144EB2B70, 0x1405EEA03, 0x144EB2D74})


LAB = os.environ.get("IW7_RE_LAB", os.path.join(os.path.expanduser("~"), "Documents", "IW7-RE-Lab"))
# the readers of the tables the capacity work found by crashes or by reading (docs: engine-capacity handover, section 1; a16)
QUEUE = [0x1405EE500, 0x1405EE530, 0x1405EE550, 0x1405EE590, 0x1405EE6E0, 0x1405EE880, 0x1405EE960, 0x1405EE9E0,
         0x1405EF0C3]                      # the last one belongs to the module behind the table (its first global is the end)
KNOWN = {                                   # base -> (stride, readers)
    0x144EB2B70: (0x208, QUEUE),
    0x145C51580: (0x8, [0x14048FD60, 0x1404912F0, 0x140AC6780, 0x140AC6820, 0x140AC6AA0]),          # character work table, 42 rows
    0x145C516D0: (0x14, [0x140AC6820, 0x140AC68B3, 0x140AC6AA0]),                                  # character work table, 5 x 42
    0x145C6F5A0: (0xA0, [0x140AF6310, 0x140AF6E50]),                                               # sentients, 71 rows
    0x143C34440: (0x4D0, [0x140004650, 0x1403EB8F0, 0x1403EBA90, 0x1403EBB20, 0x1403EE550, 0x1403EE600, 0x1403EE780, 0x1403F0230]),
    0x143C4BA00: (0x180, [0x1400046A0, 0x1403F1250, 0x1403F1330, 0x1403F2820, 0x1403F28A0, 0x1403F34F0]),
}


@unittest.skipUnless(os.path.exists(os.path.join(LAB, "engine", "iw7-insn-index.sqlite")) and
                     os.path.exists(os.path.join(LAB, "engine", "iw7-engine.sqlite")), "no analysed engine on this machine")
class KnownTables(unittest.TestCase):
    """Ground truth on the real image: the tool finds the tables that were found earlier by crashes."""

    @classmethod
    def setUpClass(cls):
        import argparse
        import engine as eng
        a = argparse.Namespace(db=eng.DEFAULT_DB, index=eng.DEFAULT_INDEX, image=eng.DEFAULT_IMAGE, snapshots=eng.DEFAULT_SNAPSHOTS)
        e, ctx = st.load_ctx(a)
        funcs = set()
        for _, readers in KNOWN.values():
            funcs |= set(readers)
        cls.rows, _ = st.run(ctx, None, funcs=funcs, source="")
        cls.by = {int(r["base"], 16): r for r in cls.rows}

    def test_entity_queue(self):
        t = self.by[0x144EB2B70]
        self.assertEqual(t["stride"], 0x208)
        self.assertTrue({1, 2, 3} <= set(t["passes"]), t["passes"])   # loop bound, memset 42 x 0x208, entity number read
        self.assertEqual(t["room_rows"], 42)                         # the next module's first global follows the 42 rows
        self.assertTrue(t["strong"])

    def test_at_least_five_known_tables_with_their_stride(self):
        found = [b for b, (stride, _) in KNOWN.items() if b in self.by and self.by[b]["stride"] == stride]
        self.assertGreaterEqual(len(found), 5, [hex(b) for b in KNOWN if b not in found])

    def test_handled_column_reads_the_capacity_source(self):
        lits = st.handled_sets("rip(0x1405EE50Full, 0x144EB2B70, x); add(0x1405EE53B, 0x5550, y);")
        t = st.Table(0x144EB2B70, 0x208, st.Cand(0x144EB2B70))
        t.sites = [(0x1405EE50C, "lea of the base"), (0x1405EE539, "size immediate 0x5550"), (0x1405EE600, "lea of the base")]
        hit, total, _, open_sites = st.judge_handled(t, lits, None)
        self.assertEqual((hit, total, [a for a, _ in open_sites]), (2, 3, [0x1405EE600]))


if __name__ == "__main__":
    unittest.main()
