"""Reproduce Cryptex tree reads on new cache clones; never write a VM or source image."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'scripts'))
from patchers import component_effects as effects, cryptex_source, guest_write

KEYS = ('st_dev','st_ino','st_size','st_mtime_ns','st_ctime_ns','st_nlink','st_mode','st_uid','st_gid')


def identity(path):
    info=path.lstat()
    return {key:getattr(info,key) for key in KEYS}


def digest(path):
    with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()


def probe(source, out, readonly):
    clone=out/'cache.dmg';mount=out/'mount';mount.mkdir()
    subprocess.run(['/bin/cp','-c','-p',str(source),str(clone)],check=True)
    clone_sha=digest(clone)
    result=dict(readonly=readonly,uid=os.geteuid(),source=str(source),cloneSHA256Before=clone_sha,
                treePassed=False,diagnostics=[],VMStarts=0,CFWWrites=0)
    command=['/usr/bin/hdiutil','attach','-mountpoint',str(mount),str(clone),'-nobrowse','-owners','off','-plist']
    if readonly:command.append('-readonly')
    attachment=None;original_exit=effects.regular.__exit__
    original_walk=guest_write.walk;original_lstat=Path.lstat
    seen={};walks=[];changes=[]
    def observe_lstat(path,*args,**kwargs):
        info=original_lstat(path,*args,**kwargs)
        if path==mount or mount in path.parents:
            value={key:getattr(info,key) for key in KEYS}
            if path in seen and seen[path]!=value and len(changes)<20:
                changes.append(dict(path=str(path.relative_to(mount)),before=seen[path],after=value))
            seen.setdefault(path,value)
        return info
    def observe_walk(path):
        if Path(path)!=mount:
            yield from original_walk(path);return
        entries=list(original_walk(path));walks.append([str(p.relative_to(mount)) for p in entries])
        yield from entries
    def observe_exit(reader,*args):
        after=os.fstat(reader.fd);named=reader.path.lstat()
        states={label:{key:getattr(info,key) for key in KEYS} for label,info in
                (('before',reader.before),('after',after),('named',named))}
        try:return original_exit(reader,*args)
        except Exception as error:
            result['diagnostics'].append(dict(path=str(reader.path.relative_to(mount)),error=str(error),states=states))
            raise
    try:
        attachment=plistlib.loads(subprocess.check_output(command))
        (out/'attachment.plist').write_bytes(plistlib.dumps(attachment))
        effects.regular.__exit__=observe_exit
        Path.lstat=observe_lstat;guest_write.walk=observe_walk
        started=time.monotonic();tree=cryptex_source.tree(mount)
        result.update(treePassed=True,entries=len(tree),treeSHA256=hashlib.sha256(effects.canonical(tree)).hexdigest(),
                      elapsedSeconds=time.monotonic()-started)
    except Exception as error:result['error']=str(error)
    finally:
        effects.regular.__exit__=original_exit
        Path.lstat=original_lstat;guest_write.walk=original_walk
        result['metadataChanges']=changes
        result['walkCounts']=[len(row) for row in walks]
        result['addedMembers']=sorted(set(walks[-1])-set(walks[0])) if len(walks)>1 else []
        result['removedMembers']=sorted(set(walks[0])-set(walks[-1])) if len(walks)>1 else []
        if attachment is not None:
            subprocess.run(['/usr/bin/hdiutil','detach',str(mount)],check=True)
            result['normallyDetached']=True
        result['cloneSHA256After']=digest(clone)
        (out/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    return result


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    source=args.source.resolve(strict=True);out=args.output
    if not source.is_file() or out.exists() or ROOT not in out.absolute().parents:
        raise ValueError('Require a stable regular source and new repository-local output')
    before=identity(source);sha=digest(source);out.mkdir()
    result=dict(sourceSHA256Before=sha,sourceIdentityBefore=before,observations=[])
    try:
        for name,readonly in (('writable',False),('readonly',True)):
            folder=out/name;folder.mkdir()
            observed=probe(source,folder,readonly);result['observations'].append(observed)
            print(json.dumps(observed),flush=True)
    finally:
        result['sourceIdentityPreserved']=identity(source)==before
        result['sourceSHA256After']=digest(source)
        result['sourceBytesPreserved']=result['sourceSHA256After']==sha
        (out/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    if not result['sourceIdentityPreserved'] or not result['sourceBytesPreserved']:
        raise ValueError('Source changed during clone-only diagnostic')
    return 0 if all(row['treePassed'] for row in result['observations']) else 1


if __name__=='__main__':raise SystemExit(main())
