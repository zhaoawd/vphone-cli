import pathlib,json,subprocess,time,os,signal
out=pathlib.Path('/private/tmp/vphone-b26-t46-helper');pids=set()
for p in out.glob('*.json'):
 try:d=json.loads(p.read_text())
 except:continue
 if not isinstance(d,dict):continue
 for e in d.get('events',[]):
  for k in ['client_pid','service_pid']:
   if e.get(k):pids.add(int(e[k]))
records=[]
for pid in sorted(pids):
 args=['/bin/ps','-p',str(pid),'-o','pid=,ppid=,uid=,lstart=,command='];p=subprocess.run(args,text=True,capture_output=True)
 records.append({'pid':pid,'argv':args,'exit_code':p.returncode,'stdout':p.stdout,'stderr':p.stderr})
r={'scope':'Exact PIDs observed in this harness only; no system services queried or changed','records':records,'matching_live_pids':[x['pid'] for x in records if x['exit_code']==0 and x['stdout'].strip()],'signals_sent':[]}
(out/'process-final-readback.json').write_text(json.dumps(r,indent=2)+'\n');print('observed_pids',len(pids),'live',r['matching_live_pids'])
