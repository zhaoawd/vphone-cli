#!/bin/zsh
# Build an isolated helper candidate. Registration is a separate explicit verb.
set -euo pipefail
SCRIPT_DIR="${0:a:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
cd "$PROJECT_ROOT"
STAGE="$PROJECT_ROOT/.build/helper-candidate"
TEAM="${VPHONE_HELPER_SIGNING_TEAM:-}"
IDENTITY="${VPHONE_HELPER_SIGNING_IDENTITY:-}"
if [[ -n "$TEAM" && -z "$IDENTITY" ]] || [[ -z "$TEAM" && -n "$IDENTITY" ]]; then
  print -u2 -- 'Set both VPHONE_HELPER_SIGNING_TEAM and VPHONE_HELPER_SIGNING_IDENTITY, or neither.'
  exit 64
fi
mkdir -p "$STAGE"
"$PROJECT_ROOT/.venv/bin/python3" - "$STAGE" "$TEAM" <<'PY'
import plistlib, re, sys
from pathlib import Path
stage, team = Path(sys.argv[1]), sys.argv[2]
if team and not re.fullmatch(r'[A-Z0-9]{10}', team):
    raise SystemExit('Invalid Apple Team ID')
label = 'com.vphone.cli.helper'
def requirement(identifier):
    return f'anchor apple generic and identifier "{identifier}" and certificate leaf[subject.OU] = "{team}"'
info = {'CFBundleIdentifier': label, 'CFBundleVersion': '1', 'CFBundleShortVersionString': '2.0.8',
        'VPhoneHelperSigningTeam': team, 'SMAuthorizedClients':
        [requirement(name) for name in ['com.vphone.cli', 'com.vphone.cli.launchpad']] if team else []}
(stage/'Helper-Info.plist').write_bytes(plistlib.dumps(info))
(stage/'Helper-Launchd.plist').write_bytes(plistlib.dumps({'Label': label, 'MachServices': {label: True}}))
PY
swift build -c release --force-resolved-versions --product vphone-helper \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$STAGE/Helper-Info.plist" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __launchd_plist -Xlinker "$STAGE/Helper-Launchd.plist"
cp .build/release/vphone-helper "$STAGE/com.vphone.cli.helper"
codesign --force --sign "${IDENTITY:--}" --identifier com.vphone.cli.helper "$STAGE/com.vphone.cli.helper"
codesign --verify --strict "$STAGE/com.vphone.cli.helper"
if [[ -z "$TEAM" ]]; then
  print -- "Unconfigured candidate: $STAGE/com.vphone.cli.helper (registration disabled; no signing team)."
  exit 0
fi
"$STAGE/com.vphone.cli.helper" --check-configuration
[[ -d .build/vphone-cli.app ]] || { print -u2 -- 'Run make build first.'; exit 1; }
# An isolated copy preserves the ordinary ad hoc VM build and its signatures.
APP="$STAGE/vphone-cli.app"
[[ ! -e "$APP" ]] || { print -u2 -- "Candidate app already exists: $APP; preserve or remove it explicitly before rebuilding."; exit 1; }
ditto .build/vphone-cli.app "$APP"
mkdir -p "$APP/Contents/Library/LaunchServices"
cp "$STAGE/com.vphone.cli.helper" "$APP/Contents/Library/LaunchServices/com.vphone.cli.helper"
"$PROJECT_ROOT/.venv/bin/python3" - "$APP/Contents/Info.plist" "$TEAM" <<'PY'
import plistlib, sys
from pathlib import Path
p, team = Path(sys.argv[1]), sys.argv[2]
info = plistlib.loads(p.read_bytes())
info['VPhoneHelperSigningTeam'] = team
info['SMPrivilegedExecutables'] = {'com.vphone.cli.helper':
    f'anchor apple generic and identifier "com.vphone.cli.helper" and certificate leaf[subject.OU] = "{team}"'}
p.write_bytes(plistlib.dumps(info))
PY
codesign --force --sign "$IDENTITY" "$APP/Contents/MacOS/vphone-cli"
codesign --force --sign "$IDENTITY" "$APP"
codesign --verify --strict --deep "$APP"
print -- "Signed candidate: $APP"
print -- 'Registration was not performed. Use its CLI: helper register'
