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
from .volume_state import volume_read_only

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
    target=str(device)
    if not target.startswith('/'): target='/dev/'+target
    return plistlib.loads(subprocess.check_output(['/usr/sbin/diskutil','info','-plist',target]))


def writable_attachment_state(container):
    """Keep attachment observations except allocation counters changed by writes."""
    state = dict(container)
    state.pop('CapacityFree', None)
    volumes = state.get('Volumes')
    if not isinstance(volumes, list) or any(not isinstance(item, dict) for item in volumes):
        raise ValueError('writable APFS volume inventory is unknown')
    state['Volumes'] = [{key: value for key, value in item.items() if key != 'CapacityInUse'}
                        for item in volumes]
    return state


def mount_point(details, expected):
    if details.get('DeviceIdentifier')!=expected:
        raise ValueError('mounted volume device differs from staged APFS volume')
    if 'Mounted' in details and type(details['Mounted']) is not bool:
        raise ValueError('volume mounted state is unknown')
    point=details.get('MountPoint')
    if details.get('Mounted') is False:
        if point not in (None,'','Not Mounted'):
            raise ValueError('unmounted volume reports a mountpoint')
        return None
    if point in ('','Not Mounted'):
        if details.get('Mounted') is True:
            raise ValueError('mounted volume reports no mountpoint')
        return None
    if isinstance(point,str) and point.startswith('/'):
        return point
    raise ValueError('volume mountpoint is unknown')


def require_mount(root, expected, read_only):
    # Query the path itself as well as selecting the volume through the staged
    # image's physical container. APFS inventory may omit MountPoint entirely.
    details=volume_info(root)
    if mount_point(details,expected)!=str(root) or volume_read_only(details) is not read_only:
        raise ValueError('final volume is not the exact requested mount')
    return details


def mount_roots(plan, image, wanted, *, read_only=True):
    image = gate.private_path(plan, image)
    wanted = set(wanted)
    if not wanted or not wanted.issubset(VOLUMES): raise ValueError('unknown final target volume')
    mount=Path(os.environ['CFW_HOST_MNT']);container=attachments(image)
    reference=container['ContainerReference'];roots={}
    for volume in sorted(wanted):
        name,slice_name=VOLUMES[volume];root=gate.private_path(plan,mount/name)
        matches=[item for item in container.get('Volumes',[]) if item.get('DeviceIdentifier')==reference+slice_name]
        if len(matches)!=1: raise ValueError('missing exact staged APFS volume')
        expected=reference+slice_name
        current=mount_point(volume_info(expected),expected)
        if current==str(root):
            # Reject an over-mounted path before unmounting anything.
            details=volume_info(root)
            if mount_point(details,expected)!=str(root):
                raise ValueError('staged final volume mounted at another path')
        if current==str(root) and volume_read_only(details) is not read_only:
            subprocess.run(['/sbin/umount',str(root)],check=True)
            current=None
        if current is None or current=='Not Mounted':
            root.mkdir(mode=0o700,exist_ok=True)
            if any(root.iterdir()): raise ValueError('final reader mountpoint is not empty')
            subprocess.run(['/sbin/mount_apfs','-o','rdonly' if read_only else 'rw,nobrowse','/dev/'+reference+slice_name,str(root)],check=True)
        elif current!=str(root):
            raise ValueError('staged final volume mounted at another path')
        roots[volume]=root
    mounted=attachments(image)
    identities={}
    for volume,root in roots.items():
        expected=reference+VOLUMES[volume][1]
        if len([item for item in mounted.get('Volumes',[]) if item.get('DeviceIdentifier')==expected])!=1:
            raise ValueError('final root is not the exact staged volume mount')
        require_mount(root,expected,read_only)
        info=root.lstat();identities[volume]=(info.st_dev,info.st_ino)
    if 'system' in roots: roots['dsc']=roots['system']/'System/Cryptexes/OS/System/Library/Caches/com.apple.dyld'
    return roots, mounted, identities


def run(plan):
    import cfw_disk_txn as transaction
    gate.require_write_context(plan)
    if plan.context['variant']=='less': raise ValueError('less requires its encrypted-filesystem final reader')
    evidence=Path(os.environ['VPHONE_GUEST_EVIDENCE']);work=evidence.parent
    image=gate.private_path(plan,work/'Disk.img')
    record=json.loads(gate.strict_bytes(work/'transaction.json'))
    if record.get('version') not in (2,3,4) or record.get('provenanceMode')!='required' or record.get('status')!='staged' or record.get('vm')!=plan.context['vmDirectory']:
        raise ValueError('final reader requires this VM staged transaction')
    transaction.require_staged(work,record['staged'])
    rows=[json.loads(line) for line in gate.strict_bytes(evidence).splitlines()]
    wanted={row['target'].split(':',1)[0] for row in rows}
    if 'dsc' in wanted: wanted.remove('dsc');wanted.add('system')
    roots, mounted, identities = mount_roots(plan, image, wanted)
    reference = mounted['ContainerReference']
    transaction.require_staged(work,record['staged'])
    image_before=transaction.identity(image.lstat())
    evidence_sha=effects.digest(evidence)
    outputs=effects.verify_rows(plan,rows,roots,work/'effect-blobs')
    def recheck_final():
        transaction.require_staged(work,record['staged']);gate.recheck(plan)
        if evidence_sha!=effects.digest(evidence) or attachments(image)!=mounted:
            raise ValueError('final image attachment or operation evidence changed during readback')
        if transaction.identity(image.lstat())!=image_before:
            raise ValueError('staged image changed during readonly effect readback')
        for volume in wanted:
            require_mount(roots[volume],reference+VOLUMES[volume][1],True)
        if any((root.lstat().st_dev,root.lstat().st_ino)!=identities[volume] for volume,root in roots.items() if volume!='dsc'):
            raise ValueError('final mount identity changed during readback')
    recheck_final()
    from .undo_provenance import persist, recheck_sources
    undo_sha = persist(plan,rows,outputs,work)
    recheck_sources(plan,rows,work/'effect-blobs')
    recheck_final()
    return {'schemaVersion':1,'transactionID':record.get('id'),'planDigest':plan.record['planSHA256'],'desiredSHA256':plan.raw_sha256,
            'generationID':plan.context['generationID'],'operationsSHA256':evidence_sha,
            'undoProvenanceSHA256':undo_sha,
            'stagedImage':str(image),'stagedIdentity':image_before,'outputs':outputs,
            'roots':{volume:str(root) for volume,root in roots.items()}}
