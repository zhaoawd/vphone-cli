"""Capture rig2 GUI baseline and a bottom swipe while holding its task lock."""
import base64
import fcntl
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
VM = ROOT / "vm-2607-rig2"
OUT = ROOT / "research/artifacts" / ("a3-rig2-" + time.strftime("%Y%m%d-%H%M%S"))
HOST = ROOT / ".build/vphone-cli.app/Contents/MacOS/vphone-cli"


def request(payload):
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(20)
        connection.connect(str(VM / "vphone.sock"))
        connection.sendall(json.dumps(payload).encode() + b"\n")
        data = b""
        while b"\n" not in data:
            chunk = connection.recv(65536)
            if not chunk:
                raise RuntimeError("Unexpected EOF")
            data += chunk
            if len(data) > 2 * 1024 * 1024:
                raise RuntimeError("Response exceeds protocol limit")
    response = json.loads(data.split(b"\n")[0])
    image = response.pop("image", None)
    label = payload.get("label", payload["t"])
    if image:
        (OUT / f"{label}.jpg").write_bytes(base64.b64decode(image))
    with (OUT / "requests.jsonl").open("a") as output:
        output.write(json.dumps({"time": time.time(), "request": payload,
                                 "response": response}) + "\n")
    return response


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    with open("/Users/qcz3840/github/autophone/runs/.locks/vm-2607-rig2.lock") as task_lock:
        fcntl.flock(task_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        directory = os.open(VM, os.O_RDONLY)
        try:
            fcntl.flock(directory, fcntl.LOCK_EX | fcntl.LOCK_NB)
            assert not (VM / "vphone.sock").exists(), "rig2 already has a socket"
            assert not (VM / ".firmware-transaction").exists(), "pending transaction"
        finally:
            os.close(directory)
        with (OUT / "boot.log").open("wb") as log:
            process = subprocess.Popen([str(HOST), "boot", "--config", str(VM / "config.plist"),
                                        "--variant", "exp", "--vphoned-bin", str(OUT / "disabled-update")],
                                       stdout=log, stderr=subprocess.STDOUT)
            try:
                deadline = time.monotonic() + 180
                while time.monotonic() < deadline:
                    if process.poll() is not None:
                        raise RuntimeError(f"Host exited: {process.returncode}")
                    try:
                        state = request({"t": "capabilities"})
                        if state.get("guest_connected"):
                            break
                    except (OSError, RuntimeError):
                        pass
                    time.sleep(2)
                else:
                    raise TimeoutError("Guest connection did not become ready")
                print(json.dumps(state), flush=True)
                time.sleep(10)
                request({"t": "screenshot", "label": "before", "color": True})
                request({"t": "swipe", "label": "after-swipe", "x1": 645.0, "y1": 2790.0,
                         "x2": 645.0, "y2": 1600.0, "ms": 300, "delay": 1500})
                request({"t": "screenshot", "label": "after", "color": True})
                time.sleep(5)
                request({"t": "swipe", "label": "second-swipe", "x1": 645.0, "y1": 2790.0,
                         "x2": 645.0, "y2": 1600.0, "ms": 300, "delay": 1500})
                request({"t": "screenshot", "label": "second-after", "color": True})
                request({"t": "key", "name": "home", "label": "home", "delay": 1500})
                request({"t": "screenshot", "label": "home-after", "color": True})
            finally:
                if process.poll() is None:
                    process.send_signal(signal.SIGINT)
                    process.wait(timeout=60)
                (OUT / "exit.json").write_text(json.dumps({"pid": process.pid, "exit": process.returncode,
                                                          "socket_exists": (VM / "vphone.sock").exists()}))


if __name__ == "__main__":
    main()
