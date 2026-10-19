import datetime,json,subprocess
from pathlib import Path
root=Path.cwd();out=root/'.build/t32-rebaseline-debug'
rows=[]
for line in subprocess.check_output(['ps','-axo','pid,ppid,etime,time,pcpu,command'],text=True).splitlines()[1:]:
 p=line.strip().split(None,5)
 if len(p)==6:rows.append(dict(pid=int(p[0]),ppid=int(p[1]),elapsed=p[2],cpuTime=p[3],cpuPercent=p[4],command=p[5]))
selected={19942}
while True:
 children={r['pid'] for r in rows if r['ppid'] in selected}
 if children<=selected:break
 selected|=children
observed=[r for r in rows if r['pid'] in selected]
state=dict(time=datetime.datetime.now(datetime.timezone.utc).isoformat(),processes=observed)
with (out/'installation-processes.jsonl').open('a') as f:f.write(json.dumps(state)+'\n')
summary=[dict(elapsed=r['elapsed'],cpuPercent=r['cpuPercent'],command=r['command'].replace(str(root)+'/','')) for r in observed if r['pid']!=19942 and r['pid']!=22395]
print(json.dumps(dict(active=summary,continuation=json.loads((out/'continuation.json').read_text()))))
