import json
from pathlib import Path

# Reuse only the target-fenced transport functions; do not rerun the prior probe.
exec(Path('/private/tmp/vphone-b11-app-boundary.py').read_text().split('\ntry:\n',1)[0])
try:
 r=call('shell',cmd='PATH=/usr/bin:/bin:/usr/sbin:/sbin:/var/jb/usr/bin:/var/jb/bin; export PATH; command -v su; id mobile',timeout_ms=10000)
 if r.get('code')==0 and 'uid=501(mobile)' in r.get('stdout','') and '/su\n' in r.get('stdout',''):
  call('shell',cmd="PATH=/usr/bin:/bin:/usr/sbin:/sbin:/var/jb/usr/bin:/var/jb/bin; export PATH; su mobile -c '/var/jb/usr/bin/uiopen --bundleid com.apple.Preferences'",timeout_ms=10000)
  call('shell',cmd='PATH=/usr/bin:/bin:/usr/sbin:/sbin:/var/jb/usr/bin:/var/jb/bin; export PATH; ps -A -o pid=,comm= | grep -E "Preferences.app/Preferences|MobileSafari.app/MobileSafari"',timeout_ms=10000)
  call('app_foreground')
  shot('after-mobile-uiopen')
finally:Path('/private/tmp/vphone-b11-user-context.json').write_text(json.dumps(rows,ensure_ascii=False,indent=2)+'\n')
