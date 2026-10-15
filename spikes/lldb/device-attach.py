#!/usr/bin/env python3
"""Attach LLDB to a process on a physical device (CoreDevice) with visible state + timeout.

Usage: PYTHONPATH=$(lldb -P) python3 attach.py <udid> <pid> [lldb command file to run once stopped]
"""
import sys, time
import lldb

udid, pid = sys.argv[1], int(sys.argv[2])
after = sys.argv[3] if len(sys.argv) > 3 else None

dbg = lldb.SBDebugger.Create()
dbg.SetAsync(True)
ci = dbg.GetCommandInterpreter()

def run(cmd):
    r = lldb.SBCommandReturnObject()
    ci.HandleCommand(cmd, r)
    out = (r.GetOutput() or "") + (r.GetError() or "")
    print(f"(lldb) {cmd}\n{out.strip()[:4000]}", flush=True)
    return r

t0 = time.time()
run(f"device select {udid}")
run(f"device process attach -p {pid}")

listener = dbg.GetListener()
state = None
deadline = time.time() + 90
while time.time() < deadline:
    ev = lldb.SBEvent()
    if listener.WaitForEvent(1, ev):
        if lldb.SBProcess.EventIsProcessEvent(ev):
            state = lldb.SBProcess.GetStateFromEvent(ev)
            print(f"[{time.time()-t0:5.1f}s] process state -> {dbg.StateAsCString(state)}", flush=True)
            if state in (lldb.eStateStopped, lldb.eStateExited, lldb.eStateDetached, lldb.eStateCrashed):
                break
        else:
            desc = lldb.SBStream(); ev.GetDescription(desc)
            print(f"[{time.time()-t0:5.1f}s] event: {desc.GetData()[:200]}", flush=True)
    tgt = dbg.GetSelectedTarget()
    if tgt and tgt.GetProcess() and tgt.GetProcess().GetState() == lldb.eStateStopped:
        state = lldb.eStateStopped
        print(f"[{time.time()-t0:5.1f}s] process is stopped", flush=True)
        break
else:
    tgt = dbg.GetSelectedTarget()
    p = tgt.GetProcess() if tgt else None
    print(f"TIMEOUT after 90s; target={tgt}; process state={dbg.StateAsCString(p.GetState()) if p else None}", flush=True)
    run("target list")
    run("process status")
    sys.exit(2)

if state == lldb.eStateStopped and after:
    dbg.SetAsync(False)
    for line in open(after):
        if line.strip():
            run(line.strip())
dbg.SetAsync(False)
run("detach")
print(f"total {time.time()-t0:.1f}s")
