// Read the installed branch and undo owners without mounting the running disk.
import fs from 'node:fs';
import path from 'node:path';
import net from 'node:net';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
const [socketArg,outArg,expectedAgent]=process.argv.slice(2);
const root=fs.realpathSync(new URL('../../../../',import.meta.url));
const socket=fs.realpathSync(socketArg),out=path.resolve(outArg);
assert.equal(path.dirname(socket),root+'/.build/duo-runtime-84e3ce54/machines/duo-overall-20261116');
assert(out.startsWith(root+'/.build/'));fs.mkdirSync(out);process.chdir(path.dirname(socket));
const save=(name,value)=>fs.writeFileSync(out+'/'+name+'.json',JSON.stringify(value,null,2)+'\n');
const request=payload=>new Promise((resolve,reject)=>{
    const chunks=[],c=net.createConnection('./vphone.sock',()=>c.write(JSON.stringify({...payload,screen:false})+'\n'));
    c.setTimeout(120000,()=>c.destroy(Error('Request timeout')));c.on('data',b=>chunks.push(b));c.on('error',reject);
    c.on('end',()=>{try{const r=JSON.parse(Buffer.concat(chunks));assert(r.ok,JSON.stringify(r));resolve(r.result)}catch(e){reject(e)}});
});
const rpc=(method,params={})=>request({t:'rpc',method,params});
assert(/^[a-f0-9]{64}$/.test(expectedAgent??''));
assert.equal((await rpc('device.info')).agent.binary_hash,expectedAgent);
const guest='/System/Cryptexes/OS/System/Library/Caches/com.apple.dyld';
const reference=root+'/.build/overall-port-20261116/framebuffer-cache-regression-fixed/cache-applied';
// Installation normalizes legacy X1 runs before applying any DSC patch.
// The offline revert already verified every migrated word and prior owner.
const normalized=root+'/.build/overall-port-20261116/framebuffer-cache-regression-fixed/cache';
const offline=JSON.parse(fs.readFileSync(path.dirname(normalized)+'/report.json'));
assert.equal(offline.phases.revert.previousOwnersPreserved,true);assert.equal(offline.phases.revert.migratedWords,8);
const expected=JSON.parse(fs.readFileSync(normalized+'/.vphone-dsc-undo.json'));
const identifier='dyld-cfw-quartzcore_unrotated_framebuffer';
expected.Records.push(...JSON.parse(fs.readFileSync(reference+'/.vphone-dsc-undo.json')).Records.filter(r=>r.PatchID===identifier));
const file=await rpc('files.read',{path:guest+'/.vphone-dsc-undo.json',limit:8*1024*1024});
assert.equal(file.truncated,false);assert.equal(file.encoding,'utf8');
const actual=JSON.parse(file.content);save('installed-undo',actual);
for(const record of expected.Records){
    const found=actual.Records.find(r=>r.PatchID===record.PatchID&&r.VMA===record.VMA&&r.FileOffset===record.FileOffset);
    assert.deepEqual(found,record,'Existing undo record: '+record.PatchID);
}
const records=actual.Records.filter(r=>r.PatchID===identifier);assert.equal(records.length,1);
const record=records[0];assert.equal(record.Chunk,path.basename(record.Chunk));
const bytes=await rpc('files.read',{path:guest+'/'+record.Chunk,offset:record.FileOffset,limit:4,binary:true});
assert.equal(bytes.encoding,'base64');const installed=Buffer.from(bytes.content,'base64');assert.equal(installed.length,4);
const handle=fs.openSync(reference+'/'+record.Chunk,'r'),verified=Buffer.alloc(4);
try{assert.equal(fs.readSync(handle,verified,0,4,record.FileOffset),4);}finally{fs.closeSync(handle);}
assert(installed.equals(verified),'Installed branch differs from the verified candidate');
assert(!installed.equals(Buffer.from(record.Original,'base64')),'Branch must be changed');
save('branch',{record,installed:installed.toString('hex'),verified:verified.toString('hex')});
const pull=await request({t:'pull',path:guest+'/.vphone-dsc-undo.words',local:out+'/installed-undo.words'});save('pull',pull);
const hash=file=>createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const expectedWords=hash(normalized+'/.vphone-dsc-undo.words'),actualWords=hash(out+'/installed-undo.words');
assert.equal(actualWords,expectedWords,'The validated X1 originals must all be retained');
const summary={branchMatchesVerifiedCandidate:true,previousJSONRecordsPreserved:expected.Records.length,
    x1WordStoreExactMatch:true,migratedOriginalWords:8,x1WordStoreSHA256:actualWords,installedOwners:[...new Set(actual.Records.map(r=>r.PatchID))].sort()};
save('summary',summary);console.log(JSON.stringify(summary));
