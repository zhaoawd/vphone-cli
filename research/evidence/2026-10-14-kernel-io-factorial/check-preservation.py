"""Check frozen acceptance inputs and the pre-benchmark workspace snapshot."""
import argparse
import hashlib
import json
from pathlib import Path

E = Path(__file__).resolve().parent
PROJECT = E.parents[2]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--after-docs', action='store_true')
    args = parser.parse_args()
    old = json.loads((E / 'initial-workspace-manifest.json').read_text())
    differences = []
    for name, sha in old.items():
        actual = digest(PROJECT / name)
        if actual != sha:
            differences.append(dict(path=name, before=sha, after=actual))
    allowed = {'docs/kernel-io-performance.md'} if args.after_docs else set()
    assert all(item['path'] in allowed for item in differences), differences
    protected = json.loads((PROJECT / 'research/evidence/2026-10-14-kernel-io-integration/protected-inputs.json').read_text())
    checks = {}
    for group, files in protected.items():
        checks[group] = dict(checked=len(files), mismatches=[name for name, sha in files.items()
            if digest(Path(name) if Path(name).is_absolute() else PROJECT / name) != sha])
    manifest = json.loads((PROJECT / 'research/evidence/2026-10-14-kernel-io-integration/frozen-v9-source-manifest.json').read_text())
    snapshot = PROJECT / 'research/evidence/2026-10-14-kernel-io-integration/frozen-v9-source'
    checks['frozen_v9_source'] = dict(checked=len(manifest['sourceFiles']), mismatches=[item['path']
        for item in manifest['sourceFiles'] if digest(snapshot / item['path']) != item['sha256']])
    assert all(not check['mismatches'] for check in checks.values()), checks
    variants = json.loads((E / 'variants.json').read_text())['variants']
    test = PROJECT / 'tests/FirmwarePatcherTests/FirmwareKernelIOFactorialBenchmarkTests.swift'
    assert all(digest(test) == v['benchmark_test_sha256'] for v in variants)
    output = dict(passed=True, existing_workspace_files_checked=len(old),
                  expected_document_changes=differences, protected=checks,
                  added_benchmark_matches_all_frozen_artifacts=True,
                  scope='No VM image content was read by this check')
    (E / ('final-preservation-check.json' if args.after_docs else 'pre-document-preservation-check.json')).write_text(
        json.dumps(output, indent=2) + '\n')
    print(json.dumps(output, indent=2))


if __name__ == '__main__':
    main()
