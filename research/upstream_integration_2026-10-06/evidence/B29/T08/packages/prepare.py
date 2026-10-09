#!/usr/bin/env python3
"""Prepare pinned native RootHide debs and a first-install Irisin dry-run job.

This program DOES NOT run any deb, shell script, Irisin helper, or VM command.
It writes flat blobs/manifest.json and implements TransactionPlanner for a
fixed selected package set. It does not implement libsolv's package selection.
Requires a Python tarfile implementation supporting the input compression
(this host's Python supports the 86 zstd and 3 xz package pairs).

Example (paths and guest snapshots must be supplied by the calling agent):
  python3 prepare.py --status-file guest-status --guest-passwd guest-passwd \
    --guest-group guest-group --output /private/tmp/vphone-b29-prepared \
    --guest-base /var/root/vphone-b29

Upload transfer-manifest.json's mappings, then execute the REAL guest helper
with job.dry-run.json on stdin. This program itself never does that.
"""

import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import re
import tarfile

MINIMUM_FREE = 5 * 1024**3
ARCHITECTURE = "iphoneos-arm64e"
RELATIONS = ("depends", "pre-depends", "provides", "conflicts", "breaks")
TERM = re.compile(
    r"([a-z0-9][a-z0-9+.-]*)(?::([a-z0-9-]+))?"
    r"\s*(?:\((>=|<=|=|>>|<<)\s*([^()\s]+)\s*\))?"
)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def disk_guard(directory, reserve=0):
    anchor = Path(directory)
    while not anchor.exists():
        anchor = anchor.parent
    info = os.statvfs(anchor)
    free = info.f_bavail * info.f_frsize
    require(free >= MINIMUM_FREE + reserve,
            f"STOP: available {free}, required {MINIMUM_FREE + reserve}")


def digest_file(path):
    sha = hashlib.sha256()
    total = 0
    with Path(path).open("rb") as stream:
        while block := stream.read(1024 * 1024):
            sha.update(block)
            total += len(block)
    return sha.hexdigest(), total


def write_bytes(path, data):
    disk_guard(path.parent, len(data))
    path.parent.mkdir(parents=True, exist_ok=True)
    require(not path.exists(), f"Refuse overwrite: {path}")
    with path.open("xb") as stream:
        stream.write(data)


def write_json(path, value):
    raw = json.dumps(value, ensure_ascii=False, sort_keys=True,
                     separators=(",", ":")).encode("utf-8")
    write_bytes(path, raw)
    return hashlib.sha256(raw).hexdigest(), len(raw)


def control_fields(text):
    fields = {}
    current = None
    for line in text.replace("\r\n", "\n").splitlines():
        if not line:
            continue
        if line[0] in " \t":
            require(current is not None, "Control continuation without field")
            fields[current] += " " + line.strip()
        else:
            require(":" in line, f"Malformed control line: {line!r}")
            name, value = line.split(":", 1)
            current = name.lower()
            require(current not in fields, f"Duplicate control field: {name}")
            fields[current] = value.strip()
    return fields


def paragraphs(data):
    return [control_fields(x) for x in
            data.decode("utf-8").replace("\r\n", "\n").split("\n\n")
            if x.strip()]


def read_identities(path, field):
    result = {}
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#"):
            continue
        items = line.split(":")
        if len(items) > field and items[field].isdigit():
            result[items[0]] = int(items[field])
    return result


def relative_path(original):
    require(not original.startswith("/") and "\x00" not in original
            and "\n" not in original, f"Unsafe tar path: {original!r}")
    parts = [x for x in original.split("/") if x not in ("", ".")]
    require(".." not in parts, f"Parent traversal: {original!r}")
    return "/".join(parts)


