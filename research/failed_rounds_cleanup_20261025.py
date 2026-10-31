"""Prepare and execute a separately approved capacity-based cleanup, without VM starts."""
import argparse
import fcntl
import gzip
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys

import project_storage_review_20261024 as packages
import retire_t32_t33_states_20261025 as storage

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / '.build/t32-t33-completion-20261023'
OUT = ROOT / 'research/evidence/failed-rounds-cleanup-20261025'
sys.path.insert(0, str(ROOT / 'research/upstream_integration_2026-10-15/tools'))
import execute_t33_dev_overlay_acceptance as previous

OLD_VM = ROOT / 'vm-t32-t33-dsc-20261018'
PACKAGES = (
    'producer-package-final-20261024', 'origin-identity-package-20261024',
    'exp-cryptex-links-package-20261024-r3', 'exp-target-binding-package-20261025',
    'exp-signing-package-20261025',
)
PRIMARY = tuple('.build/' + name for name in ('out','test-module-cache','test-cache')) + tuple(
    '.build/t32-t33-completion-20261023/' + name for name in PACKAGES) + (
    '.build/t33t-20261025/.cfw-history/20261025T021021Z-hnTJT23g/effect-blobs',
) + tuple('.build/t32-t33-completion-20261023/' + folder + '/' + mode + '/cache.dmg'
    for folder in ('cryptex-tree-stability-20261025-user','cryptex-tree-stability-20261025-user-r2')
    for mode in ('writable','readonly'))
SECONDARY = tuple('vm-t32-t33-dsc-20261018/' + name for name in
    ('.cfw-history','Disk.img','iPhone17,3_26.0_23A341_Restore'))
TARGET_FREE = 100 * 1024**3


def save(path,value):
    previous.base.save(path,value)


def configure():
    storage.ROOT=ROOT;storage.OUT=OUT


def sha(path):
    return previous.base.evidence.digest(Path(path))


def inventory(path):
    if path.is_symlink() or path.resolve(strict=True)!=path:
        raise ValueError('Linked or unexpected cleanup target: '+str(path))
    if path.is_file():return {str(path.relative_to(ROOT)):storage.metadata(path)}
    if not path.is_dir():raise ValueError('Special cleanup target')
    for directory,_,_ in os.walk(path,followlinks=False,onerror=lambda error:(_ for _ in ()).throw(error)):
        if not os.access(directory,os.W_OK|os.X_OK):raise ValueError('Unwritable cleanup directory: '+directory)
    return storage.inventory(path)


def unused(path):
    if path.is_dir():return storage.unused(path)
    result=subprocess.run(['/usr/sbin/lsof','-nP','-F','pn',str(path)],capture_output=True,text=True,timeout=60)
    if result.returncode not in (0,1) or result.stderr.strip():raise ValueError('File holder check failed')
    owner=None
    for line in result.stdout.splitlines():
        if line.startswith('p'):owner=int(line[1:])
        elif line.startswith('n') and owner!=os.getpid():raise ValueError('Cleanup file held by another process')


def exact_scope(plan):
    if (tuple(plan['primary'])!=PRIMARY or tuple(plan['secondary'])!=SECONDARY
            or plan['targetFreeBytes']!=TARGET_FREE or plan['VMStarts']!=0
            or plan['securityWindows']!=0 or plan['automaticRetry'] is not False):
        raise ValueError('Cleanup scope differs from named capacity plan')
    targets=[ROOT/name for name in PRIMARY+SECONDARY]
    if any(a!=b and a in b.parents for a in targets for b in targets):raise ValueError('Overlapping cleanup roots')
    for name in plan['protectedInputs']:
        if any(Path(name)==target or target in Path(name).parents for target in targets):
            raise ValueError('Protected input intersects cleanup scope: '+name)
    return targets


