"""Real Ghidra, BSim and HTTP MCP smoke test using only 48 authored x64 bytes.

Run under the canonical Analysis scheduler and its external owned-job host.
That host must confirm root exit and an empty job before releasing its lease.
No game inputs. This script alone cannot attest the outer lifecycle.
"""
import argparse
import asyncio
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import threading
import time


class BoundedLog:
    """Drain an original child's pipe, retain at most 1 MiB and fail on overflow."""
    LIMIT = 1024 * 1024

    def __init__(self, command, path):
        self.failure = None
        self.path = path
        self.child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def _read(self):
        try:
            with self.path.open("xb") as log, self.child.stdout as pipe:
                size = 0
                while chunk := pipe.read(8192):
                    remaining = max(0, self.LIMIT - size)
                    log.write(chunk[:remaining])
                    size += len(chunk)
                    if size > self.LIMIT:
                        self.failure = RuntimeError("Child log exceeded 1 MiB; qualification refused")
        except Exception as error:
            self.failure = error

    def check(self):
        if self.failure:
            raise self.failure

    def finish(self, timeout):
        try:
            self.child.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            self.child.kill()
            self.child.wait(timeout=5)
            raise RuntimeError("Original root required forced closure; outer job must verify descendants")
        self.reader.join(timeout=3)
        if self.reader.is_alive():
            raise RuntimeError("Log pipe still open; outer owner must close and verify its job")
        self.check()


def fixture(root, ghidra):
    import pyghidra
    pyghidra.start(install_dir=ghidra)
    from ghidra.app.decompiler import DecompInterface, DecompileOptions
    from ghidra.program.util import GhidraProgramUtilities
    from generic.lsh.vector import WeightedLSHCosineVectorFactory, VectorCompare
    from ghidra.features.bsim.query import GenSignatures
    from ghidra.xml import NonThreadedXmlPullParserImpl
    from ghidra.util.xml import SpecXmlUtils

    # clamp_sum(int a,int b); identical second implementation; a bit mixer.
    first = bytes.fromhex("89c801d085c0790231c0c3")
    third = bytes.fromhex("89c869c03bf3d945c1e80531d0c3")
    data = first.ljust(16, b"\xcc") * 2 + third.ljust(16, b"\xcc")
    binary = root / "authored.bin"
    binary.write_bytes(data)
    with pyghidra.open_program(binary, project_location=root, project_name="authored",
            language="x86:LE:64:default", compiler="windows", analyze=False,
            loader="ghidra.app.util.opinion.BinaryLoader", nested_project_location=False) as api:
        program = api.getCurrentProgram()
        tx = program.startTransaction("Define three authored fixture functions")
        try:
            functions = []
            for offset, name in [(0, "clamp_sum"), (16, "clamp_sum_copy"), (32, "mix_bits")]:
                address = api.toAddr(offset)
                api.disassemble(address)
                functions.append(api.createFunction(address, name))
            GhidraProgramUtilities.markProgramAnalyzed(program)
        finally:
            program.endTransaction(tx, True)
        factory = WeightedLSHCosineVectorFactory()
        language = program.getLanguageID()
        weights = GenSignatures.getWeightsFile(language, language).getInputStream()
        try:
            parser = NonThreadedXmlPullParserImpl(weights, "BSim weights", SpecXmlUtils.getXmlHandler(), False)
            factory.readWeights(parser)
        finally:
            weights.close()
        decompiler = DecompInterface()
        try:
            decompiler.setOptions(DecompileOptions())
            decompiler.setSignatureSettings(factory.getSettings())
            assert decompiler.openProgram(program)
            signatures = [decompiler.generateSignatures(f, False, 10, None) for f in functions]
            assert all(s is not None and len(s.features) for s in signatures)
            vectors = [factory.buildVector(s.features) for s in signatures]
            same = float(vectors[0].compare(vectors[1], VectorCompare()))
            different = float(vectors[0].compare(vectors[2], VectorCompare()))
            assert same > 0.999999 and different < same, (same, different)
        finally:
            decompiler.dispose()
    result = dict(bytes=len(data), sha256=hashlib.sha256(data).hexdigest(),
                  bsim_identical=same, bsim_different=different,
                  commercial_inputs=False, fixture_execution=False)
    (root / "fixture-result.json").write_text(json.dumps(result, indent=2))


