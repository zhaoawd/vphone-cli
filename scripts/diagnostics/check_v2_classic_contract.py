#!/usr/bin/env python3
"""R5 contract checks scoped to the approved v2 acceptance VM.

Run contracts first; inspect before-tap.png before explicitly running tap.
Retains the guest marker and stops only the location generation it created.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import secrets
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from host_control_client import decode_file, endpoint, request, require_ok


VM = "lp-v2-accept-20261002"
SOCKET = Path("/Users/kolar/vphone-v2-accept-20261002/VMs") / VM / "vphone.sock"


class Recorder:
    def __init__(self, path):
        self.path = path

    def record(self, target, payload, response):
        with self.path.open("a") as stream:
            stream.write(json.dumps({"time": time.time(), "vm": target.name,
                                     "request": payload, "response": response}) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=("contracts", "tap"))
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    target = endpoint(VM, SOCKET)
    recorder = Recorder(output / (args.phase + ".jsonl"))
    results = {}

    def call(payload):
        response = request(target, payload, recorder, 15)
        require_ok(target, payload["t"], response)
        return response

    def check(name, operation):
        try:
            results[name] = operation()
        except Exception as error:
            results[name] = {"status": "failed", "error": str(error)}

    caps = call({"t": "capabilities"})
    (output / (args.phase + "-capabilities.json")).write_text(json.dumps(caps, indent=2))
    assert caps.get("guest_connected") is True, caps
    commands = caps.get("commands", {})

    def unavailable(*names):
        missing = [name for name in names if commands.get(name) is not True]
        return {"status": "blocked", "missing": missing} if missing else None

    def screenshot(name):
        blocked = unavailable("screenshot")
        if blocked:
            return blocked
        path = output / name
        call({"t": "screenshot", "path": str(path), "screen": False})
        assert path.is_file() and path.stat().st_size > 0
        return {"status": "passed", "path": str(path)}

    if args.phase == "tap":
        # A second invocation cannot accidentally repeat the approved single tap.
        marker = output / "tap-attempt.json"
        with marker.open("x") as stream:
            json.dump({"x": 10, "y": 10, "time": time.time()}, stream)
        assert (output / "before-tap.png").is_file(), "inspect before-tap.png first"
        blocked = unavailable("tap", "screenshot")
        results["tap"] = blocked or {"status": "passed", "response": call({"t": "tap", "x": 10.0, "y": 10.0})}
        check("after_tap", lambda: screenshot("after-tap.png"))
    else:
        def files():
            blocked = unavailable("file_put", "file_get")
            if blocked:
                return blocked
            path = "/var/mobile/Library/Caches/vphone-r5-" + secrets.token_hex(8) + ".txt"
            data = ("vphone R5 classic file contract " + path + "\n").encode()
            written = call({"t": "file_put", "path": path,
                            "data_b64": base64.b64encode(data).decode(), "perm": "600"})
            assert written.get("size") == len(data), written
            readback = decode_file(target, call({"t": "file_get", "path": path}))
            assert readback == data, "file readback differs"
            return {"status": "passed", "retained_guest_path": path,
                    "sha256": hashlib.sha256(readback).hexdigest()}

        def location():
            blocked = unavailable("location_source_set", "location_source_status", "location_source_stop")
            if blocked:
                return blocked
            initial = call({"t": "location_source_status"})
            if initial.get("state") != "off" or initial.get("generation") is not None:
                return {"status": "blocked", "reason": "existing location source", "initial": initial}
            lat, lon = 31.2304, 121.4737
            source = call({"t": "location_source_set", "mode": "fixed", "coordinate_system": "wgs84",
                           "owner": "vphone-r5-acceptance", "lat": lat, "lon": lon,
                           "producer_sequence": 0, "timestamp": time.time(), "heartbeat_s": 1.0,
                           "replace": False, "persist": False})
            generation = source.get("generation")
            assert isinstance(generation, str) and generation, source
            try:
                deadline = time.monotonic() + 30
                while True:
                    source = call({"t": "location_source_status"})
                    assert source.get("generation") in (None, generation), "location generation changed"
                    applied = source.get("applied") or {}
                    fix = applied.get("last_fix") or {}
                    if (source.get("state") == "running" and source.get("generation") == generation
                            and abs(fix.get("latitude", 999) - lat) < 1e-6
                            and abs(fix.get("longitude", 999) - lon) < 1e-6
                            and isinstance(applied.get("last_delivery_sequence"), int)
                            and applied["last_delivery_sequence"] > 0 and applied.get("last_ack_at")):
                        break
                    assert time.monotonic() < deadline, "location did not reach running with fix and ack"
                    time.sleep(0.2)
            finally:
                stopped = call({"t": "location_source_stop", "generation": generation})
            final = call({"t": "location_source_status"})
            assert stopped.get("state") == final.get("state") == "off"
            assert stopped.get("generation") is None and final.get("generation") is None
            return {"status": "partial", "protocol": "passed", "app_CoreLocation_reading": "not_run",
                    "generation": generation, "running": source, "final": final}

        def app():
            blocked = unavailable("app_launch")
            if blocked:
                return blocked
            return {"status": "partial", "response": call({"t": "app_launch", "bundle_id": "com.apple.Preferences", "screen": False}),
                    "application_behavior": "not_verified"}

        check("files", files)
        check("location", location)
        check("app_launch", app)
        check("before_tap", lambda: screenshot("before-tap.png"))

    (output / (args.phase + "-results.json")).write_text(json.dumps(results, indent=2))
    print(json.dumps(results, indent=2))
    return int(any(result.get("status") == "failed" for result in results.values()))


if __name__ == "__main__":
    raise SystemExit(main())
