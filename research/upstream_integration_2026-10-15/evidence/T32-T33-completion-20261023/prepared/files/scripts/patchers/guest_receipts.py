"""Component receipts derived from sealed actual guest effects, never selection."""
from . import plan_gate as gate
from . import component_transport as transport

FILENAME='guest-install-receipts.json'


def build(record,final,rows,image_sha256):
    if (not rows or not final.get('outputs') or final.get('transactionID')!=record['id']
            or not gate.DIGEST.fullmatch(image_sha256)):
        raise ValueError('Guest receipt has no qualified publication effects')
    qualification={key:final[key] for key in ('generationID','planDigest','desiredSHA256')}
    grouped={};by_digest={};removals={}
    for row in rows:
        if any(row.get(key)!=value for key,value in qualification.items()):
            raise ValueError('Guest receipt operation qualification differs')
        identifier=row['declarationID'];digest=gate.sha(gate.canonical(row))
        if digest in by_digest:raise ValueError('Guest receipt contains duplicate operation evidence')
        by_digest[digest]=identifier
        grouped.setdefault(identifier,[]).append((digest,row))
        if row['effect'].get('command') in ('rm','mv'):
            for member in transport.expanded(row):
                if member['effect']['after']=={'kind':'missing'}:
                    removals.setdefault(member['target'],set()).add(identifier)
    outputs=final['outputs']
    if len({row['target'] for row in outputs})!=len(outputs):raise ValueError('Guest receipt outputs are duplicated')
    targets={identifier:[] for identifier in grouped}
    for output in outputs:
        if (not isinstance(output.get('state'),dict) or not isinstance(output.get('effects'),list)
                or len(set(output['effects']))!=len(output['effects'])
                or any(digest not in by_digest for digest in output['effects'])):
            raise ValueError('Guest receipt output lacks exact producer association')
        owners={by_digest[digest] for digest in output['effects']}
        if not owners:
            if output['state']!={'kind':'missing'} or output['target'] not in removals:
                raise ValueError('Guest receipt output lacks exact producer association')
            owners=removals[output['target']]
        for identifier in owners:
            targets[identifier].append(output['target'])
    declarations=[]
    for identifier,operations in sorted(grouped.items()):
        changed=any(row['effect']['before']!=row['effect']['after'] for _,row in operations)
        state=('verified-effect' if changed else 'verified-noop') if targets[identifier] else 'observed-consumed'
        declarations.append(dict(declarationID=identifier,state=state,
            operationSHA256s=[digest for digest,_ in operations],targets=sorted(targets[identifier])))
    return dict(schemaVersion=1,component='Guest',scope='installed-component-effects',state='committed',
                transactionID=record['id'],**qualification,imageSHA256=image_sha256,
                declarations=declarations,outputs=outputs,originQualified=False,runtimeValidated=False,
                activation='unknown',acceptance='unknown')
