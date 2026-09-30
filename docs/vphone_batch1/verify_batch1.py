#!/usr/bin/env python3
"""Record baseline/post-patch checks on the real Mac; never boot/restore a VM.

Creates a NEW evidence directory. Does not run bootstrap installers or alter host
security settings, edit documents, commit or push. Project make commands may
resolve their normal build dependencies. Optional fetch only obtains
the fixed upstream object; it does not change branch, index or remote config.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import signal
import subprocess
import sys

BASE = "bc3bfa83ee8d3397e1caa08ce580e24407de17cd"
UPSTREAM = "9d218dedf58d4b19db5e51c8b584c1f14a96eee3"


def run(command: list[str], cwd: Path, log: Path, timeout: int) -> dict:
    result = {"command": command, "started_at": datetime.now(timezone.utc).isoformat(), "log": log.name}
    try:
        with log.open("xb") as stream:
            process = subprocess.Popen(command, cwd=cwd, stdout=stream, stderr=subprocess.STDOUT,
                                       start_new_session=True)
            try:
                result["exit_code"] = process.wait(timeout=timeout)
                result["status"] = "passed" if result["exit_code"] == 0 else "failed"
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                result.update(status="timed_out", exit_code=process.returncode)
    except FileNotFoundError as error:
        result.update(status="blocked", reason=str(error))
    result["finished_at"] = datetime.now(timezone.utc).isoformat()
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--phase", required=True, choices=["baseline", "post"])
    parser.add_argument("--timeout", type=int, default=1800)
    parser.add_argument("--fetch-upstream", action="store_true")
    args = parser.parse_args()
    repo = args.repo.resolve()
    output = args.output.resolve()
    if output == repo or repo in output.parents:
        parser.error("--output must be a new directory outside the repository")
    if args.timeout < 1:
        parser.error("--timeout must be positive")
    output.mkdir(parents=True, exist_ok=False)
    report = {
        "phase": args.phase, "repo": str(repo), "base_commit": BASE,
        "upstream_commit": UPSTREAM, "platform": platform.platform(), "checks": [],
        "vm_acceptance": "not_run", "variant_and_camera_abi_review": "not_run",
        "complete_vm_backup": "not_run",
        "note": "Command results only. Not a full P0/P1c sign-off; VM and manual reviews remain separate."
    }
    report_path = output / "results.json"
    def add(name: str, command: list[str]) -> dict:
        result = run(command, repo, output / f"{name}.log", args.timeout)
        result["name"] = name
        report["checks"].append(result)
        report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        print(f"{name}: {result['status']}", flush=True)
        return result
    add("head", ["git", "rev-parse", "HEAD"])
    add("worktree-status", ["git", "status", "--short"])
    add("submodules", ["git", "submodule", "status"])
    add("swift-version", ["swift", "--version"])
    if platform.system() != "Darwin":
        report["blocked_reason"] = "Not macOS; original project/Virtualization/Xcode checks were NOT run."
        report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        return 2
    add("xcode-version", ["xcodebuild", "-version"])
    add("macos-version", ["sw_vers"])
    add("base-object", ["git", "cat-file", "-e", f"{BASE}^{{commit}}"])
    if args.fetch_upstream:
        add("fetch-fixed-upstream", ["git", "fetch", "--no-tags", "https://github.com/Lakr233/vphone-cli.git", UPSTREAM])
    upstream = add("upstream-object", ["git", "cat-file", "-e", f"{UPSTREAM}^{{commit}}"])
    if upstream.get("exit_code") == 0:
        add("merge-base", ["git", "merge-base", "--all", BASE, UPSTREAM])
        merge = add("merge-tree", ["git", "merge-tree", "--write-tree", "--name-only", BASE, UPSTREAM])
        if merge.get("exit_code") == 1:
            merge["status"] = "recorded_conflicts"
        add("changed-paths", ["git", "diff", "--name-status", BASE, UPSTREAM, "--", ".", ":(exclude)TODO.md"])
    add("make-test", ["make", "test"])
    add("make-test-fixtures", ["make", "test_fixtures"])
    if args.phase == "post":
        add("make-test-swift", ["make", "test_swift"])
        add("make-build", ["make", "build"])
        add("diff-check", ["git", "diff", "--check", "--", ".", ":(exclude)TODO.md"])
    add("worktree-status-after", ["git", "status", "--short"])
    report["log_sha256"] = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in output.glob("*.log")}
    report["all_executed_checks_passed"] = all(
        r["status"] in ("passed", "recorded_conflicts") for r in report["checks"])
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(f"Evidence: {report_path}\nVM acceptance remains NOT RUN.")
    return 0 if report["all_executed_checks_passed"] else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(2)