def ar_members(path):
    with path.open("rb") as stream:
        require(stream.read(8) == b"!<arch>\n", f"Not an ar archive: {path}")
        while header := stream.read(60):
            require(len(header) == 60 and header[58:60] == b"`\n",
                    f"Bad ar member header: {path}")
            name = header[:16].decode("ascii").strip().removesuffix("/")
            require(not name.startswith(("#1/", "/")), "Extended ar names unsupported")
            size = int(header[48:58])
            require(size >= 0, "Negative ar member size")
            data = stream.read(size)
            require(len(data) == size, "Truncated ar member")
            if size % 2:
                require(len(stream.read(1)) == 1, "Truncated ar padding")
            yield name, data


def prepare_deb(path, destination, users, groups):
    disk_guard(destination)
    destination.mkdir(parents=True, exist_ok=False)
    sequence = 0
    controls = {}
    entries = []
    outer_seen = set()
    control = ""

    def blob(stream, expected_size):
        nonlocal sequence
        sequence += 1
        name = f"blob-{sequence}"
        target = destination / name
        disk_guard(destination, min(expected_size, 1024 * 1024))
        sha, md5, size = hashlib.sha256(), hashlib.md5(), 0
        with target.open("xb") as output:
            while block := stream.read(1024 * 1024):
                disk_guard(destination, len(block))
                output.write(block)
                sha.update(block)
                md5.update(block)
                size += len(block)
        require(size == expected_size, f"Wrong blob length: {path} {name}")
        return {"name": name, "sha256": sha.hexdigest(),
                "md5": md5.hexdigest(), "size": size}

    for name, compressed in ar_members(path):
        if name == "debian-binary":
            require(name not in outer_seen, "Repeated debian-binary")
            outer_seen.add(name)
            require(compressed == b"2.0\n", "Unsupported Debian archive version")
            blob(io.BytesIO(compressed), len(compressed))
            continue
        is_control = name == "control.tar" or name.startswith("control.tar.")
        is_data = name == "data.tar" or name.startswith("data.tar.")
        if not is_control and not is_data:
            continue
        key = "control" if is_control else "data"
        require(key not in outer_seen, f"Repeated {key} archive")
        outer_seen.add(key)
        # Official copyMember temporarily assigns a blob number to the inner
        # compressed archive and deletes that blob after decoding. Skip that
        # disk copy while retaining its sequence number.
        sequence += 1
        seen = set()
        try:
            archive = tarfile.open(fileobj=io.BytesIO(compressed), mode="r:*")
        except tarfile.ReadError as error:
            raise ValueError("Python tarfile lacks required compression support; "
                             f"cannot decode {path.name}:{name}") from error
        with archive:
            for member in archive:
                member_path = relative_path(member.name)
                if not member_path:
                    continue
                require(member_path not in seen, f"Duplicate tar path: {member_path}")
                seen.add(member_path)
                file = None
                link = None
                if member.islnk():
                    kind = "hardLink"
                    link = relative_path(member.linkname)
                    require(bool(link), "Empty hard link")
                elif member.isfile():
                    kind = "file"
                    require(member.size >= 0, "Negative tar entry size")
                    with archive.extractfile(member) as source:
                        file = blob(source, member.size)
                elif member.isdir():
                    kind = "directory"
                elif member.issym():
                    kind = "symbolicLink"
                    link = member.linkname
                    require(bool(link) and "\x00" not in link, "Invalid symbolic link")
                else:
                    raise ValueError(f"Unsupported tar entry kind: {member_path}")
                if is_control:
                    require(kind == "file" and "/" not in member_path,
                            "Control member must be a flat regular file")
                    controls[member_path] = file
                    if member_path == "control":
                        control = (destination / file["name"]).read_text(encoding="utf-8")
                else:
                    require(0 <= member.uid <= 0xFFFFFFFF and
                            0 <= member.gid <= 0xFFFFFFFF, "Invalid tar uid/gid")
                    uid = users.get(member.uname, member.uid)
                    gid = groups.get(member.gname, member.gid)
                    require(0 <= uid <= 0xFFFFFFFF and 0 <= gid <= 0xFFFFFFFF,
                            "Invalid resolved owner")
                    require(0 <= member.mode <= 0o7777, "Invalid tar mode")
                    timestamp = int(member.mtime)
                    require(-(1 << 63) <= timestamp < (1 << 63), "Invalid mtime")
                    entry = {"path": member_path, "kind": kind,
                             "mode": member.mode, "uid": uid, "gid": gid,
                             "modificationTime": timestamp}
                    if file is not None:
                        entry["file"] = file
                    if link is not None:
                        entry["linkTarget"] = link
                    entries.append(entry)
    require(outer_seen >= {"debian-binary", "control", "data"} and control,
            f"Incomplete Debian package: {path}")
    by_path = {x["path"]: x for x in entries}
    for entry in entries:
        if entry["kind"] != "hardLink":
            continue
        seen_links = {entry["path"]}
        target = entry["linkTarget"]
        while True:
            require(target not in seen_links and target in by_path,
                    f"Missing/cyclic hard link: {entry['path']}")
            seen_links.add(target)
            other = by_path[target]
            if other["kind"] == "file":
                break
            require(other["kind"] == "hardLink", "Hard link does not end at a regular file")
            target = other["linkTarget"]
    manifest = {"formatVersion": 1, "control": control,
                "controlFiles": controls, "entries": entries}
    sha, _ = write_json(destination / "manifest.json", manifest)
    return sha, control_fields(control)


