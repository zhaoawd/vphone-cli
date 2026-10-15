#!/usr/bin/env python3
"""Generate the execution catalog from reviewed decisions for the fixed upstream commit.

Source declarations describe upstream intent, not local execution permission. Every
target ID needs a reviewed decision; this generator never invents a missing binding.
"""

import argparse
import gzip
import hashlib
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
TARGET = "8a75092013eda87a4e30ed029b72028cb9279ac4"
RESEARCH = Path("research/upstream_integration_2026-10-15")
EVIDENCE = RESEARCH / "evidence/target-declarations-8a75092"
DECISIONS = RESEARCH / "T09_target_applicability.json"
OUTPUT = Path("sources/FirmwarePatcher/PatchSet/PatchDeclarationCatalogData.swift")
VARIANTS = {"regular", "dev", "jb", "exp", "less"}
BASES = {"18", "26", "27", "other"}

# A bounded reader for this fixed snapshot's declaration calls, not a Swift parser.
# Strings and comments are tokens so commas/parentheses in summaries are ignored.
TOKEN = re.compile(r'"""[\s\S]*?"""|"(?:\\.|[^"\\])*"|//[^\n]*|/\*[\s\S]*?\*/|.', re.S)


def call_arguments(source, opening):
    depth = 0
    start = opening + 1
    args = []
    for match in TOKEN.finditer(source, opening):
        token = match.group()
        if token in ("(", "[", "{"):
            depth += 1
        elif token in (")", "]", "}"):
            depth -= 1
            if depth == 0:
                args.append(source[start:match.start()].strip())
                return [a for a in args if a], match.end()
        elif token == "," and depth == 1:
            args.append(source[start:match.start()].strip())
            start = match.end()
    raise ValueError("Unterminated declaration call")


def fixed_sources(root=ROOT):
    manifest = json.loads((root / EVIDENCE / "fixed-target-source-manifest.json").read_text())
    if manifest["target"] != TARGET:
        raise ValueError("Source snapshot is not the fixed upstream target")
    ids = [r["id"] for r in manifest["declarations"]]
    if len(ids) != 148 or len(set(ids)) != 148:
        raise ValueError("Fixed target must contain 148 unique declaration IDs")
    metadata = {}
    expressions = {r["expression"]: r["id"] for r in manifest["declarations"]}
    for file in manifest["files"]:
        data = gzip.decompress((root / EVIDENCE / file["evidence"]).read_bytes())
        blob = hashlib.sha1(f"blob {len(data)}\0".encode() + data).hexdigest()
        if (len(data) != file["bytes"] or hashlib.sha256(data).hexdigest() != file["sha256"]
                or blob != file["git_blob"]):
            raise ValueError(f"Fixed source hash mismatch: {file['path']}")
        source = data.decode()
        constants = dict(re.findall(r'static let (\w+) = ("[^"\n]*")', source))
        for match in re.finditer(r'static let (\w+) = VPhonePatchApplicability\(', source):
            _, end = call_arguments(source, match.end() - 1)
            constants[match[1]] = source[match.start():end].split(" = ", 1)[1]
        for match in re.finditer(r'\b(VPhonePatchDeclaration|property)\(', source):
            args, _ = call_arguments(source, match.end() - 1)
            if match[1] == "property":
                if not args[0].startswith('"'):
                    continue  # The helper's definition.
                expression = args[0]
                fields = {"title": args[1]}
            else:
                fields = dict(a.split(":", 1) for a in args)
                fields = {k.strip(): v.strip() for k, v in fields.items()}
                expression = fields["identifier"]
                if expression == "identifier":
                    continue  # The property helper's declaration constructor.
            resolved = constants.get(expression, expression)
            identifier = json.loads(resolved) if resolved.startswith('"') else expressions.get(expression)
            if identifier not in ids or identifier in metadata:
                raise ValueError(f"Unreviewed or duplicate source declaration: {expression}")
            applicability = fields.get("applicability", ".always (default)")
            applicability = " ".join(constants.get(applicability, applicability).split())
            metadata[identifier] = {
                "title": json.loads(fields["title"]),
                "applicability": applicability,
                "bootEssential": fields.get("bootEssential", "false") == "true",
                "path": file["path"], "gitBlob": file["git_blob"],
            }
    if set(metadata) != set(ids):
        raise ValueError("Fixed source declarations differ from the source manifest")
    return metadata


