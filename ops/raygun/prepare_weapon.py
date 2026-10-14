"""Author private IW7 weapon/PAP JSON from complete existing source templates.

No serializer, binary reader, game launcher or engine hook. The pinned IW7
ZoneTool consumes the resulting weapons/, attachments/ and zone_source/ files.
"""
import argparse
import copy
import hashlib
import json
import math
from pathlib import Path
import re

ATTACHMENTS = tuple("attachments" + (str(i) if i > 1 else "") for i in range(1, 7))
PRIVATE_NAME = re.compile(r"sdk_[a-z0-9_]{1,55}\Z")
ASSET_NAME = re.compile(r"[A-Za-z0-9_./+\-]{1,160}\Z")
MAX_JSON_BYTES = 2 * 1024 * 1024


def require(condition, message):
    if not condition:
        raise ValueError(message)


def asset_name(value):
    require(isinstance(value, str) and ASSET_NAME.fullmatch(value) and
            ".." not in value.split("/") and not value.startswith("/") and
            value.lower() not in {"none", "unknown", "todo"}, "Explicit asset name required")
    return value


def positive(value, field):
    require(type(value) in (int, float) and math.isfinite(value) and value > 0,
            "Positive native weapon field required: " + field)


def rename_attachment_references(weapon, slot, old, new):
    # Paths confirmed by IW7 weapondef.cpp parse_complete/parse overrides.
    # Other strings, including unknown fields and ammunition names, are data.
    weapon[slot] = [new if item == old else item for item in weapon[slot]]
    paths = [(weapon, "notetrackOverrides", ("attachment",))]
    paths.extend((weapon["weapDef"], field, ("attachment1", "attachment2"))
                 for field in ("animOverrides", "sfxOverrides", "vfxOverrides"))
    for parent, field, keys in paths:
        entries = parent.get(field)
        if entries is None:
            continue
        require(isinstance(entries, list), "Native attachment override array required: " + field)
        for entry in entries:
            if entry is None:
                continue
            require(isinstance(entry, dict), "Native attachment override object required: " + field)
            for key in keys:
                if entry.get(key) == old:
                    entry[key] = new


def author(weapon, pap, name="sdk_raygun_zm", pap_name="sdk_raygun_pap_zm", refs=None):
    require(PRIVATE_NAME.fullmatch(name) and PRIVATE_NAME.fullmatch(pap_name) and name != pap_name,
            "Two distinct private sdk_ names required")
    require(isinstance(weapon, dict) and isinstance(pap, dict) and "baseAsset" not in weapon,
            "Complete IW7 JSON templates required; baseAsset inheritance is unsupported")
    # Preserve the entire full-template tree, including unrecognized fields.
    json.dumps([weapon, pap], allow_nan=False)
    source_name = asset_name(weapon.get("szInternalName"))
    source_pap = asset_name(pap.get("szInternalName"))
    require(not {name, pap_name} & {source_name, source_pap}, "Never overwrite a retail template identity")
    definition = weapon.get("weapDef")
    require(isinstance(definition, dict) and isinstance(definition.get("unk0"), dict),
            "Full WeaponCompleteDef with nested WeaponDef/unk0 required")
    require(type(definition.get("weapType")) is int and definition["weapType"] == 3 and
            type(definition.get("inventoryType")) is int and definition["inventoryType"] == 0 and
            type(definition.get("weapClass")) is int and definition["weapClass"] in (*range(10), 12, 13),
            "Player primary projectile template required")
    for field in ("gunXModel", "worldModel", "szXAnims"):
        asset_name(definition.get(field))
    require(type(weapon.get("iClipSize")) is int, "Native clip size must be an integer")
    positive(weapon["iClipSize"], "iClipSize")
    for field in ("iMaxAmmo", "iAmmoUsedPerShot", "damage", "iProjectileSpeed", "projLifetime"):
        positive(definition.get(field), field)
    require(pap.get("papAttachment") is True and type(pap.get("weaponType")) is int and
            pap["weaponType"] == 3, "Existing projectile PAP attachment required")
    slots = []
    for slot in ATTACHMENTS:
        values = weapon.get(slot)
        require(values is None or isinstance(values, list), "Invalid native attachment list: " + slot)
        if values:
            for value in values:
                if value is not None:
                    asset_name(value)
            slots.extend(slot for value in values if value == source_pap)
    require(len(slots) == 1, "PAP template must occur exactly once in the base weapon's own attachment lists")
    output_weapon = copy.deepcopy(weapon)
    rename_attachment_references(output_weapon, slots[0], source_pap, pap_name)
    output_pap = copy.deepcopy(pap)
    output_weapon["szInternalName"] = name
    output_weapon["szDisplayName"] = "Ray Gun (IW7 prototype)"
    output_pap["szInternalName"] = pap_name
    output_pap["szDisplayName"] = "Ray Gun upgrade (IW7 prototype)"
    target = output_weapon["weapDef"]
    if refs:
        require(set(refs) == {"view_model", "world_model", "animation_package"},
                "Supply the complete FP/TP/animation-package reference group")
        for value in refs.values():
            asset_name(value)
        require(not any(target.get(field) for field in
                ("gunXModelLeftHand", "gunXModelRightHand", "complexGunXModel",
                 "complexWorldModel", "szXAnimsRightHanded", "szXAnimsLeftHanded")),
                "Dual/complex visual templates need their own explicit asset mapping")
        for field in ("gunXModel", "defaultViewModel"):
            target[field] = refs["view_model"]
        for field in ("worldModel", "defaultWorldModel", "playerShadowModel"):
            target[field] = refs["world_model"]
        target["szXAnims"] = refs["animation_package"]
    report = {
        "schema": "iw7.raygun-authoring/1", "weapon": name, "pap_attachment": pap_name,
        "upgraded_engine_variant": name + "+" + pap_name,
        "source_weapon": source_name, "source_pap_attachment": source_pap,
        "pap_attachment_slot": slots[0], "engine_weapon_type": "projectile",
        "visuals": "explicit adapted references" if refs else "inherited IW7 template",
        "model_references": refs, "mechanics": "preserved from complete IW7 templates",
        "bo3_assets_authenticated": False, "ff_built": False, "weapon_granted": False,
        "projectile_damage_verified": False, "retail_pap_machine_registered": False,
        "retail_pap_transaction_verified": False, "gameplay_accepted": False,
    }
    return output_weapon, output_pap, report


