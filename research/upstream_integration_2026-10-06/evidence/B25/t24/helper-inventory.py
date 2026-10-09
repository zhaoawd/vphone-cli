import hashlib,json,os,plistlib,re,subprocess
from pathlib import Path
root=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli')
roots=[root/'.build',Path('/Users/qcz3840/github/vphone-cli/.build'),Path('/private/tmp'),Path('/Applications')]
r=subprocess.run(['rg','--files','-uuu',*[str(p) for p in roots],'-g','!TODO.md'],capture_output=True,text=True)
paths=[]
for line in r.stdout.splitlines():
    p=Path(line)
    if not (('helper' in p.name.lower()) and ('vphone' in str(p).lower())): continue
    try:
        with p.open('rb') as f: magic=f.read(4)
    except OSError: continue
    if magic in (b'\xcf\xfa\xed\xfe',b'\xce\xfa\xed\xfe',b'\xca\xfe\xba\xbe',b'\xbe\xba\xfe\xca'):
        paths.append(p)
report={'searched_roots':[str(p) for p in roots],'installed_helper_exists':Path('/Library/PrivilegedHelperTools/com.vphone.cli.helper').exists(),'matching_macho':[], 'limits':'Read-only filename/Mach-O inventory; no helper execution, installation or service registration. No historical production protocol-v1 helper located in these roots.'}
for p in sorted(set(paths)):
    records=[]
    for argv in [('codesign','-dvvv',str(p)),('otool','-s','__TEXT','__info_plist',str(p))]:
        result=subprocess.run(argv,capture_output=True,text=True)
        records.append({'argv':argv,'exit_code':result.returncode,'stdout':result.stdout,'stderr':result.stderr})
    source=p.with_suffix('.swift')
    is_fixture=source.exists() and 'Controlled legacy-protocol sample' in source.read_text()
    report['matching_macho'].append({'path':str(p),'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'controlled_fixture':is_fixture,'protocol':'1 (controlled fixture source)' if is_fixture else '2 (current production candidate; adjacent Helper-Info.plist CFBundleVersion)', 'checks':records})
Path('/private/tmp/vphone-b25-t24/helper-inventory.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({k:v for k,v in report.items() if k!='matching_macho'},indent=2))
for item in report['matching_macho']:print(item['path'],item['sha256'],item['protocol'])