async def query(port):
    from mcp import ClientSession
    from mcp.client.streamable_http import streamable_http_client
    from serve_project import READ_TOOLS
    timings, outputs = [], []
    for client in range(2):
        async with streamable_http_client(f"http://127.0.0.1:{port}/mcp") as (read, write):
            async with ClientSession(read, write) as session:
                await session.initialize()
                names = {t.name for t in (await session.list_tools()).tools}
                assert names == set(READ_TOOLS), names
                listing = await session.call_tool("list_project_binaries", {})
                assert not listing.is_error
                for _ in range(2):
                    start = time.perf_counter()
                    answer = await session.call_tool("decompile_function", {
                        "binary_name": "/authored.bin", "name_or_address": "clamp_sum",
                        "timeout_sec": 10,
                    })
                    timings.append(time.perf_counter() - start)
                    assert not answer.is_error, answer
                    text = json.dumps(answer.model_dump(mode="json"))
                    assert "return" in text and "clamp_sum" in text, text
                    outputs.append(text)
                forbidden = await session.call_tool("import_binary", {"path": "never-imported.exe"})
                assert forbidden.is_error
    assert len(set(outputs)) == 1
    return dict(clients=2, queries=4, query_seconds=timings,
                same_decompilation=True, inspection_tools=len(names), import_refused=True)


def main():
    if sys.flags.optimize:
        raise RuntimeError("Qualification requires Python assertions enabled; remove -O/PYTHONOPTIMIZE")
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--root", type=Path, required=True)
    p.add_argument("--ghidra", type=Path, required=True)
    p.add_argument("--fixture-child", action="store_true")
    args = p.parse_args()
    if args.fixture_child:
        fixture(args.root, args.ghidra)
        return
    if os.name != "nt":
        p.error("Qualification host requires the Windows owned-job lifecycle")
    args.root.mkdir(parents=True, exist_ok=False)
    started = time.monotonic()
    capture = BoundedLog([sys.executable, __file__, "--fixture-child", "--root", str(args.root),
                         "--ghidra", str(args.ghidra)], args.root / "fixture.log")
    try:
        deadline = time.monotonic() + 90
        while capture.child.poll() is None:
            capture.check()
            if time.monotonic() >= deadline:
                raise TimeoutError("Authored fixture exceeded 90 seconds")
            time.sleep(0.1)
    finally:
        capture.finish(timeout=1)
    if capture.child.returncode:
        raise RuntimeError(f"Authored fixture exited {capture.child.returncode}; see fixture.log")
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    stop_file = args.root / "stop"
    state = args.root / "mcp-state"
    capture = BoundedLog([sys.executable, str(Path(__file__).with_name("serve_project.py")),
            "--project", str(args.root / "authored.gpr"), "--ghidra", str(args.ghidra),
            "--state", str(state), "--stop-file", str(stop_file), "--port", str(port),
            "--max-seconds", "120"], args.root / "server.log")
    child = capture.child
    try:
        try:
            deadline = time.monotonic() + 75
            while True:
                capture.check()
                if child.poll() is not None:
                    raise RuntimeError(f"Inspection server exited {child.returncode}; see server.log")
                try:
                    with socket.create_connection(("127.0.0.1", port), timeout=0.25):
                        break
                except OSError:
                    if time.monotonic() >= deadline:
                        raise TimeoutError("Inspection server startup exceeded 75 seconds")
                    time.sleep(0.25)
            async def checked_query():
                task = asyncio.create_task(query(port))
                try:
                    while not task.done():
                        capture.check()
                        await asyncio.sleep(0.1)
                    return await task
                finally:
                    if not task.done():
                        task.cancel()
                        await asyncio.gather(task, return_exceptions=True)
            result = asyncio.run(asyncio.wait_for(checked_query(), timeout=45))
        finally:
            stop_file.touch()
            capture.finish(timeout=40)
        assert child.returncode == 0, child.returncode
    finally:
        capture.check()
    assert not (state / "chromadb").exists()
    result.update(fixture=json.loads((args.root / "fixture-result.json").read_text()),
                  server_exit=child.returncode, server_pid=child.pid,
                  outer_job_closure="Requires separate original-owner receipt after this process exits",
                  indexing_created=False, elapsed_seconds=time.monotonic()-started,
                  engine_qualification=False, speedup_vs_previous_adapter_measured=False)
    for path in args.root.rglob("*.log"):
        assert path.stat().st_size <= BoundedLog.LIMIT, path
    (args.root / "qualification.json").write_text(json.dumps(result, indent=2))
    print(json.dumps(result))


if __name__ == "__main__":
    main()
