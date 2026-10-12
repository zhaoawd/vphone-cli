"""Durable operation effects with bounded reads and final-target verification.

Blobs are content-addressed evidence, never executable authority. The plan gate
owns declaration/target qualification. Callers must requalify that context before
using verify_rows against an explicit final mount.
"""
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import stat
import struct
import tempfile

CHUNK = 1 << 20


def canonical(value):
    return json.dumps(value,sort_keys=True,separators=(',',':'),ensure_ascii=False).encode()


def digest(path):
    with regular(path) as stream:
        h=hashlib.sha256()
        while block:=stream.read(CHUNK): h.update(block)
        return h.hexdigest()


class regular:
    def __init__(self,path): self.path=Path(path)
    def __enter__(self):
        self.fd=os.open(self.path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
        self.before=os.fstat(self.fd)
        if not stat.S_ISREG(self.before.st_mode) or self.before.st_nlink!=1:
            os.close(self.fd);raise ValueError('effect input is not an unlinked regular file')
        self.stream=os.fdopen(self.fd,'rb');return self.stream
    def __exit__(self,*args):
        try:
            after=os.fstat(self.fd);named=self.path.lstat()
            keys=('st_dev','st_ino','st_size','st_mtime_ns','st_ctime_ns')
            if any(getattr(self.before,k)!=getattr(after,k) or getattr(after,k)!=getattr(named,k) for k in keys):
                raise ValueError('effect input changed during read')
        finally: self.stream.close()


def metadata(path):
    info=Path(path).lstat()
    return {'mode':stat.S_IMODE(info.st_mode),'uid':info.st_uid,'gid':info.st_gid}


def state(path, recursive=True):
    path=Path(path)
    try: info=path.lstat()
    except FileNotFoundError: return {'kind':'missing'}
    result=metadata(path)
    if stat.S_ISLNK(info.st_mode): return dict(result,kind='symlink',link=os.readlink(path))
    if stat.S_ISREG(info.st_mode): return dict(result,kind='file',sha256=digest(path))
    if stat.S_ISDIR(info.st_mode):
        if not recursive: return dict(result,kind='directory')
        names=sorted(os.listdir(path))
        result=dict(result,kind='directory',children={n:state(path/n) for n in names})
        after=path.lstat()
        if (info.st_dev,info.st_ino,info.st_mtime_ns,info.st_ctime_ns)!=(after.st_dev,after.st_ino,after.st_mtime_ns,after.st_ctime_ns) or names!=sorted(os.listdir(path)):
            raise ValueError('effect tree changed during read')
        return result
    raise ValueError('special file in effect tree')


def persist(path,store):
    store=Path(store)
    store.mkdir(mode=0o700,parents=False,exist_ok=True)
    if store.is_symlink() or not store.is_dir(): raise ValueError('linked effect store')
    fd,name=tempfile.mkstemp(prefix='.input-',dir=store)
    try:
        with os.fdopen(fd,'wb') as out, regular(path) as source:
            h=hashlib.sha256()
            while block:=source.read(CHUNK): out.write(block);h.update(block)
            out.flush();os.fsync(out.fileno())
        key=h.hexdigest();target=store/key
        if target.exists():
            if digest(target)!=key: raise ValueError('corrupt effect blob')
        else: os.rename(name,target)
        directory=os.open(store,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
        try: os.fsync(directory)
        finally: os.close(directory)
        return key
    finally:
        if os.path.exists(name): os.unlink(name)


def blob(store,key):
    if not isinstance(key,str) or len(key)!=64 or any(c not in '0123456789abcdef' for c in key): raise ValueError('invalid effect blob key')
    path=Path(store)/key
    if digest(path)!=key: raise ValueError('effect blob differs')
    return path


def capture_input(path,store,recursive=True):
    value=state(path,recursive)
    if value['kind']=='file':
        key=persist(path,store)
        if key!=value['sha256']: raise ValueError('input changed during preservation')
    return value


def plist(path):
    if path.stat().st_size>16*CHUNK: return None
    with regular(path) as stream:
        start=stream.read(8)
        if start!=b'bplist00' and not start.startswith(b'<?xml'): return None
        stream.seek(0)
        try: return plistlib.load(stream)
        except (ValueError,plistlib.InvalidFileException): return None


def projection(before,after,path=()):
    if isinstance(before,dict) and isinstance(after,dict):
        changes=[]
        for key in sorted(set(before)|set(after)):
            if key not in after: changes.append({'path':list(path+(key,)),'deleted':True})
            elif key not in before:
                if isinstance(after[key],dict) and after[key]: changes.extend(projection({},after[key],path+(key,)))
                else: changes.append({'path':list(path+(key,)),'value':encode_value(after[key])})
            else: changes.extend(projection(before[key],after[key],path+(key,)))
        return changes
    if encode_value(before)==encode_value(after): return []
    return [{'path':list(path),'value':encode_value(after)}]


def encode_value(value):
    return base64.b64encode(plistlib.dumps({'value':value},fmt=plistlib.FMT_BINARY,sort_keys=True)).decode()


def macho_layout(path):
    """Thin 64-bit Mach-O load commands; unknown containers use byte effects."""
    with regular(path) as stream:
        header=stream.read(32)
        if len(header)!=32 or header[:4]!=b'\xcf\xfa\xed\xfe': return None
        ncmds,size=struct.unpack_from('<II',header,16)
        if size>16*CHUNK or ncmds>65536: raise ValueError('invalid Mach-O load command bounds')
        commands=stream.read(size)
        if len(commands)!=size: raise ValueError('truncated load command area')
    result=[];groups={};order=[];offset=0
    for _ in range(ncmds):
        if offset+8>len(commands): raise ValueError('truncated load command')
        cmd,length=struct.unpack_from('<II',commands,offset)
        if length<8 or offset+length>len(commands): raise ValueError('invalid load command')
        if cmd==0x1d:
            if length!=16: raise ValueError('invalid code signature command')
            start,count=struct.unpack_from('<II',commands,offset+8)
            if start+count>path.stat().st_size: raise ValueError('invalid code signature region')
        if cmd in (0xc,0x80000018,0x8000001f,0x20,0x80000023):
            if length<24: raise ValueError('invalid dylib command')
            name=struct.unpack_from('<I',commands,offset+8)[0]
            if name<24 or name>=length: raise ValueError('invalid dylib name')
            raw=commands[offset+name:offset+length]
            if b'\0' not in raw: raise ValueError('unterminated dylib name')
            timestamp,current_version,compatibility=struct.unpack_from('<III',commands,offset+12)
            result.append({'command':cmd,'name':raw.split(b'\0',1)[0].decode(),
                           'timestamp':timestamp,'currentVersion':current_version,'compatibilityVersion':compatibility,
                           'raw':base64.b64encode(commands[offset:offset+length]).decode()})
            # The unique dependency path identifies its position; mutable
            # command fields remain independently required by entry effects.
            order.append(('dylib',result[-1]['name']))
        else:
            group=groups.setdefault(str(cmd),[])
            order.append((str(cmd),len(group)))
            group.append(commands[offset:offset+length])
        offset+=length
    if offset!=len(commands): raise ValueError('load command size differs')
    if len({entry['name'] for entry in result})!=len(result):
        raise ValueError('ambiguous duplicate dylib command')
    return {'entries':result,'groups':groups,'order':order,'size':size}


def libraries(path):
    layout=macho_layout(path)
    return None if layout is None else layout['entries']


def command_projection(first,last,scalar_fields=()):
    changes=[]
    for cmd in sorted(set(first)|set(last)):
        old,new=first.get(cmd,[]),last.get(cmd,[])
        if old==new: continue
        if len(old)!=len(new) or any(len(a)!=len(b) for a,b in zip(old,new)):
            changes.append({'command':cmd,'exact':[base64.b64encode(c).decode() for c in new]})
        else:
            for index,(a,b) in enumerate(zip(old,new)):
                changed={i for i,value in enumerate(b) if a[i]!=value}
                # A changed dylib uint32 field requires its complete value,
                # including unchanged bytes within that same field.
                for offset in scalar_fields:
                    field=range(offset,offset+4)
                    if any(i in changed for i in field): changed.update(field)
                edits=[{'offset':i,'value':b[i]} for i in sorted(changed)]
                if edits: changes.append({'command':cmd,'count':len(new),'index':index,'size':len(b),'edits':edits})
    return changes


def verify_command_changes(changes,groups):
    for change in changes:
        actual=groups.get(change['command'],[])
        if 'exact' in change:
            if [base64.b64encode(c).decode() for c in actual]!=change['exact']: raise ValueError('required load command structure differs')
        else:
            if len(actual)!=change['count'] or len(actual[change['index']])!=change['size']: raise ValueError('required load command identity differs')
            command=actual[change['index']]
            if any(command[e['offset']]!=e['value'] for e in change['edits']): raise ValueError('required load command effect was overwritten')


def file_projection(old,new):
    first,last=plist(old),plist(new)
    if first is not None and last is not None:
        return {'kind':'plist','changes':projection(first,last)}
    first,last=macho_layout(old),macho_layout(new)
    changed_entries=[] if first is None or last is None else [entry for entry in last['entries'] if entry not in first['entries']]
    if changed_entries:
        common=set(first['order']) & set(last['order'])
        if [key for key in first['order'] if key in common]!=[key for key in last['order'] if key in common]:
            # Reordering existing commands has no supported semantic identity
            # relation; preserve the concrete byte effects without exclusions.
            return {'kind':'bytes','ranges':ranges(old,new)}
        # Only ncmds/sizeofcmds and command positions are structural. Every
        # command byte is represented by its complete dylib identity or a
        # command-relative effect. Signature data remains ordinary byte data.
        if last['size']>first['size']:
            with regular(old) as stream:
                stream.seek(32+first['size'])
                padding=stream.read(last['size']-first['size'])
            if len(padding)!=last['size']-first['size'] or any(padding):
                raise ValueError('load command growth consumes non-padding bytes')
        old_entries={entry['name']:entry for entry in first['entries']}
        new_entries={entry['name']:entry for entry in last['entries']}
        matched=old_entries.keys() & new_entries.keys()
        result={'kind':'macho','entries':[entry for entry in changed_entries if entry['name'] not in old_entries],
                'order':[list(key) for key in last['order']],
                'removed':[entry for entry in first['entries'] if entry['name'] not in new_entries],
                'dylibChanges':command_projection(
                    {name:[base64.b64decode(old_entries[name]['raw'])] for name in matched},
                    {name:[base64.b64decode(new_entries[name]['raw'])] for name in matched},
                    scalar_fields=(0,4,8,12,16,20)),
                'commands':command_projection(first['groups'],last['groups']),
                'ranges':ranges(old,new,[(16,24),(32,32+max(first['size'],last['size']))])}
        if old.stat().st_size!=new.stat().st_size: result['exactSize']=new.stat().st_size
        return result
    return {'kind':'bytes','ranges':ranges(old,new)}


def ranges(before,after,excluded=None):
    # Equal-sized raw edits are described by actual changed byte intervals. A
    # size-changing unknown binary requires exact whole-output preservation.
    if excluded is None and before.stat().st_size!=after.stat().st_size:
        return [{'offset':0,'count':after.stat().st_size,'exactSize':after.stat().st_size}]
    changes=[];position=0;start=None
    with regular(before) as a,regular(after) as b:
        while right:=b.read(CHUNK):
            left=a.read(len(right))
            if left == right:
                if start is not None: changes.append({'offset':start,'count':position-start});start=None
                position+=len(left);continue
            for index,new in enumerate(right):
                at=position+index
                changed=(index>=len(left) or left[index]!=new) and not any(lo<=at<hi for lo,hi in (excluded or []))
                if changed and start is None: start=at
                if not changed and start is not None:
                    changes.append({'offset':start,'count':at-start});start=None
            position+=len(right)
        if start is not None: changes.append({'offset':start,'count':position-start})
    return changes


def capture_change(before,path,store,recursive=True):
    after=capture_input(path,store,recursive)
    result={'schemaVersion':1,'operation':'change','before':before,'after':after}
    if before['kind']=='file' and after['kind']=='file':
        old,new=blob(store,before['sha256']),blob(store,after['sha256'])
        result['projection']=file_projection(old,new)
    elif after['kind']=='file': result['projection']={'kind':'materialized-file'}
    elif after['kind']=='directory' and 'children' not in after: result['projection']={'kind':'directory'}
    else: result['projection']={'kind':'state'}
    return result


def content(value):
    return {k:({n:content(c) for n,c in v.items()} if k=='children' else v) for k,v in value.items() if k not in ('mode','uid','gid')}


def capture_copy(source,path,store,before=None,recursive=True):
    source_state=capture_input(source,store,recursive) if not isinstance(source,dict) else source
    target_state=capture_input(path,store,recursive)
    # Metadata can be changed by a later explicit chmod/chown operation. Content
    # and type/link/tree equality must hold at the copy boundary.
    if content(source_state)!=content(target_state): raise ValueError('copy target differs from observed source')
    return {'schemaVersion':1,'operation':'copy','source':source_state,'before':source_state if before is None else before,'after':target_state,'projection':{'kind':'copy'}}


def lookup(value,path):
    for key in path:
        if not isinstance(value,dict) or key not in value: return False,None
        value=value[key]
    return True,value


def validate_state(value):
    if not isinstance(value,dict): raise ValueError('invalid operation state')
    kind=value.get('kind')
    fields={'missing':{'kind'},'file':{'kind','mode','uid','gid','sha256'},
            'symlink':{'kind','mode','uid','gid','link'},
            'directory':{'kind','mode','uid','gid'}}
    if not isinstance(kind,str) or kind not in fields: raise ValueError('unknown operation state')
    wanted=fields[kind]|({'children'} if kind=='directory' and 'children' in value else set())
    if set(value)!=wanted: raise ValueError('invalid operation state fields')
    if kind!='missing' and any(type(value[k]) is not int or value[k]<0 for k in ('mode','uid','gid')):
        raise ValueError('invalid operation metadata')
    if kind=='file' and (not isinstance(value['sha256'],str) or len(value['sha256'])!=64 or any(c not in '0123456789abcdef' for c in value['sha256'])):
        raise ValueError('invalid operation digest')
    if kind=='symlink' and not isinstance(value['link'],str): raise ValueError('invalid operation link')
    if 'children' in value:
        if not isinstance(value['children'],dict): raise ValueError('invalid operation children')
        for name,child in value['children'].items():
            if not isinstance(name,str) or not name or name in ('.','..') or '/' in name: raise ValueError('invalid child name')
            validate_state(child)


def validate_proof(proof):
    if not isinstance(proof,dict) or type(proof.get('schemaVersion')) is not int or proof['schemaVersion']!=1:
        raise ValueError('unknown operation proof')
    if proof.get('operation') not in ('copy','change'): raise ValueError('unknown operation')
    for field in ('before','after'): validate_state(proof.get(field))
    projected=proof.get('projection')
    if not isinstance(projected,dict): raise ValueError('missing operation projection')
    if proof['operation']=='copy':
        validate_state(proof.get('source'))
        if projected!={'kind':'copy'}: raise ValueError('unknown copy projection')
    elif proof['before']['kind']=='file' and proof['after']['kind']=='file':
        if projected.get('kind') not in ('plist','bytes','macho'): raise ValueError('unknown file projection')
    else:
        after=proof['after']
        kind='materialized-file' if after['kind']=='file' else 'directory' if after['kind']=='directory' and 'children' not in after else 'state'
        if projected!={'kind':kind}: raise ValueError('incompatible operation projection')


def verify(proofs,path,store):
    if not proofs: raise ValueError('missing operation effects')
    for proof in proofs: validate_proof(proof)
    recursive=any('children' in p['after'] for p in proofs)
    final=state(path,recursive);previous=None
    for index,proof in enumerate(proofs):
        before,after=proof['before'],proof['after']
        if previous is not None and before!=previous and not (proof['operation']=='copy' and proof.get('source')==previous): raise ValueError('operation inputs are not the preceding output')
        previous=after
        if proof['operation']=='copy':
            source=proof.get('source')
            if source is None: raise ValueError('copy source association missing')
            if content(source)!=content(after): raise ValueError('copy source association differs')
            if index!=0 and content(before)!=content(after) and source!=proofs[index-1]['after']: raise ValueError('later copy cannot replace an earlier required effect')
            if after['kind']=='file': blob(store,after['sha256'])
            continue
        kind=proof['projection']['kind']
        if before['kind']=='file' and after['kind']=='file':
            old,new=blob(store,before['sha256']),blob(store,after['sha256'])
            expected=file_projection(old,new)
            if canonical(proof['projection'])!=canonical(expected): raise ValueError('operation projection differs from preserved source/output')
        if kind=='plist':
            actual=plist(Path(path))
            if actual is None: raise ValueError('final target is not the required plist')
            for change in proof['projection']['changes']:
                found,value=lookup(actual,change['path'])
                if change.get('deleted'):
                    if found: raise ValueError('required plist deletion was reversed')
                elif not found or encode_value(value)!=change['value']: raise ValueError('required plist effect was overwritten')
        elif kind=='macho':
            layout=macho_layout(Path(path))
            if layout is None or any(entry not in layout['entries'] for entry in proof['projection']['entries']) or any(entry['name']==actual['name'] for entry in proof['projection']['removed'] for actual in layout['entries']): raise ValueError('required Mach-O loader entry missing')
            ordered=[list(key) for key in layout['order'] if list(key) in proof['projection']['order']]
            if ordered!=proof['projection']['order']: raise ValueError('required load command order differs')
            if 'exactSize' in proof['projection'] and Path(path).stat().st_size!=proof['projection']['exactSize']:
                raise ValueError('Mach-O size differs')
            verify_command_changes(proof['projection']['commands'],layout['groups'])
            verify_command_changes(proof['projection']['dylibChanges'],
                {entry['name']:[base64.b64decode(entry['raw'])] for entry in layout['entries']})
        if kind in ('bytes','macho'):
            expected=blob(store,after['sha256'])
            with regular(path) as actual,regular(expected) as wanted:
                for span in proof['projection']['ranges']:
                    offset,count=span['offset'],span['count']
                    if offset<0 or count<0 or offset+count>expected.stat().st_size: raise ValueError('invalid effect range')
                    if 'exactSize' in span and Path(path).stat().st_size!=span['exactSize']: raise ValueError('binary size differs')
                    actual.seek(offset);wanted.seek(offset)
                    while count:
                        length=min(count,CHUNK)
                        if actual.read(length)!=wanted.read(length): raise ValueError('required byte effect was overwritten')
                        count-=length
        elif kind=='plist': pass
        elif kind=='materialized-file':
            if final['kind']!='file': raise ValueError('materialized file disappeared')
            blob(store,after['sha256'])
        elif kind=='directory':
            if final['kind']!='directory': raise ValueError('required directory disappeared')
        elif kind=='state':
            prepared_replacement = proof.get('command') in ('rm','mkdir') and any(
                later['operation']=='copy' and later.get('owner')==proof.get('owner')
                for later in proofs[index+1:])
            if prepared_replacement and after['kind'] in ('missing','directory'): continue
            if final!=after: raise ValueError('required type/link/tree effect differs')
        else: raise ValueError('unsupported operation projection')
        for key in ('mode','uid','gid'):
            if before.get(key)!=after.get(key) and final.get(key)!=after.get(key): raise ValueError('required metadata effect was overwritten')
    if final!=previous: raise ValueError('final output has unrecorded changes')


def verify_rows(plan,rows,roots,store):
    """Read explicit final roots; recorded temporary paths never select targets."""
    from . import plan_gate as gate
    grouped={}
    for row in rows:
        if row.get('schemaVersion')!=1 or row.get('planDigest')!=plan.record['planSHA256'] or row.get('desiredSHA256')!=plan.raw_sha256 or row.get('generationID')!=plan.record['generationID']:
            raise ValueError('operation evidence differs from qualified plan')
        gate.authorize(plan,row['declarationID'],row['target'])
        proof=row.get('effect')
        if proof is None: raise ValueError('legacy operation has no final effect proof')
        validate_proof(proof)
        # A2 supplies the explicit transport/consumption graph. Capturing these
        # rows remains enabled, but a partial validator cannot accept them.
        if proof.get('command') in ('mv','rm','tar','gtar'):
            raise ValueError('final transport/consumption proof is not integrated')
        for field in ('before','after'):
            observed=proof[field]
            if observed['kind']=='file':
                recorded=observed['sha256']
                if row.get(field+'Metadata')!={k:observed[k] for k in ('mode','uid','gid')}:
                    raise ValueError('operation metadata differs from row')
            else:
                encoded={'state':'missing'} if observed['kind']=='missing' else observed
                recorded=hashlib.sha256(canonical(encoded)).hexdigest()
            if row.get(field+'SHA256')!=recorded: raise ValueError('operation bytes differ from row')
        target=row['target'];volume,relative=target.split(':',1)
        if volume not in roots or not relative.startswith('/') or '..' in Path(relative).parts:
            raise ValueError('operation has no qualified final target root')
        root=Path(roots[volume]);path=root/relative.lstrip('/')
        parent=path.parent
        while parent!=root:
            if parent.is_symlink() or not parent.is_dir(): raise ValueError('linked final target parent')
            parent=parent.parent
        grouped.setdefault(target,[]).append((row,path))
    if not grouped: raise ValueError('missing operation evidence')
    for entries in grouped.values():
        verify([dict(row['effect'],owner=row['declarationID']) for row,_ in entries],entries[0][1],store)
