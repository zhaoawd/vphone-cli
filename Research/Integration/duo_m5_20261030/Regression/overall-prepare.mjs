// Establish existing test preconditions on the approved combined clone.
import fs from 'node:fs';
import path from 'node:path';
import net from 'node:net';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {setTimeout as sleep} from 'node:timers/promises';
const [socketArg,outArg,expectedAgent]=process.argv.slice(2);
const root=fs.realpathSync(new URL('../../../../',import.meta.url));
const socket=fs.realpathSync(socketArg),out=path.resolve(outArg);
assert.equal(path.dirname(socket),root+'/.build/duo-runtime-84e3ce54/machines/duo-overall-20261116');
assert(out.startsWith(root+'/.build/'));assert(/^[a-f0-9]{64}$/.test(expectedAgent??''));
fs.mkdirSync(out);process.chdir(path.dirname(socket));
const save=(name,value)=>fs.writeFileSync(out+'/'+name+'.json',JSON.stringify(value,null,2)+'\n');
const rpc=(method,params={})=>new Promise((resolve,reject)=>{
    const chunks=[],c=net.createConnection('./vphone.sock',()=>c.write(JSON.stringify({t:'rpc',method,params,screen:false})+'\n'));
    c.setTimeout(60000,()=>c.destroy(Error('RPC timeout')));c.on('data',b=>chunks.push(b));c.on('error',reject);
    c.on('end',()=>{try{const r=JSON.parse(Buffer.concat(chunks));assert(r.ok,JSON.stringify(r));resolve(r.result)}catch(e){reject(e)}});
});
assert.equal((await rpc('device.info')).agent.binary_hash,expectedAgent);
const id='com.autophone.tap-probe',apps=await rpc('apps.list',{filter:'user'});
save('apps-before',apps);assert.equal(apps.truncated,false);
if(!apps.apps.some(app=>app.bundle_id===id)){
    const ipaPath=root+'/.build/upstream-port-20261116/tap-probe-measured/TapProbe/TapProbe.ipa';
    const ipa=fs.readFileSync(ipaPath);assert(ipa.length<1024*1024);
    save('input',{bundleID:id,ipaPath,sha256:createHash('sha256').update(ipa).digest('hex'),installationPath:'apps.install'});
    const guest='/var/root/Library/Caches/overall-tap-probe-20261116.ipa';
    save('upload',await rpc('files.write',{path:guest,encoding:'base64',content:ipa.toString('base64')}));
    const installed=await rpc('apps.install',{path:guest});save('install',installed);assert.equal(installed.bundle_id,id);
}
const installed=await rpc('apps.list',{filter:'user'});save('apps-after',installed);
assert.equal(installed.truncated,false);assert(installed.apps.some(app=>app.bundle_id===id&&app.data_path));
await rpc('screen.unlock',{timeout:30});await rpc('input.button',{name:'home'});await sleep(1000);
const deny='com.apple.lockdown.ax.trust.deny_trust',confirm='com.apple.lockdown.ax.trust.confirm_trust';
const initial=await rpc('ui.tree');save('initial-tree',initial);
if(initial.elements.some(e=>e.identifier===deny)&&initial.elements.some(e=>e.identifier===confirm)){
    assert.equal((await rpc('apps.foreground')).bundle_id,'com.apple.springboard');
    save('trust-denial',await rpc('ui.tap_element',{identifier:deny,match:'exact'}));
}
await rpc('input.button',{name:'home'});await sleep(750);
const observations=[];
for(let attempt=0;attempt<20;attempt++){
    const foreground=await rpc('apps.foreground'),tree=await rpc('ui.tree');observations.push({foreground,tree});save('settled',observations);
    assert(!tree.elements.some(e=>e.identifier===deny||e.identifier===confirm),'Trust prompt must stay dismissed');
    assert(foreground.verified&&foreground.bundle_id==='com.apple.springboard','Home foreground required');
    await sleep(250);
}
console.log(JSON.stringify({tapProbeInstalled:true,trustPromptAbsentSamples:observations.length,installdValidated:false}));
