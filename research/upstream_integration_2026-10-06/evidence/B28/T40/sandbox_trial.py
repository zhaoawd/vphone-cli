import json,os,pathlib,subprocess
P=pathlib.Path; OUT=P('/private/tmp/vphone-b28-t40'); ROOT=OUT/'runtime-v1'
profile='''(version 1)
(allow default)
(deny network*)
(deny file-read* (subpath "/opt/homebrew"))
(deny file-read* (subpath "/Users/qcz3840/github/vphone-cli/..venv.generations"))
(deny file-read* (subpath "/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli"))
(deny file-read* (subpath "/Library/Python"))
'''
(OUT/'deny-original.sb').write_text(profile)
(ROOT/'extended_probe.py').write_text('''import ctypes,hashlib,importlib,json,pathlib,sys
root=pathlib.Path(__file__).resolve().parent
sys.path.insert(0,str(root/'site-packages'))
import runpy
sys.argv=[str(root/'project/scripts/check_python_runtime.py'),'--locked','--json']
try: runpy.run_path(sys.argv[0],run_name='__main__')
except SystemExit as e:
 if e.code: raise
import ssl,lzma,sqlite3,decimal,compression.zstd
assert lzma.decompress(lzma.compress(b't40'))==b't40'
assert compression.zstd.decompress(compression.zstd.compress(b't40'))==b't40'
assert sqlite3.connect(':memory:').execute('select 40').fetchone()==(40,)
assert decimal.Decimal('1.25')*2==decimal.Decimal('2.5')
ssl.create_default_context()
dyld=ctypes.CDLL('/usr/lib/libSystem.B.dylib')
dyld._dyld_image_count.restype=ctypes.c_uint32
dyld._dyld_get_image_name.argtypes=[ctypes.c_uint32]
dyld._dyld_get_image_name.restype=ctypes.c_char_p
images=[dyld._dyld_get_image_name(i).decode() for i in range(dyld._dyld_image_count())]
modules={k:str(getattr(v,'__file__','')) for k,v in sorted(sys.modules.items()) if getattr(v,'__file__',None)}
print(json.dumps({'extended_ok':True,'prefix':sys.prefix,'base_prefix':sys.base_prefix,'sys_path':sys.path,'images':images,'module_files':modules,'ssl_default_paths':ssl.get_default_verify_paths()._asdict()},sort_keys=True))
''')
env=json.loads((ROOT/'trial-env.json').read_text())
exe=ROOT/'Frameworks/Python.framework/Versions/3.14/bin/python3.14'
commands=[('sandbox-baseline-denied',['/usr/bin/sandbox-exec','-f',str(OUT/'deny-original.sb'),'/opt/homebrew/opt/python@3.14/bin/python3.14','-I','-S','-B','-c','print(40)']),('sandbox-naive-copy-denied',['/usr/bin/sandbox-exec','-f',str(OUT/'deny-original.sb'),str(exe),'-I','-S','-B','-c','print(40)']),('sandbox-controlled-locked',['/usr/bin/sandbox-exec','-f',str(OUT/'deny-original.sb'),str(exe),'-S','-B',str(ROOT/'run_locked.py')]),('sandbox-controlled-extended',['/usr/bin/sandbox-exec','-f',str(OUT/'deny-original.sb'),str(exe),'-S','-B',str(ROOT/'extended_probe.py')])]
report=[]
for label,argv in commands:
 useenv=env if label.startswith('sandbox-controlled') else {'PATH':'/usr/bin:/bin','HOME':str(ROOT),'TMPDIR':str(OUT),'PYTHONDONTWRITEBYTECODE':'1'}
 r=subprocess.run(argv,env=useenv,cwd=OUT,capture_output=True,timeout=120)
 (OUT/(label+'.stdout')).write_bytes(r.stdout); (OUT/(label+'.stderr')).write_bytes(r.stderr)
 entry={'label':label,'argv':argv,'returncode':r.returncode,'stdout':label+'.stdout','stderr':label+'.stderr'};report.append(entry)
 print(json.dumps(entry)); print(r.stderr.decode(errors='replace')[:500])
(OUT/'sandbox-trial.json').write_text(json.dumps(report,indent=2)+'\n')
