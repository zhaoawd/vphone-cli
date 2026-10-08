import concurrent.futures,hashlib,json,os,stat,subprocess,time
from pathlib import Path
r=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli');exe=r/'.build/acceptance/B15/helper-client.app/Contents/MacOS/vphone-cli';installed=Path('/Library/PrivilegedHelperTools/com.vphone.cli.helper');rows=[]
assert hashlib.sha256(installed.read_bytes()).hexdigest()=='728b03532d1792cf2ef54077ac98cbcece910a55b367d00af1e3178e383b60ce'
def run(version):
 p=Path('/private/tmp')/('vphone-b15-helper-operation-retest-'+version+'.log');assert not p.exists()
 c=[str(exe),'helper','verify-bundle','--version',version,'--log-file',str(p)]
 start=time.monotonic();x=subprocess.run(c,capture_output=True,text=True,timeout=45)
 assert x.returncode!=0 and 'timed out' not in x.stderr.lower(),x.stderr
 expected=('Verifying Core Bundle '+version+'\nUnable to inspect at /Library/Application Support/vphone-launchpad: No such file or directory\n').encode()
 assert p.read_bytes()==expected,(p,p.read_bytes())
 assert stat.S_IMODE(p.stat().st_mode)==0o600 and p.stat().st_uid==os.getuid()
 holders=subprocess.run(['/usr/sbin/lsof','-nP','-t','--',str(p)],capture_output=True,text=True);assert holders.returncode==1 and not holders.stdout
 return {'command':c,'returncode':x.returncode,'stdout':x.stdout,'stderr':x.stderr,'elapsed_seconds':time.monotonic()-start,'log_path':str(p),'log_bytes':len(expected),'log_sha256':hashlib.sha256(expected).hexdigest(),'log_mode':'0600','log_closed_after_return':True,'exact_own_version_only':True}
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:rows=list(pool.map(run,['2.6.0','2.6.1']))
p=Path(rows[0]['log_path']);before=p.read_bytes();x=subprocess.run(rows[0]['command'],capture_output=True,text=True,timeout=45)
assert x.returncode!=0 and p.read_bytes()==before
result={'source_head':'ee7b9ec2c6be7a0402291afbf6e2eae0136c7f3b','helper_source_head':'55fd8ef57a6731e42cba0727f477bc9b25f0c9ca','helper_CDHash':'30ce6ce220a60617b6ae42066372bf3ac2e8ebe6','observations':rows,'existing_log_refused_without_overwrite':{'returncode':x.returncode,'stdout':x.stdout,'stderr':x.stderr,'unchanged':True},'two_signed_clients_logs_complete_and_separate':True,'successful_Bundle_install_or_verify':False,'ACK_evidence':'Underlying operation error is returned after finish ACK according to frozen service and current client implementation; no syscall or ACK packet tracing was performed.'}
Path('/private/tmp/vphone-b15-helper-log-probe.json').write_text(json.dumps(result,indent=2)+'\n');print({k:v for k,v in result.items() if k not in ['observations','existing_log_refused_without_overwrite']})
