"""Compile one small offline harness using the installed MSVC; never build IW7."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

from verify_archive import ROOT, verify


def run(native_source):
    manifest, base, overlay = verify(native_source)
    scratch = ROOT / ".scratch"
    scratch.mkdir(exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="harness-", dir=scratch)).resolve()
    if not work.is_relative_to(scratch.resolve()):
        raise ValueError("unexpected harness directory")
    # Keep the bounded diagnostic output; no recursive source/clone cleanup.
    tree = work / "reconstruction"
    target = tree / manifest["path"]
    target.parent.mkdir(parents=True)
    target.write_bytes(base)
    env = dict(os.environ, GIT_CEILING_DIRECTORIES=str(work))
    for extra in (["--check"], []):
        subprocess.run(["git", "-c", "core.autocrlf=false", "apply", "--no-index", *extra, str(ROOT / manifest["patch"])],
                       cwd=tree, env=env, check=True, timeout=20, capture_output=True)
    if target.read_bytes() != overlay:
        raise ValueError("git apply did not reconstruct the exact overlay")
    include = work / "include"
    include.mkdir()
    (include / "native_stubs.hpp").write_bytes((ROOT / "tests/native_stubs.hpp").read_bytes())
    (include / "std_include.hpp").write_text('#include "native_stubs.hpp"\n', encoding="utf-8")
    for header in ("loader/component_loader.hpp", "download.hpp", "console/console.hpp", "scheduler.hpp", "party.hpp",
                   "game/ui_scripting/execution.hpp", "utils/hash.hpp", "utils/concurrency.hpp", "utils/http.hpp"):
        stub = include / header
        stub.parent.mkdir(parents=True, exist_ok=True)
        stub.write_text("#pragma once\n", encoding="utf-8")
    vswhere = Path(os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)")) / "Microsoft Visual Studio/Installer/vswhere.exe"
    vs = subprocess.check_output([str(vswhere), "-latest", "-products", "*", "-requires", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
                                  "-property", "installationPath"], timeout=15, text=True).strip()
    if not vs:
        raise RuntimeError("installed MSVC was not found; no tool will be downloaded")
    vcvars = Path(vs) / "VC/Auxiliary/Build/vcvars64.bat"
    exe = work / "test_download.exe"
    for path in (vcvars, work, ROOT):
        if any(ch in str(path) for ch in '\n\r"%'):
            raise ValueError("unsupported batch path characters")
    batch = work / "compile.cmd"
    batch.write_text(
        '@echo off\ncall "' + str(vcvars) + '" >nul\nif errorlevel 1 exit /b 1\n'
        'cl /nologo /std:c++20 /EHsc /W4 /WX /Od /D_CRT_SECURE_NO_WARNINGS '
        f'/I"{include}" /I"{target.parent}" /Fe:"{exe}" /Fo:"{work / "test_download.obj"}" '
        f'"{ROOT / "tests/test_download.cpp"}"\nexit /b %errorlevel%\n', encoding="utf-8")
    compile_run = subprocess.run([os.environ.get("COMSPEC", "cmd.exe"), "/d", "/c", str(batch)],
                                 cwd=work, timeout=90, capture_output=True, text=True)
    (work / "compile.log").write_text(compile_run.stdout + compile_run.stderr, encoding="utf-8")
    if compile_run.returncode:
        raise RuntimeError("harness compilation failed: " + compile_run.stdout + compile_run.stderr)
    result = subprocess.run([str(exe)], cwd=work, timeout=30, capture_output=True, text=True)
    (work / "tests.log").write_text(result.stdout + result.stderr, encoding="utf-8")
    print(result.stdout, end="")
    if result.returncode:
        raise RuntimeError("harness failed: " + result.stderr)
    receipt = {"schema": "iw7.community-download-tests/1", "upstream_commit": manifest["upstream_commit"],
               "overlay_sha256": manifest["overlay_sha256"], "patch_applied_exactly": True,
               "harness_sha256": hashlib.sha256((ROOT / "tests/test_download.cpp").read_bytes()).hexdigest(),
               "stubs_sha256": hashlib.sha256((ROOT / "tests/native_stubs.hpp").read_bytes()).hexdigest(),
               "test_count": result.stdout.count("PASS "), "passed": True,
               "tests_log_sha256": hashlib.sha256((result.stdout + result.stderr).encode()).hexdigest(),
               "real_windows_file_operations": True, "network": "mocked", "scheduler": "deterministic mock",
               "full_native_build": False, "gameplay": False}
    (work / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    print("Receipt:", work / "receipt.json")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native-source", required=True, type=Path)
    run(parser.parse_args().native_source)
