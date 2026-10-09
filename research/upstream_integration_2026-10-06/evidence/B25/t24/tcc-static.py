import json, plistlib, subprocess, hashlib
from pathlib import Path
root=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli')
report={'scope':'Static signature/configuration only. No TCC reset, DB changes, VM/GUI launch or authorization request performed.', 'artifacts':{}, 'sources':{}}
for name,path in {'cli':'.build/vphone-cli.app/Contents/MacOS/vphone-cli','vm':'.build/vphone-cli.app/Contents/MacOS/vphone-vm','launchpad':'.build/vphone-launchpad.app/Contents/MacOS/vphone-launchpad','launcher':'.build/vphone-launchpad.app/Contents/MacOS/vphone-launchpad-launcher'}.items():
    p=root/path
    results=[]
    for argv in [('codesign','-dvvv',str(p)),('codesign','-d','--entitlements','-','--xml',str(p)),('codesign','--verify','--strict',str(p)),('otool','-s','__TEXT','__info_plist',str(p))]:
        result=subprocess.run(argv,text=True,capture_output=True)
        results.append({'argv':argv,'exit_code':result.returncode,'stdout':result.stdout,'stderr':result.stderr})
    report['artifacts'][name]={'path':str(p),'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'checks':results}
for relative in ('sources/Info.plist','sources/VPhoneLaunchpad-Info.plist','sources/vphone.entitlements'):
    report['sources'][relative]=plistlib.loads((root/relative).read_bytes())
report['location_helper']='No separate location helper target exists in the local Package.swift. CoreLocation calls occur in VPhoneLocationProvider in vphone-vm.'
Path('/private/tmp/vphone-b25-t24/tcc-static.json').write_text(json.dumps(report,indent=2)+'\n')