def reviewed_declarations(root=ROOT):
    sources = fixed_sources(root)
    delta = json.loads((root / RESEARCH / "T09_declaration_delta.json").read_text())
    if delta["target"] != TARGET or {r["id"] for r in delta["rows"]} != set(sources):
        raise ValueError("Preset evidence differs from the fixed upstream target")
    decisions = json.loads((root / DECISIONS).read_text())
    if decisions["target"] != TARGET:
        raise ValueError("Decision table is not for the fixed upstream target")
    rows = decisions["decisions"]
    ids = [r["id"] for r in rows]
    if len(ids) != len(set(ids)) or set(ids) != set(sources):
        raise ValueError("Each fixed target ID must have exactly one explicit decision")
    declarations = []
    for row in rows:
        declaration = row["declaration"]
        source = sources[row["id"]]
        if row["upstream"] != source:
            raise ValueError(f"Decision does not match fixed source: {row['id']}")
        if declaration["id"] != row["id"] or declaration["upstreamIDs"] != [row["id"]]:
            raise ValueError(f"Ambiguous target binding: {row['id']}")
        if declaration["upstreamApplicability"] != source["applicability"]:
            raise ValueError(f"Stale applicability: {row['id']}")
        presets = {name: row["id"] in preset["selected_ids_before_version_gates"]
                   for name, preset in delta["presets_target"].items()}
        if row["presets"] != presets:
            raise ValueError(f"Stale fixed-target preset membership: {row['id']}")
        if row["decision"] not in {"preserveLocal", "notImplemented"} or not row["reason"]:
            raise ValueError(f"Missing implementation decision/reason: {row['id']}")
        if set(row["applicability"]) != VARIANTS or any(
                set(versions) != BASES for versions in row["applicability"].values()):
            raise ValueError(f"Incomplete variant/version decision: {row['id']}")
        if row["decision"] == "notImplemented":
            if (declaration["coverage"] != "notImplemented" or declaration["swiftSteps"]
                    or declaration["versionRule"] is not None):
                raise ValueError(f"Unsupported decision authorizes execution: {row['id']}")
        for path in row["localEvidence"]:
            if not (root / path).is_file():
                raise ValueError(f"Missing local implementation evidence: {path}")
        declarations.append(declaration)
    declarations += decisions["localOnly"]
    if {r["id"] for r in decisions["localOnly"]} != {
            "filesystem-less-cryptex_merge", "manifest-less-hash_rewrite", 'system-cryptex-boot-install', 'system-iosbinpack-boot-install', 'system-launchdaemons-boot-install', 'system-launchd-jb-hook', 'preboot-jb-bootstrap-install', 'system-jb-basebin-install', 'preboot-jb-tweakloader-install', 'system-jb-firstboot-install', 'preboot-exp-vcam-install'}:
        raise ValueError("Local less and guest declarations must remain explicit")
    if any(r["upstreamIDs"] for r in decisions["localOnly"]):
        raise ValueError("Local declarations cannot claim target IDs")
    if len({r["id"] for r in declarations}) != 159:
        raise ValueError("Duplicate declaration IDs")
    return declarations


def render(root=ROOT):
    declarations = reviewed_declarations(root)
    quote = lambda value: json.dumps(value, ensure_ascii=False)
    lines = ["// GENERATED by scripts/generate_target_patch_catalog.py; do not edit by hand.",
             "// Fixed-source decisions: research/upstream_integration_2026-10-15/T09_target_applicability.json.",
             "// Upstream intent does not authorize new local execution; local rules remain authoritative.",
             "", "import Foundation", "", "extension PatchDeclarationCatalog {",
             f"    static let upstreamTag = {quote(TARGET)}", "",
             "    static let generatedDeclarations: [PatchDeclaration] = ["]
    for row in declarations:
        lines += ["        PatchDeclaration(", f"            id: {quote(row['id'])},",
                  f"            title: {quote(row['title'])},",
                  f"            coverage: .{'guestStep' if row['coverage'] == 'guest' else row['coverage']},",
                  f"            swiftSteps: {quote(row['swiftSteps'])},",
                  f"            variants: {quote(row['variants'])},",
                  f"            optIn: .{row['optIn']},",
                  f"            required: {str(row['required']).lower()},",
                  f"            versionRule: {'.' + row['versionRule'] if row['versionRule'] else 'nil'},",
                  f"            upstreamIDs: {quote(row['upstreamIDs'])},",
                  f"            upstreamApplicability: {quote(row['upstreamApplicability'])},",
                  f"            requires: {quote(row['requires'])},",
                  f"            conflicts: {quote(row['conflicts'])},"]
        if row.get("implementationNote"):
            lines += [f"            after: {quote(row['after'])},",
                      f"            implementationNote: {quote(row['implementationNote'])}),"]
        else:
            lines.append(f"            after: {quote(row['after'])}),")
    return "\n".join(lines + ["    ]", "}", ""])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    generated = render()
    if args.check:
        if (ROOT / OUTPUT).read_text() != generated:
            parser.error("Generated catalog differs from the reviewed fixed-target decisions")
        print("Fixed target catalog matches: 148 target decisions, 2 local less and 9 local guest declarations")
    else:
        sys.stdout.write(generated)


if __name__ == "__main__":
    main()
