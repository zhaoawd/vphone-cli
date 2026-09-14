#!/bin/zsh
# Provision the same locked environment used by the application.
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
export PIP_CACHE_DIR="${PIP_CACHE_DIR:-${PROJECT_ROOT}/.build/pip-cache}"
PYTHON="${VPHONE_HOST_PYTHON:-$(command -v python3)}"
exec "$PYTHON" "$SCRIPT_DIR/python_environment.py" \
  --base "$PROJECT_ROOT" --venv "${VPHONE_VENV_DIR:-${PROJECT_ROOT}/.venv}" "$@"
