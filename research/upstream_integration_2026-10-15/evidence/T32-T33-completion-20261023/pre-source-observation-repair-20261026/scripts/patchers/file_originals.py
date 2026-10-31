"""Observe file originals only on fresh readonly images derived from a generation.

The catalog is sealed by the existing CFW journal. Installed files and backup
names cannot create originals; this module never changes the guest disk.
"""
import contextlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

if __package__ in (None,''):sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from patchers import component_effects as effects,component_signatures as signatures
from patchers import plan_gate as gate,undo_provenance,final_guest
import cfw_guest_evidence as evidence

FILENAME='guest-file-originals.json'
ROOT_MEMBERS=('usr/libexec/seputil','usr/libexec/launchd_cache_loader',
              'usr/libexec/mobileactivationd','usr/libexec/diskimagesiod',
              'sbin/launchd','System/Library/xpc/launchd.plist',
              'System/Library/CoreServices/SystemVersion.plist')
VERSION='System/Library/CoreServices/SystemVersion.plist'
PROFILES=(('rootfs','OS',{'system:/'+name:name for name in ROOT_MEMBERS}),
          ('cryptex','Cryptex1,SystemOS',{'preboot:/Cryptexes/OS/'+VERSION:VERSION,
                                       'system:/System/Cryptexes/OS/'+VERSION:VERSION}))


def code_pages(path,kind):
    if kind=='data':return 0
    if kind!='macho':raise ValueError('Unknown original file kind')
    layouts=signatures.layouts(path);directories=signatures.directories(path)
    if not layouts or any(layout['identity']=='dsc' for layout in layouts) or not directories:
        raise ValueError('Original Mach-O has no complete CodeDirectory')
    if {cd['identity'] for cd in directories}!={layout['identity'] for layout in layouts}:
        raise ValueError('Original Mach-O signature misses an architecture')
    if any(cd['count']==0 for cd in directories):raise ValueError('Original Mach-O has no code pages')
    signatures.verify_slots(path,[dict(identity=cd['identity'],slot=cd['slot'],pages=range(cd['count']))
                                  for cd in directories])
    return sum(cd['count'] for cd in directories)


@contextlib.contextmanager
def mounted(image,workspace):
    def run(argv):return subprocess.check_output(argv,stderr=subprocess.PIPE,timeout=60)
    info=plistlib.loads(run(['/usr/bin/hdiutil','info','-plist']))
    if any(Path(row.get('image-path','')).absolute()==image for row in info.get('images',[])):
        raise ValueError('Original image already attached; preserve existing attachment')
    root=Path(tempfile.mkdtemp(prefix='mnt_sysos_file_originals_',dir=workspace));device=None;attached=False
    try:
        info=plistlib.loads(run(['/usr/bin/hdiutil','attach','-readonly','-nobrowse','-owners','on',
                                '-mountpoint',str(root),'-plist',str(image)]));attached=True
        matches=[row for row in info['system-entities'] if row.get('mount-point')==str(root)]
        if len(matches)!=1:raise ValueError('Original image has no unique readonly root')
        device=matches[0]['dev-entry']
        def recheck():
            listing=plistlib.loads(run(['/usr/bin/hdiutil','info','-plist']))
            associated=[row for row in listing.get('images',[]) if Path(row.get('image-path','')).absolute()==image
                        and any(entry.get('mount-point')==str(root) and entry.get('dev-entry')==device
                                for entry in row.get('system-entities',[]))]
            if len(associated)!=1:raise ValueError('Original image mount association changed')
            final_guest.require_mount(root,device.removeprefix('/dev/'),True)
            if not os.statvfs(root).f_flag&os.ST_RDONLY:raise ValueError('Original mount is writable')
        recheck();yield root,recheck;recheck()
    finally:
        if attached:
            # Mount discovery must have identified the device. If discovery
            # failed, preserve the attachment rather than guessing its owner.
            if device is None:raise ValueError('Unknown original attachment device; preserve it')
            # Normal detach unmounts this owned source volume and detaches its
            # image. A busy-volume failure preserves both for caller cleanup.
            run(['/usr/bin/hdiutil','detach',device])
        root.rmdir()


def capture_members(root,mapping,store):
    result={}
    for target,relative in mapping.items():
        path=root/relative;parent=path.parent
        while parent!=root:
            if parent.is_symlink():raise ValueError('Linked original file parent')
            parent=parent.parent
        state=effects.capture_input(path,store,False,readonly_source=True)
        if state['kind']=='missing':continue
        if state['kind']!='file':raise ValueError('Original member is not a regular file')
        kind='data' if relative.endswith('.plist') else 'macho'
        pages=code_pages(effects.blob(store,state['sha256']),kind)
        result[target]=dict(state=state,kind=kind,verifiedCodePages=pages)
    return result


