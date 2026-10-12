"""Read local Git objects only; verify exact private patch reconstruction."""
import argparse
import difflib
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent


def verify(native_source):
    manifest = json.loads((ROOT / "manifest.json").read_text(encoding="utf-8"))
    path = manifest["path"]
    base = subprocess.check_output(
        ["git", "-C", str(native_source), "show", f'{manifest["upstream_commit"]}:{path}'], timeout=20
    )
    final = (ROOT / "overlay" / path).read_bytes()
    patch = (ROOT / manifest["patch"]).read_bytes()
    expected = "".join(difflib.unified_diff(
        base.decode("utf-8").splitlines(keepends=True), final.decode("utf-8").splitlines(keepends=True),
        fromfile="a/" + path, tofile="b/" + path, n=3,
    )).encode("utf-8")
    for label, content in (("base", base), ("overlay", final), ("patch", patch)):
        if hashlib.sha256(content).hexdigest() != manifest[label + "_sha256"]:
            raise ValueError(label + " hash mismatch")
    if expected != patch:
        raise ValueError("patch does not exactly describe the pinned base -> overlay transformation")
    license_bytes = subprocess.check_output(
        ["git", "-C", str(native_source), "show", manifest["upstream_commit"] + ":LICENSE"], timeout=20
    )
    if license_bytes != (ROOT / "LICENSE.upstream").read_bytes():
        raise ValueError("upstream license differs")
    return manifest, base, final


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native-source", type=Path, required=True)
    args = parser.parse_args()
    manifest, _, _ = verify(args.native_source)
    print(json.dumps({"verified": True, "upstream_commit": manifest["upstream_commit"], "overlay_sha256": manifest["overlay_sha256"]}))
