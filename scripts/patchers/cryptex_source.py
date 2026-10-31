"""Prove a Cryptex mount comes from this generation's verified image chain."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
from . import plan_gate as gate


def file_sha(path, *, readonly_source=False):
    return gate.snapshot(path,readonly_source=readonly_source).sha256


def observation(path):
    """Bind a stable regular image's identity and bytes in one observation."""
    from . import component_effects as effects
    with effects.regular(path) as stream:
        info=os.fstat(stream.fileno());digest=hashlib.sha256()
        while block:=stream.read(effects.CHUNK): digest.update(block)
    return {'device':info.st_dev,'inode':info.st_ino,'size':info.st_size,'sha256':digest.hexdigest()}


def proof(plan, cache):
    from . import component_effects as effects
    binding=json.loads(gate.strict_bytes(marker(cache)))
    if binding.get('planDigest')!=plan.record['planSHA256'] or binding.get('generationID')!=plan.context['generationID']:
        raise ValueError('image binding belongs to another frozen plan')
    store=Path(os.environ['VPHONE_GUEST_EVIDENCE']).parent/'effect-blobs'
    return {'bindingSHA256':effects.persist(marker(cache),store),'image':observation(cache)}


def image_rows(plan, cache):
    evidence=Path(os.environ['VPHONE_GUEST_EVIDENCE'])
    rows=[json.loads(line) for line in gate.strict_bytes(evidence).splitlines()] if evidence.exists() else []
    return [row for row in rows if row.get('sourceImage')==str(cache) and row.get('target','').startswith('dsc:')
            and row.get('planDigest')==plan.record['planSHA256']]


def expected_tree(binding, rows):
    from . import component_effects as effects
    result=dict(binding['baselineTree'])
    for row in rows:
        relative='System/Library/Caches/com.apple.dyld/'+row['target'].removeprefix('dsc:/')
        effect=row.get('effect')
        if effect is None or effect['operation']!='change' or effects.content(effect['before'])!=result.get(relative):
            raise ValueError('Cryptex member lacks original/preceding source relation')
        result[relative]=effects.content(effect['after'])
    return result


def marker(cache): return Path(cache).with_name('.' + Path(cache).name + '.source.json')


def attach(plan, cache, root):
    gate.require_write_context(plan)
    cache,root=gate.private_path(plan,cache),gate.private_path(plan,root)
    mount=Path(os.environ['CFW_HOST_MNT'])
    if root.parent!=mount or root.name not in ('mnt_sysos','mnt_appos','mnt_sysos_hv_vmm'):
        raise ValueError('unknown Cryptex mount target')
    if root.name=='mnt_sysos_hv_vmm' and plan.context['variant']!='exp': raise ValueError('EXP source mount requires EXP')
    expected=Path(plan.context['vmDirectory'])/'.cfw_temp'/('CryptexAppOS.dmg' if root.name=='mnt_appos' else 'CryptexSystemOS.dmg')
    if cache!=expected: raise ValueError('Cryptex image differs from declared source')
    stamp=json.loads(gate.strict_bytes(marker(cache)))
    if stamp.get('generationID')!=plan.context['generationID'] or stamp.get('planDigest')!=plan.record['planSHA256'] or stamp.get('cacheSHA256')!=file_sha(cache) or stamp.get('sourceSHA256')!=file_sha(stamp['source']):
        raise ValueError('Cryptex source changed before mount')
    command=['/usr/bin/hdiutil','attach','-mountpoint',str(root),str(cache),'-nobrowse','-owners','off']
    if root.name!='mnt_sysos_hv_vmm': command.append('-readonly')
    subprocess.run(command,check=True)
    stamp['cacheSHA256']=file_sha(cache)
    if root.name=='mnt_sysos_hv_vmm':
        if stamp.get('transition'): raise ValueError('Cryptex transformation cannot be restarted')
        stamp['imageBefore']=observation(cache)
        stamp['baselineTree']=tree(root)
    elif root.name=='mnt_sysos' and not stamp.get('transition'):
        # First-member provenance is captured only on the original readonly
        # image. Installed files and writable transformed caches cannot create it.
        from .undo_provenance import capture_baseline
        stamp['originalDSC']=capture_baseline(plan,root,cache,stamp)
    previous = gate.strict_bytes(marker(cache))
    marker(cache).write_bytes(gate.canonical(stamp))
    try:
        mounted(plan,root)
    except Exception:
        marker(cache).write_bytes(previous)
        raise


