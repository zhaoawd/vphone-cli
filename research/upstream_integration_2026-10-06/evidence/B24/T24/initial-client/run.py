import pathlib,subprocess,json,hashlib,plistlib,uuid,time,stat
R=pathlib.Path('/private/tmp/vphone-b24-helper-v1')
CLI=pathlib.Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli/.build/helper-candidate/vphone-cli.app/Contents/MacOS/vphone-cli')
LABEL='com.vphone.cli.helper'
ROOT=pathlib.Path('/private/var/tmp/vphone-b24-legacy-'+str(uuid.uuid4()))
def call(args,timeout=30):
 t=time.monotonic();p=subprocess.run([str(x) for x in args],capture_output=True,text=True,timeout=timeout)
 return {'args':[str(x) for x in args],'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr,'seconds':time.monotonic()-t}
def checked(args):
 r=call(args);assert r['exit']==0,r;return r
def digest(p):return hashlib.file_digest(p.open('rb'),'sha256').hexdigest()
def store():
 p=pathlib.Path('/Library/Application Support/vphone-launchpad/Bundles'); out={}
 if not p.exists():return {'exists':False}
 for f in sorted(p.rglob('*')):
  s=f.lstat();item={'size':s.st_size,'mode':stat.S_IMODE(s.st_mode),'uid':s.st_uid,'gid':s.st_gid}
  if f.is_file() and not f.is_symlink():item['sha256']=digest(f)
  if f.is_symlink():item['link']=f.readlink().as_posix()
  out[f.relative_to(p).as_posix()]=item
 return out
baseline=call(['/bin/launchctl','print','system/'+LABEL]);assert baseline['exit']!=0,baseline
assert not pathlib.Path('/Library/PrivilegedHelperTools/'+LABEL).exists()
assert not ROOT.exists()
rule_before=call(['/usr/bin/security','authorizationdb','read',LABEL+'.privileged'])
snapshot=store(); result={'scope':'production signed client with controlled protocol-v1 system Mach service; not historical helper executable','client_sha256':digest(CLI),'fixture_sha256':digest(R/'legacy-helper-v1'),'baseline_service':baseline,'authorization_rule_before':rule_before,'store_before':snapshot,'rows':[]}
plist={'Label':LABEL,'ProgramArguments':[str(ROOT/'legacy-helper-v1')],'MachServices':{LABEL:True},'StandardOutPath':str(ROOT/'stdout.log'),'StandardErrorPath':str(ROOT/'stderr.log')}
(R/'service.plist').write_bytes(plistlib.dumps(plist));bootstrapped=False
try:
 checked(['sudo','-n','mkdir','-m','0755',ROOT])
 checked(['sudo','-n','install','-o','root','-g','wheel','-m','0755',R/'legacy-helper-v1',ROOT/'legacy-helper-v1'])
 checked(['sudo','-n','install','-o','root','-g','wheel','-m','0644',R/'service.plist',ROOT/'service.plist'])
 result['bootstrap']=checked(['sudo','-n','launchctl','bootstrap','system',ROOT/'service.plist']);bootstrapped=True
 result['status']=call([CLI,'helper','status']);assert result['status']['exit']==0 and 'helper protocol: 1' in result['status']['stdout'],result['status']
 archive=R/'archive.bin';archive.write_bytes(b'controlled acceptance data, never installed\n')
 for op in ['verify-bundle','install-bundle']:
  for mode in ['no-log','new-log','existing-log']:
   log=R/(op+'-'+mode+'.log');sentinel=b'preserve existing operation log\n'
   if mode=='existing-log':log.write_bytes(sentinel)
   else:assert not log.exists()
   args=[CLI,'helper',op,'--version','2.6.1-local.ab12cd34']
   if op=='install-bundle':args+=['--archive',archive,'--sha256',digest(archive)]
   if mode!='no-log':args+=['--log-file',log]
   row=call(args);row.update({'operation':op,'mode':mode,'log_exists_after':log.exists()})
   assert row['exit']!=0 and 'Installed helper protocol differs from this client.' in row['stderr'],row
   if mode=='existing-log':assert log.read_bytes()==sentinel
   else:assert not log.exists()
   result['rows'].append(row)
 result['fixture_log']=checked(['sudo','-n','cat',ROOT/'stderr.log'])['stdout']
 assert 'FIXTURE_FORBIDDEN_OPERATION' not in result['fixture_log']
 result['version_requests']=result['fixture_log'].count('helperVersion -> 1');assert result['version_requests']==7
 result['authorization_rule_after']=call(['/usr/bin/security','authorizationdb','read',LABEL+'.privileged'])
 assert result['authorization_rule_after']['stdout']==rule_before['stdout'] and result['authorization_rule_after']['exit']==rule_before['exit']
 result['store_after']=store();assert result['store_after']==snapshot
 result['passed']=True
finally:
 if bootstrapped:
  current=call(['sudo','-n','launchctl','print','system/'+LABEL]);result['service_before_cleanup']=current
  assert str(ROOT/'legacy-helper-v1') in current['stdout'],current
  result['bootout']=checked(['sudo','-n','launchctl','bootout','system/'+LABEL])
 for name in ['stdout.log','stderr.log']:
  r=call(['sudo','-n','cat',ROOT/name]);(R/('fixture-'+name)).write_text(r['stdout'])
 if ROOT.exists():
  checked(['sudo','-n','rm','-f',ROOT/'legacy-helper-v1',ROOT/'service.plist',ROOT/'stdout.log',ROOT/'stderr.log'])
  checked(['sudo','-n','rmdir',ROOT])
 result['final_service']=call(['/bin/launchctl','print','system/'+LABEL]);assert result['final_service']['exit']!=0
 result['temporary_root_removed']=not ROOT.exists()
 (R/'result.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
print(json.dumps({'passed':result.get('passed',False),'rows':len(result['rows']),'version_requests':result.get('version_requests'),'cleanup':result['temporary_root_removed']}))