def version_compare(left, right):
    def split(value):
        epoch, rest = value.split(":", 1) if ":" in value else ("0", value)
        upstream, revision = rest.rsplit("-", 1) if "-" in rest else (rest, "0")
        require(epoch.isdigit() and upstream, f"Invalid Debian version: {value}")
        return int(epoch), upstream, revision

    def compare_part(a, b):
        def order(char):
            if char == "~":
                return -1
            if not char:
                return 0
            if "A" <= char <= "Z" or "a" <= char <= "z":
                return ord(char)
            return ord(char) + 256
        while a or b:
            while (a and not a[0].isdigit()) or (b and not b[0].isdigit()):
                first, second = order(a[0] if a else ""), order(b[0] if b else "")
                if first != second:
                    return (first > second) - (first < second)
                a, b = a[1:] if a else "", b[1:] if b else ""
            x, y = re.match(r"\d*", a)[0], re.match(r"\d*", b)[0]
            a, b = a[len(x):], b[len(y):]
            x, y = x.lstrip("0"), y.lstrip("0")
            if len(x) != len(y):
                return (len(x) > len(y)) - (len(x) < len(y))
            if x != y:
                return (x > y) - (x < y)
        return 0

    ae, au, ar = split(left)
    be, bu, br = split(right)
    return ((ae > be) - (ae < be)) if ae != be else compare_part(au, bu) or compare_part(ar, br)


def version_satisfies(actual, operator, required):
    if operator is None:
        return True
    comparison = version_compare(actual, required)
    return {"=": comparison == 0, ">=": comparison >= 0,
            "<=": comparison <= 0, ">>": comparison > 0,
            "<<": comparison < 0}[operator]


def parse_relations(value):
    if not value.strip():
        return []
    clauses = []
    for clause in value.split(","):
        terms = []
        for raw in clause.split("|"):
            match = TERM.fullmatch(raw.strip())
            require(match is not None, f"Unsupported/malformed relation: {raw}")
            terms.append(match.groups())
        clauses.append(terms)
    return clauses


def strongly_connected_components(graph):
    # Port of Irisin's iterative Kosaraju implementation, including index
    # traversal and component ordering. No package/program is executed.
    visited, order = set(), []
    for node in sorted(graph):
        if node in visited:
            continue
        stack = [(node, False)]
        while stack:
            current, finish = stack.pop()
            if finish:
                order.append(current)
                continue
            if current in visited:
                continue
            visited.add(current)
            stack.append((current, True))
            for following in reversed(graph.get(current, [])):
                if following in graph and following not in visited:
                    stack.append((following, False))
    reverse = {}
    for node, edges in graph.items():
        for following in edges:
            reverse.setdefault(following, []).append(node)
    visited, result = set(), []
    for node in reversed(order):
        if node in visited:
            continue
        component, stack = set(), [node]
        while stack:
            current = stack.pop()
            if current in visited:
                continue
            visited.add(current)
            component.add(current)
            stack.extend(reverse.get(current, []))
        result.append(component)
    return list(reversed(result))


