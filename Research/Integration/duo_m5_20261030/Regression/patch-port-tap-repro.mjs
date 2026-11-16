import fs from 'node:fs';
import path from 'node:path';
import net from 'node:net';
import assert from 'node:assert/strict';
import {setTimeout as sleep} from 'node:timers/promises';
const root=fs.realpathSync(new URL('../../../../',import.meta.url));
const [mode='host',outArg]=process.argv.slice(2);assert(['host','guest','ax'].includes(mode));
const out=path.resolve(outArg);assert(out.startsWith(root+'/.build/'));fs.mkdirSync(out);
const machine=root+'/.build/duo-runtime-84e3ce54/machines/duo-patches-20261116';process.chdir(machine);
const raw=payload=>new Promise((resolve,reject)=>{
    const chunks=[],c=net.createConnection('./vphone.sock',()=>c.write(JSON.stringify(payload)+'\n'));
    c.setTimeout(30000,()=>c.destroy(Error('RPC timeout')));c.on('data',b=>chunks.push(b));c.on('error',reject);
    c.on('end',()=>{try{resolve(JSON.parse(Buffer.concat(chunks)))}catch(e){reject(e)}});
});
const checked=async payload=>{const r=await raw(payload);assert(r.ok,JSON.stringify(r));return r.result;};
const rpc=(method,params={})=>checked({t:'rpc',method,params,screen:false});
const save=(name,value)=>fs.writeFileSync(out+'/'+name+'.json',JSON.stringify(value,null,2)+'\n');
assert.equal((await rpc('device.info')).agent.binary_hash,'c04e362ae02b6b521bac06d1f2833850935e8e88ea121b8d7fd8fb139dd48593');
const pose=await rpc('display.pose'),lock=await rpc('display.auto_lock');
try {
    await rpc('display.auto_lock.set',{never:true});await rpc('screen.unlock',{timeout:30});
    await rpc('display.posture',{hinge:'closed'});await rpc('display.rotation',{orientation:'portrait'});
    await rpc('apps.launch',{bundle_id:'com.autophone.tap-probe'});await sleep(1200);
    const apps=await rpc('apps.list',{filter:'user'}),app=apps.apps.find(x=>x.bundle_id==='com.autophone.tap-probe');assert(app?.data_path);
    const probe=async()=>JSON.parse((await rpc('files.read',{path:app.data_path+'/Documents/tap-probe.json'})).content);
    const tree=await rpc('ui.tree');save('tree',tree);const identifier='tap-4',target=tree.elements.find(e=>e.identifier===identifier);assert(target?.clickable);
    const before=await probe(),host=await checked({t:'display.geometry'}),foreground=await rpc('apps.foreground');
    const parameters={x:target.x*before.screen.scale,y:target.y*before.screen.scale};
    const reply=mode==='host'?await raw({t:'tap',...parameters}):mode==='guest'?await raw({t:'rpc',method:'input.tap',params:{x:target.x,y:target.y},screen:false}):await raw({t:'rpc',method:'ui.tap_element',params:{identifier},screen:false});
    let after;
    for(let attempt=0;attempt<20;attempt++){await sleep(100);after=await probe();if(after.total!==before.total)break;}
    const touch=await raw({t:'rpc',method:'files.read',params:{path:app.data_path+'/Documents/tap-touch.json'},screen:false});
    save('result',{mode,target,parameters,host,foreground,reply,before,after,touch});
    assert(reply.ok);assert.equal(after.total,before.total+1);assert.equal(after.last_identifier,identifier);
    console.log(JSON.stringify({mode,actionReceived:true,total:after.total}));
} finally {
    save('lock-restored',await rpc('display.auto_lock.set',lock.never?{never:true}:{seconds:lock.auto_lock_seconds}));
    save('pose-restored',await rpc('display.posture',{hinge:pose.hinge,orientation:pose.orientation,tabletop:pose.tabletop}));
}
