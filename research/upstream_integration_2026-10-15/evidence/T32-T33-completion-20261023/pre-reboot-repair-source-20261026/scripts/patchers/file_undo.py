"""Qualified file chains from original bytes through staging, signing and copies."""
from . import component_effects as effects,component_signatures as signatures
from . import component_transport as transport,plan_gate as gate,file_originals


def build(plan,rows,outputs,store,catalog):
    if catalog is None:return []
    entries=[]
    for target,original in sorted(catalog['members'].items()):
        final=[item for item in outputs if item['target']==target]
        if not final:continue
        if len(final)!=1 or final[0]['state'].get('kind')!='file':
            raise ValueError('File Undo target has no unique regular final output')
        baseline=original['state'];nodes={}
        for row in rows:
            digest=gate.sha(gate.canonical(row))
            for member in transport.expanded(row):
                if member['target'] not in (target,target+'.bak'):continue
                proof=member['effect'];before,after=proof['before'],proof['after'];path=member['path']
                if after.get('kind')!='file':nodes.pop(path,None);continue
                previous=nodes.get(path)
                if previous is not None and previous['state']!=before:
                    raise ValueError('File Undo path chain is incomplete')
                operation=proof['operation']
                if operation=='copy':
                    source=proof.get('source');parent=nodes.get(proof.get('sourcePath'))
                    if parent is not None:
                        if parent['state']!=source:raise ValueError('File Undo copy source was substituted')
                        node=dict(parent,operations=list(parent['operations']))
                    elif source is not None and effects.content(source)==effects.content(baseline):
                        node=dict(state=source,operations=[])
                    else:
                        nodes.pop(path,None);continue
                    if effects.content(source)!=effects.content(after):raise ValueError('File Undo copy bytes differ')
                    # Copies transport the qualified chain. Destination state
                    # before a replacement is not promoted to the first original.
                    node.update(state=after,target=member['target'],phase=row.get('phase'))
                    nodes[path]=node;continue
                if previous is None:
                    if effects.content(before)!=effects.content(baseline):continue
                    previous=dict(state=before,operations=[])
                node=dict(previous,operations=list(previous['operations']))
                if operation not in ('change','sign'):raise ValueError('Unsupported file Undo operation')
                if before!=after:
                    stamp=proof.get('implementation')
                    if operation=='sign':
                        signatures.verify_signing(effects.blob(store,before['sha256']),effects.blob(store,after['sha256']))
                        stamp=dict(kind='verified-signature-transition')
                    elif proof.get('command') in ('chmod','chown'):
                        if before['sha256']!=after['sha256']:raise ValueError('Metadata operation changes file bytes')
                        stamp=dict(kind='observed-metadata-transition')
                    elif (not isinstance(stamp,dict) or set(stamp)!={'schemaVersion','kind','sha256'}
                          or stamp.get('schemaVersion')!=1 or stamp.get('kind')!='python-patchers-source'
                          or not gate.DIGEST.fullmatch(stamp.get('sha256',''))):
                        raise ValueError('File Undo patch has no implementation fingerprint')
                    node['operations'].append(dict(declarationID=row['declarationID'],rowSHA256=digest,
                        implementation=stamp,beforeSHA256=before['sha256'],afterSHA256=after['sha256'],
                        beforeState=before,afterState=after,
                        ranges=effects.ranges(effects.blob(store,before['sha256']),effects.blob(store,after['sha256']))))
                node.update(state=after,target=member['target'],phase=row.get('phase'));nodes[path]=node
        candidates=[node for node in nodes.values() if node['target']==target and node['phase']!='staging'
                    and node['state']==final[0]['state'] and node['operations']]
        if not candidates:continue
        if len(candidates)!=1:raise ValueError('File Undo final chain is ambiguous')
        node=candidates[0];current=effects.blob(store,node['state']['sha256'])
        file_originals.code_pages(current,original['kind'])
        original_blob=effects.blob(store,baseline['sha256'])
        history={operation['rowSHA256'] for operation in node['operations']}
        if not history.issubset(set(final[0]['effects'])):raise ValueError('File Undo operations lack final transport coverage')
        covered=[]
        # The qualified transport already proves which operations survived in
        # this exact target. Complete declaration checks still reject other
        # targets changed by any selected declaration.
        for row in rows:
            digest=gate.sha(gate.canonical(row))
            if digest in final[0]['effects']:
                covered.extend(dict(rowSHA256=digest,target=member['target']) for member in transport.expanded(row)
                               if member['target'] in (target,target+'.bak'))
        auxiliary=[]
        backups=[item for item in outputs if item['target']==target+'.bak']
        if backups and len(backups)==1 and effects.content(backups[0]['state'])==effects.content(baseline):
            auxiliary=backups
            for row in rows:
                digest=gate.sha(gate.canonical(row))
                if digest in backups[0]['effects']:
                    covered.extend(dict(rowSHA256=digest,target=member['target']) for member in transport.expanded(row)
                                   if member['target']==target+'.bak')
        entries.append(dict(target=target,kind=original['kind'],originalSHA256=baseline['sha256'],
            originalState=baseline,finalSHA256=node['state']['sha256'],finalState=node['state'],
            size=original_blob.stat().st_size,finalSize=current.stat().st_size,
            operations=node['operations'],coveredEffects=covered,auxiliaryOutputs=auxiliary))
    return entries
