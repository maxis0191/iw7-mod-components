"""MCP server (stdio) over the engine database: agents call find/decomp/xrefs/... as tools, no Ghidra running.

Standard library only (JSON-RPC 2.0 over stdin/stdout, MCP protocol 2025-06-18). Each tool runs
`engine.py --json <command> ...` with the same Python and returns its output. Registration (user scope, done by
ops/engine/Install-EngineTools.ps1):

    claude mcp add --scope user iw7-engine -- python -I <install>/engine_mcp.py
"""
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ENGINE = os.path.join(HERE, "engine.py")
PROTOCOL = "2025-06-18"

S = {"type": "string"}
I = {"type": "integer"}
B = {"type": "boolean"}
TOOLS = {
    "find": ("Find functions, labels, strings and our notes whose name or text contains TEXT.", {"text": S, "max": I}, ["text"]),
    "at": ("What is at an address (function and offset, label, string, how many callers/readers, notes).", {"addr": S}, ["addr"]),
    "decomp": ("Decompiled C of the function containing ADDR or named FUNC (Ghidra, exported once).", {"func": S}, ["func"]),
    "disasm": ("Disassembly of a function (or from an address with here=true) with names of targets and strings.",
               {"func": S, "max": I, "here": B}, ["func"]),
    "callers": ("Functions that call FUNC (depth follows the chain).", {"func": S, "depth": I, "max": I}, ["func"]),
    "callees": ("Functions FUNC calls.", {"func": S, "depth": I, "max": I}, ["func"]),
    "xrefs": ("Code that reads, writes or points at an address; range covers ADDR..ADDR+range-1 (a table or a structure).",
              {"addr": S, "kind": {"type": "string", "enum": ["read", "write", "data"]}, "range": I, "max": I}, ["addr"]),
    "grep": ("Regular expression over every decompiled function; one line per hit. inside limits to one function.",
             {"regex": S, "inside": S, "max": I, "case": B}, ["regex"]),
    "imm": ("Instructions that use VALUE as an immediate (or, with disp=true, as a [reg+VALUE] displacement: a structure field).",
            {"value": S, "disp": B, "inside": S, "mnemonic": S, "max": I}, ["value"]),
    "struct": ("Layout of a structure (Ghidra types, the client fork's structs, our knowledge). % is a wildcard.", {"name": S}, ["name"]),
    "mem": ("Value at an address in a memory snapshot of a running game; [X]+0x10 dereferences.",
            {"addr": S, "type": S, "count": I, "snapshot": S}, ["addr"]),
    "name": ("Name a function or a global in the shared knowledge file (committed; Ghidra applies it at the next analysis).",
             {"addr": S, "name": S, "note": S, "evidence": S, "kind": S, "replace": B}, ["addr", "name", "evidence"]),
    "note": ("Write a finding at an address into the shared knowledge (tag limit for a capacity limit; give value and evidence).",
             {"addr": S, "text": S, "tag": S, "value": S, "evidence": S}, ["addr", "text", "evidence"]),
    "notes": ("List knowledge notes and names (tag, like filter).", {"tag": S, "like": S}, []),
    "status": ("What the database holds and how fresh it is.", {}, []),
}
POSITIONAL = {"find": ["text"], "at": ["addr"], "decomp": ["func"], "disasm": ["func"], "callers": ["func"],
              "callees": ["func"], "xrefs": ["addr"], "grep": ["regex"], "imm": ["value"], "struct": ["name"],
              "mem": ["addr"], "name": ["addr", "name"], "note": ["addr", "text"], "notes": [], "status": []}
FLAGS = {"inside": "--in"}


def run_tool(name, args):
    argv = [sys.executable, "-B", ENGINE, "--json", name]
    for p in POSITIONAL[name]:
        argv.append(str(args[p]))
    for k, v in args.items():
        if k in POSITIONAL[name] or v is None:
            continue
        flag = FLAGS.get(k, "--" + k.replace("_", "-"))
        if isinstance(v, bool):
            if v:
                argv.append(flag)
        else:
            argv += [flag, str(v)]
    env = dict(os.environ, IW7_AGENT=os.environ.get("IW7_AGENT", "mcp-agent"))
    r = subprocess.run(argv, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=300, env=env)
    text = r.stdout if r.returncode == 0 else (r.stdout + r.stderr)
    if len(text) > 200000:
        text = text[:200000] + "\n... cut at 200000 characters: narrow the query (max, inside, kind)"
    return text, r.returncode != 0


def handle(msg):
    method = msg.get("method")
    mid = msg.get("id")
    if method == "initialize":
        return {"jsonrpc": "2.0", "id": mid, "result": {
            "protocolVersion": msg.get("params", {}).get("protocolVersion", PROTOCOL),
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": "iw7-engine", "version": "1"},
            "instructions": "IW7 engine database: decompiled code, calls, references, structures, memory snapshots and "
                            "the team's knowledge. Start with find or at; record findings with note/name and evidence."}}
    if method == "tools/list":
        tools = [{"name": n, "description": d, "inputSchema": {"type": "object", "properties": props, "required": req}}
                 for n, (d, props, req) in TOOLS.items()]
        return {"jsonrpc": "2.0", "id": mid, "result": {"tools": tools}}
    if method == "tools/call":
        p = msg.get("params", {})
        name = p.get("name")
        if name not in TOOLS:
            return {"jsonrpc": "2.0", "id": mid, "error": {"code": -32602, "message": f"unknown tool {name}"}}
        try:
            text, err = run_tool(name, p.get("arguments") or {})
        except Exception as ex:  # a tool failure is a result, not a protocol error
            text, err = f"{type(ex).__name__}: {ex}", True
        return {"jsonrpc": "2.0", "id": mid, "result": {"content": [{"type": "text", "text": text}], "isError": err}}
    if method == "ping":
        return {"jsonrpc": "2.0", "id": mid, "result": {}}
    if mid is None:
        return None  # notification
    return {"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": f"method not found: {method}"}}


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue
        reply = handle(msg)
        if reply is not None:
            sys.stdout.write(json.dumps(reply) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
