#!/usr/bin/env python3
"""Package T32 receipts/file Undo without installing or touching any VM."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import argparse

ROOT=Path(__file__).resolve().parents[3]
WORK=ROOT/'.build/t32-t33-completion-20261023'
BASE=ROOT/'.build/t52-provider-fix-20261023/package/VPhone.bundle'
parser=argparse.ArgumentParser();parser.add_argument('--package-name',default='package')
options=parser.parse_args()
if Path(options.package_name).name!=options.package_name:raise ValueError('Package name must be one path component')
BUNDLE=WORK/options.package_name/'VPhone.bundle'
SCRIPTS=('cfw_disk_txn.py','cfw_guest_evidence.py','cfw_install_host.sh','cfw_verify_effects.py','check_bundle.py')


def sha(path):
    h=hashlib.sha256()
    with path.open('rb') as stream:
        while block:=stream.read(1<<20):h.update(block)
    return h.hexdigest()


def run(*args):subprocess.run([str(arg) for arg in args],cwd=ROOT,check=True)


def inventory(root):return {str(p.relative_to(root)):sha(p) for p in root.rglob('*') if p.is_file()}


def main():
    if BUNDLE.exists():raise ValueError('Preserve the existing candidate; select a new package directory')
    BUNDLE.parent.mkdir()
    run('/usr/bin/ditto',BASE,BUNDLE)
    resources=BUNDLE/'Contents/Resources';cli=BUNDLE/'Contents/MacOS/vphone-cli'
    shutil.copy2(ROOT/'.build/release/vphone-cli',cli)
    run('/usr/bin/codesign','--force','--sign','-',cli)
    sources={}
    for relative in SCRIPTS:
        source=ROOT/'scripts'/relative;shutil.copy2(source,resources/'scripts'/relative)
        sources[str(source.relative_to(ROOT))]=sha(source)
    common=ROOT/'scripts/lib/cfw_common.sh'
    shutil.copy2(common,resources/'scripts/lib/cfw_common.sh');sources[str(common.relative_to(ROOT))]=sha(common)
    for source in sorted((ROOT/'scripts/patchers').glob('*.py')):
        shutil.copy2(source,resources/'scripts/patchers'/source.name)
        sources[str(source.relative_to(ROOT))]=sha(source)
    provenance=dict(scope='v5 guest declaration receipts and generation-qualified complete-file Undo',
        base=str(BASE),sourceSHA256=sources,guestOriginQualified=False,runtimeValidated=False,
        installed=False,booted=False,securityWindowStarted=False)
    (resources/'t32-file-undo-provenance.json').write_text(json.dumps(provenance,indent=2)+'\n')
    run(ROOT/'.venv/bin/python','-B',ROOT/'scripts/build_native_dependencies.py',BUNDLE)
    run(ROOT/'.venv/bin/python','-B',ROOT/'scripts/record_build_dependencies.py',BUNDLE)
    run('/usr/bin/codesign','--force','--sign','-',BUNDLE)
    run(ROOT/'.venv/bin/python','-B',ROOT/'scripts/check_bundle.py',BUNDLE)
    before,after=inventory(BASE),inventory(BUNDLE)
    protected=[name for name in before if name.startswith(('Contents/Resources/guest-resources/',
        'Contents/Resources/.build/guest-components-v2/','Contents/Frameworks/')) or name=='Contents/MacOS/vphone-vm']
    for name in protected:
        if before[name]!=after[name]:raise ValueError('Protected candidate input changed: '+name)
    version='2.6.2-local.'+sha(resources/'build-dependencies.json')[:12]
    archive=WORK/(version+'.tar')
    if archive.exists():raise ValueError('Preserve existing archive')
    run('/usr/bin/tar','-cf',archive,'-C',BUNDLE.parent,'VPhone.bundle')
    record=dict(state='prepared_not_installed',version=version,bundle=str(BUNDLE),archive=str(archive),
        archiveSHA256=sha(archive),archiveBytes=archive.stat().st_size,cliSHA256=sha(cli),
        vmSHA256=sha(BUNDLE/'Contents/MacOS/vphone-vm'),VMAndGuestAssetsUnchanged=True,
        changedPaths=[n for n in sorted(before.keys()|after.keys()) if before.get(n)!=after.get(n)],provenance=provenance)
    (WORK/'candidate.json').write_text(json.dumps(record,indent=2)+'\n')
    print(json.dumps({k:record[k] for k in ('state','version','archiveSHA256','archiveBytes')}))


if __name__=='__main__':main()
