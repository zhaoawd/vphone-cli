#!/usr/bin/env python3
"""Build the F1 support matrix (JSON and Markdown) from run.json evidence only.

Rows are exact combinations: combo ID, device, iOS/cloudOS version and build,
variant, options and tool commit. Records from different builds or commits are
never merged. Steps without evidence are shown as not_run; nothing is inferred
from other versions or variants.
"""

import argparse
import json
from pathlib import Path
import sys


SCHEMA_VERSION = 1
STATUSES = ("passed", "failed", "partial", "blocked", "not_applicable", "not_run")
COLUMNS = ("preflight", "S1", "S2", "S3", "S4", "S5", "S6", "S7", "S8", "S9", "S10", "S11", "S12")
EVIDENCE_REQUIRED = ("passed", "failed", "partial")
FRIDA_FIELDS = ("client_version", "server_version", "attach_target", "script_sha256", "messages")


class MatrixError(ValueError):
    pass


def collect_paths(inputs):
    paths = []
    for item in inputs:
        path = Path(item)
        if path.is_dir():
            paths.extend(sorted(path.rglob("run.json")))
        elif path.is_file():
            paths.append(path)
        else:
            raise MatrixError(f"input does not exist: {path}")
    if not paths:
        raise MatrixError("no run.json inputs found")
    return paths


