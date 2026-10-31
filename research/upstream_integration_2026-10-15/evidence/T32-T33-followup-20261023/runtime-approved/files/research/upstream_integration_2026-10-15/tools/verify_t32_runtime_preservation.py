#!/usr/bin/env python3
"""Read back preserved boot-state backups and both prior evidence batches."""
import hashlib
import json
from pathlib import Path
import time

ROOT=Path(__file__).resolve().parents[3]
WORK=ROOT/'.build/t32-t33-followup-20261023'


def digest(path):
    h=hashlib.sha256()
    with path.open('rb') as stream:
        for data in iter(lambda:stream.read(16*1024*1024),b''):h.update(data)
    return h.hexdigest()


def main():
    backup=json.loads((WORK/'runtime-backup.json').read_text());rows={}
    for name,record in backup['files'].items():
        path=Path(backup['backup'])/name;actual=digest(path)
        if actual!=record['sha256'] or path.stat().st_size!=record['bytes']:
            raise ValueError('Backup changed: '+name)
        rows[name]=dict(bytes=path.stat().st_size,sha256=actual,passed=True)
    archives={};base=ROOT/'research/upstream_integration_2026-10-15/evidence'
    for relative in ['T32-T33-followup-20261023','T32-T33-new-vm-20261018/dsc-on-off-on-20261020-resume']:
        folder=base/relative;manifest=json.loads((folder/'manifest.json').read_text())
        entries=manifest['files']
        if isinstance(entries,dict):entries=[dict(path=name,**row) for name,row in entries.items()]
        for row in entries:
            path=folder/row['path']
            if path.stat().st_size!=row['bytes'] or digest(path)!=row['sha256']:
                raise ValueError('Archived evidence changed: '+str(path))
        archives[relative]=len(entries)
    plan=json.loads((WORK/'runtime-plan.json').read_text());changed=[]
    for path,expected in plan['frozenTools'].items():
        if digest(Path(path))!=expected:changed.append(path)
    observer=str(ROOT/'research/upstream_integration_2026-10-15/tools/observe_t32_runtime.py')
    if changed!=[observer]:raise ValueError('Unexpected frozen input changes: '+str(changed))
    if digest(WORK/'executed-runtime-observer.py')!=plan['frozenTools'][observer]:
        raise ValueError('Executed observer copy changed')
    metadata={};vm=Path(backup['vm'])
    for name,record in backup['files'].items():
        if name=='Disk.img':continue
        actual=digest(vm/name)
        metadata[name]=dict(sha256=actual,matchesBackup=actual==record['sha256'])
    result=dict(backupFiles=rows,all12BackupFilesPassed=len(rows)==12,priorArchives=archives,
                currentMetadata=metadata,frozenInputsChangedAfterExecution=changed,
                executedObserverSaved=True,time=time.time())
    with (WORK/'runtime-preservation.json').open('x') as stream:
        json.dump(result,stream,indent=2);stream.write('\n')
    print(json.dumps(dict(backupFilesVerified=len(rows),priorArchives=archives,
                         currentMetadataMatches={name:row['matchesBackup'] for name,row in metadata.items()})))


if __name__=='__main__':main()
