// Validate native capture pixels against independently measured UIKit fixed points.
import fs from 'node:fs';
import path from 'node:path';
import net from 'node:net';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {setTimeout as sleep} from 'node:timers/promises';
import {markerPixels} from './display-marker-pixels.mjs';
const [socketArg,outArg,ipaArg,expectedAgent]=process.argv.slice(2);
const root=fs.realpathSync(new URL('../../../../',import.meta.url));
const socket=fs.realpathSync(socketArg),out=path.resolve(outArg),ipa=fs.realpathSync(ipaArg);
assert.equal(path.dirname(socket),root+'/.build/duo-runtime-84e3ce54/machines/duo-overall-20261116');
for(const file of [out,ipa])assert(file.startsWith(root+'/.build/'));
fs.mkdirSync(out);process.chdir(path.dirname(socket));
const save=(name,value)=>fs.writeFileSync(out+'/'+name+'.json',JSON.stringify(value,null,2)+'\n');
const request=payload=>new Promise((resolve,reject)=>{
    const chunks=[],c=net.createConnection('./vphone.sock',()=>c.write(JSON.stringify({...payload,screen:false})+'\n'));
    c.setTimeout(45000,()=>c.destroy(Error('Request timeout')));c.on('data',b=>chunks.push(b));c.on('error',reject);
    c.on('end',()=>{try{const r=JSON.parse(Buffer.concat(chunks));assert(r.ok,JSON.stringify(r));resolve(r.result)}catch(e){reject(e)}});
});
const rpc=(method,params={})=>request({t:'rpc',method,params});
const device=await rpc('device.info');assert.equal(device.agent.binary_hash,expectedAgent);
const original={device,pose:await rpc('display.pose'),lock:await rpc('display.auto_lock')};save('before',original);
const id='com.vphone.tests.display-probe';let apps=await rpc('apps.list',{filter:'user'});assert.equal(apps.truncated,false);
if(!apps.apps.some(a=>a.bundle_id===id)){
    save('input',{ipa,sha256:createHash('sha256').update(fs.readFileSync(ipa)).digest('hex'),installationPath:'apps.install'});
    const guest='/var/root/Library/Caches/display-probe-20261116.ipa';
    save('upload',await request({t:'push',local:ipa,path:guest,mode:'644'}));
    save('install',await rpc('apps.install',{path:guest}));apps=await rpc('apps.list',{filter:'user'});
}
const app=apps.apps.find(a=>a.bundle_id===id);assert(app?.data_path);save('app',app);
const probe=async()=>JSON.parse((await rpc('files.read',{path:app.data_path+'/Documents/display-probe.json'})).content);
const rows=[];
try{
    await rpc('display.auto_lock.set',{never:true});await rpc('screen.unlock',{timeout:30});
    await rpc('display.rotation_lock',{locked:false});await rpc('apps.launch',{bundle_id:id});await sleep(1000);
    for(const [panel,hinge,displayID,angles] of [['outer','closed',1,[0,90,270]],['inner','open-flat',7,[0,90,180]]]){
        await rpc('display.posture',{hinge,orientation:'portrait'});
        for(const degrees of angles){
            const key=panel+'-'+degrees,row={panel,degrees};rows.push(row);
            try{
                row.rotation=await rpc('display.rotation',{orientation:String(degrees)});await sleep(800);
                row.orientation=await rpc('display.orientation');assert.equal(row.orientation.degrees,degrees);
                const front=await rpc('apps.foreground');assert(front.verified&&front.bundle_id===id);row.foreground=front;
                row.probe=await probe();
                const capture=await rpc('display.capture_active'),{base64,...metadata}=capture;row.capture=metadata;
                assert.equal(capture.available,true);assert.equal(capture.source.display_id,displayID);assert.equal(capture.source_after.display_id,displayID);
                const image=out+'/'+key+'.png';fs.writeFileSync(image,Buffer.from(base64,'base64'));
                const decoded=spawnSync('ffmpeg',['-v','error','-threads','1','-i',image,'-frames:v','1','-pix_fmt','rgba','-f','rawvideo','-'],{maxBuffer:64*1024*1024});
                assert.equal(decoded.status,0,decoded.stderr.toString());
                row.pixels=markerPixels(decoded.stdout,capture.width,capture.height,row.probe);
                const after=await probe();assert.equal(after.pid,row.probe.pid);assert.equal(after.orientation,row.probe.orientation);
                assert.deepEqual(after.fixed,row.probe.fixed);assert.deepEqual(after.markers,row.probe.markers);
                row.passed=row.pixels.every(p=>p.passed);
                await request({t:'screenshot',path:out+'/'+key+'-host.png'});
            }catch(error){row.error=String(error);row.passed=false;}
            save('results',rows);
        }
    }
}finally{
    await rpc('input.button',{name:'home'});
    save('pose-restored',await rpc('display.posture',{hinge:original.pose.hinge,orientation:original.pose.orientation,tabletop:original.pose.tabletop}));
    save('rotation-lock-restored',await rpc('display.rotation_lock',{locked:device.rotation.locked}));
    save('auto-lock-restored',await rpc('display.auto_lock.set',original.lock.never?{never:true}:{seconds:original.lock.auto_lock_seconds}));
    const current=await rpc('device.info');if(device.lock.locked&&!current.lock.locked)await rpc('input.button',{name:'power'});
}
const summary={cases:rows.length,passed:rows.filter(r=>r.passed).length,markerChecks:rows.reduce((n,r)=>n+(r.pixels?.length??0),0),
    scope:'Native raw capture colors at UIKit window-to-fixed-screen points; no global capture metadata guarantee'};
save('summary',summary);console.log(JSON.stringify(summary));assert.equal(rows.length,6);assert(rows.every(r=>r.passed),'Native pixels must match every measured marker');
