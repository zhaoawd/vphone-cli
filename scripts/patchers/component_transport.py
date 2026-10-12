"""Compose observed member transfers without granting paths target authority.

The caller qualifies every original row. Tree members below a qualified whole-
tree copy are derived from that observed tree, never from a path-prefix owner.
"""
import hashlib
import json
from pathlib import Path
import tarfile

from . import component_effects as effects
from . import guest_write


def final_path(target, roots):
    volume,relative=target.split(':',1)
    if volume not in roots or not relative.startswith('/') or '..' in Path(relative).parts:
        raise ValueError('operation has no qualified final target root')
    root=Path(roots[volume]);path=root/relative.lstrip('/')
    if root.is_symlink() or not root.is_dir(): raise ValueError('invalid final root')
    current=path.parent
    while current!=root:
        if current.is_symlink(): raise ValueError('linked final target parent')
        current=current.parent
    return path


def shallow(value):
    return {key:value for key,value in value.items() if key!='children'}


def members(value, prefix=''):
    yield prefix,shallow(value)
    for name,child in value.get('children',{}).items():
        yield from members(child, prefix+'/'+name if prefix else name)


def child(value, relative):
    for name in relative.split('/') if relative else []:
        value=value.get('children',{}).get(name,{'kind':'missing'})
    return shallow(value)


def expanded(row):
    proof=row['effect']
    if proof['operation']=='change' and any('children' in proof[key] for key in ('before','after')):
        if proof.get('command') not in ('rm','mkdir','chmod','chown'):
            raise ValueError('unknown recursive tree change')
        before_members=dict(members(proof['before']));after_members=dict(members(proof['after']))
        for relative in sorted(before_members.keys()|after_members.keys()):
            before=before_members.get(relative,{'kind':'missing'});after=after_members.get(relative,{'kind':'missing'})
            if relative and before==after: continue
            kind='directory' if after['kind']=='directory' else 'state'
            if before['kind']=='file' and after['kind']=='file':
                if before['sha256']!=after['sha256']: raise ValueError('metadata operation changes file bytes')
                kind='bytes'
            projection={'kind':kind,'ranges':[]} if kind=='bytes' else {'kind':kind}
            yield dict(row,path=str(Path(row['path'])/relative),
                       target=row['target'].rstrip('/')+('/'+relative if relative else ''),
                       effect=dict(proof,before=before,after=after,projection=projection))
        return
    if proof['operation']!='copy' or 'children' not in proof['after']:
        yield row
        return
    if effects.content(proof['source'])!=effects.content(proof['after']):
        raise ValueError('tree copy differs from actual source members')
    if not proof.get('sourcePath'): raise ValueError('tree copy source association missing')
    for relative,after in members(proof['after']):
        source=child(proof['source'],relative)
        evidence=dict(proof,source=source,before=child(proof['before'],relative),after=after,
                      sourcePath=str(Path(proof['sourcePath'])/relative))
        yield dict(row,path=str(Path(row['path'])/relative),
                   target=row['target'].rstrip('/')+('/'+relative if relative else ''),effect=evidence)


def archive_groups(rows,store,table):
    """Re-read preserved archive bytes and require its complete extraction rows."""
    groups={}
    for index,row in enumerate(rows):
        proof=row['effect']
        if proof.get('command') not in ('tar','gtar'): continue
        association=proof.get('sourceArchive')
        if not isinstance(association,dict) or not proof.get('operationID'):
            raise ValueError('archive extraction lacks source/operation association')
        groups.setdefault(proof['operationID'],[]).append((index,row))
    consumed={}
    for group in groups.values():
        association=group[0][1]['effect']['sourceArchive']
        name=association['archiveName'];expected=table['archives'].get(name)
        if expected is None: raise ValueError('unknown archive proof')
        archive=effects.blob(store,association['archiveSHA256'])
        observations={r['effect']['sourceArchive']['member']:(i,r) for i,r in group}
        if len(observations)!=len(group) or set(observations)!=set(expected):
            raise ValueError('archive extraction has missing or repeated members')
        seen=set()
        with tarfile.open(archive) as stream:
            for member in stream:
                member_name=str(Path(member.name))
                if member_name=='.': continue
                if member_name in seen or expected.get(member_name)!={'type':member.type.decode(),'link':member.linkname}:
                    raise ValueError('archive source member table differs')
                seen.add(member_name)
                index,row=observations[member_name];proof=row['effect']
                if proof['sourceArchive']!=dict(association,member=member_name):
                    raise ValueError('archive member source substituted')
                target=association['destination'].rstrip('/')+'/'+member_name
                if row['target']!=target: raise ValueError('archive member target substituted')
                source=proof.get('source')
                if source is None or any(source.get(k)!=getattr(member,k) for k in ('mode','uid','gid')):
                    raise ValueError('archive member metadata differs')
                if member.isfile():
                    h=hashlib.sha256()
                    with stream.extractfile(member) as data:
                        while block:=data.read(effects.CHUNK): h.update(block)
                    wanted={'kind':'file','sha256':h.hexdigest()}
                elif member.isdir(): wanted={'kind':'directory'}
                elif member.issym(): wanted={'kind':'symlink','link':member.linkname}
                else: raise ValueError('unsupported archive member')
                if effects.content(source)!=wanted or effects.content(proof['after'])!=wanted:
                    raise ValueError('archive member bytes/type/link differ')
        if seen!=set(expected): raise ValueError('preserved archive misses required member')
        key=(association['archivePath'],association['archiveSHA256'])
        if key in consumed: raise ValueError('ambiguous repeated archive consumption')
        consumed[key]={index for index,_ in group}
    return consumed


