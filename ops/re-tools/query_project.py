"""Query a running shared inspection session without restarting Codex or Ghidra."""
import argparse
import asyncio
import json
from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client
from serve_project import READ_TOOLS


async def query(port, name, arguments):
    async with streamable_http_client(f"http://127.0.0.1:{port}/mcp") as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            result = await session.call_tool(name, arguments)
            print(result.model_dump_json())
            return 1 if result.is_error else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tool", choices=READ_TOOLS)
    parser.add_argument("--arguments", default="{}", help="JSON object, not shell commands")
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    if not 1024 <= args.port <= 65535:
        parser.error("Choose an unprivileged port")
    arguments = json.loads(args.arguments)
    if not isinstance(arguments, dict):
        parser.error("Arguments must be a JSON object")
    raise SystemExit(asyncio.run(query(args.port, args.tool, arguments)))


if __name__ == "__main__":
    main()
