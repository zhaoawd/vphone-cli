#!/usr/bin/env python3
"""Generate/check/apply the reviewed P1c edits. Default: CHECK ONLY.

No reset, checkout, commit, push, dependency installation or VM operation.
Touched tracked files must match the fixed baseline in both worktree and index.
Other files, including the two locally revised research documents, are untouched.
"""
from __future__ import annotations

import argparse
import difflib
import hashlib
import json
from pathlib import Path, PurePosixPath
import subprocess
import sys


class Refused(RuntimeError):
    pass


def git(repo: Path, *args: str, input_bytes: bytes | None = None) -> bytes:
    result = subprocess.run(["git", "-C", str(repo), *args], input=input_bytes,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if result.returncode:
        raise Refused(f"git {' '.join(args)} failed ({result.returncode}):\n"
                      + result.stderr.decode("utf-8", errors="replace"))
    return result.stdout


def safe_path(repo: Path, relative: str) -> Path:
    path = PurePosixPath(relative)
    if path.is_absolute() or not path.parts or any(p in ("..", ".git") for p in path.parts):
        raise Refused(f"Unsafe package path: {relative}")
    if relative == "TODO.md":
        raise Refused("Repository-root TODO.md is outside this task")
    cursor = repo
    for part in path.parts:
        cursor = cursor / part
        if cursor.is_symlink():
            raise Refused(f"Refusing a symlink path: {cursor}")
    return cursor


def make_patch(repo: Path, package: Path, stage: str) -> tuple[bytes, list[str]]:
    manifest = json.loads((package / "changes.json").read_text(encoding="utf-8"))
    base = manifest["base_commit"]
    git(repo, "cat-file", "-e", f"{base}^{{commit}}")
    git(repo, "merge-base", "--is-ancestor", base, "HEAD")
    stages = {"nvram", "clone"} if stage == "all" else {stage}
    replacements: dict[str, list[dict[str, str]]] = {}
    for change in manifest["changes"]:
        if change["stage"] in stages:
            replacements.setdefault(change["path"], []).append(change)
    new_paths = [path for key, values in manifest["new_files"].items() if key in stages for path in values]
    touched = list(replacements) + new_paths
    for relative in touched:
        safe_path(repo, relative)
    diff: list[str] = []
    for relative, edits in replacements.items():
        path = safe_path(repo, relative)
        if not path.is_file():
            raise Refused(f"Missing tracked file: {relative}")
        before_bytes = git(repo, "show", f"{base}:{relative}")
        if path.read_bytes() != before_bytes:
            raise Refused(f"{relative} differs from baseline {base[:7]}; not overwriting local/newer edits")
        if git(repo, "show", f":{relative}") != before_bytes:
            raise Refused(f"{relative} has staged changes; preserve/reconcile them before applying")
        before = before_bytes.decode("utf-8")
        after = before
        for edit in edits:
            if after.count(edit["before"]) != 1:
                raise Refused(f"Reviewed source block is not unique/exact in {relative}")
            after = after.replace(edit["before"], edit["after"], 1)
        diff.append(f"diff --git a/{relative} b/{relative}\n")
        diff.extend(difflib.unified_diff(before.splitlines(keepends=True), after.splitlines(keepends=True),
                                         fromfile=f"a/{relative}", tofile=f"b/{relative}"))
    for relative in new_paths:
        destination = safe_path(repo, relative)
        if destination.exists() or destination.is_symlink():
            raise Refused(f"New file already exists: {relative}")
        if git(repo, "ls-files", "--", relative).strip():
            raise Refused(f"New file is already tracked, possibly deleted locally: {relative}")
        payload = (package / "files" / relative).read_bytes()
        expected = manifest.get("payload_sha256", {}).get(relative)
        if expected is None or hashlib.sha256(payload).hexdigest() != expected:
            raise Refused(f"Package payload checksum mismatch: {relative}")
        after = payload.decode("utf-8")
        diff.append(f"diff --git a/{relative} b/{relative}\nnew file mode 100644\n")
        diff.extend(difflib.unified_diff([], after.splitlines(keepends=True),
                                         fromfile="/dev/null", tofile=f"b/{relative}"))
    return "".join(diff).encode("utf-8"), touched


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True, type=Path)
    parser.add_argument("--stage", choices=["all", "nvram", "clone"], default="all")
    parser.add_argument("--apply", action="store_true", help="apply after all preconditions and git apply --check pass")
    parser.add_argument("--patch-out", type=Path, help="save the computed patch to a NEW file")
    args = parser.parse_args()
    package = Path(__file__).resolve().parent
    try:
        requested = args.repo.resolve(strict=True)
        repo = Path(git(requested, "rev-parse", "--show-toplevel").decode().strip()).resolve()
        if requested != repo:
            raise Refused("--repo must be the repository root")
        patch, paths = make_patch(repo, package, args.stage)
        git(repo, "apply", "--check", "--whitespace=error-all", "-", input_bytes=patch)
        if args.patch_out:
            target = args.patch_out.resolve()
            if target == repo or repo in target.parents:
                raise Refused("--patch-out must be outside the repository")
            with target.open("xb") as stream:
                stream.write(patch)
        print(f"CHECK PASSED: {len(paths)} paths; stage={args.stage}")
        for path in paths:
            print(f"  {path}")
        if args.apply:
            # git apply rejects the whole patch on a mismatch; no --reject/--3way/--unsafe-paths.
            git(repo, "apply", "--whitespace=error-all", "-", input_bytes=patch)
            print("APPLIED to this worktree only. No commits, push, build or VM acceptance performed.")
        else:
            print("CHECK ONLY: repository files were not changed.")
        return 0
    except (Refused, OSError, ValueError, KeyError, UnicodeError) as error:
        print(f"REFUSED: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
