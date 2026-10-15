"""Owned synthetic Source fixtures only; never captured, retail or runtime data."""
import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("iw7_neutral_clone", ROOT / "ops/raygun/prepare_iw7_clone.py")
clone = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(clone)


def pair(slot="attachments4"):
    weapon = {
        "szInternalName": clone.SOURCE_WEAPON, "szDisplayName": "Synthetic IW7 fixture",
        "iClipSize": 12, "unknown": {"same_pap_string": clone.SOURCE_PAP, "uint64": 2**64 - 1},
        "notetrackOverrides": [{"attachment": clone.SOURCE_PAP, "opaque": clone.SOURCE_PAP}],
        "weapDef": {"unk0": {"opaque": 17}, "weapType": 1, "inventoryType": 0,
                    "weapClass": 5, "damage": 200, "iMaxAmmo": 120, "iAmmoUsedPerShot": 1,
                    "iProjectileSpeed": 0, "projLifetime": 0.0, "gunXModel": "synthetic_view",
                    "worldModel": "synthetic_world", "szXAnims": "synthetic_animation_package",
                    "turretBarrelSpinUpSnd": [""] * 4, "turretBarrelSpinDownSnd": [""] * 4,
                    "ammoName": clone.SOURCE_PAP,
                    "animOverrides": [{"attachment1": clone.SOURCE_PAP, "attachment2": "scope_fixture"}],
                    "sfxOverrides": [{"attachment1": "scope_fixture", "attachment2": clone.SOURCE_PAP}],
                    "vfxOverrides": [{"attachment1": clone.SOURCE_PAP, "attachment2": clone.SOURCE_PAP}],
                    "unrecognized": {"attachment1": clone.SOURCE_PAP}}}
    for field in clone._base.ATTACHMENTS:
        weapon[field] = ["scope_fixture", None] if field == "attachments" else None
    weapon[slot] = [None, clone.SOURCE_PAP, "scope_fixture"]
    pap = {"szInternalName": clone.SOURCE_PAP, "szDisplayName": "Synthetic upgrade",
           "papAttachment": True, "weaponType": 0, "damageScale": 2.0,
           "unknown": {"same_pap_string": clone.SOURCE_PAP, "retain": [1, None, 3]}}
    return weapon, pap


def raw_json(data):
    return (json.dumps(data, allow_nan=False) + "\n").encode()