def image_bindings(rows,store,plan):
    """Resolve immutable image observations and exact producer-row transitions."""
    resolved={}
    for row in rows:
        if row.get('sourceImage') is None: continue
        proof=row.get('sourceImageProof')
        if not isinstance(proof,dict) or set(proof)!={'bindingSHA256','image'}:
            raise ValueError('image source has no observed binding')
        binding=json.loads(effects.blob(store,proof['bindingSHA256']).read_bytes())
        original=Path(binding['source'])
        original_root=Path(plan.context['vmDirectory'])/'.firmware-generations'/plan.context['generationID']/'originals'
        if (binding.get('planDigest')!=plan.record['planSHA256'] or binding.get('generationID')!=plan.context['generationID'] or
            original_root not in original.parents or '..' in original.parts):
            raise ValueError('image source binding differs from frozen generation')
        observed=proof['image']
        if row['target'].startswith('dsc:'):
            initial=binding.get('imageBefore')
            if initial is None or any(initial[k]!=observed[k] for k in ('device','inode')) or binding.get('transition'):
                raise ValueError('DSC image producer has no original image identity')
        else:
            if observed['sha256']!=binding['cacheSHA256']:
                raise ValueError('copied image digest differs from recorded binding')
            transition=binding.get('transition')
            producers=[candidate for candidate in rows if candidate.get('sourceImage')==row['sourceImage'] and candidate['target'].startswith('dsc:')]
            if producers:
                if not transition or observed!=transition['after'] or transition['before']!=binding['imageBefore']:
                    raise ValueError('copied transformed image has no final identity/digest')
                if any(transition['before'][k]!=transition['after'][k] for k in ('device','inode')):
                    raise ValueError('transformed image identity changed')
                if transition['rows']!=[hashlib.sha256(effects.canonical(r)).hexdigest() for r in producers]:
                    raise ValueError('image transition substitutes producer rows')
                if any(r['sourceImageProof']['bindingSHA256']!=transition['baselineBinding'] for r in producers):
                    raise ValueError('image transition substitutes original image binding')
                baseline=json.loads(effects.blob(store,transition['baselineBinding']).read_bytes())
                if {k:v for k,v in binding.items() if k not in ('transition','transformation','cacheSHA256')}!={k:v for k,v in baseline.items() if k!='cacheSHA256'}:
                    raise ValueError('image transition changes original binding')
        resolved[id(row)]=binding
    return resolved


