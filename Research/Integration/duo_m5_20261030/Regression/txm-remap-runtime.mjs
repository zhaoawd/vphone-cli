// Installs only the generated probe on the explicitly approved TXM clone.
// This uses apps.install; it does not validate installd or physical pairing.
import fs from 'node:fs';
import path from 'node:path';
import net from 'node:net';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {setTimeout as sleep} from 'node:timers/promises';
const [socketArg,outArg,probeArg,bundleArg,mode='install']=process.argv.slice(2);
const root=fs.realpathSync(new URL('../../../../',import.meta.url));
const socket=fs.realpathSync(socketArg),out=path.resolve(outArg),probe=fs.realpathSync(probeArg),bundle=fs.realpathSync(bundleArg);
for(const p of [socket,out,probe,bundle])assert(p.startsWith(root+'/.build/'));
const machineName=path.basename(path.dirname(socket));
assert(['duo-txm-remap-20261116','duo-overall-20261116'].includes(machineName));
assert(['install','run','run-no-custom-trust'].includes(mode));fs.mkdirSync(out);process.chdir(path.dirname(socket));
const hash=b=>createHash('sha256').update(b).digest('hex');
const save=(name,value)=>fs.writeFileSync(out+'/'+name+'.json',JSON.stringify(value,null,2)+'\n');
const rpc=(method,params={})=>new Promise((resolve,reject)=>{
    const chunks=[],c=net.createConnection('./vphone.sock',()=>c.write(JSON.stringify({t:'rpc',method,params,screen:false})+'\n'));
    c.setTimeout(60000,()=>c.destroy(Error('RPC timeout')));c.on('data',b=>chunks.push(b));c.on('error',reject);
    c.on('end',()=>{try{const r=JSON.parse(Buffer.concat(chunks));assert(r.ok,method+': '+JSON.stringify(r));resolve(r.result)}catch(e){reject(e)}});
});
const read=async guestPath=>{
    const r=await rpc('files.read',{path:guestPath,binary:true,limit:8*1024*1024});
    assert.equal(r.encoding,'base64');assert.equal(r.truncated,false,guestPath);return Buffer.from(r.content,'base64');
};
const signature=bytes=>{
    assert.equal(bytes.readUInt32LE(0),0xfeedfacf);
    let command=32,offset;
    for(let i=0;i<bytes.readUInt32LE(16);i++){
        if(bytes.readUInt32LE(command)===0x1d)offset=bytes.readUInt32LE(command+8);
        command+=bytes.readUInt32LE(command+4);
    }
    assert(offset!==undefined);assert.equal(bytes.readUInt32BE(offset),0xfade0cc0);
    const slots=[];
    for(let i=0;i<bytes.readUInt32BE(offset+8);i++)slots.push({type:bytes.readUInt32BE(offset+12+i*8),offset:offset+bytes.readUInt32BE(offset+16+i*8)});
    const cd=slots.find(x=>x.type===0);assert(cd);assert.equal(bytes.readUInt32BE(cd.offset),0xfade0c02);
    return {flags:bytes.readUInt32BE(cd.offset+12),cms:slots.some(x=>x.type===0x10000),sha256:hash(bytes)};
};
const id='com.vphone.tests.remap-probe';
const info=await rpc('device.info');save('device',info);
assert.equal(info.agent.binary_hash,hash(fs.readFileSync(bundle+'/Contents/Resources/guest-resources/vphoned')));
const receipt=JSON.parse(execFileSync(bundle+'/Contents/MacOS/vphone-cli',['fw','patches',machineName,'-l',path.dirname(path.dirname(socket)),'--json'],{encoding:'utf8',maxBuffer:8*1024*1024}));
save('patches',receipt);
assert.equal(receipt.patches.find(x=>x.identifier==='txm-cfw-executable_remap').applied,true);
assert.equal(receipt.patches.find(x=>x.identifier==='txm-exp-precheck_admission').applied,false);
let apps=await rpc('apps.list',{filter:'user'});assert.equal(apps.truncated,false);
let app=apps.apps.find(x=>x.bundle_id===id);assert.equal(!!app,mode!=='install');
if(mode==='install'){
    const ipa=fs.readFileSync(probe+'/RemapProbe.ipa');save('input',{ipaSHA256:hash(ipa),bundleID:id,installationPath:'apps.install'});
    const guestIPA='/var/root/Library/Caches/txm-remap-probe-20261116.ipa';
    save('upload',await rpc('files.write',{path:guestIPA,encoding:'base64',content:ipa.toString('base64')}));
    save('install',await rpc('apps.install',{path:guestIPA}));
    apps=await rpc('apps.list',{filter:'user'});assert.equal(apps.truncated,false);app=apps.apps.find(x=>x.bundle_id===id);
}
assert(app?.data_path&&app?.bundle_path);save('app',app);
// Each run needs a new PID: an old complete report is never a fresh result.
if(app.pid>0)save('terminate-previous',await rpc('apps.terminate',{bundle_id:id}));
if(mode==='run-no-custom-trust'){
    const before=await read(app.bundle_path+'/RemapProbe'),target=out+'/RemapProbe-no-custom-trust';
    fs.writeFileSync(out+'/RemapProbe-before-resign',before);fs.writeFileSync(target,before);
    const entitlements=out+'/without-custom-trust.plist';
    fs.writeFileSync(entitlements,execFileSync(bundle+'/Contents/MacOS/vphone-cli',['dump-entitlements',target]));
    execFileSync('/usr/bin/xcrun',['swift','-module-cache-path',out+'/modules','-e',`
        import Foundation
        let url = URL(fileURLWithPath: CommandLine.arguments.last!)
        var plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as! [String: Any]
        precondition(plist.removeValue(forKey: "jb.pmap_cs_custom_trust") != nil)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
    `,entitlements]);
    execFileSync(bundle+'/Contents/MacOS/vphone-cli',['sign',target,'--entitlements',entitlements,'--identifier',id]);
    const bytes=fs.readFileSync(target);assert.equal(signature(bytes).flags,0);assert.equal(signature(bytes).cms,false);
    await rpc('files.write',{path:app.bundle_path+'/RemapProbe',encoding:'base64',content:bytes.toString('base64')});
    await rpc('files.chmod',{path:app.bundle_path+'/RemapProbe',mode:'755'});
    assert.equal(hash(await read(app.bundle_path+'/RemapProbe')),hash(bytes));
    save('resign',{before:signature(before),after:signature(bytes),removedEntitlement:'jb.pmap_cs_custom_trust'});
}
const external=[];
for(const name of ['libinjected-ldid.dylib','libinjected-adhoc.dylib','standalone-ldid','standalone-adhoc']){
    const bytes=fs.readFileSync(probe+'/external/'+name),guest=app.data_path+'/Documents/'+name;
    await rpc('files.write',{path:guest,encoding:'base64',content:bytes.toString('base64')});await rpc('files.chmod',{path:guest,mode:'755'});
    assert.equal(hash(await read(guest)),hash(bytes));const meta=signature(bytes);
    assert.equal(meta.flags,name.includes('-adhoc')?2:0);external.push({name,...meta});
}
save('external-signatures',external);
const installed=[];
for(const relative of ['RemapProbe','Frameworks/RemapFixture.framework/RemapFixture']){
    const bytes=await read(app.bundle_path+'/'+relative),target=out+'/'+path.basename(relative);fs.writeFileSync(target,bytes);
    const entitlements=execFileSync(bundle+'/Contents/MacOS/vphone-cli',['dump-entitlements',target],{encoding:'utf8'});
    fs.writeFileSync(target+'.entitlements.plist',entitlements);
    installed.push({path:relative,...signature(bytes),entitlements});
}
save('installed-signatures',installed);
if(mode==='run-no-custom-trust')assert(!installed[0].entitlements.includes('jb.pmap_cs_custom_trust'));
const pose=await rpc('display.pose'),lock=await rpc('display.auto_lock'),snapshot=await rpc('device.snapshot');
save('initial',{pose,lock,snapshot});save('crashes-before',await rpc('logs.crashes'));
try {
    await rpc('display.auto_lock.set',{never:true});await rpc('screen.unlock',{timeout:30});
    const launch=await rpc('apps.launch',{bundle_id:id});save('launch',launch);
    let result;
    for(let attempt=0;attempt<100;attempt++){
        await sleep(500);
        try {result=JSON.parse((await read(app.data_path+'/Documents/remap-probe.json')).toString());save('report',result);}
        catch(error){save('read-error',{error:String(error)});}
        if(result?.complete&&result.pid===launch.pid)break;
    }
    save('foreground',await rpc('apps.foreground'));save('crashes-after',await rpc('logs.crashes'));
    assert(result?.complete,'Probe must complete');assert.equal(result.pid,launch.pid);
    const summary={cases:result.cases.length,passed:result.cases.filter(x=>x.passed).length,
        aliases:result.cases.reduce((n,x)=>n+x.aliases.length,0),libraries:result.libraries,
        standalone:result.standalone,customTrust:installed[0].entitlements.includes('jb.pmap_cs_custom_trust')};
    save('summary',summary);console.log(JSON.stringify(summary));
    assert.equal(result.cases.length,20);assert(result.cases.every(x=>x.passed),'Actual RX and execution required in every remap case');
    assert.equal(result.libraries.length,2);assert(result.libraries.every(x=>x.passed),'Both pushed libraries must execute constructors and exports');
    assert(result.standalone.every(x=>x.spawnError===0&&x.exit===0),'Standalone injection must succeed in both signature modes');
} finally {
    save('auto-lock-restored',await rpc('display.auto_lock.set',lock.never?{never:true}:{seconds:lock.auto_lock_seconds}));
    save('pose-restored',await rpc('display.posture',{hinge:pose.hinge,orientation:pose.orientation,tabletop:pose.tabletop}));
    await rpc('input.button',{name:'home'});
    const current=await rpc('device.snapshot');if(snapshot.lock.locked&&!current.lock.locked)await rpc('input.button',{name:'power'});
}
