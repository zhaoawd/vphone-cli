// Verify installed DSC writes against original bytes and the GPU identity in a host copy.
import fs from 'node:fs';
import path from 'node:path';
import net from 'node:net';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
const [socketArg,outArg,expectedAgent,systemArg]=process.argv.slice(2);
const root=fs.realpathSync(new URL('../../../../',import.meta.url));
const system=systemArg?fs.realpathSync(systemArg):null;
const socket=system?null:fs.realpathSync(socketArg),out=path.resolve(outArg);
if(system)assert.equal(system,root+'/.build/overall-port-20261116/post-update-system');
else assert.equal(path.dirname(socket),root+'/.build/duo-runtime-84e3ce54/machines/duo-overall-20261116');
assert(out.startsWith(root+'/.build/'));fs.mkdirSync(out);if(socket)process.chdir(path.dirname(socket));
const save=(name,value)=>fs.writeFileSync(out+'/'+name+'.json',JSON.stringify(value,null,2)+'\n');
if(system){
    const plist=execFileSync('/usr/sbin/diskutil',['info','-plist',system]);
    const volume=JSON.parse(execFileSync('/usr/bin/plutil',['-convert','json','-o','-','-'],{input:plist,encoding:'utf8'}));
    for(const key of ['Writable','WritableMedia','WritableVolume'])assert.equal(volume[key],false,key);
    assert.equal(volume.MountPoint,system);save('readonly-volume',volume);
}
const systemFile=guest=>{
    assert(guest.startsWith('/'));const resolved=fs.realpathSync(system+guest);
    assert(resolved.startsWith(system+'/'),'File must stay inside mounted System');return resolved;
};
const request=async payload=>{
    if(system){
        if(payload.t==='pull'){
            assert(payload.local.startsWith(out+'/'));fs.copyFileSync(systemFile(payload.path),payload.local);
            return {path:payload.path,local:payload.local,size:fs.statSync(payload.local).size};
        }
        assert.equal(payload.t,'rpc');const {method,params}=payload;
        if(method==='device.info')return {agent:{binary_hash:createHash('sha256').update(fs.readFileSync(systemFile('/usr/bin/vphoned'))).digest('hex')}};
        assert.equal(method,'files.read');const file=systemFile(params.path),size=fs.statSync(file).size;
        const offset=params.offset??0,bytes=Buffer.alloc(Math.min(params.limit??524288,Math.max(0,size-offset))),handle=fs.openSync(file,'r');
        try{assert.equal(fs.readSync(handle,bytes,0,bytes.length,offset),bytes.length);}finally{fs.closeSync(handle);}
        return {encoding:params.binary?'base64':'utf8',content:bytes.toString(params.binary?'base64':'utf8'),truncated:offset+bytes.length<size};
    }
    return new Promise((resolve,reject)=>{
    const chunks=[],c=net.createConnection('./vphone.sock',()=>c.write(JSON.stringify({...payload,screen:false})+'\n'));
    c.setTimeout(60000,()=>c.destroy(Error('Request timeout')));c.on('data',b=>chunks.push(b));c.on('error',reject);
    c.on('end',()=>{try{const r=JSON.parse(Buffer.concat(chunks));assert(r.ok,JSON.stringify(r));resolve(r.result)}catch(e){reject(e)}});
    });
};
const rpc=(method,params={})=>request({t:'rpc',method,params});
assert.equal((await rpc('device.info')).agent.binary_hash,expectedAgent);
const cache='/System/Cryptexes/OS/System/Library/Caches/com.apple.dyld';
const undo=await rpc('files.read',{path:cache+'/.vphone-dsc-undo.json',limit:8*1024*1024});assert.equal(undo.truncated,false);
const actual=JSON.parse(undo.content);
const before=JSON.parse(fs.readFileSync(root+'/.build/overall-port-20261116/combined-patch-report.json'));
const selected=before.patches.filter(p=>p.pending&&p.delivery==='update-environment'&&p.identifier.startsWith('dyld-')).map(p=>p.identifier);
assert.equal(selected.length,7);const rows=[];
for(const id of selected){
    const records=actual.Records.filter(r=>r.PatchID===id);assert(records.length>0,id);
    for(const record of records){
        assert.equal(record.Chunk,path.basename(record.Chunk));const original=Buffer.from(record.Original,'base64');
        const fixture=fs.openSync(root+'/.build/overall-port-20261116/duo-cache-original/'+record.Chunk,'r'),bytes=Buffer.alloc(original.length);
        try{assert.equal(fs.readSync(fixture,bytes,0,bytes.length,record.FileOffset),bytes.length);}finally{fs.closeSync(fixture);}
        assert(bytes.equals(original),'Undo original must match pre-update source: '+id);
        const current=await rpc('files.read',{path:cache+'/'+record.Chunk,offset:record.FileOffset,limit:original.length,binary:true});
        assert.equal(current.encoding,'base64');const installed=Buffer.from(current.content,'base64');assert.equal(installed.length,original.length);
        assert(!installed.equals(original),'Recorded write must be present: '+id);
        rows.push({identifier:id,chunk:record.Chunk,offset:record.FileOffset,original:original.toString('hex'),installed:installed.toString('hex')});save('writes',rows);
    }
}
const marker=await rpc('files.read',{path:'/usr/lib/vphone-gles-upper-left'});save('gles-upper-left',marker);assert.equal(marker.content,'1\n');
const gpu='/System/Library/Extensions/AppleParavirtGPUMetalIOGPUFamily.bundle/';
for(const [guest,local] of [['AppleParavirtGPUMetalIOGPUFamily','driver'],['libAppleParavirtCompilerPluginIOGPUFamily.dylib','plugin.dylib']]){
    save('pull-'+local,await request({t:'pull',path:gpu+guest,local:out+'/'+local}));
}
const hash=file=>createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const driver=out+'/driver',prior=hash(driver),cli=root+'/.build/overall-port-20261116/REVIEWED/VPhone.bundle/Contents/MacOS/vphone-cli';
const result=execFileSync(cli,['cfw','patch-paravirt-gpu-compiler-cache',driver,'--compiler-plugin',out+'/plugin.dylib'],{encoding:'utf8'});
fs.writeFileSync(out+'/compiler-cache.log',result);assert.equal(hash(driver),prior,'Installed compiler identity must already match its plugin');
// The installed executable seals its bundle Info.plist. Verify in that layout;
// a standalone host copy cannot satisfy that special CodeDirectory slot.
assert(system,'Bundle signature verification requires the stopped, read-only mounted System');
execFileSync('/usr/bin/codesign',['--verify','--strict',systemFile(gpu.slice(0,-1))],{stdio:'pipe'});
const summary={inputMode:'readonly-mounted-system',dscPatchIDs:7,verifiedWriteRecords:rows.length,originalsMatchSource:true,glesUpperLeftMarker:true,compilerIdentityMatchesInstalledPlugin:true,driverBundleStrictSignature:true,driverSHA256:prior};
save('summary',summary);console.log(JSON.stringify(summary));