def verify(rows,roots,store,plan):
    table=guest_write.target_table()[0]
    image_bindings(rows,store,plan)
    consumed=archive_groups(rows,store,table)
    allowed_moves={tuple(pair) for pair in table['moves']}
    nodes={};required=set();covered=set();deletions={};archive_deletions=[]
    transfers={}
    for index,original in enumerate(rows):
        for row in expanded(original):
            proof=row['effect'];path=row['path'];target=row['target']
            identifier=(index,path)
            before,after=proof['before'],proof['after']
            previous=nodes.get(path)
            command=proof.get('command')
            if command not in (None,'cp','mv','rm','mkdir','chmod','chown','ln','find','tar','gtar'):
                raise ValueError('unknown producer transport operation')
            if previous is not None and previous['after']!=before:
                raise ValueError('transport input differs from preceding observed output')
            if after['kind']=='missing':
                destination=proof.get('transportTarget')
                if destination is not None:
                    key=(proof.get('operationID'),path,destination)
                    if key not in transfers or transfers[key]!=before:
                        raise ValueError('move has no exact observed destination')
                elif previous is not None:
                    archive_key=(path,before.get('sha256'))
                    if archive_key in consumed:
                        archive_deletions.append((previous['history'],consumed[archive_key]))
                    elif before['kind']=='directory' and guest_write.normalized(target) in table['consumedDirectories']:
                        if any(Path(path) in Path(other).parents and node['after']['kind']!='missing' for other,node in nodes.items()):
                            raise ValueError('consumed container still has required members')
                        covered.update(key for key,_ in previous['history'])
                    # Other removed prior effects remain required and uncovered.
                nodes[path]={'after':after,'history':[],'target':target}
                deletions[path]=(target,row['declarationID'])
                continue
            history=[] if previous is None else list(previous['history'])
            if proof['operation']=='copy':
                source_path=proof.get('sourcePath');source=proof['source']
                if effects.content(source)!=effects.content(after): raise ValueError('transport source differs from output')
                source_node=nodes.get(source_path)
                image=row.get('sourceImage')
                if image is not None:
                    tree_rule=table['treeTargets'].get(original['target'])
                    expected_image=None if tree_rule is None else str(Path(plan.context['vmDirectory'])/'.cfw_temp'/tree_rule['image'])
                    if image!=expected_image:
                        raise ValueError('tree copy image association differs')
                    member_prefix='system:/System/Cryptexes/OS/System/Library/Caches/com.apple.dyld/'
                    if target.startswith(member_prefix):
                        member=target.removeprefix(member_prefix)
                        matches=[node for node in nodes.values() if node.get('sourceImage')==image
                                 and node['target']=='dsc:/'+member]
                        if len(matches)>1: raise ValueError('ambiguous Cryptex image member producer')
                        if matches:
                            if source_node is not None and source_node is not matches[0]:
                                raise ValueError('ambiguous source path/image member relation')
                            source_node=matches[0]
                if previous is not None and effects.content(previous['after'])!=effects.content(after):
                    source_history=set() if source_node is None else {key for key,_ in source_node['history']}
                    if not {key for key,_ in previous['history']}.issubset(source_history):
                        raise ValueError('unrelated copy overwrites an earlier required effect')
                if source_node is not None:
                    if source_node['after']!=source: raise ValueError('copy source substituted after producer')
                    history+=source_node['history']
                    if proof.get('sourceTarget') is None:
                        source_node['target']=None
                if command=='mv':
                    source_target=proof.get('sourceTarget')
                    pair=(guest_write.normalized(source_target),guest_write.normalized(target)) if source_target else None
                    hardware=source_target is not None and guest_write.normalized(source_target)=='hardware:/<gigalocker>.gl' and target=='hardware:/AA.gl'
                    if pair not in allowed_moves and not hardware: raise ValueError('undeclared move relationship')
                    if not proof.get('operationID') or source_path is None: raise ValueError('move operation identity missing')
                    transfers[(proof['operationID'],source_path,target)]=source
            if path in deletions:
                if deletions[path][1]!=row['declarationID']: raise ValueError('replacement has a different declaration owner')
                deletions.pop(path)
            history.append((identifier,proof));history=sorted(dict(history).items(),key=lambda item:item[0][0])
            required.add(identifier)
            final_target=target if row.get('phase')!='staging' else None
            nodes[path]={'after':after,'history':history,'target':final_target,'sourceImage':row.get('sourceImage')}
    outputs=[]
    for path,node in nodes.items():
        if node['target'] is None: continue
        final=final_path(node['target'],roots)
        actual=effects.state(final,False)
        if actual!=node['after']: raise ValueError('final transported member differs from recorded output')
        if node['history']:
            proofs=[proof for _,proof in node['history']]
            # Copy-only leaves need no duplicated content blob: both observed
            # source and output digest/type/link already agree, as does readback.
            if any(proof['operation']!='copy' for proof in proofs):
                effects.verify(proofs,final,store)
            covered.update(key for key,_ in node['history'])
        outputs.append({'target':node['target'],'state':actual,
                        'effects':sorted({hashlib.sha256(effects.canonical(rows[index])).hexdigest() for (index,_),_proof in node['history']})})
    for history,extractions in archive_deletions:
        if not extractions.issubset({index for index,_ in covered}):
            raise ValueError('archive consumed before required extraction effects survived')
        covered.update(key for key,_ in history)
    if required-covered: raise ValueError('required producer member has no surviving final transport')
    return sorted(outputs,key=lambda output:output['target'])
