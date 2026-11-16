// Temporarily switch only the approved clone's daemon; preserve update markers.
import fs from 'node:fs';
import path from 'node:path';
import net from 'node:net';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {setTimeout as sleep} from 'node:timers/promises';
const [socketArg,binaryArg,expectedBefore,outArg,restoreArg]=process.argv.slice(2);
const root=fs.realpathSync(new URL('../../../../',import.meta.url));
const socket=fs.realpathSync(socketArg),binary=fs.realpathSync(binaryArg),out=path.resolve(outArg);
assert.equal(path.dirname(socket),root+'/.build/duo-runtime-84e3ce54/machines/duo-overall-20261116');
for(const file of [binary,out])assert(file.startsWith(root+'/.build/'));
assert(/^[a-f0-9]{64}$/.test(expectedBefore??''));fs.mkdirSync(out);process.chdir(path.dirname(socket));
const save=(name,value)=>fs.writeFileSync(out+'/'+name+'.json',JSON.stringify(value,null,2)+'\n');
const request=payload=>new Promise((resolve,reject)=>{
    const chunks=[],c=net.createConnection('./vphone.sock',()=>c.write(JSON.stringify({...payload,screen:false})+'\n'));
    c.setTimeout(60000,()=>c.destroy(Error('Request timeout')));c.on('data',b=>chunks.push(b));c.on('error',reject);
    c.on('end',()=>{try{const r=JSON.parse(Buffer.concat(chunks));assert(r.ok,JSON.stringify(r));resolve(r.result)}catch(e){reject(e)}});
});
const rpc=(method,params={})=>request({t:'rpc',method,params});
const before=await rpc('device.info');save('device-before',before);assert.equal(before.agent.binary_hash,expectedBefore);
const environment=await rpc('environment.status');save('environment-before',environment);assert.equal(environment.root_read_only,true);
const cache='/var/root/Library/Caches',leaves=['vphoned.api-v2','vphoned.api-v2.pending'];
async function markers(){
    const listing=await rpc('files.list',{path:cache});assert(Array.isArray(listing.entries));assert.notEqual(listing.truncated,true);
    const names=new Set(listing.entries.map(e=>e.name??path.basename(e.path))),result={};
    for(const leaf of leaves){result[leaf]={present:names.has(leaf)};if(names.has(leaf)){
        const file=await rpc('files.read',{path:cache+'/'+leaf,limit:256});assert.equal(file.truncated,false);result[leaf].content=file.content;
    }}return result;
}
save('markers-before',await markers());
const hash=createHash('sha256').update(fs.readFileSync(binary)).digest('hex');save('input',{binary,sha256:hash});
save('upload',await request({t:'push',local:binary,path:cache+'/vphoned.next',mode:'755'}));
save('apply-update',await rpc('agent.apply_update',{sha256:hash}));
let after;
for(let attempt=0;attempt<100;attempt++){
    await sleep(500);try{const value=await rpc('device.info');if(value.agent.binary_hash===hash&&value.agent.pid!==before.agent.pid){after=value;break;}}catch{}
}
assert(after,'A new worker with the pinned hash is required');save('device-after',after);
if(restoreArg){
    const restoredFrom=fs.realpathSync(restoreArg);assert(restoredFrom.startsWith(root+'/.build/'));
    const original=JSON.parse(fs.readFileSync(restoredFrom)),current=await markers();
    for(const leaf of leaves){
        if(original[leaf].present)await rpc('files.write',{path:cache+'/'+leaf,content:original[leaf].content,encoding:'utf8'});
        else if(current[leaf].present)await rpc('files.rename',{from:cache+'/'+leaf,to:cache+'/'+leaf+'.ax-followup-'+Date.now()});
    }
    const restored=await markers();save('markers-restored',restored);assert.deepEqual(restored,original);
}
save('markers-after',await markers());
const finalEnvironment=await rpc('environment.status');save('environment-after',finalEnvironment);assert.deepEqual(finalEnvironment,environment);
console.log(JSON.stringify({beforePID:before.agent.pid,afterPID:after.agent.pid,sha256:hash,environmentUnchanged:true,markersRestored:!!restoreArg}));