def prepare(plan, kind, source, cache):
    gate.require_write_context(plan)
    source, cache = Path(source), gate.private_path(plan, cache)
    vm = Path(plan.context['vmDirectory'])
    if vm not in source.parents or source.is_symlink(): raise ValueError('Cryptex input outside bound VM')
    original = vm / '.firmware-generations' / plan.context['generationID'] / 'originals' / source.relative_to(vm)
    original_before = observation(original)
    if file_sha(source) != original_before['sha256']: raise ValueError('Cryptex input differs from verified generation')
    binding = dict(schemaVersion=1,generationID=plan.context['generationID'],planDigest=plan.record['planSHA256'],
                   source=str(original),sourceSHA256=original_before['sha256'])
    stamp = marker(cache)
    if stamp.exists() and cache.exists():
        old=json.loads(gate.strict_bytes(stamp))
        if all(old.get(k)==v for k,v in binding.items()) and old.get('cacheSHA256')==file_sha(cache): return
    if cache.exists(): cache.unlink()
    if kind=='systemos':
        from cache_systemos import cache_systemos
        cache_systemos(original,cache)
    elif kind=='appos': shutil.copyfile(original,cache)
    else: raise ValueError('unknown Cryptex kind')
    if observation(original) != original_before: raise ValueError('Cryptex original changed during cache creation')
    stamp.write_bytes(gate.canonical(dict(binding,cacheSHA256=file_sha(cache))))


def mounted(plan, root):
    root=Path(root)
    expected=Path(plan.context['vmDirectory'])/'.cfw_temp'/('CryptexAppOS.dmg' if root.name=='mnt_appos' else 'CryptexSystemOS.dmg')
    stamp=json.loads(gate.strict_bytes(marker(expected)))
    if stamp.get('generationID')!=plan.context['generationID'] or stamp.get('planDigest')!=plan.record['planSHA256']:
        raise ValueError('Cryptex cache differs from bound generation/transformation')
    observed=observation(expected)
    rows=image_rows(plan,expected)
    if root.name=='mnt_sysos_hv_vmm':
        initial=stamp.get('imageBefore')
        if initial is None or any(initial[key]!=observed[key] for key in ('device','inode')):
            raise ValueError('writable Cryptex image identity changed')
        if tree(root)!=expected_tree(stamp,rows):
            raise ValueError('Cryptex tree contains unproved member changes')
    else:
        if stamp.get('cacheSHA256')!=observed['sha256']:
            raise ValueError('Cryptex final image digest changed')
        if stamp.get('transition'):
            if observed!=stamp['transition']['after'] or tree(root)!=expected_tree(stamp,rows):
                raise ValueError('remounted Cryptex differs from proved image/member transition')
    if file_sha(stamp['source'])!=stamp['sourceSHA256']: raise ValueError('Cryptex original changed')
    info=plistlib.loads(subprocess.check_output(['/usr/bin/hdiutil','info','-plist']))
    matches=[image for image in info.get('images',[]) if Path(image.get('image-path','')).resolve()==expected.resolve()
             and any(entity.get('mount-point')==str(root) for entity in image.get('system-entities',[]))]
    if len(matches)!=1: raise ValueError('Cryptex mount is not the bound image')
    return expected