def manifest_for(weapon_raw, pap_raw):
    result = {
        "schema": "iw7.registered-player-definition-pair/1", "donor": "cp_zmb",
        "native_source_pin": clone.NATIVE_SOURCE,
        "weapon": clone.SOURCE_WEAPON, "pap_attachment": clone.SOURCE_PAP,
        "observed": {"base_type": 1, "pap_type": 0, "pap_flag_raw": 1, "pap_flag": True, "occurrences": 1},
        "readset": {"bytes": 1000, "elements": 40, "script_calls": 2, "copied_text_bytes": 70,
                    "json_estimate": 10000, "allocation_estimate": 40000,
                    "native_string_matrices": [], "flat_empty_string_arrays": 2},
        "files": [{"path": name, "bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest()}
                  for name, raw in (("weapons/iw7_shredder_zm.json", weapon_raw),
                                    ("attachments/shredderpap1.json", pap_raw))],
    }
    result.update({key: False for key in clone.MANIFEST_FALSE})
    result.update({key: True for key in clone.MANIFEST_TRUE})
    return result


class NeutralCloneTests(unittest.TestCase):
    def test_only_known_identity_rewrites_and_unknown_mechanics_preserved(self):
        weapon, pap = pair()
        before = copy.deepcopy((weapon, pap))
        result, upgrade, report = clone.clone_pair(weapon, pap)
        expected_weapon, expected_pap = copy.deepcopy((weapon, pap))
        expected_weapon["szInternalName"] = clone.PRIVATE_WEAPON
        expected_pap["szInternalName"] = clone.PRIVATE_PAP
        expected_weapon["attachments4"][1] = clone.PRIVATE_PAP
        expected_weapon["notetrackOverrides"][0]["attachment"] = clone.PRIVATE_PAP
        expected_weapon["weapDef"]["animOverrides"][0]["attachment1"] = clone.PRIVATE_PAP
        expected_weapon["weapDef"]["sfxOverrides"][0]["attachment2"] = clone.PRIVATE_PAP
        expected_weapon["weapDef"]["vfxOverrides"][0].update(attachment1=clone.PRIVATE_PAP, attachment2=clone.PRIVATE_PAP)
        self.assertEqual((result, upgrade), (expected_weapon, expected_pap))
        self.assertEqual((weapon, pap), before)
        self.assertEqual(result["unknown"]["uint64"], 18446744073709551615)
        self.assertEqual(report["observed_base_type"], 1)
        self.assertEqual(report["observed_pap_type"], 0)
        self.assertNotIn("engine_weapon_type", report)
        self.assertTrue(all(report[key] is False for key in clone.REPORT_FALSE))

    def test_exact_pap_association_in_each_of_six_original_slots(self):
        for slot in clone._base.ATTACHMENTS:
            with self.subTest(slot=slot):
                weapon, pap = pair(slot)
                result, _, report = clone.clone_pair(weapon, pap)
                self.assertEqual(report["pap_attachment_slot"], slot)
                self.assertEqual(result[slot], [None, clone.PRIVATE_PAP, "scope_fixture"])
                self.assertEqual({key: result[key] for key in clone._base.ATTACHMENTS if key != slot},
                                 {key: weapon[key] for key in clone._base.ATTACHMENTS if key != slot})

    def test_old_projectile_author_still_refuses_this_pair(self):
        weapon, pap = pair()
        with self.assertRaisesRegex(ValueError, "projectile template required"):
            clone._base.author(weapon, pap)
        clone.clone_pair(weapon, pap)  # The explicit neutral route does not change that author.

    def test_fixed_names_exact_integer_types_and_true_pap_required(self):
        for target, field, value in (("weapon", "szInternalName", "other_weapon"),
                                     ("pap", "szInternalName", "other_pap"),
                                     ("def", "weapType", True), ("def", "weapType", 1.0),
                                     ("def", "weapType", 3), ("pap", "weaponType", False),
                                     ("pap", "weaponType", "0"), ("pap", "weaponType", 3),
                                     ("pap", "papAttachment", 1)):
            with self.subTest(target=target, field=field, value=value):
                weapon, pap = pair()
                parent = weapon if target == "weapon" else pap if target == "pap" else weapon["weapDef"]
                parent[field] = value
                with self.assertRaises(ValueError):
                    clone.clone_pair(weapon, pap)

    def test_missing_duplicate_or_malformed_attachment_and_override_refuse(self):
        for action in ("missing", "missing_slot", "duplicate", "same_slot_duplicate", "bad_path", "bad_list", "bad_override", "too_many"):
            with self.subTest(action=action):
                weapon, pap = pair()
                if action == "missing": weapon["attachments4"] = None
                if action == "missing_slot": del weapon["attachments6"]
                if action == "duplicate": weapon["attachments6"] = [clone.SOURCE_PAP]
                if action == "same_slot_duplicate": weapon["attachments4"].append(clone.SOURCE_PAP)
                if action == "bad_path": weapon["attachments6"] = ["../escaped"]
                if action == "bad_list": weapon["attachments2"] = "scope_fixture"
                if action == "bad_override": weapon["weapDef"]["animOverrides"] = [False]
                if action == "too_many": weapon["attachments2"] = ["scope_fixture"] * 65
                with self.assertRaises(ValueError): clone.clone_pair(weapon, pap)

    def test_no_inheritance_diagnostic_nonfinite_or_matrix_repair(self):
        for action in ("inheritance", "diagnostic", "nan", "missing_nested", "matrix", "nonnull_flat"):
            with self.subTest(action=action):
                weapon, pap = pair()
                if action == "inheritance": pap["baseAsset"] = clone.SOURCE_PAP
                if action == "diagnostic": weapon["schema"] = "iw7.player-pair-profile/1"
                if action == "nan": weapon["weapDef"]["damage"] = float("nan")
                if action == "missing_nested": weapon["weapDef"]["unk0"] = None
                if action == "matrix": weapon["weapDef"]["turretBarrelSpinUpSnd"] = [["s"] * 4] * 4
                if action == "nonnull_flat": weapon["weapDef"]["turretBarrelSpinDownSnd"] = ["sound"] * 4
                with self.assertRaises(ValueError): clone.clone_pair(weapon, pap)

    def test_strict_json_duplicate_nonfinite_overflow_and_utf8(self):
        for raw in (b'{"a":1,"a":2}', b'{"a":{"b":1,"b":2}}', b'{"a":NaN}',
                    b'{"a":Infinity}', b'{"a":1e999}', b'{"a":"\xff"}'):
            with self.subTest(raw=raw):
                with self.assertRaises(ValueError): clone.decode_json(raw)
        self.assertEqual(clone.decode_json(b'\xef\xbb\xbf{"n":18446744073709551615}'), {"n": 2**64 - 1})

    def test_manifest_policy_refuses_before_either_body_is_opened(self):
        weapon, pap = pair()
        manifest = manifest_for(raw_json(weapon), raw_json(pap))
        for change in ({"ready": True}, {"runtime_abi_verified": True}, {"donor": "other"},
                       {"native_source_pin": "0" * 40}, {"observed": {**manifest["observed"], "base_type": True}},
                       {"readset": {**manifest["readset"], "bytes": 2**30}},
                       {"readset": {**manifest["readset"], "flat_empty_string_arrays": True}}):
            bad = {**manifest, **change}
            with self.subTest(change=change), mock.patch.object(clone, "read_pinned", return_value=raw_json(bad)) as read:
                with self.assertRaises(ValueError):
                    clone.prepare_sources("manifest", "a" * 64, "weapon", "pap", "output")
                self.assertEqual(read.call_count, 1)

    def test_manifest_full_binding_refusals(self):
        weapon, pap = pair()
        wr, pr = raw_json(weapon), raw_json(pap)
        manifest = manifest_for(wr, pr)
        clone.validate_manifest(manifest, wr, pr)
        for action in ("hash", "length", "upper_hash", "path", "duplicate", "coerced_length", "extra_file_key"):
            changed = copy.deepcopy(manifest)
            first = changed["files"][0]
            if action == "hash": first["sha256"] = "0" * 64
            if action == "length": first["bytes"] += 1
            if action == "upper_hash": first["sha256"] = first["sha256"].upper()
            if action == "path": first["path"] = "../escape.json"
            if action == "duplicate": changed["files"][1] = first.copy()
            if action == "coerced_length": first["bytes"] = float(first["bytes"])
            if action == "extra_file_key": first["extra"] = False
            with self.subTest(action=action), self.assertRaises(ValueError):
                clone.validate_manifest(changed, wr, pr)

    def test_bounded_input_hash_precedes_decode_and_growth_is_capped(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "owned.json"
            path.write_bytes(b"not JSON")
            with self.assertRaisesRegex(ValueError, "hash changed"):
                clone.read_pinned(path, "0" * 64, 64)
            class Growing(io.BytesIO):
                def read(self, count=-1):
                    self.requested = count
                    return b"x" * count
                def close(self): pass
            stream = Growing()
            with mock.patch.object(Path, "open", return_value=stream):
                with self.assertRaisesRegex(ValueError, "before hash/decode"):
                    clone.read_pinned(path, "0" * 64, 64)
            self.assertEqual(stream.requested, 65)
        with self.assertRaises(ValueError): clone.read_pinned("relative.json", "a" * 64, 64)

    def test_owned_triplet_produces_only_source_and_preserves_input_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            weapon, pap = pair()
            wr, pr = raw_json(weapon), raw_json(pap)
            mr = raw_json(manifest_for(wr, pr))
            paths = [root / name for name in ("manifest.json", "weapon.json", "pap.json")]
            for path, raw in zip(paths, (mr, wr, pr)): path.write_bytes(raw)
            output = root / "fresh-clone"
            report, files = clone.prepare_sources(paths[0], hashlib.sha256(mr).hexdigest(), paths[1], paths[2], output)
            self.assertEqual(len(files), 4)
            self.assertEqual(sorted(str(p.relative_to(output)).replace("\\", "/") for p in output.rglob("*") if p.is_file()), sorted(files))
            emitted = json.loads((output / ("weapons/" + clone.PRIVATE_WEAPON + ".json")).read_text())
            self.assertEqual(emitted["weapDef"]["weapType"], 1)
            self.assertEqual(emitted["weapDef"]["iProjectileSpeed"], 0)
            self.assertEqual((output / ("zone_source/" + clone.PRIVATE_WEAPON + ".csv")).read_text(),
                             "weapon," + clone.PRIVATE_WEAPON + "\nattachment," + clone.PRIVATE_PAP + "\n")
            self.assertTrue(all(report[key] is False for key in clone.REPORT_FALSE))
            self.assertEqual(json.loads((output / "neutral-clone.json").read_text()), report)
            for entry in report["files"]:
                raw = (output / entry["path"]).read_bytes()
                self.assertEqual((len(raw), hashlib.sha256(raw).hexdigest()),
                                 (entry["bytes"], entry["sha256"]))
            self.assertEqual([p.read_bytes() for p in paths], [mr, wr, pr])
            with self.assertRaisesRegex(ValueError, "Fresh absolute"):
                clone.prepare_sources(paths[0], hashlib.sha256(mr).hexdigest(), paths[1], paths[2], output)

    def test_invalid_hash_or_output_growth_creates_no_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            weapon, pap = pair()
            result, upgraded, report = clone.clone_pair(weapon, pap)
            result["large_unknown"] = "x" * clone.MAX_JSON_BYTES
            output = root / "not-created"
            with self.assertRaisesRegex(ValueError, "before output creation"):
                clone.write_sources(output, result, upgraded, report)
            self.assertFalse(output.exists())
            for name in ("stock", "sdk_../escape", "sdk_name,weapon"):
                with self.subTest(name=name), self.assertRaises(ValueError):
                    clone.clone_pair(weapon, pap, name=name)


if __name__ == "__main__":
    unittest.main()
