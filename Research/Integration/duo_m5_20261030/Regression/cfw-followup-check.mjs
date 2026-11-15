import {fileURLToPath} from 'node:url';
import fs from 'node:fs';import path from 'node:path';import net from 'node:net';import assert from 'node:assert/strict';import {createHash} from 'node:crypto';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../../../..');
const [socket,out,resources]=process.argv.slice(2);assert.equal(path.basename(path.dirname(socket)),'duo-cfw-followup-20261115');process.chdir(path.dirname(socket));
const rpc=(method,params={})=>new Promise((resolve,reject)=>{let chunks=[];const c=net.createConnection('./vphone.sock',()=>c.write(JSON.stringify({t:'rpc',method,params,screen:false})+'\n'));c.setTimeout(30000,()=>c.destroy(Error('timeout')));c.on('data',b=>chunks.push(b));c.on('error',reject);c.on('end',()=>{try{const j=JSON.parse(Buffer.concat(chunks));assert(j.ok,method+': '+JSON.stringify(j.error));resolve(j.result)}catch(e){reject(e)}})});
const save=(name,j)=>fs.writeFileSync(out+'/'+name+'.json',JSON.stringify(j,null,2)+'\n');const digest=file=>createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const info=await rpc('device.info');save('device',info);assert.equal(info.agent.binary_hash,'c04e362ae02b6b521bac06d1f2833850935e8e88ea121b8d7fd8fb139dd48593');assert.equal(info.agent.binary_hash,digest(resources+'/vphoned'));
const environment=await rpc('environment.status');save('environment',environment);assert.equal(environment.root_read_only,true);assert.equal(environment.libraries.length,21);
const baseline=JSON.parse(fs.readFileSync(root+'/.build/host-webcam-distribution-20261115/original-cache-state.json')).environment.libraries;
for(const library of environment.libraries){const old=baseline.find(l=>l.name===library.name);assert(old);const expected=old.sha256?digest(resources+'/'+library.name):null;assert.equal(library.sha256,expected,library.name);}
save('auto-lock',await rpc('display.auto_lock'));save('orientation',await rpc('display.orientation'));save('methods',await rpc('methods.list'));save('processes',await rpc('processes.list'));
const summary={daemon:info.agent.binary_hash,libraryEntries:21,allExpectedHashes:true,rootReadOnly:true,uptimeSeconds:info.uptime_seconds};save('summary',summary);console.log(JSON.stringify(summary));