def read_json(path, expected):
    require(re.fullmatch(r"[A-Fa-f0-9]{64}", expected), "Exact JSON input SHA-256 required")
    path = Path(path)
    require(path.is_file() and not path.is_symlink() and path.stat().st_size <= MAX_JSON_BYTES,
            "Bounded source JSON file required")
    with path.open("rb") as stream:
        raw = stream.read(MAX_JSON_BYTES + 1)
    require(len(raw) <= MAX_JSON_BYTES, "Source JSON exceeds byte cap before hash/decode")
    require(hashlib.sha256(raw).hexdigest() == expected.lower(), "Source template hash changed")
    return json.loads(raw.decode("utf-8-sig"))


def write_sources(output, weapon, pap, report):
    output = Path(output)
    require(PRIVATE_NAME.fullmatch(report["weapon"]) and PRIVATE_NAME.fullmatch(report["pap_attachment"]),
            "Private output asset identities required")
    require(output.is_absolute() and not output.exists(), "Fresh absolute source output required")
    require(not any(p.is_symlink() or p.is_junction() for p in (output, *output.parents)),
            "Linked output ancestry refused")
    sources = {
        "weapons/" + report["weapon"] + ".json": json.dumps(weapon, indent=2, allow_nan=False) + "\n",
        "attachments/" + report["pap_attachment"] + ".json": json.dumps(pap, indent=2, allow_nan=False) + "\n",
        "zone_source/sdk_raygun.csv": "weapon," + report["weapon"] + "\nattachment," + report["pap_attachment"] + "\n",
        "raygun-authoring.json": json.dumps(report, indent=2, allow_nan=False) + "\n",
    }
    output.mkdir(parents=True, exist_ok=False)
    for relative, text in sources.items():
        target = output / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("x", encoding="utf-8", newline="\n") as stream:
            stream.write(text)
    return tuple(sources)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--weapon-json", required=True)
    parser.add_argument("--weapon-sha256", required=True)
    parser.add_argument("--pap-json", required=True)
    parser.add_argument("--pap-sha256", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--name", default="sdk_raygun_zm")
    parser.add_argument("--pap-name", default="sdk_raygun_pap_zm")
    parser.add_argument("--view-model")
    parser.add_argument("--world-model")
    parser.add_argument("--animation-package")
    args = parser.parse_args()
    refs = {key: getattr(args, key) for key in ("view_model", "world_model", "animation_package")}
    weapon, pap, report = author(read_json(args.weapon_json, args.weapon_sha256),
                                read_json(args.pap_json, args.pap_sha256),
                                args.name, args.pap_name, refs if any(refs.values()) else None)
    report["input_json_sha256"] = {"weapon": args.weapon_sha256.lower(), "pap": args.pap_sha256.lower()}
    files = write_sources(args.output, weapon, pap, report)
    print(json.dumps({"output": str(args.output), "source_files": files, "ff_or_game_executed": False}))


if __name__ == "__main__":
    main()
