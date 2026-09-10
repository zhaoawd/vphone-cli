#!/usr/bin/env python3
"""Stage fresh fixed-pair inputs and run non-less full-pipeline parity tests.

Build release tests first. This runner uses --skip-build, runs scenarios serially,
and refuses existing run directories. It does not fetch, patch files, or boot VMs.
"""
import argparse
import datetime
import os
import re
import subprocess
import time

import c3_full_pipeline_acceptance as common


def parity(pair, run_name):
    common.PAIR = pair
    base = common.ROOT / "research/artifacts/c3-full-pipeline-2026-09-10"
    common.OUTPUT = base if pair == "261" else base.with_name(base.name + "-" + pair)
    if common.OUTPUT.resolve() != common.OUTPUT:
        raise ValueError("Output path must not contain symlinks")
    common.stage(run_name)
    run = common.OUTPUT / "runs" / run_name
    scenarios = common.scenarios()
    command = ["swift", "test", "-c", "release", "--skip-build", "--filter", "FullPipelineParityTests"]
    invocation = {
        "pair": pair, "config": common.pair_config(), "scenarios": scenarios,
        "command": command, "git_head": subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=common.ROOT, text=True).strip(),
        "started_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "staging_sha256": common.sha((run / "staging.json").read_bytes()),
        "force_exc_guard": False, "scope": "in-memory legacy/structured full-pipeline parity; no restore or boot",
    }
    common.write_json(run / "parity-invocation.json", invocation)
    completed = {}
    for scenario, settings in scenarios.items():
        env = os.environ.copy()
        env.update({
            "VPHONE_TEST_PIPELINE_VM": str(run / scenario / "vm"),
            "VPHONE_TEST_PIPELINE_VARIANT": settings["variant"],
            "VPHONE_TEST_PIPELINE_FRIDA": "1" if settings["frida"] else "0",
            "VPHONE_TEST_PIPELINE_FORCE_EXC_GUARD": "0",
        })
        log_path = run / scenario / "parity.log"
        print(f"Running {pair}/{scenario}: {log_path}", flush=True)
        started = time.monotonic()
        with log_path.open("x") as log:
            result = subprocess.run(command, cwd=common.ROOT, env=env,
                                    stdout=log, stderr=subprocess.STDOUT)
        log_text = log_path.read_text()
        test_passed = bool(re.search(r"Test Case .*FullPipelineParityTests.*testNonLessLegacyAndStructuredPayloadsMatch.* passed", log_text))
        evidence = {"exit_code": result.returncode, "expected_test_passed": test_passed, "seconds": time.monotonic() - started,
                    "log_sha256": common.sha(log_path.read_bytes()),
                    "variant": settings["variant"], "frida": settings["frida"]}
        common.write_json(run / scenario / "parity-result.json", evidence)
        completed[scenario] = evidence
        if result.returncode:
            raise subprocess.CalledProcessError(result.returncode, command)
        if not test_passed:
            raise ValueError(f"Expected parity test did not report passed: {log_path}")
    common.write_json(run / "parity-summary.json", {
        "pair": pair, "passed": True, "scenarios": completed,
        "invocation_sha256": common.sha((run / "parity-invocation.json").read_bytes()),
    })
    print(run / "parity-summary.json", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pair", choices=common.PAIRS, required=True)
    parser.add_argument("--run-name", default="parity-01", help="New isolated run name; existing paths are refused")
    args = parser.parse_args()
    parity(args.pair, args.run_name)


if __name__ == "__main__":
    main()
