// Compare receipt outcomes; runtime/file checks remain independent evidence.
import fs from 'node:fs';
import assert from 'node:assert/strict';
const [beforeFile,afterFile,outputFile]=process.argv.slice(2);
const before=JSON.parse(fs.readFileSync(beforeFile)),after=JSON.parse(fs.readFileSync(afterFile));
assert.equal(before.vmName,'duo-overall-20261116');assert.equal(after.vmName,before.vmName);
const pending=before.patches.filter(p=>p.pending&&p.delivery==='update-environment');
assert.equal(pending.length,9);
const results=pending.map(p=>{
    const actual=after.patches.find(x=>x.identifier===p.identifier);assert(actual,p.identifier);
    assert.equal(actual.enabled,true,p.identifier);assert.equal(actual.applied,true,p.identifier);
    assert.equal(actual.pending,false,p.identifier);
    return {identifier:actual.identifier,enabled:actual.enabled,planned:actual.planned,applied:actual.applied,pending:actual.pending};
});
assert.equal(after.patches.filter(p=>p.pending&&p.delivery==='update-environment').length,0);
for(const prior of before.patches.filter(p=>p.part!=='Guest')){
    const actual=after.patches.find(p=>p.identifier===prior.identifier);assert(actual,prior.identifier);
    for(const key of ['enabled','planned','applied','pending'])assert.equal(actual[key],prior[key],prior.identifier+': '+key);
}
assert.equal(after.patches.find(p=>p.identifier==='txm-cfw-executable_remap').applied,true);
assert.equal(after.patches.find(p=>p.identifier==='txm-exp-precheck_admission').applied,false);
const report={results,remainingPending:after.patches.filter(p=>p.pending).map(p=>({identifier:p.identifier,delivery:p.delivery})),nonGuestReceiptUnchanged:true};
fs.writeFileSync(outputFile,JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify(report));
