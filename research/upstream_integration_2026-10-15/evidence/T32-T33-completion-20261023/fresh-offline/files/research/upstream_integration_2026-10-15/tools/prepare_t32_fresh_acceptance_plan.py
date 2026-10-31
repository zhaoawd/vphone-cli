#!/usr/bin/env python3
"""Freeze an unapproved new-source isolated VM acceptance plan."""
import json
from pathlib import Path
import sys
ROOT=Path(__file__).resolve().parents[3];WORK=ROOT/'.build/t32-t33-completion-20261023'
sys.path.insert(0,str(ROOT/'scripts'));import cfw_guest_evidence as evidence


def main():
    candidate=json.loads(evidence.read(WORK/'candidate-r5.json'));backup=json.loads(evidence.read(WORK/'acceptance-backup.json'))
    old=Path(backup['vm']);generation='6ebc5f6705cf0bffb32da62bf3006cc7ece5027edee4306abc8031aee9f4bb42'
    archives=json.loads(evidence.read(WORK/'fresh-archive-sources.json'))
    rom=old/'.firmware-generations'/generation/'originals/AVPBooter.vresearch1.bin'
    if evidence.digest(rom)!='301bc973b56e86a9906bb6002d008015a57c9e07b5f191260717b97a62589072':raise ValueError('Original ROM differs')
    frozen={}
    def add(p):frozen[str(p)]=evidence.digest(p)
    for p in Path(candidate['bundle']).rglob('*'):
        if p.is_symlink():raise ValueError('Linked candidate')
        if p.is_file():add(p)
    for row in archives:
        p=Path(row['path'])
        if evidence.digest(p)!=row['sha256']:raise ValueError('Archive changed')
        frozen[str(p)]=row['sha256']
    add(rom);add(Path(candidate['archive']))
    for name in ('candidate-r5.json','acceptance-backup.json','fresh-archive-sources.json','offline-refusal-preservation.json',
                 'identity-missing-history.json','identity-file-full-green.log','identity-actual-diagnosis-confirmed.log','fresh-acceptance-guards-r2.log'):
        add(WORK/name)
    for name in ('execute_t32_fresh_file_acceptance.py','execute_t32_file_acceptance.py','test_t32_fresh_file_acceptance.py','prepare_t32_fresh_acceptance_plan.py'):
        add(Path(__file__).parent/name)
    for name in ('cfw_disk_txn.py','cfw_guest_evidence.py','cfw_verify_effects.py','vm_lock.py','sparse_file.py'):
        add(ROOT/'scripts'/name)
    for p in (ROOT/'scripts/patchers').glob('*.py'):add(p)
    python=ROOT/'.venv/bin/python';add(python.resolve(strict=True));add(ROOT/'.venv/pyvenv.cfg')
    cache=WORK/'file-original-source/pristine-rootfs.dmg';stat=cache.stat()
    if evidence.digest(cache)!='3ba28458a3a2a926acd1a7543f216eb7f1dc9d404162ad48ac4b1bf01b071ac6':raise ValueError('Decoder cache differs')
    prior=json.loads(evidence.read(WORK/'file-acceptance-plan.json'))
    desired=json.loads(evidence.read(Path(backup['backup'])/'.firmware-desired-plan.json'))
    plan=dict(schemaVersion=1,approvalRequired=True,approved=False,sourceVM=str(old),
        vm=str(WORK/'fresh-library/t32-t33-file-acceptance-20261023'),
        scope='New isolated stopped-VM copy from verified current boot state; fresh original-source generation then three-Mach-O on/off/on',
        priorPlan='cdb74f7aab1d221cf7c65b769455c65800062fbb83755a3066d96311e6c20ea9',
        priorResult='identity refusal before staging; all12 source files unchanged',
        candidateVersion=candidate['version'],candidateArchive=candidate['archive'],candidateArchiveSHA256=candidate['archiveSHA256'],
        cliExecutable=str(Path(candidate['bundle'])/'Contents/MacOS/vphone-cli'),python=str(python),pythonResolved=str(python.resolve(strict=True)),
        iphoneSource=archives[0]['path'],cloudOSSource=archives[1]['path'],bootROMSource=str(rom),
        archiveSHA256={'iPhone':archives[0]['sha256'],'cloudOS':archives[1]['sha256']},
        bootROMIs='Archived original ROM whose bytes match the independent original source digest; installed patched ROM is not used',
        oldGenerationID=generation,expectedPlanSHA256=desired['planSHA256'],
        generationPolicy='Call public fresh IPSW producer; require a new generation and exactly the prior semantic plan; never fabricate old missing history',
        copyBootFiles=[n for n in backup['files'] if n not in ('.firmware-desired-plan.json','.firmware-component-receipts.json')],
        copyPolicy='Full APFS clones with independent inodes; exclude old desired plan, receipts, histories, runtime and generation authority',
        freshWorkingTree='Clone only from the newly produced verified generation originals',
        declarations=prior['declarations'],targets=prior['targets'],
        phases=['fresh-copy-and-generation','one regular/classic Cryptex reapplication','one exact three-declaration Undo','one regular/classic Cryptex reapplication'],
        checks=prior['acceptance'],minimumFreeBytes=75<<30,
        decodedCacheCleanup=dict(path=str(cache),sha256='3ba28458a3a2a926acd1a7543f216eb7f1dc9d404162ad48ac4b1bf01b071ac6',
            bytes=stat.st_size,scope='Only this regenerable decoded DMG after independent digest and no-attachment check; original AEA, file copies and source evidence retained'),
        temporaryCleanup='Only new invocation staging and decoded scratch after normal detach; fresh sources and every disk/history retained',
        preserve=['Original VM current disk and all12 persistent inputs','Both old incomplete histories without changes','All old generations and evidence','Other VMs and backups'],
        VMStarts=0,securityWindows=0,BundleStoreInstall=False,VMRebind=False,noForceUnmount=True,
        automaticRetry=False,automaticRollback=False,failurePolicy='Stop remaining phases; preserve partial new copy and all evidence',
        originQualified=False,runtimeValidated=False,completeT32T33Acceptance=False,
        pending='Trusted guest origin bridge and separately authorized real runtime/display acceptance',frozenInputs=frozen)
    destination=WORK/'fresh-file-acceptance-plan.json';evidence.write_new(destination,json.dumps(plan,indent=2).encode()+b'\n')
    print(json.dumps(dict(plan=str(destination),sha256=evidence.digest(destination),frozenFiles=len(frozen),candidate=candidate['version'],archiveSHA256=candidate['archiveSHA256'],cacheBytes=stat.st_size)))


if __name__=='__main__':main()
