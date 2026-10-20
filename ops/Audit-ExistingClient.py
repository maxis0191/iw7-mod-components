"""Read pinned upstream sources and optionally query getinfo; never start IW7.

This is a source/protocol audit, not an unmodified-client gameplay test.
No download, native payload execution, server command or state change is made.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import secrets
import socket
import subprocess

PINS = {
    "Aurora": "37abcb260408ce7cdef0dde831bbfcad594510e3",
    "CB": "d9c5dea1092b5ac493d2346043b26b2e2322d09c",
    "RetainedMergedBase": "a99c04937513530648573fd4ca2a05321a90b4a5",
}
FILES = ("party.cpp", "download.cpp", "ui_scripting.cpp", "fastfiles.cpp",
         "command.cpp", "io.cpp", "gsc/script_extension.cpp", "updater.cpp")


def read_blob(root, revision, path):
    return subprocess.run(["git", "-C", str(root), "show", revision + ":" + path],
                          check=True, capture_output=True).stdout


def table(source, name):
    match = re.search(r"std::vector<fastdl_file>\s+" + re.escape(name) +
                      r"\s*=\s*\{(.*?)\n\s*\};", source, re.S)
    if not match:
        return None
    return [dict(extension=e, key=k, optional=o == "true", localized=l == "true")
            for e, k, o, l in re.findall(
                r'\{"([^"]+)",\s*"([^"]+)",\s*(true|false)(?:,\s*(true|false))?\}',
                match[1])]


def source_audit(root, revision):
    sources, hashes = {}, {}
    for name in FILES:
        data = read_blob(root, revision, "src/client/component/" + name)
        sources[name] = data.decode("utf-8")
        hashes[name] = hashlib.sha256(data).hexdigest()
    party, ui = sources["party.cpp"], sources["ui_scripting.cpp"]
    mods, maps = table(party, "mod_files"), table(party, "usermap_files")
    if mods is None or [r["extension"] for r in mods] != [".ff", ".sabl", ".sabs"]:
        raise ValueError("Pinned mod-file contract changed; audit manually")
    return {
        "revision": revision, "blobs_sha256": hashes,
        "mod_files": mods, "usermap_files": maps,
        "embedded_lua_entrypoint": "load_zone_scripts" in ui,
        "lua_io_bindings": sorted(set(re.findall(r'lua\["io"\]\["([^"]+)"\]', ui))),
        "gsc_extensions": sorted(set(re.findall(r'function::add\("([^"]+)"', sources["gsc/script_extension.cpp"]))),
        "lua_named_native_bridge_registered": any(
            re.search(r'lua\["' + name + r'"\]\s*=', ui)
            for name in ("ffi", "memory", "native", "patch")),
        "capacity_contract_recognized": "paris_capacity" in party,
        "updater_origins": sorted(set(re.findall(r'https://[^"\s]+/', sources["updater.cpp"]))),
        "asset_loader_is_DB_LoadXAssets": "game::DB_LoadXAssets" in sources["fastfiles.cpp"],
        "note": "Named-binding and entrypoint inventory only; absence is not a proof about every retail builtin.",
    }


def parse_info(data, nonce):
    header = b"\xff\xff\xff\xffinfoResponse"
    if not any(data.startswith(header + separator) for separator in (b"\n", b" ")):
        raise ValueError("Unexpected getinfo response")
    start = data.find(b"\\")
    if start < 0:
        raise ValueError("Missing info string")
    parts = data[start + 1:].rstrip(b"\0\r\n").decode("ascii", "strict").split("\\")
    if len(parts) % 2:
        raise ValueError("Unpaired info-string fields")
    fields = {}
    for key, value in zip(parts[::2], parts[1::2]):
        if key in fields:
            raise ValueError("Duplicate info-string key")
        fields[key] = value
    if fields.get("challenge") != nonce or not fields.get("clients", "").isdigit():
        raise ValueError("Nonce or client count invalid")
    return fields


def query(port):
    # Loopback only: no public discovery, RCON or connection/authentication request.
    nonce = secrets.token_hex(16)
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
        udp.settimeout(3)
        udp.connect(("127.0.0.1", port))
        udp.send(b"\xff\xff\xff\xffgetinfo " + nonce.encode("ascii"))
        fields = parse_info(udp.recv(65535), nonce)
    keys = ("gamename", "protocol", "playmode", "mapname", "clients", "sv_maxclients",
            "fs_game", "mod_hash", "paris_capacity", "sv_wwwBaseUrl", "usermap_hash")
    return {"nonce_verified": True, "fields": {k: fields.get(k) for k in keys},
            "retail_map_must_be_installed": True,
            "mod_download_advertised": bool(fields.get("fs_game")),
            "native_profile_download_advertised": False,
            "evidence": "Live getinfo only; no game client or join was executed"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--upstream-root", type=Path, required=True)
    parser.add_argument("--port", type=int)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.port is not None and not 1 <= args.port <= 65535:
        parser.error("Invalid UDP port")
    report = {
        "schema": "iw7.existing-client-capacity-audit/1",
        "utc": datetime.now(timezone.utc).isoformat(),
        "sources": {name: source_audit(args.upstream_root, pin) for name, pin in PINS.items()},
        "wire_arithmetic": {"stock_reserved_players": 18, "ordinary": 48, "reserve": 16,
                            "characters": 82, "required_bits": (82 - 1).bit_length(),
                            "stock_explicit_agent_bits": 6,
                            "evidence": "Arithmetic against reviewed native capacity implementation, not an executed codec"},
        "engine_launched": False, "unchanged_client_gameplay_qualified": False,
        "capacity_header_sha256": hashlib.sha256(
            (Path(__file__).resolve().parents[1] / "src/native/paris_agent_capacity.hpp").read_bytes()).hexdigest(),
    }
    if args.port is not None:
        report["server"] = query(args.port)
    with args.output.open("x", encoding="utf-8", newline="\n") as output:
        json.dump(report, output, indent=2)
        output.write("\n")
    print(json.dumps({"output": str(args.output), "sources": len(report["sources"]),
                      "nonce_query": args.port is not None, "engine_launched": False}))


if __name__ == "__main__":
    main()
