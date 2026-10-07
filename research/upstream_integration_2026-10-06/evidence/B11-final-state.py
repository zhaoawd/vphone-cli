import base64,hashlib,json,os,socket,subprocess
from pathlib import Path
root=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli')
main=Path('/Users/qcz3840/github/vphone-cli');vm=main/'vm-new'
def sha(b):return hashlib.sha256(b).hexdigest()
def git(path,*args):return subprocess.check_output(['git',*args],cwd=path).decode().strip()
exec(Path('/private/tmp/vphone-b11-app-boundary.py').read_text().split('\ntry:\n',1)[0])
call('capabilities')
call('environment_status')
call('shell',cmd='PATH=/usr/bin:/bin:/usr/sbin:/sbin:/var/jb/usr/bin:/var/jb/bin; export PATH; ps -A -o pid=,comm= | grep -E "Preferences.app/Preferences|MobileSafari.app/MobileSafari"',timeout_ms=10000)
r=call('file_get',path='/usr/bin/vphoned');assert r['ok'];b=base64.b64decode(r.pop('data'),validate=True);r['readback']={'bytes':len(b),'sha256':sha(b)}
assert r['readback']['sha256']=='306ed42ba743f6d5e71ebda142eeaa78f1f21fa14d3b37445dee8fc1401f9001'
ps=subprocess.check_output(['/bin/ps','-axo','pid=,ppid=,stat=,command='],text=True)
processes=[]
for line in ps.splitlines():
 cells=line.split(None,3)
 if len(cells)!=4:continue
 if cells[0]=='92943':
  assert cells[3].startswith(str(root/'.build/acceptance/B09/candidate.app/Contents/MacOS/vphone-vm'));processes.append({'pid':int(cells[0]),'ppid':int(cells[1]),'state':cells[2],'command':cells[3]})
 assert not (cells[3].startswith('/Applications/Xcode.app/Contents/Developer/Library/Frameworks/Python3.framework/') and '/private/tmp/vphone-b10-amfid-candidate/scoped.py' in cells[3])
 assert not cells[3].startswith('/Applications/Xcode.app/Contents/SharedFrameworks/LLDB.framework/Resources/debugserver')
assert len(processes)==1
art=json.loads((root/'research/upstream_integration_2026-10-06/evidence/B09-artifact-manifest.json').read_text())
for app in ['baseline.app','candidate.app','launchpad.app']:
 for n,m in art[app]['files'].items():
  b=(root/'.build/acceptance/B09'/app/n).read_bytes();assert sha(b)==m['sha256'] and len(b)==m['bytes']
state={'processes':processes,'observations':rows,'implementation_head':git(root,'rev-parse','HEAD'),'worktree_status':git(root,'status','--porcelain'),'main_head':git(main,'rev-parse','HEAD'),'main_status':git(main,'status','--porcelain'),'config_sha256':sha((vm/'config.plist').read_bytes()),'guest_payload_sha256':sha((vm/'.vphoned.signed').read_bytes()),'udid_prediction_sha256':sha((vm/'udid-prediction.txt').read_bytes()),'free_bytes':os.statvfs(vm).f_bavail*os.statvfs(vm).f_frsize,'frozen_artifact_files_verified':599,'helper_debugserver_remaining':False,'new_guest_payload_deployed':False,'vm_2607_operated':False}
assert state['main_status']==state['worktree_status']==''
assert state['main_head']=='e8d825b3723d9ec72d31b050a79d353acd4b59bf'
old=json.loads(Path('/private/tmp/vphone-b10-final-state.json').read_text())
for k in ['config_sha256','guest_payload_sha256','udid_prediction_sha256']:assert state[k]==old[k]
Path('/private/tmp/vphone-b11-final-state.json').write_text(json.dumps(state,ensure_ascii=False,indent=2)+'\n')
print({'running_vm_pid':92943,'classic_guest_hash_matched':True,'frozen_files_verified':599,'main_source_clean':True,'helpers_remaining':False})
