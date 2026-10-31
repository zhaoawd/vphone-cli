#!/usr/bin/env python3
"""Exercise remaining byte/signing paths only on new local fixture copies."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import time

ROOT=Path(__file__).resolve().parents[3]
WORK=ROOT/'.build/t32-t33-completion-20261023/exp-bounded-preflight-20261024'
BUNDLE=ROOT/'.build/t32-t33-completion-20261023/exp-cryptex-links-package-20261024-r3/VPhone.bundle'
sys.path.insert(0,str(ROOT/'scripts'))
from patchers import component_signatures as signatures
from patchers.cfw_patch_build_version import patch_plist
from patchers.cfw_patch_jetsam import patch_launchd_jetsam
from patchers.cfw_patch_watchdogd import patch_watchdogd
from patchers.cfw import dylib_command


def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def command(argv,log):
    with log.open('xb') as output:
        subprocess.run([str(x) for x in argv],stdout=output,stderr=subprocess.STDOUT,
                       check=True,timeout=20,stdin=subprocess.DEVNULL)


def verify_pages(path):
    cds=signatures.directories(path)
    if not cds:raise ValueError('Missing CodeDirectories')
    signatures.verify_slots(path,[dict(identity=c['identity'],slot=c['slot'],pages=range(c['count'])) for c in cds])
    return sum(c['count'] for c in cds)


def main():
    folder=WORK/'producer-fixtures';folder.mkdir(mode=0o700);start=time.monotonic()
    os.environ['PATH']=str(BUNDLE/'Contents/Resources/.tools/bin')+':/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin'
    history=ROOT/'.build/t33q-20261024/.cfw-history/20261024T131058Z-8sbOtt6f'
    catalog=json.loads((history/'guest-file-originals.json').read_text())
    result=dict(scope='actual captured bytes; isolated fixture copies only',VMStarts=0,CFWWrites=0,
                nativeUndoExecuted=False,checks={},passed=False)
    def source(target):
        record=catalog['members'][target];path=history/'effect-blobs'/record['state']['sha256']
        if sha(path)!=record['state']['sha256']:raise ValueError('Captured original blob differs')
        return path
    try:
        for index,target in enumerate(('system:/System/Library/CoreServices/SystemVersion.plist',
             'preboot:/Cryptexes/OS/System/Library/CoreServices/SystemVersion.plist')):
            raw=source(target).read_bytes();path=folder/('version-'+str(index)+'.plist');path.write_bytes(raw)
            original=plistlib.loads(raw);assert patch_plist(path,'23Z999999')
            first=path.read_bytes();changed=plistlib.loads(first)
            assert changed==dict(original,ProductBuildVersion='23Z999999')
            stamp=path.stat().st_mtime_ns;assert patch_plist(path,'23Z999999') is False
            assert path.stat().st_mtime_ns==stamp and path.read_bytes()==first
            path.write_bytes(raw);assert path.read_bytes()==raw
            assert patch_plist(path,'23Z999999') and path.read_bytes()==first
            result['checks'][target]=dict(passed=True,sourceSHA256=hashlib.sha256(raw).hexdigest(),
                firstAndReappliedSHA256=hashlib.sha256(first).hexdigest(),onlyExpectedKeyChanged=True,
                idempotentNoRewrite=True,restoreScope='exact original bytes on fixture; native Undo still pending')
        key=folder/'signcert.p12';fd=os.open(key,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
        with os.fdopen(fd,'wb') as output:
            subprocess.run(['/usr/bin/tar','-xOf',str(BUNDLE/'Contents/Resources/scripts/resources/cfw_input.tar.zst'),
                            'cfw_input/signcert.p12'],stdout=output,check=True,timeout=20)
        ldid=BUNDLE/'Contents/MacOS/ldid'
        original=source('system:/sbin/launchd');launchd=folder/'launchd';shutil.copyfile(original,launchd)
        ent=folder/'launchd.entitlements';command([ldid,'-e',original],ent)
        command(dylib_command(launchd,'/b'),folder/'launchd-injection.log')
        if not patch_launchd_jetsam(launchd):raise ValueError('launchd jetsam pattern not applied')
        signatures.reserve_signature_command(launchd)
        unsigned=folder/'launchd-before-sign';shutil.copyfile(launchd,unsigned)
        command([ldid,'-S'+str(ent),'-M','-K'+str(key),launchd],folder/'launchd-sign.log')
        signatures.verify_signing(unsigned,launchd);signatures.verify_artifact(launchd,require_cms=True)
        if signatures.entitlements(original)!=signatures.entitlements(launchd):raise ValueError('launchd entitlements changed')
        result['checks']['launchd']=dict(passed=True,nonSignatureBytesPreservedBySigning=True,
            originalEntitlementsPreserved=True,verifiedCodePages=verify_pages(launchd),cmsIntegrityPassed=True)
        captured=WORK/'root-readonly/guest-files'
        watchdog=folder/'watchdogd';shutil.copyfile(captured/'watchdogd',watchdog)
        count=patch_watchdogd(str(watchdog))
        result['checks']['watchdogd']=dict(passed=True,patchedSites=count,verifiedCodePages=verify_pages(watchdog),
            signatureScope='code pages only, matching producer; CMS not re-signed or asserted')
        original=captured/'debugserver';debug=folder/'debugserver';shutil.copyfile(original,debug)
        xml=folder/'debugserver.entitlements';command([ldid,'-e',original],xml)
        value=plistlib.loads(xml.read_bytes());value.pop('seatbelt-profiles',None);value['task_for_pid-allow']=True
        xml.write_bytes(plistlib.dumps(value));unsigned=folder/'debugserver-before-sign';shutil.copyfile(debug,unsigned)
        command([ldid,'-S'+str(xml),'-K'+str(key),debug],folder/'debugserver-sign.log')
        signatures.verify_signing(unsigned,debug);signatures.verify_artifact(debug,require_cms=True)
        if signatures.entitlements(debug)!=[value]:raise ValueError('Debugserver effective entitlements differ')
        result['checks']['debugserver']=dict(passed=True,effectiveEntitlementsMatchProducer=True,
            verifiedCodePages=verify_pages(debug),cmsIntegrityPassed=True,executableNeverLaunched=True)
        result['passed']=True
    except Exception as error:result['error']=str(error)
    result['elapsedSeconds']=time.monotonic()-start
    (WORK/'producer-fixture-preflight.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result),flush=True);return 0 if result['passed'] else 1


if __name__=='__main__':raise SystemExit(main())
