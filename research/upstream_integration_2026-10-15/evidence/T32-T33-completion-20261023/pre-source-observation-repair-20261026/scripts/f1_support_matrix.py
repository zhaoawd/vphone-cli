#!/usr/bin/env python3
"""Build the F1 support matrix (JSON and Markdown) from recorded evidence only.

Rows are exact combinations: combo ID, device, iOS/cloudOS version and build,
variant, options and tool commit. Records from different builds or commits are
never merged. Steps without evidence are shown as not_run; nothing is inferred
from other versions or variants.

Optional inputs bind evidence to one VM instance per combination spec
(`<combo>:<variant>[:<options>]`, for example `N:exp:frida`):

  --create-status SPEC=PATH  vm create-status JSON or raw checkpoint.json; derives S1-S3
                             and binds run.json records whose --bundle/--socket
                             belongs to the same bundle
  --manual SPEC=PATH         hand-written manual_results.json; S5/S7/S8/S10/S11/...
  --jb-setup-log SPEC=PATH   guest /var/log/vphone_jb_setup.log copy (jb/exp S3)
  --limits PATH              known limits / open issues / excluded combinations

Cell selection: manual records outrank run.json and checkpoint records; within
one rank the latest record wins. A failed record is never replaced by a record
that is older than it. Every candidate is kept in the cell for review.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import sys


SCHEMA_VERSION = 1
STATUSES = ("passed", "failed", "partial", "blocked", "not_applicable", "not_run")
COLUMNS = ("preflight", "S1", "S2", "S3", "S4", "S5", "S6", "S7", "S8", "S9", "S10", "S11", "S12")
EVIDENCE_REQUIRED = ("passed", "failed", "partial")
FRIDA_FIELDS = ("client_version", "server_version", "attach_target", "script_sha256", "messages")

VARIANTS = ("regular", "dev", "jb", "exp", "less")
OPTION_TOKENS = ("frida",)
SOURCE_RANK = {"auto": 1, "checkpoint": 1, "manual": 2}
JB_FINALIZE_MARKER = "=== vphone_jb_setup.sh complete ==="
FAILED_OVERALL = ("failed", "cancelled", "interrupted", "incomplete", "recovery_required")
# Plan §2.1 combination definitions and §3.2 S1 historical patch record counts.
COMBINATIONS = {
    "P": {"device": "iPhone17,3", "ios": ("26.1", "23B85"), "cloudos": ("26.1", "23B85"),
          "patch_records": {"regular": 58, "dev": 70, "jb": 152, "exp": 178, "less": 26},
          "note": None},
    "N": {"device": "iPhone17,3", "ios": ("26.6.1", "23G82"), "cloudos": ("26.4", "23E5207q"),
          "patch_records": {},
          "note": "iOS 23G82 为非 catalog 构建（catalog 配对为 23G83），经本地路径指定"},
    "L": {"device": "iPhone17,3", "ios": ("18.6.2", "22G100"), "cloudos": ("26.1", "23B85"),
          "patch_records": {}, "note": None},
}
MANUAL_TOP_KEYS = ("vm", "variant", "combo", "options", "recorded_at", "frida", "setup_assistant")
MANUAL_STEP_KEY = re.compile(r"^(S(?:1[0-2]|[1-9]))(?:_([a-z][a-z_]*))?$")
MANUAL_STATUS = re.compile(r"^(passed|failed|partial|blocked|not_applicable|not_run)(?:\s*\((.*)\))?$", re.S)
MANUAL_META_KEYS = ("status", "evidence", "run", "source")


class MatrixError(ValueError):
    pass


# MARK: - run.json inputs

def collect_paths(inputs, allow_empty=False):
    paths = []
    for item in inputs:
        path = Path(item)
        if path.is_dir():
            paths.extend(sorted(path.rglob("run.json")))
        elif path.is_file():
            paths.append(path)
        else:
            raise MatrixError(f"input does not exist: {path}")
    if not paths and not allow_empty:
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


def auto_candidates(run, run_path=None):
    launch = run.get("launch") if isinstance(run.get("launch"), dict) else {}
    for step in run["steps"]:
        status, notes = effective_status(step)
        failure = step.get("failure") if isinstance(step.get("failure"), dict) else {}
        yield step["id"], {
            "source": "auto", "ref": run["run_id"],
            "label": Path(run_path).parent.name if run_path else run["run_id"],
            "path": display_path(run_path) if run_path else None,
            "status": status, "time": step.get("finished_at"),
            "expectation": step.get("expectation"),
            "classification": failure.get("classification"),
            "reason": step.get("reason") or failure.get("reason"),
            "launch_mode": launch.get("declared_mode"),
            "notes": notes,
        }


# MARK: - Helpers

def display_path(path):
    path = Path(path)
    try:
        return str(path.resolve().relative_to(Path.cwd().resolve()))
    except ValueError:
        return str(path)


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def time_key(value):
    if not value:
        return datetime.min.replace(tzinfo=timezone.utc)
    text = str(value).strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError as error:
        raise MatrixError(f"invalid timestamp {value!r}") from error
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


def parse_spec(text):
    parts = text.split(":")
    if len(parts) not in (2, 3) or not parts[0] or not parts[1]:
        raise MatrixError(f"invalid combination spec {text!r}; expected <combo>:<variant>[:<options>]")
    combo, variant = parts[0], parts[1]
    if combo not in COMBINATIONS:
        raise MatrixError(f"unknown combination {combo!r} in spec {text!r}")
    if variant not in VARIANTS:
        raise MatrixError(f"unknown variant {variant!r} in spec {text!r}")
    options = ()
    if len(parts) == 3:
        tokens = [token for token in parts[2].split(",") if token]
        if not tokens or any(token not in OPTION_TOKENS for token in tokens):
            raise MatrixError(f"unsupported options in spec {text!r}; allowed: {', '.join(OPTION_TOKENS)}")
        options = tuple(sorted(set(tokens)))
    return (combo, variant, options)


def spec_label(spec):
    combo, variant, options = spec
    return f"{combo}:{variant}" + (f":{','.join(options)}" if options else "")


def parse_assignment(text, flag):
    if "=" not in text:
        raise MatrixError(f"{flag} expects SPEC=PATH, got {text!r}")
    spec_text, path_text = text.split("=", 1)
    spec = parse_spec(spec_text)
    path = Path(path_text)
    if not path.is_file():
        raise MatrixError(f"{flag} {spec_label(spec)}: file does not exist: {path}")
    return spec, path


def load_json(path, what):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise MatrixError(f"{path}: unreadable {what}: {error}") from error


def run_bundle(run):
    argv = (run.get("invocation") or {}).get("argv") or []

    def value(flag):
        return argv[argv.index(flag) + 1] if flag in argv and argv.index(flag) + 1 < len(argv) else None

    bundle = value("--bundle")
    if bundle is None and value("--socket"):
        bundle = str(Path(value("--socket")).parent)
    return os.path.normpath(os.path.abspath(bundle)) if bundle else None


# MARK: - Create checkpoint

def overall_from_stages(checkpoint):
    """Mirror VPhoneCreateCheckpoint.overallStatus for raw checkpoint files."""
    if checkpoint.get("recovery_required"):
        return "recovery_required"
    statuses = [stage.get("status") for stage in checkpoint.get("stages") or []]
    for status, overall in (("failed", "failed"), ("cancelled", "cancelled"), ("running", "interrupted")):
        if status in statuses:
            return overall
    if not all(status in ("succeeded", "unverified", "not_applicable") for status in statuses):
        return "incomplete"
    return "completed_unverified" if "unverified" in statuses else "succeeded"


def load_create_status(spec, path):
    document = load_json(path, "create status")
    if not isinstance(document, dict):
        raise MatrixError(f"{path}: create status must be an object")
    checkpoint = document.get("checkpoint") if "checkpoint" in document else document
    if (not isinstance(checkpoint, dict) or checkpoint.get("schema_version") != 1
            or not isinstance(checkpoint.get("stages"), list)
            or not isinstance(checkpoint.get("effective_options"), dict)):
        raise MatrixError(f"{path}: not a create checkpoint (schema_version 1 with stages and effective_options)")
    options = checkpoint["effective_options"]
    combo, variant, spec_options = spec
    if options.get("variant") != variant:
        raise MatrixError(f"{path}: checkpoint variant {options.get('variant')!r} does not match spec "
                          f"{spec_label(spec)}")
    if bool(options.get("enable_frida")) != ("frida" in spec_options):
        raise MatrixError(f"{path}: checkpoint enable_frida={options.get('enable_frida')!r} does not match spec "
                          f"{spec_label(spec)}")
    bundle = document.get("bundle") or (checkpoint.get("bundle_identity") or {}).get("path")
    derived = overall_from_stages(checkpoint)
    recorded = document.get("overall_status")
    return {
        "path": path, "checkpoint": checkpoint,
        "bundle": os.path.normpath(bundle) if bundle else None,
        "vm_name": (checkpoint.get("bundle_identity") or {}).get("name") or (Path(bundle).name if bundle else None),
        "overall": recorded or derived, "overall_recorded": recorded is not None, "overall_derived": derived,
        "stages": {stage.get("stage"): stage for stage in checkpoint["stages"]},
        "tool_sha256": (checkpoint.get("tool") or {}).get("executable_sha256"),
        "attempts": len(checkpoint.get("attempts") or []),
    }


def checkpoint_candidates(spec, create, jb_log=None):
    combo, variant, _ = spec
    definition = COMBINATIONS[combo]
    stages = create["stages"]
    ref = display_path(create["path"])

    def candidate(column, status, time, notes, supplement=None):
        return column, {"source": "checkpoint", "ref": ref, "path": ref, "status": status, "time": time,
                        "expectation": None, "classification": None, "reason": None,
                        "supplement": supplement, "notes": notes}

    def stage(name):
        return stages.get(name) or {}

    # S1: prepare / patch / cfw and overall status.
    prepare, patch, cfw = stage("prepare"), stage("patch"), stage("cfw")
    notes = [f"overall_status={create['overall']}"
             + ("" if create["overall_recorded"] else "（由阶段状态推导）")]
    if create["attempts"] > 1:
        notes.append(f"attempts={create['attempts']}；采用各阶段最终记录")
    s1_statuses = [prepare.get("status"), patch.get("status"), cfw.get("status")]
    evidence = prepare.get("evidence") or {}
    observed_ios = (evidence.get("ios_version"), evidence.get("ios_build"))
    observed_cloud = (evidence.get("cloudos_version"), evidence.get("cloudos_build"))
    records = (patch.get("evidence") or {}).get("patch_records")
    expected_records = definition["patch_records"].get(variant)
    if create["overall"] in FAILED_OVERALL or any(s in ("failed", "cancelled") for s in s1_statuses):
        s1 = "failed"
    elif any(s is None or s == "running" for s in s1_statuses):
        s1 = "not_run" if all(s is None for s in s1_statuses) else "failed"
    elif observed_ios != definition["ios"] or observed_cloud != definition["cloudos"]:
        s1 = "failed"
        notes.append(f"prepare 版本 iOS {observed_ios[0]}/{observed_ios[1]}、cloudOS {observed_cloud[0]}/"
                     f"{observed_cloud[1]} 与组合 {combo} 定义不一致")
    else:
        s1 = "passed"
        notes.append(f"prepare iOS {observed_ios[0]}/{observed_ios[1]}、cloudOS {observed_cloud[0]}/"
                     f"{observed_cloud[1]} 与组合 {combo} 定义一致")
        unverified = [name for name, item in stages.items()
                      if item.get("status") == "unverified" and name not in ("jb_finalize", "verification")]
        if unverified or any(s not in ("succeeded", "not_applicable") for s in s1_statuses):
            s1 = "partial"
            notes.append(f"创建阶段未全部 succeeded：{unverified or s1_statuses}")
        if cfw.get("status") == "not_applicable":
            notes.append(f"cfw not_applicable（{cfw.get('reason')}）")
    if records is not None:
        if expected_records is None:
            notes.append(f"patch_records={records}；无同输入历史值可比较")
        elif str(records) == str(expected_records):
            notes.append(f"patch_records={records}，与历史值一致")
        else:
            notes.append(f"patch_records={records}，历史值 {expected_records}，差异未解释")
            if s1 == "passed":
                s1 = "partial"
    yield candidate("S1", s1, patch.get("finished_at") or prepare.get("finished_at"), notes)

    # S2: restore evidence.
    restore = stage("restore")
    restore_evidence = restore.get("evidence") or {}
    notes = [f"restore status={restore.get('status')}, restore_update_exit="
             f"{restore_evidence.get('restore_update_exit')}, post_restore_dfu_outcome="
             f"{restore_evidence.get('post_restore_dfu_outcome')}"]
    exit_code = restore_evidence.get("restore_update_exit")
    if not restore or restore.get("status") in (None, "pending"):
        s2 = "not_run"
    elif restore.get("status") in ("failed", "cancelled", "running") or (exit_code is not None
                                                                         and str(exit_code) != "0"):
        s2 = "failed"
    elif (restore.get("status") == "succeeded" and str(exit_code) == "0"
          and restore_evidence.get("post_restore_dfu_outcome") == "matched"):
        s2 = "passed"
    else:
        s2 = "partial"
    yield candidate("S2", s2, restore.get("finished_at"), notes)

    # S3: first boot prompt, verification and (jb/exp) JB finalization.
    first_boot, verification, finalize = stage("first_boot"), stage("verification"), stage("jb_finalize")
    notes = [f"first_boot status={first_boot.get('status')}, prompt="
             f"{(first_boot.get('evidence') or {}).get('prompt')}; verification status={verification.get('status')}"]
    supplement = None
    if not first_boot or first_boot.get("status") in (None, "pending"):
        s3 = "not_run"
    elif (first_boot.get("status") in ("failed", "cancelled", "running")
          or verification.get("status") in ("failed", "cancelled", "running")):
        s3 = "failed"
    elif first_boot.get("status") == "succeeded" and (first_boot.get("evidence") or {}).get("prompt") == "matched":
        s3 = "passed"
        if verification.get("status") != "succeeded":
            s3 = "partial"
            notes.append(f"verification {verification.get('status')}（{verification.get('reason')}）")
    else:
        s3 = "partial"
    if variant in ("jb", "exp") and s3 != "not_run":
        finalize_status = finalize.get("status")
        if finalize_status == "unverified":
            notes.append("jb_finalize unverified：检查点按设计不读取客户机收尾日志")
            if jb_log is None:
                if s3 == "passed":
                    s3 = "partial"
                notes.append("未提供 JB 收尾日志，收尾完成未确认")
            elif jb_log["complete"]:
                supplement = "manual"
                notes.append(f"JB 收尾完成标记见人工取回日志 `{display_path(jb_log['path'])}`")
            else:
                supplement = "manual"
                if s3 == "passed":
                    s3 = "partial"
                notes.append(f"人工取回日志 `{display_path(jb_log['path'])}` 无完成标记")
        elif finalize_status in ("failed", "cancelled"):
            s3 = "failed"
            notes.append(f"jb_finalize {finalize_status}")
    yield candidate("S3", s3, verification.get("finished_at") or first_boot.get("finished_at"), notes, supplement)


# MARK: - Manual results

def parse_manual_status(value, where):
    if not isinstance(value, str):
        raise MatrixError(f"{where}: status must be a string")
    match = MANUAL_STATUS.match(value.strip())
    if not match:
        raise MatrixError(f"{where}: invalid status {value!r}")
    qualifier = match.group(2)
    expectation = "absent" if qualifier and "negative" in qualifier else None
    return match.group(1), expectation, qualifier


def resolve_evidence(reference, vm_dir):
    token = str(reference).split(" ")[0]
    record = {"ref": reference}
    if "{" in token:
        record["state"] = "unresolved"
        return record
    for base in (vm_dir, Path.cwd()):
        target = base / token
        if any(char in token for char in "*?["):
            matches = sorted(base.glob(token))
            if matches:
                record.update(path=display_path(base / token), state="glob", matches=len(matches))
                return record
            continue
        if target.is_file():
            record.update(path=display_path(target), state="file", sha256=sha256_file(target))
            return record
        if target.is_dir():
            run_json = target / "run.json"
            if run_json.is_file():
                record.update(path=display_path(run_json), state="file", sha256=sha256_file(run_json))
            else:
                record.update(path=display_path(target), state="directory")
            return record
    record["state"] = "missing"
    return record


def manual_notes(entry):
    notes = []
    for key, value in entry.items():
        if key in MANUAL_META_KEYS:
            continue
        if isinstance(value, str):
            notes.append(f"{key}: {value}")
        elif isinstance(value, dict) and isinstance(value.get("status"), str):
            detail = "；".join(str(value[k]) for k in ("reason", "note") if value.get(k))
            notes.append(f"{key}: {value['status']}" + (f"（{detail}）" if detail else ""))
        elif isinstance(value, dict):
            others = [f"{name}={result}" for name, result in value.items()
                      if not (isinstance(result, str) and result.startswith("passed"))]
            if others:
                notes.append(f"{key}: " + "，".join(others))
        elif isinstance(value, list):
            notes.append(f"{key}: {len(value)} 项")
    return notes


def manual_candidates(spec, path):
    document = load_json(path, "manual results")
    if not isinstance(document, dict):
        raise MatrixError(f"{path}: manual results must be an object")
    combo, variant, options = spec
    if document.get("combo") != combo or document.get("variant") != variant:
        raise MatrixError(f"{path}: combo/variant {document.get('combo')!r}/{document.get('variant')!r} "
                          f"does not match spec {spec_label(spec)}")
    recorded_options = document.get("options") or []
    if not isinstance(recorded_options, list) or tuple(sorted(set(recorded_options))) != options:
        raise MatrixError(f"{path}: options {recorded_options!r} do not match spec {spec_label(spec)}")
    recorded_at = document.get("recorded_at")
    if not recorded_at:
        raise MatrixError(f"{path}: missing recorded_at")
    time_key(recorded_at)
    ref = display_path(path)
    vm_dir = Path(path).resolve().parent.parent
    full, subitems, row_notes = {}, {}, []
    if document.get("frida") is not None:
        frida = document["frida"]
        row_notes.append("frida: " + ("，".join(f"{k}={v}" for k, v in frida.items())
                                      if isinstance(frida, dict) else str(frida)))
    for key, entry in document.items():
        if key in MANUAL_TOP_KEYS and key != "setup_assistant":
            continue
        if key == "setup_assistant":
            column, suffix = "S3", "setup_assistant"
        else:
            match = MANUAL_STEP_KEY.match(key)
            if not match:
                raise MatrixError(f"{path}: unsupported key {key!r}")
            column, suffix = match.group(1), match.group(2)
        if not isinstance(entry, dict) or "status" not in entry:
            raise MatrixError(f"{path}: {key} must be an object with status")
        status, expectation, qualifier = parse_manual_status(entry["status"], f"{path}: {key}")
        evidence = []
        for field in ("evidence", "run"):
            values = entry.get(field)
            for value in ([values] if isinstance(values, str) else values or []):
                evidence.append(resolve_evidence(value, vm_dir))
        notes = ([f"限定：{qualifier}"] if qualifier else []) + manual_notes(entry)
        missing = [item["ref"] for item in evidence if item["state"] == "missing"]
        if missing:
            notes.append(f"证据路径不存在：{missing}")
        record = {"source": "manual", "ref": f"{ref}#{key}", "path": ref, "status": status,
                  "time": recorded_at, "expectation": expectation,
                  "classification": entry.get("classification"),
                  "reason": entry.get("reason"), "evidence": evidence, "notes": notes}
        if suffix in (None, "after_setup"):
            if column in full:
                raise MatrixError(f"{path}: duplicate manual records for {column}")
            full[column] = record
        else:
            subitems.setdefault(column, []).append(record)
    return full, subitems, row_notes


def load_jb_setup_log(spec, path):
    if spec[1] not in ("jb", "exp"):
        raise MatrixError(f"--jb-setup-log {spec_label(spec)}: JB setup log applies only to jb/exp")
    try:
        text = Path(path).read_text(errors="replace")
    except OSError as error:
        raise MatrixError(f"{path}: unreadable JB setup log: {error}") from error
    return {"path": path, "complete": JB_FINALIZE_MARKER in text}


# MARK: - Known limits

def load_limits(path):
    document = load_json(path, "limits config")
    if not isinstance(document, dict) or document.get("schema_version") != 1:
        raise MatrixError(f"{path}: limits config requires schema_version 1")
    seen = set()
    for section, prefix, required in (("known_limits", "L", "decision"), ("open_issues", "O", "tracking")):
        entries = document.get(section)
        if not isinstance(entries, list):
            raise MatrixError(f"{path}: {section} must be a list")
        for entry in entries:
            if not isinstance(entry, dict) or not re.fullmatch(prefix + r"\d+", str(entry.get("id"))):
                raise MatrixError(f"{path}: {section} entry id must match {prefix}<n>")
            if entry["id"] in seen:
                raise MatrixError(f"{path}: duplicate id {entry['id']}")
            seen.add(entry["id"])
            for field in ("summary", required):
                if not isinstance(entry.get(field), str) or not entry[field]:
                    raise MatrixError(f"{path}: {entry['id']} requires {field}")
            applies = entry.get("applies_to")
            if not isinstance(applies, list) or not applies:
                raise MatrixError(f"{path}: {entry['id']} requires applies_to")
            for item in applies:
                if not isinstance(item, dict) or not isinstance(item.get("steps"), list) or not item["steps"]:
                    raise MatrixError(f"{path}: {entry['id']} applies_to entries need spec and steps")
                item["_spec"] = parse_spec(str(item.get("spec")))
                if any(step not in COLUMNS for step in item["steps"]):
                    raise MatrixError(f"{path}: {entry['id']} has invalid step in {item['steps']}")
            validate_limit_evidence(path, entry)
    excluded = document.get("excluded_combinations") or []
    if not isinstance(excluded, list):
        raise MatrixError(f"{path}: excluded_combinations must be a list")
    for entry in excluded:
        if (not isinstance(entry, dict) or entry.get("combo_id") not in COMBINATIONS
                or not isinstance(entry.get("variants"), list) or not entry["variants"]
                or any(variant not in VARIANTS for variant in entry["variants"])
                or not isinstance(entry.get("reason"), str)):
            raise MatrixError(f"{path}: excluded_combinations entries need a known combo_id, variants and reason")
        validate_limit_evidence(path, entry)
    return document


def validate_limit_evidence(path, entry):
    evidence = entry.get("evidence")
    label = entry.get("id") or entry.get("combo_id")
    if not isinstance(evidence, list) or not evidence:
        raise MatrixError(f"{path}: {label} requires evidence")
    for item in evidence:
        if not isinstance(item, dict) or not isinstance(item.get("path"), str):
            raise MatrixError(f"{path}: {label} evidence entries need path")
        target = Path(item["path"])
        if not target.exists():
            raise MatrixError(f"{path}: {label} evidence path does not exist: {item['path']}")
        if target.is_file():
            item["sha256"] = sha256_file(target)


# MARK: - Matrix

def empty_cell():
    return {"status": "not_run", "source": None, "run_id": None, "ref": None, "label": None, "finished_at": None,
            "expectation": None, "notes": [], "history": [], "candidates": [],
            "reason": None, "classification": None, "known_limits": [], "open_issues": []}


def select_candidate(candidates):
    """Highest source rank, then latest time; a later failed record is never displaced."""
    ranked = sorted(enumerate(candidates),
                    key=lambda pair: (SOURCE_RANK[pair[1]["source"]], time_key(pair[1]["time"]), pair[0]))
    winner = ranked[-1][1]
    notes = []
    if winner["status"] != "failed":
        later_failed = [(time_key(c["time"]), index, c) for index, c in ranked
                        if c["status"] == "failed" and time_key(c["time"]) > time_key(winner["time"])]
        if later_failed:
            chosen = max(later_failed, key=lambda item: (item[0], item[1]))[2]
            notes.append(f"{winner['source']} {winner['status']} 早于 {chosen['source']} failed，保留 failed")
            winner = chosen
    return winner, notes


def finalize_cell(cell, candidates, subitems=()):
    for candidate in candidates:
        if candidate["source"] == "auto":
            cell["history"].append({"run_id": candidate["ref"], "status": candidate["status"],
                                    "finished_at": candidate["time"],
                                    "classification": candidate["classification"]})
    effective = [candidate for candidate in candidates if candidate["status"] != "not_run"]
    cell["candidates"] = [dict(candidate) for candidate in effective]
    if effective:
        winner, notes = select_candidate(effective)
        source = winner["source"] + (f"+{winner['supplement']}" if winner.get("supplement") else "")
        cell.update({"status": winner["status"], "source": source, "ref": winner["ref"],
                     "label": winner.get("label") or winner["ref"],
                     "run_id": winner["ref"] if winner["source"] == "auto" else None,
                     "finished_at": winner["time"], "expectation": winner["expectation"],
                     "notes": list(winner["notes"]) + notes, "reason": winner["reason"],
                     "classification": winner["classification"]})
    for item in subitems:
        cell["notes"].append(f"子项 {item['ref'].split('#')[-1]} [manual] {item['status']}"
                             + (f"：{'；'.join(item['notes'])}" if item["notes"] else ""))
        if item["status"] == "failed" and cell["status"] == "passed":
            cell["status"] = "partial"
            cell["notes"].append("人工子项 failed，单元格由 passed 降为 partial")


def legacy_rows(runs, paths):
    rows = {}
    for run, path in zip(runs, paths):
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
            "candidates": {column: [] for column in COLUMNS},
        })
        row["worktree_clean"].add((run.get("tool") or {}).get("worktree_clean"))
        row["runs"].append(run["run_id"])
        launch = run.get("launch")
        if isinstance(launch, dict):
            row["launch"].append({"run_id": run["run_id"], **launch})
        for column, candidate in auto_candidates(run, path):
            row["candidates"][column].append(candidate)
    ordered = []
    for key in sorted(rows, key=lambda item: tuple("" if part is None else str(part) for part in item)):
        row = rows[key]
        clean = row.pop("worktree_clean")
        row["worktree_clean"] = clean.pop() if len(clean) == 1 else None
        candidates = row.pop("candidates")
        row["cells"] = {}
        for column in COLUMNS:
            cell = empty_cell()
            finalize_cell(cell, candidates[column])
            row["cells"][column] = cell
        ordered.append(row)
    return ordered


def instance_rows(instances, runs, paths):
    """Bind run.json records to spec instances; return (rows, unbound runs, unbound paths)."""
    by_bundle = {}
    for spec, instance in instances.items():
        create = instance.get("create")
        if create and create["bundle"]:
            if create["bundle"] in by_bundle:
                raise MatrixError(f"bundle {create['bundle']} bound to more than one spec")
            by_bundle[create["bundle"]] = spec
    bound = {spec: [] for spec in instances}
    unbound_runs, unbound_paths = [], []
    for run, path in zip(runs, paths):
        combination = run["combination"]
        spec = by_bundle.get(run_bundle(run))
        if spec is None:
            frida = ("frida",) if (combination.get("options") or {}).get("frida") else ()
            key = (combination["combo_id"], combination["variant"], frida)
            if key in instances and not instances[key].get("create"):
                spec = key
        if spec is None:
            unbound_runs.append(run)
            unbound_paths.append(path)
            continue
        combo, variant, options = spec
        definition = COMBINATIONS[combo]
        if combination["combo_id"] != combo or combination["variant"] != variant:
            raise MatrixError(f"{path}: run combination {combination['combo_id']}:{combination['variant']} "
                              f"conflicts with bundle spec {spec_label(spec)}")
        for field in ("ios", "cloudos"):
            observed = ((combination.get(field) or {}).get("version"), (combination.get(field) or {}).get("build"))
            if observed != definition[field]:
                raise MatrixError(f"{path}: run {field} {observed} does not match combination {combo} "
                                  f"{definition[field]}")
        bound[spec].append((run, path))
    rows = []
    for spec in sorted(instances, key=lambda s: (list(COMBINATIONS).index(s[0]), VARIANTS.index(s[1]), s[2])):
        instance = instances[spec]
        combo, variant, options = spec
        definition = COMBINATIONS[combo]
        create = instance.get("create")
        candidates = {column: [] for column in COLUMNS}
        row_notes = [definition["note"]] if definition["note"] else []
        commits, clean, launches, run_ids = [], set(), [], []
        for run, path in sorted(bound[spec], key=lambda pair: (pair[0].get("started_at") or "", str(pair[1]))):
            tool = run.get("tool") or {}
            if tool.get("git_commit") and tool["git_commit"] not in commits:
                commits.append(tool["git_commit"])
            clean.add(tool.get("worktree_clean"))
            run_ids.append(run["run_id"])
            if isinstance(run.get("launch"), dict):
                launches.append({"run_id": run["run_id"], "run_dir": Path(path).parent.name if path else None,
                                 **run["launch"]})
            run_frida = bool((run["combination"].get("options") or {}).get("frida"))
            if run_frida != ("frida" in options):
                row_notes.append(f"run `{display_path(path)}` options.frida={run_frida} 与规格 "
                                 f"{spec_label(spec)} 不一致；按 bundle 归入本行")
            for column, candidate in auto_candidates(run, path):
                candidates[column].append(candidate)
        if create:
            for column, candidate in checkpoint_candidates(spec, create, instance.get("jb_log")):
                candidates[column].append(candidate)
        elif instance.get("jb_log"):
            raise MatrixError(f"--jb-setup-log {spec_label(spec)} requires --create-status for the same spec")
        subitems = {}
        if instance.get("manual"):
            full, subitems, manual_row_notes = manual_candidates(spec, instance["manual"])
            row_notes.extend(manual_row_notes)
            for column, candidate in full.items():
                candidates[column].append(candidate)
        if commits:
            row_notes.append("run.json 工具提交：" + ", ".join(commit[:12] for commit in commits))
        if create:
            row_notes.append(f"创建工具 vphone-cli SHA-256 {create['tool_sha256']}")
        cells = {}
        for column in COLUMNS:
            cell = empty_cell()
            finalize_cell(cell, candidates[column], subitems.get(column, ()))
            cells[column] = cell
        rows.append({
            "spec": spec_label(spec), "combo_id": combo, "device": definition["device"],
            "ios": {"version": definition["ios"][0], "build": definition["ios"][1]},
            "cloudos": {"version": definition["cloudos"][0], "build": definition["cloudos"][1]},
            "variant": variant, "options": {"frida": "frida" in options},
            "vm": {"name": create["vm_name"] if create else None,
                   "bundle": display_path(create["bundle"]) if create and create["bundle"] else None},
            "git_commit": commits[0] if len(commits) == 1 else None, "tool_commits": commits,
            "worktree_clean": clean.pop() if len(clean) == 1 else None,
            "runs": run_ids, "launch": launches, "row_notes": row_notes, "cells": cells,
        })
    return rows, unbound_runs, unbound_paths


def excluded_rows(limits, instances):
    rows = []
    for entry in (limits or {}).get("excluded_combinations") or []:
        combo = entry["combo_id"]
        definition = COMBINATIONS[combo]
        for variant in entry["variants"]:
            if any(spec[0] == combo and spec[1] == variant for spec in instances):
                raise MatrixError(f"excluded combination {combo}:{variant} also has evidence inputs")
            cells = {column: empty_cell() for column in COLUMNS}
            rows.append({
                "spec": f"{combo}:{variant}", "combo_id": combo, "device": definition["device"],
                "ios": {"version": definition["ios"][0], "build": definition["ios"][1]},
                "cloudos": {"version": definition["cloudos"][0], "build": definition["cloudos"][1]},
                "variant": variant, "options": {"frida": False}, "vm": {"name": None, "bundle": None},
                "git_commit": None, "tool_commits": [], "worktree_clean": None, "runs": [], "launch": [],
                "excluded": True, "row_notes": [f"不纳入：{entry['reason']}"], "cells": cells,
            })
    return rows


def apply_limits(rows, limits):
    if not limits:
        return
    by_spec = {row["spec"]: row for row in rows if "spec" in row}
    for section, field in (("known_limits", "known_limits"), ("open_issues", "open_issues")):
        for entry in limits[section]:
            for item in entry["applies_to"]:
                label = spec_label(item["_spec"])
                if label not in by_spec:
                    raise MatrixError(f"limits {entry['id']}: spec {label} has no matrix row")
                for step in item["steps"]:
                    by_spec[label]["cells"][step][field].append(entry["id"])


def build_matrix(runs, run_paths=None, instances=None, limits=None):
    paths = list(run_paths) if run_paths is not None else [None] * len(runs)
    instances = instances or {}
    extended = bool(instances) or limits is not None
    rows, runs_left, paths_left = instance_rows(instances, runs, paths) if instances else ([], runs, paths)
    rows.extend(excluded_rows(limits, instances))
    apply_limits(rows, limits)
    rows.extend(legacy_rows(runs_left, paths_left))
    matrix = {"schema_version": SCHEMA_VERSION, "columns": list(COLUMNS),
              "selection_rule": "latest non-not_run record per exact combination and step; "
                                "records from other builds, options or commits are separate rows",
              "rows": rows}
    if extended:
        matrix["selection_rule"] = (
            "rows bound to a combination spec merge run.json (auto), create checkpoint (checkpoint) and "
            "manual_results.json (manual) records; manual outranks auto and checkpoint, the latest record "
            "wins within a rank, and a failed record is never displaced by an older record; unbound "
            "run.json records keep the per-commit rows")
        if limits is not None:
            matrix["known_limits"] = strip_private(limits.get("known_limits"))
            matrix["open_issues"] = strip_private(limits.get("open_issues"))
            matrix["excluded_combinations"] = limits.get("excluded_combinations") or []
    return matrix


def strip_private(entries):
    result = []
    for entry in entries or []:
        copy = dict(entry)
        copy["applies_to"] = [{k: v for k, v in item.items() if not k.startswith("_")}
                              for item in entry["applies_to"]]
        result.append(copy)
    return result


# MARK: - Markdown

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


MERGE_RULES = """\
- 单元格来源标注：`auto` 为 `run.json`（验收脚本输出），`checkpoint` 为创建检查点（S1–S3），`manual` 为人工结果 `manual_results.json`；`checkpoint+manual` 表示 S3 由检查点推导，JB 收尾完成标记来自人工取回的 `vphone_jb_setup.log`。
- 合并规则：`manual` 的排序高于 `auto` 与 `checkpoint`；同一排序内时间最新的记录决定状态（`run.json` 用步骤 `finished_at`，检查点用阶段 `finished_at`，人工用 `recorded_at`）。人工结果在首次设置后的 GUI 复跑之后记录，因此首次设置后的 GUI 复跑与人工结果优先于首次设置前的 headless 结果。
- `failed` 保护：若某条 `failed` 记录晚于按上述规则选中的非 `failed` 记录，状态保持 `failed`；`failed` 只会被更晚且排序不低的记录替换。
- 被替换的记录保留在 JSON 的 `candidates` 与下方备注中。人工子项（如 `S12_graphics`、`setup_assistant`、嵌套的 `bottom_edge_swipe_home_guest_path`）只写入备注，不决定单元格状态；子项 `failed` 时 `passed` 降为 `partial`。
- 检查点推导：S1 要求 prepare/patch 成功、cfw 成功或 not_applicable、整体状态不属于失败类、prepare 的 iOS/cloudOS 版本与组合定义一致，patch 记录数与历史值不一致时降为 `partial`；S2 要求 `restore_update_exit=0` 且 `post_restore_dfu_outcome=matched`；S3 要求 first_boot `prompt=matched` 且 verification `succeeded`，jb/exp 的 `jb_finalize=unverified` 需人工取回日志含完成标记，否则为 `partial`。
- `(negative)` 表示负向检查，不计为功能通过；`*` 表示记录了失败分类；`L<n>`/`O<n>` 为下文已知限制与未解决问题编号。"""


def extended_cell_text(cell):
    text = cell_text(cell)
    if cell.get("source"):
        text += f" [{cell['source']}]"
    ids = cell.get("known_limits", []) + cell.get("open_issues", [])
    if ids:
        text += " " + ",".join(ids)
    return text


def shorten(text, limit=200):
    text = str(text)
    return text if len(text) <= limit else text[:limit - 1] + "…"


def candidate_text(candidate):
    text = f"{candidate['source']} `{candidate.get('label') or candidate['ref']}`={candidate['status']}"
    extra = [shorten(value) for value in (candidate.get("classification"), candidate.get("reason")) if value]
    return text + (f"（{'；'.join(extra)}）" if extra else "")


def render_extended_markdown(matrix, context):
    lines = [f"# {context['title']}", ""]
    lines += ["生成文件，请勿手工修改；修改输入后重新生成。", "", "## 生成命令", "", "```sh",
              context["command"], "```", "", "## 单元格来源与合并规则", "", MERGE_RULES, "", "## 矩阵", ""]
    header = ["Combo", "Device", "iOS", "cloudOS", "Variant", "Options", "VM"] + matrix["columns"]
    lines += ["| " + " | ".join(header) + " |", "| " + " | ".join("---" for _ in header) + " |"]
    for row in matrix["rows"]:
        options = ", ".join(f"{key}={value}" for key, value in sorted(row["options"].items())
                            if value not in (None, False)) or "-"
        if "spec" in row:
            vm = (row.get("vm") or {}).get("name") or "-"
        else:
            vm = "@" + (row["git_commit"] or "?")[:12]
        values = [row["combo_id"], row["device"] or "-",
                  f"{row['ios'].get('version') or '?'}/{row['ios'].get('build') or '?'}",
                  f"{row['cloudos'].get('version') or '?'}/{row['cloudos'].get('build') or '?'}",
                  row["variant"], options, vm]
        values += [extended_cell_text(row["cells"][column]) for column in matrix["columns"]]
        lines.append("| " + " | ".join(str(value) for value in values) + " |")
    lines += ["", "## 备注", ""]
    for row in matrix["rows"]:
        label = row.get("spec") or row_label(row)
        lines.append(f"### {label}" + (f"（{row['vm']['name']}）" if (row.get("vm") or {}).get("name") else ""))
        lines.append("")
        for note in row.get("row_notes", []):
            lines.append(f"- {note}")
        for entry in row.get("launch", []):
            lines.append(f"- run `{entry.get('run_dir') or entry['run_id']}` {launch_text(entry)}")
        for column in matrix["columns"]:
            cell = row["cells"][column]
            if cell["status"] == "not_run" and not cell["candidates"]:
                continue
            parts = [f"{column} `{cell['status']}` [{cell['source'] or '-'}] 选用 `{cell.get('label') or cell['ref']}`"]
            others = [candidate_text(c) for c in cell["candidates"]
                      if c["ref"] != cell["ref"] or c["source"] != (cell["source"] or "").split("+")[0]]
            if cell.get("classification") or cell.get("reason"):
                parts.append("分类/原因：" + "；".join(shorten(v) for v in (cell.get("classification"),
                                                                     cell.get("reason")) if v))
            if cell["notes"]:
                parts.append("说明：" + "；".join(cell["notes"]))
            if others:
                parts.append("其他记录：" + "，".join(others))
            if cell["known_limits"]:
                parts.append("已知限制：" + ", ".join(cell["known_limits"]))
            if cell["open_issues"]:
                parts.append("未解决问题：" + ", ".join(cell["open_issues"]))
            lines.append("- " + "。".join(parts))
        lines.append("")
    if "known_limits" in matrix:
        for title, key, field, label in (("已知限制", "known_limits", "decision", "决定"),
                                         ("未解决问题", "open_issues", "tracking", "跟踪")):
            lines += [f"## {title}", "", f"| 编号 | 内容 | 适用单元格 | {label} | 证据 |", "| --- | --- | --- | --- | --- |"]
            for entry in matrix[key]:
                cells = "；".join(f"{item['spec']} {'/'.join(item['steps'])}" for item in entry["applies_to"])
                evidence = "<br>".join(f"`{item['path']}`" + (f"：{item['detail']}" if item.get("detail") else "")
                                       for item in entry["evidence"])
                summary = entry["summary"] + (f"（{entry['detail']}）" if entry.get("detail") else "")
                lines.append(f"| {entry['id']} | {summary} | {cells} | {entry[field]} | {evidence} |")
            lines.append("")
        if matrix.get("excluded_combinations"):
            lines += ["## 不纳入的组合", ""]
            for entry in matrix["excluded_combinations"]:
                evidence = "，".join(f"`{item['path']}`" for item in entry["evidence"])
                lines.append(f"- {entry['combo_id']}（{'/'.join(entry['variants'])}）：{entry['reason']}。证据：{evidence}")
            lines.append("")
    lines += ["## 输入清单", "", "| 类型 | 规格 | 路径 | SHA-256 |", "| --- | --- | --- | --- |"]
    for item in context["inputs"]:
        lines.append(f"| {item['kind']} | {item['spec'] or '-'} | `{item['path']}` | `{item['sha256']}` |")
    return "\n".join(lines).rstrip() + "\n"


# MARK: - CLI

def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("inputs", nargs="+", help="run.json files or directories searched recursively")
    parser.add_argument("--json-out", type=Path)
    parser.add_argument("--md-out", type=Path)
    parser.add_argument("--create-status", action="append", default=[], metavar="SPEC=PATH")
    parser.add_argument("--manual", action="append", default=[], metavar="SPEC=PATH")
    parser.add_argument("--jb-setup-log", action="append", default=[], metavar="SPEC=PATH")
    parser.add_argument("--limits", type=Path, help="known limits / open issues JSON")
    parser.add_argument("--title", default="F1 支持矩阵", help="Markdown title for extended output")
    raw_argv = list(sys.argv[1:] if argv is None else argv)
    args = parser.parse_args(raw_argv)
    try:
        extended = bool(args.create_status or args.manual or args.jb_setup_log or args.limits)
        run_paths = collect_paths(args.inputs, allow_empty=extended)
        runs = [load_run(path) for path in run_paths]
        instances = {}
        inputs = [{"kind": "run.json", "spec": None, "path": display_path(path), "sha256": sha256_file(path)}
                  for path in run_paths]
        for flag, values, key in (("--create-status", args.create_status, "create"),
                                  ("--manual", args.manual, "manual"),
                                  ("--jb-setup-log", args.jb_setup_log, "jb_log")):
            for value in values:
                spec, path = parse_assignment(value, flag)
                instance = instances.setdefault(spec, {})
                if key in instance:
                    raise MatrixError(f"{flag} given twice for {spec_label(spec)}")
                if key == "create":
                    instance[key] = load_create_status(spec, path)
                elif key == "jb_log":
                    instance[key] = load_jb_setup_log(spec, path)
                else:
                    instance[key] = path
                inputs.append({"kind": flag[2:], "spec": spec_label(spec), "path": display_path(path),
                               "sha256": sha256_file(path)})
        limits = load_limits(args.limits) if args.limits else None
        if args.limits:
            inputs.append({"kind": "limits", "spec": None, "path": display_path(args.limits),
                           "sha256": sha256_file(args.limits)})
        matrix = build_matrix(runs, run_paths, instances, limits)
    except MatrixError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    if instances or limits is not None:
        matrix["inputs"] = inputs
        context = {"title": args.title, "inputs": inputs,
                   "command": "python3 scripts/f1_support_matrix.py " + shlex.join(raw_argv)}
        markdown = render_extended_markdown(matrix, context)
    else:
        markdown = render_markdown(matrix)
    if args.json_out:
        args.json_out.write_text(json.dumps(matrix, indent=2, sort_keys=True, ensure_ascii=False) + "\n")
    if args.md_out:
        args.md_out.write_text(markdown)
    if not args.json_out and not args.md_out:
        sys.stdout.write(markdown)
    return 0


if __name__ == "__main__":
    sys.exit(main())
