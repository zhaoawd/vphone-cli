#!/usr/bin/env python3
"""Run two explicit upstream VM boot/stop cycles through the autophone adapter."""
from __future__ import annotations

import argparse
import fcntl
import json
import os
import socket
import subprocess
import time
from pathlib import Path


def request(path: Path, payload: dict, *, timeout: float = 3) -> dict:
    """Read-only stage-1 probes; never negotiate or retry a write."""
    if payload not in ({"t": "ping", "screen": False}, {
        "t": "rpc", "method": "device.info", "params": {}, "screen": False,
    }):
        raise ValueError("Only stage-1 read probes are allowed")
    if timeout <= 0:
        raise ValueError("probe timeout must be positive")
    deadline = time.monotonic() + timeout
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as channel:
        channel.settimeout(timeout)
        channel.connect(str(path))
        channel.sendall(json.dumps(payload).encode() + b"\n")
        response = bytearray()
        while b"\n" not in response:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("probe deadline expired")
            channel.settimeout(remaining)
            chunk = channel.recv(65536)
            if not chunk:
                raise ValueError("incomplete response")
            response.extend(chunk)
            if len(response) > 1 << 20:
                raise ValueError("response exceeds 1 MiB")
    line, trailing = response.split(b"\n", 1)
    if trailing.strip():
        raise ValueError("multiple responses")
    result = json.loads(line)
    if not isinstance(result, dict) or result.get("ok") is not True:
        raise ValueError(f"probe refused: {result}")
    return result


def disk_holders(disk: Path) -> list[int]:
    result = subprocess.run(
        ["/usr/sbin/lsof", "-t", "--", str(disk)], capture_output=True, text=True,
        timeout=10, check=False,
    )
    if result.returncode not in (0, 1) or result.stderr.strip():
        raise RuntimeError(f"lsof failed: {result.returncode}: {result.stderr}")
    return [int(pid) for pid in result.stdout.split()]


def check_shutdown(boot_log: str, stop_log: str) -> None:
    required = ("[vphone] Asking the guest to shut down", "[vphone] Guest stopped")
    if not all(marker in boot_log for marker in required):
        raise RuntimeError("guest shutdown confirmation is missing")
    if "turning it off" in boot_log or "force-killing" in stop_log:
        raise RuntimeError("shutdown used a power-off or forced kill")


def check_firmware(metadata: dict) -> None:
    if (metadata.get("ios", {}).get("build") != "24A446"
            or metadata.get("cloudOS", {}).get("build") != "23E5207q"):
        raise RuntimeError("restored firmware does not match the selected build pair")


