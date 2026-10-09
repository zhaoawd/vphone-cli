import pathlib,subprocess,json,shutil,hashlib,plistlib
out=pathlib.Path('/private/tmp/vphone-b28-t24');repo=pathlib.Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli');original=repo/'.build/vphone-cli.app';app=out/'final-client.app';helper=out/'com.vphone.cli.helper';records=[]
def sha(p):return hashlib.file_digest(p.open('rb'),'sha256').hexdigest()
def manifest(root):
 return [{'path':str(p.relative_to(root)),'sha256':sha(p),'mode':oct(p.stat().st_mode&0o7777),'bytes':p.stat().st_size} for p in sorted(root.rglob('*')) if p.is_file() and not p.is_symlink()]
assert not app.exists();shutil.copytree(original,app,symlinks=True);shutil.copy2(out/'legacy-v1-built',helper)
(out/'client-original-manifest.json').write_text(json.dumps({'source':str(original),'files':manifest(original)},indent=2)+'\n')
(out/'client-copy-before-manifest.json').write_text(json.dumps(manifest(app),indent=2)+'\n')
p=app/'Contents/Info.plist';info=plistlib.loads(p.read_bytes());info['VPhoneHelperSigningTeam']='3AA3QL69MQ';info['SMPrivilegedExecutables']={'com.vphone.cli.helper':'anchor apple generic and identifier "com.vphone.cli.helper" and certificate leaf[subject.OU] = "3AA3QL69MQ"'};p.write_bytes(plistlib.dumps(info))
for name in ['client','helper']:
 src=app/'Contents/MacOS/vphone-cli' if name=='client' else helper;dst=out/(name+'-before-unsigned');shutil.copy2(src,dst)
 r=subprocess.run(['codesign','--remove-signature',str(dst)],capture_output=True,text=True);records.append({'argv':r.args,'returncode':r.returncode,'stdout':r.stdout,'stderr':r.stderr});assert r.returncode==0
(out/'unsigned-baseline.json').write_text(json.dumps({n:sha(out/(n+'-before-unsigned')) for n in ['client','helper']},indent=2)+'\n')
(out/'prepare-readback.json').write_text(json.dumps(records,indent=2)+'\n');print('client source/copied manifest files',len(manifest(original)),'main',sha(original/'Contents/MacOS/vphone-cli'),'helper',sha(helper))
