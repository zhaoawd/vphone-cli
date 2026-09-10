#!/usr/bin/env python3
"""Verify saved CLI DeviceTrees for one fixed pair without rebuilding tests.

Runs the existing DeviceTree parity suite against regular/exp output, then compares
all other scenario containers to the corresponding verified output. No VM boots.
"""
import argparse
import json
import os
import pathlib
import re
import subprocess

import c3_full_pipeline_acceptance as common


def verify(pair, run_name, evidence_name):
    for name in (run_name, evidence_name):
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}", name):
            raise ValueError("Invalid run or evidence name")
    common.PAIR = pair
    base = common.ROOT / "research/artifacts/c3-full-pipeline-2026-09-10"
    root = base if pair == "261" else base.with_name(base.name + "-" + pair)
    run, stock = root / "runs" / run_name, root / "stock"
    if run.resolve() != run or stock.resolve() != stock:
        raise ValueError("Input paths must not contain symlinks")
    source_data = (stock / "sources.json").read_bytes()
    sources = json.loads(source_data)
    staging = json.loads((run / "staging.json").read_text())
    if sources.get("pair", "261") != pair or staging.get("pair", "261") != pair:
        raise ValueError("Pair identity mismatch")
    if staging["sources_sha256"] != common.sha(source_data):
        raise ValueError("Stock provenance differs from staged provenance")
    if staging.get("scenarios", common.scenarios() if pair == "261" else None) != common.scenarios():
        raise ValueError("Scenario inventory mismatch")
    relative = pathlib.Path("Firmware/all_flash/DeviceTree.vphone600ap.im4p")
    original = stock / "cloudos" / relative
    record = next(item for item in sources["files"] if item["path"] == str(original.relative_to(root)))
    if len(original.read_bytes()) != record["bytes"] or common.sha(original.read_bytes()) != record["sha256"]:
        raise ValueError("Original DeviceTree changed")
    restore = common.pair_config()["restore_name"]
    outputs = {scenario: run / scenario / "vm" / restore / relative for scenario in common.scenarios()}
    # Fail before launching the suite if any saved CLI output is absent.
    for path in outputs.values():
        if not path.is_file() or path.resolve() != path:
            raise ValueError(f"Missing or redirected output: {path}")
    evidence = run / evidence_name
    evidence.mkdir(exist_ok=False)
    env = os.environ.copy()
    env.update({"VPHONE_TEST_DT_IM4P": str(original),
                "VPHONE_TEST_DT_BASE_OUTPUT_IM4P": str(outputs["regular"]),
                "VPHONE_TEST_DT_EXP_OUTPUT_IM4P": str(outputs["exp"])})
    command = ["swift", "test", "-c", "release", "--skip-build", "--filter", "DeviceTreeStructuredParityTests"]
    log_path = evidence / "test.log"
    with log_path.open("x") as log:
        result = subprocess.run(command, cwd=common.ROOT, env=env, stdout=log, stderr=subprocess.STDOUT)
    if result.returncode:
        raise subprocess.CalledProcessError(result.returncode, command)
    text = log_path.read_text()
    for exp in ("false", "true"):
        if f"C3 DeviceTree exp={exp}: CLI output serialized payload compared:" not in text:
            raise ValueError("Expected saved-output comparison did not execute")
    comparisons = {}
    for scenario, settings in common.scenarios().items():
        reference = "exp" if settings["variant"] == "exp" else "regular"
        data = outputs[scenario].read_bytes()
        if data != outputs[reference].read_bytes():
            raise ValueError(f"DeviceTree container mismatch: {scenario} vs {reference}")
        comparisons[scenario] = {"reference": reference, "file_sha256": common.sha(data), "bytes": len(data)}
    common.write_json(evidence / "result.json", {
        "pair": pair, "run": run_name, "command": command,
        "sources_sha256": common.sha(source_data), "log_sha256": common.sha(log_path.read_bytes()),
        "saved_payload_parity_passed": True, "container_comparisons": comparisons,
    })
    print(evidence / "result.json")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pair", choices=common.PAIRS, required=True)
    parser.add_argument("--run-name", default="acceptance-01")
    parser.add_argument("--evidence-name", default="devicetree-output-01")
    args = parser.parse_args()
    verify(args.pair, args.run_name, args.evidence_name)


if __name__ == "__main__":
    main()
