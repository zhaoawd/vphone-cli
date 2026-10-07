import base64,hashlib,json,os,socket,subprocess
from pathlib import Path
root=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli')
main=Path('/Users/qcz3840/github/vphone-cli');vm=main/'vm-new'
def sha(b):return hashlib.sha256(b).hexdigest()
def git(path,*args):return subprocess.check_output(['git',*args],cwd=path).decode().strip()
import base64,hashlib,json,socket
from pathlib import Path
rows=[]
target={'vm':'vm-new','pid':92943,'instance_id':'068574F6-DEF3-4910-88AB-57F5330C7A02'}
def call(t,**kw):
 q={'t':t,'screen':False,'target':target,**kw}
 with socket.socket(socket.AF_UNIX) as s:
  s.settimeout(30);s.connect('/Users/qcz3840/github/vphone-cli/vm-new/vphone.sock');s.sendall(json.dumps(q).encode()+b'\n');b=b''
  while b'\n' not in b:
   c=s.recv(65536)
   if not c:raise RuntimeError('closed')
   b+=c
   if len(b)>4*1024*1024:raise RuntimeError('reply bound')
 r=json.loads(b.split(b'\n')[0]);rows.append({'request':q,'response':r});return r
def shot(name):
 r=call('screenshot',color=True)
 if 'image' in r:
  b=base64.b64decode(r.pop('image'),validate=True);path=Path('/private/tmp/vphone-b11-'+name+'.jpg');path.write_bytes(b);r['saved_image']={'path':str(path),'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest()}
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
newart=json.loads(Path('/private/tmp/vphone-b13-artifact-manifest.json').read_text());newcount=0
for app,record in newart['apps'].items():
 for n,m in record['files'].items():
  b=(root/'.build/acceptance/B13'/app/n).read_bytes();assert sha(b)==m['sha256'] and len(b)==m['bytes'];newcount+=1
 assert subprocess.run(['/usr/bin/codesign','--verify','--strict','--deep',str(root/'.build/acceptance/B13'/app)],capture_output=True).returncode==0
assert newcount==607
cleanup=json.loads(Path('/private/tmp/vphone-b13-api-cleanup-final.json').read_text());assert cleanup['temporary_API_proxy_and_worker_stopped']
correct=subprocess.run(['/usr/bin/security','authorizationdb','read','com.vphone.cli.helper.privileged'],capture_output=True,text=True)
Path('/private/tmp/vphone-b13-correct-helper-right-final.json').write_text(json.dumps({'command':correct.args,'returncode':correct.returncode,'stdout':correct.stdout,'stderr':correct.stderr,'read_only':True},indent=2)+'\n');assert correct.returncode!=0 and '-60005' in correct.stderr
state={'new_frozen_artifact_files_verified':newcount,'candidate_source_head':newart['source_head'],'processes':processes,'observations':rows,'implementation_head':git(root,'rev-parse','HEAD'),'worktree_status':git(root,'status','--porcelain'),'main_head':git(main,'rev-parse','HEAD'),'main_status':git(main,'status','--porcelain'),'config_sha256':sha((vm/'config.plist').read_bytes()),'guest_payload_sha256':sha((vm/'.vphoned.signed').read_bytes()),'udid_prediction_sha256':sha((vm/'udid-prediction.txt').read_bytes()),'free_bytes':os.statvfs(vm).f_bavail*os.statvfs(vm).f_frsize,'frozen_artifact_files_verified':599,'helper_debugserver_remaining':False,'classic_guest_payload_replaced':False,'temporary_API_trial_performed':True,'temporary_API_pair_stopped':True,'vm_2607_operated':False}
assert state['main_status']==state['worktree_status']==''
assert state['main_head']=='e8d825b3723d9ec72d31b050a79d353acd4b59bf'
old=json.loads(Path('/private/tmp/vphone-b10-final-state.json').read_text())
for k in ['config_sha256','guest_payload_sha256','udid_prediction_sha256']:assert state[k]==old[k]
Path('/private/tmp/vphone-b13-final-state.json').write_text(json.dumps(state,ensure_ascii=False,indent=2)+'\n')
print({'running_vm_pid':92943,'classic_guest_hash_matched':True,'frozen_files_verified':599,'main_source_clean':True,'helpers_remaining':False})