def plan_stages(installed, candidates):
    # ResolutionPool orders installed identities, then candidate (repo,name)
    # and version descending. There is one fixed version per candidate here;
    # omitted unselected candidates cannot change selected relative order.
    records = [dict(x, _installed=True) for x in sorted(installed, key=lambda x: x["package"])]
    records += [dict(x, _installed=False) for x in
                sorted(candidates, key=lambda x: (x["_source"], x["package"]))]
    names = [x["package"] for x in records]
    require(len(names) == len(set(names)), "First-install set repeats an installed identity")
    relations = [{k: parse_relations(x.get(k, "")) for k in RELATIONS} for x in records]
    providers = {}
    for index, record in enumerate(records):
        capabilities = {record["package"]}
        capabilities.update(t[0] for clause in relations[index]["provides"] for t in clause)
        for name in capabilities:
            providers.setdefault(name, []).append(index)

    def matches(index, term):
        name, qualifier, operator, required = term
        record = records[index]
        if qualifier == "any":
            if record.get("multi-arch") not in ("allowed", "foreign"):
                return False
        elif qualifier not in (None, "native", ARCHITECTURE):
            return False
        if record["package"] == name and version_satisfies(record["version"], operator, required):
            return True
        for clause in relations[index]["provides"]:
            for provided_name, _, provided_operator, provided_version in clause:
                if provided_name == name and (operator is None or
                    provided_operator == "=" and version_satisfies(provided_version, operator, required)):
                    return True
        return False

    def witnesses(clause):
        result = []
        for term in clause:
            for index in providers.get(term[0], []):
                if index not in result and matches(index, term):
                    result.append(index)
        return result

    def satisfied(clause, available):
        return any(index in available for index in witnesses(clause))

    def requirements_satisfied(index, available, kinds):
        return all(satisfied(c, available) for kind in kinds for c in relations[index][kind])

    def conflicts(lhs, rhs, kind):
        return names[lhs] != names[rhs] and any(rhs in witnesses(c) for c in relations[lhs][kind])

    def dependencies(index):
        return [w for kind in ("depends", "pre-depends") for c in relations[index][kind]
                for w in witnesses(c) if w != index]

    def dependencies_first(members):
        graph = {i: [w for w in dependencies(i) if w in members] for i in sorted(members)}
        return [i for component in strongly_connected_components(graph) for i in sorted(component)]

    selected = set(range(len(records)))
    for index in sorted(selected):
        require(requirements_satisfied(index, selected, ("depends", "pre-depends")),
                f"Unsatisfied final dependencies: {names[index]}")
        for kind in ("conflicts", "breaks"):
            require(not any(conflicts(index, other, kind) for other in selected),
                    f"Final {kind}: {names[index]}")
    present = {i for i, x in enumerate(records) if x["_installed"]}
    configured = {i for i in present if records[i].get("status", "").endswith(" installed")}
    require(present == configured, "This tool only admits fully configured initial installed records")
    unpack = selected - present
    stages, ordered = [], True
    while unpack or not selected <= configured:
        progress = False
        waiting = set()
        for index in dependencies_first(unpack):
            if ((ordered and not waiting.isdisjoint(dependencies(index))) or
                not requirements_satisfied(index, configured, ("pre-depends",))):
                waiting.add(index)
                continue
            if any(conflicts(index, p, "conflicts") or conflicts(p, index, "conflicts") for p in present):
                continue
            broken = {p for p in configured if
                      conflicts(index, p, "breaks") or conflicts(p, index, "breaks")}
            if any(p in selected for p in broken):
                continue
            # Fresh install: there are no old versions, removals, or upgrades.
            configured -= broken
            present.add(index)
            unpack.remove(index)
            stages.append({"unpack": {"_0": [names[index]]}})
            progress = True
        pending = (selected & present) - configured
        edges = {index: [] for index in sorted(pending)}
        for index in sorted(pending):
            for kind in ("depends", "pre-depends"):
                for clause in relations[index][kind]:
                    offered = witnesses(clause)
                    if any(w in configured for w in offered):
                        continue
                    witness = next((w for w in offered if w in pending), None)
                    if witness is not None:
                        edges[index].append(witness)
        for component in strongly_connected_components(edges):
            available = configured | component
            if not all(requirements_satisfied(i, available, ("depends", "pre-depends")) for i in component):
                continue
            if any(conflicts(i, p, "breaks") or conflicts(p, i, "breaks")
                   for i in component for p in present):
                continue
            stages.append({"configure": {"_0": [names[i] for i in sorted(component)]}})
            configured |= component
            progress = True
        if not progress:
            if ordered:
                ordered = False
                continue
            remaining = sorted(names[i] for i in unpack | (selected - configured))
            raise ValueError(f"No install order: {remaining}")
        ordered = True
    require(present == selected, "Unplanned final state")
    return stages


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    here = Path(__file__).resolve().parent
    parser.add_argument("--inventory", type=Path, default=here / "closure-inventory.json")
    parser.add_argument("--downloads", type=Path, default=here / "downloads.json")
    parser.add_argument("--status-file", type=Path, required=True,
                        help="Exact guest jbroot/Library/dpkg/status bytes")
    parser.add_argument("--guest-passwd", type=Path, required=True,
                        help="Guest /etc/passwd snapshot for uname lookup")
    parser.add_argument("--guest-group", type=Path, required=True,
                        help="Guest /etc/group snapshot for gname lookup")
    parser.add_argument("--output", type=Path, required=True,
                        help="New host output directory; use a separate directory outside the 256MiB download budget")
    parser.add_argument("--guest-base", required=True,
                        help="Absolute real guest directory to receive debs/ and prepared/")
    args = parser.parse_args()
    guest_base = args.guest_base.rstrip("/")
    require(guest_base.startswith("/") and guest_base != "" and
            ".." not in guest_base.split("/") and "\x00" not in guest_base,
            "Unsafe guest base")
    require(not args.output.exists(), "Refuse existing output directory")
    items = json.loads(args.inventory.read_text())["packages"]
    downloads = json.loads(args.downloads.read_text())
    require(len(items) <= 512 and items, "Invalid package count")
    downloaded = {x["package"]: x for x in downloads}
    require(len(downloaded) == len(downloads), "Repeated download identity")
    status_bytes = args.status_file.read_bytes()
    status = paragraphs(status_bytes)
    status_names = {x.get("package") for x in status}
    require(len(status_names) == len(status), "Duplicate status package")
    installed = []
    for fields in status:
        state = fields.get("status", "").split()
        require(len(state) == 3 and state[1] == "ok", "Malformed/unfinished installed status")
        if state[2] in ("not-installed", "config-files"):
            continue
        require(state[2] == "installed", "Initial database has unconfigured packages")
        installed.append(fields)
    users = read_identities(args.guest_passwd, 2)
    groups = read_identities(args.guest_group, 2)
    require(users.get("root") == 0 and groups.get("wheel") == 0,
            "Guest identity snapshots must include root uid=0 and wheel gid=0")
    candidate_fields = []
    for item in items:
        name = item["Package"].lower()
        require(TERM.fullmatch(name) is not None and len(name) >= 2, "Unsafe package identity")
        require(name not in status_names, f"Bootstrap package already recorded: {name}")
        require(item["Architecture"] in (ARCHITECTURE, "all"), "Foreign architecture requires adapter")
        require(name in downloaded and downloaded[name].get("ok") is True, "Missing verified download")
        local_path = Path(downloaded[name]["path"])
        require(local_path.is_file() and not local_path.is_symlink(), "Deb must be a regular file")
        sha, size = digest_file(local_path)
        require(sha == item["SHA256"] and size == int(item["Size"]), f"Pinned deb changed: {name}")
        require(size == downloaded[name]["bytes"] and sha == downloaded[name]["sha256"], "Download snapshot differs")
        control_path = here / "control-metadata" / name / "control"
        fields = control_fields(control_path.read_text(encoding="utf-8"))
        require(fields.get("package", "").lower() == name and fields.get("version") == item["Version"]
                and fields.get("architecture") == item["Architecture"], "Control metadata mismatch")
        fields["package"] = name
        fields["_source"] = item["source"]
        candidate_fields.append(fields)
    stages = plan_stages(installed, candidate_fields)
    # Reserve the measured uncompressed payload plus metadata before writing.
    # During every blob chunk another check preserves the hard disk floor.
    measured = json.loads((here / "static-deb-inspection.json").read_text())
    reserve = sum(x["regularPayloadBytes"] for x in measured) + 16 * 1024**2
    disk_guard(args.output.parent, reserve)
    args.output.mkdir(parents=True, exist_ok=False)
    write_bytes(args.output / "status.input", status_bytes)
    transaction_items, mappings, prepared_summary = [], [], []
    for item, fields in zip(items, candidate_fields):
        name = fields["package"]
        archive = Path(downloaded[name]["path"])
        prepared = args.output / "prepared" / name
        manifest_sha, real_fields = prepare_deb(archive, prepared, users, groups)
        for key in ("package", "version", "architecture") + RELATIONS:
            require(real_fields.get(key, "").lower() == fields.get(key, "").lower(),
                    f"Actual archive metadata differs: {name}:{key}")
        guest_archive = guest_base + "/debs/" + archive.name
        guest_prepared = guest_base + "/prepared/" + name
        transaction_items.append({"identity": name, "path": guest_archive,
                                  "sha256": item["SHA256"], "preparedPath": guest_prepared,
                                  "preparedSHA256": manifest_sha})
        mappings.append({"host": str(archive), "guest": guest_archive,
                         "sha256": item["SHA256"], "bytes": int(item["Size"])})
        for blob_path in sorted(prepared.iterdir()):
            sha, size = digest_file(blob_path)
            mappings.append({"host": str(blob_path), "guest": guest_prepared + "/" + blob_path.name,
                             "sha256": sha, "bytes": size})
        prepared_summary.append({"package": name, "manifestSHA256": manifest_sha})
        print("prepared", name, flush=True)
    transaction = {"install": transaction_items, "remove": [], "dryRun": True,
                   "stages": stages, "configureExisting": [],
                   "autoInstalled": sorted(x["identity"] for x in transaction_items
                                           if x["identity"] != "owngoal-bootstrap-vphone"),
                   "statusDigest": hashlib.sha256(status_bytes).hexdigest(),
                   "allowSystemRemoval": False, "ignoreScriptFailures": False,
                   "recoveryMode": False, "bootstrapInstall": True}
    job = {"transaction": {"_0": transaction}}
    job_size = len(json.dumps(job, separators=(",", ":")).encode())
    require(job_size <= 256 * 1024, "Installer job exceeds 256KiB")
    write_json(args.output / "job.dry-run.json", job)
    write_json(args.output / "stages.json", stages)
    write_json(args.output / "transfer-manifest.json", mappings)
    write_json(args.output / "prepared-summary.json", prepared_summary)
    print("dry-run job", args.output / "job.dry-run.json", "packages", len(items),
          "stages", len(stages), "bytes", job_size, flush=True)
    print("No guest command or maintainer script has been executed.", flush=True)


if __name__ == "__main__":
    main()
