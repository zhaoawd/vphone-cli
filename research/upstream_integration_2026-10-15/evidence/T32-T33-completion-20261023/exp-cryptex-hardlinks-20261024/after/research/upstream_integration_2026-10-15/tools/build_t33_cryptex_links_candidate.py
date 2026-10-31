#!/usr/bin/env python3
"""Package only the Cryptex reader repair over the preserved a84 candidate."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

ROOT=Path(__file__).resolve().parents[3]
WORK=ROOT/'.build/t32-t33-completion-20261023'
BASE_RECORD=WORK/'candidate-origin-identity-package-20261024.json'
PACKAGE=WORK/'exp-cryptex-links-package-20261024-r3'
sys.path.insert(0,str(ROOT/'scripts'))
from patchers.component_signatures import verify_signing, entitlements


def sha(path):
    digest=hashlib.sha256()
    with Path(path).open('rb') as stream:
        while block:=stream.read(1<<20):digest.update(block)
    return digest.hexdigest()


def run(*args):
    subprocess.run([str(arg) for arg in args],cwd=ROOT,check=True)


def inventory(root):
    return {str(p.relative_to(root)):sha(p) for p in root.rglob('*') if p.is_file()}


def main():
    old=json.loads(BASE_RECORD.read_text());base=Path(old['bundle'])
    if (old['version']!='2.6.2-local.a84f5889b159'
            or old['archiveSHA256']!='c7a6e66a6848dc92eb7e8f3680ec374c9cf01e9482e5c1ea55660a7db2c88105'
            or sha(old['archive'])!=old['archiveSHA256']):
        raise ValueError('Preserved candidate differs')
    if PACKAGE.exists():raise ValueError('Preserve existing package output')
    run(ROOT/'.venv/bin/python3','-B',ROOT/'scripts/check_bundle.py',base)
    before=inventory(base);PACKAGE.mkdir();bundle=PACKAGE/'VPhone.bundle'
    run('/usr/bin/ditto',base,bundle)
    relative='Contents/Resources/scripts/patchers/cryptex_source.py'
    shutil.copy2(ROOT/'scripts/patchers/cryptex_source.py',bundle/relative)
    provenance=bundle/'Contents/Resources/t32-producer-provenance.json'
    report=json.loads(provenance.read_text())
    report['sourceSHA256']['scripts/patchers/cryptex_source.py']=sha(ROOT/'scripts/patchers/cryptex_source.py')
    report['cryptexReaderRepair']=dict(baseVersion=old['version'],baseArchiveSHA256=old['archiveSHA256'],
        scope='contained stable hard-link groups for tree observation; patch target guards unchanged',
        reusedHostExecutables=True,installed=False,runtimeValidated=False)
    provenance.write_text(json.dumps(report,indent=2)+'\n')
    run('/usr/bin/codesign','--force','--sign','-',bundle)
    run(ROOT/'.venv/bin/python3','-B',ROOT/'scripts/record_build_dependencies.py',bundle)
    run('/usr/bin/codesign','--force','--sign','-',bundle)
    run(ROOT/'.venv/bin/python3','-B',ROOT/'scripts/check_bundle.py',bundle)
    after=inventory(bundle)
    changed=[name for name in sorted(before.keys()|after.keys()) if before.get(name)!=after.get(name)]
    allowed={relative,'Contents/Resources/t32-producer-provenance.json',
             'Contents/Resources/build-dependencies.json','Contents/_CodeSignature/CodeResources',
             'Contents/MacOS/vphone-cli'}
    if set(changed)-allowed:raise ValueError('Unexpected package changes: '+str(set(changed)-allowed))
    cli=bundle/'Contents/MacOS/vphone-cli';vm=bundle/'Contents/MacOS/vphone-vm'
    verify_signing(base/'Contents/MacOS/vphone-cli',cli)
    if entitlements(base/'Contents/MacOS/vphone-cli')!=entitlements(cli) or sha(vm)!=old['vmSHA256']:
        raise ValueError('Host executable content or entitlements changed')
    version='2.6.2-local.'+sha(bundle/'Contents/Resources/build-dependencies.json')[:12]
    archive=WORK/(version+'.tar')
    if archive.exists():raise ValueError('Preserve existing archive')
    run('/usr/bin/tar','-cf',archive,'-C',PACKAGE,'VPhone.bundle')
    result=dict(state='prepared_not_installed',version=version,bundle=str(bundle),archive=str(archive),
        archiveSHA256=sha(archive),archiveBytes=archive.stat().st_size,cliSHA256=sha(cli),vmSHA256=sha(vm),
        changedPaths=changed,baseVersion=old['version'],baseArchiveSHA256=old['archiveSHA256'],
        cliExecutableContentUnchanged=True,vmExecutableUnchanged=True,guestAssetsUnchanged=True,runtimeValidated=False)
    with (WORK/'candidate-exp-cryptex-links-package-20261024-r3.json').open('x') as output:
        json.dump(result,output,indent=2);output.write('\n')
    print(json.dumps(result))


if __name__=='__main__':main()
