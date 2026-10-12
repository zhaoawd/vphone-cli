#!/bin/zsh
# R9: checks only the approved fresh classic control VM.
set -euo pipefail
BUILD_ROOT=/private/tmp/vphone-v2-build-20261002
TEST_ROOT=/Users/kolar/vphone-v2-accept-20261002
VM=lp-classic-accept-20261002
CLI="$BUILD_ROOT/.build/vphone-cli.app/Contents/MacOS/vphone-cli"
export VPHONE_ROOT="$TEST_ROOT"
export VPHONE_PYTHON=/Users/kolar/github/vphone-cli/.venv/bin/python3
phase="${1:?offline|runtime}"
output="${2:?output directory}"
mkdir -p "$output"
case "$phase" in
  offline)
    check_code=0
    "$CLI" cfw update-environment "$VM" --library-root "$TEST_ROOT/VMs" \
      --project-root "$BUILD_ROOT" --components "$BUILD_ROOT/.build/guest-components-v2/stage" \
      --check --root-popup > "$output/r9-offline.json" || check_code=$?
    python3 - "$output/r9-offline.json" "$check_code" "$TEST_ROOT/VMs/$VM" <<'PY'
import json,sys,pathlib
report=json.load(open(sys.argv[1]))
assert int(sys.argv[2]) in (0,3),sys.argv[2]
assert report['classification']=='full_migration_required',report
assert report['bootstrap']['kind']=='none'
assert report['bootstrap']['v2_alias_present'] is False
assert report['bootstrap']['launchd_custom_loads']==[]
assert report['daemon']['sha256'] is None
assert report['daemon']['launchd_key_present'] is False
assert report['disk']['unchanged'] is True
assert all(not row['present'] for row in report['libraries'] if row['scope']=='local')
vm=pathlib.Path(sys.argv[3])
checkpoint=json.loads((vm/'.create-checkpoint/checkpoint.json').read_text())
restore=json.loads((vm/'restore-info.json').read_text())
stages={row['stage']:row['status'] for row in checkpoint['stages']}
assert all(stages[name]=='succeeded' for name in ('prepare','patch','restore','cfw','first_boot','verification')),stages
assert 'guest_environment' not in restore
print('R9 offline assertions passed: bootstrap none, v2 alias/API absent, disk unchanged')
PY
    ;;
  runtime)
    "$CLI" guest send "$VM" '{"t":"capabilities"}' --library-root "$TEST_ROOT/VMs" > "$output/r9-capabilities.json"
    python3 - "$output/r9-capabilities.json" <<'PY'
import json,sys
caps=json.load(open(sys.argv[1]))
assert caps['ok'] is True and caps['guest_connected'] is True
assert caps['boot_mode']=='normal'
assert 'file' in caps['guest_capabilities'] and 'location_owned' in caps['guest_capabilities']
assert caps['commands']['environment_update'] is False
assert caps['commands']['file_get'] is True and caps['commands']['file_put'] is True
print('R9 runtime assertions passed: classic connected, file/location capabilities present')
PY
    ;;
  *) print -u2 'unknown phase'; exit 64 ;;
esac
