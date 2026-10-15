"""Focused authoring tests using synthetic JSON, never retail/runtime evidence."""
import copy
import hashlib
import importlib.util
import json
import io
from pathlib import Path
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("raygun_authoring", ROOT / "ops/raygun/prepare_weapon.py")
authoring = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(authoring)


def templates():
    return ({"szInternalName": "synthetic_projectile", "szDisplayName": "Synthetic only",
             "iClipSize": 12, "attachments": ["scope_test"], "attachments2": None,
             "attachments3": [], "attachments4": ["synthetic_pap"], "attachments5": [], "attachments6": [],
             "hideTags": [None] * 32, "notetrackOverrides": [{"attachment": "synthetic_pap"}],
             "private_unknown": {"retain": [7, {"tag": "not_a_model"}]},
             "weapDef": {"unk0": {"native_unknown": 19}, "weapType": 3, "inventoryType": 0,
                         "weapClass": 5, "gunXModel": "synthetic_view", "worldModel": "synthetic_world",
                         "szXAnims": "synthetic_animation_package", "iMaxAmmo": 120,
                         "iAmmoUsedPerShot": 1, "damage": 100, "iProjectileSpeed": 900,
                         "projLifetime": 4.0, "projTrailEffect": {"type": 0, "name": "synthetic_trail"},
                         "sfxPackage": "synthetic_sfx", "defaultViewModel": "synthetic_view",
                         "reload_unrecognized": {"duration": 1250, "notify": "reload_done"}}},
            {"szInternalName": "synthetic_pap", "papAttachment": True, "weaponType": 3,
             "damageScale": 2.0, "projectile": {"projectileSpeed": 900},
             "unknown_native_attachment": {"preserve": [1, 2, 3]}})


