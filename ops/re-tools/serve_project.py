"""Inspect an existing Ghidra project through pinned upstream MCP read tools.

No importer, analyzer, semantic index or edit tool is registered. Run within
the shared Analysis reservation; the lifetime deadline is not a hard kill.
"""
import argparse
from contextlib import asynccontextmanager
from importlib.metadata import distribution
import json
from pathlib import Path
import threading
import time

PIN = "42d8f80551a765441b1a723f6f1ff45aa3914d5e"
READ_TOOLS = (
    "list_project_binaries", "list_project_binary_metadata",
    "decompile_function", "search_symbols_by_name", "list_xrefs",
    "read_bytes", "disassemble", "list_exports", "list_imports",
)


def verify_package():
    dist = distribution("pyghidra-mcp")
    provenance = json.loads(dist.read_text("direct_url.json") or "{}")
    if dist.version != "0.2.7" or provenance.get("vcs_info", {}).get("commit_id") != PIN:
        raise RuntimeError("Install the reviewed pyghidra-mcp commit before use")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, required=True)
    parser.add_argument("--ghidra", type=Path, required=True)
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--stop-file", type=Path, required=True)
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--max-seconds", type=int, default=300)
    args = parser.parse_args()
    if not 1 <= args.max_seconds <= 3600 or not 1024 <= args.port <= 65535:
        parser.error("Choose a lifetime of 1..3600 seconds and an unprivileged port")
    project = args.project.resolve(strict=True)
    if project.suffix != ".gpr" or not project.with_suffix(".rep").is_dir():
        parser.error("An existing local Ghidra .gpr/.rep project is required")
    if args.stop_file.exists():
        parser.error("Use a fresh stop-file path")
    verify_package()

    import pyghidra
    import uvicorn
    from mcp.server.mcpserver import MCPServer
    from pyghidra_mcp.context import PyGhidraContext
    from pyghidra_mcp import mcp_tools

    class InspectionContext(PyGhidraContext):
        def _init_indexing_state(self, *_args, **_kwargs):
            # No Chroma client, embedding model, executor or downloads.
            self.index_executor = None

        def schedule_indexing(self, *_args, **_kwargs):
            return False

        def schedule_startup_indexing(self, **_kwargs):
            return None

        def shutdown_indexing(self):
            return None

        def analyze_project(self, *_args, **_kwargs):
            raise RuntimeError("Analysis is a separate explicitly scoped operation")

    pyghidra.start(install_dir=args.ghidra.resolve(strict=True))
    context = InspectionContext(
        project.stem, project.parent, pyghidra_mcp_dir=args.state.resolve(),
        threaded=False, max_workers=1, no_symbols=True,
    )
    try:
        @asynccontextmanager
        async def lifespan(_server):
            yield context

        server = MCPServer("iw7-ghidra-inspect", lifespan=lifespan)
        for name in READ_TOOLS:
            server.tool()(getattr(mcp_tools, name))
        http = uvicorn.Server(uvicorn.Config(
            server.streamable_http_app(), host="127.0.0.1", port=args.port,
            log_level="warning", timeout_graceful_shutdown=30,
        ))
        finished = threading.Event()

        def stop_when_requested():
            deadline = time.monotonic() + args.max_seconds
            while not finished.wait(0.25):
                if args.stop_file.exists() or time.monotonic() >= deadline:
                    http.should_exit = True
                    return

        control = threading.Thread(target=stop_when_requested, daemon=True)
        control.start()
        try:
            http.run()
        finally:
            finished.set()
            control.join(timeout=2)
    finally:
        # Reading can populate in-memory analysis caches; do not save changes.
        context.close(save=False)


if __name__ == "__main__":
    main()
