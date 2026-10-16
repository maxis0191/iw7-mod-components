"""Pinned MCP model compatibility only: no HTTP, JVM, native input or engine."""
import asyncio
from contextlib import asynccontextmanager, redirect_stdout
import inspect
import io
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

from mcp import ClientSession
from mcp.types import CallToolResult, ListToolsResult, TextContent, Tool

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "ops" / "re-tools"))
import qualify_tools
import query_project
from serve_project import READ_TOOLS

constructor = inspect.signature(ClientSession)
call_signature = inspect.signature(ClientSession.call_tool)


@asynccontextmanager
async def transport(url):
    yield object(), object()  # Pinned SDK transport yields read/write only.


class Session:
    fail_name = None

    def __init__(self, *args):
        constructor.bind(*args)

    async def __aenter__(self):
        return self

    async def __aexit__(self, *args):
        return False

    async def initialize(self):
        pass

    async def list_tools(self):
        return ListToolsResult(tools=[Tool(name=name, input_schema={"type": "object"})
                                     for name in READ_TOOLS])

    async def call_tool(self, name, arguments):
        call_signature.bind(self, name, arguments)
        return CallToolResult(
            content=[TextContent(type="text", text="int clamp_sum() { return 1; }")],
            is_error=name == "import_binary" or name == self.fail_name,
        )


class Compatibility(unittest.TestCase):
    def test_qualifier_model_access_and_serialization(self):
        with patch("mcp.ClientSession", Session), patch(
                "mcp.client.streamable_http.streamable_http_client", transport):
            result = asyncio.run(qualify_tools.query(8765))
        self.assertEqual((result["clients"], result["queries"]), (2, 4))
        self.assertTrue(result["same_decompilation"] and result["import_refused"])

    def test_qualifier_rejects_error_results(self):
        for name in ("list_project_binaries", "decompile_function"):
            with patch("mcp.ClientSession", Session), patch.object(Session, "fail_name", name), patch(
                    "mcp.client.streamable_http.streamable_http_client", transport):
                with self.assertRaises(AssertionError):
                    asyncio.run(qualify_tools.query(8765))

    def test_cli_result_model_success_and_error(self):
        for name, expected in (("list_project_binaries", 0), ("import_binary", 1)):
            output = io.StringIO()
            with patch.object(query_project, "ClientSession", Session), patch.object(
                    query_project, "streamable_http_client", transport), redirect_stdout(output):
                code = asyncio.run(query_project.query(8765, name, {}))
            self.assertEqual(code, expected)
            decoded = CallToolResult.model_validate(json.loads(output.getvalue()))
            self.assertEqual(decoded.is_error, bool(expected))


if __name__ == "__main__":
    if sys.flags.optimize:
        raise RuntimeError("Compatibility checks require assertions enabled")
    unittest.main()
