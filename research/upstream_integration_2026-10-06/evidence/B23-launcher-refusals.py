import fcntl,hashlib,json,os,pathlib,shutil,subprocess
assert os.geteuid()==0
wt=pathlib.Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli');cli=wt/'.build/vphone-cli.app/Contents/MacOS/vphone-cli';launcher=wt/'.build/vphone-launchpad.app/Contents/MacOS/vphone-launchpad-launcher';record=json.loads(pathlib.Path('/private/tmp/vphone-b22-local-core-bundle.json').read_text());archive=pathlib.Path(record['archive']);store=pathlib.Path('/Library/Application Support/vphone-launchpad/Bundles');uid=2035870432;version=record['version'];destination=store/version;resource=destination/'VPhone.bundle/Contents/Resources/integration-provenance.json';out=pathlib.Path('/private/tmp/vphone-b23-launcher-refusals.json')
assert not os.path.lexists(store);assert hashlib.sha256(archive.read_bytes()).hexdigest()==record['archive_sha256'];assert launcher.is_file()
rows=[];installed=False;receipt=None

def call(args,expected=None):
 p=subprocess.run(args,capture_output=True,text=True,timeout=90);row={'command':args,'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr};rows.append(row)
 if expected is not None:assert p.returncode==expected,row
 return row

def launch(label,args):
 row=call(['/usr/bin/sudo','-n','-u','#'+str(uid),str(launcher),str(destination/'VPhone.bundle/Contents/MacOS/vphone-cli')]+args,77);row['case']=label;assert 'refused:' in row['stderr'],row

try:
 receipt=json.loads(call([str(cli),'core-bundle','install','--version',version,'--archive',str(archive),'--sha256',record['archive_sha256']],0)['stdout']);installed=True
 assert json.loads(call([str(cli),'core-bundle','verify','--version',version],0)['stdout'])==receipt
 assert resource.stat().st_uid==0 and resource.stat().st_mode&0o777==0o644
 launch('unknown-verb',['helper','register','unused'])
 os.chown(resource,uid,resource.stat().st_gid)
 try:launch('wrong-owner',['vm','launch','b23-absent-machine','--library-root','/private/tmp/vphone-b23-empty-library'])
 finally:os.chown(resource,0,0)
 os.chmod(resource,0o666)
 try:launch('shared-writable-resource',['vm','launch','b23-absent-machine','--library-root','/private/tmp/vphone-b23-empty-library'])
 finally:os.chmod(resource,0o644)
 saved=resource.with_suffix('.b23-backup');assert not saved.exists();resource.rename(saved);resource.symlink_to(saved.name)
 try:launch('symbolic-link-resource',['vm','launch','b23-absent-machine','--library-root','/private/tmp/vphone-b23-empty-library'])
 finally:resource.unlink();saved.rename(resource)
 assert json.loads(call([str(cli),'core-bundle','verify','--version',version],0)['stdout'])==receipt
finally:
 if installed:
  assert sorted(p.name for p in store.iterdir())==['.store.lock',version]
  assert json.loads(call([str(cli),'core-bundle','verify','--version',version],0)['stdout'])==receipt
  lock=os.open(store/'.store.lock',os.O_RDWR);fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
  try:shutil.rmtree(destination);(store/'.store.lock').unlink();store.rmdir()
  finally:os.close(lock)
 result={'rows':rows,'installed_version':version,'receipt':receipt,'store_absent_after':not os.path.lexists(store),'VM_started':False,'helper_registered':False,'escalator_executed':False,'AMFI_modified':False,'scope':'Actual ordinary launcher subprocess; owner/link/write/unknown verb refusal. No TCC or old helper test.'};out.write_text(json.dumps(result,indent=2)+'\n');os.chown(out,uid,-1)
print({'cases':[(r.get('case'),r['exit']) for r in rows if r.get('case')],'store_absent_after':not os.path.lexists(store)})
