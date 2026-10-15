"""Explicit neutral IW7 Shredder clone profile; no projectile authoring or runtime.

Actual captured inputs require their separately reviewed/admitted caller. This
module's tests use owned synthetic JSON only. It acquires no resource lease and
does not parse/link a fastfile, run native code, register assets or change GSC.
"""
import argparse
import copy
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import re

_spec = importlib.util.spec_from_file_location(
    "iw7_clone_projectile_source", Path(__file__).with_name("prepare_weapon.py"))
_base = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_base)

PROFILE = "iw7-shredder-neutral-1-0"
SOURCE_WEAPON = "iw7_shredder_zm"
SOURCE_PAP = "shredderpap1"
PRIVATE_WEAPON = "sdk_shredder_clone_zm"
PRIVATE_PAP = "sdk_shredder_clone_pap_zm"
NATIVE_SOURCE = "fab935826c898806855376662a8a03317b3ad8f1"
MAX_JSON_BYTES = 2 * 1024 * 1024
MAX_MANIFEST_BYTES = 16 * 1024
MAX_REPORT_BYTES = 64 * 1024
SHA256 = re.compile(r"[0-9a-f]{64}\Z")
MANIFEST_FALSE = (
    "projectile_author_eligible", "dependency_bodies_captured", "runtime_abi_verified",
    "lifetime_verified", "roundtrip_verified", "weapon_granted", "projectile_damage_verified",
    "physics_qualified", "retail_pap_transaction_verified", "gameplay_accepted",
)
MANIFEST_TRUE = ("source_layout_only", "templates_exported", "full_definitions_observed")
MANIFEST_KEYS = {"schema", "donor", "native_source_pin", "weapon", "pap_attachment",
                 "observed", "readset", "files", *MANIFEST_FALSE, *MANIFEST_TRUE}
READSET_CAPS = {"bytes": 1024 * 1024, "elements": 8192, "script_calls": 2048,
                "copied_text_bytes": 1024 * 1024, "json_estimate": MAX_JSON_BYTES,
                "allocation_estimate": 16 * 1024 * 1024}
REPORT_FALSE = ("bo3_assets_authenticated", "external_name_driven_gameplay_verified",
                "native_parser_verified", "ff_built", "roundtrip_verified", "runtime_abi_verified",
                "lifetime_verified", "weapon_granted", "projectile_damage_verified", "physics_qualified",
                "retail_pap_transaction_verified", "gameplay_accepted", "ready")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def encode_json(data, cap):
    queue = [(data, 0)]
    nodes = 0
    while queue:
        value, depth = queue.pop()
        nodes += 1
        require(nodes <= 32768 and depth <= 64, "Neutral JSON tree node/depth bound exceeded")
        if isinstance(value, dict):
            require(all(type(key) is str for key in value), "JSON object keys must be strings")
            queue.extend((child, depth + 1) for child in value.values())
        elif isinstance(value, list):
            require(len(value) <= 8192, "Neutral JSON array bound exceeded")
            queue.extend((child, depth + 1) for child in value)
        else:
            require(value is None or type(value) in (str, bool, int, float), "Native JSON value required")
            require(type(value) is not float or math.isfinite(value), "Finite bounded JSON tree required")
    try:
        raw = (json.dumps(data, ensure_ascii=False, indent=2, allow_nan=False) + "\n").encode("utf-8")
    except (TypeError, ValueError, RecursionError) as error:
        raise ValueError("Finite bounded JSON tree required") from error
    require(len(raw) <= cap, "Serialized source exceeds byte cap before output creation")
    return raw


def decode_json(raw):
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, "Duplicate JSON key: " + key)
            result[key] = value
        return result

    def invalid_constant(value):
        raise ValueError("Nonfinite JSON constant: " + value)

    try:
        result = json.loads(raw.decode("utf-8-sig"), object_pairs_hook=pairs,
                            parse_constant=invalid_constant)
        # Also refuses overflowing finite-looking literals such as 1e999.
        encode_json(result, MAX_JSON_BYTES)
        return result
    except (UnicodeError, RecursionError) as error:
        raise ValueError("Bounded UTF-8 JSON required") from error


def unlinked_path(path):
    path = Path(path)
    require(path.is_absolute(), "Absolute source path required")
    require(not any(p.is_symlink() or p.is_junction() for p in (path, *path.parents)),
            "Redirected source ancestry refused")
    return path


def read_pinned(path, expected_sha256, cap):
    require(isinstance(expected_sha256, str) and SHA256.fullmatch(expected_sha256),
            "Canonical exact SHA-256 required")
    path = unlinked_path(path)
    require(path.is_file(), "Ordinary source JSON file required")
    with path.open("rb") as stream:
        raw = stream.read(cap + 1)
    require(len(raw) <= cap, "Source input exceeds byte cap before hash/decode")
    require(hashlib.sha256(raw).hexdigest() == expected_sha256, "Source input hash changed")
    return raw


