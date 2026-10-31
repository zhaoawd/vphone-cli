#!/bin/zsh
set -euo pipefail
cd /Users/kolar/github/vphone-cli
/bin/mkdir -m 700 /Users/kolar/github/vphone-cli/research/evidence/t32-t33-retirement-20261025/native-launch.claim
/usr/bin/nohup /Users/kolar/github/vphone-cli/.venv/bin/python -u /Users/kolar/github/vphone-cli/research/retire_t32_t33_states_20261025.py --apply-approved dd2799d50f0a3fbaa0edfe9af16e247f0c8b6cd8b9ea76e64ed99a8211b5a5bc > /Users/kolar/github/vphone-cli/research/evidence/t32-t33-retirement-20261025/root-execution.log 2>&1 < /dev/null &
retirement_pid=$!
print -r -- "$retirement_pid" > /Users/kolar/github/vphone-cli/research/evidence/t32-t33-retirement-20261025/root-launch.pid
/bin/chmod 0644 /Users/kolar/github/vphone-cli/research/evidence/t32-t33-retirement-20261025/root-launch.pid
