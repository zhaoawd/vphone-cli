import subprocess,os,sys,json,time,hashlib
from pathlib import Path
root=Path('/Users/qcz3840/github/vphone-cli')
destination=root/'research/evidence/2026-10-13-task7-fix1'
name=sys.argv[1];cmd=sys.argv[2:]
env={k:v for k,v in os.environ.items() if not k.startswith(('VPHONE_TEST_','VPHONE_LESS_','VPHONE_C4_'))}
def git(*args):return subprocess.check_output(['git',*args],cwd=root,text=True).strip()
paths=set(git('diff','--name-only','--','sources','tests','scripts','Package.swift','Package.resolved').splitlines())
paths.update(git('ls-files','--others','--exclude-standard','--','sources','tests').splitlines())
files={p:hashlib.sha256((root/p).read_bytes()).hexdigest() for p in sorted(paths) if (root/p).is_file()}
source={'baseGitSHA':git('rev-parse','HEAD'),'modifiedSourceSHA256':files}
source['sourceSHA256']=hashlib.sha256(json.dumps(source,sort_keys=True).encode()).hexdigest()
(destination/(name+'.source.json')).write_text(json.dumps(source,indent=2)+'\n')
start=time.time()
with (destination/(name+'.log')).open('w') as f:r=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT,env=env,cwd=root)
(destination/(name+'.command.json')).write_text(json.dumps({'argv':cmd,'exit':r.returncode,'seconds':time.time()-start,'sourceSHA256':source['sourceSHA256']},indent=2)+'\n')
print(name,r.returncode)
