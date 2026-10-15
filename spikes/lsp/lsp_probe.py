#!/usr/bin/env python3
"""Probe sourcekit-lsp against an Xcode project using only a prebuilt index store.

Usage: lsp_probe.py <root> <index_store> <index_db_dir> <file> <line0> <col0> <workspace_symbol_query>
"""
import json, os, subprocess, sys, time, pathlib

root, store, db, path, line, col, query = sys.argv[1:8]
line, col = int(line), int(col)
p = subprocess.Popen(["xcrun", "sourcekit-lsp", "--default-workspace-type", "compilationDatabase", "--compilation-db-search-path", os.environ.get('CDB','')], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=subprocess.DEVNULL)
nid = 0

def send(method, params, notify=False):
    global nid
    msg = {"jsonrpc": "2.0", "method": method, "params": params}
    if not notify:
        nid += 1
        msg["id"] = nid
    body = json.dumps(msg).encode()
    p.stdin.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
    p.stdin.flush()
    return None if notify else nid

def recv(want):
    while True:
        hdr = b""
        while not hdr.endswith(b"\r\n\r\n"):
            hdr += p.stdout.read(1)
        n = int([h for h in hdr.decode().split("\r\n") if h.lower().startswith("content-length")][0].split(":")[1])
        m = json.loads(p.stdout.read(n))
        if m.get("id") == want and "method" not in m:
            return m
        if "method" in m and "id" in m:  # server->client request: reply null
            body = json.dumps({"jsonrpc": "2.0", "id": m["id"], "result": None}).encode()
            p.stdin.write(b"Content-Length: %d\r\n\r\n" % len(body) + body); p.stdin.flush()

def call(method, params):
    t0 = time.time(); r = recv(send(method, params)); return r, time.time() - t0

uri = pathlib.Path(path).as_uri()
r, dt = call("initialize", {"processId": os.getpid(), "rootUri": pathlib.Path(root).as_uri(),
    "capabilities": {"workspace": {"symbol": {}}, "textDocument": {"definition": {}, "references": {}}},
    "initializationOptions": {"index": {"indexStorePath": store, "indexDatabasePath": db}}})
print(f"initialize {dt:.2f}s ok={'result' in r}")
send("initialized", {}, notify=True)
send("textDocument/didOpen", {"textDocument": {"uri": uri, "languageId": "swift", "version": 1,
                                                "text": open(path).read()}}, notify=True)
time.sleep(25)  # let the index DB load units from the store
r, dt = call("workspace/symbol", {"query": query})
res = r.get("result") or []
print(f"workspace/symbol '{query}' {dt:.2f}s -> {len(res)} results")
for s in res[:5]:
    print("  ", s["name"], s.get("containerName"), s["location"]["uri"].split("/")[-1], s["location"]["range"]["start"])
pos = {"textDocument": {"uri": uri}, "position": {"line": line, "character": col}}
r, dt = call("textDocument/definition", pos)
res = r.get("result") or []
res = res if isinstance(res, list) else [res]
print(f"definition {dt:.2f}s -> {len(res)}", [(x['uri'].split('/')[-1], x['range']['start']['line']) for x in res][:5], r.get("error"))
r, dt = call("textDocument/references", {**pos, "context": {"includeDeclaration": True}})
res = r.get("result") or []
print(f"references {dt:.2f}s -> {len(res)}", sorted({x['uri'].split('/')[-1] for x in res})[:10], r.get("error"))
p.terminate()