def source_selection(plan):
    """Select only manifest-bound customer erase sources; absence grants nothing."""
    generation=Path(plan.context['vmDirectory'])/'.firmware-generations'/plan.context['generationID']
    manifest=json.loads(gate.strict_bytes(generation/'manifest.json'))
    restores=[row['name'] for row in manifest['content']['originals'] if row['name'].endswith('Restore')]
    if len(restores)!=1:return {}
    restore=generation/'originals'/restores[0]
    identity_manifest=restore/'iPhone-BuildManifest.plist'
    if not identity_manifest.exists():identity_manifest=restore/'BuildManifest.plist'
    if not identity_manifest.exists():return {}
    identities=plistlib.loads(gate.strict_bytes(identity_manifest))['BuildIdentities']
    identities=[row for row in identities if row.get('Info',{}).get('Variant')=='Customer Erase Install (IPSW)']
    if len(identities)!=1:return {}
    result={}
    for name,key,_mapping in PROFILES:
        item=identities[0]['Manifest'].get(key)
        if item is None:continue
        relative=Path(item['Info']['Path'])
        if relative.is_absolute() or '..' in relative.parts:raise ValueError('Invalid original source path')
        source=restore/relative
        # This also verifies the BuildManifest's containing original tree.
        result[name]=(source,undo_provenance.qualify_source(plan,source))
    return result


def prepare(plan,work):
    import cfw_disk_txn as transaction
    from cache_systemos import cache_systemos
    gate.require_write_context(plan);work=gate.private_path(plan,work)
    record=transaction.staged_record(work)
    if (record['version']!=5 or record.get('operation') is not None
            or work!=Path(os.environ['VPHONE_GUEST_EVIDENCE']).parent):
        raise ValueError('File originals require this new ordinary CFW transaction')
    selected=source_selection(plan)
    directory=work/'file-original-sources';directory.mkdir(mode=0o700)
    store=work/evidence.STORE;store.mkdir(mode=0o700,exist_ok=True)
    members={};sources=[]
    for name,_key,mapping in PROFILES:
        if name not in selected:continue
        source,qualified=selected[name]
        image=directory/(name+'.dmg')
        cache_systemos(source,image)
        digest=effects.digest(image)
        with mounted(image,Path(os.environ['CFW_HOST_MNT'])) as (root,recheck):
            observed=capture_members(root,mapping,store);recheck()
        if (effects.digest(image)!=digest or undo_provenance.qualify_source(plan,source)!=qualified):
            raise ValueError('Original image/source changed during observation')
        index=len(sources)
        sources.append(dict(profile=name,source=str(source),generationSource=qualified,imageSHA256=digest))
        for target,value in observed.items():
            if target in members:raise ValueError('Duplicate original file target')
            members[target]=dict(value,sourceIndex=index)
        # The mount has normally detached and the required member blobs are
        # durable. This invocation's decoded source image is scratch, not a
        # retained VM disk or generation original. Refuse a substituted name.
        if effects.digest(image)!=digest:raise ValueError('Original scratch image changed before cleanup')
        image.unlink()
    directory.rmdir()
    if transaction.staged_record(work)!=record:raise ValueError('CFW transaction changed during original capture')
    catalog=dict(schemaVersion=1,transactionID=record['id'],vmDirectory=record['vm'],
                 generationID=plan.context['generationID'],planSHA256=plan.record['planSHA256'],
                 desiredSHA256=plan.raw_sha256,sources=sources,members=members)
    evidence.write_new(work/FILENAME,evidence.canonical(catalog))
    record['fileOriginalsSHA256']=evidence.digest(work/FILENAME);transaction.save_record(work,record)
    return catalog


def load(plan,store):
    import cfw_disk_txn as transaction
    work=Path(store).parent;record=transaction.load_record(work)
    expected=None if record is None else record.get('fileOriginalsSHA256')
    path=work/FILENAME
    if expected is None:
        if path.exists() or path.is_symlink():raise ValueError('Unbound file original catalog')
        return None
    raw=evidence.read(path);catalog=json.loads(raw)
    if (record['version']!=5 or gate.sha(raw)!=expected or catalog.get('schemaVersion')!=1
            or catalog.get('transactionID')!=record['id'] or catalog.get('vmDirectory')!=record['vm']
            or catalog.get('generationID')!=plan.context['generationID']
            or catalog.get('planSHA256')!=plan.record['planSHA256']
            or catalog.get('desiredSHA256')!=plan.raw_sha256):
        raise ValueError('File original catalog qualification differs')
    mappings={name:mapping for name,_key,mapping in PROFILES};selected=source_selection(plan);seen=set()
    for source in catalog['sources']:
        profile=source['profile']
        if (profile not in selected or profile in seen
                or selected[profile]!=(Path(source['source']),source['generationSource'])
                or not isinstance(source.get('imageSHA256'),str) or not gate.DIGEST.fullmatch(source['imageSHA256'])):
            raise ValueError('File original generation source changed')
        seen.add(profile)
    for target,value in catalog['members'].items():
        index=value['sourceIndex']
        if type(index) is not int or not 0<=index<len(catalog['sources']):raise ValueError('Invalid file original source index')
        profile=catalog['sources'][index]['profile']
        if target not in mappings[profile] or value['state'].get('kind')!='file':raise ValueError('Unknown original file target')
        state=value['state']
        if (set(state)!={'kind','sha256','mode','uid','gid'}
                or any(type(state[k]) is not int or state[k]<0 for k in ('mode','uid','gid'))
                or state['mode']>0o7777):raise ValueError('Invalid original file metadata')
        kind='data' if mappings[profile][target].endswith('.plist') else 'macho'
        if value['kind']!=kind or code_pages(effects.blob(store,value['state']['sha256']),kind)!=value['verifiedCodePages']:
            raise ValueError('File original code pages differ')
    return catalog


if __name__=='__main__':
    if len(sys.argv)!=3 or sys.argv[1]!='prepare':raise SystemExit('usage: file_originals.py prepare WORK')
    prepare(gate.from_environment(),Path(sys.argv[2]))