class RayGunAuthoringTests(unittest.TestCase):
    def test_pair_profile_is_ineligible_even_with_forged_full_template_fields(self):
        weapon, pap = templates()
        for base, upgrade in (({"schema": "iw7.player-pair-profile/1"}, pap),
                              ({**weapon, "schema": "iw7.player-pair-profile/1"}, pap),
                              (weapon, {**pap, "schema": "iw7.player-pair-profile/1"})):
            with self.subTest(base=base.get("schema"), pap=upgrade.get("schema")):
                with self.assertRaisesRegex(ValueError, "classification diagnostics"):
                    authoring.author(base, upgrade)

    def test_real_source_artifacts_and_engine_attachment_variant(self):
        weapon, pap = templates()
        before = copy.deepcopy((weapon, pap))
        result, upgraded, report = authoring.author(weapon, pap)
        self.assertEqual(report["upgraded_engine_variant"], "sdk_raygun_zm+sdk_raygun_pap_zm")
        self.assertEqual(result["attachments4"], ["sdk_raygun_pap_zm"])
        self.assertEqual(result["notetrackOverrides"][0]["attachment"], "sdk_raygun_pap_zm")
        self.assertEqual(result["attachments"], ["scope_test"])
        self.assertEqual(result["private_unknown"], weapon["private_unknown"])
        self.assertEqual(result["weapDef"], weapon["weapDef"])
        self.assertEqual(upgraded["unknown_native_attachment"], pap["unknown_native_attachment"])
        self.assertEqual((weapon, pap), before)
        self.assertTrue(upgraded["papAttachment"])
        self.assertFalse(report["retail_pap_transaction_verified"])
        self.assertFalse(report["bo3_assets_authenticated"])
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "new-authoring"
            files = authoring.write_sources(output, result, upgraded, report)
            self.assertEqual(len(files), 4)
            self.assertEqual(json.loads((output / "weapons/sdk_raygun_zm.json").read_text()), result)
            self.assertEqual(json.loads((output / "attachments/sdk_raygun_pap_zm.json").read_text()), upgraded)
            self.assertEqual((output / "zone_source/sdk_raygun.csv").read_text(),
                             "weapon,sdk_raygun_zm\nattachment,sdk_raygun_pap_zm\n")
            with self.assertRaisesRegex(ValueError, "Fresh absolute"):
                authoring.write_sources(output, result, upgraded, report)

    def test_supplied_visuals_do_not_change_native_mechanics(self):
        weapon, pap = templates()
        refs = {"view_model": "private/converted_view", "world_model": "private/converted_world",
                "animation_package": "private_weapon_animation"}
        result, _, report = authoring.author(weapon, pap, refs=refs)
        for field in ("gunXModel", "defaultViewModel"):
            self.assertEqual(result["weapDef"][field], refs["view_model"])
        for field in ("worldModel", "defaultWorldModel", "playerShadowModel"):
            self.assertEqual(result["weapDef"][field], refs["world_model"])
        for field in ("damage", "iProjectileSpeed", "iMaxAmmo", "projLifetime", "reload_unrecognized"):
            self.assertEqual(result["weapDef"][field], weapon["weapDef"][field])
        self.assertFalse(report["bo3_assets_authenticated"])

    def test_non_player_non_projectile_and_empty_native_parameters_refuse(self):
        weapon, pap = templates()
        for field, value in (("weapType", 1), ("inventoryType", 6), ("weapClass", 10),
                             ("damage", 0), ("iProjectileSpeed", 0), ("projLifetime", -1),
                             ("iAmmoUsedPerShot", True), ("iMaxAmmo", None), ("gunXModel", "")):
            with self.subTest(field=field):
                changed = copy.deepcopy(weapon)
                changed["weapDef"][field] = value
                with self.assertRaises(ValueError):
                    authoring.author(changed, pap)
        for size in (0, True, 1.5):
            changed = copy.deepcopy(weapon)
            changed["iClipSize"] = size
            with self.assertRaises(ValueError):
                authoring.author(changed, pap)

    def test_pap_must_belong_to_the_template_in_an_unambiguous_slot(self):
        weapon, pap = templates()
        for change in ("not_pap", "wrong_type", "unlisted", "duplicate"):
            with self.subTest(change=change):
                base, upgrade = copy.deepcopy((weapon, pap))
                if change == "not_pap":
                    upgrade["papAttachment"] = False
                elif change == "wrong_type":
                    upgrade["weaponType"] = 1
                elif change == "unlisted":
                    base["attachments4"] = []
                else:
                    base["attachments6"] = ["synthetic_pap"]
                with self.assertRaises(ValueError):
                    authoring.author(base, upgrade)

    def test_full_template_no_inheritance_and_finite_source(self):
        weapon, pap = templates()
        for changed in ({"baseAsset": "stock"}, {**weapon, "baseAsset": "stock"},
                        {**weapon, "weapDef": None}, {**weapon, "extra": float("nan")}):
            with self.assertRaises(ValueError):
                authoring.author(changed, pap)

    def test_visual_group_and_complex_templates_refuse(self):
        weapon, pap = templates()
        with self.assertRaises(ValueError):
            authoring.author(weapon, pap, refs={"view_model": "test"})
        refs = {"view_model": "test", "world_model": "test_world", "animation_package": "test_anims"}
        changed = copy.deepcopy(weapon)
        changed["weapDef"]["complexGunXModel"] = ["third_model"]
        with self.assertRaises(ValueError):
            authoring.author(changed, pap, refs=refs)

    def test_asset_and_private_identity_escape_refuse(self):
        weapon, pap = templates()
        for name in ("retail_name", "sdk_../bad", "sdk_a,weapon", "sdk_same"):
            with self.assertRaises(ValueError):
                authoring.author(weapon, pap, name=name, pap_name=name)
        for name in ("../../secret", "unknown", "file,extra"):
            changed = copy.deepcopy(weapon)
            changed["weapDef"]["gunXModel"] = name
            with self.assertRaises(ValueError):
                authoring.author(changed, pap)

    def test_only_exact_hash_source_json_is_read(self):
        weapon, _ = templates()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "synthetic.json"
            raw = (json.dumps(weapon) + "\n").encode()
            path.write_bytes(raw)
            self.assertEqual(authoring.read_json(path, hashlib.sha256(raw).hexdigest()), weapon)
            with self.assertRaisesRegex(ValueError, "hash changed"):
                authoring.read_json(path, "0" * 64)

    def test_same_string_unknown_data_is_preserved_and_only_known_refs_rename(self):
        weapon, pap = templates()
        old = pap["szInternalName"]
        weapon["private_unknown"]["tag"] = old
        weapon["private_unknown"]["attachment"] = old
        weapon["weapDef"]["szAmmoName"] = old
        for field in ("animOverrides", "sfxOverrides", "vfxOverrides"):
            weapon["weapDef"][field] = [{"attachment1": old, "attachment2": old,
                                         "overrides": old, "unknown": old}]
        result, _, _ = authoring.author(weapon, pap)
        self.assertEqual(result["private_unknown"], weapon["private_unknown"])
        self.assertEqual(result["weapDef"]["szAmmoName"], old)
        for field in ("animOverrides", "sfxOverrides", "vfxOverrides"):
            row = result["weapDef"][field][0]
            self.assertEqual(row["attachment1"], "sdk_raygun_pap_zm")
            self.assertEqual(row["attachment2"], "sdk_raygun_pap_zm")
            self.assertEqual(row["overrides"], old)
            self.assertEqual(row["unknown"], old)

    def test_growth_after_stat_reads_cap_plus_one_and_never_hashes_or_decodes(self):
        class GrowthSpy(io.BytesIO):
            def __init__(self):
                super().__init__(b"x" * (authoring.MAX_JSON_BYTES + 100))
                self.read_sizes = []
                self.observed = 0

            def read(self, size=-1):
                self.read_sizes.append(size)
                data = super().read(size)
                self.observed += len(data)
                return data

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "grew-after-stat.json"
            path.write_text("{}", encoding="utf-8")  # Tiny actual stat result.
            spy = GrowthSpy()  # Source grows before its first data read.
            with mock.patch.object(Path, "open", return_value=spy), \
                 mock.patch.object(authoring.hashlib, "sha256", side_effect=AssertionError("hashed oversize")), \
                 mock.patch.object(authoring.json, "loads", side_effect=AssertionError("decoded oversize")):
                with self.assertRaisesRegex(ValueError, "before hash/decode"):
                    authoring.read_json(path, "0" * 64)
            self.assertEqual(spy.read_sizes, [authoring.MAX_JSON_BYTES + 1])
            self.assertEqual(spy.observed, authoring.MAX_JSON_BYTES + 1)


if __name__ == "__main__":
    unittest.main()
