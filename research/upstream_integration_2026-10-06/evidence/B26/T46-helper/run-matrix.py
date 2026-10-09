import pathlib,subprocess,json,time,sys,uuid,hashlib
out=pathlib.Path('/private/tmp/vphone-b26-t46-helper');mode=sys.argv[1];label=mode+'-'+uuid.uuid4().hex[:8];run=out/'runs'/label;run.parent.mkdir(exist_ok=True)
args=[str(out/'TransportHarness.app/Contents/MacOS/TransportHarness'),mode,str(run)];start=time.monotonic();p=subprocess.run(args,text=True,capture_output=True,timeout=50);events=[]
for l in p.stdout.splitlines():
 try:events.append(json.loads(l))
 except:pass
r={'mode':mode,'label':label,'argv':args,'exit_code':p.returncode,'wall_seconds':time.monotonic()-start,'events':events,'stdout':p.stdout,'stderr':p.stderr,'logs':[]}
for f in run.glob('*.log'):
 r['logs'].append({'path':str(f),'content':f.read_text(),'sha256':hashlib.file_digest(open(f,'rb'),'sha256').hexdigest(),'mode':oct(f.stat().st_mode&0o777),'bytes':f.stat().st_size})
(out/f'{label}.json').write_text(json.dumps(r,indent=2)+'\n');print(json.dumps(r,ensure_ascii=False),flush=True);raise SystemExit(p.returncode)
