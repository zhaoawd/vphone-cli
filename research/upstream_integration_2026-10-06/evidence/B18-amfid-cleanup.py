import json,os,signal,subprocess,time
from pathlib import Path
scope='/private/tmp/vphone-b18-amfid-candidate/scoped.py'
lines=subprocess.check_output(['/bin/ps','-axo','pid=,ppid=,command='],text=True).splitlines()
rows=[l for l in lines if len(l.split(None,2))==3 and l.split(None,2)[2].startswith('/Applications/Xcode.app/Contents/Developer/Library/Frameworks/Python3.framework/') and l.split(None,2)[2].endswith(' -B '+scope)]
assert len(rows)==1,rows
pid=int(rows[0].split()[0]);command=rows[0].split(None,2)[2]
def alive():
 p=subprocess.run(['/bin/ps','-p',str(pid),'-o','command='],capture_output=True,text=True)
 if p.returncode==0:assert p.stdout.strip()==command
 return p.returncode==0
assert alive();os.kill(pid,signal.SIGINT);time.sleep(2);signals=['SIGINT']
if alive():os.kill(pid,signal.SIGTERM);signals.append('SIGTERM')
for _ in range(20):
 if not alive():break
 time.sleep(.25)
assert not alive()
allps=subprocess.check_output(['/bin/ps','-axo','pid=,ppid=,stat=,command='],text=True).splitlines();debug=[l for l in allps if len(l.split(None,3))==4 and l.split(None,3)[3].startswith('/Applications/Xcode.app/Contents/SharedFrameworks/LLDB.framework/Resources/debugserver')];amfid=[l for l in allps if len(l.split(None,3))==4 and l.split(None,3)[3]=='/usr/libexec/amfid']
result={'driver_before':rows,'signals':signals,'driver_gone':True,'debugserver_remaining':debug,'amfid':amfid};Path('/private/tmp/vphone-b18-amfid-cleanup.json').write_text(json.dumps(result,indent=2)+'\n');assert not debug and all(l.split()[1]=='1' for l in amfid);print(result)
