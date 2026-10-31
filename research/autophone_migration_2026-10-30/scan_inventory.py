#!/usr/bin/env python3
"""Read-only source inventory; JSON is written only to stdout.

This scans literal Python dictionaries, not runtime call graphs. --check verifies
the saved source hashes, migration IDs (M01-M32), historical reconciliation IDs
(H01-H22), and Markdown links without importing project modules.
"""
from __future__ import annotations

import argparse
import ast
from collections import Counter, defaultdict
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import subprocess
from zoneinfo import ZoneInfo

HERE = Path(__file__).resolve().parent
LOCAL = HERE.parents[1]
ROOTS = {"local": LOCAL, "autophone": LOCAL.parent / "autophone",
         "upstream": LOCAL.parent / "vphone-cli-up"}
MAPPING = {
    "capabilities": "M03", "ping": "M04", "screenshot": "M05",
    "tap": "M06", "swipe": "M06", "key": "M06", "type": "M07",
    "shell": "M08", "file_get": "M09", "file_put": "M09",
    "app_list": "M10", "app_foreground": "M10", "app_launch": "M11",
    "app_terminate": "M11", "ipa_install": "M12",
    "location": "M13", "location_stop": "M13",
    "location_source_set": "M14", "location_source_control": "M14",
    "location_source_status": "M14", "location_source_stop": "M14",
    "location_stream_start": "M15", "location_stream_push": "M15",
    "camera_present": "M16", "camera_status": "M16", "camera_stop": "M16",
}
DISPATCH = {
    "local": ("sources/vphone-cli/VPhoneHostCommandExecutor.swift", 8),
    "upstream": ("VPhoneExecutable/VPhoneVirtualization/UI/VPhoneHostAutomationServer.swift", 12),
}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def git(root, *args):
    result = subprocess.run(["git", "-C", str(root), *args], text=True,
                            capture_output=True, check=True)
    return result.stdout.strip(), result.stderr.strip()


def locate(path):
    path = path.resolve()
    for name, root in ROOTS.items():
        if path.is_relative_to(root.resolve()):
            return name, path.relative_to(root.resolve()).as_posix()
    raise ValueError(f"source outside the three repositories: {path}")


def links():
    result = set()
    for target in re.findall(r"\]\(([^)]+)\)", (HERE / "README.md").read_text()):
        if "://" in target or target.startswith("#"):
            continue
        path = (HERE / target.split("#", 1)[0]).resolve()
        if not path.exists():
            raise ValueError(f"missing document link: {target}")
        if path.is_file() and path.parent != HERE:
            if path.name == "TODO.md":
                raise ValueError("TODO.md must not be read")
            result.add(path)
    return result


def collect_local_git_sampling(local_root):
    status_all, _ = git(local_root, "status", "--porcelain=v1", "-uall", "--", ".", ":!TODO.md")
    tracked_dirty = []
    untracked_non_research = []
    untracked_total = 0
    for line in status_all.splitlines():
        if line.startswith("?? "):
            rel = line[3:]
            untracked_total += 1
            if not rel.startswith("research/") and not rel.startswith(".claude/"):
                untracked_non_research.append(rel)
        elif line:
            tracked_dirty.append(line)
    stashes, _ = git(local_root, "stash", "list")
    worktrees_raw, _ = git(local_root, "worktree", "list", "--porcelain")
    worktrees = [line[9:] for line in worktrees_raw.splitlines() if line.startswith("worktree ")]
    return {
        "tracked_modified_count": len(tracked_dirty),
        "untracked_expanded_total_count": untracked_total,
        "untracked_non_research_count": len(untracked_non_research),
        "untracked_non_research_paths": sorted(untracked_non_research),
        "stash_count": len(stashes.splitlines()) if stashes else 0,
        "worktree_paths": worktrees,
    }