def validate_manifest(manifest, weapon_raw=None, pap_raw=None):
    require(isinstance(manifest, dict) and set(manifest) == MANIFEST_KEYS,
            "Closed neutral definition manifest required")
    require(manifest["schema"] == "iw7.registered-player-definition-pair/1" and
            manifest["donor"] == "cp_zmb" and manifest["native_source_pin"] == NATIVE_SOURCE and
            manifest["weapon"] == SOURCE_WEAPON and manifest["pap_attachment"] == SOURCE_PAP,
            "Fixed neutral Shredder Source profile required")
    require(all(manifest[key] is False for key in MANIFEST_FALSE) and
            all(manifest[key] is True for key in MANIFEST_TRUE),
            "Neutral observation flags cannot promote runtime eligibility")
    observed = manifest["observed"]
    require(isinstance(observed, dict) and set(observed) ==
            {"base_type", "pap_type", "pap_flag_raw", "pap_flag", "occurrences"},
            "Closed observed pair required")
    require(all(type(observed[key]) is int and observed[key] == value for key, value in
                (("base_type", 1), ("pap_type", 0), ("pap_flag_raw", 1), ("occurrences", 1))) and
            observed["pap_flag"] is True, "Uncoerced neutral integer1/0 and true PAP flag required")
    readset = manifest["readset"]
    require(isinstance(readset, dict) and set(readset) ==
            {*READSET_CAPS, "native_string_matrices", "flat_empty_string_arrays"},
            "Closed bounded readset required")
    require(all(type(readset[key]) is int and 0 <= readset[key] <= cap
                for key, cap in READSET_CAPS.items()), "Readset counter outside Source policy")
    require(all(readset[key] > 0 for key in ("bytes", "elements", "json_estimate", "allocation_estimate")) and
            readset["copied_text_bytes"] <= readset["bytes"], "Readset counters contradict the capture")
    require(type(readset["flat_empty_string_arrays"]) is int and
            readset["flat_empty_string_arrays"] == 2 and readset["native_string_matrices"] == [],
            "This clone profile requires the captured flat turret-array shape")
    files = manifest["files"]
    require(isinstance(files, list) and len(files) == 2, "Exactly two bound definition files required")
    expected = {"weapons/iw7_shredder_zm.json": weapon_raw,
                "attachments/shredderpap1.json": pap_raw}
    seen = set()
    for entry in files:
        require(isinstance(entry, dict) and set(entry) == {"path", "bytes", "sha256"},
                "Closed definition file binding required")
        path = entry["path"]
        require(isinstance(path, str) and path in expected and path not in seen,
                "Exact unique definition paths required")
        seen.add(path)
        require(type(entry["bytes"]) is int and 0 < entry["bytes"] <= MAX_JSON_BYTES and
                isinstance(entry["sha256"], str) and SHA256.fullmatch(entry["sha256"]),
                "Bounded definition file pin required")
        raw = expected[path]
        if raw is not None:
            require(entry["bytes"] == len(raw) and entry["sha256"] == hashlib.sha256(raw).hexdigest(),
                    "Definition size/hash binding differs")
    return {entry["path"]: entry for entry in files}


def clone_pair(weapon, pap, name=PRIVATE_WEAPON, pap_name=PRIVATE_PAP):
    require(isinstance(name, str) and isinstance(pap_name, str) and
            _base.PRIVATE_NAME.fullmatch(name) and _base.PRIVATE_NAME.fullmatch(pap_name) and
            name != pap_name, "Two distinct private sdk_ names required")
    require(isinstance(weapon, dict) and isinstance(pap, dict) and
            "baseAsset" not in weapon and "baseAsset" not in pap,
            "Complete definition trees required; no baseAsset inheritance")
    require(weapon.get("schema") != "iw7.player-pair-profile/1" and
            pap.get("schema") != "iw7.player-pair-profile/1",
            "Classification diagnostics are not clone definitions")
    encode_json(weapon, MAX_JSON_BYTES); encode_json(pap, MAX_JSON_BYTES)
    require(weapon.get("szInternalName") == SOURCE_WEAPON and pap.get("szInternalName") == SOURCE_PAP,
            "Only the fixed neutral Shredder pair is supported")
    definition = weapon.get("weapDef")
    require(isinstance(definition, dict) and isinstance(definition.get("unk0"), dict),
            "Full nested WeaponDef/unk0 required")
    require(type(definition.get("weapType")) is int and definition["weapType"] == 1 and
            type(pap.get("weaponType")) is int and pap["weaponType"] == 0 and
            pap.get("papAttachment") is True, "Neutral Shredder profile requires unchanged integer1/0")
    require(all(definition.get(key) == ["", "", "", ""] for key in
                ("turretBarrelSpinUpSnd", "turretBarrelSpinDownSnd")),
            "Captured flat empty turret arrays required; no matrix repair")
    slots = []
    for slot in _base.ATTACHMENTS:
        require(slot in weapon, "All six original attachment slots must be supplied")
        values = weapon.get(slot)
        require(values is None or isinstance(values, list), "Invalid native attachment list: " + slot)
        if values is not None:
            require(len(values) <= 64, "Native attachment list exceeds Source bound")
            for value in values:
                if value is not None:
                    _base.asset_name(value)
            slots.extend(slot for value in values if value == SOURCE_PAP)
    require(len(slots) == 1, "PAP must occur exactly once in the original six attachment slots")
    out_weapon, out_pap = copy.deepcopy(weapon), copy.deepcopy(pap)
    _base.rename_attachment_references(out_weapon, slots[0], SOURCE_PAP, pap_name)
    out_weapon["szInternalName"] = name
    out_pap["szInternalName"] = pap_name
    # No display name, enum, mechanics, model/animation or unknown value is changed.
    report = {
        "schema": "iw7.neutral-weapon-clone/1", "profile": PROFILE,
        "weapon": name, "pap_attachment": pap_name, "source_weapon": SOURCE_WEAPON,
        "source_pap_attachment": SOURCE_PAP, "pap_attachment_slot": slots[0],
        "upgraded_engine_variant": name + "+" + pap_name,
        "observed_base_type": 1, "observed_pap_type": 0,
        "source_enum_map": {"base": "WEAPTYPE_BULLET", "pap": "WEAPTYPE_NONE"},
        "source_layout_pin": NATIVE_SOURCE,
        "json_mechanics_fields_preserved": True,
        "external_name_driven_gameplay": "unverified: private names do not inherit Shredder GSC callbacks",
        "visuals": "unchanged IW7 references; dependency bodies not captured",
    }
    report.update({flag: False for flag in REPORT_FALSE})
    return out_weapon, out_pap, report


