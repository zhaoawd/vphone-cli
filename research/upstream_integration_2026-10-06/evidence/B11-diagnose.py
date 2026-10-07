import base64, hashlib, json, socket, time
from pathlib import Path

vm=Path('/Users/qcz3840/github/vphone-cli/vm-new')
out=Path('/private/tmp/vphone-b11-diagnose.json')
rows=[]
def call(t, **kw):
    q={'t':t, 'screen':False, **kw}
    with socket.socket(socket.AF_UNIX) as s:
        s.settimeout(45); s.connect(str(vm/'vphone.sock'))
        s.sendall(json.dumps(q).encode()+b'\n'); b=b''
        while b'\n' not in b:
            c=s.recv(65536)
            if not c: raise RuntimeError('closed before LF')
            b+=c
            if len(b)>4*1024*1024: raise RuntimeError('reply bound exceeded')
    r=json.loads(b.split(b'\n')[0]);rows.append({'request':q,'response':r});return r
try:
    r=call('capabilities')
    assert r['guest_connected'] and r['target']['instance_id']=='068574F6-DEF3-4910-88AB-57F5330C7A02'
    call('shell',cmd='PATH=/usr/bin:/bin:/usr/sbin:/sbin:/var/jb/usr/bin:/var/jb/bin; export PATH; id; ps -A -o pid=,comm= | grep -E "SpringBoard|backboardd|vphoned|Preferences|MobileSafari"; command -v notifyutil; command -v log; command -v launchctl; command -v uiopen; df -h /private/var',timeout_ms=10000)
    call('shell',cmd='PATH=/usr/bin:/bin:/usr/sbin:/sbin:/var/jb/usr/bin:/var/jb/bin; export PATH; notifyutil -g com.apple.springboard.lockstate; notifyutil -g com.apple.iokit.hid.displayStatus; notifyutil -g com.apple.springboard.finishedstartup',timeout_ms=10000)
    call('shell',cmd='PATH=/usr/bin:/bin:/usr/sbin:/sbin:/var/jb/usr/bin:/var/jb/bin; export PATH; log show --last 2m --style compact --predicate \'process == "SpringBoard" OR process == "backboardd" OR process == "uiopen"\' | tail -n 160',timeout_ms=30000)
    call('app_launch',bundle_id='com.apple.Preferences')
    call('shell',cmd='PATH=/usr/bin:/bin:/usr/sbin:/sbin:/var/jb/usr/bin:/var/jb/bin; export PATH; log show --last 20s --style compact --predicate \'process == "SpringBoard" OR process == "backboardd" OR process == "uiopen" OR process == "runningboardd"\' | tail -n 160',timeout_ms=30000)
    r=call('screenshot',color=True)
    if 'image' in r:
        b=base64.b64decode(r.pop('image'),validate=True)
        path=Path('/private/tmp/vphone-b11-screen.png');path.write_bytes(b)
        r['saved_image']={'path':str(path),'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest()}
finally:
    out.write_text(json.dumps(rows,ensure_ascii=False,indent=2)+'\n')
print('diagnostic_report='+str(out))
