import fs from 'node:fs';
import path from 'node:path';
import net from 'node:net';
import assert from 'node:assert/strict';
import {setTimeout as sleep} from 'node:timers/promises';
const [socketArg,outArg,expectedAgent]=process.argv.slice(2);
const root=fs.realpathSync(new URL('../../../../',import.meta.url));
const socket=fs.realpathSync(socketArg),out=path.resolve(outArg);
assert.equal(path.basename(path.dirname(socket)),'duo-patches-20261116');
assert(socket.startsWith(root+'/.build/')&&out.startsWith(root+'/.build/'));
assert(/^[a-f0-9]{64}$/.test(expectedAgent??''));fs.mkdirSync(out);process.chdir(path.dirname(socket));
const save=(name,value)=>fs.writeFileSync(out+'/'+name+'.json',JSON.stringify(value,null,2)+'\n');
const request=payload=>new Promise((resolve,reject)=>{
    const chunks=[],c=net.createConnection('./vphone.sock',()=>c.write(JSON.stringify(payload)+'\n'));
    c.setTimeout(30000,()=>c.destroy(Error('request timeout')));c.on('data',b=>chunks.push(b));c.on('error',reject);
    c.on('end',()=>{try{const j=JSON.parse(Buffer.concat(chunks));assert(j.ok,JSON.stringify(j));resolve(j.result)}catch(e){reject(e)}});
});
const rpc=(method,params={})=>request({t:'rpc',method,params,screen:false});
const info=await rpc('device.info');assert.equal(info.agent.binary_hash,expectedAgent);assert(info.ios_version.startsWith('27.1'));
const pose=await rpc('display.pose'),lock=await rpc('display.auto_lock'),snapshot=await rpc('device.snapshot');
save('initial',{info,pose,lock,snapshot});
const id='com.autophone.tap-probe';
const apps=await rpc('apps.list',{filter:'user'});save('apps',apps);
assert.equal(apps.truncated,false);
const app=apps.apps.find(x=>x.bundle_id===id);assert(app?.data_path,'Existing TapProbe required');
const probe=async()=>JSON.parse((await rpc('files.read',{path:app.data_path+'/Documents/tap-probe.json'})).content);
const rows=[];
try {
    await rpc('display.auto_lock.set',{never:true});await rpc('screen.unlock',{timeout:30});
    await rpc('apps.launch',{bundle_id:id});
    for(const hinge of ['closed','open-flat']){
        await rpc('display.posture',{hinge});await rpc('display.rotation',{orientation:'portrait'});await sleep(1800);
        const foreground=await rpc('apps.foreground');assert.equal(foreground.bundle_id,id);assert.equal(foreground.verified,true);
        const host=await request({t:'display.geometry'});save('host-'+hinge,host);assert.equal(host.windowed,true,'A windowed VZ touch path is required');
        const state=await probe();save('probe-'+hinge,state);assert.equal(state.orientation,1);
        await request({t:'screenshot',path:out+'/before-'+hinge+'.jpg'});
        for(const index of [0,4,8]){
            const identifier='tap-'+index,observations=[];
            let target;
            for(let attempt=0;attempt<20;attempt++){
                const tree=await rpc('ui.tree');observations.push({attempt,tree});
                save('tree-'+hinge+'-'+index,observations);
                target=tree.elements.find(e=>e.identifier===identifier);
                if(target?.clickable)break;
                await sleep(250);
            }
            assert(target?.clickable,hinge+': '+identifier+' must be present in AX');
            const before=await probe();
            // The host accepts current screenshot pixels. Duo can composite a
            // larger guest canvas into the fixed VZ backing framebuffer.
            assert.deepEqual(before.scene,before.screen.bounds);
            assert.equal(host.screenshot_pixels.length,2);
            const x=target.x*host.screenshot_pixels[0]/before.screen.bounds[0];
            const y=target.y*host.screenshot_pixels[1]/before.screen.bounds[1];
            const response=await request({t:'tap',x,y});
            let after;
            for(let retry=0;retry<20;retry++){await sleep(150);after=await probe();if(after.total!==before.total)break;}
            let touches=[],touchError;
            try { touches=JSON.parse((await rpc('files.read',{path:app.data_path+'/Documents/tap-touch.json'})).content); }
            catch(error) { touchError=String(error); }
            const row={hinge,identifier,target,pixels:{x,y},response,before,after,touches,touchError};rows.push(row);save('touches',rows);
            assert.equal(after.total,before.total+1);assert.equal(after.last_identifier,identifier);
            assert.equal(after.counts[identifier],before.counts[identifier]+1);
            assert(touches.some(t=>t.identifier===identifier));
        }
    }
    save('summary',{hostTaps:rows.length,appReceipts:rows.length,panels:2,windowed:true});
    console.log(JSON.stringify({hostTaps:rows.length,appReceipts:rows.length,panels:2,windowed:true}));
} finally {
    save('auto-lock-restored',await rpc('display.auto_lock.set',lock.never===true?{never:true}:{seconds:lock.auto_lock_seconds}));
    save('pose-restored',await rpc('display.posture',{hinge:pose.hinge,orientation:pose.orientation,tabletop:pose.tabletop}));
    await rpc('input.button',{name:'home'});
    const current=await rpc('device.snapshot');
    if(snapshot.lock.locked&&!current.lock.locked)await rpc('input.button',{name:'power'});
}
