"""Verify fresh synthetic probe counters, without using them as timing benchmarks."""
import collections
import hashlib
import importlib.util
import json
from pathlib import Path
import sys

sys.dont_write_bytecode = True
root = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location(
    "trace_analysis", root.parent / "2026-10-14-kernel-io-performance/analyze-trace.py")
analysis = importlib.util.module_from_spec(spec)
spec.loader.exec_module(analysis)


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def read_probe(name):
    paths = list((root / "traces").glob(name + ".*.jsonl"))
    require(len(paths) == 1, "Expected exactly one fresh trace for " + name)
    path = paths[0]
    raw = path.read_text()
    analysis.analyze(raw)
    rows = [json.loads(line) for line in raw.splitlines()]
    footer = rows.pop()
    require(footer["complete"] and footer["dropped"] == 0 and footer["open_spans"] == 0,
            "Incomplete measurement")
    require(all(row["outcome"] == "success" for row in rows), "Unexpected failed span")
    ids = {row["id"]: row for row in rows}

    def descendants(parent):
        result = []
        for row in rows:
            current = row
            while current.get("parent_id"):
                if current["parent_id"] == parent["id"]:
                    result.append(row)
                    break
                current = ids[current["parent_id"]]
        return result

    return path, rows, descendants


path, rows, descendants = read_probe("final-capture-probe")
captures = [row for row in rows if row["phase"] == "kernelDisk.capture"]
require(len(captures) == 1, "Expected one capture")
children = descendants(captures[0])
sha = [row for row in children if row["phase"] == "generation.fileSHA256"]
require(len(sha) == 3, "Standalone capture SHA count differs")
size = 16 * 1024 * 1024 + 3
require(all(row["counts"]["bytes"] == size for row in sha), "Standalone SHA bytes differ")
require(collections.Counter(row["labels"]["role"] for row in sha)
        == {"live_disk": 2, "candidate_image": 1}, "Standalone SHA roles differ")
compare, = [row for row in children if row["phase"] == "kernelDisk.capture.compare"]
counts = compare["counts"]
require(counts["old_bytes"] == counts["new_bytes"] == size, "Scan bytes differ")
require(counts["old_sha_bytes"] == counts["new_sha_bytes"] == size
        and counts["fused_sha_finalizations"] == 2, "Fused SHA coverage differs")
require(counts["old_read_calls"] == counts["new_read_calls"] == 18, "pread/EOF attempts differ")
require(counts["blocks"] == 4097 and counts["changed_blocks"] == 5
        and counts["logical_bytes"] == size, "Block coverage differs")
syncs = [row for row in children if row["phase"] == "kernelDisk.fsync"]
require(len(syncs) == 3 and all(row["started_ns"] + row["elapsed_ns"] <= compare["started_ns"]
                              for row in syncs), "Comparison was not after all three syncs")
capture_result = dict(trace=path.name, trace_sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                      size=size, standalone_sha=3, fused_sha=2, sha_logical_bytes=5 * size,
                      explicit_read_bytes=sum(row["counts"]["bytes"] for row in sha)
                      + counts["old_bytes"] + counts["new_bytes"], compare=counts)

path, rows, descendants = read_probe("final-lifecycle-probe")
publications = [row for row in rows if row["phase"] == "kernelUpdate.publishQualified"]
require(len(publications) == 3, "Expected two updates and one rollback")
observations = []
for publication in publications:
    origins = [row for row in descendants(publication) if row["phase"] == "transaction.verifyOrigin"]
    require(collections.Counter(row["labels"]["point"] for row in origins)
            == {"candidate": 2, "published": 6}, "Origin checkpoint count differs")
    for origin in origins:
        images = [row for row in descendants(origin) if row["phase"] == "generation.fileSHA256"
                  and row["labels"].get("role") in ("live_disk", "candidate_image")]
        point = origin["labels"]["point"]
        require(len(images) == (2 if point == "candidate" else 4), "Origin image SHA count differs")
        require(all(row["counts"]["bytes"] == 12288 for row in images), "Origin image SHA bytes differ")
        role = "candidate_image" if point == "candidate" else "live_disk"
        require(all(row["labels"]["role"] == role for row in images), "Origin image SHA role differs")
        observations.append(dict(point=point, image_sha_calls=len(images),
                                 image_sha_bytes=sum(row["counts"]["bytes"] for row in images)))

result = dict(passed=True, scope="Synthetic helper and update/rollback counters; no comparative timing or VM acceptance",
              capture=capture_result,
              lifecycle=dict(trace=path.name, trace_sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                             publications=3, candidate_checks=6, published_checks=18, origins=observations))
(root / "trace-check.json").write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps({"passed": True, "capture_read_bytes": capture_result["explicit_read_bytes"],
                  "candidate_checks": 6, "published_checks": 18}, indent=2))