def load_run(path):
    try:
        run = json.loads(Path(path).read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise MatrixError(f"{path}: unreadable run.json: {error}") from error
    if not isinstance(run, dict) or run.get("schema_version") != SCHEMA_VERSION:
        raise MatrixError(f"{path}: unsupported schema_version")
    for key in ("run_id", "combination", "tool", "steps"):
        if key not in run:
            raise MatrixError(f"{path}: missing {key}")
    combination = run["combination"]
    if not isinstance(combination, dict) or not combination.get("combo_id") or not combination.get("variant"):
        raise MatrixError(f"{path}: combination requires combo_id and variant")
    if not isinstance(run["steps"], list):
        raise MatrixError(f"{path}: steps must be a list")
    for step in run["steps"]:
        if not isinstance(step, dict) or step.get("id") not in COLUMNS:
            raise MatrixError(f"{path}: invalid step id {step.get('id') if isinstance(step, dict) else step!r}")
        if step.get("status") not in STATUSES:
            raise MatrixError(f"{path}: step {step['id']} has invalid status {step.get('status')!r}")
        if step["status"] in EVIDENCE_REQUIRED:
            evidence = step.get("evidence")
            if (not isinstance(evidence, list) or not evidence
                    or any(not isinstance(item, dict) or not item.get("path") or not item.get("sha256")
                           for item in evidence)):
                raise MatrixError(f"{path}: step {step['id']} status {step['status']} lacks evidence digests")
    return run


def row_key(run):
    combination = run["combination"]
    ios = combination.get("ios") or {}
    cloudos = combination.get("cloudos") or {}
    return (
        combination["combo_id"], combination.get("device"),
        ios.get("version"), ios.get("build"),
        cloudos.get("version"), cloudos.get("build"),
        combination["variant"],
        json.dumps(combination.get("options") or {}, sort_keys=True),
        (run.get("tool") or {}).get("git_commit"),
    )


def effective_status(step):
    """Apply generator rules that must not rely on the producing script."""
    status = step["status"]
    notes = []
    if step["id"] == "S11" and status == "passed":
        observed = step.get("observed") or {}
        missing = [field for field in FRIDA_FIELDS if not observed.get(field)]
        if missing:
            status = "partial"
            notes.append(f"S11 passed without {missing}; downgraded to partial")
    return status, notes


def build_matrix(runs):
    rows = {}
    for run in runs:
        key = row_key(run)
        combination = run["combination"]
        row = rows.setdefault(key, {
            "combo_id": combination["combo_id"],
            "device": combination.get("device"),
            "ios": {k: (combination.get("ios") or {}).get(k) for k in ("version", "build")},
            "cloudos": {k: (combination.get("cloudos") or {}).get(k) for k in ("version", "build")},
            "variant": combination["variant"],
            "options": combination.get("options") or {},
            "git_commit": (run.get("tool") or {}).get("git_commit"),
            "worktree_clean": set(),
            "runs": [],
            "launch": [],
            "cells": {column: {"status": "not_run", "run_id": None, "finished_at": None,
                               "expectation": None, "notes": [], "history": []}
                      for column in COLUMNS},
        })
        row["worktree_clean"].add((run.get("tool") or {}).get("worktree_clean"))
        row["runs"].append(run["run_id"])
        launch = run.get("launch")
        if isinstance(launch, dict):
            row["launch"].append({"run_id": run["run_id"], **launch})
        for step in run["steps"]:
            status, notes = effective_status(step)
            cell = row["cells"][step["id"]]
            failure = step.get("failure") if isinstance(step.get("failure"), dict) else {}
            cell["history"].append({"run_id": run["run_id"], "status": status,
                                    "finished_at": step.get("finished_at"),
                                    "classification": failure.get("classification")})
            if status == "not_run":
                continue
            if cell["finished_at"] is None or (step.get("finished_at") or "") >= cell["finished_at"]:
                cell.update({"status": status, "run_id": run["run_id"],
                             "finished_at": step.get("finished_at"),
                             "expectation": step.get("expectation"), "notes": notes,
                             "reason": step.get("reason") or failure.get("reason"),
                             "classification": failure.get("classification")})
    ordered = []
    for key in sorted(rows, key=lambda item: tuple("" if part is None else str(part) for part in item)):
        row = rows[key]
        clean = row.pop("worktree_clean")
        row["worktree_clean"] = clean.pop() if len(clean) == 1 else None
        ordered.append(row)
    return {"schema_version": SCHEMA_VERSION, "columns": list(COLUMNS),
            "selection_rule": "latest non-not_run record per exact combination and step; "
                              "records from other builds, options or commits are separate rows",
            "rows": ordered}


def cell_text(cell):
    text = cell["status"]
    if cell.get("expectation") == "absent" and cell["status"] != "not_run":
        text += " (negative)"
    if cell.get("classification"):
        text += " *"
    return text


def row_label(row):
    return (f"{row['combo_id']} {row['variant']} {row['ios'].get('version') or '?'}/"
            f"{row['ios'].get('build') or '?'} @{(row['git_commit'] or '?')[:12]}")


def launch_text(entry):
    mode = entry.get("declared_mode") or "undeclared"
    return f"launch={mode}, screen_available={entry.get('screen_available')!r}"


def render_markdown(matrix):
    header = ["Combo", "Device", "iOS", "cloudOS", "Variant", "Options", "Commit"] + matrix["columns"]
    lines = ["| " + " | ".join(header) + " |", "| " + " | ".join("---" for _ in header) + " |"]
    for row in matrix["rows"]:
        options = ", ".join(f"{key}={value}" for key, value in sorted(row["options"].items())
                            if value not in (None, False)) or "-"
        values = [
            row["combo_id"], row["device"] or "-",
            f"{row['ios'].get('version') or '?'}/{row['ios'].get('build') or '?'}",
            f"{row['cloudos'].get('version') or '?'}/{row['cloudos'].get('build') or '?'}",
            row["variant"], options, (row["git_commit"] or "?")[:12],
        ] + [cell_text(row["cells"][column]) for column in matrix["columns"]]
        lines.append("| " + " | ".join(str(value) for value in values) + " |")
    notes = []
    for row in matrix["rows"]:
        for entry in row.get("launch", []):
            notes.append(f"- {row_label(row)}: run `{entry['run_id']}` {launch_text(entry)}")
        for column in matrix["columns"]:
            cell = row["cells"][column]
            if cell.get("classification"):
                notes.append(f"- {row_label(row)}: {column} {cell['status']} "
                             f"classification=`{cell['classification']}` (run `{cell['run_id']}`)")
            for note in cell.get("notes", []):
                notes.append(f"- {row_label(row)}: {column} {note}")
    lines.append("")
    lines.append("Cells come only from run.json evidence; `(negative)` marks absence checks that do "
                 "not count as functional passes.")
    if notes:
        lines.append("")
        lines.append("Notes:")
        lines.append("")
        lines.extend(notes)
    return "\n".join(lines) + "\n"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("inputs", nargs="+", help="run.json files or directories searched recursively")
    parser.add_argument("--json-out", type=Path)
    parser.add_argument("--md-out", type=Path)
    args = parser.parse_args(argv)
    try:
        runs = [load_run(path) for path in collect_paths(args.inputs)]
    except MatrixError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    matrix = build_matrix(runs)
    markdown = render_markdown(matrix)
    if args.json_out:
        args.json_out.write_text(json.dumps(matrix, indent=2, sort_keys=True) + "\n")
    if args.md_out:
        args.md_out.write_text(markdown)
    if not args.json_out and not args.md_out:
        sys.stdout.write(markdown)
    return 0


if __name__ == "__main__":
    sys.exit(main())
