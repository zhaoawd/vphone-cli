import json,os,pathlib,subprocess
P=pathlib.Path; OUT=P('/private/tmp/vphone-b28-t40'); ROOT=OUT/'runtime-v1'
launcher=ROOT/'python-runtime'
launcher.write_text('''#!/bin/zsh
set -euo pipefail
runtime_root=${0:a:h}
export PYTHONHOME="$runtime_root/Frameworks/Python.framework/Versions/3.14"
export PYTHONPATH="$runtime_root/site-packages"
export DYLD_FRAMEWORK_PATH="$runtime_root/Frameworks"
export DYLD_LIBRARY_PATH="$runtime_root/lib"
export PYTHONDONTWRITEBYTECODE=1
unset PYTHONEXECUTABLE PYTHONUSERBASE __PYVENV_LAUNCHER__ PYTHONSTARTUP
exec "$PYTHONHOME/bin/python3.14" -S -B "$@"
'''); launcher.chmod(0o700)
(ROOT/'tls_probe.py').write_text('''import json,ssl,certifi
ctx=ssl.create_default_context()
print(json.dumps({'certifi_ca':certifi.where(),'default_verify_paths':ssl.get_default_verify_paths()._asdict(),'cert_store_stats':ctx.cert_store_stats()},sort_keys=True))
''')
commands=[('sandbox-launcher-locked',[str(launcher),str(ROOT/'project/scripts/check_python_runtime.py'),'--locked','--json'],{}),('sandbox-launcher-tls-default',[str(launcher),str(ROOT/'tls_probe.py')],{}),('sandbox-launcher-tls-certifi',[str(launcher),str(ROOT/'tls_probe.py')],{'SSL_CERT_FILE':str(ROOT/'site-packages/certifi/cacert.pem'),'SSL_CERT_DIR':str(ROOT/'empty-ca-dir')})]
(ROOT/'empty-ca-dir').mkdir(exist_ok=False)
report=[]
for label,args,extra in commands:
 argv=['/usr/bin/sandbox-exec','-f',str(OUT/'deny-original.sb')]+args
 env={'PATH':'/usr/bin:/bin','HOME':str(ROOT),'TMPDIR':str(OUT),'PYTHONPATH':'/opt/homebrew/blocked-inherited-path'}; env.update(extra)
 r=subprocess.run(argv,cwd=OUT,env=env,capture_output=True,timeout=120)
 (OUT/(label+'.stdout')).write_bytes(r.stdout); (OUT/(label+'.stderr')).write_bytes(r.stderr)
 entry={'label':label,'argv':argv,'environment_changes':extra,'returncode':r.returncode,'stdout':label+'.stdout','stderr':label+'.stderr'};report.append(entry)
 print(json.dumps(entry)); print(r.stdout.decode(errors='replace')[:200] if 'locked' in label else r.stdout.decode(errors='replace'));print(r.stderr.decode(errors='replace')[:1000])
(OUT/'launcher-trial.json').write_text(json.dumps(report,indent=2)+'\n')