def launch_lock_held(vm: Path) -> bool:
    descriptor = os.open(vm / ".autophone-launch.lock", os.O_RDWR | os.O_NOFOLLOW)
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return True
        return False
    finally:
        os.close(descriptor)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, required=True)
    parser.add_argument("--vm-dir", type=Path, required=True)
    parser.add_argument("--autophone", type=Path, required=True)
    parser.add_argument("--python", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--boot-timeout", type=float, default=300)
    args = parser.parse_args()
    if args.boot_timeout <= 0:
        parser.error("--boot-timeout must be positive")
    vm = args.vm_dir.resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    command = [str(args.python), "-m", "autophone.rig.upstream"]
    common = ["--bundle", str(args.bundle.resolve()), "--vm-dir", str(vm)]
    environment = {**os.environ, "VPHONE_ROOT": str(vm.parent.parent / "cache")}
    result: dict = {"accepted": False, "vm": str(vm), "cycles": []}
    try:
        metadata = json.loads((vm / "restore-info.json").read_text())
        check_firmware(metadata)
        result["restore_info"] = metadata
        if disk_holders(vm / "Disk.img"):
            raise RuntimeError("target disk is already open")
        for index in (1, 2):
            cycle: dict = {"index": index, "ready": False, "stopped": False}
            result["cycles"].append(cycle)
            log_path = output / f"boot-{index}.log"
            with log_path.open("xb") as log:
                launch = subprocess.Popen(
                    [*command, "launch", *common], cwd=args.autophone,
                    env=environment, stdout=log, stderr=subprocess.STDOUT,
                    start_new_session=True,
                )
                cycle["launcher_pid"] = launch.pid
                try:
                    start = time.monotonic()
                    deadline = start + args.boot_timeout
                    last_error = ""
                    while time.monotonic() < deadline:
                        if launch.poll() is not None:
                            raise RuntimeError(f"launcher exited before ready: {launch.returncode}")
                        try:
                            cycle["ping"] = request(vm / "vphone.sock", {"t": "ping", "screen": False})
                            break
                        except (OSError, ValueError) as exc:
                            last_error = str(exc)
                            time.sleep(1)
                    else:
                        raise TimeoutError(f"guest readiness timed out: {last_error}")
                    cycle["ready"] = True
                    cycle["boot_seconds"] = time.monotonic() - start
                    info_start = time.monotonic()
                    # Upstream VPhoneHTTPLimits.rpc permits 180 s. Allow its
                    # response to arrive before this client gives up.
                    cycle["device_info"] = request(vm / "vphone.sock", {
                        "t": "rpc", "method": "device.info", "params": {}, "screen": False,
                    }, timeout=185)
                    cycle["device_info_seconds"] = time.monotonic() - info_start
                    if cycle["device_info"].get("result", {}).get("ios_version") != "27.0.1":
                        raise RuntimeError("guest iOS version does not match the selected firmware")
                    identity = subprocess.run(
                        [str(args.python), "-m", "tools.vphone_process", "--binary",
                         str(args.bundle.resolve() / "Contents/MacOS/vphone-cli"),
                         "--config", str(vm / "config.plist")],
                        cwd=args.autophone, env=environment, capture_output=True, text=True,
                        timeout=15, check=False,
                    )
                    cycle["process_identity"] = {"exit_code": identity.returncode,
                                                 "stdout": identity.stdout, "stderr": identity.stderr}
                    if identity.returncode != 0 or identity.stdout.strip() != "target":
                        raise RuntimeError("companion process attribution failed")
                    cycle["disk_holders_running"] = disk_holders(vm / "Disk.img")
                    if not cycle["disk_holders_running"]:
                        raise RuntimeError("running VM has no observed disk holder")
                    cycle["launch_lock_held_running"] = launch_lock_held(vm)
                    if not cycle["launch_lock_held_running"]:
                        raise RuntimeError("launch lock was not retained by the upstream process")
                finally:
                    stop = subprocess.run(
                        [*command, "stop", *common], cwd=args.autophone, env=environment,
                        capture_output=True, text=True, timeout=40, check=False,
                    )
                    (output / f"stop-{index}.log").write_text(stop.stdout + stop.stderr)
                    cycle["stop_exit_code"] = stop.returncode
                    cycle["launcher_exit_code"] = launch.wait(timeout=15)
                if stop.returncode != 0 or launch.returncode != 0:
                    raise RuntimeError("stop/launcher exit code is nonzero")
            check_shutdown(log_path.read_text(errors="replace"), stop.stdout + stop.stderr)
            holders = disk_holders(vm / "Disk.img")
            cycle["disk_holders_after_stop"] = holders
            if holders:
                raise RuntimeError(f"disk remains open after stop: {holders}")
            cycle["launch_lock_held_after_stop"] = launch_lock_held(vm)
            if cycle["launch_lock_held_after_stop"]:
                raise RuntimeError("launch lock remains held after stop")
            cycle["stopped"] = True
        sessions = [c["device_info"]["result"].get("boot_session_uuid") for c in result["cycles"]]
        result["boot_sessions"] = sessions
        if not all(isinstance(s, str) and s for s in sessions) or sessions[0] == sessions[1]:
            raise RuntimeError("distinct boot session UUIDs were not observed")
        result["accepted"] = True
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError, KeyError, TypeError) as exc:
        result["error"] = f"{type(exc).__name__}: {exc}"
    finally:
        (output / "result.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"accepted": result["accepted"], "output": str(output),
                      "error": result.get("error")}, ensure_ascii=False))
    return 0 if result["accepted"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
