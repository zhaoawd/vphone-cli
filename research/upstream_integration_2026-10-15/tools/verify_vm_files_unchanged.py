#!/usr/bin/env python3
"""Read back the exact metadata and small-file digests in a saved VM baseline."""

import argparse
import hashlib
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    baseline = json.loads(args.baseline.read_text())
    actual, differences = {}, []
    for directory, files in baseline.items():
        actual[directory] = {}
        for name, expected in files.items():
            path = Path(directory) / name
            try:
                info = path.lstat()
                observed = {key: getattr(info, key) for key in expected if key != "sha256"}
                if "sha256" in expected:
                    with path.open("rb") as stream:
                        observed["sha256"] = hashlib.file_digest(stream, "sha256").hexdigest()
            except OSError as error:
                observed = {"error": str(error)}
            actual[directory][name] = observed
            if observed != expected:
                differences.append({"path": str(path), "expected": expected, "actual": observed})
    report = {"schema": "vphone.vm-file-preservation/1", "baseline": str(args.baseline),
              "matched": not differences, "actual": actual, "differences": differences,
              "scope": "Only listed metadata and explicitly recorded digests; no full disk hash."}
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(f"VM file baseline matched: {not differences}; differences: {len(differences)}")
    return int(bool(differences))


if __name__ == "__main__":
    raise SystemExit(main())
