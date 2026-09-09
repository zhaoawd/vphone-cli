#!/usr/bin/env python3
"""Validate structured firmware results; log wording is not an acceptance criterion."""
import argparse
import json
from pathlib import Path

RULE_GATES = {
    "iosBaseIs18": "iosBaseIs18", "iosBaseIs27": "iosBaseIs27",
    "cloudOSFridaCapable": "applyFrida", "excGuardActive": "excGuardActive",
}


def validate(report):
    errors = []
    if not isinstance(report, dict):
        return ["report must be an object"]
    if report.get("ablation") != []:
        errors.append("acceptance requires an non-ablation run with an explicit empty ablation list")
    gates = report.get("gates")
    if not isinstance(gates, dict):
        return errors + ["missing gate snapshot"]
    components = report.get("components")
    if not isinstance(components, list) or not components:
        return errors + ["missing component reports"]
    seen = set()
    for component in components:
        if not isinstance(component, dict):
            errors.append("component must be an object")
            continue
        if component.get("coverage") != "structured":
            errors.append(f"{component.get('component')}: legacy or unknown coverage")
        records, results = component.get("records"), component.get("results")
        if not isinstance(records, list) or not isinstance(results, list) or not results:
            errors.append("missing records/results arrays or empty result coverage")
            continue
        for result in results:
            if not isinstance(result, dict):
                errors.append("result must be an object")
                continue
            ident = result.get("id")
            if not isinstance(ident, str) or len(ident.split('.', 2)) != 3 or ident.endswith('.*'):
                errors.append("invalid method id")
                continue
            if ident in seen:
                errors.append(f"{ident}: duplicate method")
            seen.add(ident)
            if result.get("gates") != gates:
                errors.append(f"{ident}: inconsistent gate snapshot")
            requirement = result.get("requirement")
            required = requirement == "required"
            if requirement == "conditional":
                rule = result.get("rule")
                gate = RULE_GATES.get(rule)
                if rule == "always":
                    required = True
                elif gate and type(gates.get(gate)) is bool:
                    required = gates[gate]
                else:
                    errors.append(f"{ident}: unknown rule or missing Boolean gate")
            elif requirement not in ("required", "optional"):
                errors.append(f"{ident}: unknown requirement")
            outcome = result.get("outcome")
            if outcome not in ("applied", "alreadyApplied", "notApplicable"):
                errors.append(f"{ident}: {outcome}: {result.get('reason', '')}")
            if required and outcome not in ("applied", "alreadyApplied"):
                errors.append(f"{ident}: required method did not succeed")
            indices = result.get("recordIndices")
            if not isinstance(indices, list) or any(type(i) is not int or not 0 <= i < len(records) for i in indices):
                errors.append(f"{ident}: invalid record indices")
            elif outcome == "applied" and not indices:
                errors.append(f"{ident}: applied without a byte record")
    return errors


def validate_coverage(report, manifest):
    configurations = {
        cfg["variant"]: {c["component"].lower(): {m["name"] for m in c["methods"]}
                         for c in cfg["components"] if c["methods"]}
        for cfg in manifest["patch_configurations"]
    }
    variant = report.get("variant")
    observed = {}
    patchers = set()
    for component in report["components"]:
        for result in component["results"]:
            comp, patcher, method = result["id"].split(".", 2)
            observed.setdefault(comp, set()).add(method)
            patchers.add(patcher)
    if variant == "component":
        if len(patchers) != 1:
            return ["single-component report must contain exactly one patcher"]
        patcher = next(iter(patchers))
        regular = configurations["regular"]
        selections = {
            "KernelPatcher": {"kernelcache": regular["kernelcache"]},
            "KernelJBPatcher": {"kernelcache": configurations["jb"]["kernelcache"] - regular["kernelcache"]},
            "KernelEXPPatcher": {"kernelcache": configurations["exp"]["kernelcache"] - configurations["jb"]["kernelcache"]},
            "TXMPatcher": {"txm": regular["txm"]},
        }
        expected = selections.get(patcher)
    else:
        expected = configurations.get(variant)
    if expected is None:
        return ["unknown variant or single-component patcher"]
    if observed != expected:
        missing = {c: sorted(methods - observed.get(c, set())) for c, methods in expected.items()
                   if methods - observed.get(c, set())}
        extra = {c: sorted(methods - expected.get(c, set())) for c, methods in observed.items()
                 if methods - expected.get(c, set())}
        return [f"method coverage mismatch: missing={missing}, extra={extra}"]
    return []


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path)
    args = parser.parse_args()
    try:
        report = json.loads(args.report.read_text())
        errors = validate(report)
        if not errors:
            manifest_path = Path(__file__).resolve().parents[1] / "research/firmware_compatibility.json"
            errors += validate_coverage(report, json.loads(manifest_path.read_text()))
    except (OSError, ValueError, KeyError, TypeError) as error:
        errors = [str(error)]
    if errors:
        for error in errors:
            print(f"FAIL: {error}")
        return 1
    print(f"PASS: {sum(len(c['results']) for c in report['components'])} structured methods; "
          f"{sum(len(c['records']) for c in report['components'])} byte records")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
