import fs from 'node:fs';
import path from 'node:path';
import net from 'node:net';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
const root=fs.realpathSync(new URL('../../../../',import.meta.url));
const machine=root+'/.build/duo-runtime-84e3ce54/machines/duo-patches-20261116';
const [outArg,mode='install',ipaArg=root+'/.build/upstream-port-20261116/tap-probe/TapProbe/TapProbe.ipa']=process.argv.slice(2),out=path.resolve(outArg);assert(['install','update'].includes(mode));assert(path.resolve(ipaArg).startsWith(root+'/.build/'));assert(out.startsWith(root+'/.build/'));fs.mkdirSync(out);
process.chdir(machine);
const rpc=(method,params={})=>new Promise((resolve,reject)=>{
    const chunks=[],c=net.createConnection('./vphone.sock',()=>c.write(JSON.stringify({t:'rpc',method,params,screen:false})+'\n'));
    c.setTimeout(60000,()=>c.destroy(Error('RPC timeout')));c.on('data',b=>chunks.push(b));c.on('error',reject);
    c.on('end',()=>{try{const r=JSON.parse(Buffer.concat(chunks));assert(r.ok,JSON.stringify(r));resolve(r.result)}catch(e){reject(e)}});
});
const save=(name,value)=>fs.writeFileSync(out+'/'+name+'.json',JSON.stringify(value,null,2)+'\n');
assert.equal((await rpc('device.info')).agent.binary_hash,'c04e362ae02b6b521bac06d1f2833850935e8e88ea121b8d7fd8fb139dd48593');
const apps=await rpc('apps.list',{filter:'user'});save('apps-before',apps);assert.equal(apps.truncated,false);const previous=apps.apps.find(x=>x.bundle_id==='com.autophone.tap-probe');assert.equal(!!previous,mode==='update');
const ipa=fs.readFileSync(ipaArg);assert(ipa.length<1024*1024);
save('input',{bundleID:'com.autophone.tap-probe',ipa:path.resolve(ipaArg),sha256:createHash('sha256').update(ipa).digest('hex'),mode,installationPath:'apps.install'});
const guestPath='/var/root/Library/Caches/patch-port-tap-probe-20261116.ipa';
save('upload',await rpc('files.write',{path:guestPath,encoding:'base64',content:ipa.toString('base64')}));
const installed=await rpc('apps.install',{path:guestPath});save('install',installed);assert.equal(installed.bundle_id,'com.autophone.tap-probe');
if(mode==='update'){assert.equal(installed.upgraded,true);assert.equal(installed.data_container,previous.data_path);}
console.log('Installed generated TapProbe through apps.install; this does not exercise installd');
