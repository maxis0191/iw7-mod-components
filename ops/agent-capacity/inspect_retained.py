"""Lecture bornée de références déjà capturées ; aucun processus ni décompilateur."""
import argparse
import hashlib
import json
import re
import struct
from pathlib import Path

INPUTS = {
    "text": ("unpacked-text.bin", "5f2953f04a8d5f2a53d1e5a5e076de8f29d5b5303ca652f2420fec8d2a6a9138"),
    "rdata": ("unpacked-rdata.bin", "28b66189c1f35442d3e32ea5077e785e7cb8fbf45ed420094dc6b2795afd04e5"),
    "pdata": ("unpacked-pdata.bin", "8ff97607018c0c531a9d6851282701074a50b141729060f9f23ae728c9fad41e"),
}
SLICES = (
    ("map_entity_index_predicate", 0x140073C90, 0x140073CA9),
    ("entity_type_6_or_14_predicate", 0x140073CC0, 0x140073CD1),
    ("entity_type_predicate_wrapper", 0x140449430, 0x14044944A),
)


def inspect(reference_root):
    blobs = {}
    for kind, (name, expected) in INPUTS.items():
        blob = (reference_root / name).read_bytes()
        if hashlib.sha256(blob).hexdigest() != expected:
            raise ValueError(f"Empreinte différente : {name}")
        blobs[kind] = blob
    records = list(struct.iter_unpack("<III", blobs["pdata"]))
    slices = []
    for name, start, end in SLICES:
        code = blobs["text"][start - 0x140001000:end - 0x140001000]
        owners = [{"start": hex(0x140000000 + a), "end": hex(0x140000000 + b),
                   "unwind_rva": hex(u)} for a, b, u in records
                  if a <= start - 0x140000000 < b]
        if owners and (len(owners) != 1 or int(owners[0]["start"], 16) != start
                       or int(owners[0]["end"], 16) != end):
            raise ValueError("Le wrapper ne correspond plus au propriétaire complet")
        slices.append({"name": name, "start": hex(start), "end": hex(end),
                       "bytes": len(code), "signature_sha256": hashlib.sha256(code).hexdigest(),
                       "pdata_owners": owners,
                       "ownership": "complete-unwind-owner" if owners else "leaf-both-return-paths-no-pdata"})
    pattern = re.compile(r"netfield|agentstate|characterindex|msg_(read|write)|deltaentity|"
                         r"snapshot.*(parse|read|write)|(parse|read|write).*snapshot", re.I)
    candidates = []
    total = 0
    for match in re.finditer(rb"[ -~]{5,}\x00", blobs["rdata"]):
        value = match.group()[:-1].decode("ascii")
        if not pattern.search(value) and value not in ("clientNum", "number", "eType", "agentIndex", "characterIndex"):
            continue
        total += 1
        if len(candidates) >= 32:
            continue
        address = 0x141435000 + match.start()
        needle = struct.pack("<Q", address)
        refs = []
        position = 0
        while len(refs) < 32:
            position = blobs["rdata"].find(needle, position)
            if position < 0:
                break
            refs.append(hex(0x141435000 + position))
            position += 1
        candidates.append({"address": hex(address), "name": value, "rdata_direct_pointer_sites": refs})
    return {"schema": "iw7.agent-capacity-light-reading/1", "input_hashes": {
        name: expected for name, expected in INPUTS.values()}, "slices": slices,
        "rdata_candidate_count": total, "rdata_candidates": candidates,
        "verified_wire_codec_roots": [], "wire_width_status": "unknown",
        "limits": "Names/direct pointers only; no text-wide scan, RVA/relative references or writable data captured."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    workspace = Path(__file__).resolve().parents[2]
    output = args.output.resolve()
    if not output.is_relative_to(workspace / "runtime" / "agent-capacity"):
        parser.error("Sortie requise sous runtime/agent-capacity du worktree")
    if output.exists():
        parser.error("La sortie existe déjà ; choisir un chemin neuf")
    report = inspect(args.reference_root)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"3 signatures vérifiées ; {report['rdata_candidate_count']} noms candidats ; aucune racine wire vérifiée")


if __name__ == "__main__":
    main()
