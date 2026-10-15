#!/usr/bin/env python3
"""Minimal stdio MCP client for `xcrun mcpbridge`.

Usage: mcp_call.py '<json list of [tool, args]>'
Runs the calls sequentially in one bridge session; args values of the form
"$prev.<field>" are substituted from the previous call's structured result.
"""
import json, subprocess, sys, time

calls = json.loads(sys.argv[1])
p = subprocess.Popen(["xcrun", "mcpbridge"], stdin=subprocess.PIPE,
                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)

def send(msg):
    p.stdin.write(json.dumps(msg) + "\n"); p.stdin.flush()

def recv(want_id):
    while True:
        line = p.stdout.readline()
        if not line:
            raise SystemExit("bridge closed: " + p.stderr.read())
        m = json.loads(line)
        if m.get("id") == want_id:
            return m

send({"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {
    "protocolVersion": "2025-06-18", "capabilities": {},
    "clientInfo": {"name": "ios-cli-probe", "version": "0"}}})
recv(0)
send({"jsonrpc": "2.0", "method": "notifications/initialized"})

prev = {}
for i, (tool, args) in enumerate(calls, start=1):
    args = {k: (prev.get(v[6:]) if isinstance(v, str) and v.startswith("$prev.") else v)
            for k, v in args.items()}
    t0 = time.time()
    send({"jsonrpc": "2.0", "id": i, "method": "tools/call",
          "params": {"name": tool, "arguments": args}})
    r = recv(i)
    dt = time.time() - t0
    res = r.get("result", r.get("error"))
    sc = res.get("structuredContent") if isinstance(res, dict) else None
    if sc:
        prev.update(sc)
    print(f"===== {tool} ({dt:.2f}s)")
    print(json.dumps(sc or res, indent=1)[:4000])
p.stdin.close()
p.terminate()
