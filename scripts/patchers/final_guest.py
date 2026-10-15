"""Qualify the current staged disk's actual APFS roots before effect readback.

This validates producer evidence. It does not publish component receipts or
origin records; the transaction coordinator owns those decisions.
"""
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess

from . import component_effects as effects
from . import plan_gate as gate

VOLUMES={'system':('mnt1','s1'),'hardware':('mnt3','s3'),'preboot':('mnt5','s5')}


def attachments(image):
    info=plistlib.loads(subprocess.check_output(['/usr/bin/hdiutil','info','-plist']))
    matches=[item for item in info.get('images',[]) if Path(item.get('image-path','')).absolute()==image]
    if len(matches)!=1: raise ValueError('final image has no unique live attachment')
    bases={entry.get('dev-entry') for entry in matches[0].get('system-entities',[])
           if re.fullmatch('/dev/disk[0-9]+',entry.get('dev-entry',''))}
    physical={entry.get('dev-entry') for entry in matches[0].get('system-entities',[])
              if entry.get('content-hint') in ('GUID_partition_scheme','FDisk_partition_scheme','Apple_partition_scheme')}
    if physical: bases &= physical
    if len(bases)!=1: raise ValueError('final image has no unique base device')
    physical=next(iter(bases)).removeprefix('/dev/')+'s1'
    listing=plistlib.loads(subprocess.check_output(['/usr/sbin/diskutil','apfs','list','-plist']))
    containers=[item for item in listing.get('Containers',[])
                if [store.get('DeviceIdentifier') for store in item.get('PhysicalStores',[])]==[physical]]
    if len(containers)!=1 or not re.fullmatch('disk[0-9]+',containers[0].get('ContainerReference','')):
        raise ValueError('final APFS container differs from attached staged image')
    return containers[0]


def volume_info(device):
    return plistlib.loads(subprocess.check_output(['/usr/sbin/diskutil','info','-plist','/dev/'+device]))


def run(plan):
    import cfw_disk_txn as transaction
    gate.require_write_context(plan)
    if plan.context['variant']=='less': raise ValueError('less requires its encrypted-filesystem final reader')
    evidence=Path(os.environ['VPHONE_GUEST_EVIDENCE']);work=evidence.parent
    image=gate.private_path(plan,work/'Disk.img')
    record=json.loads(gate.strict_bytes(work/'transaction.json'))
    if record.get('version') not in (1,2) or record.get('status')!='staged' or record.get('vm')!=plan.context['vmDirectory']:
        raise ValueError('final reader requires this VM staged transaction')
    transaction.require_staged(work,record['staged'])
    rows=[json.loads(line) for line in gate.strict_bytes(evidence).splitlines()]
    wanted={row['target'].split(':',1)[0] for row in rows}
    if 'dsc' in wanted: wanted.remove('dsc');wanted.add('system')
    if not wanted or not wanted.issubset(VOLUMES): raise ValueError('unknown final target volume')
    mount=Path(os.environ['CFW_HOST_MNT']);container=attachments(image)
    reference=container['ContainerReference'];roots={}
    for volume in sorted(wanted):
        name,slice_name=VOLUMES[volume];root=gate.private_path(plan,mount/name)
        matches=[item for item in container.get('Volumes',[]) if item.get('DeviceIdentifier')==reference+slice_name]
        if len(matches)!=1: raise ValueError('missing exact staged APFS volume')
        current=matches[0].get('MountPoint')
        if current==str(root) and volume_info(reference+slice_name).get('ReadOnlyVolume') is not True:
            subprocess.run(['/sbin/umount',str(root)],check=True)
            current=None
        if current is None or current=='Not Mounted':
            root.mkdir(mode=0o700,exist_ok=True)
            if any(root.iterdir()): raise ValueError('final reader mountpoint is not empty')
            subprocess.run(['/sbin/mount_apfs','-o','rdonly','/dev/'+reference+slice_name,str(root)],check=True)
        elif current!=str(root):
            raise ValueError('staged final volume mounted at another path')
        roots[volume]=root
    mounted=attachments(image)
    identities={}
    for volume,root in roots.items():
        expected=reference+VOLUMES[volume][1]
        if len([item for item in mounted.get('Volumes',[]) if item.get('DeviceIdentifier')==expected and item.get('MountPoint')==str(root)])!=1:
            raise ValueError('final root is not the exact staged volume mount')
        details=volume_info(expected)
        if details.get('ReadOnlyVolume') is not True or details.get('DeviceIdentifier')!=expected or details.get('MountPoint')!=str(root):
            raise ValueError('final volume is not the exact readonly mount')
        info=root.lstat();identities[volume]=(info.st_dev,info.st_ino)
    if 'system' in roots: roots['dsc']=roots['system']/'System/Cryptexes/OS/System/Library/Caches/com.apple.dyld'
    transaction.require_staged(work,record['staged'])
    image_before=transaction.identity(image.lstat())
    evidence_sha=effects.digest(evidence)
    outputs=effects.verify_rows(plan,rows,roots,work/'effect-blobs')
    transaction.require_staged(work,record['staged']);gate.recheck(plan)
    if evidence_sha!=effects.digest(evidence) or attachments(image)!=mounted:
        raise ValueError('final image attachment or operation evidence changed during readback')
    if transaction.identity(image.lstat())!=image_before:
        raise ValueError('staged image changed during readonly effect readback')
    if any(volume_info(reference+VOLUMES[volume][1]).get('ReadOnlyVolume') is not True for volume in wanted):
        raise ValueError('final volume lost readonly state')
    if any((root.lstat().st_dev,root.lstat().st_ino)!=identities[volume] for volume,root in roots.items() if volume!='dsc'):
        raise ValueError('final mount identity changed during readback')
    return {'schemaVersion':1,'transactionID':record.get('id'),'planDigest':plan.record['planSHA256'],'desiredSHA256':plan.raw_sha256,
            'generationID':plan.context['generationID'],'operationsSHA256':evidence_sha,
            'stagedImage':str(image),'stagedIdentity':image_before,'outputs':outputs,
            'roots':{volume:str(root) for volume,root in roots.items()}}
