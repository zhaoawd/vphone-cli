"""Archive only a fully qualified DSC result; no VM writes or Git operations."""
import datetime,hashlib,importlib.util,json,os,stat
from pathlib import Path
ROOT=Path('/Users/kolar/github/vphone-cli');DEBUG=ROOT/'.build/t32-resume-acceptance-20261020'
BASE=ROOT/'research/upstream_integration_2026-10-15'
PROOFS=['installed','restored','api-restored','postboot-restored','reapplied','api-reapplied','postboot-reapplied']
def digest(path):
 with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()
def validate(result,proofs):
 spec=importlib.util.spec_from_file_location('previous_archive_contract',ROOT/'.build/t32-cryptex-symlink-debug/archive-after-pass.py')
 old=importlib.util.module_from_spec(spec);spec.loader.exec_module(old);old.validate(result,proofs)
 for phase in ('installed','reapplied'):
  p=proofs[phase]
  if p['verifiedOriginalCodePages']!=6885 or p['verifiedInstalledCodePages']!=6885 or p['originalInstruction']['value']!=0x548 or p['installedInstruction']['value']!=0x560:raise ValueError('installed code-page or instruction proof differs')
  if p['originalSHA256']!=result['originalSHA256'] or p['installedSHA256']!=result['installedSHA256']:raise ValueError('installed member digest differs')
 p=proofs['restored']
 if p['verifiedRestoredCodePages']!=6885 or p['restoredInstruction']['value']!=0x548 or p['originalSHA256']!=result['originalSHA256'] or p['parentTransactionID']!=result['transactions']['installed'] or p['guestOrigin']!='unknown':raise ValueError('restored parent/original/page proof differs')
 for phase in ('restored','reapplied'):
  b=proofs['api-'+phase];cycles=b['cycles']
  if len(cycles)!=2 or any(not c.get('guestStopped') or c.get('forcedFrameworkStop') or not c.get('diskReleased') or c.get('stopExitCode')!=0 or c.get('vmExitCode')!=0 for c in cycles):raise ValueError('boot/shutdown matrix differs')
  if cycles[0]['bootSessionUUID']==cycles[1]['bootSessionUUID'] or cycles[0]['bootSeconds']==cycles[1]['bootSeconds']:raise ValueError('boot identity not distinct')
  if any(c.get('systemVersion',{}).get('ProductVersion')!='26.0' or c.get('systemVersion',{}).get('ProductBuildVersion')!='23A341' for c in cycles):raise ValueError('guest system version differs from selected acceptance firmware')
  post=proofs['postboot-'+phase]
  if post['transactionID']!=result['transactions'][phase] or len(post['commands'])!=2 or any(c['exitCode']!=0 for c in post['commands']):raise ValueError('postboot reader proof differs')
def copy_regular(source,destination):
 before=source.lstat()
 if not stat.S_ISREG(before.st_mode) or before.st_size>32*1024*1024 or source.suffix.lower() in {'.img','.dmg','.ipsw','.bin'}:raise ValueError('not bounded metadata: '+str(source))
 destination.parent.mkdir(parents=True,exist_ok=True)
 with source.open('rb') as src,destination.open('xb') as dst:
  while block:=src.read(1024*1024):dst.write(block)
 after=source.lstat()
 if any(getattr(before,k)!=getattr(after,k) for k in ('st_dev','st_ino','st_size','st_mtime_ns','st_ctime_ns')) or digest(source)!=digest(destination):raise ValueError('metadata changed during archive')
def main():
 os.chdir(ROOT)
 state=json.loads((DEBUG/'acceptance-state.json').read_text())
 if state['state']!='passed':raise ValueError('real sequential acceptance has not passed')
 result=json.loads((DEBUG/'on-off-on-result.json').read_text());proofs={}
 for name in PROOFS:
  folder=ROOT/('.build/t32-dsc-v4-resume20-'+name)
  proofs[name]=json.loads((folder/('runtime-result.json' if name.startswith('api-') else 'result.json')).read_text())
 validate(result,proofs)
 for name,value in json.loads((DEBUG/'input-manifest.json').read_text()).items():
  if digest(ROOT/name)!=value:raise ValueError('frozen acceptance input changed: '+name)
 out=BASE/'evidence/T32-T33-new-vm-20261018/dsc-on-off-on-20261020-resume';out.mkdir(exist_ok=False)
 for name in PROOFS:
  folder=ROOT/('.build/t32-dsc-v4-resume20-'+name)
  for source in sorted(folder.rglob('*')):
   if source.is_symlink():raise ValueError('linked proof input')
   if source.is_file():copy_regular(source,out/name/source.relative_to(folder))
 vm=ROOT/'vm-t32-t33-dsc-20261018'
 for phase,identifier in result['transactions'].items():
  folder=vm/'.cfw-history'/identifier
  record=json.loads((folder/'transaction.json').read_text())
  if record['status']!='published' or record['id']!=identifier:raise ValueError('journal was not published')
  for name in ('transaction.json','guest-changes.jsonl','guest-publication.json','guest-effects-final.json'):
   copy_regular(folder/name,out/'journals'/phase/name)
 for name in ('on-off-on-result.json','acceptance-state.json','run-acceptance.py','archive-acceptance.py','input-manifest.json','boot-argument-probe.json','host-allowance-restore.json'):
  if (DEBUG/name).exists():copy_regular(DEBUG/name,out/name)
 for source in sorted(DEBUG.glob('*.log')):copy_regular(source,out/'logs'/source.name)
 manifest=dict(recordedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),state='passed',scope='independent DSC Undo and same-generation reapplication',sourceBase='d968d02f5c69615b9f2f3bd45805b60e10540bfc',result=result,broaderT32T33Accepted=False,limitations=['graphics and runtime patch effects not established','Mach-O/Preboot Undo and arbitrary intermediate replay incomplete','trusted guest origin not advanced','payload images and effect blobs remain in original retained VM journals'])
 manifest['files']={str(p.relative_to(out)):dict(bytes=p.stat().st_size,sha256=digest(p)) for p in sorted(out.rglob('*')) if p.is_file()}
 (out/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
 print(json.dumps(dict(state='passed',manifest=str(out/'manifest.json'))))
if __name__=='__main__':main()
