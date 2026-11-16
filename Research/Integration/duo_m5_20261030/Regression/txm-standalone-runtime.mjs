// Launchd isolates executable admission from the App's posix_spawn restriction.
// Jobs live in a cache directory and are unloaded before returning.
import fs from 'node:fs';
import path from 'node:path';
import net from 'node:net';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {setTimeout as sleep} from 'node:timers/promises';
const [socketArg,outArg,appArg,probeArg,route='environment']=process.argv.slice(2);
const root=fs.realpathSync(new URL('../../../../',import.meta.url));
const socket=fs.realpathSync(socketArg),out=path.resolve(outArg),appFile=fs.realpathSync(appArg);
const probe=probeArg?fs.realpathSync(probeArg):undefined;
for(const p of [socket,out,appFile])assert(p.startsWith(root+'/.build/'));
assert.equal(path.basename(path.dirname(socket)),'duo-txm-remap-20261116');
assert(['environment','exec-env'].includes(route));
const app=JSON.parse(fs.readFileSync(appFile));assert.equal(app.bundle_id,'com.vphone.tests.remap-probe');
fs.mkdirSync(out);process.chdir(path.dirname(socket));
const save=(name,value)=>fs.writeFileSync(out+'/'+name+'.json',JSON.stringify(value,null,2)+'\n');
const raw=(method,params={})=>new Promise((resolve,reject)=>{
    const chunks=[],c=net.createConnection('./vphone.sock',()=>c.write(JSON.stringify({t:'rpc',method,params,screen:false})+'\n'));
    c.setTimeout(30000,()=>c.destroy(Error('RPC timeout')));c.on('data',b=>chunks.push(b));c.on('error',reject);
    c.on('end',()=>{try{resolve(JSON.parse(Buffer.concat(chunks)))}catch(e){reject(e)}});
});
const rpc=async(method,params={})=>{const r=await raw(method,params);assert(r.ok,JSON.stringify(r));return r.result};
const nonce=Date.now().toString(36),guest='/var/root/Library/Caches/txm-standalone-'+nonce;
const rows=[];save('crashes-before',await rpc('logs.crashes'));
if(probe){
    assert(probe.startsWith(root+'/.build/'));
    const inputs=[];
    for(const name of ['standalone-ldid','standalone-adhoc']){
        const bytes=fs.readFileSync(probe+'/external/'+name),guestPath=app.data_path+'/Documents/'+name;
        await rpc('files.write',{path:guestPath,encoding:'base64',content:bytes.toString('base64')});await rpc('files.chmod',{path:guestPath,mode:'755'});
        inputs.push({name,sha256:createHash('sha256').update(bytes).digest('hex')});
    }
    save('inputs',inputs);
}
for(const mode of ['ldid','adhoc']){
    const label='com.vphone.tests.remap-'+mode+'-'+nonce,plistPath=guest+'/'+mode+'.plist';
    const program=app.data_path+'/Documents/standalone-'+mode;
    const library=app.data_path+'/Documents/libinjected-ldid.dylib';
    const reportPath=guest+'/'+mode+'.json';
    const row={mode,label,program,reportPath,route};rows.push(row);
    const argumentsList=route==='exec-env'?[app.data_path+'/Documents/standalone-ldid','--inject',library,program,reportPath]:[program,reportPath];
    const manifest={Label:label,ProgramArguments:argumentsList,RunAtLoad:true,KeepAlive:false,
        EnvironmentVariables:route==='environment'?{DYLD_INSERT_LIBRARIES:library}:{},WorkingDirectory:guest,
        StandardOutPath:guest+'/'+mode+'.stdout',StandardErrorPath:guest+'/'+mode+'.stderr'};
    const plist=execFileSync('/usr/bin/plutil',['-convert','xml1','-o','-','-'],{input:JSON.stringify(manifest),encoding:'utf8'});
    fs.writeFileSync(out+'/'+mode+'.plist',plist);
    await rpc('files.write',{path:plistPath,content:plist});await rpc('files.chmod',{path:plistPath,mode:'644'});
    await rpc('files.chown',{path:plistPath,owner:'0:0'});
    const before=await rpc('files.read',{path:program,binary:true,limit:1048576});assert.equal(before.truncated,false);
    row.programSHA256=createHash('sha256').update(Buffer.from(before.content,'base64')).digest('hex');
    try {
        row.load=await raw('services.load',{paths:[plistPath]});save('results',rows);
        for(let attempt=0;attempt<20;attempt++){
            await sleep(250);row.status=await raw('services.status',{label});
            const file=await raw('files.read',{path:reportPath});
            if(file.ok){row.report=JSON.parse(file.result.content);break;}
            if(row.status.ok&&row.status.result.running===false&&row.status.result.last_exit_status!==undefined)break;
        }
        row.description=await raw('services.print',{label});
        row.stderr=await raw('files.read',{path:guest+'/'+mode+'.stderr'});
        const canonical=p=>p?.replace(/^\/private\/var\//,'/var/');
        row.passed=row.load.ok&&row.report?.constructor===1&&row.report?.answer===73&&canonical(row.report.executablePath)===canonical(program);
    } finally {
        row.unload=await raw('services.unload',{paths:[plistPath],force:true});
        row.finalStatus=await raw('services.status',{label});save('results',rows);
    }
}
save('crashes-after',await rpc('logs.crashes'));
save('summary',{cases:rows.length,passed:rows.filter(x=>x.passed).length,
    unloaded:rows.every(x=>x.unload.ok&&x.finalStatus.ok&&x.finalStatus.result.loaded===false)});
console.log(JSON.stringify(rows.map(x=>({mode:x.mode,passed:x.passed,report:x.report,status:x.status,unloaded:x.finalStatus.result?.loaded===false}))));
assert(rows.every(x=>x.unload.ok&&x.finalStatus.ok&&x.finalStatus.result.loaded===false),'All generated jobs must be unloaded');
assert(rows.every(x=>x.passed),'Both standalone signature modes must execute the injected constructor and export');
