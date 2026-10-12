"""Prove a Cryptex mount comes from this generation's verified image chain."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
from . import plan_gate as gate


def file_sha(path):
    return gate.snapshot(path).sha256


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
    marker(cache).write_bytes(gate.canonical(stamp))
    mounted(plan,root)


def prepare(plan, kind, source, cache):
    gate.require_write_context(plan)
    source, cache = Path(source), gate.private_path(plan, cache)
    vm = Path(plan.context['vmDirectory'])
    if vm not in source.parents or source.is_symlink(): raise ValueError('Cryptex input outside bound VM')
    original = vm / '.firmware-generations' / plan.context['generationID'] / 'originals' / source.relative_to(vm)
    if file_sha(source) != file_sha(original): raise ValueError('Cryptex input differs from verified generation')
    binding = dict(schemaVersion=1,generationID=plan.context['generationID'],planDigest=plan.record['planSHA256'],
                   source=str(original),sourceSHA256=file_sha(original))
    stamp = marker(cache)
    if stamp.exists() and cache.exists():
        old=json.loads(gate.strict_bytes(stamp))
        if all(old.get(k)==v for k,v in binding.items()) and old.get('cacheSHA256')==file_sha(cache): return
    if cache.exists(): cache.unlink()
    if kind=='systemos':
        from cache_systemos import cache_systemos
        cache_systemos(source,cache)
    elif kind=='appos': shutil.copyfile(source,cache)
    else: raise ValueError('unknown Cryptex kind')
    stamp.write_bytes(gate.canonical(dict(binding,cacheSHA256=file_sha(cache))))


def mounted(plan, root):
    root=Path(root)
    expected=Path(plan.context['vmDirectory'])/'.cfw_temp'/('CryptexAppOS.dmg' if root.name=='mnt_appos' else 'CryptexSystemOS.dmg')
    stamp=json.loads(gate.strict_bytes(marker(expected)))
    if stamp.get('generationID')!=plan.context['generationID'] or stamp.get('planDigest')!=plan.record['planSHA256']:
        raise ValueError('Cryptex cache differs from bound generation/transformation')
    if stamp.get('cacheSHA256')!=file_sha(expected):
        rows=[json.loads(line) for line in gate.strict_bytes(os.environ['VPHONE_GUEST_EVIDENCE']).splitlines()]
        changes={row['path']:row for row in rows if row.get('sourceImage')==str(expected) and row.get('planDigest')==plan.record['planSHA256']}
        if plan.context['variant']!='exp' or not changes or any(row['afterSHA256']!=file_sha(path) for path,row in changes.items()):
            raise ValueError('Cryptex changed without matching declared DSC readback')
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
    rows=[json.loads(line) for line in gate.strict_bytes(os.environ['VPHONE_GUEST_EVIDENCE']).splitlines()]
    if plan.context['variant']!='exp' or not any(r.get('sourceImage')==str(cache) and r.get('planDigest')==plan.record['planSHA256'] and r.get('declarationID') in ('dyld-exp-hv_vmm','dyld-cfw-camera') for r in rows):
        raise ValueError('Cryptex refresh has no declared DSC evidence')
    info=plistlib.loads(subprocess.check_output(['/usr/bin/hdiutil','info','-plist']))
    if any(Path(image.get('image-path','')).resolve()==cache.resolve() for image in info.get('images',[])):
        raise ValueError('Cryptex refresh requires detached image')
    binding['cacheSHA256']=file_sha(cache);binding['transformation']='declared-exp-dsc'
    stamp.write_bytes(gate.canonical(binding))


def tree(path):
    from .guest_write import walk
    root=Path(path);result={}
    for entry in walk(root):
        relative=str(entry.relative_to(root))
        if entry.is_symlink(): result[relative]={'kind':'link','link':os.readlink(entry)}
        elif entry.is_dir(): result[relative]={'kind':'directory'}
        elif entry.is_file(): result[relative]={'kind':'file','sha256':file_sha(entry)}
        else: raise ValueError('unsupported Cryptex source member')
    return result
