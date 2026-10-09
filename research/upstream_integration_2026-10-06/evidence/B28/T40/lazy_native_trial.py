import json,pathlib,shutil,subprocess
P=pathlib.Path; OUT=P('/private/tmp/vphone-b28-t40'); ROOT=OUT/'runtime-v1'
(ROOT/'lazy_usb_probe.py').write_text('''import json,sys
from usb.backend.libusb1 import _load_library
try:
 lib=_load_library()
 print(json.dumps({'libusb_loaded':True,'name':lib._name}))
except Exception as error:
 print(json.dumps({'libusb_loaded':False,'error_type':type(error).__name__,'error':str(error)}))
 sys.exit(1)
''')
shutil.copy2(P('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli/scripts/pymobiledevice3_bridge.py'),ROOT/'project/scripts/pymobiledevice3_bridge.py')
report=[]
commands=[('source-lazy-usb',['/Users/qcz3840/github/vphone-cli/..venv.generations/env-9asn3gud/bin/python3','-I','-B','-c','import json; from usb.backend.libusb1 import _load_library; lib=_load_library(); print(json.dumps(dict(libusb_loaded=True,name=lib._name)))']),('sandbox-launcher-lazy-usb',['/usr/bin/sandbox-exec','-f',str(OUT/'deny-original.sb'),str(ROOT/'python-runtime'),str(ROOT/'lazy_usb_probe.py')]),('sandbox-launcher-bridge-help',['/usr/bin/sandbox-exec','-f',str(OUT/'deny-original.sb'),str(ROOT/'python-runtime'),str(ROOT/'project/scripts/pymobiledevice3_bridge.py'),'--help'])]
for label,argv in commands:
 env={'PATH':'/usr/bin:/bin','HOME':str(ROOT),'TMPDIR':str(OUT),'PYTHONDONTWRITEBYTECODE':'1'}
 r=subprocess.run(argv,cwd=OUT,env=env,capture_output=True,timeout=120)
 (OUT/(label+'.stdout')).write_bytes(r.stdout); (OUT/(label+'.stderr')).write_bytes(r.stderr)
 entry={'label':label,'argv':argv,'returncode':r.returncode,'stdout':label+'.stdout','stderr':label+'.stderr'};report.append(entry)
 print(json.dumps(entry)); print(r.stdout.decode(errors='replace')[:300]); print(r.stderr.decode(errors='replace')[:500])
(OUT/'lazy-native-trial.json').write_text(json.dumps(report,indent=2)+'\n')
