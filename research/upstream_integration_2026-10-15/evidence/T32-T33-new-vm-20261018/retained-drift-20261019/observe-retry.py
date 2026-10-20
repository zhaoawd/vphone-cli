import datetime,json,subprocess
from pathlib import Path
raw=subprocess.check_output(['ps','-axo','pid,ppid,user,etime,time,pcpu,command'],text=True)
rows=[]
for line in raw.splitlines()[1:]:
 p=line.strip().split(None,6)
 if len(p)==7:rows.append(dict(pid=int(p[0]),ppid=int(p[1]),user=p[2],elapsed=p[3],cpuTime=p[4],cpuPercent=p[5],command=p[6]))
selected={2004}
while True:
 children={r['pid'] for r in rows if r['ppid'] in selected}
 if children<=selected:break
 selected|=children
result=dict(time=datetime.datetime.now(datetime.timezone.utc).isoformat(),processes=[r for r in rows if r['pid'] in selected])
p=Path('.build/t32-undo-mount-debug/retry-processes.jsonl')
with p.open('a') as f:f.write(json.dumps(result)+'\n')
print(json.dumps(result))
