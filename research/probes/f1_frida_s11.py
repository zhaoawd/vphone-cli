#!/usr/bin/env python3
"""F1 S11: Frida client instrumentation on a guest over usbmux.

usage: frida_s11.py <udid> <out dir> [<vphone.sock>]
Run with the autophone venv python (frida 17.16.1). Writes s11.json.
Hook and Stalker run in separate scripts; unload/detach steps are time-bounded.
"""
import json, sys, threading, time
from pathlib import Path
import frida

udid, out = sys.argv[1], Path(sys.argv[2]); out.mkdir(parents=True, exist_ok=True)
sock = sys.argv[3] if len(sys.argv) > 3 else None
result = {"client_version": frida.__version__, "udid": udid, "checks": {}, "messages": []}


def check(name, status, detail):
    result["checks"][name] = {"status": status, "detail": detail}
    print(name, status, detail, flush=True)


def bounded(name, fn, seconds=20):
    box = {}

    def run():
        try:
            box["value"] = fn()
        except Exception as e:
            box["error"] = f"{type(e).__name__}: {e}"

    t = threading.Thread(target=run, daemon=True)
    t.start(); t.join(seconds)
    if t.is_alive():
        return "timeout", f"{name} did not return within {seconds}s"
    return ("error", box["error"]) if "error" in box else ("ok", box.get("value"))


def activity():
    """Make SpringBoard do work (and open files) by launching/terminating Settings via host control."""
    if not sock:
        return "no socket given"
    sys.path.insert(0, "/Users/kolar/github/vphone-cli/scripts")
    import host_control_client as hc

    class R:
        def record(self, *a):
            pass

    ep = hc.endpoint("vm", sock)
    a = hc.request(ep, {"t": "app_launch", "bundle_id": "com.apple.Preferences", "screen": False}, R(), 60)
    time.sleep(1.5)
    b = hc.request(ep, {"t": "app_terminate", "bundle_id": "com.apple.Preferences", "screen": False}, R(), 60)
    return {"launch": a.get("ok"), "terminate": b.get("ok")}


HOOK = r"""
let count = 0;
const openPtr = Module.getGlobalExportByName('open');
Interceptor.attach(openPtr, { onEnter(args) { count++; } });
send({type: 'hook_ready', open: openPtr.toString(), pid: Process.id, arch: Process.arch});
rpc.exports = { count() { return count; } };
"""

STALK = r"""
rpc.exports = {
  stalk(ms) {
    return new Promise(resolve => {
      const threads = Process.enumerateThreads();
      const tid = threads[0].id;
      let blocks = 0;
      Stalker.follow(tid, {events: {compile: true},
        onReceive(events) { blocks += Stalker.parse(events, {annotate: false}).length; }});
      setTimeout(() => { Stalker.unfollow(tid); Stalker.flush();
        setTimeout(() => resolve({tid, threads: threads.length, blocks}), 500); }, ms);
    });
  }
};
"""

try:
    device = frida.get_device(udid, timeout=15)
    params = device.query_system_parameters()
    result["server"] = {k: params.get(k) for k in ("os", "platform", "arch", "access")}
    check("device_connect", "passed", f"{device.name} {params.get('os', {}).get('version')}")
    pid_before = device.get_process("SpringBoard").pid
    session = device.attach(pid_before)

    hook = session.create_script(HOOK)
    hook.on("message", lambda m, d: result["messages"].append(m))
    hook.load()
    time.sleep(1)
    ready = [m for m in result["messages"] if m.get("type") == "send" and m["payload"].get("type") == "hook_ready"]
    check("hook_message", "passed" if ready else "failed", ready[0]["payload"] if ready else result["messages"])
    act = activity()
    time.sleep(2)
    n = hook.exports_sync.count()
    check("hook_counts_open", "passed" if n > 0 else "partial", f"open() calls while host launched/terminated Settings ({act}): {n}")
    st, v = bounded("hook_unload", hook.unload)
    check("hook_unload", "passed" if st == "ok" else "failed", "unloaded" if st == "ok" else v)

    stalk = session.create_script(STALK)
    stalk.load()
    st, v = bounded("stalker", lambda: stalk.exports_sync.stalk(1500), 30)
    check("stalker_follow_existing_thread", "passed" if st == "ok" and v.get("blocks", 0) > 0 else "failed", v)
    st, v = bounded("stalker_unload", stalk.unload)
    check("stalker_unload", "passed" if st == "ok" else "failed", "unloaded" if st == "ok" else v)

    st, v = bounded("session_detach", session.detach)
    check("session_detach", "passed" if st == "ok" else "failed", "detached" if st == "ok" else v)
    time.sleep(2)
    st, v = bounded("target_lookup", lambda: device.get_process("SpringBoard").pid)
    check("target_alive_after_detach", "passed" if st == "ok" and v == pid_before else "failed",
          f"SpringBoard pid {pid_before} -> {v}")
except Exception as e:
    check("exception", "failed", f"{type(e).__name__}: {e}")

statuses = [c["status"] for c in result["checks"].values()]
result["status"] = "failed" if "failed" in statuses else ("passed" if statuses and all(s == "passed" for s in statuses) else "partial")
(out / "s11.json").write_text(json.dumps(result, indent=1, default=str))
print("S11", result["status"], flush=True)
import os
os._exit(0 if result["status"] == "passed" else 1)
