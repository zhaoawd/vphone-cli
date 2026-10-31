#!/bin/zsh
set -euo pipefail
setopt noclobber
if (( EUID != 0 )); then
  print -u2 "Native administrator authentication required"
  exit 77
fi
exec '/usr/bin/env' '-i' 'PATH=/usr/bin:/bin:/usr/sbin:/sbin' 'PYTHONDONTWRITEBYTECODE=1' '/opt/homebrew/Cellar/python@3.14/3.14.5/Frameworks/Python.framework/Versions/3.14/bin/python3.14' '/Users/kolar/github/vphone-cli/research/upstream_integration_2026-10-15/tools/execute_t32_origin_identity_acceptance.py' '--execute-approved-plan' 'b98e0a565583ebd57380c5984be62ff0ed491fe499e7357c4d111c8fe5f87230' > '/Users/kolar/github/vphone-cli/.build/t32-t33-completion-20261023/origin-identity-acceptance-20261024-r2/root-execution.log' 2>&1
