import json,pathlib,subprocess
P=pathlib.Path; OUT=P('/private/tmp/vphone-b28-t40'); ROOT=OUT/'runtime-v1'
env=json.loads((ROOT/'trial-env.json').read_text()); exe=ROOT/'Frameworks/Python.framework/Versions/3.14/bin/python3.14'
report=[]
for label,script in [('sandbox-env-locked','run_locked.py'),('sandbox-env-extended','extended_probe.py')]:
 argv=['/usr/bin/sandbox-exec','-f',str(OUT/'deny-original.sb'),'/usr/bin/env']+[k+'='+v for k,v in sorted(env.items())]+[str(exe),'-S','-B',str(ROOT/script)]
 r=subprocess.run(argv,cwd=OUT,env={'PATH':'/usr/bin:/bin'},capture_output=True,timeout=120)
 (OUT/(label+'.stdout')).write_bytes(r.stdout); (OUT/(label+'.stderr')).write_bytes(r.stderr)
 entry={'label':label,'argv':argv,'returncode':r.returncode,'stdout':label+'.stdout','stderr':label+'.stderr'};report.append(entry)
 print(json.dumps(entry)); print(r.stderr.decode(errors='replace')[:1500])
(OUT/'sandbox-env-trial.json').write_text(json.dumps(report,indent=2)+'\n')
