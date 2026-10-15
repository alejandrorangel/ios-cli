#!/usr/bin/env python3
"""mcp.py '<json list of [tool,args]>' [--full]  -> prints result per call (truncated unless --full), saves all to last.json"""
import json, subprocess, sys, time
calls = json.loads(sys.argv[1]); full = '--full' in sys.argv
p = subprocess.Popen(["xcrun","mcpbridge"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
def send(m): p.stdin.write(json.dumps(m)+"\n"); p.stdin.flush()
def recv(i):
    while True:
        l = p.stdout.readline()
        if not l: raise SystemExit("bridge closed")
        m = json.loads(l)
        if m.get("id") == i: return m
send({"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"ios-cli-spike","version":"0"}}}); recv(0)
send({"jsonrpc":"2.0","method":"notifications/initialized"})
out=[]; prev={}
for i,(tool,args) in enumerate(calls,1):
    args={k:(prev.get(v[6:]) if isinstance(v,str) and v.startswith("$prev.") else v) for k,v in args.items()}
    t0=time.time(); send({"jsonrpc":"2.0","id":i,"method":"tools/call","params":{"name":tool,"arguments":args}})
    r=recv(i); dt=time.time()-t0
    res=r.get("result",r.get("error")); sc=res.get("structuredContent") if isinstance(res,dict) else None
    if sc: prev.update(sc)
    out.append({"tool":tool,"args":args,"secs":round(dt,2),"result":sc or res})
    s=json.dumps(sc or res,indent=1)
    print(f"===== {tool} ({dt:.2f}s)"); print(s if full else s[:2500])
json.dump(out,open("last.json","w"),indent=1)
p.stdin.close(); p.terminate()
