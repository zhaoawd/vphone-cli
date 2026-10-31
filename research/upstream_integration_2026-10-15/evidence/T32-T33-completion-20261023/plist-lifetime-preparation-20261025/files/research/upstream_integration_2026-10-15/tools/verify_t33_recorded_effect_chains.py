"""Verify saved byte/signature chains under the private-path chronology model.

The existing verifier's _final_state parameter is used as it is for preserved
signing-boundary blobs: ownership metadata comes from the historical record,
while data, projections and signatures are checked against preserved bytes.
This is not a new readback of guest filesystem metadata or the failed disk.
"""
import copy
import hashlib
import json
from pathlib import Path
import sys
from types import SimpleNamespace

import analyze_t33_transport_chronology as analysis

ROOT=analysis.ROOT
sys.path.insert(0,str(ROOT/'scripts'))
from patchers import component_effects as effects


def main():
    base=ROOT/'.build/t32-t33-completion-20261023'
    work=base/'exp-bootstrap-acceptance-20261025'
    history=ROOT/'.build/t33t-20261025/.cfw-history/20261025T114952Z-zhZ5OOCf'
    output=base/'recorded-effect-chains-20261025.json'
    if output.exists():raise ValueError('Preserve existing recorded-chain analysis')
    modeled=json.loads((base/'transport-chronology-analysis-20261025.json').read_bytes())
    journal=history/'guest-changes.jsonl'
    if analysis.digest(journal)!=modeled['originalJournalSHA256']:
        raise ValueError('Historical journal changed')
    rows=[json.loads(line) for line in journal.read_text().splitlines()]
    for index in modeled['changedRows']:
        rows[index]=analysis.renamed(rows[index],modeled['oldPrivatePath'],modeled['newPrivatePath'])
    native=json.loads((work/'execution/exp/verify-plan.log').read_bytes())['record']
    plan=SimpleNamespace(context=dict(vmDirectory=str(history.parents[1]),generationID=native['generationID']),
                         record=dict(planSHA256=native['planSHA256']))
    store=history/'effect-blobs';graph=analysis.graph_verifier()(rows,{},store,plan)
    checked=[];failures=[];copy_only=0
    for path,node in graph['nodes'].items():
        if node['target'] is None or not node['history']:continue
        proofs=[proof for _,proof in node['history']]
        if all(proof['operation']=='copy' for proof in proofs):
            copy_only+=1;continue
        state=node['after']
        try:
            if state['kind']=='file':
                carrier=effects.blob(store,state['sha256'])
            else:
                # These chains validate recorded type/link/metadata relations.
                # No filesystem existence claim is made for this placeholder.
                carrier=base/'unused-recorded-state-carrier'
            effects.verify(proofs,carrier,store,_final_state=state)
            checked.append(dict(target=node['target'],kind=state['kind'],proofs=len(proofs),
                                byteCarrierSHA256=state.get('sha256')))
        except Exception as error:
            failures.append(dict(target=node['target'],kind=state['kind'],error=str(error),
                                 rowIndices=sorted({key[0] for key,_ in node['history']})))
    if analysis.digest(journal)!=modeled['originalJournalSHA256']:
        raise ValueError('Historical journal changed during verification')
    result=dict(scope='historical byte/signature proof chains and recorded metadata only',
        originalJournalSHA256=modeled['originalJournalSHA256'],originalJournalPreserved=True,
        pathOnlyCounterfactual=True,checked=checked,failures=failures,
        checkedChains=len(checked),failedChains=len(failures),copyOnlyFinalTargets=copy_only,
        finalDiskReadPerformed=False,guestMetadataReadbackPerformed=False,
        accepted=False,runtimeValidated=False,VMStarts=0,CFWWrites=0)
    with output.open('x') as stream:json.dump(result,stream,indent=2);stream.write('\n')
    print(json.dumps({key:value for key,value in result.items() if key not in ('checked',)}),flush=True)
    return 1 if failures else 0


if __name__=='__main__':raise SystemExit(main())