def write_sources(output, weapon, pap, report):
    require(report.get("schema") == "iw7.neutral-weapon-clone/1" and report.get("profile") == PROFILE and
            all(report.get(flag) is False for flag in REPORT_FALSE), "Honest neutral clone report required")
    name, pap_name = report["weapon"], report["pap_attachment"]
    require(isinstance(name, str) and isinstance(pap_name, str) and
            _base.PRIVATE_NAME.fullmatch(name) and _base.PRIVATE_NAME.fullmatch(pap_name) and
            name != pap_name and weapon.get("szInternalName") == name and pap.get("szInternalName") == pap_name,
            "Private clone identities differ")
    sources = {
        "weapons/" + name + ".json": encode_json(weapon, MAX_JSON_BYTES),
        "attachments/" + pap_name + ".json": encode_json(pap, MAX_JSON_BYTES),
        "zone_source/" + name + ".csv": ("weapon," + name + "\nattachment," + pap_name + "\n").encode(),
    }
    published_report = copy.deepcopy(report)
    published_report["files"] = [{"path": path, "bytes": len(raw),
                                  "sha256": hashlib.sha256(raw).hexdigest()}
                                 for path, raw in sources.items()]
    sources["neutral-clone.json"] = encode_json(published_report, MAX_REPORT_BYTES)
    output = unlinked_path(output)
    require(not output.exists(), "Fresh absolute source output required")
    output.mkdir(parents=True, exist_ok=False)
    for relative, raw in sources.items():
        target = output / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("x+b") as stream:
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())
            stream.seek(0)
            require(stream.read(len(raw) + 1) == raw, "Same-stream Source output readback differs")
    return published_report, tuple(sources)


def prepare_sources(manifest_path, manifest_sha256, weapon_path, pap_path, output):
    manifest_raw = read_pinned(manifest_path, manifest_sha256, MAX_MANIFEST_BYTES)
    manifest = decode_json(manifest_raw)
    pins = validate_manifest(manifest)  # All policy checks precede either body open.
    expected_paths = ("weapons/iw7_shredder_zm.json", "attachments/shredderpap1.json")
    weapon_raw = read_pinned(weapon_path, pins[expected_paths[0]]["sha256"], MAX_JSON_BYTES)
    pap_raw = read_pinned(pap_path, pins[expected_paths[1]]["sha256"], MAX_JSON_BYTES)
    validate_manifest(manifest, weapon_raw, pap_raw)
    weapon, pap, report = clone_pair(decode_json(weapon_raw), decode_json(pap_raw))
    report["input_sha256"] = {"manifest": manifest_sha256,
                              "weapon": hashlib.sha256(weapon_raw).hexdigest(),
                              "pap": hashlib.sha256(pap_raw).hexdigest()}
    return write_sources(output, weapon, pap, report)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--manifest-sha256", required=True)
    parser.add_argument("--weapon-json", type=Path, required=True)
    parser.add_argument("--pap-json", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    _, files = prepare_sources(args.manifest, args.manifest_sha256, args.weapon_json,
                               args.pap_json, args.output)
    print(json.dumps({"output": str(args.output), "source_files": files,
                      "native_or_game_executed": False, "ready": False}))


if __name__ == "__main__":
    main()
