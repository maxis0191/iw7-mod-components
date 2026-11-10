"""Unit tests for ops/engine-map/iw7_world_live.py on synthetic world dumps (no real map data)."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


def load_module(name, rel):
    spec = importlib.util.spec_from_file_location(name, ROOT / rel)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


world = load_module("iw7_world_live_under_test", "ops/engine-map/iw7_world_live.py")

PROPS = [
    ("crate_small", 0.0, 0.0, 0.0),
    ("crate_small", 10.0, 0.0, 0.0),
    ("lamp", 0.0, 30.0, 40.0),
    ("wall_long", 500.0, 500.0, 0.0),
    ("crate_small", -100.0, -100.0, -5.0),
    ("lamp", 1000.0, 0.0, 200.0),
]


def make_doc(props=PROPS, **change):
    doc = {
        "schema": "iw7.world-live/1", "map": "cp_test", "count": len(props), "fields": "synthetic",
        "props": [{"i": n, "model": m, "origin": [x, y, z], "axis": [1, 0, 0, 0, 1, 0, 0, 0, 1], "scale": 1.0, "cull": 100, "flags": 9, "vl_flags": 0}
                  for n, (m, x, y, z) in enumerate(props)],
    }
    doc.update(change)
    return doc


def run(*argv):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = world.main(list(argv))
    return code, out.getvalue(), err.getvalue()


class WorldLiveTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)
        self.file = self.write("good.json", make_doc())

    def write(self, name, doc):
        path = self.dir / name
        path.write_text(doc if isinstance(doc, str) else json.dumps(doc), encoding="utf-8")
        return str(path)

    def database(self, rows, columns="idx integer, model text, x real, y real, z real"):
        path = self.dir / "world.sqlite"
        if path.exists():
            path.unlink()
        con = sqlite3.connect(path)
        con.execute("CREATE TABLE smodels (%s)" % columns)
        con.executemany("INSERT INTO smodels VALUES (?,?,?,?,?)", rows)
        con.commit()
        con.close()
        return str(path)

    # near
    def test_near_orders_by_distance(self):
        code, out, _ = run("near", self.file, "0", "0", "0", "--top", "3")
        self.assertEqual(code, 0)
        lines = [l for l in out.splitlines() if "dist" in l]
        self.assertEqual([l.split()[0] for l in lines], ["0", "1", "2"])
        self.assertIn("dist 0.00", lines[0])
        self.assertIn("dist 10.00", lines[1])
        self.assertIn("dist 50.00", lines[2])

    def test_near_radius_filters_and_reports_the_rest(self):
        code, out, _ = run("near", self.file, "0", "0", "0", "--radius", "60", "--top", "1")
        self.assertEqual(code, 0)
        self.assertIn("3 within 60 of the point", out)
        self.assertIn("... 2 more", out)

    def test_near_accepts_negative_coordinates(self):
        code, out, _ = run("near", self.file, "-100", "-100", "-5", "--top", "1")
        self.assertEqual(code, 0)
        self.assertIn("     4  crate_small", out)

    # box
    def test_box_counts_models_and_accepts_either_corner_order(self):
        a = run("box", self.file, "-20", "-20", "-20", "20", "50", "50")
        b = run("box", self.file, "20", "50", "50", "-20", "-20", "-20")
        self.assertEqual(a, b)
        self.assertIn("3 of 6 props", a[1])
        self.assertIn("     2  crate_small", a[1])
        self.assertIn("     1  lamp", a[1])

    def test_box_edge_is_inside(self):
        _, out, _ = run("box", self.file, "0", "0", "0", "10", "0", "0")
        self.assertIn("2 of 6 props", out)

    def test_box_with_nothing_inside(self):
        _, out, _ = run("box", self.file, "5000", "5000", "5000", "6000", "6000", "6000")
        self.assertIn("0 of 6 props", out)

    # models
    def test_models_top(self):
        code, out, _ = run("models", self.file, "--top", "2")
        self.assertEqual(code, 0)
        self.assertIn("6 props, 3 distinct models", out)
        rows = [l.split() for l in out.splitlines()[1:]]
        self.assertEqual(rows, [["3", "crate_small"], ["2", "lamp"]])

    # refusals
    def test_wrong_schema_is_refused(self):
        bad = self.write("bad.json", make_doc(schema="iw7.hang/1"))
        for argv in (("models", bad), ("near", bad, "0", "0", "0"), ("box", bad, "0", "0", "0", "1", "1", "1")):
            code, _, err = run(*argv)
            self.assertEqual(code, 2, argv)
            self.assertIn("not a world dump", err)

    def test_truncated_file_is_refused(self):
        cut = self.write("cut.json", json.dumps(make_doc())[:120])
        code, _, err = run("models", cut)
        self.assertEqual(code, 2)
        self.assertIn("truncated", err)

    def test_count_must_match_props(self):
        bad = self.write("count.json", make_doc(count=7))
        code, _, err = run("models", bad)
        self.assertEqual(code, 2)
        self.assertIn("incomplete", err)

    def test_prop_without_origin_is_refused(self):
        doc = make_doc()
        del doc["props"][2]["origin"]
        code, _, err = run("models", self.write("noorigin.json", doc))
        self.assertEqual(code, 2)
        self.assertIn("prop 2", err)

    def test_missing_file_and_usage_errors(self):
        self.assertEqual(run("models", str(self.dir / "nothing.json"))[0], 2)
        self.assertEqual(run("near", self.file, "1", "2")[0], 2)
        self.assertEqual(run("models", self.file, "--top", "0")[0], 2)
        self.assertEqual(run("near", self.file, "0", "0", "0", "--radius", "-1")[0], 2)

    # compare
    def test_compare_matches(self):
        db = self.database([(n, m, x + 0.005, y, z) for n, (m, x, y, z) in enumerate(PROPS)])
        code, out, _ = run("compare", self.file, "--db", db)
        self.assertEqual(code, 0, out)
        self.assertIn("6 live props, 6 database rows, 0 model names differ, 0 positions", out)

    def test_compare_reports_name_position_and_count(self):
        rows = [(n, m, x, y, z) for n, (m, x, y, z) in enumerate(PROPS)]
        rows[1] = (1, "other", 10.0, 0.0, 0.0)
        rows[3] = (3, "wall_long", 500.5, 500.0, 0.0)
        rows.pop()
        code, out, _ = run("compare", self.file, "--db", self.database(rows))
        self.assertEqual(code, 1)
        self.assertIn("1 model names differ, 1 positions", out)
        self.assertIn("count: live 6, database 5", out)
        self.assertIn("index 5 is not in the database", out)

    def test_compare_column_names_are_found_and_missing_ones_refused(self):
        db = self.database([(n, m, x, y, z) for n, (m, x, y, z) in enumerate(PROPS)], "smodel_index integer, model_name text, x real, y real, z real")
        self.assertEqual(run("compare", self.file, "--db", db)[0], 0)
        db = self.database([], "a integer, b text, x real, y real, z real")
        code, _, err = run("compare", self.file, "--db", db)
        self.assertEqual(code, 2)
        self.assertIn("smodels has columns", err)

    def test_compare_without_table_or_database(self):
        path = self.dir / "empty.sqlite"
        sqlite3.connect(path).close()
        self.assertEqual(run("compare", self.file, "--db", str(path))[0], 2)
        self.assertEqual(run("compare", self.file, "--db", str(self.dir / "missing.sqlite"))[0], 2)


if __name__ == "__main__":
    unittest.main()
