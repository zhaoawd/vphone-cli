import hashlib,json,os,subprocess
from pathlib import Path
assert os.geteuid()==0
r=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli');record=json.loads(Path('/private/tmp/vphone-b22-local-core-bundle.json').read_text());store=Path('/Library/Application Support/vphone-launchpad/Bundles');assert not os.path.lexists(store)
cli=r/'.build/vphone-cli.app/Contents/MacOS/vphone-cli';assert hashlib.sha256(cli.read_bytes()).hexdigest()=='ba718e55aab0a0b6697141264213658729c22eef5ff133c73bccdb914c4f1dfb';archive=Path(record['archive']);assert hashlib.sha256(archive.read_bytes()).hexdigest()==record['archive_sha256']
rows=[]
def run(args):
 p=subprocess.run(args,capture_output=True,text=True,timeout=90);rows.append({'command':args,'returncode':p.returncode,'stdout':p.stdout,'stderr':p.stderr});assert p.returncode==0,rows[-1];return json.loads(p.stdout)
receipt=run([str(cli),'core-bundle','install','--version',record['version'],'--archive',str(archive),'--sha256',record['archive_sha256']]);verified=run([str(cli),'core-bundle','verify','--version',record['version']]);assert receipt==verified
result={'root_store_absent_before':True,'version':record['version'],'receipt':receipt,'verified':True,'observations':rows,'escalator_executed':False,'temporary_AMFI_scope_unchanged':True,'cleanup_pending_bound_VM_acceptance':True}
p=Path('/private/tmp/vphone-b22-install-local-core.json');p.write_text(json.dumps(result,indent=2)+'\n');os.chown(p,cli.stat().st_uid,-1);print({'version':record['version'],'verified':True})
