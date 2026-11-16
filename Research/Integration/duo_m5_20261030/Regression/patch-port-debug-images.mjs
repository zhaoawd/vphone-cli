// Read installed debugger images and their backups; never write guest files.
import fs from 'node:fs';
import path from 'node:path';
import net from 'node:net';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
const [socketArg,outArg,bundleArg]=process.argv.slice(2);
const root=fs.realpathSync(new URL('../../../../',import.meta.url));
const socket=fs.realpathSync(socketArg),out=path.resolve(outArg),bundle=fs.realpathSync(bundleArg);
assert.equal(path.basename(path.dirname(socket)),'duo-patches-20261116');
for(const p of [socket,out,bundle])assert(p.startsWith(root+'/.build/'));
fs.mkdirSync(out);process.chdir(path.dirname(socket));
const save=(name,value)=>fs.writeFileSync(out+'/'+name+'.json',JSON.stringify(value,null,2)+'\n');
const hash=b=>createHash('sha256').update(b).digest('hex');
const rpc=(method,params={})=>new Promise((resolve,reject)=>{
    const chunks=[],c=net.createConnection('./vphone.sock',()=>c.write(JSON.stringify({t:'rpc',method,params,screen:false})+'\n'));
    c.setTimeout(60000,()=>c.destroy(Error('RPC timeout')));c.on('data',b=>chunks.push(b));c.on('error',reject);
    c.on('end',()=>{try{const r=JSON.parse(Buffer.concat(chunks));assert(r.ok,JSON.stringify(r));resolve(r.result)}catch(e){reject(e)}});
});
assert.equal((await rpc('device.info')).agent.binary_hash,hash(fs.readFileSync(bundle+'/Contents/Resources/guest-resources/vphoned')));
const catalog=JSON.parse(execFileSync(bundle+'/Contents/MacOS/vphone-cli',['fw','patches','duo-patches-20261116','-l',path.dirname(path.dirname(socket)),'--json'],{encoding:'utf8',maxBuffer:8*1024*1024}));
save('catalog',catalog);
const source=fs.readFileSync(root+'/VPhoneExecutable/VPhoneCommand/FirmwarePatcher/PatchSets/FirmwareGuestSystemPatchSet.swift','utf8');
const section=source.split('public static let arm64eX1DebugImages:')[1].split('/// In-process accessibility')[0];
const ids=[...section.matchAll(/"(system-[a-z0-9_-]+)"/g)].map(x=>x[1]);assert.equal(ids.length,12);
for(const kind of ['installed','pristine'])for(const name of ['System','usr'])fs.mkdirSync(out+'/'+kind+'/'+name,{recursive:true});
const rows=[];
const copyInstalled=async guestPath=>{
    const reply=await rpc('files.read',{path:guestPath,binary:true,limit:64*1024*1024});
    assert.equal(reply.encoding,'base64');assert.equal(reply.truncated,false,guestPath);
    const target=out+'/installed'+guestPath;
    fs.mkdirSync(path.dirname(target),{recursive:true});fs.writeFileSync(target,Buffer.from(reply.content,'base64'));
    return target;
};
for(const id of ids){
    const declaration=catalog.patches.find(x=>x.identifier===id);assert(declaration?.applied);assert.equal(declaration.pending,false);
    const guestPath=declaration.target.replace(/ \((file|executable)\)$/,'');assert(guestPath.startsWith('/'));
    const row={identifier:id,path:guestPath};
    for(const [kind,suffix] of [['installed',''],['pristine','.bak']]){
        const reply=await rpc('files.read',{path:guestPath+suffix,binary:true,limit:64*1024*1024});
        assert.equal(reply.encoding,'base64');assert.equal(reply.truncated,false,guestPath+suffix);
        const bytes=Buffer.from(reply.content,'base64'),target=out+'/'+kind+guestPath;
        fs.mkdirSync(path.dirname(target),{recursive:true});fs.writeFileSync(target,bytes);row[kind]={bytes:bytes.length,sha256:hash(bytes)};
    }
    assert.notEqual(row.installed.sha256,row.pristine.sha256,id);
    const framework=guestPath.match(/^(.+\.framework)\//)?.[1];
    if(framework){
        await copyInstalled(framework+'/Info.plist');
        const resourceFile=await copyInstalled(framework+'/_CodeSignature/CodeResources');
        // CodeResources contains plist Data, which plutil cannot emit as JSON.
        // Foundation extracts just the resource names without converting hashes.
        const resources=JSON.parse(execFileSync('/usr/bin/xcrun',['swift','-module-cache-path',out+'/modules','-e',`
            import Foundation
            let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments.last!))
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
            let names = Set(["files", "files2"].flatMap { Array((plist[$0] as? [String: Any] ?? [:]).keys) }).sorted()
            print(String(decoding: try JSONSerialization.data(withJSONObject: names), as: UTF8.self))
        `,resourceFile],{encoding:'utf8'}));
        for(const resource of resources){
            assert(!resource.startsWith('/')&&!resource.split('/').includes('..'),resource);
            await copyInstalled(framework+'/'+resource);
        }
        row.bundleResources=resources.length;
    }
    // Framework signatures include Info.plist and sealed resources. An
    // executable-only copy cannot validate those slots.
    execFileSync('/usr/bin/codesign',['--verify','--strict',out+'/installed'+(framework??guestPath)]);
    row.strictSignatureVerified=true;rows.push(row);save('images',rows);
}
let instructions=0;
for(const kind of ['installed','pristine']){
    const report=JSON.parse(execFileSync(bundle+'/Contents/MacOS/vphone-cli',['cfw','audit-arm64e-x1',out+'/'+kind,'--json',...(kind==='installed'?['--strict']:[])],{encoding:'utf8',maxBuffer:8*1024*1024}));
    save(kind+'-audit',report);assert.equal(report.failures.length,0);assert.equal(report.images.length,12);
    for(const image of report.images){
        assert.equal(image.unvisitedCandidates,0);assert.equal(image.state,kind==='installed'?'noLoweringNeeded':'needsLowering');
        assert.equal(image.declarations.length,1);assert(ids.includes(image.declarations[0]));
        if(kind==='pristine'){assert(image.instructions>0);instructions+=image.instructions;}
    }
}
save('summary',{images:12,pristineInstructions:instructions,noRemainingX1:true,backupsReadable:true,strictSignatures:12,lldbTested:false});
console.log(JSON.stringify({images:12,pristineInstructions:instructions,noRemainingX1:true,strictSignatures:12,lldbTested:false}));
