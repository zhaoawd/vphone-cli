import json,os,signal,socket,subprocess,time
from pathlib import Path
vm=Path('/Users/qcz3840/github/vphone-cli/vm-new');target={'vm':'vm-new','pid':92943,'instance_id':'068574F6-DEF3-4910-88AB-57F5330C7A02'}
q={'t':'capabilities','screen':False,'target':target}
with socket.socket(socket.AF_UNIX) as s:
 s.settimeout(10);s.connect(str(vm/'vphone.sock'));s.sendall(json.dumps(q).encode()+b'\n');data=b''
 while b'\n' not in data:data+=s.recv(65536)
 reply=json.loads(data.split(b'\n')[0]);assert reply['ok'] and reply['target']['instance_id']==target['instance_id']
cmd=['/bin/ps','-p','92943','-o','pid=,ppid=,lstart=,command='];before=subprocess.run(cmd,capture_output=True,text=True);assert before.returncode==0 and 'acceptance/B09/candidate.app/Contents/MacOS/vphone-vm --config '+str(vm/'config.plist') in before.stdout
assert subprocess.run(cmd,capture_output=True,text=True).stdout==before.stdout
os.kill(92943,signal.SIGINT);obs=[]
files=[str(p) for p in vm.rglob('*') if p.is_file() and not p.is_symlink()]
for i in range(30):
 time.sleep(1);ps=subprocess.run(cmd,capture_output=True,text=True);h=subprocess.run(['/usr/sbin/lsof','-nP','-t','--',*files],capture_output=True,text=True,timeout=10);obs.append({'pid_returncode':ps.returncode,'pid_stdout':ps.stdout,'disk_holders_returncode':h.returncode,'disk_holders':h.stdout,'stderr':h.stderr})
 if ps.returncode!=0 and h.returncode==1 and not h.stdout.strip():break
result={'target':target,'verified_process':before.stdout,'capabilities_before':reply,'signal':'SIGINT','observations':obs,'process_exited':ps.returncode!=0,'disk_released':h.returncode==1 and not h.stdout.strip()};Path('/private/tmp/vphone-b14-stop-old.json').write_text(json.dumps(result,indent=2)+'\n');assert result['process_exited'] and result['disk_released'];print({'old_vm_stopped':True,'disk_free':True})
