"""Default is inert. Native execution is a child phase of the reviewed original-job runner."""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

from verify_archive import ROOT, verify


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def require_original_job_ticket(ticket_path):
    """Accidental-direct-run guard; the parent's retained job handle is the authority."""
    if os.name != "nt":
        raise RuntimeError("Windows original-job execution required")
    ticket = json.loads(Path(ticket_path).read_text(encoding="utf-8-sig"))
    if ticket["schema"] != "iw7.community-download-worker/1" or time.time() > ticket["expires_unix"]:
        raise ValueError("Missing/expired original-job ticket")
    if os.getppid() != ticket["launcher_pid"]:
        raise ValueError("Worker parent differs from the admitted launcher")
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.GetCurrentProcess.restype = ctypes.c_void_p
    kernel.IsProcessInJob.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_int)]
    kernel.IsProcessInJob.restype = ctypes.c_int
    member = ctypes.c_int()
    if not kernel.IsProcessInJob(kernel.GetCurrentProcess(), None, ctypes.byref(member)) or not member.value:
        raise RuntimeError("Worker is not in a native Job Object")
    # This alone cannot identify the exact job. Harness.ps1 owns the original
    # handle; a JSON ticket is not independent admission or membership evidence.
    return ticket["plan"]


def run_worker(ticket_path):
    plan = require_original_job_ticket(ticket_path)
    for relative, expected in plan["source_hashes"].items():
        if digest(ROOT / relative) != expected.lower():
            raise ValueError("Reviewed source changed: " + relative)
    for key in ("python", "compiler", "linker"):
        if digest(plan[key + "_path"]) != plan[key + "_sha256"].lower():
            raise ValueError("Planned tool changed: " + key)
    manifest, base, overlay = verify(Path(plan["native_source"]))
    output = Path(plan["output_root"]).resolve()
    work = output / "work"
    work.mkdir(exist_ok=False)
    tree = work / "reconstruction"
    target = tree / manifest["path"]
    target.parent.mkdir(parents=True)
    target.write_bytes(base)
    env = dict(os.environ, GIT_CEILING_DIRECTORIES=str(work))
    for extra in (["--check"], []):
        subprocess.run(["git", "-c", "core.autocrlf=false", "apply", "--no-index", *extra, str(ROOT / manifest["patch"])],
                       cwd=tree, env=env, check=True, timeout=20, capture_output=True)
    if target.read_bytes() != overlay:
        raise ValueError("git apply differs from reviewed overlay")
    include = work / "include"
    include.mkdir()
    (include / "native_stubs.hpp").write_bytes((ROOT / "tests/native_stubs.hpp").read_bytes())
    (include / "std_include.hpp").write_text('#include "native_stubs.hpp"\n', encoding="utf-8")
    for header in ("loader/component_loader.hpp", "download.hpp", "console/console.hpp", "scheduler.hpp", "party.hpp",
                   "game/ui_scripting/execution.hpp", "utils/hash.hpp", "utils/concurrency.hpp", "utils/http.hpp"):
        stub = include / header
        stub.parent.mkdir(parents=True, exist_ok=True)
        stub.write_text("#pragma once\n", encoding="utf-8")
    exe = work / "test_download.exe"
    command = [plan["compiler_path"], "/nologo", "/std:c++20", "/EHsc", "/W4", "/WX", "/Od", "/D_CRT_SECURE_NO_WARNINGS",
               "/I" + str(include), "/I" + str(target.parent), "/Fe:" + str(exe), "/Fo:" + str(work / "test_download.obj"),
               str(ROOT / "tests/test_download.cpp")]
    (work / "compile-command.json").write_text(json.dumps(command, indent=2) + "\n", encoding="utf-8")
    # All subprocesses inherit the original job. No shell, vcvars or second job.
    with (work / "compile.stdout.log").open("xb") as out, (work / "compile.stderr.log").open("xb") as err:
        compiled = subprocess.run(command, cwd=work, timeout=90, stdout=out, stderr=err)
    if compiled.returncode:
        raise RuntimeError("Harness compile failed; retained logs identify the failure")
    with (work / "tests.stdout.log").open("xb") as out, (work / "tests.stderr.log").open("xb") as err:
        tested = subprocess.run([str(exe)], cwd=work, timeout=30, stdout=out, stderr=err)
    text = (work / "tests.stdout.log").read_text(encoding="utf-8")
    expected = plan["expected_test_count"]
    if tested.returncode or text.count("PASS ") != expected or f"RESULT {expected} passed" not in text:
        raise RuntimeError("Harness result differs from the reviewed case count")
    for relative, expected_hash in plan["source_hashes"].items():
        if digest(ROOT / relative) != expected_hash.lower():
            raise ValueError("Source changed during the worker: " + relative)
    receipt = {"schema": "iw7.community-download-functional/1", "functional_passed": True,
               "test_count": expected, "overlay_sha256": manifest["overlay_sha256"],
               "executable_sha256": digest(exe), "raw_tests_log_sha256": digest(work / "tests.stdout.log"),
               "admitted_pipeline_passed": False, "original_job_closure": "Must be established by the retained parent owner",
               "full_native_build": False, "gameplay": False}
    (output / "functional-result.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native-source", type=Path, help="Historical argument; no longer starts a build")
    parser.add_argument("--original-job-ticket", type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.original_job_ticket:
        run_worker(args.original_job_ticket)
    else:
        print(json.dumps({"action": "Plan", "native_started": False, "ready_to_run": False,
                          "next": "Use Harness.ps1 -Action Plan, then review and admit its original-job Run separately"}))
