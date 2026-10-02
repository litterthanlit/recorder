#!/usr/bin/env python3
"""Drives `Trace --mcp` over stdio and checks the MCP protocol basics.

    scripts/mcp-smoke.py path/to/Trace.app/Contents/MacOS/Trace

Covers both protocol eras (2026-07-28 per-request metadata, and the `initialize` handshake
of older clients), version errors, prompts, that stdout carries nothing but JSON lines,
and that the server exits when stdin closes. Needs no running Trace app: only `tools/call`
talks to it, and it isn't called here.
"""

import json
import subprocess
import sys

MODERN = "2026-07-28"
META = {
    "io.modelcontextprotocol/protocolVersion": MODERN,
    "io.modelcontextprotocol/clientCapabilities": {},
    "io.modelcontextprotocol/clientInfo": {"name": "mcp-smoke", "version": "1"},
}

failures = []


def check(condition, message):
    if not condition:
        failures.append(message)
        print(f"FAIL: {message}")


def request(id, method, params=None, meta=True):
    params = dict(params or {})
    if meta:
        params["_meta"] = META
    return {"jsonrpc": "2.0", "id": id, "method": method, "params": params}


def session(binary, messages, timeout=20):
    """Sends `messages`, closes stdin, and returns the decoded stdout lines."""
    payload = "".join(json.dumps(m) + "\n" for m in messages).encode()
    try:
        result = subprocess.run(
            [binary, "--mcp"],
            input=payload,
            capture_output=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        check(False, "server did not exit after stdin closed")
        return []
    check(result.returncode == 0, f"exit code {result.returncode} (stderr: {result.stderr.decode(errors='replace')[-500:]})")
    decoded = []
    for line in result.stdout.decode().splitlines():
        try:
            decoded.append(json.loads(line))
        except json.JSONDecodeError:
            check(False, f"stdout line is not JSON: {line[:200]!r}")
    return decoded


def by_id(messages):
    return {m["id"]: m for m in messages if "id" in m and "method" not in m}


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    binary = sys.argv[1]

    # A modern (2026-07-28) client.
    modern = by_id(session(binary, [
        request(1, "server/discover"),
        request(2, "tools/list"),
        request(3, "prompts/list"),
        request(4, "prompts/get", {"name": "launch_demo", "arguments": {"product": "Acme"}}),
        request(5, "tools/list", meta=False),
        {"jsonrpc": "2.0", "id": 6, "method": "tools/list",
         "params": {"_meta": {**META, "io.modelcontextprotocol/protocolVersion": "1900-01-01"}}},
        request(7, "no/such/method"),
        request(8, "ping"),
    ]))
    discover = modern.get(1, {}).get("result", {})
    check(MODERN in discover.get("supportedVersions", []), "server/discover lists 2026-07-28")
    check(discover.get("resultType") == "complete", "server/discover has resultType")
    check(discover.get("_meta", {}).get("io.modelcontextprotocol/serverInfo", {}).get("name") == "trace",
          "server/discover names the server")
    check("tools" in discover.get("capabilities", {}), "server/discover declares tools")
    check(isinstance(modern.get(2, {}).get("result", {}).get("tools"), list), "tools/list returns a list")
    prompts = [p.get("name") for p in modern.get(3, {}).get("result", {}).get("prompts", [])]
    check("launch_demo" in prompts, "prompts/list has launch_demo")
    messages = modern.get(4, {}).get("result", {}).get("messages", [])
    check(bool(messages) and "Acme" in messages[0].get("content", {}).get("text", ""), "prompts/get renders arguments")
    check(modern.get(5, {}).get("error", {}).get("code") == -32602, "a request without _meta is refused (-32602)")
    error = modern.get(6, {}).get("error", {})
    check(error.get("code") == -32022, "an unsupported version gets -32022")
    check(MODERN in error.get("data", {}).get("supported", []), "-32022 lists the supported versions")
    check(modern.get(7, {}).get("error", {}).get("code") == -32601, "unknown methods get -32601")
    check(modern.get(8, {}).get("result", {}).get("resultType") == "complete", "ping answers")

    # A legacy (initialize handshake) client.
    legacy_messages = session(binary, [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": {"name": "mcp-smoke", "version": "1"},
        }},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        request(2, "tools/list", meta=False),
        request(3, "prompts/list", meta=False),
    ])
    legacy = by_id(legacy_messages)
    initialize = legacy.get(1, {}).get("result", {})
    check(initialize.get("protocolVersion") == "2025-06-18", "initialize echoes a supported version")
    check(initialize.get("serverInfo", {}).get("name") == "trace", "initialize names the server")
    check(bool(initialize.get("instructions")), "initialize sends instructions")
    check(isinstance(legacy.get(2, {}).get("result", {}).get("tools"), list), "legacy tools/list works after initialize")
    check("launch_demo" in [p.get("name") for p in legacy.get(3, {}).get("result", {}).get("prompts", [])],
          "legacy prompts/list works")
    check(len(legacy_messages) == 3, f"exactly one answer per request ({len(legacy_messages)} lines)")

    if failures:
        print(f"{len(failures)} check(s) failed")
        sys.exit(1)
    print("MCP smoke test passed")


if __name__ == "__main__":
    main()
