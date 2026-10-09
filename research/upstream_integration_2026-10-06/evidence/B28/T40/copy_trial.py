import hashlib,json,os,pathlib,shutil,subprocess
P=pathlib.Path
OUT=P('/private/tmp/vphone-b28-t40'); inventory=json.loads((OUT/'inventory.json').read_text())
ROOT=OUT/'runtime-v1'; ROOT.mkdir(mode=0o700,exist_ok=False)
assert inventory['candidate_copy_bytes']<1024**3
fw=P(inventory['roots']['framework']['path']); destfw=ROOT/'Frameworks/Python.framework'
shutil.copytree(fw,destfw,symlinks=True)
shutil.copytree(P(inventory['roots']['packages']['path']),ROOT/'site-packages',symlinks=True)
(ROOT/'lib').mkdir()
for source,entry in inventory['external_native'].items():
 target=ROOT/'lib'/P(entry['load_path']).name
 shutil.copy2(source,target)
 if P(source).name!=target.name: (ROOT/'lib'/P(source).name).symlink_to(target.name)
project=P('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli')
(ROOT/'project/scripts').mkdir(parents=True); (ROOT/'project/dependencies').mkdir()
for name in ['requirements.txt','scripts/check_python_runtime.py','dependencies/python-darwin-arm64-3.14.lock','dependencies/python-darwin-arm64-3.14.json']:
 shutil.copy2(project/name,ROOT/'project'/name)
(ROOT/'run_locked.py').write_text('import pathlib,runpy,sys\nsys.path.insert(0,str(pathlib.Path(__file__).resolve().parent/"site-packages"))\nsys.argv=[str(pathlib.Path(__file__).resolve().parent/"project/scripts/check_python_runtime.py"),"--locked","--json"]\nrunpy.run_path(sys.argv[0],run_name="__main__")\n')
(ROOT/'probe_info.py').write_text('import json,sys,sysconfig; print(json.dumps(dict(executable=sys.executable,prefix=sys.prefix,base_prefix=sys.base_prefix,path=sys.path,paths=sysconfig.get_paths()),indent=2))\n')
def observe(label,argv,env=None):
 r=subprocess.run(argv,capture_output=True,env=env,timeout=120)
 (OUT/(label+'.stdout')).write_bytes(r.stdout); (OUT/(label+'.stderr')).write_bytes(r.stderr)
 value={'argv':argv,'returncode':r.returncode,'stdout':label+'.stdout','stderr':label+'.stderr'}
 print(json.dumps(value)); return value
report={'copy':'preserve symlinks, file bytes, modes, xattrs with shutil.copytree/copy2; no signatures regenerated','commands':[]}
exe=destfw/'Versions/3.14/bin/python3.14'
env={'PATH':'/usr/bin:/bin','HOME':str(ROOT),'TMPDIR':str(OUT),'PYTHONDONTWRITEBYTECODE':'1'}
report['commands'].append(observe('naive-copy-info',[str(exe),'-I','-S','-B',str(ROOT/'probe_info.py')],env))
env.update(PYTHONHOME=str(destfw/'Versions/3.14'),DYLD_FRAMEWORK_PATH=str(ROOT/'Frameworks'),DYLD_LIBRARY_PATH=str(ROOT/'lib'))
report['relocated_environment']={k:env[k] for k in ['PYTHONHOME','DYLD_FRAMEWORK_PATH','DYLD_LIBRARY_PATH']}
report['commands'].append(observe('controlled-copy-info',[str(exe),'-S','-B',str(ROOT/'probe_info.py')],env))
report['commands'].append(observe('controlled-copy-locked',[str(exe),'-S','-B',str(ROOT/'run_locked.py')],env))
for label,path in [('source-framework',fw),('copy-framework',destfw),('source-python',fw/'Versions/3.14/bin/python3.14'),('copy-python',exe)]:
 report['commands'].append(observe(label+'-signature',['/usr/bin/codesign','--verify','--deep','--strict','--verbose=2',str(path)]))
(ROOT/'trial-env.json').write_text(json.dumps(env,indent=2)+'\n')
(OUT/'copy-trial.json').write_text(json.dumps(report,indent=2)+'\n')
print((OUT/'controlled-copy-locked.stdout').read_text()[:200])