def preserved(plan,removed=()):
    for name,digest in plan['protectedInputs'].items():
        if sha(name)!=digest:raise ValueError('Protected input changed: '+name)
    for name,expected in plan['protectedDiskIdentities'].items():
        if name in removed:continue
        info=(ROOT/name).lstat()
        if dict(dev=info.st_dev,ino=info.st_ino,size=info.st_size)!=expected:
            raise ValueError('Protected disk identity changed: '+name)
    for name,value in plan['protectedTrees'].items():
        if storage.inventory(ROOT/name)!=value:raise ValueError('Retained source generation changed: '+name)
    if sha(ROOT/plan['currentEXPDisk'])!=plan['expectedEXPDiskSHA256']:
        raise ValueError('Current EXP complete disk differs from source baseline')
    return previous.base.baseline(plan)


def package_records():
    records={}
    for path in BASE.glob('candidate*.json'):
        value=json.loads(path.read_bytes())
        if isinstance(value,dict) and value.get('bundle'):
            parent=Path(value['bundle']).parent
            if parent.name in PACKAGES:records[parent.name]=value
    return [records[name] for name in PACKAGES]


def prepare():
    configure()
    if OUT.exists():raise ValueError('Preserve existing cleanup preparation')
    old=json.loads((previous.WORK/'offline-plan.json').read_bytes())
    if json.loads((previous.WORK/'finalization.json').read_bytes())['nativeState']!='failed':
        raise ValueError('Latest offline execution not finalized')
    plan={key:old[key] for key in ('sourceBackup','sourceBootFiles')}
    plan.update(schemaVersion=1,primary=list(PRIMARY),secondary=list(SECONDARY),targetFreeBytes=TARGET_FREE,
        VMStarts=0,securityWindows=0,automaticRetry=False,authorization='not approved',
        protectedInputs=dict(old['frozenInputs']),protectedDiskIdentities=dict(old['unrelatedDiskIdentities']),
        currentEXPDisk='.build/t33t-20261025/Disk.img',
        expectedEXPDiskSHA256=old['sourceBootFiles']['Disk.img']['sha256'],
        protectedTrees={str((OLD_VM/name).relative_to(ROOT)):storage.inventory(OLD_VM/name)
                        for name in ('.firmware-generations','.firmware-history')},packages=package_records())
    exact_scope(plan)
    targets=[ROOT/name for name in PRIMARY+SECONDARY]
    if subprocess.check_output(['/usr/bin/git','ls-files','-z','--',*PRIMARY,*SECONDARY],cwd=ROOT):
        raise ValueError('Tracked file in cleanup scope')
    storage.attachments(targets)
    rows={}
    for path in targets:
        unused(path);rows[str(path.relative_to(ROOT))]=inventory(path)
    comparisons=[packages.compare(Path(row['bundle']).parent,Path(row['archive']),row['archiveSHA256'],plan['protectedInputs'])
                 for row in plan['packages']]
    if any(row['currentPlanFrozenReferences'] for row in comparisons):raise ValueError('Package is a protected input')
    for row in plan['packages']:plan['protectedInputs'][row['archive']]=row['archiveSHA256']
    for name in ('failed_rounds_cleanup_20261025.py','test_failed_rounds_cleanup_20261025.py',
                 'project_storage_review_20261024.py','retire_t32_t33_states_20261025.py'):
        path=ROOT/'research'/name;plan['protectedInputs'][str(path)]=sha(path)
    record=ROOT/'.build/t33t-20261025/.cfw-history/20261025T021021Z-hnTJT23g/transaction.json'
    if json.loads(record.read_bytes())['status']!='failed':raise ValueError('Selected blob transaction is not failed')
    plan['protectedInputs'][str(record)]=sha(record)
    plan['sourceBaselineBeforeReview']=preserved(plan)
    plan['allocatedBytesByTarget']={name:sum(v['blocks']*512 for v in values.values()) for name,values in rows.items()}
    plan['freeBytesAtReview']=shutil.disk_usage(ROOT).free
    plan['inventorySHA256']=hashlib.sha256(gzip.compress(json.dumps(rows).encode(),mtime=0)).hexdigest()
    OUT.mkdir()
    (OUT/'inventory-before.json.gz').write_bytes(gzip.compress(json.dumps(rows).encode(),mtime=0))
    save(OUT/'package-comparison.json',comparisons);save(OUT/'plan.json',plan)
    print(json.dumps(dict(state='prepared-not-approved',planSHA256=sha(OUT/'plan.json'),
        targets=len(targets),freeBytes=plan['freeBytesAtReview'],primaryAllocatedBytes=sum(plan['allocatedBytesByTarget'][n] for n in PRIMARY),
        secondaryAllocatedBytes=sum(plan['allocatedBytesByTarget'][n] for n in SECONDARY))))


