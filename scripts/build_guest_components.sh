#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
cd "$PROJECT_ROOT"
python3 "$SCRIPT_DIR/check_guest_components.py"
make -C sources/VPhoneGuestComponents all
python3 "$SCRIPT_DIR/check_guest_components.py" --stage .build/guest-components-v2/stage --record
