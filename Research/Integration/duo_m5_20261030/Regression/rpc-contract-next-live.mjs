// Actual guest regression for the five RPC contract changes. The caller owns VM rollback.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import net from 'node:net';
import {fileURLToPath} from 'node:url';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {setTimeout as sleep} from 'node:timers/promises';
import {validateResult} from './rpc-foundation-live.mjs';
const [socketArg,outArg,hash] = process.argv.slice(2);
const root=fileURLToPath(new URL('../../../../',import.meta.url));
const socket=fs.realpathSync(socketArg),out=path.resolve(outArg);
assert.equal(path.basename(path.dirname(socket)),'duo-rpc-foundation-20261115');
assert(socket.startsWith(root+'.build/')&&out.startsWith(root+'.build/'));
assert(/^[a-f0-9]{64}$/.test(hash??''));fs.mkdirSync(out);process.chdir(path.dirname(socket));
const save=(name,value)=>fs.writeFileSync(path.join(out,name+'.json'),JSON.stringify(value,null,2)+'\n');
const raw=(method,params={})=>new Promise((resolve,reject)=>{
    const chunks=[],c=net.createConnection('./vphone.sock',()=>c.write(JSON.stringify({t:'rpc',method,params,screen:false})+'\n'));
    c.setTimeout(30000,()=>c.destroy(Error('RPC timeout')));c.on('data',b=>chunks.push(b));c.on('error',reject);
    c.on('end',()=>{try{resolve(JSON.parse(Buffer.concat(chunks)))}catch(e){reject(e)}});
});
const catalog=(await raw('methods.list')).result;save('catalog',catalog);
assert.equal(catalog.scope,'guest');assert.equal(catalog.complete,true);assert.equal(catalog.methods.length,197);
let schemas=0,checks=3;
const rpc=async(method,params={})=>{const reply=await raw(method,params);assert.equal(reply.ok,true,method+': '+JSON.stringify(reply.guest_error??reply.error));validateResult(catalog,method==='process.spawn'?'processes.spawn':method,reply.result);schemas++;return reply.result;};
const refuse=async(method,params,code)=>{const r=await raw(method,params);assert.equal(r.ok,false);assert.equal(r.guest_error.code,code);checks++;return r;};
assert.equal((await rpc('device.info')).agent.binary_hash,hash);
const env=await rpc('environment.status'),pose=await rpc('display.pose'),lock=await rpc('display.auto_lock');
const errors=[];
for(const [m,p,c] of [['methods.list',{extra:1},'invalid_param'],['method.not_real',{},'not_found'],['system.shutdown',{},'force_required'],['files.read',{path:'/var/root/Library/Caches/vphone-contract-missing-'+Date.now(),limit:100},'not_found']])errors.push({method:m,reply:await refuse(m,p,c)});
save('errors',errors);
try {
    save('never',await rpc('display.auto_lock.set',{never:true}));
    const seconds=await rpc('display.auto_lock.set',{seconds:1800});assert.equal(seconds.auto_lock_seconds,1800);
    await rpc('display.posture',{hinge:'closed'});await rpc('screen.unlock',{timeout:30,timeout_ms:30000});await sleep(1200);
    const tree=await rpc('ui.tree'),deny='com.apple.lockdown.ax.trust.deny_trust',confirm='com.apple.lockdown.ax.trust.confirm_trust';
    const trust={before:tree,present:tree.elements.some(e=>e.identifier===deny)&&tree.elements.some(e=>e.identifier===confirm),samples:[]};save('trust',trust);
    if(trust.present){
        assert.equal((await rpc('apps.foreground')).bundle_id,'com.apple.springboard');
        trust.action=await rpc('ui.tap_element',{identifier:deny});
        for(let i=0;i<20;i++){await sleep(250);trust.samples.push(await rpc('ui.tree'));save('trust',trust);}
        assert(trust.samples.slice(-4).every(t=>!t.elements.some(e=>e.identifier===deny)),'Trust denial must stay dismissed');checks++;
    }
    const legacy=await rpc('process.spawn',{executable:'ps',arguments:['-p','1'],timeout_seconds:3,timeout_ms:3000});assert.equal(legacy.timed_out,false);save('legacy-spawn',legacy);checks++;
    const settle=await rpc('setup.settle',{timeout_s:1,timeout_ms:0,poll_s:30,poll_ms:1000});
    assert.equal(settle.timeout_ms,0);assert.equal(settle.poll_ms,1000);assert.equal(settle.poll_s,1);save('settle',settle);checks+=3;
    const pages=[];let cursor;for(let i=0;i<3;i++){let p=await rpc('processes.list',{limit:5,...cursor?{cursor}:{}});assert.equal(p.processes.length,5);if(pages.length)assert(p.processes[0].pid>pages.at(-1).processes.at(-1).pid);pages.push(p);cursor=p.next_cursor;assert.equal(typeof cursor,'string');checks++;}save('process-pages',pages);
    const output=await rpc('processes.spawn',{executable:'ps',arguments:['-axwwo',Array(25).fill('command').join(',')],timeout_ms:10000,max_output_bytes:100});save('spawn',output);
    assert.equal(output.timed_out,false);assert.equal(output.stdout_truncated,true);assert(Buffer.byteLength(output.stdout)<=100);assert.equal(typeof output.output_id,'string');
    const chunks=[];let offset=0;do{let p=await rpc('processes.output',{output_id:output.output_id,stream:'stdout',offset,limit:4096,binary:true});assert.equal(p.total,output.stdout_total);chunks.push(Buffer.from(p.data,'base64'));if(p.next_offset===undefined)break;assert(p.next_offset>offset);offset=p.next_offset;}while(true);
    const all=Buffer.concat(chunks);assert.equal(all.length,output.stdout_total);assert(all.subarray(0,Buffer.byteLength(output.stdout)).equals(Buffer.from(output.stdout)));checks+=5;
    const file=await rpc('files.read',{path:output.output_dir+'/stdout',offset:0,limit:100});assert.equal(file.total,output.stdout_total);assert.equal(file.next_offset,100);save('file-page',file);
    save('released',await rpc('processes.output_release',{output_id:output.output_id}));save('released-error',await refuse('processes.output',{output_id:output.output_id,stream:'stdout'},'not_found'));
    const stateBefore=await rpc('device.snapshot');
    for(const bad of [{observe:1},{observe:true,observe_delay_ms:5001},{observe:false,observe_delay_ms:0.5}])await refuse('input.button',{name:'power',...bad},'invalid_param');
    assert.deepEqual((await rpc('device.snapshot')).lock,stateBefore.lock);checks++;
    const plain=await rpc('input.button',{name:'home'});assert(!('observed' in plain));
    const observed=await rpc('input.button',{name:'home',observe:true,observe_delay_ms:0});save('observed',observed);
    assert.equal(observed.observed.frontmost_bundle_id,'com.apple.springboard');assert.equal(observed.observed.frontmost_verified,true);assert(observed.observed.ui_element_count<=500);checks+=4;
    const run=promisify(execFile),results={};
    for(const [label,script] of [['ax','three-issues-ax.mjs'],['lifecycle','three-issues-lifecycle.mjs']]){
        const r=await run(process.execPath,[path.join(root,'Research/Integration/duo_m5_20261030/Regression',script),socket,path.join(out,label),hash],{timeout:240000,maxBuffer:1024*1024});
        fs.writeFileSync(path.join(out,label+'.log'),r.stdout+r.stderr);results[label]=JSON.parse(r.stdout.trim().split('\n').at(-1));
    }
    assert.equal(results.ax.hits,15);assert.equal(results.ax.failures,0);assert.equal(results.ax.lockedRejected,true);assert.equal(results.lifecycle.sourceRecovered,true);
    const after=await rpc('environment.status');assert.equal(after.root_read_only,true);assert.deepEqual(after.libraries,env.libraries);
    save('summary',{checks,schemas,methods:197,trustTested:trust.present,...results});console.log(JSON.stringify({checks,schemas,methods:197,trustTested:trust.present,...results}));
} finally {
    save('lock-restored',await rpc('display.auto_lock.set',{seconds:lock.auto_lock_seconds??2147483647}));
    save('pose-restored',await rpc('display.posture',{hinge:pose.hinge,orientation:pose.orientation,tabletop:pose.tabletop}));
}
