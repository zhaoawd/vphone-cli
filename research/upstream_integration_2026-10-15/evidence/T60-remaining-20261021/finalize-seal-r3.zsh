#!/bin/zsh
set -euo pipefail
app="$PWD/.build/t60-remaining-r3-20261021.app"
cli="$PWD/.build/t60-remaining-r3-20261021-cli.app"
.venv/bin/python - "$app" <<'PY'
from pathlib import Path
import json, subprocess, sys
app=Path(sys.argv[1]); p=app/'Contents/Resources/embedded-toolchain.json'
x=json.loads(p.read_text())
for key, name in [('vphoneCLI','vphone-cli'),('vphoneVM','vphone-vm')]:
    out=subprocess.check_output(['codesign','-dvvv',str(app/'Contents/Helpers/vphone-cli.app/Contents/MacOS'/name)],stderr=subprocess.STDOUT,text=True)
    x[key]['cdhash']=next(l.split('=',1)[1] for l in out.splitlines() if l.startswith('CDHash='))
p.write_text(json.dumps(x,indent=2,sort_keys=True)+'\n')
PY
codesign --force --sign - --identifier com.vphone.cli.launchpad "$app"
.venv/bin/python scripts/check_launchpad_bundle.py "$app" --reference "$cli"
