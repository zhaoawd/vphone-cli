import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import net from 'node:net';
import {fileURLToPath} from 'node:url';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {setTimeout as sleep} from 'node:timers/promises';

export function validateResult(catalog,method,result) {
    const fields=catalog.methods.find(row=>row.name===method)?.result;
    assert(Array.isArray(fields),'Declared result required for '+method);
    const byName=new Map(fields.map(field=>[field.name,field]));
    for(const key of Object.keys(result)) assert(byName.has(key),method+': undeclared result '+key);
    for(const field of fields) {
        if(!(field.name in result)) { assert(!field.required,method+': missing '+field.name);continue; }
        const value=result[field.name];
        if(value===null) {assert(field.nullable||field.type==='null',method+': unexpected null '+field.name);continue;}
        const valid=field.type==='any'||(field.type==='array'?Array.isArray(value):field.type==='integer'?Number.isInteger(value):field.type==='number'?typeof value==='number'&&Number.isFinite(value):field.type==='object'?typeof value==='object'&&!Array.isArray(value):typeof value===field.type);
        assert(valid,method+': wrong type '+field.name);
    }
}

// Called only by the pinned isolated runtime driver after a cold boot.
export default async function verify({rpc,save,out,socket,candidateHash}) {
    const root=fileURLToPath(new URL('../../../../',import.meta.url));
    const catalog=await rpc('methods.list'); save('method-catalog.json',catalog);
    assert.equal(catalog.complete,true); assert.equal(catalog.scope,'guest');
    assert.equal(catalog.methods.length,195);
    const names=catalog.methods.map(m=>m.name);
    assert.equal(new Set(names).size,names.length);
    const methods=new Map(catalog.methods.map(m=>[m.name,m]));
    let checks=4;
    for(const method of catalog.methods) {
        assert.equal(typeof method.description,'string'); assert(method.description.length>0);
        assert(Array.isArray(method.params)); assert(Array.isArray(method.result));
        for(const field of [...method.params,...method.result]) {
            assert.equal(typeof field.name,'string'); assert.equal(typeof field.required,'boolean');
            assert(['string','integer','number','boolean','array','object','any','null'].includes(field.type));
        }
        checks++;
    }
    assert(!methods.has('location.services')); checks++;
    const setter=methods.get('display.auto_lock.set');
    assert(setter.params.some(p=>p.name==='never'&&p.type==='boolean'));
    assert(setter.params.some(p=>p.name==='seconds'&&p.required===false)); checks+=2;
    for(const name of ['display.layout','display.metrics','display.capture_active','ui.element_at','ui.tap_element']) {
        assert(methods.has(name)); checks++;
    }
    const raw=(method,params={})=>new Promise((resolve,reject)=>{
        const chunks=[];
        const client=net.createConnection('./vphone.sock',()=>client.write(JSON.stringify({t:'rpc',method,params,screen:false})+'\n'));
        client.setTimeout(30000,()=>client.destroy(Error('RPC timeout')));
        client.on('data',b=>chunks.push(b));client.on('error',reject);
        client.on('end',()=>{try{resolve(JSON.parse(Buffer.concat(chunks)))}catch(e){reject(e)}});
    });
    const refusals=[];
    for(const [method,params] of [
        ['apps.uninstall',{bundle_id:'invalid.vphone.foundation.fixture'}],
        ['processes.kill',{pid:999999}],
        ['system.shutdown',{}],
    ]) {
        assert.equal(methods.get(method).force,'always');
        const reply=await raw(method,params);refusals.push({method,reply});
        save('force-refusals.json',refusals);
        assert.equal(reply.ok,false);assert(JSON.stringify(reply).includes('Pass force: true')); checks++;
    }
    save('force-refusals.json',refusals);
    const beforeLock=await rpc('display.auto_lock'); save('auto-lock-before.json',beforeLock);
    try {
        const never=await rpc('display.auto_lock.set',{never:true}); save('auto-lock-never.json',never);
        assert.equal(never.never,true);checks++;
        const seconds=await rpc('display.auto_lock.set',{seconds:1800}); save('auto-lock-seconds.json',seconds);
        assert.equal(seconds.auto_lock_seconds,1800);checks++;
    } finally {
        const restored=await rpc('display.auto_lock.set',{seconds:beforeLock.auto_lock_seconds??2147483647});
        save('auto-lock-restored.json',restored);
        assert.equal(restored.never,beforeLock.never);
        assert.equal(restored.auto_lock_seconds,beforeLock.auto_lock_seconds);
    }
    const beforePose=await rpc('display.pose');save('pose-before.json',beforePose);
    assert.equal(beforePose.available,true);
    const environmentBefore=await rpc('environment.status');
    // A new identity can receive a lockdown trust prompt before Home is
    // available. Refuse that pairing only when both exact system IDs match.
    await rpc('screen.unlock',{timeout:30});
    const initialTree=await rpc('ui.tree');
    const deny='com.apple.lockdown.ax.trust.deny_trust';
    const confirm='com.apple.lockdown.ax.trust.confirm_trust';
    if(initialTree.elements.some(e=>e.identifier===deny)&&initialTree.elements.some(e=>e.identifier===confirm)) {
        assert.equal((await rpc('apps.foreground')).bundle_id,'com.apple.springboard');
        save('trust-prompt.json',initialTree);
        save('trust-denial.json',await rpc('ui.tap_element',{identifier:deny}));
        let cleared=false;
        for(let attempt=0;attempt<20;attempt++) {
            await sleep(250);
            const tree=await rpc('ui.tree');
            if(!tree.elements.some(e=>e.identifier===deny)) {cleared=true;break;}
        }
        assert.equal(cleared,true,'Trust prompt must be dismissed before AX measurement');
    }
    const run=promisify(execFile);
    const outputs={};
    try {
        for(const [label,script] of [['ax','three-issues-ax.mjs'],['lifecycle','three-issues-lifecycle.mjs']]) {
            const result=await run(process.execPath,[path.join(root,'Research/Integration/duo_m5_20261030/Regression',script),socket,path.join(out,label),candidateHash],{timeout:240000,maxBuffer:1024*1024});
            fs.writeFileSync(path.join(out,label+'.log'),result.stdout+result.stderr);
            outputs[label]=JSON.parse(result.stdout.trim().split('\n').at(-1));
        }
    } finally {
        await rpc('display.posture',{hinge:beforePose.hinge,orientation:beforePose.orientation,tabletop:beforePose.tabletop});
        save('pose-restored.json',await rpc('display.pose'));
    }
    assert.equal(outputs.ax.hits,15);assert.equal(outputs.ax.failures,0);assert.equal(outputs.ax.lockedRejected,true);
    const actualHits=JSON.parse(fs.readFileSync(path.join(out,'ax/hits.json')));
    for(const row of actualHits) for(const hit of row.hits) validateResult(catalog,'ui.element_at',hit.response.result);
    const resultSchemaChecks=actualHits.reduce((sum,row)=>sum+row.hits.length,0);
    assert.equal(resultSchemaChecks,15);
    assert.equal(outputs.lifecycle.sourceRecovered,true);
    const environmentAfter=await rpc('environment.status');
    assert.equal(environmentAfter.root_read_only,true);
    assert.deepEqual(environmentAfter.libraries,environmentBefore.libraries);
    assert.equal((await rpc('device.info')).agent.binary_hash,candidateHash);
    save('foundation-summary.json',{catalogChecks:checks,resultSchemaChecks,methods:195,ax:outputs.ax,lifecycle:outputs.lifecycle});
    console.log(JSON.stringify({catalogChecks:checks,resultSchemaChecks,methods:195,ax:outputs.ax,lifecycle:outputs.lifecycle}));
}
