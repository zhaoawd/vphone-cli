import hashlib,json,os,stat,subprocess,time
from pathlib import Path
root=Path('/private/tmp/vphone-b28-t24');prepared=json.loads((root/'matrix-commands.prepared.json').read_text());rows=[]
def identity(p):
 if not p.exists():return {'exists':False}
 s=p.stat();return {'exists':True,'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'mode':oct(stat.S_IMODE(s.st_mode)),'uid':s.st_uid,'gid':s.st_gid,'bytes':s.st_size,'mtime_ns':s.st_mtime_ns}
for item in prepared:
 cwd=Path(item['working_directory']);assert cwd.is_dir();log=cwd/'operation.log';before=identity(log)
 if item['log_case']=='new':assert not before['exists']
 if item['log_case']=='existing':assert before['sha256']==item['existing_log_baseline']['sha256']
 start=time.monotonic();p=subprocess.run(item['argv'],cwd=cwd,capture_output=True,timeout=item['timeout_seconds']);elapsed=time.monotonic()-start
 Path(item['stdout_path']).write_bytes(p.stdout);Path(item['stderr_path']).write_bytes(p.stderr);after=identity(log)
 exact=b'Installed helper protocol differs from this client. Register the matching signed helper.' in p.stderr
 row={'verb':item['verb'],'log_case':item['log_case'],'argv':item['argv'],'exit':p.returncode,'seconds':elapsed,'stdout':p.stdout.decode(errors='replace'),'stderr':p.stderr.decode(errors='replace'),'protocol_refused':exact,'log_before':before,'log_after':after,'log_preserved':before==after};rows.append(row);(root/'actual-six-row-matrix.json').write_text(json.dumps(rows,indent=2)+'\n');print(json.dumps(row),flush=True)
 assert p.returncode!=0 and exact and before==after,row
print('ALL_SIX_PROTOCOL_REFUSALS_PASSED',flush=True)