def collect():
    repos = {}
    for name, root in ROOTS.items():
        head, _ = git(root, "rev-parse", "HEAD")
        branch, _ = git(root, "branch", "--show-current")
        status, warnings = git(root, "status", "--porcelain", "--untracked-files=no", "--", ".", ":!TODO.md")
        entry = {"path": str(root), "head": head, "branch": branch,
                 "tracked_status_entries": len(status.splitlines()),
                 "status_scope": "tracked only; untracked content is represented in local_git_sampling or when scanned/linked",
                 "warnings": warnings}
        if name == "local":
            entry["local_git_sampling"] = collect_local_git_sampling(root)
        repos[name] = entry
    occurrences = defaultdict(list)
    noncommands = []
    dynamic = []
    failures = []
    scanned = Counter()
    sources = links()
    scan_hashes = []
    for scope in ("autophone", "tools", "scripts"):
        for path in sorted((ROOTS["autophone"] / scope).rglob("*.py")):
            relative = path.relative_to(ROOTS["autophone"]).as_posix()
            if ".venv" in path.parts or "__pycache__" in path.parts:
                continue
            scanned[scope] += 1
            try:
                content = path.read_bytes()
                scan_hashes.append({"path": relative, "sha256": hashlib.sha256(content).hexdigest()})
                tree = ast.parse(content, filename=relative)
            except (SyntaxError, UnicodeError, OSError) as exc:
                failures.append({"path": relative, "error": str(exc)})
                continue
            for node in ast.walk(tree):
                if not isinstance(node, ast.Dict):
                    continue
                for key, value in zip(node.keys, node.values):
                    if not isinstance(key, ast.Constant) or key.value != "t":
                        continue
                    hit = {"path": relative, "line": node.lineno, "scope": scope}
                    if isinstance(value, ast.Constant) and isinstance(value.value, str):
                        if value.value in MAPPING:
                            occurrences[value.value].append(hit)
                            sources.add(path.resolve())
                        else:
                            noncommands.append({**hit, "value": value.value})
                    elif not isinstance(value, ast.Constant):
                        dynamic.append({**hit, "expression": ast.unparse(value)})
    dispatch = {}
    for name, (relative, indent) in DISPATCH.items():
        path = ROOTS[name] / relative
        content = path.read_text()
        # Exact indentation selects the command switch, not nested key names.
        cases = []
        pattern = r"^" + " " * indent + r"case ((?:\"[^\"]+\"[, \n]*)+):"
        for match in re.finditer(pattern, content, re.M):
            cases.extend(re.findall(r'"([^\"]+)"', match.group(1)))
        extras = {"rpc": "pre-switch forwarding"} if name == "local" else {"shell": "shellRequest/relayShell interactive interception"}
        dispatch[name] = {"path": relative, "switch_commands": sorted(set(cases)),
                          "other_entries": extras,
                          "limitation": "local environment_* delegation is outside the switch; capabilities are not inferred from command presence"}
        sources.add(path.resolve())
    return {
        "schema": "autophone-migration-inventory/v1",
        "collected_at": datetime.now(ZoneInfo("Asia/Shanghai")).isoformat(),
        "repositories": repos,
        "inventory_documents": [{"path": name, "sha256": digest(HERE / name)}
                                for name in ("README.md", "scan_inventory.py")],
        "scan_scope": {"python_files": dict(scanned), "parse_failures": failures,
                       "limitations": ["literal t dictionaries only; not runtime frequency or reachability",
                                      "shell-embedded Python, JS, config and external plugins not exhaustively parsed",
                                      "dynamic t expressions require manual review; numeric timestamp values excluded",
                                      "command mapping is curated; unrecognized string values retained for review"]},
        "commands": [{"command": name, "migration_id": MAPPING[name],
                      "occurrences": sorted(hits, key=lambda h: (h["path"], h["line"]))}
                     for name, hits in sorted(occurrences.items())],
        "unrecognized_string_t": noncommands, "dynamic_t": dynamic,
        "host_dispatch": dispatch,
        "python_scan_inputs": scan_hashes,
        "sources": [{"repository": repo, "path": rel, "sha256": digest(path)}
                    for path in sorted(sources) for repo, rel in [locate(path)]],
    }


def check(path):
    saved = json.loads(path.read_text())
    assert saved["schema"] == "autophone-migration-inventory/v1"
    assert not saved["scan_scope"]["parse_failures"], saved["scan_scope"]["parse_failures"]
    linked = links()
    doc = (HERE / "README.md").read_text()
    ids = re.findall(r"^\| (M\d{2}) \|", doc, re.M)
    assert sorted(ids) == [f"M{index:02}" for index in range(1, 33)], "missing or duplicate migration ID"
    h_ids = re.findall(r"^\| (H\d{2}) \|", doc, re.M)
    assert sorted(h_ids) == [f"H{index:02}" for index in range(1, 23)], "missing or duplicate historical reconciliation ID"
    for item in saved["inventory_documents"]:
        assert digest(HERE / item["path"]) == item["sha256"], f"changed inventory document: {item['path']}"
    for item in saved["unrecognized_string_t"]:
        assert item["value"] == "\t", f"unmapped string t: {item}"
    for item in saved["sources"]:
        source = ROOTS[item["repository"]] / item["path"]
        assert digest(source) == item["sha256"], f"changed source: {source}"
    for item in saved["python_scan_inputs"]:
        source = ROOTS["autophone"] / item["path"]
        assert digest(source) == item["sha256"], f"changed scan input: {source}"
    recorded = {(s["repository"], s["path"]) for s in saved["sources"]}
    assert all(locate(p) in recorded for p in linked), "linked source missing from snapshot"
    for command in saved["commands"]:
        assert command["migration_id"] == MAPPING[command["command"]]
        assert f'| {command["migration_id"]} |' in doc, command["migration_id"]
    for name, repo in saved["repositories"].items():
        assert git(ROOTS[name], "rev-parse", "HEAD")[0] == repo["head"], f"HEAD changed: {name}"
    print(json.dumps({"result": "pass", "mapped_commands": len(saved["commands"]),
                      "migration_ids": len(ids), "historical_ids": len(h_ids),
                      "source_hashes": len(saved["sources"]),
                      "scan_input_hashes": len(saved["python_scan_inputs"]),
                      "linked_sources": len(linked), "product_tests_run": False}, ensure_ascii=False))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", type=Path)
    args = parser.parse_args()
    if args.check:
        check(args.check)
    else:
        print(json.dumps(collect(), ensure_ascii=False, indent=2))
