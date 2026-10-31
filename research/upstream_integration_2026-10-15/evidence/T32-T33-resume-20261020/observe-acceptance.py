"""Read the scoped persistent acceptance process tree without privileged VM reads."""
import datetime,json,subprocess
from pathlib import Path
r=Path('/Users/kolar/github/vphone-cli');d=r/'.build/t32-resume-acceptance-20261020'
s=json.loads((d/'acceptance-state.json').read_text());rows=[]
for line in subprocess.check_output(['ps','-axo','user,pid,ppid,etime,time,pcpu,command'],text=True).splitlines()[1:]:
 p=line.strip().split(None,6)
 if len(p)==7:rows.append(dict(user=p[0],pid=int(p[1]),ppid=int(p[2]),elapsed=p[3],cpuTime=p[4],cpuPercent=p[5],command=p[6]))
script=str(r/'.build/t32-cryptex-symlink-final.app/Contents/Resources/scripts/cfw_install_host.sh')
roots={x['pid'] for x in rows if x['user']=='root' and x['command'].startswith('/bin/zsh '+script+' ') and 'vm-t32-t33-dsc-20261018' in x['command']}
selected=roots|{s['runnerPID'],s.get('childPID',-1)}
while True:
 children={x['pid'] for x in rows if x['ppid'] in selected}
 if children<=selected:break
 selected|=children
observed=[]
for x in rows:
 if x['pid'] in selected and not x['command'].startswith('/usr/bin/osascript '):
  observed.append({k:v for k,v in x.items() if k!='command'}|{'command':x['command'].replace(str(r)+'/','')[:420]})
report=dict(recordedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),stage=s['state'],runnerPID=s['runnerPID'],runnerAlive=any(x['pid']==s['runnerPID'] for x in rows),rootInstallerPIDs=sorted(roots),processes=observed)
with (d/'observations.jsonl').open('a') as out:out.write(json.dumps(report)+'\n')
print(json.dumps(report,indent=2))
