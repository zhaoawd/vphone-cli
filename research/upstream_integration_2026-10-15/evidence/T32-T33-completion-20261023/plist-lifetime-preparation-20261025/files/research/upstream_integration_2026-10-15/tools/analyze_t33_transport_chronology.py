"""Analyze historical transport relationships, with an explicit path-only model.

Original evidence is immutable. The counterfactual copy changes only the EXP
private plist path after its new lifetime starts. No before/after state changes.
This tool stops the real verifier before filesystem readback and cannot produce
deployment, signature-readback, or runtime acceptance evidence.
"""
import ast
import copy
import hashlib
import inspect
import json
from pathlib import Path
import sys
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT/'scripts'))
from patchers import component_transport as transport


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream,'sha256').hexdigest()


def graph_verifier():
    # Preserve every chronological predicate in the production verifier. Return
    # the graph where its separate physical-filesystem readback would begin.
    tree = ast.parse(inspect.getsource(transport.verify))
    function = tree.body[0]
    stops = [index for index,node in enumerate(function.body) if isinstance(node,ast.Assign)
             and len(node.targets)==1 and isinstance(node.targets[0],ast.Name) and node.targets[0].id=='outputs']
    if len(stops)!=1:
        raise ValueError('Unexpected verifier structure; no diagnostic rewrite')
    result=ast.parse('return dict(nodes=nodes,required=required,covered=covered,archive_deletions=archive_deletions)').body[0]
    function.body = function.body[:stops[0]]+[result]
    ast.fix_missing_locations(tree)
    namespace=dict(transport.__dict__)
    exec(compile(tree,'<diagnostic transport graph only>','exec'),namespace)
    return namespace['verify']


def renamed(value, old, new):
    if isinstance(value,str): return new if value==old else value
    if isinstance(value,list): return [renamed(item,old,new) for item in value]
    if isinstance(value,dict): return {key:renamed(item,old,new) for key,item in value.items()}
    return value


def main():
    work=ROOT/'.build/t32-t33-completion-20261023/exp-bootstrap-acceptance-20261025'
    history=ROOT/'.build/t33t-20261025/.cfw-history/20261025T114952Z-zhZ5OOCf'
    output=ROOT/'.build/t32-t33-completion-20261023/transport-chronology-analysis-20261025.json'
    if output.exists(): raise ValueError('Preserve existing analysis')
    verifier_path=Path(transport.__file__).resolve()
    frozen=json.loads((work/'executor-inputs.json').read_bytes())['files']
    if digest(verifier_path)!=frozen[str(verifier_path)]:
        raise ValueError('Production verifier differs from failed execution')
    journal=history/'guest-changes.jsonl'; original_sha=digest(journal)
    rows=[json.loads(line) for line in journal.read_text().splitlines()]
    native=json.loads((work/'execution/exp/verify-plan.log').read_bytes())['record']
    plan=SimpleNamespace(context=dict(vmDirectory=str(history.parents[1]),generationID=native['generationID']),
                         record=dict(planSHA256=native['planSHA256']))
    scan=json.loads((ROOT/'.build/t32-t33-completion-20261023/transport-continuity-scan-20261025.json').read_bytes())
    issue,=scan['inputContinuityMismatches']; start=issue['index']; old=issue['path']
    if old!=str(history.parents[1]/'.cfw_temp/launchd.plist'):
        raise ValueError('Unexpected historical mismatch')
    new=str(Path(old).with_name('jb_launchd.plist'))
    verify=graph_verifier();store=history/'effect-blobs'
    try: verify(rows,{},store,plan)
    except ValueError as error:
        if str(error)!='transport input differs from preceding observed output':raise
    else: raise ValueError('Original chronological failure did not reproduce')
    modeled=copy.deepcopy(rows)
    for index in range(start,len(modeled)):modeled[index]=renamed(modeled[index],old,new)
    changed=[index for index,(left,right) in enumerate(zip(rows,modeled)) if left!=right]
    for left,right in zip(rows,modeled):
        if left['effect']['before']!=right['effect']['before'] or left['effect']['after']!=right['effect']['after']:
            raise ValueError('Counterfactual changed an observed state')
    graph=verify(modeled,{},store,plan)
    covered=set(graph['covered'])
    for node in graph['nodes'].values():
        if node['target'] is not None:covered.update(key for key,_ in node['history'])
    for archive_history,extractions in graph['archive_deletions']:
        if not extractions.issubset({index for index,_ in covered}):
            raise ValueError('Modeled extraction history has no final transport')
        covered.update(key for key,_ in archive_history)
    if graph['required']-covered:
        raise ValueError('Modeled required producer has no final transport')
    if digest(journal)!=original_sha:raise ValueError('Original evidence changed')
    result=dict(scope='counterfactual private-path chronology and required-producer coverage only',
        historicalRows=len(rows),originalFailureReproduced=True,modeledChronologyChecksPassed=True,
        modeledRequiredProducerCoverageComplete=True,changedRows=changed,
        oldPrivatePath=old,newPrivatePath=new,observedBeforeAfterStatesUnchanged=True,
        modeledFinalTargets=sum(node['target'] is not None for node in graph['nodes'].values()),
        originalJournalSHA256=original_sha,originalJournalPreserved=True,verifierSHA256=digest(verifier_path),
        finalDiskReadPerformed=False,signatureReadbackPerformed=False,accepted=False,
        VMStarts=0,CFWWrites=0)
    with output.open('x') as stream:json.dump(result,stream,indent=2);stream.write('\n')
    print(json.dumps(result),flush=True)


if __name__=='__main__':main()
