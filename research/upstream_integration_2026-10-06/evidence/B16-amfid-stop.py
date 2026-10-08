import json,os,signal,subprocess,time
from pathlib import Path
pid=5503;cmd=['/bin/ps','-p',str(pid),'-o','pid=,ppid=,lstart=,command='];p=subprocess.run(cmd,capture_output=True,text=True);assert p.returncode==0 and '/private/tmp/vphone-b16-amfid-candidate/scoped.py' in p.stdout
assert subprocess.run(cmd,capture_output=True,text=True).stdout==p.stdout
k=subprocess.run(['/usr/bin/sudo','-n','/bin/kill','-TERM',str(pid)],capture_output=True,text=True);assert k.returncode==0
for i in range(10):
 time.sleep(.5);q=subprocess.run(cmd,capture_output=True,text=True)
 if q.returncode!=0:break
allps=subprocess.check_output(['/bin/ps','-axo','pid=,ppid=,stat=,command='],text=True);matches=[];amfid=[]
for line in allps.splitlines():
 cols=line.split(None,3)
 if len(cols)!=4:continue
 if cols[3].startswith('/Applications/Xcode.app/Contents/SharedFrameworks/LLDB.framework/Resources/debugserver') or cols[3].startswith('/Applications/Xcode.app/Contents/Developer/Library/Frameworks/Python3.framework/') and '/private/tmp/vphone-b16-amfid-candidate/scoped.py' in cols[3]:matches.append(line)
 if cols[3]=='/usr/libexec/amfid':amfid.append(line)
r={'signal':'SIGTERM after interactive SIGINT did not exit','before':p.stdout,'helper_gone':q.returncode!=0,'helper_or_debugserver_remaining':matches,'amfid':amfid};Path('/private/tmp/vphone-b16-amfid-stop.json').write_text(json.dumps(r,indent=2)+'\n');assert q.returncode!=0 and not matches and len(amfid)==1 and amfid[0].split()[1]=='1';print(r)
