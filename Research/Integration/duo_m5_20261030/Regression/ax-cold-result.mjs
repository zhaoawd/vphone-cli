import fs from 'node:fs';
import assert from 'node:assert/strict';
const [warm,cold]=process.argv.slice(2);
const read=(dir,file)=>JSON.parse(fs.readFileSync(dir+'/'+file));
const before=read(warm,'device.json'),after=read(cold,'device.json');
assert.notEqual(after.boot_session_uuid,before.boot_session_uuid,'A worker restart is not a cold boot');
assert.equal(fs.readFileSync(warm+'/vm-exit-code.txt','utf8').trim(),'0');
assert.equal(fs.statSync(cold+'/handles-before.txt').size,0);
assert.equal(after.agent.binary_hash,'a4860c0c5b0b630155228d2d53183831b73c69099a8cd4b3e0909c92711a0a6f');
const visible=read(cold,'ax-visible/summary.json'),touch=read(cold,'ax-touch/summary.json');
assert.deepEqual(visible.visibleCounts,[9,9,9]);assert.deepEqual(visible.unfilteredCounts,[9,9,9]);
assert.equal(touch.hostTaps,6);assert.equal(touch.appReceipts,6);
const context=JSON.parse(fs.readFileSync(cold+'/ax-context.log','utf8').trim());
assert.equal(context.hits,15);assert.equal(context.failures,0);assert.equal(context.lockedRejected,true);
const report={passed:true,beforeBootUUID:before.boot_session_uuid,coldBootUUID:after.boot_session_uuid,
    agent:after.agent.binary_hash,visibleCounts:visible.visibleCounts,nativeAXTouchReceipts:6,contextHits:15,lockedRejected:true};
fs.writeFileSync(cold+'/ax-cold-acceptance.json',JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify(report));
