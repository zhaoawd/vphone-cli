import hashlib,json,os,stat,subprocess,time
from pathlib import Path
root=Path('/Users/qcz3840/github/vphone-cli/vm.backups');src=root/'b21-restored-vm-new-20261009';copy=root/'b23-origin-clone-20261009';renamed=root/'b23-origin-renamed-20261009';cli=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli/.build/debug/vphone-cli');out={'source':str(src),'commands':[],'identity_preserving':True,'concurrent_boot':False,'binding_state':'source missing; preserved as missing, origins unknown'}
assert not copy.exists() and not renamed.exists() and not (src/'launchpad.json').exists();r=subprocess.run(['/usr/sbin/lsof','-t',str(src/'Disk.img')],capture_output=True,text=True);assert r.returncode==1 and not r.stdout
assert os.statvfs(root).f_bavail*os.statvfs(root).f_frsize>16*1024**3
def run(args):
 t=time.monotonic();p=subprocess.run([str(cli),*args],capture_output=True,text=True,timeout=600);out['commands'].append({'args':args,'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr,'seconds':time.monotonic()-t});assert p.returncode==0,p.stderr
run(['vm','clone','--library-root',str(root),src.name,copy.name])
assert not (copy/'launchpad.json').exists() and not (copy/'vphone.sock').exists() and not (copy/'.vphone-runtime.json').exists()
run(['vm','rename','--library-root',str(root),copy.name,renamed.name]);assert not copy.exists() and renamed.exists()
exclude={'.vphone-runtime.json','vphone.sock','.cfw-history'}
def inventory(p):
 result={}
 for f in sorted(p.rglob('*')):
  rel=f.relative_to(p)
  if rel.parts[0] in exclude:continue
  st=f.lstat()
  if stat.S_ISREG(st.st_mode):
   h=hashlib.sha256()
   with f.open('rb') as v:
    while b:=v.read(8*1024**2):h.update(b)
   result[str(rel)]={'bytes':st.st_size,'sha256':h.hexdigest(),'mode':stat.S_IMODE(st.st_mode)}
  elif stat.S_ISLNK(st.st_mode):result[str(rel)]={'link':os.readlink(f)}
 return result
start=time.monotonic();a=inventory(src);b=inventory(renamed);assert a==b
out.update(equal_persistent_inventory=True,files=len(a),source_inventory=a,hash_seconds=time.monotonic()-start,retained_clone=str(renamed),limitations=['Same APFS volume does not prove independent physical backup','Source launchpad.json absent; this does not test preservation of a present binding or receipts','No VM launched and no kernel/environment update performed'])
Path('/private/tmp/vphone-b23-clone-rename.json').write_text(json.dumps(out,indent=2)+'\n');print({'files':len(a),'hash_seconds':out['hash_seconds'],'clone':str(renamed)})