def remove_one(path,expected):
    unused(path)
    if inventory(path)!=expected:raise ValueError('Cleanup target changed immediately before deletion')
    if path.is_dir():
        if not shutil.rmtree.avoids_symlink_attacks:raise ValueError('Descriptor-based removal required')
        shutil.rmtree(path)
    else:path.unlink()
    if os.path.lexists(path):raise ValueError('Cleanup target remains')


def apply(digest):
    configure();plan=json.loads((OUT/'plan.json').read_bytes());targets=exact_scope(plan)
    if sha(OUT/'plan.json')!=digest:raise ValueError('Wrong approved cleanup plan digest')
    approved=json.loads((OUT/'approval.json').read_bytes())
    if approved!=dict(approved=True,planSHA256=digest,allowOldDSC=True):
        raise ValueError('Explicit cleanup and old DSC retirement approval required')
    if (OUT/'result.json').exists():raise ValueError('Prior cleanup result exists; no replay')
    raw=(OUT/'inventory-before.json.gz').read_bytes()
    if hashlib.sha256(raw).hexdigest()!=plan['inventorySHA256']:raise ValueError('Prepared inventory changed')
    inventories=json.loads(gzip.decompress(raw));handles=[]
    result=dict(state='checking',removed=[],skipped=[],planSHA256=digest,VMStarts=0,securityWindows=0)
    save(OUT/'result.json',result)
    try:
        for vm in (OLD_VM,ROOT/'.build/t33t-20261025'):
            storage.acquire(vm,handles,directory=True)
        for path in targets:storage.acquire(path,handles,directory=path.is_dir())
        storage.attachments(targets)
        for path in targets:
            unused(path)
            if inventory(path)!=inventories[str(path.relative_to(ROOT))]:raise ValueError('Prepared cleanup input changed')
        result['sourceBaselineBefore']=preserved(plan)
        archive_count=storage.archive_small_records(inventories)
        result.update(metadataFilesArchived=archive_count,freeBytesBefore=shutil.disk_usage(ROOT).free,state='removing')
        save(OUT/'result-checking.json',dict(result));save(OUT/'result-removing.json',dict(result))
        for name in PRIMARY+SECONDARY:
            # The explicit optional retirement is used only if the confirmed
            # primary cleanup does not meet the real free-space target.
            if name in SECONDARY and shutil.disk_usage(ROOT).free>=plan['targetFreeBytes']:
                result['skipped'].append(name);continue
            storage.attachments([ROOT/name]);remove_one(ROOT/name,inventories[name])
            result['removed'].append(name)
            storage.save('removal-progress.json',dict(removed=result['removed'],skipped=result['skipped']))
            print('Removed '+name,flush=True)
        result['sourceBaselineAfter']=preserved(plan,result['removed'])
        result['freeBytesAfter']=shutil.disk_usage(ROOT).free
        result['freeBytesIncrease']=result['freeBytesAfter']-result['freeBytesBefore']
        result['capacityTargetPassed']=result['freeBytesAfter']>=plan['targetFreeBytes']
        result['state']='completed' if result['capacityTargetPassed'] else 'capacity-target-not-met'
        result['retiredOldDSCHistory']=SECONDARY[0] in result['removed']
        result['retiredOldDSCDisk']=SECONDARY[1] in result['removed']
    except Exception as error:
        result.update(state='failed',error=str(error));raise
    finally:
        for fd in reversed(handles):os.close(fd)
        storage.save('result.json',result)
    print(json.dumps(result),flush=True)
    return 0 if result['state']=='completed' else 1


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    group=parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--prepare',action='store_true');group.add_argument('--apply-approved')
    args=parser.parse_args()
    if args.prepare:prepare()
    else:raise SystemExit(apply(args.apply_approved))