def refresh(plan, cache):
    gate.require_write_context(plan)
    cache=gate.private_path(plan,cache);stamp=marker(cache);binding=json.loads(gate.strict_bytes(stamp))
    if binding.get('generationID')!=plan.context['generationID'] or binding.get('planDigest')!=plan.record['planSHA256']:
        raise ValueError('Cryptex transformation belongs to another plan')
    # This transition is available only after a declared EXP DSC operation has
    # recorded this exact image, and after hdiutil has released all its mounts.
    from . import component_effects as effects
    rows=image_rows(plan,cache)
    baseline_digest=effects.persist(stamp,Path(os.environ['VPHONE_GUEST_EVIDENCE']).parent/'effect-blobs')
    if (plan.context['variant']!='exp' or not rows or binding.get('transition') or
        any(row.get('declarationID') not in ('dyld-exp-hv_vmm','dyld-cfw-camera') or
            row.get('sourceImageProof',{}).get('bindingSHA256')!=baseline_digest for row in rows)):
        raise ValueError('Cryptex refresh has no bound declared DSC evidence')
    expected_tree(binding,rows)
    final=observation(cache);initial=binding['imageBefore']
    if any(initial[key]!=final[key] for key in ('device','inode')):
        raise ValueError('Cryptex image replaced during transformation')
    info=plistlib.loads(subprocess.check_output(['/usr/bin/hdiutil','info','-plist']))
    if any(Path(image.get('image-path','')).resolve()==cache.resolve() for image in info.get('images',[])):
        raise ValueError('Cryptex refresh requires detached image')
    binding['cacheSHA256']=final['sha256'];binding['transformation']='declared-exp-dsc'
    binding['transition']={'baselineBinding':baseline_digest,'before':initial,'after':final,
        'rows':[hashlib.sha256(gate.canonical(row)).hexdigest() for row in rows]}
    stamp.write_bytes(gate.canonical(binding))


def _member_identity(info):
    return tuple(getattr(info,key) for key in (
        'st_dev','st_ino','st_size','st_mtime_ns','st_ctime_ns','st_nlink','st_mode','st_uid','st_gid'))


def _contained_member_sha(path, aliases, identities):
    """Read a closed hard-link group without authorizing a patch write."""
    from . import component_effects as effects
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
    try:
        before=os.fstat(fd)
        if (not stat.S_ISREG(before.st_mode) or before.st_nlink!=len(aliases)
                or _member_identity(before)!=_member_identity(identities[path])):
            raise ValueError('Cryptex hard-link group changed before read')
        digest=hashlib.sha256()
        while block:=os.read(fd,effects.CHUNK): digest.update(block)
        if (_member_identity(os.fstat(fd))!=_member_identity(before)
                or any(_member_identity(alias.lstat())!=_member_identity(identities[alias])
                       for alias in aliases)):
            raise ValueError('Cryptex hard-link group changed during read')
        return digest.hexdigest()
    finally: os.close(fd)


def tree(path, *, readonly_source=False):
    from .guest_write import walk
    root=Path(path);result={};entries=list(walk(root))
    identities={entry:entry.lstat() for entry in entries}
    groups={}
    for entry,info in identities.items():
        if stat.S_ISREG(info.st_mode) and info.st_nlink>1:
            groups.setdefault((info.st_dev,info.st_ino),[]).append(entry)
    if not readonly_source:
        for (device,_),aliases in groups.items():
            if device!=identities[root].st_dev or any(identities[p].st_nlink!=len(aliases) for p in aliases):
                raise ValueError('Cryptex hard-link group extends outside observed tree')
    linked_digests={}
    for entry in entries:
        relative=str(entry.relative_to(root))
        info=identities[entry]
        if stat.S_ISLNK(info.st_mode): result[relative]={'kind':'link','link':os.readlink(entry)}
        elif stat.S_ISDIR(info.st_mode): result[relative]={'kind':'directory'}
        elif stat.S_ISREG(info.st_mode):
            if info.st_nlink>1 and not readonly_source:
                key=(info.st_dev,info.st_ino)
                if key not in linked_digests:
                    linked_digests[key]=_contained_member_sha(entry,groups[key],identities)
                digest=linked_digests[key]
            else: digest=file_sha(entry,readonly_source=readonly_source)
            result[relative]={'kind':'file','sha256':digest}
        else: raise ValueError('unsupported Cryptex source member')
    if (entries!=list(walk(root)) or any(_member_identity(entry.lstat())!=_member_identity(info)
                                       for entry,info in identities.items())):
        raise ValueError('Cryptex tree changed during read')
    return result
