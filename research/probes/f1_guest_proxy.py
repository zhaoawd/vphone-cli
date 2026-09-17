#!/usr/bin/env python3
"""Set the guest en0 network service HTTP/HTTPS proxy (F2 fields) through host control.

usage: guest_proxy.py <vphone.sock> <evidence dir>
Backs up preferences.plist on host and guest; writes only the six proxy keys; verifies readback.
"""
import base64, hashlib, json, plistlib, sys, time
from pathlib import Path
sys.path.insert(0, "/Users/kolar/github/vphone-cli/scripts")
import host_control_client as hc

PREFS = "/var/preferences/SystemConfiguration/preferences.plist"
FIELDS = {"HTTPEnable": 1, "HTTPProxy": "192.168.64.1", "HTTPPort": 10808,
          "HTTPSEnable": 1, "HTTPSProxy": "192.168.64.1", "HTTPSPort": 10808}

sock, out = sys.argv[1], Path(sys.argv[2]); out.mkdir(parents=True, exist_ok=True)
ep = hc.endpoint("vm", sock)
log = open(out / "proxy-requests.jsonl", "a")


class Rec:
    def record(self, endpoint, request, response):
        r = dict(request); r.pop("data_b64", None)
        s = dict(response); s.pop("data_b64", None); s.pop("data", None)
        log.write(json.dumps({"time": time.time(), "request": r, "response": s}) + "\n")


def call(payload):
    return hc.request(ep, payload, Rec(), 60)


raw = hc.decode_file(ep, call({"t": "file_get", "path": PREFS}))
(out / "preferences.before.plist").write_bytes(raw)
prefs = plistlib.loads(raw)
current = prefs.get("CurrentSet", "")
set_id = current.rsplit("/", 1)[-1]
order = prefs.get("Sets", {}).get(set_id, {}).get("Network", {}).get("Global", {}).get("IPv4", {}).get("ServiceOrder", [])
targets = []
for sid, svc in prefs.get("NetworkServices", {}).items():
    if svc.get("Interface", {}).get("DeviceName") == "en0" and (not order or sid in order):
        targets.append(sid)
if not targets:
    print("no en0 service in current set; services:", {k: v.get("Interface", {}).get("DeviceName") for k, v in prefs.get("NetworkServices", {}).items()})
    sys.exit(3)
already = all(all(prefs["NetworkServices"][sid].get("Proxies", {}).get(k) == v for k, v in FIELDS.items()) for sid in targets)
if already:
    print("proxy already configured on", targets); sys.exit(0)
stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
hc.require_ok(ep, "file_put", call({"t": "file_put", "path": f"{PREFS}.f1-before-proxy-{stamp}",
                                     "data_b64": base64.b64encode(raw).decode(), "perm": "644"}))
for sid in targets:
    prefs["NetworkServices"][sid].setdefault("Proxies", {}).update(FIELDS)
new = plistlib.dumps(prefs, fmt=plistlib.FMT_BINARY)
(out / "preferences.after.plist").write_bytes(new)
hc.require_ok(ep, "file_put", call({"t": "file_put", "path": PREFS, "data_b64": base64.b64encode(new).decode(), "perm": "644"}))
back = hc.decode_file(ep, call({"t": "file_get", "path": PREFS}))
ok = hashlib.sha256(back).digest() == hashlib.sha256(new).digest()
print(json.dumps({"services": targets, "readback_matches": ok, "sha256": hashlib.sha256(new).hexdigest()}))
sys.exit(0 if ok else 4)
