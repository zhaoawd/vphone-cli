#!/usr/bin/env python3
"""Assert saved real-disk readback reports against the frozen T52 candidates."""
import argparse
import json
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--before', type=Path, required=True)
parser.add_argument('--after', type=Path, required=True)
parser.add_argument('--comparison', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--metadata-before', type=Path)
parser.add_argument('--metadata-after', type=Path)
args = parser.parse_args()
before = json.loads(args.before.read_text())['report']
after = json.loads(args.after.read_text())['report']
comparison = json.loads(args.comparison.read_text())
checks = []

def check(name, value):
    checks.append(dict(name=name, passed=bool(value)))

check('before_offline_update', before['classification'] == 'offline_update')
check('after_already_current', after['classification'] == 'already_current')
check('same_vm', before['vm'] == after['vm'])
check('before_read_only_unchanged', before['disk']['unchanged'])
check('after_read_only_unchanged', after['disk']['unchanged'])
check('disk_published_with_new_inode', before['disk']['inode'] != after['disk']['inode'])
check('disk_size_preserved', before['disk']['size'] == after['disk']['size'])
check('identity_and_configuration_preserved', before['identity'] == after['identity'])
check('variant_records_preserved', before['variant_records'] == after['variant_records'])
check('guest_environment_records_preserved', before['guest_environment_records'] == after['guest_environment_records'])
check('five_replacements', set(before['replace']) == set(comparison['libraries']))
check('no_remaining_replacements', after['replace'] == [])
for name, expected in comparison['libraries'].items():
    old = next(row for row in before['libraries'] if row['name'] == name)
    new = next(row for row in after['libraries'] if row['name'] == name)
    check(name + '_baseline', old['actual_sha256'] == expected['baselineSHA256'])
    check(name + '_target', new['actual_sha256'] == expected['targetSHA256'])
    check(name + '_producer', old['expected_sha256'] == new['expected_sha256'] == expected['targetSHA256'])
if args.metadata_before or args.metadata_after:
    if not (args.metadata_before and args.metadata_after):
        parser.error('Both metadata captures are required together')
    old_metadata = json.loads(args.metadata_before.read_text())
    new_metadata = json.loads(args.metadata_after.read_text())
    for field in ('mode', 'uid', 'gid', 'size'):
        check('disk_' + field + '_preserved', old_metadata['files']['Disk.img'][field] == new_metadata['files']['Disk.img'][field])
    check('history_retained', set(old_metadata['history']).issubset(new_metadata['history']))
    check('new_history_record', len(new_metadata['history']) > len(old_metadata['history']))
result = dict(state='passed' if all(x['passed'] for x in checks) else 'failed', checks=checks,
              inputs={key: str(getattr(args, key)) for key in ('before', 'after', 'comparison')})
args.output.write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2))
raise SystemExit(0 if result['state'] == 'passed' else 1)
